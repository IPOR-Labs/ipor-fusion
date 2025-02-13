// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ContextManagerInitSetup} from "./ContextManagerInitSetup.sol";
import {TestAddresses} from "../test_helpers/TestAddresses.sol";
import {ExecuteData} from "../../contracts/managers/context/ContextManager.sol";
import {IERC20} from "../../lib/forge-std/src/interfaces/IERC20.sol";
import {FeeManager} from "../../contracts/managers/fee/FeeManager.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {WithdrawRequestInfo} from "../../contracts/managers/withdraw/WithdrawManager.sol";

contract ContextManagerWithdrawManagerTest is Test, ContextManagerInitSetup {
    // Test events
    event ContextCall(address indexed target, bytes data, bytes result);
    address internal immutable _USER_2 = makeAddr("USER2");

    address[] private _addresses;
    bytes[] private _data;

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

        _addresses = new address[](1);
        _addresses[0] = address(_withdrawManager);

        _data = new bytes[](1);
        _data[0] = abi.encodeWithSelector(WithdrawManager.request.selector, withdrawAmount);

        ExecuteData memory executeData = ExecuteData({targets: _addresses, datas: _data});

        // when
        vm.startPrank(_USER_2);
        _contextManager.runWithContext(executeData);
        vm.stopPrank();

        // then
        WithdrawRequestInfo memory requestInfo = _withdrawManager.requestInfo(_USER_2);
        assertEq(requestInfo.shares, withdrawAmount, "Withdraw request shares should match");
        assertTrue(requestInfo.endWithdrawWindowTimestamp > 0, "End withdraw window timestamp should be set");
    }

    function testReleaseFunds() public {
        // given
        uint256 timestamp = block.timestamp - 1 hours; // Valid timestamp in the past

        _addresses = new address[](1);
        _addresses[0] = address(_withdrawManager);

        _data = new bytes[](1);
        _data[0] = abi.encodeWithSelector(WithdrawManager.releaseFunds.selector, timestamp, 100e18);

        ExecuteData memory executeData = ExecuteData({targets: _addresses, datas: _data});

        uint256 initialReleaseFundsTimestamp = _withdrawManager.getLastReleaseFundsTimestamp();

        // when
        vm.startPrank(TestAddresses.ALPHA);
        _contextManager.runWithContext(executeData);
        vm.stopPrank();

        // then
        uint256 updatedReleaseFundsTimestamp = _withdrawManager.getLastReleaseFundsTimestamp();
        assertEq(updatedReleaseFundsTimestamp, timestamp, "Release funds timestamp should be updated");
        assertNotEq(updatedReleaseFundsTimestamp, initialReleaseFundsTimestamp, "Timestamp should have changed");
    }

    function testUpdateWithdrawWindow() public {
        // given
        uint256 newWindow = 7 days; // Set new withdraw window to 7 days

        _addresses = new address[](1);
        _addresses[0] = address(_withdrawManager);

        _data = new bytes[](1);
        _data[0] = abi.encodeWithSelector(WithdrawManager.updateWithdrawWindow.selector, newWindow);

        ExecuteData memory executeData = ExecuteData({targets: _addresses, datas: _data});

        uint256 initialWindow = _withdrawManager.getWithdrawWindow();

        // when
        vm.startPrank(TestAddresses.ATOMIST);
        _contextManager.runWithContext(executeData);
        vm.stopPrank();

        // then
        uint256 updatedWindow = _withdrawManager.getWithdrawWindow();
        assertEq(updatedWindow, newWindow, "Withdraw window should be updated to new value");
        assertNotEq(updatedWindow, initialWindow, "Withdraw window should have changed");
    }
}
