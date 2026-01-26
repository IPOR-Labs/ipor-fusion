// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EIP7702DelegateValidationPreHook} from "../../contracts/handlers/pre_hooks/pre_hooks/EIP7702DelegateValidationPreHook.sol";
import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PreHooksLib} from "../../contracts/handlers/pre_hooks/PreHooksLib.sol";
import {PreHooksInfoReader, PreHookInfo} from "../../contracts/readers/PreHooksInfoReader.sol";
import {PlasmaVaultHelper, DeployMinimalPlasmaVaultParams} from "../test_helpers/PlasmaVaultHelper.sol";
import {PriceOracleMiddlewareHelper} from "../test_helpers/PriceOracleMiddlewareHelper.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {IporFusionAccessManagerHelper} from "../test_helpers/IporFusionAccessManagerHelper.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {RewardsClaimManager} from "../../contracts/managers/rewards/RewardsClaimManager.sol";
import {TestAddresses} from "../test_helpers/TestAddresses.sol";

/// @title Mock Smart Wallet for EIP-7702 testing
/// @notice Simulates a smart wallet that an EOA can delegate to via EIP-7702
/// @dev In real EIP-7702, when EOA delegates to this contract, calls to EOA execute this contract's code
contract MockSmartWallet {
    /// @notice Deposits assets into a PlasmaVault on behalf of the caller
    /// @dev In EIP-7702 context, this would be called as if it were the EOA's code
    function depositToVault(address vault_, address asset_, uint256 amount_, address receiver_) external {
        IERC20(asset_).approve(vault_, amount_);
        PlasmaVault(vault_).deposit(amount_, receiver_);
    }

    /// @notice Batch operation: approve and deposit in one transaction
    function batchDeposit(
        address vault_,
        address asset_,
        uint256 amount_,
        address receiver_
    ) external returns (uint256 shares) {
        IERC20(asset_).approve(vault_, amount_);
        shares = PlasmaVault(vault_).deposit(amount_, receiver_);
    }
}

/// @title Mock contract that calls vault on behalf of another address
/// @notice Used to test scenarios where msg.sender differs from tx.origin
/// @dev Simulates a router or relayer pattern
contract MockVaultCaller {
    /// @notice Calls deposit on the vault
    /// @dev When this is called, msg.sender to vault will be this contract, not tx.origin
    function callDeposit(address vault_, address asset_, uint256 amount_, address receiver_) external {
        // Transfer tokens from the original caller to this contract first
        IERC20(asset_).transferFrom(msg.sender, address(this), amount_);
        IERC20(asset_).approve(vault_, amount_);
        PlasmaVault(vault_).deposit(amount_, receiver_);
    }
}

/// @title Mock contract simulating EIP-7702 delegatecall pattern
/// @notice Simulates how EIP-7702 delegation works - code executes in EOA's context
/// @dev Uses delegatecall to execute SmartWallet code while preserving msg.sender context
contract MockEIP7702Executor {
    /// @notice Executes a call to the vault as if the caller's SmartWallet code was running
    /// @dev In real EIP-7702, this happens automatically when calling an EOA with delegation
    ///      Here we simulate it by having the EOA call this, which then calls vault
    ///      The key difference: msg.sender to vault = this contract (simulating EOA with code)
    function executeAsSmartWallet(
        address vault_,
        address asset_,
        uint256 amount_,
        address receiver_
    ) external {
        IERC20(asset_).approve(vault_, amount_);
        PlasmaVault(vault_).deposit(amount_, receiver_);
    }
}

