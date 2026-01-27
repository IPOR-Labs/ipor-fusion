// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {PlasmaVault, PlasmaVaultInitData} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultVotesExtension} from "../../contracts/vaults/PlasmaVaultVotesExtension.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {FeeConfigHelper} from "../test_helpers/FeeConfigHelper.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPlasmaVaultVotesExtension} from "../../contracts/interfaces/IPlasmaVaultVotesExtension.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {RoleLib, UsersToRoles} from "../RoleLib.sol";

contract MockToken is ERC20 {
    uint8 private _decimals;

    constructor(uint8 decimals_) ERC20("Mock", "MCK") {
        _decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}

contract PlasmaVaultVotesExtensionTest is Test {
    PlasmaVault public plasmaVault;
    PlasmaVaultVotesExtension public votesExtension;
    MockToken public underlyingToken;
    IporFusionAccessManager public accessManager;
    PriceOracleMiddleware public priceOracle;
    address public withdrawManager;
    UsersToRoles public usersToRoles;

    address public constant ATOMIST = address(0x1111);
    address public constant USER1 = address(0x2222);
    address public constant USER2 = address(0x3333);
    address public constant USER3 = address(0x4444);

    function setUp() public {
        underlyingToken = new MockToken(18);

        // Setup users to roles
        usersToRoles.superAdmin = ATOMIST;
        usersToRoles.atomist = ATOMIST;
        usersToRoles.alphas = new address[](0);
        usersToRoles.performanceFeeManagers = new address[](0);
        usersToRoles.managementFeeManagers = new address[](0);
        usersToRoles.feeTimelock = 0;

        accessManager = RoleLib.createAccessManager(usersToRoles, 0, vm);
        withdrawManager = address(new WithdrawManager(address(accessManager)));

        // Create price oracle
        priceOracle = new PriceOracleMiddleware(address(0));
        priceOracle.initialize(ATOMIST);

        votesExtension = new PlasmaVaultVotesExtension();

        vm.startPrank(ATOMIST);
        plasmaVault = new PlasmaVault();
        plasmaVault.proxyInitialize(
            PlasmaVaultInitData(
                "Test Vault",
                "TV",
                address(underlyingToken),
                address(priceOracle),
                FeeConfigHelper.createZeroFeeConfig(),
                address(accessManager),
                address(new PlasmaVaultBase()),
                address(0),
                withdrawManager,
                address(votesExtension)
            )
        );
        vm.stopPrank();

        // Setup roles for the plasma vault
        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(plasmaVault), accessManager, withdrawManager);

        // Mint tokens to users
        underlyingToken.mint(USER1, 1000 ether);
        underlyingToken.mint(USER2, 2000 ether);
        underlyingToken.mint(USER3, 500 ether);
    }

    function testVotesExtensionEnabled() public view {
        address extension = plasmaVault.PLASMA_VAULT_VOTES_EXTENSION();
        assertEq(extension, address(votesExtension), "Votes extension should be set");
    }

    function testDelegateToSelf() public {
        // Deposit first
        vm.startPrank(USER1);
        underlyingToken.approve(address(plasmaVault), 1000 ether);
        plasmaVault.deposit(1000 ether, USER1);

        // Initially no votes (need to delegate)
        assertEq(IPlasmaVaultVotesExtension(address(plasmaVault)).getVotes(USER1), 0);

        // Delegate to self
        IPlasmaVaultVotesExtension(address(plasmaVault)).delegate(USER1);

        // Now votes should equal balance
        uint256 votes = IPlasmaVaultVotesExtension(address(plasmaVault)).getVotes(USER1);
        uint256 balance = plasmaVault.balanceOf(USER1);
        assertGt(votes, 0, "Should have votes after delegation");
        assertEq(votes, balance, "Votes should equal balance");
        vm.stopPrank();
    }

    function testDelegateToOther() public {
        // Deposit for USER1
        vm.startPrank(USER1);
        underlyingToken.approve(address(plasmaVault), 1000 ether);
        plasmaVault.deposit(1000 ether, USER1);

        // Delegate to USER2
        IPlasmaVaultVotesExtension(address(plasmaVault)).delegate(USER2);
        vm.stopPrank();

        // USER1 has no votes, USER2 has USER1's votes
        assertEq(IPlasmaVaultVotesExtension(address(plasmaVault)).getVotes(USER1), 0);
        assertEq(IPlasmaVaultVotesExtension(address(plasmaVault)).getVotes(USER2), plasmaVault.balanceOf(USER1));

        // Check delegates() returns USER2
        assertEq(IPlasmaVaultVotesExtension(address(plasmaVault)).delegates(USER1), USER2);
    }

    function testVoteCheckpoints() public {
        // Deposit for USER1
        vm.startPrank(USER1);
        underlyingToken.approve(address(plasmaVault), 1000 ether);
        plasmaVault.deposit(500 ether, USER1);
        IPlasmaVaultVotesExtension(address(plasmaVault)).delegate(USER1);
        vm.stopPrank();

        uint256 firstVotes = IPlasmaVaultVotesExtension(address(plasmaVault)).getVotes(USER1);
        uint256 firstBlock = block.number;

        // Move forward
        vm.roll(block.number + 1);

        // Deposit more
        vm.startPrank(USER1);
        plasmaVault.deposit(500 ether, USER1);
        vm.stopPrank();

        uint256 secondVotes = IPlasmaVaultVotesExtension(address(plasmaVault)).getVotes(USER1);

        assertGt(secondVotes, firstVotes, "Votes should increase after deposit");

        // Check past votes
        uint256 pastVotes = IPlasmaVaultVotesExtension(address(plasmaVault)).getPastVotes(USER1, firstBlock);
        assertEq(pastVotes, firstVotes, "Past votes should match first checkpoint");
    }

    function testTransferUpdatesVotingPower() public {
        // USER1 deposits and delegates
        vm.startPrank(USER1);
        underlyingToken.approve(address(plasmaVault), 1000 ether);
        plasmaVault.deposit(1000 ether, USER1);
        IPlasmaVaultVotesExtension(address(plasmaVault)).delegate(USER1);
        vm.stopPrank();

        // USER2 delegates to self (for receiving votes)
        vm.prank(USER2);
        IPlasmaVaultVotesExtension(address(plasmaVault)).delegate(USER2);

        uint256 user1VotesBefore = IPlasmaVaultVotesExtension(address(plasmaVault)).getVotes(USER1);

        // Transfer half to USER2
        vm.prank(USER1);
        plasmaVault.transfer(USER2, user1VotesBefore / 2);

        uint256 user1VotesAfter = IPlasmaVaultVotesExtension(address(plasmaVault)).getVotes(USER1);
        uint256 user2VotesAfter = IPlasmaVaultVotesExtension(address(plasmaVault)).getVotes(USER2);

        assertEq(user1VotesAfter, user1VotesBefore / 2, "USER1 should have half votes");
        assertEq(user2VotesAfter, user1VotesBefore / 2, "USER2 should have half votes");
    }

    function testGetPastTotalSupply() public {
        // USER1 deposits
        vm.startPrank(USER1);
        underlyingToken.approve(address(plasmaVault), 1000 ether);
        plasmaVault.deposit(500 ether, USER1);
        IPlasmaVaultVotesExtension(address(plasmaVault)).delegate(USER1);
        vm.stopPrank();

        uint256 firstBlock = block.number;
        vm.roll(block.number + 1);

        // USER2 deposits
        vm.startPrank(USER2);
        underlyingToken.approve(address(plasmaVault), 2000 ether);
        plasmaVault.deposit(1000 ether, USER2);
        IPlasmaVaultVotesExtension(address(plasmaVault)).delegate(USER2);
        vm.stopPrank();

        // Check past total supply at first block
        uint256 pastTotalSupply = IPlasmaVaultVotesExtension(address(plasmaVault)).getPastTotalSupply(firstBlock);

        // Past total supply should only count USER1's delegated votes
        assertGt(pastTotalSupply, 0, "Past total supply should be positive");
    }

    function testClockAndClockMode() public view {
        uint48 currentClock = IPlasmaVaultVotesExtension(address(plasmaVault)).clock();
        assertEq(currentClock, uint48(block.number), "Clock should return block number");

        string memory mode = IPlasmaVaultVotesExtension(address(plasmaVault)).CLOCK_MODE();
        assertEq(mode, "mode=blocknumber&from=default", "Clock mode should be block number");
    }

    function testNumCheckpointsAndCheckpoints() public {
        // Deposit and delegate
        vm.startPrank(USER1);
        underlyingToken.approve(address(plasmaVault), 1000 ether);
        plasmaVault.deposit(500 ether, USER1);
        IPlasmaVaultVotesExtension(address(plasmaVault)).delegate(USER1);
        vm.stopPrank();

        vm.roll(block.number + 1);

        // Another deposit
        vm.startPrank(USER1);
        plasmaVault.deposit(500 ether, USER1);
        vm.stopPrank();

        uint32 numCheckpoints = IPlasmaVaultVotesExtension(address(plasmaVault)).numCheckpoints(USER1);
        assertGe(numCheckpoints, 1, "Should have at least one checkpoint");

        // Can access checkpoints
        if (numCheckpoints > 0) {
            IPlasmaVaultVotesExtension(address(plasmaVault)).checkpoints(USER1, 0);
        }
    }

    function testVotesExtensionNotEnabledReverts() public {
        // Deploy vault without votes extension
        vm.startPrank(ATOMIST);
        PlasmaVault vaultNoVotes = new PlasmaVault();
        vaultNoVotes.proxyInitialize(
            PlasmaVaultInitData(
                "No Votes Vault",
                "NV",
                address(underlyingToken),
                address(priceOracle),
                FeeConfigHelper.createZeroFeeConfig(),
                address(accessManager),
                address(new PlasmaVaultBase()),
                address(0),
                withdrawManager,
                address(0) // No votes extension
            )
        );
        vm.stopPrank();

        // Try to call votes function - should revert
        vm.expectRevert(PlasmaVault.VotesExtensionNotEnabled.selector);
        IPlasmaVaultVotesExtension(address(vaultNoVotes)).getVotes(USER1);
    }
}
