// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ContextManagerInitSetup} from "./ContextManagerInitSetup.sol";
import {TestAddresses} from "../test_helpers/TestAddresses.sol";
import {ExecuteData} from "../../contracts/managers/context/ContextManager.sol";
import {IERC20} from "../../lib/forge-std/src/interfaces/IERC20.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {FeeAccount} from "../../contracts/managers/fee/FeeAccount.sol";
import {FeeManager} from "../../contracts/managers/fee/FeeManager.sol";

contract ContextManagerPlasmaVaultTest is Test, ContextManagerInitSetup {
    // Test events
    event ContextCall(address indexed target, bytes data, bytes result);
    address internal immutable _USER_2 = makeAddr("USER2");

    address[] private _addresses;
    bytes[] private _data;

    FeeManager internal _feeManager;

    function setUp() public {
        initSetup();
        deal(_UNDERLYING_TOKEN, _USER_2, 100e18); // Note: wstETH uses 18 decimals
        vm.startPrank(_USER_2);
        IERC20(_UNDERLYING_TOKEN).approve(address(_plasmaVault), 100e18);
        vm.stopPrank();

        _feeManager = FeeManager(
            FeeAccount(PlasmaVaultGovernance(address(_plasmaVault)).getPerformanceFeeData().feeAccount).FEE_MANAGER()
        );

        _feeManager.initialize();

        address[] memory addresses = new address[](1);
        addresses[0] = address(_feeManager);

        vm.startPrank(TestAddresses.ATOMIST);
        _contextManager.addApprovedAddresses(addresses);
        vm.stopPrank();
    }

    function testUpdatePerformanceFee() public {
        // given
        uint256 newPerformanceFee = 1000; // 10% (with 2 decimals)

        _addresses = new address[](1);
        _addresses[0] = address(_feeManager);

        _data = new bytes[](1);
        _data[0] = abi.encodeWithSelector(FeeManager.updatePerformanceFee.selector, newPerformanceFee);

        ExecuteData memory executeData = ExecuteData({targets: _addresses, datas: _data});

        uint256 initialPerformanceFee = _feeManager.getFeeConfig().plasmaVaultPerformanceFee;

        // when
        vm.startPrank(TestAddresses.ATOMIST);
        _contextManager.runWithContext(executeData);
        vm.stopPrank();

        // then
        uint256 updatedPerformanceFee = _feeManager.getFeeConfig().plasmaVaultPerformanceFee;
        uint256 expectedPerformanceFee = newPerformanceFee + _feeManager.IPOR_DAO_PERFORMANCE_FEE();

        assertNotEq(updatedPerformanceFee, initialPerformanceFee, "Performance fee should have changed");
        assertEq(
            updatedPerformanceFee,
            expectedPerformanceFee,
            "Performance fee should be set to new value plus DAO fee"
        );
    }

    function testUpdateManagementFee() public {
        // given
        uint256 newManagementFee = 500; // 5% (with 2 decimals)

        _addresses = new address[](1);
        _addresses[0] = address(_feeManager);

        _data = new bytes[](1);
        _data[0] = abi.encodeWithSelector(FeeManager.updateManagementFee.selector, newManagementFee);

        ExecuteData memory executeData = ExecuteData({targets: _addresses, datas: _data});

        uint256 initialManagementFee = _feeManager.getFeeConfig().plasmaVaultManagementFee;

        // when
        vm.startPrank(TestAddresses.ATOMIST);
        _contextManager.runWithContext(executeData);
        vm.stopPrank();

        // then
        uint256 updatedManagementFee = _feeManager.getFeeConfig().plasmaVaultManagementFee;
        uint256 expectedManagementFee = newManagementFee + _feeManager.IPOR_DAO_MANAGEMENT_FEE();

        assertNotEq(updatedManagementFee, initialManagementFee, "Management fee should have changed");
        assertEq(updatedManagementFee, expectedManagementFee, "Management fee should be set to new value plus DAO fee");
    }

    function testSetFeeRecipientAddress() public {
        // given
        address newFeeRecipient = makeAddr("NEW_FEE_RECIPIENT");

        _addresses = new address[](1);
        _addresses[0] = address(_feeManager);

        _data = new bytes[](1);
        _data[0] = abi.encodeWithSelector(FeeManager.setFeeRecipientAddress.selector, newFeeRecipient);

        ExecuteData memory executeData = ExecuteData({targets: _addresses, datas: _data});

        address initialFeeRecipient = _feeManager.getFeeConfig().feeRecipientAddress;

        // when
        vm.startPrank(TestAddresses.ATOMIST);
        _contextManager.runWithContext(executeData);
        vm.stopPrank();

        // then
        address updatedFeeRecipient = _feeManager.getFeeConfig().feeRecipientAddress;
        assertNotEq(updatedFeeRecipient, initialFeeRecipient, "Fee recipient address should have changed");
        assertEq(updatedFeeRecipient, newFeeRecipient, "Fee recipient address should be set to new value");
    }

    function testSetIporDaoFeeRecipientAddress() public {
        // given
        address newDaoFeeRecipient = makeAddr("NEW_DAO_FEE_RECIPIENT");

        _addresses = new address[](1);
        _addresses[0] = address(_feeManager);

        _data = new bytes[](1);
        _data[0] = abi.encodeWithSelector(FeeManager.setIporDaoFeeRecipientAddress.selector, newDaoFeeRecipient);

        ExecuteData memory executeData = ExecuteData({targets: _addresses, datas: _data});

        address initialDaoFeeRecipient = _feeManager.getFeeConfig().iporDaoFeeRecipientAddress;

        // when
        vm.startPrank(TestAddresses.DAO);
        _contextManager.runWithContext(executeData);
        vm.stopPrank();

        // then
        address updatedDaoFeeRecipient = _feeManager.getFeeConfig().iporDaoFeeRecipientAddress;
        assertNotEq(updatedDaoFeeRecipient, initialDaoFeeRecipient, "DAO fee recipient address should have changed");
        assertEq(updatedDaoFeeRecipient, newDaoFeeRecipient, "DAO fee recipient address should be set to new value");
    }
}
