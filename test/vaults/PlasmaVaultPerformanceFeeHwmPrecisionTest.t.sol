// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PlasmaVaultCloneLib} from "../test_helpers/PlasmaVaultCloneLib.sol";
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

/// @title Performance fee rate and high-water mark precision (IL-9601, Olympix 2026-11-06 M11)
/// @notice Before IL-9601 the vault passed the share rate to the FeeManager as an integer number of asset units per
///         10 ** decimals() shares and the FeeManager stored the post-fee high-water mark floored to that unit. On a
///         6-decimal asset one unit is 1 ppm of the price: after a fee the HWM sits up to one unit below the true
///         post-fee price and that fraction is charged again at the next crossing, so a crystallization every 0.1 ppm
///         collects close to all of the gain. With IL-9601 the rate and the HWM carry 1e12 more precision: assets per
///         10 ** decimals() shares times 1e12, computed by the vault in one mulDiv from the same terms as the net rate.
/// @dev The test compiles against the code before IL-9601 (base copy) and fails there behaviourally. The scale is a
///      literal here; on the new FeeManager it is `HIGH_WATER_MARK_SCALE()`, read through a low-level call.
contract PlasmaVaultPerformanceFeeHwmPrecisionTest is Test {
    address public atomist = address(this);
    address public alpha = address(0x1);
    address public user = address(0xA11CE);
    /// @dev any unprivileged holder; its redeems crystallize the performance fee
    address public poker = address(0x9013E7);

    /// @dev 20% performance fee (FeeManager percentages use 2 decimals, 10000 = 100%)
    uint256 public constant PERFORMANCE_FEE = 2000;
    /// @dev Scale of the rate passed to the FeeManager and of the stored high-water mark (IL-9601)
    uint256 public constant HWM_SCALE = 1e12;
    /// @dev 10 ** PlasmaVaultLib.DECIMALS_OFFSET
    uint256 public constant SHARE_SCALE = 100;
    /// @dev 10_000_000 = one tenth of a ppm of the total assets per step
    uint256 public constant TENTH_PPM_DIVISOR = 10_000_000;
    uint256 public constant STEPS = 1000;

    MockERC20Decimals public asset;
    UsersToRoles public usersToRoles;
    IporFusionAccessManager public accessManager;
    WithdrawManager public withdrawManager;
    PlasmaVault public plasmaVault;
    FeeManager public feeManager;
    address public performanceFeeAccount;
    uint256 public oneShare;
    uint256 public userDeposit;
    uint256 public pokeShares;

    // ---------------------------------------------------------------------------------------------
    // M11 - frequent crystallization charges the configured fee, not the rounding unit
    // ---------------------------------------------------------------------------------------------

    /// @dev 1000 gains of 0.1 ppm on a 6-decimal asset, each crystallized by a small redeem. Before IL-9601 the HWM
    ///      floors back by up to 1 ppm after every fee and the same unit is charged again: the fee account collects
    ///      close to all of the gain. With the 1e12 scale the fee is 20% of the gain within 10 bps of the gain.
    function testShouldChargeConfiguredFeeWhenRedeemCrystallizesEveryTenthPpmUsdc() public {
        _deployVault(6, 0);
        _depositAll();

        (uint256 effectiveFeeBps, uint256 totalGain, uint256 feeValue) = _runRedeemSteps(STEPS);

        assertGe(effectiveFeeBps, 1990, "effective fee (6 decimals) >= 19.90%");
        assertLe(effectiveFeeBps, 2010, "effective fee (6 decimals) <= 20.10%");
        assertApproxEqAbs(
            feeValue,
            (totalGain * PERFORMANCE_FEE) / 10000,
            (totalGain * 10) / 10000,
            "fee account holds 20% of the gain within 10 bps of the gain"
        );
    }

    /// @dev The same run on an 18-decimal asset: the 1e12 scale keeps the rate (about 1e30) inside uint128
    function testShouldChargeConfiguredFeeWhenRedeemCrystallizesEveryTenthPpmEighteenDecimals() public {
        _deployVault(18, 0);
        _depositAll();

        (uint256 effectiveFeeBps, uint256 totalGain, uint256 feeValue) = _runRedeemSteps(STEPS);

        assertGe(effectiveFeeBps, 1990, "effective fee (18 decimals) >= 19.90%");
        assertLe(effectiveFeeBps, 2010, "effective fee (18 decimals) <= 20.10%");
        assertApproxEqAbs(
            feeValue,
            (totalGain * PERFORMANCE_FEE) / 10000,
            (totalGain * 10) / 10000,
            "fee account holds 20% of the gain within 10 bps of the gain"
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Scale of the rate passed to the FeeManager and of the stored HWM
    // ---------------------------------------------------------------------------------------------

    /// @dev initialize() stores the starting rate in the new scale: 10 ** assetDecimals * 1e12
    function testShouldInitializeHwmInRateScale() public {
        _deployVault(6, 0);
        assertEq(_hwm(), 1e6 * HWM_SCALE, "6 decimals: HWM = 1 asset per share in the 1e12 scale");

        _deployVault(18, 0);
        assertEq(_hwm(), 1e18 * HWM_SCALE, "18 decimals: HWM = 1 asset per share in the 1e12 scale");

        (bool ok, bytes memory ret) = address(feeManager).staticcall(
            abi.encodeWithSignature("HIGH_WATER_MARK_SCALE()")
        );
        assertTrue(ok, "FeeManager exposes HIGH_WATER_MARK_SCALE()");
        assertEq(abi.decode(ret, (uint256)), HWM_SCALE, "HIGH_WATER_MARK_SCALE() = 1e12");
    }

    /// @dev The vault passes assets per 10 ** decimals() shares times 1e12 and the HWM after the fee is the post-mint
    ///      price in that scale: at or below the exact price and less than one unit of the scale below it
    function testShouldStorePostMintPriceInRateScaleWithinOneUnit() public {
        _deployVault(6, 0);
        _depositAll();
        asset.mint(address(plasmaVault), userDeposit / 10);

        uint256 supply = plasmaVault.totalSupply();
        uint256 expectedRate = Math.mulDiv(oneShare * HWM_SCALE, plasmaVault.totalAssets() + 1, supply + SHARE_SCALE);
        vm.expectCall(
            address(feeManager),
            abi.encodeCall(
                FeeManager.calculateAndUpdatePerformanceFee,
                (uint128(expectedRate), supply, PERFORMANCE_FEE, 6)
            )
        );
        _crystallize();

        uint256 hwm = _hwm();
        uint256 totalAssets = plasmaVault.totalAssets();
        uint256 supplyAfter = plasmaVault.totalSupply();
        uint256 floorPrice = Math.mulDiv(oneShare * HWM_SCALE, totalAssets + 1, supplyAfter + SHARE_SCALE);
        uint256 ceilPrice = Math.mulDiv(
            oneShare * HWM_SCALE,
            totalAssets + 1,
            supplyAfter + SHARE_SCALE,
            Math.Rounding.Ceil
        );

        assertGt(supplyAfter, supply, "precondition: performance fee minted");
        assertEq(hwm, floorPrice, "HWM is the post-mint price in the 1e12 scale, rounded down");
        assertLe(ceilPrice - hwm, 1, "HWM is less than one unit of the scale below the post-mint price");
        assertEq(
            hwm,
            plasmaVault.convertToAssets(oneShare * HWM_SCALE),
            "HWM = convertToAssets(10 ** decimals * 1e12)"
        );
        assertEq(hwm / HWM_SCALE, plasmaVault.convertToAssets(oneShare), "HWM / 1e12 = the integer share price");
        assertGt(hwm % HWM_SCALE, 0, "the HWM keeps the fraction of the asset unit");
    }

    /// @dev IL-8870 net rate: with an accrued (unrealized) management fee the rate is one mulDiv of the same terms as
    ///      the net price, mulDiv(10 ** decimals * 1e12, G + 1, S + V + scale), not the rounded net price times 1e12
    function testShouldPassNetRateInRateScaleFromOneMulDiv_whenManagementFeeAccrued() public {
        _deployVault(6, 200);
        _depositAll();
        vm.warp(block.timestamp + 30 days);
        asset.mint(address(plasmaVault), userDeposit / 100);

        uint256 gross = plasmaVault.totalAssets();
        uint256 supply = plasmaVault.totalSupply();
        uint256 fee = plasmaVault.getUnrealizedManagementFee();
        uint256 virtualShares = Math.mulDiv(fee, supply + SHARE_SCALE, gross - fee + 1);
        uint256 netSupply = supply + virtualShares;
        uint256 expectedRate = Math.mulDiv(oneShare * HWM_SCALE, gross + 1, netSupply + SHARE_SCALE);
        uint256 hwmBefore = _hwm();

        assertGt(fee, 0, "precondition: management fee accrued");
        assertNotEq(
            expectedRate,
            plasmaVault.convertToAssets(oneShare) * HWM_SCALE,
            "precondition: one mulDiv differs from scaling the rounded rate"
        );
        assertGt(expectedRate, hwmBefore, "precondition: net rate above the HWM");

        vm.expectCall(
            address(feeManager),
            abi.encodeCall(
                FeeManager.calculateAndUpdatePerformanceFee,
                (uint128(expectedRate), netSupply, PERFORMANCE_FEE, 6)
            )
        );
        _crystallize();

        uint256 feeValue = (expectedRate - hwmBefore) * PERFORMANCE_FEE;
        uint256 perfShares = Math.mulDiv(netSupply, feeValue, expectedRate * 10000 - feeValue);
        uint256 expectedHwm = Math.mulDiv(oneShare * HWM_SCALE, gross + 1, netSupply + perfShares + SHARE_SCALE);
        uint256 netPriceAfter = plasmaVault.convertToAssets(oneShare * HWM_SCALE);

        assertEq(_hwm(), expectedHwm, "HWM = post-mint net price in the 1e12 scale");
        assertLe(netPriceAfter, _hwm(), "net price after the mint is not above the HWM");
        assertLe(
            _hwm() - netPriceAfter,
            Math.mulDiv(_hwm(), 2, netSupply) + 1,
            "net price after the mint is at most two share units below the HWM"
        );
    }

    /// @dev The owner reset stores the current net price in the same scale, and the next fee is charged only on the
    ///      gain above it. Since IL-9667 the reset cannot raise the HWM over a gain that is not crystallized (asserted
    ///      first), so the scale is checked on a downward reset: gain crystallized, then a loss, then the reset.
    function testShouldResetHwmInRateScale_whenOwnerUpdatesHighWaterMark() public {
        _deployVault(6, 0);
        _depositAll();
        asset.mint(address(plasmaVault), userDeposit / 20);

        uint256 storedHighWaterMark = _hwm();
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("HighWaterMarkResetAboveStored(uint256,uint256)")),
                plasmaVault.convertToAssets(oneShare * HWM_SCALE),
                storedHighWaterMark
            )
        );
        vm.prank(alpha);
        feeManager.updateHighWaterMarkPerformanceFee();

        _crystallize();
        uint256 feeSharesAfterGain = plasmaVault.balanceOf(performanceFeeAccount);

        uint256 loss = plasmaVault.totalAssets() / 10;
        vm.prank(address(plasmaVault));
        asset.transfer(address(0xdead), loss);
        uint256 resetRate = plasmaVault.convertToAssets(oneShare * HWM_SCALE);
        assertLt(resetRate, _hwm(), "precondition: price below the HWM");

        vm.prank(alpha);
        feeManager.updateHighWaterMarkPerformanceFee();

        assertEq(_hwm(), resetRate, "owner reset: HWM = convertToAssets(10 ** decimals * 1e12)");
        assertEq(plasmaVault.balanceOf(performanceFeeAccount), feeSharesAfterGain, "owner reset mints nothing");

        uint256 gain = plasmaVault.totalAssets() / 1000;
        asset.mint(address(plasmaVault), gain);
        _crystallize();

        assertApproxEqRel(
            plasmaVault.convertToAssets(plasmaVault.balanceOf(performanceFeeAccount) - feeSharesAfterGain),
            (gain * PERFORMANCE_FEE) / 10000,
            1e14,
            "after the reset only the new gain is charged (20%)"
        );
    }

    /// @dev Interval lowering stores the current rate in the same scale, and the next fee is charged only on the gain
    ///      above the lowered HWM
    function testShouldLowerHwmInRateScale_whenUpdateIntervalPassed() public {
        _deployVault(6, 0);
        _depositAll();
        feeManager.updateIntervalHighWaterMarkPerformanceFee(1 days);

        asset.mint(address(plasmaVault), userDeposit / 10);
        _crystallize();
        uint256 hwmAfterGain = _hwm();
        uint256 feeSharesAfterGain = plasmaVault.balanceOf(performanceFeeAccount);

        uint256 loss = plasmaVault.totalAssets() / 2;
        vm.prank(address(plasmaVault));
        asset.transfer(address(0xdead), loss);
        uint256 lowRate = plasmaVault.convertToAssets(oneShare * HWM_SCALE);
        assertLt(lowRate, hwmAfterGain, "precondition: price below the HWM");

        vm.warp(block.timestamp + 1 days);
        _crystallize();
        assertEq(_hwm(), lowRate, "interval passed: HWM lowered to the current rate in the 1e12 scale");

        uint256 gain = plasmaVault.totalAssets() / 1000;
        asset.mint(address(plasmaVault), gain);
        _crystallize();

        uint256 newFeeShares = plasmaVault.balanceOf(performanceFeeAccount) - feeSharesAfterGain;
        assertApproxEqRel(
            plasmaVault.convertToAssets(newFeeShares),
            (gain * PERFORMANCE_FEE) / 10000,
            1e14,
            "after the lowering only the gain above the lowered HWM is charged (20%)"
        );
    }

    /// @dev The uint128 skip stays: with the 1e12 scale an 18-decimal rate exceeds uint128 above a share price of about
    ///      3.4e8 assets. The fee is skipped (no shares, HWM unchanged), withdraw, redeem and execute do not revert.
    function testShouldSkipPerformanceFee_whenScaledRateExceedsUint128() public {
        _deployVault(18, 0);
        _depositFor(user, 1e18);
        asset.mint(address(plasmaVault), 4e26);

        uint256 hwmBefore = _hwm();
        assertLe(plasmaVault.convertToAssets(oneShare), type(uint128).max, "precondition: unscaled rate fits uint128");
        assertGt(
            plasmaVault.convertToAssets(oneShare * HWM_SCALE),
            type(uint128).max,
            "precondition: scaled rate above"
        );

        _crystallize();
        assertEq(plasmaVault.balanceOf(performanceFeeAccount), 0, "execute: performance fee skipped");
        assertEq(_hwm(), hwmBefore, "execute: HWM unchanged");

        uint256 shares = plasmaVault.balanceOf(user) / 2;
        uint256 expectedAssets = plasmaVault.previewRedeem(shares);
        vm.prank(user);
        assertEq(plasmaVault.redeem(shares, user, user), expectedAssets, "redeem pays the preview");

        uint256 assets = plasmaVault.maxWithdraw(user) / 2;
        vm.prank(user);
        plasmaVault.withdraw(assets, user, user);

        assertEq(plasmaVault.balanceOf(performanceFeeAccount), 0, "withdraw/redeem: performance fee skipped");
        assertEq(_hwm(), hwmBefore, "withdraw/redeem: HWM unchanged");
    }

    // ---------------------------------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------------------------------

    /// @dev `steps_` gains of 0.1 ppm of the total assets, each followed by a redeem of `pokeShares` by the poker
    /// @return effectiveFeeBps fee paid by the depositor in bps of its gross gain
    /// @return totalGain sum of the gains
    /// @return feeValue value of the performance fee account at the end
    function _runRedeemSteps(
        uint256 steps_
    ) internal returns (uint256 effectiveFeeBps, uint256 totalGain, uint256 feeValue) {
        uint256 userShares = plasmaVault.balanceOf(user);
        uint256 userValueBefore = plasmaVault.convertToAssets(userShares);
        uint256 userGrossGain;

        for (uint256 i; i < steps_; ++i) {
            uint256 gain = plasmaVault.totalAssets() / TENTH_PPM_DIVISOR;
            userGrossGain += (gain * userShares) / plasmaVault.totalSupply();
            totalGain += gain;
            asset.mint(address(plasmaVault), gain);
            vm.prank(poker);
            plasmaVault.redeem(pokeShares, poker, poker);
        }

        uint256 userNetGain = plasmaVault.convertToAssets(userShares) - userValueBefore;
        effectiveFeeBps = ((userGrossGain - userNetGain) * 10000) / userGrossGain;
        feeValue = plasmaVault.convertToAssets(plasmaVault.balanceOf(performanceFeeAccount));
    }

    function _hwm() internal view returns (uint256) {
        return feeManager.getPlasmaVaultHighWaterMarkPerformanceFee().highWaterMark;
    }

    function _crystallize() internal {
        vm.prank(alpha);
        plasmaVault.execute(new FuseAction[](0));
    }

    /// @dev 1,000,000 asset units by the depositor and 2,000 by the poker, who redeems one asset unit worth of
    ///      shares per step
    function _depositAll() internal {
        _depositFor(user, userDeposit);
        _depositFor(poker, userDeposit / 500);
        pokeShares = oneShare;
    }

    function _depositFor(address account_, uint256 amount_) internal {
        asset.mint(account_, amount_);
        vm.startPrank(account_);
        asset.approve(address(plasmaVault), type(uint256).max);
        plasmaVault.deposit(amount_, account_);
        vm.stopPrank();
    }

    function _deployVault(uint8 assetDecimals_, uint256 managementFee_) internal {
        asset = new MockERC20Decimals("Mock Asset", "mA", assetDecimals_);
        userDeposit = 1_000_000 * 10 ** assetDecimals_;

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

        accessManager = _createAccessManager();
        withdrawManager = new WithdrawManager(address(accessManager));

        plasmaVault = PlasmaVaultCloneLib.newPlasmaVault();
        plasmaVault.proxyInitialize(
            PlasmaVaultInitData(
                "IPOR Fusion mA",
                "ipfmA",
                address(asset),
                address(priceOracleMiddlewareProxy),
                FeeConfig({
                    iporDaoManagementFee: managementFee_,
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
        oneShare = 10 ** uint256(plasmaVault.decimals());
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
