// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {
    PlasmaVault,
    FuseAction,
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
import {FeeManager} from "../../contracts/managers/fee/FeeManager.sol";
import {FeeAccount} from "../../contracts/managers/fee/FeeAccount.sol";
import {PlasmaVaultConfigurator} from "../utils/PlasmaVaultConfigurator.sol";
import {RoleLib, UsersToRoles} from "../RoleLib.sol";
import {MockERC20Decimals} from "../unitTest/fuses/term_finance/mocks/MockERC20Decimals.sol";
import {PlasmaVaultCloneLib} from "../test_helpers/PlasmaVaultCloneLib.sol";

/// @title OlympixPerformanceFeeGrossRatePoC
/// @notice Olympix scan 2026-11-06, finding 5.1.24 (performance fee on the gross rate that includes the unrealized
///         management fee), adapted to the IL-8870 branch. `execute` crystallizes the performance fee while the
///         management fee is only accrued; the result for the depositor must equal the result of the path that
///         realizes the management fee first, and the high-water mark must not sit above the net price after the
///         fee is realized.
contract OlympixPerformanceFeeGrossRatePoC is Test {
    address public atomist = address(this);
    address public alpha = address(0xA1FA);
    address public depositor = address(0xDE9051);
    address public poker = address(0xB0CE);
    address public yieldSource = address(0x71E1D);

    /// @dev 2% per year management fee, 20% performance fee (2 decimals, 10000 = 100%)
    uint256 public constant MANAGEMENT_FEE = 200;
    uint256 public constant PERFORMANCE_FEE = 2000;
    uint256 public constant DEPOSIT = 1_000_000e6;
    uint256 public constant GAIN = 100_000e6;
    uint256 public constant QUIET_PERIOD = 365 days / 2;
    /// @dev tolerance of the PoC: 1 USDC
    uint256 public constant TOLERANCE = 1e6;

    MockERC20Decimals public asset;
    UsersToRoles public usersToRoles;
    PlasmaVault public plasmaVault;
    FeeManager public feeManager;
    address public performanceFeeAccount;

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
        sources[0] = address(new FixedValuePriceFeed(1e18));
        priceOracleMiddlewareProxy.setAssetsPricesSources(assets, sources);

        IporFusionAccessManager accessManager = _createAccessManager();
        WithdrawManager withdrawManager = new WithdrawManager(address(accessManager));

        plasmaVault = PlasmaVaultCloneLib.newPlasmaVault();
        plasmaVault.proxyInitialize(
            PlasmaVaultInitData(
                "IPOR Fusion mUSDC",
                "ipfmUSDC",
                address(asset),
                address(priceOracleMiddlewareProxy),
                FeeConfig({
                    iporDaoManagementFee: MANAGEMENT_FEE,
                    iporDaoPerformanceFee: PERFORMANCE_FEE,
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

        performanceFeeAccount = PlasmaVaultGovernance(address(plasmaVault)).getPerformanceFeeData().feeAccount;
        feeManager = FeeManager(FeeAccount(performanceFeeAccount).FEE_MANAGER());

        _fund(depositor, DEPOSIT);
        _fund(poker, 10e6);
        asset.mint(yieldSource, GAIN);
    }

    function testShouldNotChargeDepositorPerformanceFeeOnUnrealizedManagementFee_whenExecute() public {
        vm.prank(depositor);
        plasmaVault.deposit(DEPOSIT, depositor);

        /// @dev six quiet months: the management fee accrues unrealized
        vm.warp(block.timestamp + QUIET_PERIOD);

        vm.prank(yieldSource);
        asset.transfer(address(plasmaVault), GAIN);

        assertGt(plasmaVault.getUnrealizedManagementFee(), 0, "management fee pending");

        uint256 snap = vm.snapshotState();

        /// @dev path A: execute crystallizes the performance fee while the management fee is only accrued
        vm.prank(alpha);
        plasmaVault.execute(new FuseAction[](0));
        uint256 depositorValueAccrued = plasmaVault.maxWithdraw(depositor);
        uint256 perfFeeValueAccrued = plasmaVault.maxWithdraw(performanceFeeAccount);
        uint256 hwmAccrued = feeManager.getPlasmaVaultHighWaterMarkPerformanceFee().highWaterMark;

        /// @dev any deposit realizes the pending management fee
        vm.prank(poker);
        plasmaVault.deposit(1e6, poker);
        /// @dev IL-9601: the high-water mark is per 10 ** decimals() shares times 1e12, so the price is read in that unit
        uint256 priceAfterRealization = plasmaVault.convertToAssets(10 ** uint256(plasmaVault.decimals()) * 1e12);

        vm.revertToState(snap);

        /// @dev path B (reference): the management fee is realized first, as withdraw and redeem do
        vm.prank(poker);
        plasmaVault.deposit(1e6, poker);
        vm.prank(alpha);
        plasmaVault.execute(new FuseAction[](0));
        uint256 depositorValueRealized = plasmaVault.maxWithdraw(depositor);
        uint256 perfFeeValueRealized = plasmaVault.maxWithdraw(performanceFeeAccount);

        assertGt(perfFeeValueRealized, 0, "performance fee charged on the reference path");
        assertGt(perfFeeValueAccrued, 0, "performance fee charged on the accrued path");
        assertApproxEqAbs(
            depositorValueAccrued,
            depositorValueRealized,
            TOLERANCE,
            "depositor result depends on whether the management fee was realized first"
        );
        /// @dev the net price after the mint is the high-water mark or at most one old price unit (1e12 of the scaled
        ///      unit, the same value as before IL-9601) below it
        assertGe(priceAfterRealization + 1e12, hwmAccrued, "HWM sits above the net price after the fee is realized");
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
