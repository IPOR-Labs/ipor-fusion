// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {WhitelistWrappedPlasmaVaultFactory} from "../../contracts/factory/extensions/WhitelistWrappedPlasmaVaultFactory.sol";
import {WhitelistWrappedPlasmaVault} from "../../contracts/vaults/extensions/WhitelistWrappedPlasmaVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PlasmaVaultStorageLib} from "../../contracts/libraries/PlasmaVaultStorageLib.sol";

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

contract WhitelistWrappedPlasmaVaultFactoryTest is Test {
    WhitelistWrappedPlasmaVaultFactory public factory;
    WhitelistWrappedPlasmaVaultFactory public factoryImplementation;
    MockPlasmaVault public plasmaVault;
    MockERC20 public underlyingToken;

    address public owner;
    address public admin;
    address public user;
    address public otherUser;

    string public constant VAULT_NAME = "Whitelist Wrapped Test Vault";
    string public constant VAULT_SYMBOL = "wwTEST";

    event WhitelistWrappedPlasmaVaultCreated(
        string name,
        string symbol,
        address plasmaVault,
        address initialAdmin,
        address whitelistWrappedPlasmaVault,
        address managementFeeAccount,
        uint256 managementFeePercentage,
        address performanceFeeAccount,
        uint256 performanceFeePercentage
    );

    function setUp() public {
        // Deploy mock token
        underlyingToken = new MockERC20("Test Token", "TEST", 18);

        // Deploy mock plasma vault
        plasmaVault = new MockPlasmaVault(address(underlyingToken));

        // Deploy factory implementation and proxy
        factoryImplementation = new WhitelistWrappedPlasmaVaultFactory();

        owner = makeAddr("owner");
        admin = makeAddr("admin");
        user = makeAddr("user");
        otherUser = makeAddr("otherUser");

        bytes memory initData = abi.encodeWithSignature("initialize(address)", owner);
        factory = WhitelistWrappedPlasmaVaultFactory(
            address(new ERC1967Proxy(address(factoryImplementation), initData))
        );
    }

    function testShouldRevertInitializeWithZeroAddress() public {
        // Deploy new factory implementation
        WhitelistWrappedPlasmaVaultFactory newFactoryImpl = new WhitelistWrappedPlasmaVaultFactory();

        // Should revert when initializing with zero address
        bytes memory initData = abi.encodeWithSignature("initialize(address)", address(0));
        vm.expectRevert(WhitelistWrappedPlasmaVaultFactory.InvalidAddress.selector);
        new ERC1967Proxy(address(newFactoryImpl), initData);
    }

    function testShouldRevertInitializeTwice() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        factory.initialize(owner);
    }

    function testShouldCreateWhitelistWrappedPlasmaVault() public {
        // When
        address wrappedVault = factory.create(
            VAULT_NAME,
            VAULT_SYMBOL,
            address(plasmaVault),
            admin,
            address(this),
            30,
            address(this),
            200
        );

        // Then
        assertTrue(wrappedVault != address(0), "Wrapped vault should be created");

        WhitelistWrappedPlasmaVault vault = WhitelistWrappedPlasmaVault(wrappedVault);
        assertEq(vault.name(), VAULT_NAME, "Vault name should be correct");
        assertEq(vault.symbol(), VAULT_SYMBOL, "Vault symbol should be correct");
        assertEq(vault.PLASMA_VAULT(), address(plasmaVault), "Vault plasma vault should be correct");
    }

    function testShouldCreateMultipleWhitelistWrappedPlasmaVaults() public {
        // Create first vault
        address wrappedVault1 = factory.create(
            VAULT_NAME,
            VAULT_SYMBOL,
            address(plasmaVault),
            admin,
            address(this),
            30,
            address(this),
            200
        );

        // Create second vault with different parameters
        address wrappedVault2 = factory.create(
            "Second Vault",
            "wwSEC",
            address(plasmaVault),
            admin,
            address(this),
            30,
            address(this),
            200
        );

        // Verify both vaults are different
        assertTrue(wrappedVault1 != wrappedVault2, "Vaults should be different addresses");

        WhitelistWrappedPlasmaVault vault1 = WhitelistWrappedPlasmaVault(wrappedVault1);
        WhitelistWrappedPlasmaVault vault2 = WhitelistWrappedPlasmaVault(wrappedVault2);

        assertEq(vault1.name(), VAULT_NAME);
        assertEq(vault2.name(), "Second Vault");
        assertEq(vault1.symbol(), VAULT_SYMBOL);
        assertEq(vault2.symbol(), "wwSEC");
    }

    function testShouldAllowCreate() public {
        // Then: should be able to create vault
        address wrappedVault = factory.create(
            VAULT_NAME,
            VAULT_SYMBOL,
            address(plasmaVault),
            admin,
            address(this),
            30,
            address(this),
            200
        );
        assertTrue(wrappedVault != address(0), "Should be able to create vault after unpause");
    }

    function testShouldRevertUpgradeByNonOwner() public {
        // Deploy new implementation
        WhitelistWrappedPlasmaVaultFactory newImplementation = new WhitelistWrappedPlasmaVaultFactory();

        // Should revert when non-owner tries to upgrade
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user));
        factory.upgradeToAndCall(address(newImplementation), "");
    }

    function testShouldUpgradeByOwner() public {
        // Deploy new implementation
        WhitelistWrappedPlasmaVaultFactory newImplementation = new WhitelistWrappedPlasmaVaultFactory();

        // Should succeed when owner upgrades
        vm.prank(owner);
        factory.upgradeToAndCall(address(newImplementation), "");

        // Verify upgrade was successful by checking that we can still call functions
        address wrappedVault = factory.create(
            VAULT_NAME,
            VAULT_SYMBOL,
            address(plasmaVault),
            admin,
            address(this),
            30,
            address(this),
            200
        );
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
        factory.create(VAULT_NAME, VAULT_SYMBOL, address(0), admin, address(this), 30, address(this), 200);
    }

    function testShouldCreateVaultWithEmptyStrings() public {
        // Should be able to create vault with empty name/symbol (though not recommended)
        address wrappedVault = factory.create(
            "",
            "",
            address(plasmaVault),
            admin,
            address(this),
            30,
            address(this),
            200
        );
        assertTrue(wrappedVault != address(0), "Should be able to create vault with empty strings");

        WhitelistWrappedPlasmaVault vault = WhitelistWrappedPlasmaVault(wrappedVault);
        assertEq(vault.name(), "");
        assertEq(vault.symbol(), "");
    }

    function testShouldCreateVaultWithLongStrings() public {
        // Should be able to create vault with long name/symbol
        string memory longName = "This is a very long name for testing purposes with many characters";
        string memory longSymbol = "VERYLONGSYMBOL";

        address wrappedVault = factory.create(
            longName,
            longSymbol,
            address(plasmaVault),
            admin,
            address(this),
            30,
            address(this),
            200
        );
        assertTrue(wrappedVault != address(0), "Should be able to create vault with long strings");

        WhitelistWrappedPlasmaVault vault = WhitelistWrappedPlasmaVault(wrappedVault);
        assertEq(vault.name(), longName);
        assertEq(vault.symbol(), longSymbol);
    }

    function testShouldRevertCreateWhenPlasmaVaultIsInvalid() public {
        // Should revert when plasma vault address is not a contract
        vm.expectRevert();
        factory.create(VAULT_NAME, VAULT_SYMBOL, user, admin, address(this), 30, address(this), 200);
    }

    function testShouldSetCorrectInitialAdminForWhitelistWrappedPlasmaVault() public {
        // When: create a whitelist wrapped plasma vault with a specific admin
        address expectedAdmin = makeAddr("vaultAdmin");
        address wrappedVault = factory.create(
            VAULT_NAME,
            VAULT_SYMBOL,
            address(plasmaVault),
            expectedAdmin,
            address(this),
            30,
            address(this),
            200
        );

        // Then: verify the admin is set correctly
        WhitelistWrappedPlasmaVault vault = WhitelistWrappedPlasmaVault(wrappedVault);
        assertTrue(
            vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), expectedAdmin),
            "Initial admin should have DEFAULT_ADMIN_ROLE"
        );
    }

    function testShouldSetDifferentInitialAdminsForDifferentVaults() public {
        // When: create multiple vaults with different admins
        address admin1 = makeAddr("admin1");
        address admin2 = makeAddr("admin2");

        address wrappedVault1 = factory.create(
            VAULT_NAME,
            VAULT_SYMBOL,
            address(plasmaVault),
            admin1,
            address(this),
            30,
            address(this),
            200
        );
        address wrappedVault2 = factory.create(
            "Second Vault",
            "wwSEC",
            address(plasmaVault),
            admin2,
            address(this),
            30,
            address(this),
            200
        );

        // Then: verify each vault has the correct admin
        WhitelistWrappedPlasmaVault vault1 = WhitelistWrappedPlasmaVault(wrappedVault1);
        WhitelistWrappedPlasmaVault vault2 = WhitelistWrappedPlasmaVault(wrappedVault2);

        assertTrue(vault1.hasRole(vault1.DEFAULT_ADMIN_ROLE(), admin1), "First vault should have correct admin");
        assertTrue(vault2.hasRole(vault2.DEFAULT_ADMIN_ROLE(), admin2), "Second vault should have correct admin");
        assertTrue(admin1 != admin2, "Admins should be different");
    }

    function testInitialAdminHasDefaultAdminRole() public {
        // When: create a whitelist wrapped plasma vault
        address expectedAdmin = makeAddr("vaultAdmin");
        address wrappedVault = factory.create(
            VAULT_NAME,
            VAULT_SYMBOL,
            address(plasmaVault),
            expectedAdmin,
            address(this),
            30,
            address(this),
            200
        );

        // Then: verify the initial admin has DEFAULT_ADMIN_ROLE
        WhitelistWrappedPlasmaVault vault = WhitelistWrappedPlasmaVault(wrappedVault);
        assertTrue(
            vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), expectedAdmin),
            "Initial admin should have DEFAULT_ADMIN_ROLE"
        );
    }

    function testShouldRevertCreateWithZeroInitialAdminAddress() public {
        // Should revert when creating vault with zero initial admin address
        vm.expectRevert(abi.encodeWithSignature("InvalidAddress()"));
        factory.create(
            VAULT_NAME,
            VAULT_SYMBOL,
            address(plasmaVault),
            address(0),
            address(this),
            30,
            address(this),
            200
        );
    }

    function testShouldSetCorrectFeeConfiguration() public {
        // Given: specific fee accounts and percentages
        address managementFeeAccount = makeAddr("managementFeeAccount");
        address performanceFeeAccount = makeAddr("performanceFeeAccount");
        uint256 managementFeePercentage = 250; // 2.5%
        uint256 performanceFeePercentage = 500; // 5%

        // When: create a whitelist wrapped plasma vault with specific fee configuration
        address wrappedVault = factory.create(
            VAULT_NAME,
            VAULT_SYMBOL,
            address(plasmaVault),
            admin,
            managementFeeAccount,
            managementFeePercentage,
            performanceFeeAccount,
            performanceFeePercentage
        );

        // Then: verify the fee configuration is set correctly
        WhitelistWrappedPlasmaVault vault = WhitelistWrappedPlasmaVault(wrappedVault);

        // Check management fee configuration
        PlasmaVaultStorageLib.ManagementFeeData memory managementFeeData = vault.getManagementFeeData();
        assertEq(managementFeeData.feeAccount, managementFeeAccount, "Management fee account should be set correctly");
        assertEq(
            managementFeeData.feeInPercentage,
            managementFeePercentage,
            "Management fee percentage should be set correctly"
        );

        // Check performance fee configuration
        PlasmaVaultStorageLib.PerformanceFeeData memory performanceFeeData = vault.getPerformanceFeeData();
        assertEq(
            performanceFeeData.feeAccount,
            performanceFeeAccount,
            "Performance fee account should be set correctly"
        );
        assertEq(
            performanceFeeData.feeInPercentage,
            performanceFeePercentage,
            "Performance fee percentage should be set correctly"
        );
    }

    function testShouldSetDifferentFeeAccounts() public {
        // Given: different fee accounts
        address managementFeeAccount1 = makeAddr("managementFeeAccount1");
        address performanceFeeAccount1 = makeAddr("performanceFeeAccount1");
        address managementFeeAccount2 = makeAddr("managementFeeAccount2");
        address performanceFeeAccount2 = makeAddr("performanceFeeAccount2");

        // When: create two vaults with different fee accounts
        address wrappedVault1 = factory.create(
            VAULT_NAME,
            VAULT_SYMBOL,
            address(plasmaVault),
            admin,
            managementFeeAccount1,
            100,
            performanceFeeAccount1,
            300
        );

        address wrappedVault2 = factory.create(
            "Second Vault",
            "wwSEC",
            address(plasmaVault),
            admin,
            managementFeeAccount2,
            400,
            performanceFeeAccount2,
            600
        );

        // Then: verify fee accounts are different
        WhitelistWrappedPlasmaVault vault1 = WhitelistWrappedPlasmaVault(wrappedVault1);
        WhitelistWrappedPlasmaVault vault2 = WhitelistWrappedPlasmaVault(wrappedVault2);

        PlasmaVaultStorageLib.ManagementFeeData memory managementFeeData1 = vault1.getManagementFeeData();
        PlasmaVaultStorageLib.PerformanceFeeData memory performanceFeeData1 = vault1.getPerformanceFeeData();
        PlasmaVaultStorageLib.ManagementFeeData memory managementFeeData2 = vault2.getManagementFeeData();
        PlasmaVaultStorageLib.PerformanceFeeData memory performanceFeeData2 = vault2.getPerformanceFeeData();

        assertEq(managementFeeData1.feeAccount, managementFeeAccount1);
        assertEq(performanceFeeData1.feeAccount, performanceFeeAccount1);
        assertEq(managementFeeData2.feeAccount, managementFeeAccount2);
        assertEq(performanceFeeData2.feeAccount, performanceFeeAccount2);
    }

    function testShouldSetDifferentFeePercentages() public {
        // Given: different fee percentages
        uint256 managementFeePercentage1 = 100; // 1%
        uint256 performanceFeePercentage1 = 300; // 3%
        uint256 managementFeePercentage2 = 400; // 4%
        uint256 performanceFeePercentage2 = 600; // 6%

        // When: create two vaults with different fee percentages
        address wrappedVault1 = factory.create(
            VAULT_NAME,
            VAULT_SYMBOL,
            address(plasmaVault),
            admin,
            address(this),
            managementFeePercentage1,
            address(this),
            performanceFeePercentage1
        );

        address wrappedVault2 = factory.create(
            "Second Vault",
            "wwSEC",
            address(plasmaVault),
            admin,
            address(this),
            managementFeePercentage2,
            address(this),
            performanceFeePercentage2
        );

        // Then: verify fee percentages are different
        WhitelistWrappedPlasmaVault vault1 = WhitelistWrappedPlasmaVault(wrappedVault1);
        WhitelistWrappedPlasmaVault vault2 = WhitelistWrappedPlasmaVault(wrappedVault2);

        PlasmaVaultStorageLib.ManagementFeeData memory managementFeeData1 = vault1.getManagementFeeData();
        PlasmaVaultStorageLib.PerformanceFeeData memory performanceFeeData1 = vault1.getPerformanceFeeData();
        PlasmaVaultStorageLib.ManagementFeeData memory managementFeeData2 = vault2.getManagementFeeData();
        PlasmaVaultStorageLib.PerformanceFeeData memory performanceFeeData2 = vault2.getPerformanceFeeData();

        assertEq(managementFeeData1.feeInPercentage, managementFeePercentage1);
        assertEq(performanceFeeData1.feeInPercentage, performanceFeePercentage1);
        assertEq(managementFeeData2.feeInPercentage, managementFeePercentage2);
        assertEq(performanceFeeData2.feeInPercentage, performanceFeePercentage2);
    }

    function testShouldSetZeroFees() public {
        // Given: zero fee percentages
        address managementFeeAccount = makeAddr("managementFeeAccount");
        address performanceFeeAccount = makeAddr("performanceFeeAccount");
        uint256 managementFeePercentage = 0; // 0%
        uint256 performanceFeePercentage = 0; // 0%

        // When: create a vault with zero fees
        address wrappedVault = factory.create(
            VAULT_NAME,
            VAULT_SYMBOL,
            address(plasmaVault),
            admin,
            managementFeeAccount,
            managementFeePercentage,
            performanceFeeAccount,
            performanceFeePercentage
        );

        // Then: verify zero fees are set correctly
        WhitelistWrappedPlasmaVault vault = WhitelistWrappedPlasmaVault(wrappedVault);

        PlasmaVaultStorageLib.ManagementFeeData memory managementFeeData = vault.getManagementFeeData();
        PlasmaVaultStorageLib.PerformanceFeeData memory performanceFeeData = vault.getPerformanceFeeData();

        assertEq(managementFeeData.feeAccount, managementFeeAccount, "Management fee account should be set correctly");
        assertEq(managementFeeData.feeInPercentage, 0, "Management fee percentage should be zero");
        assertEq(
            performanceFeeData.feeAccount,
            performanceFeeAccount,
            "Performance fee account should be set correctly"
        );
        assertEq(performanceFeeData.feeInPercentage, 0, "Performance fee percentage should be zero");
    }

    function testShouldRevertCreateWithZeroAddressForFeeAccounts() public {
        // Given: zero addresses for fee accounts with non-zero fee percentages
        address zeroAddress = address(0);
        uint256 managementFeePercentage = 250; // 2.5%
        uint256 performanceFeePercentage = 500; // 5%

        // When & Then: should revert when creating vault with zero addresses for fee accounts
        vm.expectRevert(abi.encodeWithSignature("InvalidAddress()"));
        factory.create(
            VAULT_NAME,
            VAULT_SYMBOL,
            address(plasmaVault),
            admin,
            zeroAddress, // management fee account
            managementFeePercentage,
            zeroAddress, // performance fee account
            performanceFeePercentage
        );
    }
}
