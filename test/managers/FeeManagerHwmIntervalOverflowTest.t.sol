// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {FeeManager, FeeManagerInitData} from "../../contracts/managers/fee/FeeManager.sol";
import {RecipientFee} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {HighWaterMarkPerformanceFeeStorage} from "../../contracts/managers/fee/FeeManagerStorageLib.sol";

/// @title FeeManager HWM update interval sum (IL-9636, Olympix L05)
/// @notice `lastUpdate + updateInterval` was a checked uint32 sum, so a large interval made
///         calculateAndUpdatePerformanceFee panic whenever the rate was at or below the HWM, which blocks the vault
///         operations that call it. The sum is now done in uint256: a not yet elapsed interval skips the update.
contract FeeManagerHwmIntervalOverflowTest is Test {
    address public plasmaVault = address(0xBEEF);
    uint256 public constant START = 1_700_000_000;
    uint256 public constant RATE = 1_000_000 * 1e12;
    uint256 public constant PERFORMANCE_FEE = 2000;

    FeeManager public feeManager;

    function setUp() public {
        vm.warp(START);
        IporFusionAccessManager accessManager = new IporFusionAccessManager(address(this), 0);
        feeManager = new FeeManager(
            FeeManagerInitData({
                initialAuthority: address(accessManager),
                plasmaVault: plasmaVault,
                iporDaoManagementFee: 0,
                iporDaoPerformanceFee: 0,
                iporDaoFeeRecipientAddress: address(0xDA0),
                recipientManagementFees: new RecipientFee[](0),
                recipientPerformanceFees: new RecipientFee[](0)
            })
        );

        // first call stores the HWM and the lastUpdate timestamp
        _calculate(RATE);
    }

    function testShouldNotRevertWhenIntervalSumExceedsUint32AndRateIsBelowHwm() public {
        feeManager.updateIntervalHighWaterMarkPerformanceFee(type(uint32).max);
        vm.warp(START + 365 days);

        (address recipient, uint256 feeShares) = _calculate(RATE - 1);

        assertEq(recipient, address(0), "no recipient");
        assertEq(feeShares, 0, "no fee");
        HighWaterMarkPerformanceFeeStorage memory hwm = feeManager.getPlasmaVaultHighWaterMarkPerformanceFee();
        assertEq(hwm.highWaterMark, RATE, "HWM not lowered, the interval has not elapsed");
        assertEq(hwm.lastUpdate, START, "lastUpdate unchanged");
    }

    function testShouldNotRevertWhenIntervalSumExceedsUint32AndRateEqualsHwm() public {
        feeManager.updateIntervalHighWaterMarkPerformanceFee(type(uint32).max - 1);
        vm.warp(START + 1);

        (address recipient, uint256 feeShares) = _calculate(RATE);

        assertEq(recipient, address(0), "no recipient");
        assertEq(feeShares, 0, "no fee");
        assertEq(feeManager.getPlasmaVaultHighWaterMarkPerformanceFee().highWaterMark, RATE, "HWM unchanged");
    }

    function testShouldStillLowerHwmWhenIntervalElapsed() public {
        feeManager.updateIntervalHighWaterMarkPerformanceFee(1 days);
        vm.warp(START + 1 days);

        _calculate(RATE / 2);

        HighWaterMarkPerformanceFeeStorage memory hwm = feeManager.getPlasmaVaultHighWaterMarkPerformanceFee();
        assertEq(hwm.highWaterMark, RATE / 2, "HWM lowered after the interval");
        assertEq(hwm.lastUpdate, START + 1 days, "lastUpdate refreshed");
    }

    function testShouldNotLowerHwmBeforeIntervalElapsed() public {
        feeManager.updateIntervalHighWaterMarkPerformanceFee(1 days);
        vm.warp(START + 1 days - 1);

        _calculate(RATE / 2);

        assertEq(feeManager.getPlasmaVaultHighWaterMarkPerformanceFee().highWaterMark, RATE, "HWM kept");
    }

    function testShouldNotLowerHwmWhenIntervalIsZero() public {
        vm.warp(START + 3650 days);

        _calculate(RATE / 2);

        assertEq(feeManager.getPlasmaVaultHighWaterMarkPerformanceFee().highWaterMark, RATE, "zero disables lowering");
    }

    function _calculate(uint256 rate_) private returns (address recipient, uint256 feeShares) {
        vm.prank(plasmaVault);
        return feeManager.calculateAndUpdatePerformanceFee(uint128(rate_), 1e18, PERFORMANCE_FEE, 6);
    }
}
