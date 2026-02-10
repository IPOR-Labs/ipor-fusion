// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

import {PlasmaVault, PlasmaVaultInitData, FuseAction} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultVotesPlugin} from "../../contracts/vaults/plugins/PlasmaVaultVotesPlugin.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {FeeConfigHelper} from "../test_helpers/FeeConfigHelper.sol";
import {RoleLib, UsersToRoles} from "../RoleLib.sol";

/// @title PlasmaVaultNonceTest
/// @notice Tests for nonce behavior in PlasmaVault, PlasmaVaultBase, and PlasmaVaultVotesPlugin
/// @dev Tests cover:
/// - Initial nonce value
/// - Nonce increment after permit
/// - Nonce increment after delegateBySig
/// - Shared nonce between permit and delegateBySig
/// - Replay attack protection
/// - Invalid nonce handling
contract PlasmaVaultNonceTest is Test {
    // Test contracts
    PlasmaVaultBase public plasmaVaultBase;
    PlasmaVaultVotesPlugin public votesPlugin;
    PriceOracleMiddleware public priceOracle;
    MockERC20ForNonceTest public underlying;
    UsersToRoles public usersToRoles;

    // Test addresses and keys
    uint256 public constant ALICE_PRIVATE_KEY = 0xA11CE;
    uint256 public constant BOB_PRIVATE_KEY = 0xB0B;
    address public alice;
    address public bob;
    address public constant ATOMIST = address(0x1);

    // Constants
    uint256 public constant INITIAL_DEPOSIT = 1000e18;
    string public constant VAULT_NAME = "Plasma Vault Token";

    function setUp() public {
        // Derive addresses from private keys
        alice = vm.addr(ALICE_PRIVATE_KEY);
        bob = vm.addr(BOB_PRIVATE_KEY);

        // Deploy underlying token
        underlying = new MockERC20ForNonceTest("Underlying", "UND");
        underlying.mint(ATOMIST, 10_000_000e18);
        underlying.mint(alice, 100_000e18);
        underlying.mint(bob, 100_000e18);

        // Deploy price oracle
        priceOracle = new PriceOracleMiddleware(address(0));
        priceOracle.initialize(ATOMIST);

        // Deploy PlasmaVaultBase
        plasmaVaultBase = new PlasmaVaultBase();

        // Deploy VotesPlugin
        votesPlugin = new PlasmaVaultVotesPlugin();

        // Setup users to roles
        usersToRoles.superAdmin = ATOMIST;
        usersToRoles.atomist = ATOMIST;
        usersToRoles.alphas = new address[](0);
        usersToRoles.performanceFeeManagers = new address[](0);
        usersToRoles.managementFeeManagers = new address[](0);
        usersToRoles.feeTimelock = 0;
    }

    /// @notice Helper to deploy a PlasmaVault with votes plugin
    function _deployVaultWithVotes() internal returns (PlasmaVault vault, IporFusionAccessManager accessManager) {
        accessManager = RoleLib.createAccessManager(usersToRoles, 0, vm);
        address withdrawManager = address(new WithdrawManager(address(accessManager)));

        vm.startPrank(ATOMIST);

        PlasmaVaultInitData memory initData = PlasmaVaultInitData({
            assetName: VAULT_NAME,
            assetSymbol: "PVT",
            underlyingToken: address(underlying),
            priceOracleMiddleware: address(priceOracle),
            feeConfig: FeeConfigHelper.createZeroFeeConfig(),
            accessManager: address(accessManager),
            plasmaVaultBase: address(plasmaVaultBase),
            withdrawManager: withdrawManager,
            plasmaVaultVotesPlugin: address(votesPlugin)
        });

        vault = new PlasmaVault();
        vault.proxyInitialize(initData);

        vm.stopPrank();

        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(vault), accessManager, withdrawManager);
    }

    /// @notice Helper to create EIP-712 domain separator
    function _getDomainSeparator(address vaultAddress) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(VAULT_NAME)),
                keccak256(bytes("1")),
                block.chainid,
                vaultAddress
            )
        );
    }

    /// @notice Helper to sign permit
    function _signPermit(
        uint256 privateKey,
        address vaultAddress,
        address owner,
        address spender,
        uint256 value,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                spender,
                value,
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _getDomainSeparator(vaultAddress), structHash));
        (v, r, s) = vm.sign(privateKey, digest);
    }

    /// @notice Helper to sign delegateBySig
    function _signDelegation(
        uint256 privateKey,
        address vaultAddress,
        address delegatee,
        uint256 nonce,
        uint256 expiry
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)"),
                delegatee,
                nonce,
                expiry
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _getDomainSeparator(vaultAddress), structHash));
        (v, r, s) = vm.sign(privateKey, digest);
    }

    // ============================================
    // TEST: Initial nonce value
    // ============================================

    /// @notice Test that initial nonce is 0 for any address
    function testInitialNonceIsZero() public {
        (PlasmaVault vault, ) = _deployVaultWithVotes();

        // Check nonce for alice (never interacted)
        uint256 aliceNonce = IERC20Permit(address(vault)).nonces(alice);
        assertEq(aliceNonce, 0, "Initial nonce for alice should be 0");

        // Check nonce for bob (never interacted)
        uint256 bobNonce = IERC20Permit(address(vault)).nonces(bob);
        assertEq(bobNonce, 0, "Initial nonce for bob should be 0");

        // Check nonce for random address
        address randomAddr = address(0x12345);
        uint256 randomNonce = IERC20Permit(address(vault)).nonces(randomAddr);
        assertEq(randomNonce, 0, "Initial nonce for random address should be 0");
    }

    /// @notice Test initial nonce is 0 after deposit (deposit doesn't affect nonce)
    function testNonceRemainsZeroAfterDeposit() public {
        (PlasmaVault vault, ) = _deployVaultWithVotes();

        // Alice deposits
        vm.startPrank(alice);
        underlying.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, alice);
        vm.stopPrank();

        // Nonce should still be 0
        uint256 aliceNonce = IERC20Permit(address(vault)).nonces(alice);
        assertEq(aliceNonce, 0, "Nonce should remain 0 after deposit");
    }

    // ============================================
    // TEST: Nonce increment after permit
    // ============================================

    /// @notice Test that nonce increments by 1 after successful permit
    function testNonceIncrementsAfterPermit() public {
        (PlasmaVault vault, ) = _deployVaultWithVotes();

        // Alice deposits to have shares
        vm.startPrank(alice);
        underlying.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, alice);
        vm.stopPrank();

        uint256 nonceBefore = IERC20Permit(address(vault)).nonces(alice);
        assertEq(nonceBefore, 0, "Nonce before permit should be 0");

        // Prepare and execute permit
        uint256 deadline = block.timestamp + 1 days;
        uint256 permitValue = 100e18;

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(
            ALICE_PRIVATE_KEY,
            address(vault),
            alice,
            bob,
            permitValue,
            nonceBefore,
            deadline
        );

        IERC20Permit(address(vault)).permit(alice, bob, permitValue, deadline, v, r, s);

        // Check nonce incremented
        uint256 nonceAfter = IERC20Permit(address(vault)).nonces(alice);
        assertEq(nonceAfter, 1, "Nonce after permit should be 1");
        assertEq(nonceAfter, nonceBefore + 1, "Nonce should increment by exactly 1");
    }

    /// @notice Test multiple permits increment nonce sequentially
    function testMultiplePermitsIncrementNonceSequentially() public {
        (PlasmaVault vault, ) = _deployVaultWithVotes();

        // Alice deposits
        vm.startPrank(alice);
        underlying.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, alice);
        vm.stopPrank();

        uint256 deadline = block.timestamp + 1 days;

        // Execute 3 permits and check nonce each time
        for (uint256 i = 0; i < 3; i++) {
            uint256 currentNonce = IERC20Permit(address(vault)).nonces(alice);
            assertEq(currentNonce, i, "Nonce before permit should match iteration");

            (uint8 v, bytes32 r, bytes32 s) = _signPermit(
                ALICE_PRIVATE_KEY,
                address(vault),
                alice,
                bob,
                100e18 + i,  // Different values to make each permit unique
                currentNonce,
                deadline
            );

            IERC20Permit(address(vault)).permit(alice, bob, 100e18 + i, deadline, v, r, s);

            uint256 newNonce = IERC20Permit(address(vault)).nonces(alice);
            assertEq(newNonce, i + 1, "Nonce after permit should increment");
        }

        uint256 finalNonce = IERC20Permit(address(vault)).nonces(alice);
        assertEq(finalNonce, 3, "Final nonce should be 3 after 3 permits");
    }

    // ============================================
    // TEST: Nonce increment after delegateBySig
    // ============================================

    /// @notice Test that nonce increments by 1 after successful delegateBySig
    function testNonceIncrementsAfterDelegateBySig() public {
        (PlasmaVault vault, ) = _deployVaultWithVotes();

        // Alice deposits and delegates to herself first
        vm.startPrank(alice);
        underlying.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, alice);
        IVotes(address(vault)).delegate(alice);
        vm.stopPrank();

        uint256 nonceBefore = IERC20Permit(address(vault)).nonces(alice);
        assertEq(nonceBefore, 0, "Nonce before delegateBySig should be 0");

        // Sign delegation
        uint256 expiry = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _signDelegation(
            ALICE_PRIVATE_KEY,
            address(vault),
            bob,
            nonceBefore,
            expiry
        );

        // Execute delegateBySig
        IVotes(address(vault)).delegateBySig(bob, nonceBefore, expiry, v, r, s);

        // Check nonce incremented
        uint256 nonceAfter = IERC20Permit(address(vault)).nonces(alice);
        assertEq(nonceAfter, 1, "Nonce after delegateBySig should be 1");
    }

    /// @notice Test multiple delegateBySig increment nonce sequentially
    function testMultipleDelegateBySigIncrementNonceSequentially() public {
        (PlasmaVault vault, ) = _deployVaultWithVotes();

        // Alice deposits
        vm.startPrank(alice);
        underlying.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, alice);
        IVotes(address(vault)).delegate(alice);
        vm.stopPrank();

        uint256 expiry = block.timestamp + 1 days;
        address[] memory delegatees = new address[](3);
        delegatees[0] = bob;
        delegatees[1] = alice;
        delegatees[2] = address(0x999);

        // Execute 3 delegateBySig and check nonce each time
        for (uint256 i = 0; i < 3; i++) {
            uint256 currentNonce = IERC20Permit(address(vault)).nonces(alice);
            assertEq(currentNonce, i, "Nonce before delegateBySig should match iteration");

            (uint8 v, bytes32 r, bytes32 s) = _signDelegation(
                ALICE_PRIVATE_KEY,
                address(vault),
                delegatees[i],
                currentNonce,
                expiry
            );

            IVotes(address(vault)).delegateBySig(delegatees[i], currentNonce, expiry, v, r, s);

            uint256 newNonce = IERC20Permit(address(vault)).nonces(alice);
            assertEq(newNonce, i + 1, "Nonce after delegateBySig should increment");
        }

        uint256 finalNonce = IERC20Permit(address(vault)).nonces(alice);
        assertEq(finalNonce, 3, "Final nonce should be 3 after 3 delegateBySig");
    }

    // ============================================
    // TEST: Shared nonce between permit and delegateBySig
    // ============================================

    /// @notice Test that permit and delegateBySig share the same nonce
    function testPermitAndDelegateBySigShareNonce() public {
        (PlasmaVault vault, ) = _deployVaultWithVotes();

        // Alice deposits
        vm.startPrank(alice);
        underlying.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, alice);
        IVotes(address(vault)).delegate(alice);
        vm.stopPrank();

        uint256 deadline = block.timestamp + 1 days;

        // Step 1: Execute permit with nonce 0
        assertEq(IERC20Permit(address(vault)).nonces(alice), 0, "Initial nonce should be 0");
        _executePermit(vault, ALICE_PRIVATE_KEY, alice, bob, 100e18, deadline);
        assertEq(IERC20Permit(address(vault)).nonces(alice), 1, "Nonce after permit should be 1");

        // Step 2: Execute delegateBySig with nonce 1 (updated after permit)
        _executeDelegateBySig(vault, ALICE_PRIVATE_KEY, bob, deadline);
        assertEq(IERC20Permit(address(vault)).nonces(alice), 2, "Nonce after delegateBySig should be 2");

        // Step 3: Execute another permit with nonce 2
        _executePermit(vault, ALICE_PRIVATE_KEY, alice, bob, 200e18, deadline);
        assertEq(IERC20Permit(address(vault)).nonces(alice), 3, "Nonce after second permit should be 3");
    }

    /// @notice Helper to execute permit
    function _executePermit(
        PlasmaVault vault,
        uint256 privateKey,
        address owner,
        address spender,
        uint256 value,
        uint256 deadline
    ) internal {
        uint256 nonce = IERC20Permit(address(vault)).nonces(owner);
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(privateKey, address(vault), owner, spender, value, nonce, deadline);
        IERC20Permit(address(vault)).permit(owner, spender, value, deadline, v, r, s);
    }

    /// @notice Helper to execute delegateBySig
    function _executeDelegateBySig(
        PlasmaVault vault,
        uint256 privateKey,
        address delegatee,
        uint256 expiry
    ) internal {
        address signer = vm.addr(privateKey);
        uint256 nonce = IERC20Permit(address(vault)).nonces(signer);
        (uint8 v, bytes32 r, bytes32 s) = _signDelegation(privateKey, address(vault), delegatee, nonce, expiry);
        IVotes(address(vault)).delegateBySig(delegatee, nonce, expiry, v, r, s);
    }

    /// @notice Test that using permit nonce in delegateBySig fails after permit uses it
    function testCannotUseSameNonceInDelegateBySigAfterPermit() public {
        (PlasmaVault vault, ) = _deployVaultWithVotes();

        // Alice deposits
        vm.startPrank(alice);
        underlying.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, alice);
        IVotes(address(vault)).delegate(alice);
        vm.stopPrank();

        uint256 deadline = block.timestamp + 1 days;
        uint256 nonce = IERC20Permit(address(vault)).nonces(alice);

        // Sign delegation with the same nonce (before permit is executed)
        (uint8 v2, bytes32 r2, bytes32 s2) = _signDelegation(ALICE_PRIVATE_KEY, address(vault), bob, nonce, deadline);

        // Execute permit first - should succeed (consumes nonce)
        _executePermit(vault, ALICE_PRIVATE_KEY, alice, bob, 100e18, deadline);

        // Now delegateBySig with the same nonce should fail
        vm.expectRevert(abi.encodeWithSelector(PlasmaVaultVotesPlugin.InvalidAccountNonce.selector, alice, 1));
        IVotes(address(vault)).delegateBySig(bob, nonce, deadline, v2, r2, s2);
    }

    // ============================================
    // TEST: Replay attack protection
    // ============================================

    /// @notice Test that same permit signature cannot be used twice (replay attack)
    function testPermitReplayAttackPrevented() public {
        (PlasmaVault vault, ) = _deployVaultWithVotes();

        // Alice deposits
        vm.startPrank(alice);
        underlying.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, alice);
        vm.stopPrank();

        uint256 deadline = block.timestamp + 1 days;
        uint256 nonce = IERC20Permit(address(vault)).nonces(alice);

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(
            ALICE_PRIVATE_KEY,
            address(vault),
            alice,
            bob,
            100e18,
            nonce,
            deadline
        );

        // First permit should succeed
        IERC20Permit(address(vault)).permit(alice, bob, 100e18, deadline, v, r, s);

        // Second permit with same signature should fail (nonce already used)
        vm.expectRevert();
        IERC20Permit(address(vault)).permit(alice, bob, 100e18, deadline, v, r, s);
    }

    /// @notice Test that same delegateBySig signature cannot be used twice (replay attack)
    function testDelegateBySigReplayAttackPrevented() public {
        (PlasmaVault vault, ) = _deployVaultWithVotes();

        // Alice deposits and delegates
        vm.startPrank(alice);
        underlying.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, alice);
        IVotes(address(vault)).delegate(alice);
        vm.stopPrank();

        uint256 expiry = block.timestamp + 1 days;
        uint256 nonce = IERC20Permit(address(vault)).nonces(alice);

        (uint8 v, bytes32 r, bytes32 s) = _signDelegation(
            ALICE_PRIVATE_KEY,
            address(vault),
            bob,
            nonce,
            expiry
        );

        // First delegateBySig should succeed
        IVotes(address(vault)).delegateBySig(bob, nonce, expiry, v, r, s);

        // Second delegateBySig with same signature should fail
        vm.expectRevert(abi.encodeWithSelector(PlasmaVaultVotesPlugin.InvalidAccountNonce.selector, alice, 1));
        IVotes(address(vault)).delegateBySig(bob, nonce, expiry, v, r, s);
    }

    // ============================================
    // TEST: Invalid nonce handling
    // ============================================

    /// @notice Test that permit with wrong nonce (too high) fails
    function testPermitWithFutureNonceFails() public {
        (PlasmaVault vault, ) = _deployVaultWithVotes();

        // Alice deposits
        vm.startPrank(alice);
        underlying.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, alice);
        vm.stopPrank();

        uint256 deadline = block.timestamp + 1 days;
        uint256 wrongNonce = 5;  // Current nonce is 0, using 5

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(
            ALICE_PRIVATE_KEY,
            address(vault),
            alice,
            bob,
            100e18,
            wrongNonce,
            deadline
        );

        // Should fail because nonce doesn't match
        vm.expectRevert();
        IERC20Permit(address(vault)).permit(alice, bob, 100e18, deadline, v, r, s);
    }

    /// @notice Test that delegateBySig with wrong nonce (too high) fails
    function testDelegateBySigWithFutureNonceFails() public {
        (PlasmaVault vault, ) = _deployVaultWithVotes();

        // Alice deposits
        vm.startPrank(alice);
        underlying.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, alice);
        IVotes(address(vault)).delegate(alice);
        vm.stopPrank();

        uint256 expiry = block.timestamp + 1 days;
        uint256 wrongNonce = 10;  // Current nonce is 0, using 10

        (uint8 v, bytes32 r, bytes32 s) = _signDelegation(
            ALICE_PRIVATE_KEY,
            address(vault),
            bob,
            wrongNonce,
            expiry
        );

        // Should fail because nonce doesn't match
        vm.expectRevert(abi.encodeWithSelector(PlasmaVaultVotesPlugin.InvalidAccountNonce.selector, alice, 0));
        IVotes(address(vault)).delegateBySig(bob, wrongNonce, expiry, v, r, s);
    }

    /// @notice Test that delegateBySig with past nonce fails
    function testDelegateBySigWithPastNonceFails() public {
        (PlasmaVault vault, ) = _deployVaultWithVotes();

        // Alice deposits
        vm.startPrank(alice);
        underlying.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, alice);
        IVotes(address(vault)).delegate(alice);
        vm.stopPrank();

        uint256 expiry = block.timestamp + 1 days;

        // First, use nonce 0 successfully
        (uint8 v1, bytes32 r1, bytes32 s1) = _signDelegation(
            ALICE_PRIVATE_KEY,
            address(vault),
            bob,
            0,
            expiry
        );
        IVotes(address(vault)).delegateBySig(bob, 0, expiry, v1, r1, s1);

        // Then, use nonce 1 successfully
        (uint8 v2, bytes32 r2, bytes32 s2) = _signDelegation(
            ALICE_PRIVATE_KEY,
            address(vault),
            alice,
            1,
            expiry
        );
        IVotes(address(vault)).delegateBySig(alice, 1, expiry, v2, r2, s2);

        // Now current nonce is 2. Try to use nonce 0 again (past nonce)
        (uint8 v3, bytes32 r3, bytes32 s3) = _signDelegation(
            ALICE_PRIVATE_KEY,
            address(vault),
            bob,
            0,
            expiry
        );

        vm.expectRevert(abi.encodeWithSelector(PlasmaVaultVotesPlugin.InvalidAccountNonce.selector, alice, 2));
        IVotes(address(vault)).delegateBySig(bob, 0, expiry, v3, r3, s3);
    }

    // ============================================
    // TEST: Multiple users have independent nonces
    // ============================================

    /// @notice Test that different users have independent nonces
    function testUsersHaveIndependentNonces() public {
        (PlasmaVault vault, ) = _deployVaultWithVotes();

        // Alice and Bob deposit
        vm.startPrank(alice);
        underlying.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, alice);
        IVotes(address(vault)).delegate(alice);
        vm.stopPrank();

        vm.startPrank(bob);
        underlying.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, bob);
        IVotes(address(vault)).delegate(bob);
        vm.stopPrank();

        // Both start at nonce 0
        assertEq(IERC20Permit(address(vault)).nonces(alice), 0, "Alice initial nonce should be 0");
        assertEq(IERC20Permit(address(vault)).nonces(bob), 0, "Bob initial nonce should be 0");

        uint256 deadline = block.timestamp + 1 days;

        // Alice does 3 permits
        for (uint256 i = 0; i < 3; i++) {
            uint256 nonce = IERC20Permit(address(vault)).nonces(alice);
            (uint8 v, bytes32 r, bytes32 s) = _signPermit(
                ALICE_PRIVATE_KEY,
                address(vault),
                alice,
                bob,
                100e18 + i,
                nonce,
                deadline
            );
            IERC20Permit(address(vault)).permit(alice, bob, 100e18 + i, deadline, v, r, s);
        }

        // Alice nonce should be 3, Bob should still be 0
        assertEq(IERC20Permit(address(vault)).nonces(alice), 3, "Alice nonce should be 3");
        assertEq(IERC20Permit(address(vault)).nonces(bob), 0, "Bob nonce should still be 0");

        // Bob does 1 delegateBySig
        uint256 bobNonce = IERC20Permit(address(vault)).nonces(bob);
        (uint8 vBob, bytes32 rBob, bytes32 sBob) = _signDelegation(
            BOB_PRIVATE_KEY,
            address(vault),
            alice,
            bobNonce,
            deadline
        );
        IVotes(address(vault)).delegateBySig(alice, bobNonce, deadline, vBob, rBob, sBob);

        // Alice nonce should still be 3, Bob should be 1
        assertEq(IERC20Permit(address(vault)).nonces(alice), 3, "Alice nonce should remain 3");
        assertEq(IERC20Permit(address(vault)).nonces(bob), 1, "Bob nonce should be 1");
    }

    // ============================================
    // TEST: Nonce with expired signatures
    // ============================================

    /// @notice Test that expired permit does not consume nonce
    function testExpiredPermitDoesNotConsumeNonce() public {
        (PlasmaVault vault, ) = _deployVaultWithVotes();

        // Alice deposits
        vm.startPrank(alice);
        underlying.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, alice);
        vm.stopPrank();

        uint256 nonceBefore = IERC20Permit(address(vault)).nonces(alice);

        // Create permit with deadline in the past
        uint256 deadline = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(
            ALICE_PRIVATE_KEY,
            address(vault),
            alice,
            bob,
            100e18,
            nonceBefore,
            deadline
        );

        // Should revert with expired deadline
        vm.expectRevert();
        IERC20Permit(address(vault)).permit(alice, bob, 100e18, deadline, v, r, s);

        // Nonce should remain unchanged
        uint256 nonceAfter = IERC20Permit(address(vault)).nonces(alice);
        assertEq(nonceAfter, nonceBefore, "Nonce should not change on expired permit");
    }

    /// @notice Test that expired delegateBySig does not consume nonce
    function testExpiredDelegateBySigDoesNotConsumeNonce() public {
        (PlasmaVault vault, ) = _deployVaultWithVotes();

        // Alice deposits
        vm.startPrank(alice);
        underlying.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, alice);
        IVotes(address(vault)).delegate(alice);
        vm.stopPrank();

        uint256 nonceBefore = IERC20Permit(address(vault)).nonces(alice);

        // Create delegation with expiry in the past
        uint256 expiry = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) = _signDelegation(
            ALICE_PRIVATE_KEY,
            address(vault),
            bob,
            nonceBefore,
            expiry
        );

        // Should revert with expired signature
        vm.expectRevert(abi.encodeWithSelector(IVotes.VotesExpiredSignature.selector, expiry));
        IVotes(address(vault)).delegateBySig(bob, nonceBefore, expiry, v, r, s);

        // Nonce should remain unchanged
        uint256 nonceAfter = IERC20Permit(address(vault)).nonces(alice);
        assertEq(nonceAfter, nonceBefore, "Nonce should not change on expired delegateBySig");
    }

    // ============================================
    // TEST: Nonce in vault without votes plugin
    // ============================================

    /// @notice Test that nonce works for permit in vault without votes plugin
    function testNonceWorksInVaultWithoutVotesPlugin() public {
        // Deploy vault without votes plugin
        IporFusionAccessManager accessManager = RoleLib.createAccessManager(usersToRoles, 0, vm);
        address withdrawManager = address(new WithdrawManager(address(accessManager)));

        vm.startPrank(ATOMIST);

        PlasmaVaultInitData memory initData = PlasmaVaultInitData({
            assetName: VAULT_NAME,
            assetSymbol: "PVT",
            underlyingToken: address(underlying),
            priceOracleMiddleware: address(priceOracle),
            feeConfig: FeeConfigHelper.createZeroFeeConfig(),
            accessManager: address(accessManager),
            plasmaVaultBase: address(plasmaVaultBase),
            withdrawManager: withdrawManager,
            plasmaVaultVotesPlugin: address(0)  // No votes plugin
        });

        PlasmaVault vault = new PlasmaVault();
        vault.proxyInitialize(initData);
        vm.stopPrank();

        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(vault), accessManager, withdrawManager);

        // Alice deposits
        vm.startPrank(alice);
        underlying.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, alice);
        vm.stopPrank();

        // Initial nonce should be 0
        uint256 nonce0 = IERC20Permit(address(vault)).nonces(alice);
        assertEq(nonce0, 0, "Initial nonce should be 0");

        // Permit should work and increment nonce
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(
            ALICE_PRIVATE_KEY,
            address(vault),
            alice,
            bob,
            100e18,
            nonce0,
            deadline
        );

        IERC20Permit(address(vault)).permit(alice, bob, 100e18, deadline, v, r, s);

        uint256 nonce1 = IERC20Permit(address(vault)).nonces(alice);
        assertEq(nonce1, 1, "Nonce after permit should be 1");
    }

    // ============================================
    // TEST: Large nonce values
    // ============================================

    /// @notice Test nonce works correctly after many operations
    function testNonceWorksAfterManyOperations() public {
        (PlasmaVault vault, ) = _deployVaultWithVotes();

        // Alice deposits
        vm.startPrank(alice);
        underlying.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, alice);
        IVotes(address(vault)).delegate(alice);
        vm.stopPrank();

        uint256 deadline = block.timestamp + 1 days;
        uint256 numOperations = 20;

        // Alternate between permit and delegateBySig
        for (uint256 i = 0; i < numOperations; i++) {
            uint256 currentNonce = IERC20Permit(address(vault)).nonces(alice);
            assertEq(currentNonce, i, "Nonce should match iteration");

            if (i % 2 == 0) {
                // Do permit
                (uint8 v, bytes32 r, bytes32 s) = _signPermit(
                    ALICE_PRIVATE_KEY,
                    address(vault),
                    alice,
                    bob,
                    100e18 + i,
                    currentNonce,
                    deadline
                );
                IERC20Permit(address(vault)).permit(alice, bob, 100e18 + i, deadline, v, r, s);
            } else {
                // Do delegateBySig
                address delegatee = i % 4 == 1 ? bob : alice;
                (uint8 v, bytes32 r, bytes32 s) = _signDelegation(
                    ALICE_PRIVATE_KEY,
                    address(vault),
                    delegatee,
                    currentNonce,
                    deadline
                );
                IVotes(address(vault)).delegateBySig(delegatee, currentNonce, deadline, v, r, s);
            }
        }

        uint256 finalNonce = IERC20Permit(address(vault)).nonces(alice);
        assertEq(finalNonce, numOperations, "Final nonce should equal number of operations");
    }

    // ============================================
    // TEST: Nonce behavior with Context Manager
    // ============================================

    /// @notice Test that permit uses owner's nonce, not _msgSender() even with context
    /// @dev This verifies that permit is safe to call via Context Manager
    function testPermitUsesOwnerNonceNotMsgSender() public {
        (PlasmaVault vault, ) = _deployVaultWithVotes();

        // Alice deposits
        vm.startPrank(alice);
        underlying.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, alice);
        vm.stopPrank();

        // Get Alice's nonce
        uint256 aliceNonce = IERC20Permit(address(vault)).nonces(alice);
        assertEq(aliceNonce, 0, "Alice's nonce should be 0");

        // Bob's nonce should also be 0
        uint256 bobNonce = IERC20Permit(address(vault)).nonces(bob);
        assertEq(bobNonce, 0, "Bob's nonce should be 0");

        // Alice signs permit for herself
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(
            ALICE_PRIVATE_KEY,
            address(vault),
            alice,  // owner = alice
            bob,    // spender = bob
            100e18,
            aliceNonce,
            deadline
        );

        // Bob calls permit on behalf of Alice (simulating context manager scenario)
        // The permit should still use Alice's nonce because owner=alice
        vm.prank(bob);
        IERC20Permit(address(vault)).permit(alice, bob, 100e18, deadline, v, r, s);

        // Alice's nonce should have increased (not Bob's)
        assertEq(IERC20Permit(address(vault)).nonces(alice), 1, "Alice's nonce should be 1");
        assertEq(IERC20Permit(address(vault)).nonces(bob), 0, "Bob's nonce should still be 0");
    }

    /// @notice Test that delegateBySig uses signer's nonce, not msg.sender
    /// @dev This verifies that delegateBySig is safe regardless of who calls it
    function testDelegateBySigUsesSignerNonceNotMsgSender() public {
        (PlasmaVault vault, ) = _deployVaultWithVotes();

        // Alice deposits and delegates
        vm.startPrank(alice);
        underlying.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, alice);
        IVotes(address(vault)).delegate(alice);
        vm.stopPrank();

        // Get nonces
        uint256 aliceNonce = IERC20Permit(address(vault)).nonces(alice);
        uint256 bobNonce = IERC20Permit(address(vault)).nonces(bob);
        assertEq(aliceNonce, 0, "Alice's nonce should be 0");
        assertEq(bobNonce, 0, "Bob's nonce should be 0");

        // Alice signs delegation
        uint256 expiry = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _signDelegation(
            ALICE_PRIVATE_KEY,
            address(vault),
            bob,        // delegatee
            aliceNonce, // Alice's nonce
            expiry
        );

        // Bob (or anyone) calls delegateBySig - should use Alice's nonce
        vm.prank(bob);
        IVotes(address(vault)).delegateBySig(bob, aliceNonce, expiry, v, r, s);

        // Alice's nonce should have increased (not Bob's)
        assertEq(IERC20Permit(address(vault)).nonces(alice), 1, "Alice's nonce should be 1");
        assertEq(IERC20Permit(address(vault)).nonces(bob), 0, "Bob's nonce should still be 0");

        // Verify delegation worked
        assertEq(IVotes(address(vault)).delegates(alice), bob, "Alice should have delegated to Bob");
    }

    /// @notice Test that permit with wrong owner fails even if signed correctly
    /// @dev Ensures permit cannot be manipulated via context
    function testPermitFailsWithWrongOwner() public {
        (PlasmaVault vault, ) = _deployVaultWithVotes();

        // Alice deposits
        vm.startPrank(alice);
        underlying.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, alice);
        vm.stopPrank();

        uint256 deadline = block.timestamp + 1 days;

        // Alice signs permit for herself
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(
            ALICE_PRIVATE_KEY,
            address(vault),
            alice,  // Alice signs for herself
            bob,
            100e18,
            0,
            deadline
        );

        // Try to use Alice's signature but claim Bob is the owner - should fail
        vm.expectRevert();
        IERC20Permit(address(vault)).permit(bob, alice, 100e18, deadline, v, r, s);
    }
}

/// @notice Simple mock ERC20 for testing
contract MockERC20ForNonceTest is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
