// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {
    PlasmaVault,
    MarketBalanceFuseConfig,
    MarketSubstratesConfig,
    PlasmaVaultInitData
} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {FixedValuePriceFeed} from "../../contracts/price_oracle/price_feed/FixedValuePriceFeed.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {FeeManagerFactory, FeeConfig} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {PlasmaVaultConfigurator} from "../utils/PlasmaVaultConfigurator.sol";
import {RoleLib, UsersToRoles} from "../RoleLib.sol";
import {MockERC20Decimals} from "../unitTest/fuses/term_finance/mocks/MockERC20Decimals.sol";

/// @title PlasmaVaultManagementFeeDormantDustTest
/// @notice Regression suite for IL-8318 - `_realizeManagementFee` advanced the fee clock only when fee shares
///         were minted or the gross total assets were exactly zero. A 1 wei donation (or a 1 wei deposit) to an
///         empty vault froze `lastUpdateTimestamp`, so the first real deposit was charged the management fee for
///         the whole dormant period. The clock now advances on every realization and a fee that rounds to zero
///         shares is kept in the pending management fee, which keeps the IL-6959 anti-suppression property.
contract PlasmaVaultManagementFeeDormantDustTest is Test {
    address public atomist = address(this);
    address public alpha = address(0x1);
    address public attacker = address(0xA77ACCE7);
    address public victim = address(0xB1C71);
    address public depositor = address(0xDE9051);

    /// @dev 2% per year, FeeManager percentages use 2 decimals (10000 = 100%)
    uint256 public constant MANAGEMENT_FEE = 200;
    uint256 public constant VICTIM_DEPOSIT = 10_000_000e6;
    uint256 public constant DORMANT_PERIOD = 365 days;
    uint256 public constant ACTIVE_PERIOD = 1 days;

    MockERC20Decimals public asset;
    UsersToRoles public usersToRoles;
    PlasmaVault public plasmaVault;
    address public managementFeeAccount;

    function setUp() public {
        asset = new MockERC20Decimals("Mock USDC", "mUSDC", 6);

        PriceOracleMiddleware implementation = new PriceOracleMiddleware(address(0));
        PriceOracleMiddleware priceOracleMiddlewareProxy = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );
        address[] memory assets = new address[](1);
        assets[0] = address(asset);
        address[] memory sources = new address[](1);
        sources[0] = address(new FixedValuePriceFeed(1e8));
        priceOracleMiddlewareProxy.setAssetsPricesSources(assets, sources);

        IporFusionAccessManager accessManager = _createAccessManager();
        WithdrawManager withdrawManager = new WithdrawManager(address(accessManager));

        plasmaVault = new PlasmaVault();
        plasmaVault.proxyInitialize(
            PlasmaVaultInitData(
                "IPOR Fusion mUSDC",
                "ipfmUSDC",
                address(asset),
                address(priceOracleMiddlewareProxy),
                FeeConfig({
                    iporDaoManagementFee: MANAGEMENT_FEE,
                    iporDaoPerformanceFee: 0,
                    feeFactory: address(new FeeManagerFactory()),
                    iporDaoFeeRecipientAddress: address(98989898)
                }),
                address(accessManager),
                address(new PlasmaVaultBase()),
                address(withdrawManager),
                address(0)
            )
        );

        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(plasmaVault), accessManager, address(withdrawManager));

        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            atomist,
            address(plasmaVault),
            new address[](0),
            new MarketBalanceFuseConfig[](0),
            new MarketSubstratesConfig[](0)
        );

        managementFeeAccount = PlasmaVaultGovernance(address(plasmaVault)).getManagementFeeData().feeAccount;

        _fund(attacker, 1_000e6 + 1);
        _fund(victim, VICTIM_DEPOSIT);
        _fund(depositor, 1_000_000e6);
    }

    function testShouldNotChargeDormantPeriod_whenDustDonatedToEmptyVault() public {
        vm.prank(attacker);
        asset.transfer(address(plasmaVault), 1);

        vm.warp(block.timestamp + DORMANT_PERIOD);
        _deposit(victim, VICTIM_DEPOSIT);

        assertApproxEqAbs(plasmaVault.totalAssets(), VICTIM_DEPOSIT + 1, 1, "no fee priced on the victim deposit");

        vm.warp(block.timestamp + ACTIVE_PERIOD);
        _deposit(depositor, 1e6);

        _assertFeeCoversOnlyActivePeriod(0);
    }

    function testShouldNotChargeDormantPeriod_whenDustDepositedToEmptyVault() public {
        _deposit(attacker, 1);
        assertGt(plasmaVault.totalSupply(), 0, "dust shares minted");

        vm.warp(block.timestamp + DORMANT_PERIOD);
        _deposit(victim, VICTIM_DEPOSIT);

        assertApproxEqAbs(plasmaVault.totalAssets(), VICTIM_DEPOSIT + 1, 1, "no fee priced on the victim deposit");

        vm.warp(block.timestamp + ACTIVE_PERIOD);
        _deposit(depositor, 1e6);

        _assertFeeCoversOnlyActivePeriod(0);
    }

    function testShouldChargeDormantFeeOnlyOnDormantBase_whenDustSharesHoldDonation() public {
        uint256 donation = 1_000e6;
        _deposit(attacker, 1);
        vm.prank(attacker);
        asset.transfer(address(plasmaVault), donation);

        /// @dev 90 days at 2% on 1 000 tokens is ~4.93 tokens, below one share at this inflated rate
        vm.warp(block.timestamp + 90 days);
        uint256 dormantFee = ((donation + 1) * 90 days * MANAGEMENT_FEE) / (365 days * 1e4);
        uint256 supplyBefore = plasmaVault.totalSupply();

        _deposit(victim, VICTIM_DEPOSIT);

        assertEq(
            plasmaVault.totalSupply() - plasmaVault.balanceOf(victim),
            supplyBefore,
            "dormant fee rounded to zero shares"
        );
        assertEq(plasmaVault.getUnrealizedManagementFee(), dormantFee, "dormant fee kept as pending");
        assertEq(
            PlasmaVaultGovernance(address(plasmaVault)).getManagementFeeData().lastUpdateTimestamp,
            block.timestamp,
            "fee clock advanced"
        );

        vm.warp(block.timestamp + ACTIVE_PERIOD);
        _deposit(depositor, 100e6);

        _assertFeeCoversOnlyActivePeriod(dormantFee + donation);
    }

    /// @dev IL-6959: operations whose fee rounds to zero shares must not suppress the management fee
    function testShouldKeepAccruing_whenEveryRealizationRoundsToZeroShares() public {
        uint256 donation = 1_000e6;
        _deposit(attacker, 1);
        vm.prank(attacker);
        asset.transfer(address(plasmaVault), donation);

        uint256 baseAssets = plasmaVault.totalAssets();
        uint256 supplyBefore = plasmaVault.totalSupply();
        uint256 steps = 50;

        for (uint256 i; i < steps; ++i) {
            vm.warp(block.timestamp + 1 hours);
            _deposit(depositor, 100e6);
        }

        uint256 minimumFee = (baseAssets * steps * 1 hours * MANAGEMENT_FEE) / (365 days * 1e4);

        assertEq(plasmaVault.balanceOf(managementFeeAccount), 0, "no fee shares minted yet");
        assertGt(plasmaVault.totalSupply(), supplyBefore, "depositors minted shares");
        assertGe(plasmaVault.getUnrealizedManagementFee(), minimumFee, "fee not suppressed");
        assertEq(
            PlasmaVaultGovernance(address(plasmaVault)).getManagementFeeData().lastUpdateTimestamp,
            block.timestamp,
            "fee clock advanced"
        );
    }

    /// @param extraBase_ assets that were in the vault before the victim deposit (dormant fee and donation)
    function _assertFeeCoversOnlyActivePeriod(uint256 extraBase_) internal view {
        uint256 activeFee = ((VICTIM_DEPOSIT + extraBase_ + 1) * ACTIVE_PERIOD * MANAGEMENT_FEE) / (365 days * 1e4);
        uint256 dormantFeeOnVictim = (VICTIM_DEPOSIT * DORMANT_PERIOD * MANAGEMENT_FEE) / (365 days * 1e4);
        uint256 feeAssets = plasmaVault.convertToAssets(plasmaVault.balanceOf(managementFeeAccount)) +
            plasmaVault.getUnrealizedManagementFee();

        assertGt(feeAssets, 0, "active period fee charged");
        assertLe(feeAssets, activeFee + extraBase_ / 100 + 1e6, "fee limited to the active period");
        assertLt(feeAssets, dormantFeeOnVictim / 100, "dormant period not charged on the victim deposit");
    }

    function _deposit(address user_, uint256 amount_) internal {
        vm.prank(user_);
        plasmaVault.deposit(amount_, user_);
    }

    function _fund(address user_, uint256 amount_) internal {
        asset.mint(user_, amount_);
        vm.prank(user_);
        asset.approve(address(plasmaVault), type(uint256).max);
    }

    function _createAccessManager() internal returns (IporFusionAccessManager) {
        usersToRoles.superAdmin = atomist;
        usersToRoles.atomist = atomist;
        address[] memory alphas = new address[](1);
        alphas[0] = alpha;
        usersToRoles.alphas = alphas;
        return RoleLib.createAccessManager(usersToRoles, 0, vm);
    }
}
