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
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {FixedValuePriceFeed} from "../../contracts/price_oracle/price_feed/FixedValuePriceFeed.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {FeeConfigHelper} from "../test_helpers/FeeConfigHelper.sol";
import {PlasmaVaultConfigurator} from "../utils/PlasmaVaultConfigurator.sol";
import {RoleLib, UsersToRoles} from "../RoleLib.sol";
import {MockERC20Decimals} from "../unitTest/fuses/term_finance/mocks/MockERC20Decimals.sol";

/// @title PlasmaVaultPerformanceFeeRateOverflowTest
/// @notice Regression suite for IL-8307 - a 1 wei deposit followed by a direct donation of ~681 tokens of an
///         18-decimal asset pushes `convertToAssets(10 ** decimals())` above `type(uint128).max`. Before the fix
///         `PlasmaVaultFeesLib.prepareForAddPerformanceFee` narrowed that rate with `toUint128()` and every
///         withdraw, redeem and execute reverted. `_addPerformanceFee` now skips the performance fee above the bound.
contract PlasmaVaultPerformanceFeeRateOverflowTest is Test {
    address public atomist = address(this);
    address public alpha = address(0x1);
    address public attacker = address(0xA77ACCE7);
    address public victim = address(0xB1C71);

    /// @dev 1 wei seed mints 100 shares; rate = 1e20 * (A + 1) / 200 exceeds uint128 max once A > ~6.806e20
    uint256 public constant DONATION = 700e18;
    uint256 public constant VICTIM_DEPOSIT = 1_000e18;

    MockERC20Decimals public asset;
    UsersToRoles public usersToRoles;
    PlasmaVault public plasmaVault;
    WithdrawManager public withdrawManager;

    function setUp() public {
        asset = new MockERC20Decimals("Mock 18", "M18", 18);

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
        withdrawManager = new WithdrawManager(address(accessManager));

        plasmaVault = new PlasmaVault();
        plasmaVault.proxyInitialize(
            PlasmaVaultInitData(
                "IPOR Fusion M18",
                "ipfM18",
                address(asset),
                address(priceOracleMiddlewareProxy),
                FeeConfigHelper.createZeroFeeConfig(),
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

        _seedAndDonate();

        asset.mint(victim, VICTIM_DEPOSIT);
        vm.startPrank(victim);
        asset.approve(address(plasmaVault), type(uint256).max);
        plasmaVault.deposit(VICTIM_DEPOSIT, victim);
        vm.stopPrank();
    }

    function testShouldPushExchangeRateAboveUint128_whenDustSupplyVaultReceivesDonation() public view {
        assertGt(
            plasmaVault.convertToAssets(10 ** uint256(plasmaVault.decimals())),
            type(uint128).max,
            "rate above uint128"
        );
        assertGt(plasmaVault.balanceOf(victim), 0, "victim minted shares");
    }

    function testShouldRedeem_whenExchangeRateExceedsUint128() public {
        uint256 shares = plasmaVault.balanceOf(victim);
        uint256 expectedAssets = plasmaVault.previewRedeem(shares);

        vm.prank(victim);
        uint256 assets = plasmaVault.redeem(shares, victim, victim);

        assertEq(assets, expectedAssets, "redeemed assets");
        assertEq(asset.balanceOf(victim), expectedAssets, "victim received assets");
        assertEq(plasmaVault.balanceOf(victim), 0, "victim shares burned");
    }

    function testShouldWithdraw_whenExchangeRateExceedsUint128() public {
        uint256 assets = plasmaVault.maxWithdraw(victim) / 2;

        vm.prank(victim);
        plasmaVault.withdraw(assets, victim, victim);

        assertEq(asset.balanceOf(victim), assets, "victim received assets");
    }

    function testShouldExecute_whenExchangeRateExceedsUint128() public {
        uint256 totalSupplyBefore = plasmaVault.totalSupply();

        vm.prank(alpha);
        plasmaVault.execute(new FuseAction[](0));

        assertEq(plasmaVault.totalSupply(), totalSupplyBefore, "no performance fee shares minted");
    }

    function _seedAndDonate() internal {
        asset.mint(attacker, 1 + DONATION);
        vm.startPrank(attacker);
        asset.approve(address(plasmaVault), type(uint256).max);
        plasmaVault.deposit(1, attacker);
        asset.transfer(address(plasmaVault), DONATION);
        vm.stopPrank();
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
