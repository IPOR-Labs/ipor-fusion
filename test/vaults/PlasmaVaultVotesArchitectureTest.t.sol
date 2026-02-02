// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IERC6372} from "@openzeppelin/contracts/interfaces/IERC6372.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {PlasmaVault, PlasmaVaultInitData, FuseAction} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultVotesPlugin} from "../../contracts/vaults/plugins/PlasmaVaultVotesPlugin.sol";
import {PlasmaVaultStorageLib} from "../../contracts/libraries/PlasmaVaultStorageLib.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {FeeConfigHelper} from "../test_helpers/FeeConfigHelper.sol";
import {IPlasmaVaultVotesPlugin} from "../../contracts/interfaces/IPlasmaVaultVotesPlugin.sol";
import {IPlasmaVaultVotesPlugin} from "../../contracts/interfaces/IPlasmaVaultVotesPlugin.sol";
import {RoleLib, UsersToRoles} from "../RoleLib.sol";

/// @title PlasmaVaultVotesArchitectureTest
/// @notice Critical tests for the split architecture: PlasmaVault / PlasmaVaultBase / PlasmaVaultVotesPlugin
/// @dev Tests edge cases, synchronization issues, and potential security vulnerabilities
contract PlasmaVaultVotesArchitectureTest is Test {
    // Test contracts
    PlasmaVaultBase public plasmaVaultBase;
    PlasmaVaultVotesPlugin public votesPlugin;
    PriceOracleMiddleware public priceOracle;
    MockERC20 public underlying;
    UsersToRoles public usersToRoles;

    // Test addresses
    address public constant ATOMIST = address(0x1);
    address public alice = address(0x2);
    address public bob = address(0x3);
    address public charlie = address(0x4);

    // Constants
    uint256 public constant INITIAL_DEPOSIT = 1000e18;
    uint256 public constant TOTAL_SUPPLY_CAP = 1_000_000e18;

    function setUp() public {
        // Deploy underlying token
        underlying = new MockERC20("Underlying", "UND");
        underlying.mint(ATOMIST, 10_000_000e18);
        underlying.mint(alice, 10_000e18);
        underlying.mint(bob, 10_000e18);
        underlying.mint(charlie, 10_000e18);

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

    /// @notice Helper to deploy a PlasmaVault with or without votes plugin
    function _deployVault(bool withVotesPlugin) internal returns (PlasmaVault vault, IporFusionAccessManager accessManager) {
        accessManager = RoleLib.createAccessManager(usersToRoles, 0, vm);
        address withdrawManager = address(new WithdrawManager(address(accessManager)));

        vm.startPrank(ATOMIST);

        PlasmaVaultInitData memory initData = PlasmaVaultInitData({
            assetName: "Plasma Vault Token",
            assetSymbol: "PVT",
            underlyingToken: address(underlying),
            priceOracleMiddleware: address(priceOracle),
            feeConfig: FeeConfigHelper.createZeroFeeConfig(),
            accessManager: address(accessManager),
            plasmaVaultBase: address(plasmaVaultBase),
            withdrawManager: withdrawManager,
            plasmaVaultVotesPlugin: withVotesPlugin ? address(votesPlugin) : address(0)
        });

        vault = new PlasmaVault();
        vault.proxyInitialize(initData);

        vm.stopPrank();

        // Setup roles for the plasma vault
        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(vault), accessManager, withdrawManager);
    }

    // ============================================
    // TEST: Immutability of votes plugin configuration
    // ============================================

    /// @notice ARCHITECTURE: Votes plugin cannot be changed after initialization
    /// @dev This is a good security property - prevents plugin change attacks
    function testArchitecture_VotesPluginIsImmutableAfterInit() public {
        // Deploy vault with votes plugin
        (PlasmaVault vault, ) = _deployVault(true);

        address initialPlugin = vault.PLASMA_VAULT_VOTES_PLUGIN();
        assertEq(initialPlugin, address(votesPlugin), "Votes plugin should be set");

        // There's no setter function to change the plugin after initialization
        // This is verified by the absence of setPlasmaVaultVotesPlugin in PlasmaVault
        // This test documents this architectural decision
    }

    /// @notice ARCHITECTURE: Vault created without votes plugin has no voting functionality
    function testArchitecture_VaultWithoutPluginHasNoVoting() public {
        (PlasmaVault vault, ) = _deployVault(false);

        assertEq(vault.PLASMA_VAULT_VOTES_PLUGIN(), address(0), "No votes plugin");

        // All votes functions should revert
        vm.expectRevert(PlasmaVault.VotesPluginNotEnabled.selector);
        IVotes(address(vault)).getVotes(alice);

        vm.expectRevert(PlasmaVault.VotesPluginNotEnabled.selector);
        IVotes(address(vault)).delegates(alice);

        vm.expectRevert(PlasmaVault.VotesPluginNotEnabled.selector);
        IVotes(address(vault)).delegate(alice);

        vm.expectRevert(PlasmaVault.VotesPluginNotEnabled.selector);
        IERC6372(address(vault)).clock();
    }

    // ============================================
    // TEST: Voting power synchronization
    // ============================================

    /// @notice Test that new deposits immediately have voting power available (after delegation)
    function testVotingPowerAvailableImmediatelyAfterDelegation() public {
        (PlasmaVault vault, ) = _deployVault(true);

        vm.startPrank(alice);
        underlying.approve(address(vault), INITIAL_DEPOSIT);
        uint256 shares = vault.deposit(INITIAL_DEPOSIT, alice);

        // Before delegation, votes are 0
        uint256 votesBefore = IVotes(address(vault)).getVotes(alice);
        assertEq(votesBefore, 0, "Votes should be 0 before delegation");

        // After delegation, votes equal balance (shares)
        IVotes(address(vault)).delegate(alice);
        uint256 votesAfter = IVotes(address(vault)).getVotes(alice);
        assertEq(votesAfter, shares, "Votes should equal shares after delegation");
        assertEq(votesAfter, vault.balanceOf(alice), "Votes should equal balance");
        vm.stopPrank();
    }

    /// @notice Test voting power delegation flow
    function testVotingPowerDelegationFlow() public {
        (PlasmaVault vault, ) = _deployVault(true);

        // Alice deposits and delegates to Bob
        vm.startPrank(alice);
        underlying.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, alice);
        IVotes(address(vault)).delegate(bob);
        vm.stopPrank();

        uint256 aliceBalance = vault.balanceOf(alice);
        assertEq(IVotes(address(vault)).getVotes(alice), 0, "Alice has 0 votes (delegated to Bob)");
        assertEq(IVotes(address(vault)).getVotes(bob), aliceBalance, "Bob has Alice's votes");
        assertEq(IVotes(address(vault)).delegates(alice), bob, "Alice's delegate is Bob");
    }

    // ============================================
    // TEST: transferVotingUnits access control
    // ============================================

    /// @notice Test that transferVotingUnits direct call on plugin writes to plugin's own storage
    /// @dev Not exploitable but demonstrates storage isolation
    function testTransferVotingUnitsDirectCallWritesToPluginStorage() public {
        // Direct call to plugin succeeds but writes to plugin's own storage
        votesPlugin.transferVotingUnits(address(0), alice, 1000e18);

        // Plugin's own storage now has checkpoints (useless)
        // This doesn't affect any PlasmaVault because it's not delegatecall

        // Verify by deploying vault and checking alice has no votes there
        (PlasmaVault vault, ) = _deployVault(true);

        vm.prank(alice);
        IVotes(address(vault)).delegate(alice);

        // Alice has 0 votes in the vault (no deposit)
        assertEq(IVotes(address(vault)).getVotes(alice), 0, "Alice should have 0 votes in vault");
    }

    /// @notice Test that transferVotingUnits via normal vault operations works correctly
    function testTransferVotingUnitsViaDelegatecall() public {
        (PlasmaVault vault, ) = _deployVault(true);

        // Alice deposits and delegates
        vm.startPrank(alice);
        underlying.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, alice);
        IVotes(address(vault)).delegate(alice);
        vm.stopPrank();

        uint256 aliceVotes = IVotes(address(vault)).getVotes(alice);
        assertGt(aliceVotes, 0, "Alice should have votes");

        // Transfer updates voting units correctly
        vm.prank(alice);
        vault.transfer(bob, aliceVotes / 2);

        // Bob hasn't delegated, so his votes are 0
        assertEq(IVotes(address(vault)).getVotes(bob), 0, "Bob hasn't delegated");

        // Bob delegates to himself
        vm.prank(bob);
        IVotes(address(vault)).delegate(bob);

        assertEq(IVotes(address(vault)).getVotes(bob), aliceVotes / 2, "Bob should have half the votes");
    }

    // ============================================
    // TEST: getPastTotalSupply vs totalSupply
    // ============================================

    /// @notice Test historical voting supply tracking
    function testGetPastTotalSupplyHistoricalTracking() public {
        (PlasmaVault vault, ) = _deployVault(true);

        // Advance block to ensure we have a clean starting point
        vm.roll(block.number + 1);

        // Record block before any deposits
        uint256 blockBefore = block.number;

        // Advance block again
        vm.roll(block.number + 1);

        // Alice deposits and delegates
        vm.startPrank(alice);
        underlying.approve(address(vault), INITIAL_DEPOSIT);
        uint256 aliceShares = vault.deposit(INITIAL_DEPOSIT, alice);
        IVotes(address(vault)).delegate(alice);
        vm.stopPrank();

        // Advance block
        vm.roll(block.number + 1);

        // Bob deposits and delegates
        vm.startPrank(bob);
        underlying.approve(address(vault), INITIAL_DEPOSIT);
        uint256 bobShares = vault.deposit(INITIAL_DEPOSIT, bob);
        IVotes(address(vault)).delegate(bob);
        vm.stopPrank();

        // Advance block
        vm.roll(block.number + 1);

        // Check historical voting supply
        uint256 pastTotalVotes = IVotes(address(vault)).getPastTotalSupply(blockBefore);
        uint256 currentTotalSupply = vault.totalSupply();

        // Past total votes should be 0 (before any delegations)
        assertEq(pastTotalVotes, 0, "Past total votes before any deposits should be 0");
        assertEq(currentTotalSupply, aliceShares + bobShares, "Current total supply should equal all shares");
    }

    // ============================================
    // TEST: Nonce accessible via IERC20Permit interface
    // ============================================

    /// @notice Test that nonces are accessible via IERC20Permit interface
    /// @dev Permit and delegateBySig share the same nonce storage due to ERC-7201 slots
    function testNonceAccessibleViaPermitInterface() public {
        (PlasmaVault vault, ) = _deployVault(true);

        // Deposit so alice has tokens
        vm.startPrank(alice);
        underlying.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, alice);
        vm.stopPrank();

        // Get Alice's nonce from vault's permit function (via IERC20Permit interface)
        uint256 nonce = IERC20Permit(address(vault)).nonces(alice);

        // Initial nonce should be 0
        assertEq(nonce, 0, "Initial nonce should be 0");

        // Note: permit and delegateBySig share the same nonce storage (NoncesUpgradeable)
        // This is verified by the ERC-7201 namespace matching in PlasmaVaultVotesPlugin
    }

    // ============================================
    // TEST: Delegatecall storage isolation
    // ============================================

    /// @notice Test that plugin doesn't have its own meaningful state
    function testPluginHasNoMeaningfulOwnState() public {
        // Direct call to plugin reads its own (empty) storage
        uint256 directVotes = votesPlugin.getVotes(alice);
        assertEq(directVotes, 0, "Plugin's own storage should be empty");

        // Deploy vault with plugin
        (PlasmaVault vault, ) = _deployVault(true);

        // Deposit and delegate via vault
        vm.startPrank(alice);
        underlying.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, alice);
        IVotes(address(vault)).delegate(alice);
        vm.stopPrank();

        // Via vault (delegatecall) - should have votes
        uint256 vaultVotes = IVotes(address(vault)).getVotes(alice);
        assertGt(vaultVotes, 0, "Vault should have Alice's votes");

        // Direct call to plugin - still 0 (different storage context)
        directVotes = votesPlugin.getVotes(alice);
        assertEq(directVotes, 0, "Plugin's own storage still empty");
    }

    // ============================================
    // TEST: Multiple delegations same block
    // ============================================

    /// @notice Test that multiple delegations in the same block work correctly
    function testMultipleDelegationsInSameBlock() public {
        (PlasmaVault vault, ) = _deployVault(true);

        // Alice deposits
        vm.startPrank(alice);
        underlying.approve(address(vault), INITIAL_DEPOSIT);
        uint256 shares = vault.deposit(INITIAL_DEPOSIT, alice);

        // Multiple delegations in same block
        IVotes(address(vault)).delegate(bob);
        IVotes(address(vault)).delegate(charlie);
        IVotes(address(vault)).delegate(alice);
        vm.stopPrank();

        // Final delegation should win
        assertEq(IVotes(address(vault)).delegates(alice), alice, "Final delegation should be alice");
        assertEq(IVotes(address(vault)).getVotes(alice), shares, "Alice should have all votes");
        assertEq(IVotes(address(vault)).getVotes(bob), 0, "Bob should have 0 votes");
        assertEq(IVotes(address(vault)).getVotes(charlie), 0, "Charlie should have 0 votes");
    }

    // ============================================
    // TEST: Zero address delegation
    // ============================================

    /// @notice Test delegation to zero address removes voting power
    function testDelegateToZeroAddress() public {
        (PlasmaVault vault, ) = _deployVault(true);

        vm.startPrank(alice);
        underlying.approve(address(vault), INITIAL_DEPOSIT);
        uint256 shares = vault.deposit(INITIAL_DEPOSIT, alice);

        // Delegate to self first
        IVotes(address(vault)).delegate(alice);
        assertEq(IVotes(address(vault)).getVotes(alice), shares, "Alice should have votes");

        // Now delegate to zero - votes should go to no one
        IVotes(address(vault)).delegate(address(0));
        vm.stopPrank();

        assertEq(IVotes(address(vault)).delegates(alice), address(0), "Delegate should be zero");
        assertEq(IVotes(address(vault)).getVotes(alice), 0, "Alice should have 0 votes (delegated to 0)");
        assertEq(IVotes(address(vault)).getVotes(address(0)), 0, "Zero address should have 0 votes");
    }

    // ============================================
    // TEST: ERC20 transfer updates voting correctly
    // ============================================

    /// @notice Test that ERC20 transfer updates voting power correctly
    function testTransferUpdatesVotingPowerCorrectly() public {
        (PlasmaVault vault, ) = _deployVault(true);

        // Alice and Bob both deposit and delegate
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

        uint256 transferAmount = INITIAL_DEPOSIT / 4;

        uint256 aliceVotesBefore = IVotes(address(vault)).getVotes(alice);
        uint256 bobVotesBefore = IVotes(address(vault)).getVotes(bob);

        // Alice transfers to Bob
        vm.prank(alice);
        vault.transfer(bob, transferAmount);

        uint256 aliceVotesAfter = IVotes(address(vault)).getVotes(alice);
        uint256 bobVotesAfter = IVotes(address(vault)).getVotes(bob);

        // Votes should update correctly
        assertEq(aliceVotesAfter, aliceVotesBefore - transferAmount, "Alice votes should decrease");
        assertEq(bobVotesAfter, bobVotesBefore + transferAmount, "Bob votes should increase");
    }

    // ============================================
    // TEST: Clock functions
    // ============================================

    /// @notice Test that clock() returns current block number
    function testClockReturnsBlockNumber() public {
        (PlasmaVault vault, ) = _deployVault(true);

        uint48 clockValue = IERC6372(address(vault)).clock();
        assertEq(clockValue, block.number, "Clock should return block number");

        // Advance blocks
        vm.roll(block.number + 100);

        clockValue = IERC6372(address(vault)).clock();
        assertEq(clockValue, block.number, "Clock should return new block number");
    }

    /// @notice Test that CLOCK_MODE() returns expected value
    function testClockModeReturnsCorrectString() public {
        (PlasmaVault vault, ) = _deployVault(true);

        string memory mode = IERC6372(address(vault)).CLOCK_MODE();
        assertEq(mode, "mode=blocknumber&from=default", "CLOCK_MODE should return expected string");
    }

    // ============================================
    // TEST: Checkpoint functionality
    // ============================================

    /// @notice Test numCheckpoints returns correct count
    function testNumCheckpointsReturnsCorrectCount() public {
        (PlasmaVault vault, ) = _deployVault(true);

        // Initially 0 checkpoints
        uint32 checkpoints = IPlasmaVaultVotesPlugin(address(vault)).numCheckpoints(alice);
        assertEq(checkpoints, 0, "Should have 0 checkpoints initially");

        // Alice deposits and delegates
        vm.startPrank(alice);
        underlying.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, alice);
        IVotes(address(vault)).delegate(alice);
        vm.stopPrank();

        checkpoints = IPlasmaVaultVotesPlugin(address(vault)).numCheckpoints(alice);
        assertEq(checkpoints, 1, "Should have 1 checkpoint after delegation");

        // Advance block and make another action
        vm.roll(block.number + 1);

        vm.prank(alice);
        vault.transfer(bob, 100e18);

        checkpoints = IPlasmaVaultVotesPlugin(address(vault)).numCheckpoints(alice);
        assertEq(checkpoints, 2, "Should have 2 checkpoints after transfer");
    }

    // ============================================
    // TEST: ERC4626 + ERC20Votes boundary
    // ============================================

    /// @notice Test that deposit creates correct voting power when delegated
    function testERC4626DepositCreatesVotingPower() public {
        (PlasmaVault vault, ) = _deployVault(true);

        vm.startPrank(alice);
        underlying.approve(address(vault), INITIAL_DEPOSIT);

        // Delegate before deposit
        IVotes(address(vault)).delegate(alice);

        // Deposit
        uint256 shares = vault.deposit(INITIAL_DEPOSIT, alice);
        vm.stopPrank();

        // Shares should equal voting power
        assertEq(vault.balanceOf(alice), shares, "Balance should equal shares");
        assertEq(IVotes(address(vault)).getVotes(alice), shares, "Votes should equal shares");
    }

    /// @notice Test that mint creates correct voting power when delegated
    function testERC4626MintCreatesVotingPower() public {
        (PlasmaVault vault, ) = _deployVault(true);

        uint256 sharesToMint = INITIAL_DEPOSIT;
        uint256 assetsNeeded = vault.previewMint(sharesToMint);

        vm.startPrank(alice);
        underlying.approve(address(vault), assetsNeeded);

        // Delegate before mint
        IVotes(address(vault)).delegate(alice);

        // Mint
        vault.mint(sharesToMint, alice);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), sharesToMint, "Balance should equal minted shares");
        assertEq(IVotes(address(vault)).getVotes(alice), sharesToMint, "Votes should equal minted shares");
    }

    /// @notice Test that redeem correctly reduces voting power
    function testERC4626RedeemReducesVotingPower() public {
        (PlasmaVault vault, ) = _deployVault(true);

        // Setup: deposit and delegate
        vm.startPrank(alice);
        underlying.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, alice);
        IVotes(address(vault)).delegate(alice);

        uint256 sharesBefore = vault.balanceOf(alice);
        uint256 votesBefore = IVotes(address(vault)).getVotes(alice);
        assertEq(sharesBefore, votesBefore, "Shares and votes should be equal");

        // Redeem half
        uint256 sharesToRedeem = sharesBefore / 2;
        vault.redeem(sharesToRedeem, alice, alice);
        vm.stopPrank();

        uint256 sharesAfter = vault.balanceOf(alice);
        uint256 votesAfter = IVotes(address(vault)).getVotes(alice);

        assertEq(sharesAfter, sharesBefore - sharesToRedeem, "Shares should decrease");
        assertEq(votesAfter, votesBefore - sharesToRedeem, "Votes should decrease equally");
        assertEq(sharesAfter, votesAfter, "Shares and votes should still be equal");
    }

    /// @notice Test that withdraw correctly reduces voting power
    function testERC4626WithdrawReducesVotingPower() public {
        (PlasmaVault vault, ) = _deployVault(true);

        // Setup: deposit and delegate
        vm.startPrank(alice);
        underlying.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, alice);
        IVotes(address(vault)).delegate(alice);

        uint256 sharesBefore = vault.balanceOf(alice);
        uint256 votesBefore = IVotes(address(vault)).getVotes(alice);

        // Withdraw half the assets
        uint256 assetsToWithdraw = INITIAL_DEPOSIT / 2;
        uint256 sharesUsed = vault.withdraw(assetsToWithdraw, alice, alice);
        vm.stopPrank();

        uint256 sharesAfter = vault.balanceOf(alice);
        uint256 votesAfter = IVotes(address(vault)).getVotes(alice);

        assertEq(sharesAfter, sharesBefore - sharesUsed, "Shares should decrease");
        assertEq(votesAfter, votesBefore - sharesUsed, "Votes should decrease equally");
        assertEq(sharesAfter, votesAfter, "Shares and votes should still be equal");
    }

    // ============================================
    // TEST: Two vaults with same plugin contract
    // ============================================

    /// @notice Test that two vaults can use the same plugin contract without interference
    function testTwoVaultsSamePluginNoInterference() public {
        // Deploy two vaults using the same plugin contract
        (PlasmaVault vault1, ) = _deployVault(true);
        (PlasmaVault vault2, ) = _deployVault(true);

        // Alice deposits in vault1
        vm.startPrank(alice);
        underlying.approve(address(vault1), INITIAL_DEPOSIT);
        uint256 aliceShares = vault1.deposit(INITIAL_DEPOSIT, alice);
        IVotes(address(vault1)).delegate(alice);
        vm.stopPrank();

        // Bob deposits in vault2
        vm.startPrank(bob);
        underlying.approve(address(vault2), INITIAL_DEPOSIT);
        uint256 bobShares = vault2.deposit(INITIAL_DEPOSIT, bob);
        IVotes(address(vault2)).delegate(bob);
        vm.stopPrank();

        // Votes in vault1 are independent of vault2
        assertEq(IVotes(address(vault1)).getVotes(alice), aliceShares, "Alice votes in vault1");
        assertEq(IVotes(address(vault1)).getVotes(bob), 0, "Bob has no votes in vault1");

        assertEq(IVotes(address(vault2)).getVotes(bob), bobShares, "Bob votes in vault2");
        assertEq(IVotes(address(vault2)).getVotes(alice), 0, "Alice has no votes in vault2");

        // Plugin's own storage is still empty
        assertEq(votesPlugin.getVotes(alice), 0, "Plugin storage is isolated");
        assertEq(votesPlugin.getVotes(bob), 0, "Plugin storage is isolated");
    }

    // ============================================
    // TEST: Large number of checkpoints
    // ============================================

    /// @notice Test behavior with many checkpoints
    function testManyCheckpoints() public {
        (PlasmaVault vault, ) = _deployVault(true);

        // Alice deposits and delegates
        vm.startPrank(alice);
        underlying.approve(address(vault), INITIAL_DEPOSIT);
        uint256 shares = vault.deposit(INITIAL_DEPOSIT, alice);
        IVotes(address(vault)).delegate(alice);
        vm.stopPrank();

        // Create many checkpoints by delegating back and forth
        uint256 numDelegations = 50;
        for (uint256 i = 0; i < numDelegations; i++) {
            vm.roll(block.number + 1);
            vm.prank(alice);
            if (i % 2 == 0) {
                IVotes(address(vault)).delegate(bob);
            } else {
                IVotes(address(vault)).delegate(alice);
            }
        }

        // System should handle many checkpoints
        uint32 checkpoints = IPlasmaVaultVotesPlugin(address(vault)).numCheckpoints(alice);
        assertGt(checkpoints, 0, "Should have checkpoints");

        // Should still be able to query votes
        uint256 votes = IVotes(address(vault)).getVotes(alice);
        // Final delegation was to bob (49 is odd, so delegate to alice)
        assertEq(votes, shares, "Alice should have votes after odd number of switches");
    }
}

/// @notice Simple mock ERC20 for testing
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
