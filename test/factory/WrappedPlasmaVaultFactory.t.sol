// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {WrappedPlasmaVaultFactory} from "../../contracts/factory/extensions/WrappedPlasmaVaultFactory.sol";
import {WrappedPlasmaVault} from "../../contracts/vaults/extensions/WrappedPlasmaVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Simple mock for PlasmaVault that implements the required interface
contract MockPlasmaVault {
    IERC20 public immutable asset;

    constructor(address _asset) {
        asset = IERC20(_asset);
    }

    function maxWithdraw(address) external view returns (uint256) {
        return 1000e18; // Return a fixed amount for testing
    }
}

contract WrappedPlasmaVaultFactoryTest is Test {
    WrappedPlasmaVaultFactory public factory;
    WrappedPlasmaVaultFactory public factoryImplementation;
    MockPlasmaVault public plasmaVault;
    MockERC20 public underlyingToken;

    address public owner;
    address public user;
    address public otherUser;

    string public constant VAULT_NAME = "Wrapped Test Vault";
    string public constant VAULT_SYMBOL = "wTEST";

    event WrappedPlasmaVaultCreated(string name, string symbol, address plasmaVault);

    function setUp() public {
        // Deploy mock token
        underlyingToken = new MockERC20("Test Token", "TEST", 18);

        // Deploy mock plasma vault
        plasmaVault = new MockPlasmaVault(address(underlyingToken));

        // Deploy factory implementation and proxy
        factoryImplementation = new WrappedPlasmaVaultFactory();

        owner = makeAddr("owner");
        user = makeAddr("user");
        otherUser = makeAddr("otherUser");

        bytes memory initData = abi.encodeWithSignature("initialize(address)", owner);
        factory = WrappedPlasmaVaultFactory(address(new ERC1967Proxy(address(factoryImplementation), initData)));
    }

    function testShouldRevertInitializeWithZeroAddress() public {
        // Deploy new factory implementation
        WrappedPlasmaVaultFactory newFactoryImpl = new WrappedPlasmaVaultFactory();

        // Should revert when initializing with zero address
        bytes memory initData = abi.encodeWithSignature("initialize(address)", address(0));
        vm.expectRevert(WrappedPlasmaVaultFactory.InvalidAddress.selector);
        new ERC1967Proxy(address(newFactoryImpl), initData);
    }

    function testShouldRevertInitializeTwice() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        factory.initialize(owner);
    }

    function testShouldCreateWrappedPlasmaVault() public {
        // When

        address wrappedVault = factory.create(VAULT_NAME, VAULT_SYMBOL, address(plasmaVault), address(this));

        // Then
        assertTrue(wrappedVault != address(0), "Wrapped vault should be created");

        WrappedPlasmaVault vault = WrappedPlasmaVault(wrappedVault);
        assertEq(vault.name(), VAULT_NAME, "Vault name should be correct");
        assertEq(vault.symbol(), VAULT_SYMBOL, "Vault symbol should be correct");
        assertEq(vault.PLASMA_VAULT(), address(plasmaVault), "Vault plasma vault should be correct");
    }

    function testShouldCreateMultipleWrappedPlasmaVaults() public {
        // Create first vault
        address wrappedVault1 = factory.create(VAULT_NAME, VAULT_SYMBOL, address(plasmaVault), address(this));

        // Create second vault with different parameters
        address wrappedVault2 = factory.create("Second Vault", "wSEC", address(plasmaVault), address(this));

        // Verify both vaults are different
        assertTrue(wrappedVault1 != wrappedVault2, "Vaults should be different addresses");

        WrappedPlasmaVault vault1 = WrappedPlasmaVault(wrappedVault1);
        WrappedPlasmaVault vault2 = WrappedPlasmaVault(wrappedVault2);

        assertEq(vault1.name(), VAULT_NAME);
        assertEq(vault2.name(), "Second Vault");
        assertEq(vault1.symbol(), VAULT_SYMBOL);
        assertEq(vault2.symbol(), "wSEC");
    }

    function testShouldAllowCreate() public {
        // Then: should be able to create vault
        address wrappedVault = factory.create(VAULT_NAME, VAULT_SYMBOL, address(plasmaVault), address(this));
        assertTrue(wrappedVault != address(0), "Should be able to create vault after unpause");
    }

    function testShouldRevertUpgradeByNonOwner() public {
        // Deploy new implementation
        WrappedPlasmaVaultFactory newImplementation = new WrappedPlasmaVaultFactory();

        // Should revert when non-owner tries to upgrade
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user));
        factory.upgradeToAndCall(address(newImplementation), "");
    }

    function testShouldUpgradeByOwner() public {
        // Deploy new implementation
        WrappedPlasmaVaultFactory newImplementation = new WrappedPlasmaVaultFactory();

        // Should succeed when owner upgrades
        vm.prank(owner);
        factory.upgradeToAndCall(address(newImplementation), "");

        // Verify upgrade was successful by checking that we can still call functions
        address wrappedVault = factory.create(VAULT_NAME, VAULT_SYMBOL, address(plasmaVault), address(this));
        assertTrue(wrappedVault != address(0), "Should be able to create vault after upgrade");
    }

    function testShouldTransferOwnership() public {
        // Test ownership transfer
        vm.prank(owner);
        factory.transferOwnership(user);

        // Accept ownership
        vm.prank(user);
        factory.acceptOwnership();

        assertEq(factory.owner(), user, "Ownership should be transferred");
    }

    function testShouldRevertCreateWithZeroPlasmaVaultAddress() public {
        // Should revert when creating vault with zero plasma vault address
        vm.expectRevert();
        factory.create(VAULT_NAME, VAULT_SYMBOL, address(0), address(this));
    }

    function testShouldCreateVaultWithEmptyStrings() public {
        // Should be able to create vault with empty name/symbol (though not recommended)
        address wrappedVault = factory.create("", "", address(plasmaVault), address(this));
        assertTrue(wrappedVault != address(0), "Should be able to create vault with empty strings");

        WrappedPlasmaVault vault = WrappedPlasmaVault(wrappedVault);
        assertEq(vault.name(), "");
        assertEq(vault.symbol(), "");
    }

    function testShouldCreateVaultWithLongStrings() public {
        // Should be able to create vault with long name/symbol
        string memory longName = "This is a very long name for testing purposes with many characters";
        string memory longSymbol = "VERYLONGSYMBOL";

        address wrappedVault = factory.create(longName, longSymbol, address(plasmaVault), address(this));
        assertTrue(wrappedVault != address(0), "Should be able to create vault with long strings");

        WrappedPlasmaVault vault = WrappedPlasmaVault(wrappedVault);
        assertEq(vault.name(), longName);
        assertEq(vault.symbol(), longSymbol);
    }

    function testShouldMaintainStateAfterUpgrade() public {
        // Create a vault before upgrade
        address wrappedVault = factory.create(VAULT_NAME, VAULT_SYMBOL, address(plasmaVault), address(this));

        // Deploy new implementation and upgrade
        WrappedPlasmaVaultFactory newImplementation = new WrappedPlasmaVaultFactory();
        vm.prank(owner);
        factory.upgradeToAndCall(address(newImplementation), "");

        // Verify the created vault still exists and has correct properties
        WrappedPlasmaVault vault = WrappedPlasmaVault(wrappedVault);
        assertEq(vault.name(), VAULT_NAME);
        assertEq(vault.symbol(), VAULT_SYMBOL);
        assertEq(vault.PLASMA_VAULT(), address(plasmaVault));

        // Verify factory can still create new vaults
        address newWrappedVault = factory.create("New Vault", "wNEW", address(plasmaVault), address(this));
        assertTrue(newWrappedVault != address(0), "Should be able to create new vault after upgrade");
    }

    function testShouldRevertCreateWhenPlasmaVaultIsInvalid() public {
        // Should revert when plasma vault address is not a contract
        vm.expectRevert();
        factory.create(VAULT_NAME, VAULT_SYMBOL, user, address(this));
    }

    function testShouldSetCorrectOwnerForWrappedPlasmaVault() public {
        // When: create a wrapped plasma vault with a specific owner
        address expectedOwner = makeAddr("vaultOwner");
        address wrappedVault = factory.create(VAULT_NAME, VAULT_SYMBOL, address(plasmaVault), expectedOwner);

        // Then: verify the owner is set correctly
        WrappedPlasmaVault vault = WrappedPlasmaVault(wrappedVault);
        assertEq(vault.owner(), expectedOwner, "Wrapped vault owner should be set correctly");
    }

    function testShouldSetDifferentOwnersForDifferentVaults() public {
        // When: create multiple vaults with different owners
        address owner1 = makeAddr("owner1");
        address owner2 = makeAddr("owner2");

        address wrappedVault1 = factory.create(VAULT_NAME, VAULT_SYMBOL, address(plasmaVault), owner1);
        address wrappedVault2 = factory.create("Second Vault", "wSEC", address(plasmaVault), owner2);

        // Then: verify each vault has the correct owner
        WrappedPlasmaVault vault1 = WrappedPlasmaVault(wrappedVault1);
        WrappedPlasmaVault vault2 = WrappedPlasmaVault(wrappedVault2);

        assertEq(vault1.owner(), owner1, "First vault should have correct owner");
        assertEq(vault2.owner(), owner2, "Second vault should have correct owner");
        assertTrue(owner1 != owner2, "Owners should be different");
    }

    function testShouldRevertCreateWithZeroOwnerAddress() public {
        // Should revert when creating vault with zero owner address
        vm.expectRevert(WrappedPlasmaVault.ZeroOwnerAddress.selector);
        factory.create(VAULT_NAME, VAULT_SYMBOL, address(plasmaVault), address(0));
    }
}
