// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @dev IL-9533 (3sigma #6): unit tests of ContextClient sender binding. The stored context sender is returned only to
///      the caller that ran setupContext; any other caller (another account, another context manager, re-entrant code)
///      resolves to itself. setupContext(0) reverts UnauthorizedSender, clearContext without a context reverts
///      ContextNotSet. Delegatecalls keep msg.sender, so code delegatecalled by the client still sees the sender.
import {Test} from "forge-std/Test.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import {ContextClient} from "contracts/managers/context/ContextClient.sol";
import {IContextClient} from "contracts/managers/context/IContextClient.sol";
import {IporFusionAccessManager} from "contracts/managers/access/IporFusionAccessManager.sol";
import {Roles} from "contracts/libraries/Roles.sol";

contract ContextClientBindingHarness is ContextClient {
    error ContextClientBindingHarnessDelegatecallFailed(bytes reason);

    constructor(address authority_) initializer {
        __AccessManaged_init(authority_);
    }

    function whoAmI() external view returns (address) {
        return _getSenderFromContext();
    }

    /// @dev Delegatecalls whoAmI() on implementation_ (as PlasmaVault does with PlasmaVaultBase): msg.sender and the
    ///      storage of this contract are kept
    function whoAmIThroughDelegatecall(address implementation_) external returns (address) {
        (bool ok, bytes memory result) = implementation_.delegatecall(
            abi.encodeWithSelector(ContextClientBindingHarness.whoAmI.selector)
        );
        if (!ok) {
            revert ContextClientBindingHarnessDelegatecallFailed(result);
        }
        return abi.decode(result, (address));
    }

    /// @dev Calls whoAmI() back on msg.sender's target while this harness is the caller
    function whoAmIOn(ContextClientBindingHarness target_) external view returns (address) {
        return target_.whoAmI();
    }

    function _msgSender() internal view override returns (address) {
        return _getSenderFromContext();
    }
}

