// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {PlasmaVaultMockMarketsTestBase} from "./PlasmaVaultMockMarketsTestBase.sol";
import {FuseAction} from "../../contracts/vaults/PlasmaVault.sol";

/// @title OlympixPerformanceFeeNetOfManagementFeeTest
/// @notice Olympix scan 2026-11-06, finding 5.1.24 (IL-9614, M24), fixed by PR #61 (IL-8870): `execute` and
///         `updateMarketsBalances` crystallized the performance fee on a rate that still counted the unminted
///         management fee as depositor value, so depositors paid the performance fee on assets that belong to the
///         management fee recipients. `withdraw` and `redeem` realize the management fee first, so the same gain was
///         priced net or gross depending on the path.
/// @dev The proof is economic: the value of the depositor and of the performance fee recipient, in asset units, must
///      not depend on whether the management fee was realized before the performance fee crystallized. No assertion
///      reads the high-water mark, so the file does not depend on the HWM unit (1e12 scale after IL-9590 T32) and
///      is valid on the audited commit 8692fbe5 (fails) and on the tree that contains PR #61 (passes).
contract OlympixPerformanceFeeNetOfManagementFeeTest is PlasmaVaultMockMarketsTestBase {
    /// @dev 20% performance fee and 2% per year management fee (2 decimals, 10000 = 100%)
    uint256 internal constant PERFORMANCE_FEE = 2000;
    uint256 internal constant MANAGEMENT_FEE = 200;
    uint256 internal constant DEPOSIT = 1_000_000e6;
    uint256 internal constant GAIN = 100_000e6;
    /// @dev six quiet months accrue 1% of the assets as an unrealized management fee (10_000e6)
    uint256 internal constant QUIET_PERIOD = 365 days / 2;
    /// @dev the finding costs the depositor performanceFee * unrealizedFee = 20% * 10_000e6 = 2_000e6; 1e6 is 1 USDC
    uint256 internal constant TOLERANCE = 1e6;

    function _performanceFee() internal pure override returns (uint256) {
        return PERFORMANCE_FEE;
    }

    function _managementFee() internal pure override returns (uint256) {
        return MANAGEMENT_FEE;
    }

    function testShouldNotChargeDepositorOnUnrealizedManagementFee_whenExecuteCrystallizes() public {
        _prepareGainWithPendingManagementFee();
        _assertSamePerformanceFeeOutcome(true);
    }

    function testShouldNotChargeDepositorOnUnrealizedManagementFee_whenUpdateMarketsBalancesCrystallizes() public {
        _prepareGainWithPendingManagementFee();
        _assertSamePerformanceFeeOutcome(false);
    }

    /// @dev The performance fee itself must still be charged (the equality above is not satisfied by charging nothing)
    function testShouldStillChargePerformanceFeeOnTheNetGain_whenExecuteCrystallizes() public {
        _prepareGainWithPendingManagementFee();

        _crystallize(true);
        _realizeManagementFee();

        uint256 feeValue = plasmaVault.maxWithdraw(_feeAccount());
        /// @dev the net gain is GAIN minus the management fee, the fee is 20% of it: well above 15_000e6, below 20_000e6
        assertGt(feeValue, 15_000e6, "performance fee charged on the net gain");
        assertLt(feeValue, (GAIN * PERFORMANCE_FEE) / 10_000, "but not on the gross gain");
    }

    function _assertSamePerformanceFeeOutcome(bool viaExecute_) internal {
        assertGt(plasmaVault.getUnrealizedManagementFee(), 0, "premise: the management fee is pending");
        uint256 snap = vm.snapshotState();

        // path A: the performance fee crystallizes while the management fee is only accrued
        _crystallize(viaExecute_);
        _realizeManagementFee();
        uint256 depositorAccrued = plasmaVault.maxWithdraw(user);
        uint256 feeAccrued = plasmaVault.maxWithdraw(_feeAccount());

        vm.revertToState(snap);

        // path B (reference): the management fee is realized first, as withdraw and redeem do
        _realizeManagementFee();
        _crystallize(viaExecute_);
        uint256 depositorRealized = plasmaVault.maxWithdraw(user);
        uint256 feeRealized = plasmaVault.maxWithdraw(_feeAccount());

        assertGt(feeRealized, 0, "premise: performance fee charged on the reference path");
        assertGt(feeAccrued, 0, "premise: performance fee charged on the accrued path");
        assertApproxEqAbs(
            depositorAccrued,
            depositorRealized,
            TOLERANCE,
            "depositor value depends on whether the management fee was realized first (M24)"
        );
        /// @dev On path A the performance fee shares already exist when the management fee is realized and bear their
        ///      pro-rata part of it (about 1% of the performance fee here), so the two values are not equal. The fee
        ///      recipient must not get more than on the reference path (the gross rate overcharged the depositor in
        ///      its favour, by about 10% here), and not less than the dilution explains.
        assertLe(feeAccrued, feeRealized + TOLERANCE, "performance fee charged on the gross rate (M24)");
        assertGe(feeAccrued, (feeRealized * 98) / 100, "performance fee lower than the dilution explains");
    }

    function _prepareGainWithPendingManagementFee() internal {
        _deposit(user, DEPOSIT);
        vm.warp(block.timestamp + QUIET_PERIOD);
        /// @dev unbooked-by-shares gain: assets sitting idle in the vault raise the share rate
        _donate(GAIN);
    }

    function _crystallize(bool viaExecute_) internal {
        if (viaExecute_) {
            vm.prank(alpha);
            plasmaVault.execute(new FuseAction[](0));
        } else {
            uint256[] memory markets = new uint256[](1);
            markets[0] = MARKET_A;
            vm.prank(updater);
            plasmaVault.updateMarketsBalances(markets);
        }
    }

    /// @dev Any deposit realizes the pending management fee on every version of the vault
    function _realizeManagementFee() internal {
        _deposit(other, 1e6);
    }
}
