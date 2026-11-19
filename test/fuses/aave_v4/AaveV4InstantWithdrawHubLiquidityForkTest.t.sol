// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";

import {FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {InstantWithdrawalFusesParamsStruct} from "../../../contracts/libraries/PlasmaVaultLib.sol";
import {AaveV4SubstrateLib} from "../../../contracts/fuses/aave_v4/AaveV4SubstrateLib.sol";
import {AaveV4SupplyFuse} from "../../../contracts/fuses/aave_v4/AaveV4SupplyFuse.sol";
import {IAaveV4Spoke} from "../../../contracts/fuses/aave_v4/ext/IAaveV4Spoke.sol";
import {IAaveV4Hub} from "../../../contracts/fuses/aave_v4/ext/IAaveV4Hub.sol";
import {AaveV4ForkTestBase} from "./AaveV4ForkTestBase.sol";

/// @title AaveV4InstantWithdrawHubLiquidityForkTest
/// @notice IL-9559: AaveV4SupplyFuse caps the instant withdraw at the Hub's liquidity. The Hub's `liquidity` is a
///         bookkeeping field, so it is lowered by a real borrow from another account, not by moving tokens.
///         Two entries go through the real `withdrawFromMarkets` loop: Bluechip USDC (Prime Hub, reserve 4) first,
///         Main USDC (Core Hub, reserve 7) second.
contract AaveV4InstantWithdrawHubLiquidityForkTest is AaveV4ForkTestBase {
    uint256 private constant PRIME_SUPPLY = 40_000e6;
    uint256 private constant CORE_SUPPLY = 40_000e6;
    uint256 private constant PRIME_LIQUIDITY_LEFT = 10_000e6;

    address private borrower = address(0xB0B);

    function _defaultGrants() internal pure override returns (bytes32[] memory grants) {
        grants = new bytes32[](2);
        grants[0] = AaveV4SubstrateLib.encodeReserve(BLUECHIP_SPOKE, BLUECHIP_USDC_PRIME, false, false);
        grants[1] = AaveV4SubstrateLib.encodeReserve(MAIN_SPOKE, MAIN_USDC, false, false);
    }

    function testShouldPayHubLiquidityFromFirstEntryAndRestFromSecond() public {
        // given - 40k in each reserve, 20k idle; the Prime Hub is left with 10k liquidity
        _supplyBothAndConfigure();
        _drainPrimeHubTo(PRIME_LIQUIDITY_LEFT);
        assertEq(_primeLiquidity(), PRIME_LIQUIDITY_LEFT, "Prime Hub liquidity lowered by the borrow");
        uint256 primeBefore = _supplied(BLUECHIP_SPOKE, BLUECHIP_USDC_PRIME);
        uint256 coreBefore = _supplied(MAIN_SPOKE, MAIN_USDC);
        uint256 userBefore = IERC20(USDC).balanceOf(user);

        // when - 68k: 20k idle + 48k from the entries; no single entry can cover the 48k residual
        vm.prank(user);
        plasmaVault.withdraw(68_000e6, user, user);

        // then - the first entry pays its Hub liquidity, the second the rest
        assertEq(IERC20(USDC).balanceOf(user) - userBefore, 68_000e6, "user received USDC");
        assertApproxEqAbs(
            primeBefore - _supplied(BLUECHIP_SPOKE, BLUECHIP_USDC_PRIME),
            PRIME_LIQUIDITY_LEFT,
            1e3,
            "first entry paid its Hub liquidity"
        );
        assertGt(coreBefore - _supplied(MAIN_SPOKE, MAIN_USDC), 30_000e6, "second entry paid the rest");
    }

    function testShouldSkipEntryWithoutSpokeCallWhenHubLiquidityIsZero() public {
        // given - the Prime Hub is borrowed down to 0
        _supplyBothAndConfigure();
        _drainPrimeHubTo(0);
        assertEq(_primeLiquidity(), 0, "Prime Hub liquidity is zero");
        uint256 primeBefore = _supplied(BLUECHIP_SPOKE, BLUECHIP_USDC_PRIME);

        // when - selector-level match: any Spoke withdraw on the drained reserve's Spoke, whatever the amount, fails it
        vm.expectCall(BLUECHIP_SPOKE, abi.encodeWithSignature("withdraw(uint256,uint256,address)"), 0);
        vm.recordLogs();
        vm.prank(user);
        plasmaVault.withdraw(50_000e6, user, user);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // then - the first entry is skipped: no ExitFailed and no Exit event from the fuse, the second pays
        bytes32 exitFailed = AaveV4SupplyFuse.AaveV4SupplyFuseExitFailed.selector;
        bytes32 exitOk = AaveV4SupplyFuse.AaveV4SupplyFuseExit.selector;
        uint256 exits;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(plasmaVault) && logs[i].topics.length > 0) {
                assertTrue(logs[i].topics[0] != exitFailed, "no ExitFailed");
            }
            if (logs[i].topics.length > 0 && logs[i].topics[0] == exitOk) {
                ++exits;
            }
        }
        assertEq(exits, 1, "only the second entry exited");
        assertEq(_supplied(BLUECHIP_SPOKE, BLUECHIP_USDC_PRIME), primeBefore, "Prime position untouched");
    }

    function testShouldNotCapAlphaExitAtHubLiquidity() public {
        // given
        _supplyBothAndConfigure();
        _drainPrimeHubTo(PRIME_LIQUIDITY_LEFT);
        uint256 primeBefore = _supplied(BLUECHIP_SPOKE, BLUECHIP_USDC_PRIME);

        // when/then - the ALPHA exit is uncapped, so the full position amount reaches the Spoke
        //             (not shrunk to the Hub liquidity) and a request above the liquidity still reverts
        vm.expectCall(
            BLUECHIP_SPOKE,
            abi.encodeWithSignature(
                "withdraw(uint256,uint256,address)",
                BLUECHIP_USDC_PRIME,
                primeBefore,
                address(plasmaVault)
            ),
            1
        );
        // the Hub rejects it with InsufficientLiquidity(liquidity), observed in a -vvvv run
        vm.expectRevert(abi.encodeWithSignature("InsufficientLiquidity(uint256)", PRIME_LIQUIDITY_LEFT));
        _executeOne(_withdrawAction(BLUECHIP_SPOKE, USDC, BLUECHIP_USDC_PRIME, PRIME_SUPPLY, 0));
        assertEq(_supplied(BLUECHIP_SPOKE, BLUECHIP_USDC_PRIME), primeBefore, "position untouched");

        // and an exit within the liquidity works
        _executeOne(_withdrawAction(BLUECHIP_SPOKE, USDC, BLUECHIP_USDC_PRIME, PRIME_LIQUIDITY_LEFT, 0));
        assertApproxEqAbs(primeBefore - _supplied(BLUECHIP_SPOKE, BLUECHIP_USDC_PRIME), PRIME_LIQUIDITY_LEFT, 1e3);
    }

    // ============ Helpers ============

    function _supplyBothAndConfigure() private {
        FuseAction[] memory actions = new FuseAction[](2);
        actions[0] = _supplyAction(BLUECHIP_SPOKE, USDC, BLUECHIP_USDC_PRIME, PRIME_SUPPLY, 0);
        actions[1] = _supplyAction(MAIN_SPOKE, USDC, MAIN_USDC, CORE_SUPPLY, 0);
        _execute(actions);

        InstantWithdrawalFusesParamsStruct[] memory fuses = new InstantWithdrawalFusesParamsStruct[](2);
        fuses[0] = InstantWithdrawalFusesParamsStruct({
            fuse: supplyFuse,
            params: _instantParams(BLUECHIP_SPOKE, BLUECHIP_USDC_PRIME)
        });
        fuses[1] = InstantWithdrawalFusesParamsStruct({
            fuse: supplyFuse,
            params: _instantParams(MAIN_SPOKE, MAIN_USDC)
        });
        vm.prank(atomist);
        PlasmaVaultGovernance(address(plasmaVault)).configureInstantWithdrawalFuses(fuses);
    }

    function _instantParams(address spoke_, uint256 reserveId_) private pure returns (bytes32[] memory params) {
        params = new bytes32[](5);
        params[1] = PlasmaVaultConfigLib.addressToBytes32(USDC);
        params[2] = PlasmaVaultConfigLib.addressToBytes32(spoke_);
        params[3] = bytes32(reserveId_);
    }

    /// @dev An unrelated account posts WETH collateral on the Bluechip spoke and borrows USDC (Prime Hub) until
    ///      `liquidityLeft_` remains in the Hub
    function _drainPrimeHubTo(uint256 liquidityLeft_) private {
        uint256 toBorrow = _primeLiquidity() - liquidityLeft_;
        uint256 collateral = 3_000e18;
        deal(WETH, borrower, collateral);
        vm.startPrank(borrower);
        IERC20(WETH).approve(BLUECHIP_SPOKE, collateral);
        IAaveV4Spoke(BLUECHIP_SPOKE).supply(BLUECHIP_WETH, collateral, borrower);
        IAaveV4Spoke(BLUECHIP_SPOKE).setUsingAsCollateral(BLUECHIP_WETH, true, borrower);
        IAaveV4Spoke(BLUECHIP_SPOKE).borrow(BLUECHIP_USDC_PRIME, toBorrow, borrower);
        vm.stopPrank();
    }

    function _primeLiquidity() private view returns (uint256) {
        return
            IAaveV4Hub(PRIME_HUB).getAssetLiquidity(
                IAaveV4Spoke(BLUECHIP_SPOKE).getReserve(BLUECHIP_USDC_PRIME).assetId
            );
    }
}