contract ContextClientBindingUnitTest is Test {
    /// @dev ERC-7201 slot of ContextClientStorageLib.ContextSenderStorage (io.ipor.context.client.sender.storage)
    bytes32 internal constant _CONTEXT_SENDER_STORAGE_SLOT =
        0x68262fe08792a71a690eb5eb2de15df1b0f463dd786bf92bdbd5f0f0d1ae8b00;

    address internal constant _MANAGER = address(0xC0);
    address internal constant _OTHER_MANAGER = address(0xC1);
    address internal constant _USER = address(0xA11CE);
    address internal constant _OTHER = address(0xB0B);

    IporFusionAccessManager internal _accessManager;
    ContextClientBindingHarness internal _client;
    ContextClientBindingHarness internal _implementation;

    function setUp() public {
        _accessManager = new IporFusionAccessManager(address(this), 0);
        _client = new ContextClientBindingHarness(address(_accessManager));
        _implementation = new ContextClientBindingHarness(address(_accessManager));

        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = ContextClient.setupContext.selector;
        selectors[1] = ContextClient.clearContext.selector;
        _accessManager.setTargetFunctionRole(address(_client), selectors, Roles.TECH_CONTEXT_MANAGER_ROLE);
        _accessManager.grantRole(Roles.TECH_CONTEXT_MANAGER_ROLE, _MANAGER, 0);
        _accessManager.grantRole(Roles.TECH_CONTEXT_MANAGER_ROLE, _OTHER_MANAGER, 0);
    }

    // ---------------------------------------------------------------- binding to the setter

    function testShouldReturnContextSenderOnlyToTheManagerThatSetIt() public {
        vm.prank(_MANAGER);
        _client.setupContext(_USER);

        vm.prank(_MANAGER);
        assertEq(_client.whoAmI(), _USER, "setter must see the context sender");

        vm.prank(_OTHER);
        assertEq(_client.whoAmI(), _OTHER, "another caller must see itself");

        vm.prank(_OTHER_MANAGER);
        assertEq(_client.whoAmI(), _OTHER_MANAGER, "another context manager must see itself");

        vm.prank(_MANAGER);
        assertEq(_client.whoAmI(), _USER, "setter still sees the context sender after other callers");
    }

    function testShouldResolveReentrantCallerToItself() public {
        ContextClientBindingHarness reentrant = new ContextClientBindingHarness(address(_accessManager));

        vm.prank(_MANAGER);
        _client.setupContext(_USER);

        assertEq(reentrant.whoAmIOn(_client), address(reentrant), "re-entrant contract must see itself");
    }

    function testShouldKeepContextSenderThroughDelegatecall() public {
        vm.prank(_MANAGER);
        _client.setupContext(_USER);

        vm.prank(_MANAGER);
        assertEq(_client.whoAmIThroughDelegatecall(address(_implementation)), _USER, "delegatecall from the setter");

        vm.prank(_OTHER);
        assertEq(
            _client.whoAmIThroughDelegatecall(address(_implementation)),
            _OTHER,
            "delegatecall from another caller"
        );
    }

    function testShouldReturnCallerAfterClearContext() public {
        vm.prank(_MANAGER);
        _client.setupContext(_USER);
        vm.prank(_MANAGER);
        _client.clearContext();

        vm.prank(_MANAGER);
        assertEq(_client.whoAmI(), _MANAGER, "setter must see itself after clearContext");

        vm.prank(_OTHER);
        assertEq(_client.whoAmI(), _OTHER, "another caller must see itself after clearContext");
    }

    function testShouldAllowNewContextAfterClearContext() public {
        vm.prank(_MANAGER);
        _client.setupContext(_USER);
        vm.prank(_MANAGER);
        _client.clearContext();

        vm.prank(_OTHER_MANAGER);
        _client.setupContext(_OTHER);

        vm.prank(_OTHER_MANAGER);
        assertEq(_client.whoAmI(), _OTHER, "new setter must see the new context sender");

        vm.prank(_MANAGER);
        assertEq(_client.whoAmI(), _MANAGER, "previous setter must see itself");
    }

    /// @dev A stored sender without a setter of the current transaction (as left by a setupContext without
    ///      clearContext in an earlier transaction) is returned to nobody and can still be cleared.
    function testShouldNotReturnStoredSenderWithoutSetterInThisTransaction() public {
        vm.store(address(_client), _CONTEXT_SENDER_STORAGE_SLOT, bytes32(uint256(uint160(_USER))));

        vm.prank(_MANAGER);
        assertEq(_client.whoAmI(), _MANAGER, "stale stored sender must not be returned");

        vm.prank(_MANAGER);
        _client.clearContext();

        assertEq(vm.load(address(_client), _CONTEXT_SENDER_STORAGE_SLOT), bytes32(0), "stored sender not cleared");
    }

    // ---------------------------------------------------------------- setupContext / clearContext rules

    function testShouldRevertSetupContextWithZeroSender() public {
        vm.expectRevert(abi.encodeWithSelector(ContextClient.UnauthorizedSender.selector));
        vm.prank(_MANAGER);
        _client.setupContext(address(0));
    }

    function testShouldRevertClearContextWithoutContext() public {
        vm.expectRevert(abi.encodeWithSelector(ContextClient.ContextNotSet.selector));
        vm.prank(_MANAGER);
        _client.clearContext();
    }

    function testShouldRevertSetupContextTwice() public {
        vm.prank(_MANAGER);
        _client.setupContext(_USER);

        vm.expectRevert(abi.encodeWithSelector(ContextClient.ContextAlreadySet.selector));
        vm.prank(_MANAGER);
        _client.setupContext(_OTHER);
    }

    function testShouldRevertSetupContextFromAccountWithoutRole() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, _OTHER));
        vm.prank(_OTHER);
        _client.setupContext(_USER);
    }

    function testShouldRevertClearContextFromAccountWithoutRole() public {
        vm.prank(_MANAGER);
        _client.setupContext(_USER);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, _OTHER));
        vm.prank(_OTHER);
        _client.clearContext();
    }

    function testShouldEmitContextEventsWithSender() public {
        vm.expectEmit(true, true, true, true, address(_client));
        emit IContextClient.ContextSet(_USER);
        vm.prank(_MANAGER);
        _client.setupContext(_USER);

        vm.expectEmit(true, true, true, true, address(_client));
        emit IContextClient.ContextCleared(_USER);
        vm.prank(_MANAGER);
        _client.clearContext();
    }
}