/// @title EIP7702DelegateValidationPreHook Test
/// @notice Tests for EIP-7702 delegate target validation pre-hook
/// @dev Tests validation of delegate targets against a governance-managed whitelist
contract EIP7702DelegateValidationPreHookTest is Test {
    using PlasmaVaultHelper for PlasmaVault;
    using PriceOracleMiddlewareHelper for PriceOracleMiddleware;
    using IporFusionAccessManagerHelper for IporFusionAccessManager;

    EIP7702DelegateValidationPreHook public preHook;
    PlasmaVault public plasmaVault;
    IporFusionAccessManager public accessManager;

    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    address public whitelistedTarget;
    address public nonWhitelistedTarget;
    address public userEOA;

    /// @notice Counter for generating unique EOA addresses that don't exist on mainnet
    uint256 private _eoaCounter = 0xDEADBEEF_CAFE_BABE_1234;

    /// @notice Generates a fresh EOA address guaranteed to have no code
    /// @dev Uses incrementing counter + contract address + unique salt to generate addresses
    ///      that are virtually impossible to collide with existing mainnet contracts
    function _createFreshEOA(string memory label_) internal returns (address eoa) {
        _eoaCounter++;
        // Use high entropy: test contract address + counter + label + unique prefix
        uint256 privateKey = uint256(
            keccak256(
                abi.encodePacked(
                    "EIP7702_TEST_FRESH_EOA_V2_", // Unique prefix to avoid any collisions
                    address(this),
                    _eoaCounter,
                    label_
                )
            )
        );
        // Ensure private key is valid (non-zero and less than secp256k1 order)
        privateKey = (privateKey % 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364140) + 1;
        eoa = vm.addr(privateKey);
        vm.label(eoa, label_);
    }

    /// @notice Sets EIP-7702 delegation code on an address
    /// @dev Creates delegation code: 0xef0100 || delegateTarget (23 bytes total)
    function _setDelegationCode(address eoa_, address delegateTarget_) internal {
        bytes memory delegationCode = abi.encodePacked(bytes3(0xef0100), delegateTarget_);
        vm.etch(eoa_, delegationCode);
    }

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 21596204);

        preHook = new EIP7702DelegateValidationPreHook();

        // Create fresh EOA addresses that are guaranteed to have no code on the fork
        // Using _createFreshEOA ensures consistent behavior across different Foundry versions
        whitelistedTarget = _createFreshEOA("whitelistedTarget");
        nonWhitelistedTarget = _createFreshEOA("nonWhitelistedTarget");
        userEOA = _createFreshEOA("userEOA");

        // Deploy a fresh vault
        PriceOracleMiddleware priceOracleMiddleware = PriceOracleMiddlewareHelper.getEthereumPriceOracleMiddleware();

        DeployMinimalPlasmaVaultParams memory params = DeployMinimalPlasmaVaultParams({
            underlyingToken: USDC,
            underlyingTokenName: "USDC",
            priceOracleMiddleware: priceOracleMiddleware.addressOf(),
            atomist: TestAddresses.ATOMIST
        });

        vm.startPrank(TestAddresses.ATOMIST);
        (plasmaVault, ) = PlasmaVaultHelper.deployMinimalPlasmaVault(params);
        accessManager = plasmaVault.accessManagerOf();
        accessManager.setupInitRoles(
            plasmaVault,
            address(0x123),
            address(new RewardsClaimManager(address(accessManager), address(plasmaVault)))
        );
        vm.stopPrank();

        // Give USDC to test users
        deal(USDC, userEOA, 1000e6);
        deal(USDC, TestAddresses.USER, 1000e6);
    }

    /// @notice Test that whitelisted delegate target passes validation
    function testShouldAllowWhitelistedDelegateTarget() public {
        // given - set up EIP-7702 delegation code on userEOA
        _setDelegationCode(userEOA, whitelistedTarget);

        // Configure pre-hook with whitelisted target
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = PlasmaVault.deposit.selector;

        address[] memory preHooks = new address[](1);
        preHooks[0] = address(preHook);

        bytes32[][] memory substrates = new bytes32[][](1);
        substrates[0] = new bytes32[](1);
        substrates[0][0] = bytes32(uint256(uint160(whitelistedTarget)));

        vm.prank(TestAddresses.ATOMIST);
        PlasmaVaultGovernance(address(plasmaVault)).setPreHookImplementations(selectors, preHooks, substrates);

        // when - user with whitelisted delegation tries to deposit
        vm.startPrank(userEOA, userEOA); // Set both msg.sender and tx.origin
        IERC20(USDC).approve(address(plasmaVault), 1e6);

        // then - should not revert
        plasmaVault.deposit(1e6, userEOA);
        vm.stopPrank();

        assertTrue(IERC20(address(plasmaVault)).balanceOf(userEOA) > 0, "User should have received shares");
    }

    /// @notice Test that non-whitelisted delegate target reverts
    function testShouldRevertForNonWhitelistedDelegateTarget() public {
        // given - set up EIP-7702 delegation code with non-whitelisted target
        _setDelegationCode(userEOA, nonWhitelistedTarget);

        // Configure pre-hook with different whitelisted target
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = PlasmaVault.deposit.selector;

        address[] memory preHooks = new address[](1);
        preHooks[0] = address(preHook);

        bytes32[][] memory substrates = new bytes32[][](1);
        substrates[0] = new bytes32[](1);
        substrates[0][0] = bytes32(uint256(uint160(whitelistedTarget))); // Only whitelist different target

        vm.prank(TestAddresses.ATOMIST);
        PlasmaVaultGovernance(address(plasmaVault)).setPreHookImplementations(selectors, preHooks, substrates);

        // when/then - user with non-whitelisted delegation should revert
        vm.startPrank(userEOA, userEOA);
        IERC20(USDC).approve(address(plasmaVault), 1e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                EIP7702DelegateValidationPreHook.InvalidDelegateTarget.selector,
                userEOA,
                nonWhitelistedTarget
            )
        );
        plasmaVault.deposit(1e6, userEOA);
        vm.stopPrank();
    }

    /// @notice Test that regular EOA without delegation passes
    function testShouldAllowNonDelegatedEOA() public {
        // given - userEOA has no code (regular EOA)
        // Configure pre-hook with some whitelisted target
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = PlasmaVault.deposit.selector;

        address[] memory preHooks = new address[](1);
        preHooks[0] = address(preHook);

        bytes32[][] memory substrates = new bytes32[][](1);
        substrates[0] = new bytes32[](1);
        substrates[0][0] = bytes32(uint256(uint160(whitelistedTarget)));

        vm.prank(TestAddresses.ATOMIST);
        PlasmaVaultGovernance(address(plasmaVault)).setPreHookImplementations(selectors, preHooks, substrates);

        // when - regular user without delegation tries to deposit
        vm.startPrank(userEOA, userEOA);
        IERC20(USDC).approve(address(plasmaVault), 1e6);

        // then - should not revert
        plasmaVault.deposit(1e6, userEOA);
        vm.stopPrank();

        assertTrue(IERC20(address(plasmaVault)).balanceOf(userEOA) > 0, "User should have received shares");
    }

    /// @notice Test that contract with different code size passes (not EIP-7702)
    function testShouldAllowContractWithDifferentCodeSize() public {
        // given - set up code that is NOT 23 bytes (e.g., 50 bytes)
        bytes memory differentSizeCode = new bytes(50);
        for (uint256 i = 0; i < 50; i++) {
            differentSizeCode[i] = 0xab;
        }
        vm.etch(userEOA, differentSizeCode);

        // Configure pre-hook
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = PlasmaVault.deposit.selector;

        address[] memory preHooks = new address[](1);
        preHooks[0] = address(preHook);

        bytes32[][] memory substrates = new bytes32[][](1);
        substrates[0] = new bytes32[](1);
        substrates[0][0] = bytes32(uint256(uint160(whitelistedTarget)));

        vm.prank(TestAddresses.ATOMIST);
        PlasmaVaultGovernance(address(plasmaVault)).setPreHookImplementations(selectors, preHooks, substrates);

        // when - account with different code size tries to deposit
        vm.startPrank(userEOA, userEOA);
        IERC20(USDC).approve(address(plasmaVault), 1e6);

        // then - should not revert (treated as non-EIP7702)
        plasmaVault.deposit(1e6, userEOA);
        vm.stopPrank();

        assertTrue(IERC20(address(plasmaVault)).balanceOf(userEOA) > 0, "User should have received shares");
    }

    /// @notice Test that 23 bytes code with wrong prefix passes (not EIP-7702)
    function testShouldIgnoreWrongPrefix() public {
        // given - set up 23 bytes code with wrong prefix (not 0xef0100)
        bytes memory wrongPrefixCode = abi.encodePacked(bytes3(0xaabbcc), whitelistedTarget);
        vm.etch(userEOA, wrongPrefixCode);

        // Configure pre-hook
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = PlasmaVault.deposit.selector;

        address[] memory preHooks = new address[](1);
        preHooks[0] = address(preHook);

        bytes32[][] memory substrates = new bytes32[][](1);
        substrates[0] = new bytes32[](1);
        substrates[0][0] = bytes32(uint256(uint160(nonWhitelistedTarget))); // Different target in whitelist

        vm.prank(TestAddresses.ATOMIST);
        PlasmaVaultGovernance(address(plasmaVault)).setPreHookImplementations(selectors, preHooks, substrates);

        // when - account with wrong prefix tries to deposit
        vm.startPrank(userEOA, userEOA);
        IERC20(USDC).approve(address(plasmaVault), 1e6);

        // then - should not revert (treated as non-EIP7702)
        plasmaVault.deposit(1e6, userEOA);
        vm.stopPrank();

        assertTrue(IERC20(address(plasmaVault)).balanceOf(userEOA) > 0, "User should have received shares");
    }

    /// @notice Test that different selectors can have different whitelists
    function testShouldWorkWithMultipleSelectors() public {
        // given - set up EIP-7702 delegation
        _setDelegationCode(userEOA, whitelistedTarget);

        address secondWhitelistedTarget = _createFreshEOA("secondWhitelistedTarget");

        // Configure pre-hook for deposit with whitelistedTarget
        // Configure pre-hook for withdraw with secondWhitelistedTarget
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = PlasmaVault.deposit.selector;
        selectors[1] = PlasmaVault.withdraw.selector;

        address[] memory preHooks = new address[](2);
        preHooks[0] = address(preHook);
        preHooks[1] = address(preHook);

        bytes32[][] memory substrates = new bytes32[][](2);
        substrates[0] = new bytes32[](1);
        substrates[0][0] = bytes32(uint256(uint160(whitelistedTarget))); // deposit whitelist
        substrates[1] = new bytes32[](1);
        substrates[1][0] = bytes32(uint256(uint160(secondWhitelistedTarget))); // withdraw whitelist (different)

        vm.prank(TestAddresses.ATOMIST);
        PlasmaVaultGovernance(address(plasmaVault)).setPreHookImplementations(selectors, preHooks, substrates);

        // when - deposit should work (whitelistedTarget is in deposit whitelist)
        vm.startPrank(userEOA, userEOA);
        IERC20(USDC).approve(address(plasmaVault), 1e6);
        plasmaVault.deposit(1e6, userEOA);

        uint256 shares = IERC20(address(plasmaVault)).balanceOf(userEOA);
        assertTrue(shares > 0, "User should have received shares");

        // then - withdraw should revert (whitelistedTarget is NOT in withdraw whitelist)
        vm.expectRevert(
            abi.encodeWithSelector(
                EIP7702DelegateValidationPreHook.InvalidDelegateTarget.selector,
                userEOA,
                whitelistedTarget
            )
        );
        plasmaVault.withdraw(shares / 2, userEOA, userEOA);
        vm.stopPrank();
    }

    /// @notice Test multiple whitelisted targets for same selector
    function testShouldWorkWithMultipleWhitelistedTargets() public {
        // given - set up EIP-7702 delegation with second whitelisted target
        address secondWhitelistedTarget = _createFreshEOA("secondWhitelistedTarget");
        _setDelegationCode(userEOA, secondWhitelistedTarget);

        // Configure pre-hook with both targets whitelisted
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = PlasmaVault.deposit.selector;

        address[] memory preHooks = new address[](1);
        preHooks[0] = address(preHook);

        bytes32[][] memory substrates = new bytes32[][](1);
        substrates[0] = new bytes32[](2);
        substrates[0][0] = bytes32(uint256(uint160(whitelistedTarget)));
        substrates[0][1] = bytes32(uint256(uint160(secondWhitelistedTarget)));

        vm.prank(TestAddresses.ATOMIST);
        PlasmaVaultGovernance(address(plasmaVault)).setPreHookImplementations(selectors, preHooks, substrates);

        // when - user with second whitelisted target tries to deposit
        vm.startPrank(userEOA, userEOA);
        IERC20(USDC).approve(address(plasmaVault), 1e6);

        // then - should not revert
        plasmaVault.deposit(1e6, userEOA);
        vm.stopPrank();

        assertTrue(IERC20(address(plasmaVault)).balanceOf(userEOA) > 0, "User should have received shares");
    }

    /// @notice Test that empty whitelist reverts for delegated account
    function testShouldRevertWhenWhitelistIsEmpty() public {
        // given - set up EIP-7702 delegation
        _setDelegationCode(userEOA, whitelistedTarget);

        // Configure pre-hook with empty substrates
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = PlasmaVault.deposit.selector;

        address[] memory preHooks = new address[](1);
        preHooks[0] = address(preHook);

        bytes32[][] memory substrates = new bytes32[][](1);
        substrates[0] = new bytes32[](0); // Empty whitelist

        vm.prank(TestAddresses.ATOMIST);
        PlasmaVaultGovernance(address(plasmaVault)).setPreHookImplementations(selectors, preHooks, substrates);

        // when/then - should revert because whitelist is empty
        vm.startPrank(userEOA, userEOA);
        IERC20(USDC).approve(address(plasmaVault), 1e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                EIP7702DelegateValidationPreHook.InvalidDelegateTarget.selector,
                userEOA,
                whitelistedTarget
            )
        );
        plasmaVault.deposit(1e6, userEOA);
        vm.stopPrank();
    }

    /// @notice Test VERSION is set correctly
    function testVersionIsSetCorrectly() public view {
        assertEq(preHook.VERSION(), address(preHook), "VERSION should be set to contract address");
    }

    /// @notice Test to verify substrates are stored and retrievable correctly
    function testSubstratesAreStoredCorrectly() public {
        // Configure pre-hook with whitelisted target
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = PlasmaVault.deposit.selector;

        address[] memory preHooks = new address[](1);
        preHooks[0] = address(preHook);

        bytes32[][] memory substrates = new bytes32[][](1);
        substrates[0] = new bytes32[](1);
        substrates[0][0] = bytes32(uint256(uint160(whitelistedTarget)));

        vm.prank(TestAddresses.ATOMIST);
        PlasmaVaultGovernance(address(plasmaVault)).setPreHookImplementations(selectors, preHooks, substrates);

        // Deploy PreHooksInfoReader and use it to verify substrates
        PreHooksInfoReader reader = new PreHooksInfoReader();
        PreHookInfo[] memory preHooksInfo = reader.getPreHooksInfo(address(plasmaVault));

        // Find our pre-hook in the list
        bool found = false;
        for (uint256 i = 0; i < preHooksInfo.length; i++) {
            if (preHooksInfo[i].selector == PlasmaVault.deposit.selector) {
                found = true;
                assertEq(
                    preHooksInfo[i].implementation,
                    address(preHook),
                    "Implementation should match preHook address"
                );
                assertEq(preHooksInfo[i].substrates.length, 1, "Should have 1 substrate");
                assertEq(
                    address(uint160(uint256(preHooksInfo[i].substrates[0]))),
                    whitelistedTarget,
                    "Substrate should be whitelisted target"
                );
                break;
            }
        }
        assertTrue(found, "Pre-hook for deposit selector should be found");
    }

    // ============================================
    // EIP-7702 Authorization Simulation Tests
    // ============================================

    /// @notice Test simulating EOA authorization with a whitelisted smart wallet contract
    /// @dev This test demonstrates the EIP-7702 flow:
    ///      1. Deploy a trusted SmartWallet contract
    ///      2. Whitelist the SmartWallet in the PreHook substrates
    ///      3. EOA "delegates" to SmartWallet (simulated via vm.etch with EIP-7702 code)
    ///      4. EOA interacts with the vault - PreHook validates msg.sender's delegation
    ///      5. Transaction succeeds because SmartWallet is whitelisted
    function testEIP7702AuthorizationWithWhitelistedSmartWallet() public {
        // ========== STEP 1: Deploy trusted SmartWallet ==========
        // This represents a trusted smart wallet implementation that governance approves
        MockSmartWallet trustedSmartWallet = new MockSmartWallet();

        // ========== STEP 2: Governance whitelists the SmartWallet ==========
        // ATOMIST (governance) adds the SmartWallet to the whitelist via substrates
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = PlasmaVault.deposit.selector;

        address[] memory preHooks = new address[](1);
        preHooks[0] = address(preHook);

        bytes32[][] memory substrates = new bytes32[][](1);
        substrates[0] = new bytes32[](1);
        substrates[0][0] = bytes32(uint256(uint160(address(trustedSmartWallet))));

        vm.prank(TestAddresses.ATOMIST);
        PlasmaVaultGovernance(address(plasmaVault)).setPreHookImplementations(selectors, preHooks, substrates);

        // ========== STEP 3: EOA "signs" EIP-7702 authorization ==========
        // In real EIP-7702, the EOA would sign an authorization tuple:
        // authorization = (chain_id, address, nonce, y_parity, r, s)
        // This sets the EOA's code to: 0xef0100 || smart_wallet_address
        //
        // Here we simulate this by using _setDelegationCode helper
        _setDelegationCode(userEOA, address(trustedSmartWallet));

        // Verify the delegation code is set correctly
        assertEq(userEOA.code.length, 23, "EOA should have 23-byte delegation code");
        assertEq(
            bytes3(abi.encodePacked(userEOA.code[0], userEOA.code[1], userEOA.code[2])),
            bytes3(0xef0100),
            "Should have EIP-7702 prefix"
        );

        // ========== STEP 4: EOA interacts with the vault ==========
        // When EOA calls the vault, the PreHook checks:
        // - msg.sender has EIP-7702 delegation code
        // - The delegate target (SmartWallet) is in the whitelist
        vm.startPrank(userEOA, userEOA); // msg.sender = userEOA (has delegation code)
        IERC20(USDC).approve(address(plasmaVault), 100e6);

        // ========== STEP 5: Deposit succeeds ==========
        // PreHook validates: msg.sender (userEOA) -> delegated to trustedSmartWallet -> whitelisted ✓
        uint256 sharesBefore = IERC20(address(plasmaVault)).balanceOf(userEOA);
        plasmaVault.deposit(50e6, userEOA);
        uint256 sharesAfter = IERC20(address(plasmaVault)).balanceOf(userEOA);
        vm.stopPrank();

        // Verify deposit succeeded
        assertTrue(sharesAfter > sharesBefore, "EOA with whitelisted delegation should receive shares");
    }

    /// @notice Test simulating EOA authorization with a NON-whitelisted smart wallet contract
    /// @dev This test demonstrates that unauthorized smart wallets are blocked:
    ///      1. Deploy an untrusted SmartWallet contract
    ///      2. DO NOT whitelist it
    ///      3. EOA "delegates" to the untrusted SmartWallet
    ///      4. EOA tries to interact with the vault
    ///      5. PreHook reverts because SmartWallet is NOT whitelisted
    function testEIP7702AuthorizationWithNonWhitelistedSmartWalletReverts() public {
        // ========== STEP 1: Deploy trusted and untrusted SmartWallets ==========
        MockSmartWallet trustedSmartWallet = new MockSmartWallet();
        MockSmartWallet untrustedSmartWallet = new MockSmartWallet(); // Different instance, not whitelisted

        // ========== STEP 2: Governance only whitelists the trusted SmartWallet ==========
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = PlasmaVault.deposit.selector;

        address[] memory preHooks = new address[](1);
        preHooks[0] = address(preHook);

        bytes32[][] memory substrates = new bytes32[][](1);
        substrates[0] = new bytes32[](1);
        substrates[0][0] = bytes32(uint256(uint160(address(trustedSmartWallet)))); // Only trusted one

        vm.prank(TestAddresses.ATOMIST);
        PlasmaVaultGovernance(address(plasmaVault)).setPreHookImplementations(selectors, preHooks, substrates);

        // ========== STEP 3: EOA delegates to the UNTRUSTED SmartWallet ==========
        // This simulates a malicious or unknown smart wallet
        _setDelegationCode(userEOA, address(untrustedSmartWallet));

        // ========== STEP 4: EOA tries to interact with the vault ==========
        vm.startPrank(userEOA, userEOA);
        IERC20(USDC).approve(address(plasmaVault), 100e6);

        // ========== STEP 5: PreHook reverts the transaction ==========
        // PreHook validates: msg.sender (userEOA) -> delegated to untrustedSmartWallet -> NOT in whitelist ✗
        vm.expectRevert(
            abi.encodeWithSelector(
                EIP7702DelegateValidationPreHook.InvalidDelegateTarget.selector,
                userEOA,
                address(untrustedSmartWallet)
            )
        );
        plasmaVault.deposit(50e6, userEOA);
        vm.stopPrank();
    }

    /// @notice Test simulating multiple EOAs with different delegations
    /// @dev Demonstrates that different EOAs can have different delegations,
    ///      and each is validated independently
    function testMultipleEOAsWithDifferentDelegations() public {
        // Deploy two smart wallets
        MockSmartWallet smartWallet1 = new MockSmartWallet();
        MockSmartWallet smartWallet2 = new MockSmartWallet();

        // Create two fresh EOA addresses
        address alice = _createFreshEOA("alice");
        address bob = _createFreshEOA("bob");
        deal(USDC, alice, 1000e6);
        deal(USDC, bob, 1000e6);

        // Whitelist ONLY smartWallet1
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = PlasmaVault.deposit.selector;

        address[] memory preHooks = new address[](1);
        preHooks[0] = address(preHook);

        bytes32[][] memory substrates = new bytes32[][](1);
        substrates[0] = new bytes32[](1);
        substrates[0][0] = bytes32(uint256(uint160(address(smartWallet1))));

        vm.prank(TestAddresses.ATOMIST);
        PlasmaVaultGovernance(address(plasmaVault)).setPreHookImplementations(selectors, preHooks, substrates);

        // Alice delegates to smartWallet1 (whitelisted)
        _setDelegationCode(alice, address(smartWallet1));

        // Bob delegates to smartWallet2 (NOT whitelisted)
        _setDelegationCode(bob, address(smartWallet2));

        // Alice's deposit should succeed
        vm.startPrank(alice, alice);
        IERC20(USDC).approve(address(plasmaVault), 100e6);
        plasmaVault.deposit(50e6, alice);
        vm.stopPrank();

        assertTrue(IERC20(address(plasmaVault)).balanceOf(alice) > 0, "Alice should have shares");

        // Bob's deposit should fail
        vm.startPrank(bob, bob);
        IERC20(USDC).approve(address(plasmaVault), 100e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                EIP7702DelegateValidationPreHook.InvalidDelegateTarget.selector,
                bob,
                address(smartWallet2)
            )
        );
        plasmaVault.deposit(50e6, bob);
        vm.stopPrank();
    }

    /// @notice Test simulating governance updating whitelist to add/remove smart wallets
    /// @dev Demonstrates dynamic whitelist management by governance
    function testGovernanceCanUpdateWhitelist() public {
        MockSmartWallet smartWallet = new MockSmartWallet();

        // Set up EOA with delegation
        _setDelegationCode(userEOA, address(smartWallet));

        // Initially, no whitelist configured - EOA with delegation will be rejected
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = PlasmaVault.deposit.selector;

        address[] memory preHooks = new address[](1);
        preHooks[0] = address(preHook);

        bytes32[][] memory emptySubstrates = new bytes32[][](1);
        emptySubstrates[0] = new bytes32[](0);

        vm.prank(TestAddresses.ATOMIST);
        PlasmaVaultGovernance(address(plasmaVault)).setPreHookImplementations(selectors, preHooks, emptySubstrates);

        // Attempt deposit - should fail (empty whitelist)
        vm.startPrank(userEOA, userEOA);
        IERC20(USDC).approve(address(plasmaVault), 100e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                EIP7702DelegateValidationPreHook.InvalidDelegateTarget.selector,
                userEOA,
                address(smartWallet)
            )
        );
        plasmaVault.deposit(50e6, userEOA);
        vm.stopPrank();

        // Governance adds the smart wallet to whitelist
        bytes32[][] memory updatedSubstrates = new bytes32[][](1);
        updatedSubstrates[0] = new bytes32[](1);
        updatedSubstrates[0][0] = bytes32(uint256(uint160(address(smartWallet))));

        vm.prank(TestAddresses.ATOMIST);
        PlasmaVaultGovernance(address(plasmaVault)).setPreHookImplementations(selectors, preHooks, updatedSubstrates);

        // Now deposit should succeed
        vm.startPrank(userEOA, userEOA);
        plasmaVault.deposit(50e6, userEOA);
        vm.stopPrank();

        assertTrue(IERC20(address(plasmaVault)).balanceOf(userEOA) > 0, "Deposit should succeed after whitelist update");
    }

    // ============================================
    // msg.sender vs tx.origin Demonstration Tests
    // ============================================

    /// @notice Demonstrates that tx.origin (initiator) without delegation passes through
    /// @dev When msg.sender has no delegation code, the check passes regardless of tx.origin
    function testMsgSenderValidation_CallerWithoutDelegationPasses() public {
        // Deploy a router contract WITHOUT any delegation code
        MockVaultCaller router = new MockVaultCaller();
        // router has normal contract code (not 23 bytes, not EIP-7702)

        // Whitelist some smart wallet (doesn't matter which)
        MockSmartWallet someWallet = new MockSmartWallet();

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = PlasmaVault.deposit.selector;

        address[] memory preHooks = new address[](1);
        preHooks[0] = address(preHook);

        bytes32[][] memory substrates = new bytes32[][](1);
        substrates[0] = new bytes32[](1);
        substrates[0][0] = bytes32(uint256(uint160(address(someWallet))));

        vm.prank(TestAddresses.ATOMIST);
        PlasmaVaultGovernance(address(plasmaVault)).setPreHookImplementations(selectors, preHooks, substrates);

        // Give userEOA delegation to a NON-whitelisted wallet
        MockSmartWallet userMaliciousWallet = new MockSmartWallet();
        _setDelegationCode(userEOA, address(userMaliciousWallet));

        // userEOA (tx.origin, has malicious delegation) calls through router
        // tx.origin = userEOA (has non-whitelisted delegation)
        // msg.sender = router (no delegation code - normal contract)

        // With msg.sender check: router has no delegation -> PASSES (router is just a contract)
        // With tx.origin check: userEOA's delegation would be checked -> would REVERT

        // This demonstrates that msg.sender check focuses on the DIRECT CALLER
        // The router is a normal contract, so it passes through

        vm.startPrank(userEOA, userEOA);
        IERC20(USDC).approve(address(router), 100e6);

        // Should succeed - router (msg.sender) has no delegation code
        router.callDeposit(address(plasmaVault), USDC, 50e6, userEOA);
        vm.stopPrank();

        assertTrue(IERC20(address(plasmaVault)).balanceOf(userEOA) > 0, "Deposit through router should succeed");
    }

    /// @notice Key demonstration: Direct caller with delegation is always validated
    /// @dev This shows the core behavior - whoever calls the vault directly is checked
    function testMsgSenderValidation_DirectCallerWithDelegationIsAlwaysChecked() public {
        MockSmartWallet whitelistedWallet = new MockSmartWallet();
        MockSmartWallet nonWhitelistedWallet = new MockSmartWallet();

        // Only whitelist one wallet
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = PlasmaVault.deposit.selector;

        address[] memory preHooks = new address[](1);
        preHooks[0] = address(preHook);

        bytes32[][] memory substrates = new bytes32[][](1);
        substrates[0] = new bytes32[](1);
        substrates[0][0] = bytes32(uint256(uint160(address(whitelistedWallet))));

        vm.prank(TestAddresses.ATOMIST);
        PlasmaVaultGovernance(address(plasmaVault)).setPreHookImplementations(selectors, preHooks, substrates);

        // Case 1: userEOA delegates to whitelisted wallet -> should pass
        _setDelegationCode(userEOA, address(whitelistedWallet));

        vm.startPrank(userEOA, userEOA);
        IERC20(USDC).approve(address(plasmaVault), 100e6);
        plasmaVault.deposit(25e6, userEOA);
        vm.stopPrank();

        uint256 sharesAfterFirst = IERC20(address(plasmaVault)).balanceOf(userEOA);
        assertTrue(sharesAfterFirst > 0, "Whitelisted delegation should pass");

        // Case 2: Change userEOA delegation to non-whitelisted wallet -> should fail
        _setDelegationCode(userEOA, address(nonWhitelistedWallet));

        vm.startPrank(userEOA, userEOA);

        vm.expectRevert(
            abi.encodeWithSelector(
                EIP7702DelegateValidationPreHook.InvalidDelegateTarget.selector,
                userEOA,
                address(nonWhitelistedWallet)
            )
        );
        plasmaVault.deposit(25e6, userEOA);
        vm.stopPrank();

        // Shares should not have changed
        assertEq(
            IERC20(address(plasmaVault)).balanceOf(userEOA),
            sharesAfterFirst,
            "Non-whitelisted delegation should be blocked"
        );
    }

    /// @notice Demonstrates the scenario from documentation: Bob calls Alice's SmartWallet
    /// @dev In EIP-7702: Bob -> Alice (SmartWallet code runs) -> Vault
    ///      tx.origin = Bob, msg.sender = Alice
    ///      We validate Alice (msg.sender) who has the delegation
    function testMsgSenderValidation_ThirdPartyCallsEOAWithDelegation() public {
        // Setup: Alice has delegation to a whitelisted SmartWallet
        address alice = _createFreshEOA("alice");
        MockSmartWallet aliceSmartWallet = new MockSmartWallet();

        // Whitelist Alice's SmartWallet
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = PlasmaVault.deposit.selector;

        address[] memory preHooks = new address[](1);
        preHooks[0] = address(preHook);

        bytes32[][] memory substrates = new bytes32[][](1);
        substrates[0] = new bytes32[](1);
        substrates[0][0] = bytes32(uint256(uint160(address(aliceSmartWallet))));

        vm.prank(TestAddresses.ATOMIST);
        PlasmaVaultGovernance(address(plasmaVault)).setPreHookImplementations(selectors, preHooks, substrates);

        // Set Alice's delegation code
        _setDelegationCode(alice, address(aliceSmartWallet));

        // Give Alice some USDC
        deal(USDC, alice, 1000e6);

        // In real EIP-7702, when Bob calls Alice, Alice's SmartWallet code executes
        // and Alice becomes msg.sender when that code calls the vault.
        //
        // We simulate this by having Alice call the vault directly
        // (in reality, Bob would trigger this, but Alice's address would be msg.sender)

        // Simulation: Alice's SmartWallet code calls vault (Alice is msg.sender)
        // tx.origin could be anyone (Bob), but msg.sender is Alice
        address bob = _createFreshEOA("bob");

        vm.startPrank(alice, bob); // msg.sender = Alice, tx.origin = Bob
        IERC20(USDC).approve(address(plasmaVault), 100e6);

        // PreHook checks msg.sender (Alice) who has whitelisted delegation -> PASS
        // If it checked tx.origin (Bob), Bob has no delegation -> would skip validation (security hole)
        plasmaVault.deposit(50e6, alice);
        vm.stopPrank();

        assertTrue(
            IERC20(address(plasmaVault)).balanceOf(alice) > 0,
            "Alice with whitelisted delegation should be able to deposit"
        );
    }

    /// @notice Shows what happens when third party triggers EOA with non-whitelisted delegation
    /// @dev Bob -> Alice (non-whitelisted SmartWallet) -> Vault should REVERT
    function testMsgSenderValidation_ThirdPartyCallsEOAWithNonWhitelistedDelegation() public {
        address alice = _createFreshEOA("alice");
        MockSmartWallet aliceNonWhitelistedWallet = new MockSmartWallet();
        MockSmartWallet otherWhitelistedWallet = new MockSmartWallet();

        // Whitelist a DIFFERENT wallet (not Alice's)
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = PlasmaVault.deposit.selector;

        address[] memory preHooks = new address[](1);
        preHooks[0] = address(preHook);

        bytes32[][] memory substrates = new bytes32[][](1);
        substrates[0] = new bytes32[](1);
        substrates[0][0] = bytes32(uint256(uint160(address(otherWhitelistedWallet))));

        vm.prank(TestAddresses.ATOMIST);
        PlasmaVaultGovernance(address(plasmaVault)).setPreHookImplementations(selectors, preHooks, substrates);

        // Alice delegates to a NON-whitelisted wallet
        _setDelegationCode(alice, address(aliceNonWhitelistedWallet));

        deal(USDC, alice, 1000e6);

        address bob = _createFreshEOA("bob");

        // Bob triggers Alice's SmartWallet code (Alice is msg.sender)
        vm.startPrank(alice, bob); // msg.sender = Alice, tx.origin = Bob
        IERC20(USDC).approve(address(plasmaVault), 100e6);

        // PreHook checks msg.sender (Alice) -> delegation to non-whitelisted wallet -> REVERT
        vm.expectRevert(
            abi.encodeWithSelector(
                EIP7702DelegateValidationPreHook.InvalidDelegateTarget.selector,
                alice, // msg.sender (Alice has the delegation)
                address(aliceNonWhitelistedWallet)
            )
        );
        plasmaVault.deposit(50e6, alice);
        vm.stopPrank();
    }
}
