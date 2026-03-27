// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "../../../../test/OlympixUnitTest.sol";
import {ContextManager} from "../../../../contracts/managers/context/ContextManager.sol";

import {IContextClient} from "contracts/managers/context/IContextClient.sol";
import {ContextManager} from "contracts/managers/context/ContextManager.sol";
import {ExecuteData} from "contracts/managers/context/ContextManager.sol";
import {ContextDataWithSender} from "contracts/managers/context/ContextManager.sol";
import {AccessManagedUpgradeable} from "contracts/managers/access/AccessManagedUpgradeable.sol";
import {Test} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
contract ContextManagerTest is OlympixUnitTest("ContextManager") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_initialize_InvalidAuthorityZeroAddress_Reverts_opix_target_branch_142_True() public {
            // Arrange: zero authority should trigger the `if (initialAuthority_ == address(0))` branch
            address authority = address(0);
            address[] memory approvedTargets = new address[](1);
            approvedTargets[0] = address(this);
    
            // Expect the custom InvalidAuthority error from ContextManager
            vm.expectRevert(ContextManager.InvalidAuthority.selector);
    
            // Act: deploying with zero authority should revert and take opix-target-branch-142-True
            new ContextManager(authority, approvedTargets);
        }

    function test_constructor_EmptyApprovedTargets_RevertsEmptyArrayNotAllowed_opix_target_branch_150_True() public {
            // Arrange: authority is non-zero, but approvedTargets array is empty
            address authority = address(this);
            address[] memory approvedTargets = new address[](0);
    
            // Expect the custom EmptyArrayNotAllowed error from ContextManager
            vm.expectRevert(ContextManager.EmptyArrayNotAllowed.selector);
    
            // Act: deploying with an empty approvedTargets array should hit
            // the `if (length == 0)` branch in _initialize and revert
            new ContextManager(authority, approvedTargets);
        }

    function test_getNonce_opix_target_branch_175_True() public {
            // Arrange: deploy ContextManager with a valid authority and one approved target
            address authority = address(this);
            address[] memory approvedTargets = new address[](1);
            approvedTargets[0] = address(this);
            ContextManager manager = new ContextManager(authority, approvedTargets);
    
            // Act: query nonce for an arbitrary sender
            address sender = address(0xBEEF);
            uint256 nonce = manager.getNonce(sender);
    
            // Assert: function returned successfully (took the `if (true)` branch) and
            // default nonce for a fresh sender is zero
            assertEq(nonce, 0, "Initial nonce should be zero");
        }

    function test_runWithContext_RevertsOnEmptyTargetsArray_opix_target_branch_274_True() public {
            // Arrange: deploy ContextManager with a non-zero authority and one approved target
            address authority = address(this);
            address[] memory approvedTargets = new address[](1);
            approvedTargets[0] = address(this);
    
            ContextManager contextManager = new ContextManager(authority, approvedTargets);
    
            // Build ExecuteData with empty targets to hit the `if (length == 0)` branch
            ExecuteData memory executeData;
            executeData.targets = new address[](0);
            executeData.datas = new bytes[](0);
    
            // Expect the custom EmptyArrayNotAllowed error from ContextManager
            vm.expectRevert(ContextManager.EmptyArrayNotAllowed.selector);
    
            // Act: call runWithContext, which should revert and take opix-target-branch-274-True
            contextManager.runWithContext(executeData);
        }

    function test_runWithContext_NonEmptyArray_ElseBranch() public {
            // Prepare approved target list with this test contract as the only approved target
            address[] memory approvedTargets = new address[](1);
            approvedTargets[0] = address(this);
    
            // Deploy ContextManager with this contract as the authority
            ContextManager manager = new ContextManager(address(this), approvedTargets);
    
            // Build ExecuteData with non‑empty targets & datas so that
            // `length == 0` is false and the opix else-branch is taken
            address[] memory targets = new address[](1);
            bytes[] memory datas = new bytes[](1);
    
            targets[0] = address(this);
            // data that will cause a low-level call to revert (this contract
            // does not implement the called function nor IContextClient)
            datas[0] = abi.encodeWithSignature("nonExistingFunction()");
    
            ExecuteData memory execData = ExecuteData({targets: targets, datas: datas});
    
            // Expect a revert when _executeWithinContext tries to
            // call setupContext on a non‑IContextClient target / bad call
            vm.expectRevert();
            manager.runWithContext(execData);
        }

    function test_runWithContext_LengthMismatch_opix_target_branch_280_True() public {
            // Arrange: deploy ContextManager with a valid authority and one approved target
            address authority = address(this);
            address[] memory approvedTargets = new address[](1);
            approvedTargets[0] = address(this);
    
            ContextManager manager = new ContextManager(authority, approvedTargets);
    
            // Build ExecuteData with non‑empty targets and mismatched datas length
            ExecuteData memory execData;
            execData.targets = new address[](1);
            execData.targets[0] = address(this);
            execData.datas = new bytes[](0); // different length to trigger LengthMismatch branch
    
            // Expect the custom LengthMismatch error from ContextManager
            vm.expectRevert(ContextManager.LengthMismatch.selector);
    
            // Act: call runWithContext, which should revert and take opix-target-branch-280-True
            manager.runWithContext(execData);
        }

    function test_runWithContext_TargetZeroAddress_RevertsInvalidAuthority_opix_target_branch_291_True() public {
            // Arrange: deploy ContextManager with a valid authority and one approved non-zero target
            address authority = address(this);
            address[] memory approvedTargets = new address[](1);
            approvedTargets[0] = address(this);
            ContextManager manager = new ContextManager(authority, approvedTargets);
    
            // Build ExecuteData with non-empty arrays, but first target is the zero address
            address[] memory targets = new address[](1);
            bytes[] memory datas = new bytes[](1);
            targets[0] = address(0);
            datas[0] = bytes("");
    
            ExecuteData memory execData = ExecuteData({targets: targets, datas: datas});
    
            // Expect the custom InvalidAuthority error from ContextManager
            vm.expectRevert(ContextManager.InvalidAuthority.selector);
    
            // Act: call runWithContext, which should revert and take opix-target-branch-291-True
            manager.runWithContext(execData);
        }

    function test_runWithContextAndSignature_EmptyArrayReverts() public {
            // Prepare approved target list with this test contract as the only approved target
            address[] memory approvedTargets = new address[](1);
            approvedTargets[0] = address(this);
    
            // Deploy a fresh ContextManager instance locally
            ContextManager manager = new ContextManager(address(this), approvedTargets);
    
            // Prepare an empty ContextDataWithSender array to trigger the length == 0 branch
            ContextDataWithSender[] memory empty = new ContextDataWithSender[](0);
    
            // Expect the custom EmptyArrayNotAllowed error from ContextManager
            vm.expectRevert(ContextManager.EmptyArrayNotAllowed.selector);
    
            // Call the function under test with the empty array
            manager.runWithContextAndSignature(empty);
        }

    function test_runWithContextAndSignature_NonEmptyArray_ElseBranch() public {
            // Prepare approved target list with this test contract as the only approved target
            address[] memory approvedTargets = new address[](1);
            approvedTargets[0] = address(this);
    
            // Deploy ContextManager with this contract as the authority
            ContextManager manager = new ContextManager(address(this), approvedTargets);
    
            // Prepare a single ContextDataWithSender element so length != 0
            ContextDataWithSender[] memory arr = new ContextDataWithSender[](1);
    
            address sender = address(this);
            uint256 nonce = 1;
            address target = address(this);
            bytes memory callData = ""; // data is unused because we revert on SignatureExpired before execution
    
            // Set expirationTime in the past to force SignatureExpired after the length!=0 `else` branch is taken
            uint256 expirationTime = block.timestamp - 1;
    
            arr[0] = ContextDataWithSender({
                sender: sender,
                expirationTime: expirationTime,
                nonce: nonce,
                target: target,
                data: callData,
                signature: new bytes(0)
            });
    
            // Because length != 0, the function will enter the `else` branch for
            // opix-target-branch-327 and then hit SignatureExpired on the first loop iteration
            vm.expectRevert(ContextManager.SignatureExpired.selector);
            manager.runWithContextAndSignature(arr);
        }

    function test_runWithContextAndSignature_ExpirationElseBranch_SignatureInvalid() public {
            // Prepare approved target list with this test contract as the only approved target
            address[] memory approvedTargets = new address[](1);
            approvedTargets[0] = address(this);
    
            // Deploy ContextManager with this contract as the authority
            ContextManager manager = new ContextManager(address(this), approvedTargets);
    
            // Prepare a single ContextDataWithSender element so length != 0
            ContextDataWithSender[] memory arr = new ContextDataWithSender[](1);
    
            // Create a context with expirationTime in the future, so
            // `if (block.timestamp > contextData.expirationTime)` is FALSE
            // and the opix-target-branch-340-else branch is taken
            address sender = address(this);
            uint256 nonce = 1;
            address target = address(this);
            bytes memory callData = "";
            uint256 expirationTime = block.timestamp + 1;
    
            // Provide a valid-format but wrong signature so ECDSA.recover returns a non-matching address
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(1, keccak256("wrong message"));
            bytes memory signature = abi.encodePacked(r, s, v);
    
            arr[0] = ContextDataWithSender({
                sender: sender,
                expirationTime: expirationTime,
                nonce: nonce,
                target: target,
                data: callData,
                signature: signature
            });
    
            // Expect revert with InvalidSignature after taking the `else` branch of the expiration check
            vm.expectRevert(ContextManager.InvalidSignature.selector);
            manager.runWithContextAndSignature(arr);
        }

    function test_runWithContextAndSignature_ValidSignature_opix_target_branch_346_Else() public {
            // Arrange: deploy ContextManager with this contract as the only approved target
            address[] memory approvedTargets = new address[](1);
            approvedTargets[0] = address(this);
            ContextManager manager = new ContextManager(address(this), approvedTargets);
    
            // Prepare a single ContextDataWithSender element so length != 0
            ContextDataWithSender[] memory arr = new ContextDataWithSender[](1);
    
            // Use vm.sign with a known private key that corresponds to a non-zero address
            // Here we use private key 1, whose address is address(0x8626f6940E2eb28930eFb4CeF49B2d1F2C9C1199)
            uint256 privateKey = 1;
            address sender = vm.addr(privateKey);
    
            uint256 nonce = 1;
            address target = address(this);
            bytes memory callData = abi.encodeWithSignature("clearContext()");
            uint256 expirationTime = block.timestamp + 1 hours;
    
            // Build the message hash exactly as in _verifySignature
            bytes32 digest = keccak256(
                abi.encodePacked(
                    address(manager),
                    expirationTime,
                    nonce,
                    manager.CHAIN_ID(),
                    target,
                    callData
                )
            );
    
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
            bytes memory signature = abi.encodePacked(r, s, v);
    
            arr[0] = ContextDataWithSender({
                sender: sender,
                expirationTime: expirationTime,
                nonce: nonce,
                target: target,
                data: callData,
                signature: signature
            });
    
            // Act & Assert: length != 0 so the first EmptyArrayNotAllowed check takes the else branch,
            // expiration is in the future so SignatureExpired check takes its else branch,
            // and _verifySignature returns true so opix-target-branch-346-Else is taken
            // The call will ultimately revert when trying to call setupContext/clearContext on this contract,
            // which does not implement IContextClient, so we just expect a revert of any kind.
            vm.expectRevert();
            manager.runWithContextAndSignature(arr);
        }

    function test_executeWithinContext_TargetNotApproved_opix_target_branch_372_True() public {
            // Arrange: deploy ContextManager with a valid authority and one approved target (this contract)
            address authority = address(this);
            address[] memory approvedTargets = new address[](1);
            approvedTargets[0] = address(this);
            ContextManager manager = new ContextManager(authority, approvedTargets);
    
            // Build ExecuteData where targets[0] is NOT in the approvedTargets list
            // This will cause _executeWithinContext to see isTargetApproved(target_) == false
            address[] memory targets = new address[](1);
            bytes[] memory datas = new bytes[](1);
            targets[0] = address(0x1234); // unapproved target
            datas[0] = abi.encodeWithSelector(IContextClient.setupContext.selector, address(this));
    
            ExecuteData memory execData = ExecuteData({targets: targets, datas: datas});
    
            // Expect the custom TargetNotApproved error from ContextManager
            vm.expectRevert(abi.encodeWithSelector(ContextManager.TargetNotApproved.selector, targets[0]));
    
            // Act: runWithContext will internally call _executeWithinContext,
            // taking the `if (!ContextManagerStorageLib.isTargetApproved(target_))` true branch
            manager.runWithContext(execData);
        }
}