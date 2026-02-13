// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ContextManagerInitSetup} from "./ContextManagerInitSetup.sol";
import {TestAddresses} from "../test_helpers/TestAddresses.sol";
import {IERC20} from "../../lib/forge-std/src/interfaces/IERC20.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {FeeAccount} from "../../contracts/managers/fee/FeeAccount.sol";
import {FeeManager} from "../../contracts/managers/fee/FeeManager.sol";
import {ContextDataWithSender} from "../../contracts/managers/context/ContextManager.sol";
import {RecipientFee} from "../../contracts/managers/fee/FeeManagerFactory.sol";
contract ContextManagerWithSignatureFeeManagerTest is Test, ContextManagerInitSetup {
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
        _contextManager.addApprovedTargets(addresses);
        vm.stopPrank();

        vm.startPrank(TestAddresses.DAO);
        _feeManager.setIporDaoFeeRecipientAddress(TestAddresses.IPOR_DAO_FEE_RECIPIENT_ADDRESS);
        vm.stopPrank();
    }

    function testUpdatePerformanceFee() public {
        // given
        uint256 newPerformanceFee = 1000; // 10% (with 2 decimals)

        RecipientFee[] memory recipientFees = new RecipientFee[](1);
        recipientFees[0] = RecipientFee({recipient: makeAddr("RECIPIENT"), feeValue: newPerformanceFee});

        ContextDataWithSender[] memory dataWithSignatures = new ContextDataWithSender[](1);
        dataWithSignatures[0] = preperateDataWithSignature(
            TestAddresses.ATOMIST_PRIVATE_KEY,
            block.timestamp + 1000,
            block.number,
            address(_feeManager),
            abi.encodeWithSelector(FeeManager.updatePerformanceFee.selector, recipientFees)
        );

        uint256 initialPerformanceFee = _feeManager.getTotalPerformanceFee();

        // when
        _contextManager.runWithContextAndSignature(dataWithSignatures);

        // then
        uint256 updatedPerformanceFee = _feeManager.getTotalPerformanceFee();
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

        RecipientFee[] memory recipientFees = new RecipientFee[](1);
        recipientFees[0] = RecipientFee({recipient: makeAddr("RECIPIENT"), feeValue: newManagementFee});

        ContextDataWithSender[] memory dataWithSignatures = new ContextDataWithSender[](1);
        dataWithSignatures[0] = preperateDataWithSignature(
            TestAddresses.ATOMIST_PRIVATE_KEY,
            block.timestamp + 1000,
            block.number,
            address(_feeManager),
            abi.encodeWithSelector(FeeManager.updateManagementFee.selector, recipientFees)
        );

        uint256 initialManagementFee = _feeManager.getTotalManagementFee();

        // when
        _contextManager.runWithContextAndSignature(dataWithSignatures);

        // then
        uint256 updatedManagementFee = _feeManager.getTotalManagementFee();
        uint256 expectedManagementFee = newManagementFee + _feeManager.IPOR_DAO_MANAGEMENT_FEE();

        assertNotEq(updatedManagementFee, initialManagementFee, "Management fee should have changed");
        assertEq(updatedManagementFee, expectedManagementFee, "Management fee should be set to new value plus DAO fee");
    }

    function testSetIporDaoFeeRecipientAddress() public {
        // given
        address newDaoFeeRecipient = makeAddr("NEW_DAO_FEE_RECIPIENT");

        ContextDataWithSender[] memory dataWithSignatures = new ContextDataWithSender[](1);
        dataWithSignatures[0] = preperateDataWithSignature(
            TestAddresses.DAO_PRIVATE_KEY,
            block.timestamp + 1000,
            block.number,
            address(_feeManager),
            abi.encodeWithSelector(FeeManager.setIporDaoFeeRecipientAddress.selector, newDaoFeeRecipient)
        );

        address initialDaoFeeRecipient = _feeManager.getIporDaoFeeRecipientAddress();

        // when
        _contextManager.runWithContextAndSignature(dataWithSignatures);

        // then
        address updatedDaoFeeRecipient = _feeManager.getIporDaoFeeRecipientAddress();
        assertNotEq(updatedDaoFeeRecipient, initialDaoFeeRecipient, "DAO fee recipient address should have changed");
        assertEq(updatedDaoFeeRecipient, newDaoFeeRecipient, "DAO fee recipient address should be set to new value");
    }
}
