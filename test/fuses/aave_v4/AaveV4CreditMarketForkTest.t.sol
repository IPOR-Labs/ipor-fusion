// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {AaveV4SubstrateLib} from "../../../contracts/fuses/aave_v4/AaveV4SubstrateLib.sol";
import {AaveV4SupplyFuse} from "../../../contracts/fuses/aave_v4/AaveV4SupplyFuse.sol";
import {AaveV4BorrowFuse} from "../../../contracts/fuses/aave_v4/AaveV4BorrowFuse.sol";
import {AaveV4CollateralFuse} from "../../../contracts/fuses/aave_v4/AaveV4CollateralFuse.sol";
import {IAaveV4Spoke} from "../../../contracts/fuses/aave_v4/ext/IAaveV4Spoke.sol";
import {AaveV4ForkTestBase} from "./AaveV4ForkTestBase.sol";

/// @title AaveV4CreditMarketForkTest
/// @notice End-to-end credit market flow against the live Aave V4 Bluechip spoke on Ethereum mainnet:
///         supply WETH -> enable collateral -> borrow USDC -> repay -> disable collateral -> withdraw,
///         plus the substrate guarantees (reserve-level grants, duplicate-asset disambiguation, spoke isolation).
contract AaveV4CreditMarketForkTest is AaveV4ForkTestBase {
    uint256 private constant WETH_SUPPLY = 10e18;
    uint256 private constant USDC_BORROW = 10_000e6;

    // ============ Happy path ============

    function testShouldSupplyWethToBluechipSpoke() public {
        // given
        uint256 totalAssetsBefore = plasmaVault.totalAssets();
        uint256 wethBefore = IERC20(WETH).balanceOf(address(plasmaVault));

        // when
        _executeOne(_supplyAction(BLUECHIP_SPOKE, WETH, BLUECHIP_WETH, WETH_SUPPLY, 0));

        // then
        assertApproxEqAbs(_supplied(BLUECHIP_SPOKE, BLUECHIP_WETH), WETH_SUPPLY, 1, "supplied WETH");
        assertEq(wethBefore - IERC20(WETH).balanceOf(address(plasmaVault)), WETH_SUPPLY, "vault WETH moved to Aave");

        (bool usingAsCollateral, bool borrowing) = _status(BLUECHIP_SPOKE, BLUECHIP_WETH);
        assertFalse(usingAsCollateral, "supply must not enable collateral in Aave V4");
        assertFalse(borrowing);

        assertGt(_aaveMarketBalance(), 0, "AAVE_V4 market balance tracked");
        assertApproxEqRel(
            plasmaVault.totalAssets(),
            totalAssetsBefore,
            NAV_TOLERANCE,
            "NAV unchanged by moving WETH into Aave"
        );
    }

    function testShouldRevertBorrowWhenCollateralNotEnabled() public {
        // given - supplied but collateral not enabled
        _executeOne(_supplyAction(BLUECHIP_SPOKE, WETH, BLUECHIP_WETH, WETH_SUPPLY, 0));

        // when/then
        vm.expectRevert(IAaveV4Spoke.HealthFactorBelowThreshold.selector);
        _executeOne(_borrowAction(BLUECHIP_SPOKE, USDC, BLUECHIP_USDC_PRIME, USDC_BORROW, 0));
    }

    function testShouldEnableCollateralAndBorrowPrimeUsdc() public {
        // given
        uint256 totalAssetsBefore = plasmaVault.totalAssets();
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(plasmaVault));

        // when
        _openPosition(WETH_SUPPLY, USDC_BORROW);

        // then
        assertEq(IERC20(USDC).balanceOf(address(plasmaVault)) - usdcBefore, USDC_BORROW, "borrowed USDC received");
        assertApproxEqAbs(_debt(BLUECHIP_SPOKE, BLUECHIP_USDC_PRIME), USDC_BORROW, 1, "debt");
        assertEq(_debt(BLUECHIP_SPOKE, BLUECHIP_USDC_CORE), 0, "no debt on the Core-hub USDC reserve");

        (bool wethCollateral, bool wethBorrowing) = _status(BLUECHIP_SPOKE, BLUECHIP_WETH);
        assertTrue(wethCollateral);
        assertFalse(wethBorrowing);

        (bool usdcCollateral, bool usdcBorrowing) = _status(BLUECHIP_SPOKE, BLUECHIP_USDC_PRIME);
        assertFalse(usdcCollateral);
        assertTrue(usdcBorrowing);

        IAaveV4Spoke.UserAccountData memory data = IAaveV4Spoke(BLUECHIP_SPOKE).getUserAccountData(
            address(plasmaVault)
        );
        assertGt(data.healthFactor, 1e18, "healthy");
        assertEq(data.borrowCount, 1);
        assertEq(data.activeCollateralCount, 1);

        assertApproxEqRel(plasmaVault.totalAssets(), totalAssetsBefore, NAV_TOLERANCE, "NAV unchanged by borrowing");
    }

    function testShouldAccrueDebtAndReflectInMarketBalance() public {
        // given
        _openPosition(WETH_SUPPLY, USDC_BORROW);
        uint256 debtBefore = _debt(BLUECHIP_SPOKE, BLUECHIP_USDC_PRIME);
        uint256 suppliedBefore = _supplied(BLUECHIP_SPOKE, BLUECHIP_WETH);
        uint256 marketBefore = _aaveMarketBalance();

        // when - one day of interest
        vm.warp(block.timestamp + 1 days);
        uint256 debtAfter = _debt(BLUECHIP_SPOKE, BLUECHIP_USDC_PRIME);
        uint256 suppliedAfter = _supplied(BLUECHIP_SPOKE, BLUECHIP_WETH);
        _updateBalances();

        // then
        assertGt(debtAfter, debtBefore, "debt accrues");
        assertGe(suppliedAfter, suppliedBefore, "supply never shrinks");

        int256 expectedDeltaUsd = int256(_usdValueWad(WETH, suppliedAfter - suppliedBefore)) -
            int256(_usdValueWad(USDC, debtAfter - debtBefore));
        int256 expectedMarketAfter = int256(marketBefore) +
            (
                expectedDeltaUsd >= 0
                    ? int256(_usdWadToUsdc(uint256(expectedDeltaUsd)))
                    : -int256(_usdWadToUsdc(uint256(-expectedDeltaUsd)))
            );

        assertApproxEqAbs(_aaveMarketBalance(), uint256(expectedMarketAfter), 1e4, "market balance follows accrual");
    }

    function testShouldRepayFullDebtWithMaxAmount() public {
        // given
        _openPosition(WETH_SUPPLY, USDC_BORROW);
        vm.warp(block.timestamp + 1 hours);
        uint256 debt = _debt(BLUECHIP_SPOKE, BLUECHIP_USDC_PRIME);
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(plasmaVault));

        // when
        _executeOne(_repayAction(BLUECHIP_SPOKE, USDC, BLUECHIP_USDC_PRIME, type(uint256).max, 0));

        // then
        assertEq(_debt(BLUECHIP_SPOKE, BLUECHIP_USDC_PRIME), 0, "debt cleared");
        (, bool borrowing) = _status(BLUECHIP_SPOKE, BLUECHIP_USDC_PRIME);
        assertFalse(borrowing);
        assertApproxEqAbs(usdcBefore - IERC20(USDC).balanceOf(address(plasmaVault)), debt, 1, "paid drawn + premium");
    }

    function testShouldRevertDisableCollateralWhileDebtOutstanding() public {
        // given
        _openPosition(WETH_SUPPLY, USDC_BORROW);

        // when/then
        vm.expectRevert(IAaveV4Spoke.HealthFactorBelowThreshold.selector);
        _executeOne(_disableCollateralAction(BLUECHIP_SPOKE, BLUECHIP_WETH));
    }

    function testShouldUnwindPosition() public {
        // given
        uint256 totalAssetsBefore = plasmaVault.totalAssets();
        uint256 wethBefore = IERC20(WETH).balanceOf(address(plasmaVault));
        _openPosition(WETH_SUPPLY, USDC_BORROW);

        // when
        FuseAction[] memory actions = new FuseAction[](3);
        actions[0] = _repayAction(BLUECHIP_SPOKE, USDC, BLUECHIP_USDC_PRIME, type(uint256).max, 0);
        actions[1] = _disableCollateralAction(BLUECHIP_SPOKE, BLUECHIP_WETH);
        actions[2] = _withdrawAction(BLUECHIP_SPOKE, WETH, BLUECHIP_WETH, type(uint256).max, 0);
        _execute(actions);

        // then
        assertEq(_debt(BLUECHIP_SPOKE, BLUECHIP_USDC_PRIME), 0);
        assertLe(_supplied(BLUECHIP_SPOKE, BLUECHIP_WETH), 1e9, "position closed (dust only)");
        (bool usingAsCollateral, bool borrowing) = _status(BLUECHIP_SPOKE, BLUECHIP_WETH);
        assertFalse(usingAsCollateral);
        assertFalse(borrowing);
        assertApproxEqAbs(IERC20(WETH).balanceOf(address(plasmaVault)), wethBefore, 1e9, "WETH back in the vault");
        assertApproxEqRel(plasmaVault.totalAssets(), totalAssetsBefore, NAV_TOLERANCE, "NAV preserved");
        assertLe(_aaveMarketBalance(), _usdWadToUsdc(_usdValueWad(WETH, 1e9)), "AAVE_V4 market ~ empty");
    }

    function testShouldWithdrawPartOfCollateralWhileHealthy() public {
        // given
        _openPosition(WETH_SUPPLY, USDC_BORROW);

        // when - withdraw 1 WETH of 10 (HF stays ~1.8)
        _executeOne(_withdrawAction(BLUECHIP_SPOKE, WETH, BLUECHIP_WETH, 1e18, 0));

        // then
        assertApproxEqAbs(_supplied(BLUECHIP_SPOKE, BLUECHIP_WETH), 9e18, 1);
        assertGt(_healthFactor(BLUECHIP_SPOKE), 1e18);
    }

    function testShouldWithdrawFullPositionWhenAmountExceedsSupply() public {
        // given
        _executeOne(_supplyAction(BLUECHIP_SPOKE, WETH, BLUECHIP_WETH, WETH_SUPPLY, 0));
        uint256 wethBefore = IERC20(WETH).balanceOf(address(plasmaVault));

        // when
        _executeOne(_withdrawAction(BLUECHIP_SPOKE, WETH, BLUECHIP_WETH, 100e18, 0));

        // then
        assertLe(_supplied(BLUECHIP_SPOKE, BLUECHIP_WETH), 1e9);
        assertApproxEqAbs(IERC20(WETH).balanceOf(address(plasmaVault)) - wethBefore, WETH_SUPPLY, 1e9);
    }

    // ============ Substrate guarantees ============

    function testShouldRevertBorrowOnCoreUsdcWhenOnlyPrimeUsdcGranted() public {
        // given - USDC is listed twice on Bluechip; only reserve 4 (Prime hub) is granted
        _executeOne(_supplyAction(BLUECHIP_SPOKE, WETH, BLUECHIP_WETH, WETH_SUPPLY, 0));
        _executeOne(_enableCollateralAction(BLUECHIP_SPOKE, BLUECHIP_WETH));

        // when/then - reserve 7 (Core hub) is rejected although it is the same underlying
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4BorrowFuse.AaveV4BorrowFuseUnsupportedSubstrate.selector,
                "enter",
                BLUECHIP_SPOKE,
                BLUECHIP_USDC_CORE
            )
        );
        _executeOne(_borrowAction(BLUECHIP_SPOKE, USDC, BLUECHIP_USDC_CORE, USDC_BORROW, 0));
    }

    function testShouldBorrowCoreUsdcWhenOnlyCoreUsdcGranted() public {
        // given - the mirror configuration: only reserve 7 (Core hub) borrowable
        bytes32[] memory grants = new bytes32[](2);
        grants[0] = AaveV4SubstrateLib.encodeReserve(BLUECHIP_SPOKE, BLUECHIP_WETH, true, false);
        grants[1] = AaveV4SubstrateLib.encodeReserve(BLUECHIP_SPOKE, BLUECHIP_USDC_CORE, false, true);
        _grantReserves(grants);

        _executeOne(_supplyAction(BLUECHIP_SPOKE, WETH, BLUECHIP_WETH, WETH_SUPPLY, 0));
        _executeOne(_enableCollateralAction(BLUECHIP_SPOKE, BLUECHIP_WETH));

        // when/then - Prime reserve rejected
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4BorrowFuse.AaveV4BorrowFuseUnsupportedSubstrate.selector,
                "enter",
                BLUECHIP_SPOKE,
                BLUECHIP_USDC_PRIME
            )
        );
        _executeOne(_borrowAction(BLUECHIP_SPOKE, USDC, BLUECHIP_USDC_PRIME, USDC_BORROW, 0));

        // and Core reserve works
        _executeOne(_borrowAction(BLUECHIP_SPOKE, USDC, BLUECHIP_USDC_CORE, USDC_BORROW, 0));
        assertApproxEqAbs(_debt(BLUECHIP_SPOKE, BLUECHIP_USDC_CORE), USDC_BORROW, 1);
        assertEq(_debt(BLUECHIP_SPOKE, BLUECHIP_USDC_PRIME), 0);
    }

    function testShouldRevertSupplyOnMainSpokeWhenOnlyBluechipGranted() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4SupplyFuse.AaveV4SupplyFuseUnsupportedSubstrate.selector,
                "enter",
                MAIN_SPOKE,
                MAIN_WETH
            )
        );
        _executeOne(_supplyAction(MAIN_SPOKE, WETH, MAIN_WETH, WETH_SUPPLY, 0));
    }

    function testShouldSupplyOnMainSpokeWhenGranted() public {
        // given - grant WETH on the Main spoke too
        bytes32[] memory grants = new bytes32[](2);
        grants[0] = AaveV4SubstrateLib.encodeReserve(BLUECHIP_SPOKE, BLUECHIP_WETH, true, false);
        grants[1] = AaveV4SubstrateLib.encodeReserve(MAIN_SPOKE, MAIN_WETH, true, false);
        _grantReserves(grants);

        // when
        _executeOne(_supplyAction(MAIN_SPOKE, WETH, MAIN_WETH, WETH_SUPPLY, 0));

        // then
        assertApproxEqAbs(_supplied(MAIN_SPOKE, MAIN_WETH), WETH_SUPPLY, 1);
        assertEq(_supplied(BLUECHIP_SPOKE, BLUECHIP_WETH), 0);
    }

    function testShouldRevertEnableCollateralWhenSubstrateNotFlaggedCollateral() public {
        // given - WETH granted as plain supply
        bytes32[] memory grants = new bytes32[](2);
        grants[0] = AaveV4SubstrateLib.encodeReserve(BLUECHIP_SPOKE, BLUECHIP_WETH, false, false);
        grants[1] = AaveV4SubstrateLib.encodeReserve(BLUECHIP_SPOKE, BLUECHIP_USDC_PRIME, false, true);
        _grantReserves(grants);
        _executeOne(_supplyAction(BLUECHIP_SPOKE, WETH, BLUECHIP_WETH, WETH_SUPPLY, 0));

        // when/then
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4CollateralFuse.AaveV4CollateralFuseUnsupportedSubstrate.selector,
                "enter",
                BLUECHIP_SPOKE,
                BLUECHIP_WETH
            )
        );
        _executeOne(_enableCollateralAction(BLUECHIP_SPOKE, BLUECHIP_WETH));
    }

    function testShouldRevertBorrowWhenSubstrateNotFlaggedCanBorrow() public {
        // given - USDC granted as plain supply
        bytes32[] memory grants = new bytes32[](2);
        grants[0] = AaveV4SubstrateLib.encodeReserve(BLUECHIP_SPOKE, BLUECHIP_WETH, true, false);
        grants[1] = AaveV4SubstrateLib.encodeReserve(BLUECHIP_SPOKE, BLUECHIP_USDC_PRIME, false, false);
        _grantReserves(grants);
        _executeOne(_supplyAction(BLUECHIP_SPOKE, WETH, BLUECHIP_WETH, WETH_SUPPLY, 0));
        _executeOne(_enableCollateralAction(BLUECHIP_SPOKE, BLUECHIP_WETH));

        // when/then
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4BorrowFuse.AaveV4BorrowFuseUnsupportedSubstrate.selector,
                "enter",
                BLUECHIP_SPOKE,
                BLUECHIP_USDC_PRIME
            )
        );
        _executeOne(_borrowAction(BLUECHIP_SPOKE, USDC, BLUECHIP_USDC_PRIME, USDC_BORROW, 0));
    }

    function testShouldRepayAfterCanBorrowRevoked() public {
        // given - open position, then the atomist downgrades USDC to plain
        _openPosition(WETH_SUPPLY, USDC_BORROW);
        bytes32[] memory grants = new bytes32[](2);
        grants[0] = AaveV4SubstrateLib.encodeReserve(BLUECHIP_SPOKE, BLUECHIP_WETH, true, false);
        grants[1] = AaveV4SubstrateLib.encodeReserve(BLUECHIP_SPOKE, BLUECHIP_USDC_PRIME, false, false);
        _grantReserves(grants);

        // when - repaying must still work
        _executeOne(_repayAction(BLUECHIP_SPOKE, USDC, BLUECHIP_USDC_PRIME, type(uint256).max, 0));

        // then
        assertEq(_debt(BLUECHIP_SPOKE, BLUECHIP_USDC_PRIME), 0);
    }

    function testShouldRevertSupplyOnCoreUsdcReserveWithZeroAddCap() public {
        // given - reserve 7 (Core hub USDC) has addCap 0 on the Bluechip spoke; grant it as plain supply
        bytes32[] memory grants = new bytes32[](1);
        grants[0] = AaveV4SubstrateLib.encodeReserve(BLUECHIP_SPOKE, BLUECHIP_USDC_CORE, false, false);
        _grantReserves(grants);

        // when/then - the hub rejects the supply (cap), the fuse bubbles the revert
        vm.expectRevert();
        _executeOne(_supplyAction(BLUECHIP_SPOKE, USDC, BLUECHIP_USDC_CORE, 1_000e6, 0));
    }

    function testShouldRevertWhenAssetDoesNotMatchReserve() public {
        // given - reserve 4 is USDC, alpha passes WETH
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4BorrowFuse.AaveV4BorrowFuseReserveAssetMismatch.selector,
                BLUECHIP_USDC_PRIME,
                WETH,
                USDC
            )
        );
        _executeOne(_borrowAction(BLUECHIP_SPOKE, WETH, BLUECHIP_USDC_PRIME, 1e18, 0));
    }

    // ============ Transient storage path ============

    function testShouldExecuteSupplyAndCollateralViaTransientStorage() public {
        // given
        address[] memory fuses = new address[](2);
        fuses[0] = supplyFuse;
        fuses[1] = collateralFuse;

        bytes32[][] memory inputsByFuse = new bytes32[][](2);
        inputsByFuse[0] = new bytes32[](5);
        inputsByFuse[0][0] = bytes32(uint256(uint160(BLUECHIP_SPOKE)));
        inputsByFuse[0][1] = bytes32(uint256(uint160(WETH)));
        inputsByFuse[0][2] = bytes32(BLUECHIP_WETH);
        inputsByFuse[0][3] = bytes32(WETH_SUPPLY);
        inputsByFuse[0][4] = bytes32(0);
        inputsByFuse[1] = new bytes32[](2);
        inputsByFuse[1][0] = bytes32(uint256(uint160(BLUECHIP_SPOKE)));
        inputsByFuse[1][1] = bytes32(BLUECHIP_WETH);

        FuseAction[] memory actions = new FuseAction[](3);
        actions[0] = _setInputsAction(fuses, inputsByFuse);
        actions[1] = FuseAction({fuse: supplyFuse, data: abi.encodeWithSignature("enterTransient()")});
        actions[2] = FuseAction({fuse: collateralFuse, data: abi.encodeWithSignature("enterTransient()")});

        // when
        _execute(actions);

        // then
        assertApproxEqAbs(_supplied(BLUECHIP_SPOKE, BLUECHIP_WETH), WETH_SUPPLY, 1);
        (bool usingAsCollateral, ) = _status(BLUECHIP_SPOKE, BLUECHIP_WETH);
        assertTrue(usingAsCollateral);
    }
}
