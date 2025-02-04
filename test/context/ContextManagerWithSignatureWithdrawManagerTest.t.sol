// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ContextManagerInitSetup} from "./ContextManagerInitSetup.sol";
import {TestAddresses} from "../test_helpers/TestAddresses.sol";
import {IERC20} from "../../lib/forge-std/src/interfaces/IERC20.sol";
import {FeeManager} from "../../contracts/managers/fee/FeeManager.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {WithdrawRequestInfo} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {ContextDataWithSender} from "../../contracts/managers/context/ContextManager.sol";

contract ContextManagerWithSignatureWithdrawManagerTest is Test, ContextManagerInitSetup {
    // Test events
    event ContextCall(address indexed target, bytes data, bytes result);
    uint256 internal immutable _USER_2_PRIVATE_KEY =
        vm.deriveKey("test test test test test test test test test test test junk", 111);
    address internal immutable _USER_2 = vm.addr(_USER_2_PRIVATE_KEY);

    FeeManager internal _feeManager;

    function setUp() public {
        setupWithdrawManager();
        deal(_UNDERLYING_TOKEN, _USER_2, 100e18); // Note: wstETH uses 18 decimals
        vm.startPrank(_USER_2);
        IERC20(_UNDERLYING_TOKEN).approve(address(_plasmaVault), 100e18);
        vm.stopPrank();

        address[] memory addresses = new address[](1);
        addresses[0] = address(_withdrawManager);

        vm.startPrank(TestAddresses.ATOMIST);
        _contextManager.addApprovedTargets(addresses);
        vm.stopPrank();
    }

    function testRequestWithdraw() public {
        // given
        uint256 withdrawAmount = 50e18;

        ContextDataWithSender[] memory dataWithSignatures = new ContextDataWithSender[](1);
        dataWithSignatures[0] = preperateDataWithSignature(
            _USER_2_PRIVATE_KEY,
            block.timestamp + 1000,
            block.number,
            address(_withdrawManager),
            abi.encodeWithSelector(WithdrawManager.request.selector, withdrawAmount)
        );

        // when
        _contextManager.runWithContextAndSignature(dataWithSignatures);

        // then
        WithdrawRequestInfo memory requestInfo = _withdrawManager.requestInfo(_USER_2);
        assertEq(requestInfo.amount, withdrawAmount, "Withdraw request amount should match");
        assertTrue(requestInfo.endWithdrawWindowTimestamp > 0, "End withdraw window timestamp should be set");
    }

    function testReleaseFunds() public {
        // given
        uint256 timestamp = block.timestamp - 1 hours; // Valid timestamp in the past

        ContextDataWithSender[] memory dataWithSignatures = new ContextDataWithSender[](1);
        dataWithSignatures[0] = preperateDataWithSignature(
            TestAddresses.ALPHA_PRIVATE_KEY,
            block.timestamp + 1000,
            block.number,
            address(_withdrawManager),
            abi.encodeWithSelector(WithdrawManager.releaseFunds.selector, timestamp, 100e18)
        );

        uint256 initialReleaseFundsTimestamp = _withdrawManager.getLastReleaseFundsTimestamp();

        // when
        _contextManager.runWithContextAndSignature(dataWithSignatures);

        // then
        uint256 updatedReleaseFundsTimestamp = _withdrawManager.getLastReleaseFundsTimestamp();
        assertEq(updatedReleaseFundsTimestamp, timestamp, "Release funds timestamp should be updated");
        assertNotEq(updatedReleaseFundsTimestamp, initialReleaseFundsTimestamp, "Timestamp should have changed");
    }

    function testUpdateWithdrawWindow() public {
        // given
        uint256 newWindow = 7 days; // Set new withdraw window to 7 days

        ContextDataWithSender[] memory dataWithSignatures = new ContextDataWithSender[](1);
        dataWithSignatures[0] = preperateDataWithSignature(
            TestAddresses.ATOMIST_PRIVATE_KEY,
            block.timestamp + 1000,
            block.number,
            address(_withdrawManager),
            abi.encodeWithSelector(WithdrawManager.updateWithdrawWindow.selector, newWindow)
        );

        uint256 initialWindow = _withdrawManager.getWithdrawWindow();

        // when
        _contextManager.runWithContextAndSignature(dataWithSignatures);

        // then
        uint256 updatedWindow = _withdrawManager.getWithdrawWindow();
        assertEq(updatedWindow, newWindow, "Withdraw window should be updated to new value");
        assertNotEq(updatedWindow, initialWindow, "Withdraw window should have changed");
    }
}
