// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {MidasBalanceFuse} from "contracts/fuses/midas/MidasBalanceFuse.sol";
import {MidasSubstrate, MidasSubstrateType} from "contracts/fuses/midas/lib/MidasSubstrateLib.sol";
import {MidasSubstrateLib} from "contracts/fuses/midas/lib/MidasSubstrateLib.sol";
import {IMidasDepositVault} from "contracts/fuses/midas/ext/IMidasDepositVault.sol";
import {IMidasRedemptionVault} from "contracts/fuses/midas/ext/IMidasRedemptionVault.sol";
import {IporMath} from "contracts/libraries/math/IporMath.sol";
import {Errors} from "contracts/libraries/errors/Errors.sol";

import {MidasBalanceFuseHarness} from "./mocks/MidasBalanceFuseHarness.sol";
import {MockMidasDepositVaultForBalance} from "./mocks/MockMidasDepositVaultForBalance.sol";
import {MockMidasRedemptionVaultForBalance} from "./mocks/MockMidasRedemptionVaultForBalance.sol";
import {MockMidasDataFeedForBalance} from "./mocks/MockMidasDataFeedForBalance.sol";
import {MockPriceOracleMiddlewareForBalance} from "./mocks/MockPriceOracleMiddlewareForBalance.sol";
import {MockERC20ForBalance} from "./mocks/MockERC20ForBalance.sol";

/// @title MidasBalanceFuseTest
/// @notice Unit tests for MidasBalanceFuse — 100% branch coverage target.
///         Uses MidasBalanceFuseHarness (inherits MidasBalanceFuse) so that address(this)
///         is the harness, simulating the PlasmaVault delegatecall context.
contract MidasBalanceFuseTest is Test {
    // ============ Constants ============

    uint256 constant MARKET_ID = 42;
    uint256 constant WAD = 1e18;

    // ============ State Variables ============

    MidasBalanceFuseHarness harness;
    MockMidasDepositVaultForBalance depositVault;
    MockMidasDepositVaultForBalance depositVault2;
    MockMidasRedemptionVaultForBalance redemptionVault;
    MockMidasRedemptionVaultForBalance redemptionVault2;
    MockMidasDataFeedForBalance dataFeed;
    MockMidasDataFeedForBalance dataFeed2;
    MockPriceOracleMiddlewareForBalance oracle;
    MockERC20ForBalance mTokenA;
    MockERC20ForBalance mTokenB;
    MockERC20ForBalance usdc;
    MockERC20ForBalance dai;
    MockERC20ForBalance wbtc;

    address executor;

    // ============ Setup ============

    function setUp() public {
        harness = new MidasBalanceFuseHarness(MARKET_ID);

        depositVault = new MockMidasDepositVaultForBalance();
        depositVault2 = new MockMidasDepositVaultForBalance();
        redemptionVault = new MockMidasRedemptionVaultForBalance();
        redemptionVault2 = new MockMidasRedemptionVaultForBalance();
        dataFeed = new MockMidasDataFeedForBalance();
        dataFeed2 = new MockMidasDataFeedForBalance();
        oracle = new MockPriceOracleMiddlewareForBalance();

        mTokenA = new MockERC20ForBalance(18);
        mTokenB = new MockERC20ForBalance(18);
        usdc = new MockERC20ForBalance(6);
        dai = new MockERC20ForBalance(18);
        wbtc = new MockERC20ForBalance(8);

        executor = makeAddr("executor");

        vm.label(address(harness), "MidasBalanceFuseHarness");
        vm.label(address(depositVault), "DepositVault1");
        vm.label(address(depositVault2), "DepositVault2");
        vm.label(address(redemptionVault), "RedemptionVault1");
        vm.label(address(redemptionVault2), "RedemptionVault2");
        vm.label(address(dataFeed), "DataFeed1");
        vm.label(address(dataFeed2), "DataFeed2");
        vm.label(address(oracle), "PriceOracle");
        vm.label(address(mTokenA), "mTokenA");
        vm.label(address(mTokenB), "mTokenB");
        vm.label(address(usdc), "USDC");
        vm.label(address(dai), "DAI");
        vm.label(address(wbtc), "WBTC");
        vm.label(executor, "Executor");
    }

    // ============ Helper Functions ============

    /// @dev Build a single DEPOSIT_VAULT substrate bytes32
    function _depositVaultSubstrate(address vault_) internal pure returns (bytes32) {
        return MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.DEPOSIT_VAULT, substrateAddress: vault_})
        );
    }

    /// @dev Build a single REDEMPTION_VAULT substrate bytes32
    function _redemptionVaultSubstrate(address vault_) internal pure returns (bytes32) {
        return MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.REDEMPTION_VAULT, substrateAddress: vault_})
        );
    }

    /// @dev Build a single ASSET substrate bytes32
    function _assetSubstrate(address asset_) internal pure returns (bytes32) {
        return MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.ASSET, substrateAddress: asset_})
        );
    }

    /// @dev Build a M_TOKEN substrate bytes32
    function _mTokenSubstrate(address mToken_) internal pure returns (bytes32) {
        return MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.M_TOKEN, substrateAddress: mToken_})
        );
    }

    /// @dev Build a INSTANT_REDEMPTION_VAULT substrate bytes32
    function _instantRedemptionVaultSubstrate(address vault_) internal pure returns (bytes32) {
        return MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.INSTANT_REDEMPTION_VAULT, substrateAddress: vault_})
        );
    }

    /// @dev Set up a single deposit vault with mToken and data feed
    function _setupDepositVault(
        MockMidasDepositVaultForBalance vault_,
        MockERC20ForBalance mToken_,
        MockMidasDataFeedForBalance feed_,
        uint256 price_,
        uint256 harnessBalance_
    ) internal {
        vault_.setMToken(address(mToken_));
        vault_.setMTokenDataFeed(address(feed_));
        feed_.setPrice(price_);
        mToken_.setBalance(address(harness), harnessBalance_);
    }

    /// @dev Grant a single deposit vault substrate to harness market
    function _grantDepositVault(MockMidasDepositVaultForBalance vault_) internal {
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = _depositVaultSubstrate(address(vault_));
        harness.setMarketSubstrates(MARKET_ID, substrates);
    }

    /// @dev Create a pending deposit request on the harness storage
    function _addPendingDepositRequest(
        address vault_,
        uint256 requestId_,
        uint8 status_,
        uint256 usdAmount_
    ) internal {
        MockMidasDepositVaultForBalance(vault_).setMintRequest(
            requestId_,
            IMidasDepositVault.Request({
                sender: address(this),
                tokenIn: address(usdc),
                status: status_,
                depositedUsdAmount: usdAmount_,
                usdAmountWithoutFees: usdAmount_,
                tokenOutRate: 0
            })
        );
        harness.addPendingDeposit(vault_, requestId_);
    }

    /// @dev Create a pending redemption request on the harness storage
    function _addPendingRedemptionRequest(
        address vault_,
        uint256 requestId_,
        uint8 status_,
        uint256 amountMToken_
    ) internal {
        MockMidasRedemptionVaultForBalance(vault_).setRedeemRequest(
            requestId_,
            IMidasRedemptionVault.Request({
                sender: address(this),
                tokenOut: address(usdc),
                status: status_,
                amountMToken: amountMToken_,
                mTokenRate: 0,
                tokenOutRate: 0
            })
        );
        harness.addPendingRedemption(vault_, requestId_);
    }

    // ============ Constructor Tests ============

    /// @dev Branch: C1 — revert when marketId is zero
    function test_constructor_ShouldRevert_WhenMarketIdIsZero() public {
        // When / Then
        vm.expectRevert(abi.encodeWithSelector(Errors.WrongValue.selector));
        new MidasBalanceFuse(0);
    }

    /// @dev Branch: C2 — immutables set correctly when marketId is valid
    function test_constructor_ShouldSetImmutables_WhenMarketIdIsValid() public {
        // When
        MidasBalanceFuse fuse = new MidasBalanceFuse(1);

        // Then
        assertEq(fuse.MARKET_ID(), 1, "MARKET_ID should be 1");
        assertEq(fuse.VERSION(), address(fuse), "VERSION should be address of fuse");
    }

    // ============ Empty State Tests ============

    /// @dev Branch: B1 — no substrates configured
    function test_balanceOf_ShouldReturnZero_WhenNoSubstrates() public {
        // Given: no substrates set (default empty)
        // When
        uint256 balance = harness.balanceOf();
        // Then
        assertEq(balance, 0, "Should return 0 when no substrates configured");
    }

    /// @dev Branch: B5 — only M_TOKEN and INSTANT_REDEMPTION_VAULT substrate types
    function test_balanceOf_ShouldReturnZero_WhenOnlyNonRelevantSubstrateTypes() public {
        // Given: substrates with types that are not DEPOSIT_VAULT, REDEMPTION_VAULT, or ASSET
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = _mTokenSubstrate(address(mTokenA));
        substrates[1] = _instantRedemptionVaultSubstrate(address(redemptionVault));
        harness.setMarketSubstrates(MARKET_ID, substrates);

        // When
        uint256 balance = harness.balanceOf();

        // Then: no deposit vaults → no mTokens resolved → no components computed
        assertEq(balance, 0, "Should return 0 when only M_TOKEN and INSTANT_REDEMPTION_VAULT substrates exist");
    }

    // ============ Component A: mToken Balance Tests ============

    /// @dev Branches: B7, B8 — single mToken with balance and price
    function test_balanceOf_ComponentA_ShouldReturnCorrectValue_WhenSingleMTokenWithBalance() public {
        // Given
        _setupDepositVault(depositVault, mTokenA, dataFeed, 1.05e18, 100e18);
        _grantDepositVault(depositVault);

        // Expected: convertToWad(100e18 * 1.05e18, 36) = 105e18
        uint256 expected = IporMath.convertToWad(100e18 * 1.05e18, 36);

        // When
        uint256 balance = harness.balanceOf();

        // Then
        assertEq(balance, expected, "Component A should return 105e18 for 100 tokens at 1.05 price");
        assertEq(balance, 105e18, "Component A should equal 105e18");
    }

    /// @dev Branch: B9 — mToken balance is zero
    function test_balanceOf_ComponentA_ShouldReturnZero_WhenMTokenBalanceIsZero() public {
        // Given: mToken balance on harness = 0
        _setupDepositVault(depositVault, mTokenA, dataFeed, 1.05e18, 0);
        _grantDepositVault(depositVault);

        // When
        uint256 balance = harness.balanceOf();

        // Then
        assertEq(balance, 0, "Component A should return 0 when mToken balance is zero");
    }

    /// @dev Branch: B10 — mToken price is zero
    function test_balanceOf_ComponentA_ShouldRevert_WhenMTokenPriceIsZero() public {
        // Given: price = 0
        _setupDepositVault(depositVault, mTokenA, dataFeed, 0, 100e18);
        _grantDepositVault(depositVault);

        // When & Then
        vm.expectRevert(abi.encodeWithSelector(MidasBalanceFuse.MTokenPriceIsZero.selector, address(mTokenA)));
        harness.balanceOf();
    }

    /// @dev Branches: B6, B7 — two deposit vaults sharing same mToken → counted once
    function test_balanceOf_ComponentA_ShouldDeduplicateMTokens_WhenMultipleDepositVaultsShareSameMToken() public {
        // Given: two deposit vaults, same mToken, same data feed
        depositVault.setMToken(address(mTokenA));
        depositVault.setMTokenDataFeed(address(dataFeed));
        depositVault2.setMToken(address(mTokenA));
        depositVault2.setMTokenDataFeed(address(dataFeed));
        dataFeed.setPrice(2e18);
        mTokenA.setBalance(address(harness), 50e18);

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = _depositVaultSubstrate(address(depositVault));
        substrates[1] = _depositVaultSubstrate(address(depositVault2));
        harness.setMarketSubstrates(MARKET_ID, substrates);

        // Expected: counted once: convertToWad(50e18 * 2e18, 36) = 100e18
        uint256 expected = IporMath.convertToWad(50e18 * 2e18, 36);

        // When
        uint256 balance = harness.balanceOf();

        // Then
        assertEq(balance, expected, "Same mToken should be counted only once even with two deposit vaults");
        assertEq(balance, 100e18, "Should be 100e18");
    }

    /// @dev Branches: B7, B8 — two deposit vaults with different mTokens
    function test_balanceOf_ComponentA_ShouldSumMultipleMTokens_WhenDifferentMTokensExist() public {
        // Given
        depositVault.setMToken(address(mTokenA));
        depositVault.setMTokenDataFeed(address(dataFeed));
        dataFeed.setPrice(1e18);
        mTokenA.setBalance(address(harness), 100e18);

        depositVault2.setMToken(address(mTokenB));
        depositVault2.setMTokenDataFeed(address(dataFeed2));
        dataFeed2.setPrice(1.5e18);
        mTokenB.setBalance(address(harness), 200e18);

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = _depositVaultSubstrate(address(depositVault));
        substrates[1] = _depositVaultSubstrate(address(depositVault2));
        harness.setMarketSubstrates(MARKET_ID, substrates);

        // Expected: 100e18 (mTokenA) + 300e18 (mTokenB) = 400e18
        uint256 expectedA = IporMath.convertToWad(100e18 * 1e18, 36);
        uint256 expectedB = IporMath.convertToWad(200e18 * 1.5e18, 36);

        // When
        uint256 balance = harness.balanceOf();

        // Then
        assertEq(balance, expectedA + expectedB, "Should sum mTokenA + mTokenB values");
        assertEq(balance, 400e18, "Should equal 400e18");
    }

    // ============ Component B: Pending Deposit Tests ============

    /// @dev Branch: PD3 — single pending deposit request
    function test_balanceOf_ComponentB_ShouldReturnCorrectValue_WhenSinglePendingDeposit() public {
        // Given: deposit vault with 0 mToken balance (focus on pending)
        _setupDepositVault(depositVault, mTokenA, dataFeed, 1e18, 0);
        _grantDepositVault(depositVault);

        // Add pending deposit request (status=0)
        _addPendingDepositRequest(address(depositVault), 1, 0, 1000e18);

        // When
        uint256 balance = harness.balanceOf();

        // Then
        assertEq(balance, 1000e18, "Component B should return depositedUsdAmount for pending request");
    }

    /// @dev Branches: PD3, PD4 — mix of pending, processed, and canceled requests
    function test_balanceOf_ComponentB_ShouldSkipNonPendingRequests() public {
        // Given
        _setupDepositVault(depositVault, mTokenA, dataFeed, 1e18, 0);
        _grantDepositVault(depositVault);

        // Request ID 1: Pending (status=0)
        _addPendingDepositRequest(address(depositVault), 1, 0, 500e18);
        // Request ID 2: Processed (status=1) — skip
        _addPendingDepositRequest(address(depositVault), 2, 1, 300e18);
        // Request ID 3: Canceled (status=2) — skip
        _addPendingDepositRequest(address(depositVault), 3, 2, 200e18);

        // When
        uint256 balance = harness.balanceOf();

        // Then: only status=0 counted
        assertEq(balance, 500e18, "Should only count pending (status=0) deposit requests");
    }

    /// @dev Branch: PD2 — no pending request IDs in storage for deposit vault
    function test_balanceOf_ComponentB_ShouldReturnZero_WhenNoPendingDeposits() public {
        // Given: deposit vault with no pending requests
        _setupDepositVault(depositVault, mTokenA, dataFeed, 1e18, 0);
        _grantDepositVault(depositVault);
        // No addPendingDeposit calls

        // When
        uint256 balance = harness.balanceOf();

        // Then
        assertEq(balance, 0, "Should return 0 when no pending deposit request IDs in storage");
    }

    /// @dev Branch: PD3 — sum across multiple deposit vaults
    function test_balanceOf_ComponentB_ShouldSumAcrossMultipleDepositVaults() public {
        // Given: two deposit vaults, no mToken balance
        depositVault.setMToken(address(mTokenA));
        depositVault.setMTokenDataFeed(address(dataFeed));
        dataFeed.setPrice(1e18);
        mTokenA.setBalance(address(harness), 0);

        depositVault2.setMToken(address(mTokenB));
        depositVault2.setMTokenDataFeed(address(dataFeed2));
        dataFeed2.setPrice(1e18);
        mTokenB.setBalance(address(harness), 0);

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = _depositVaultSubstrate(address(depositVault));
        substrates[1] = _depositVaultSubstrate(address(depositVault2));
        harness.setMarketSubstrates(MARKET_ID, substrates);

        _addPendingDepositRequest(address(depositVault), 1, 0, 100e18);
        _addPendingDepositRequest(address(depositVault2), 1, 0, 200e18);

        // When
        uint256 balance = harness.balanceOf();

        // Then: 100e18 + 200e18 = 300e18
        assertEq(balance, 300e18, "Should sum pending deposits across multiple deposit vaults");
    }

    // ============ Component C: Pending Redemption Tests ============

    /// @dev Branches: PR3, PR5 — single pending redemption request
    function test_balanceOf_ComponentC_ShouldReturnCorrectValue_WhenSinglePendingRedemption() public {
        // Given: deposit vault (mTokenA, price=1.05e18, 0 balance) + redemption vault (mTokenA)
        _setupDepositVault(depositVault, mTokenA, dataFeed, 1.05e18, 0);
        redemptionVault.setMToken(address(mTokenA));

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = _depositVaultSubstrate(address(depositVault));
        substrates[1] = _redemptionVaultSubstrate(address(redemptionVault));
        harness.setMarketSubstrates(MARKET_ID, substrates);

        _addPendingRedemptionRequest(address(redemptionVault), 1, 0, 100e18);

        // Expected: convertToWad(100e18 * 1.05e18, 36) = 105e18
        uint256 expected = IporMath.convertToWad(100e18 * 1.05e18, 36);

        // When
        uint256 balance = harness.balanceOf();

        // Then
        assertEq(balance, expected, "Component C should value pending redemption at mToken price");
        assertEq(balance, 105e18, "Should equal 105e18");
    }

    /// @dev Branches: PR5, PR6 — skip non-pending redemption requests
    function test_balanceOf_ComponentC_ShouldSkipNonPendingRedemptions() public {
        // Given
        _setupDepositVault(depositVault, mTokenA, dataFeed, 1e18, 0);
        redemptionVault.setMToken(address(mTokenA));

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = _depositVaultSubstrate(address(depositVault));
        substrates[1] = _redemptionVaultSubstrate(address(redemptionVault));
        harness.setMarketSubstrates(MARKET_ID, substrates);

        // Request 1: Pending (status=0) — count
        _addPendingRedemptionRequest(address(redemptionVault), 1, 0, 100e18);
        // Request 2: Processed (status=1) — skip
        _addPendingRedemptionRequest(address(redemptionVault), 2, 1, 200e18);

        // When
        uint256 balance = harness.balanceOf();

        // Then: only status=0: convertToWad(100e18 * 1e18, 36) = 100e18
        assertEq(balance, 100e18, "Should only count pending (status=0) redemption requests");
    }

    /// @dev Branch: PR4 — mToken not found in deposit vaults → price=0
    function test_balanceOf_ComponentC_ShouldRevert_WhenMTokenNotFoundInDepositVaults() public {
        // Given: deposit vault has mTokenA, redemption vault has mTokenB
        _setupDepositVault(depositVault, mTokenA, dataFeed, 1e18, 0);
        redemptionVault.setMToken(address(mTokenB)); // different mToken

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = _depositVaultSubstrate(address(depositVault));
        substrates[1] = _redemptionVaultSubstrate(address(redemptionVault));
        harness.setMarketSubstrates(MARKET_ID, substrates);

        _addPendingRedemptionRequest(address(redemptionVault), 1, 0, 100e18);

        // When & Then: mTokenB not found in deposit vaults → revert
        vm.expectRevert(abi.encodeWithSelector(MidasBalanceFuse.MTokenPriceIsZero.selector, address(mTokenB)));
        harness.balanceOf();
    }

    /// @dev Branch: PR2 — no pending request IDs for redemption vault
    function test_balanceOf_ComponentC_ShouldReturnZero_WhenNoRedemptionRequestIds() public {
        // Given
        _setupDepositVault(depositVault, mTokenA, dataFeed, 1e18, 0);
        redemptionVault.setMToken(address(mTokenA));

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = _depositVaultSubstrate(address(depositVault));
        substrates[1] = _redemptionVaultSubstrate(address(redemptionVault));
        harness.setMarketSubstrates(MARKET_ID, substrates);
        // No addPendingRedemption calls

        // When
        uint256 balance = harness.balanceOf();

        // Then
        assertEq(balance, 0, "Component C should return 0 when no redemption request IDs in storage");
    }

    /// @dev Branches: PR3, PR5 — sum across multiple redemption vaults
    function test_balanceOf_ComponentC_ShouldSumAcrossMultipleRedemptionVaults() public {
        // Given: deposit vault provides mTokenA with price=2e18
        _setupDepositVault(depositVault, mTokenA, dataFeed, 2e18, 0);
        redemptionVault.setMToken(address(mTokenA));
        redemptionVault2.setMToken(address(mTokenA));

        bytes32[] memory substrates = new bytes32[](3);
        substrates[0] = _depositVaultSubstrate(address(depositVault));
        substrates[1] = _redemptionVaultSubstrate(address(redemptionVault));
        substrates[2] = _redemptionVaultSubstrate(address(redemptionVault2));
        harness.setMarketSubstrates(MARKET_ID, substrates);

        _addPendingRedemptionRequest(address(redemptionVault), 1, 0, 50e18);
        _addPendingRedemptionRequest(address(redemptionVault2), 1, 0, 30e18);

        // Expected: convertToWad(50e18 * 2e18, 36) + convertToWad(30e18 * 2e18, 36) = 100e18 + 60e18 = 160e18
        uint256 expectedC = IporMath.convertToWad(50e18 * 2e18, 36) + IporMath.convertToWad(30e18 * 2e18, 36);

        // When
        uint256 balance = harness.balanceOf();

        // Then
        assertEq(balance, expectedC, "Should sum pending redemptions across multiple redemption vaults");
        assertEq(balance, 160e18, "Should equal 160e18");
    }

    // ============ Component D: Executor Balance Tests ============

    /// @dev Branch: E1 — no executor set (address(0))
    function test_balanceOf_ComponentD_ShouldReturnZero_WhenNoExecutorSet() public {
        // Given: executor is not set (address(0) by default)
        _setupDepositVault(depositVault, mTokenA, dataFeed, 1e18, 0);
        _grantDepositVault(depositVault);

        // When
        uint256 balance = harness.balanceOf();

        // Then
        assertEq(balance, 0, "Component D should return 0 when no executor set");
    }

    /// @dev Branch: E2 — executor holds mTokens
    function test_balanceOf_ComponentD_ShouldReturnMTokenValue_WhenExecutorHoldsMTokens() public {
        // Given
        _setupDepositVault(depositVault, mTokenA, dataFeed, 1.1e18, 0);
        _grantDepositVault(depositVault);
        mTokenA.setBalance(executor, 50e18); // executor holds mTokens
        harness.setExecutor(executor);

        // Expected D.a: convertToWad(50e18 * 1.1e18, 36) = 55e18
        uint256 expected = IporMath.convertToWad(50e18 * 1.1e18, 36);

        // When
        uint256 balance = harness.balanceOf();

        // Then
        assertEq(balance, expected, "Component D should value executor mToken holdings");
        assertEq(balance, 55e18, "Should equal 55e18");
    }

    /// @dev Branch: E3 — executor mToken balance is zero
    function test_balanceOf_ComponentD_ShouldSkipMToken_WhenExecutorMTokenBalanceIsZero() public {
        // Given
        _setupDepositVault(depositVault, mTokenA, dataFeed, 1.1e18, 0);
        _grantDepositVault(depositVault);
        mTokenA.setBalance(executor, 0); // executor has no mTokens
        harness.setExecutor(executor);

        // When
        uint256 balance = harness.balanceOf();

        // Then
        assertEq(balance, 0, "Component D.a should return 0 when executor mToken balance is zero");
    }

    /// @dev Branch: E4 — executor mToken balance > 0 but price = 0 → revert
    function test_balanceOf_ComponentD_ShouldRevert_WhenMTokenPriceIsZero() public {
        // Given: mToken price = 0
        _setupDepositVault(depositVault, mTokenA, dataFeed, 0, 0);
        _grantDepositVault(depositVault);
        mTokenA.setBalance(executor, 100e18);
        harness.setExecutor(executor);

        // When & Then
        vm.expectRevert(abi.encodeWithSelector(MidasBalanceFuse.MTokenPriceIsZero.selector, address(mTokenA)));
        harness.balanceOf();
    }

    /// @dev Branch: E6 — executor holds USDC (6 decimals) asset
    function test_balanceOf_ComponentD_ShouldReturnAssetValue_WhenExecutorHoldsAssets() public {
        // Given: deposit vault (no mToken balance) + USDC asset substrate
        _setupDepositVault(depositVault, mTokenA, dataFeed, 1e18, 0);
        harness.setExecutor(executor);
        harness.setPriceOracle(address(oracle));
        oracle.setAssetPrice(address(usdc), 1e8, 8);
        usdc.setBalance(executor, 1000e6); // USDC 6 decimals

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = _depositVaultSubstrate(address(depositVault));
        substrates[1] = _assetSubstrate(address(usdc));
        harness.setMarketSubstrates(MARKET_ID, substrates);

        // Expected D.b: convertToWad(1000e6 * 1e8, 6+8) = convertToWad(1000e14, 14) = 1000e18
        uint256 expected = IporMath.convertToWad(1000e6 * 1e8, 14);

        // When
        uint256 balance = harness.balanceOf();

        // Then
        assertEq(balance, expected, "Component D.b should correctly value USDC holdings on executor");
        assertEq(balance, 1000e18, "Should equal 1000e18");
    }

    /// @dev Branch: E5 — price oracle is address(0) → revert when assets configured
    function test_balanceOf_ComponentD_ShouldRevert_WhenPriceOracleIsZeroAddress() public {
        // Given: executor set, priceOracle = address(0) (default), asset substrate configured
        _setupDepositVault(depositVault, mTokenA, dataFeed, 1e18, 0);
        harness.setExecutor(executor);
        // priceOracle NOT set (stays address(0))
        usdc.setBalance(executor, 1000e6);

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = _depositVaultSubstrate(address(depositVault));
        substrates[1] = _assetSubstrate(address(usdc));
        harness.setMarketSubstrates(MARKET_ID, substrates);

        // When & Then: revert because priceOracle is not set but assets are configured
        vm.expectRevert(abi.encodeWithSelector(MidasBalanceFuse.MidasBalanceFusePriceOracleNotSet.selector));
        harness.balanceOf();
    }

    /// @dev Branch: E7 — executor asset balance is zero
    function test_balanceOf_ComponentD_ShouldSkipAsset_WhenAssetBalanceOnExecutorIsZero() public {
        // Given
        _setupDepositVault(depositVault, mTokenA, dataFeed, 1e18, 0);
        harness.setExecutor(executor);
        harness.setPriceOracle(address(oracle));
        oracle.setAssetPrice(address(usdc), 1e8, 8);
        usdc.setBalance(executor, 0); // zero balance

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = _depositVaultSubstrate(address(depositVault));
        substrates[1] = _assetSubstrate(address(usdc));
        harness.setMarketSubstrates(MARKET_ID, substrates);

        // When
        uint256 balance = harness.balanceOf();

        // Then: asset balance=0 → no price lookup, no contribution
        assertEq(balance, 0, "Component D.b should skip assets with zero balance on executor");
    }

    /// @dev Branches: E2, E6 — executor holds both mTokens and assets
    function test_balanceOf_ComponentD_ShouldSumMTokensAndAssets() public {
        // Given: deposit vault + asset substrate + executor
        _setupDepositVault(depositVault, mTokenA, dataFeed, 1e18, 0);
        harness.setExecutor(executor);
        harness.setPriceOracle(address(oracle));
        oracle.setAssetPrice(address(usdc), 1e8, 8);

        mTokenA.setBalance(executor, 100e18); // D.a: 100e18 * 1e18 → 100e18
        usdc.setBalance(executor, 500e6); // D.b: 500e6 * 1e8 → convertToWad(500e14, 14) = 500e18

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = _depositVaultSubstrate(address(depositVault));
        substrates[1] = _assetSubstrate(address(usdc));
        harness.setMarketSubstrates(MARKET_ID, substrates);

        // Expected: 100e18 (mToken) + 500e18 (USDC) = 600e18
        uint256 expectedDA = IporMath.convertToWad(100e18 * 1e18, 36);
        uint256 expectedDB = IporMath.convertToWad(500e6 * 1e8, 14);

        // When
        uint256 balance = harness.balanceOf();

        // Then
        assertEq(balance, expectedDA + expectedDB, "Component D should sum mToken and asset values");
        assertEq(balance, 600e18, "Should equal 600e18");
    }

    // ============ Full Integration Tests (All Components) ============

    /// @dev Branches: B8, PD3, PR5, E2, E6 — all four components active
    function test_balanceOf_ShouldSumAllFourComponents() public {
        // Given
        _setupDepositVault(depositVault, mTokenA, dataFeed, 1e18, 100e18); // A: 100e18
        redemptionVault.setMToken(address(mTokenA));
        harness.setExecutor(executor);
        harness.setPriceOracle(address(oracle));
        oracle.setAssetPrice(address(usdc), 1e8, 8);
        mTokenA.setBalance(executor, 30e18);    // D.a: 30e18
        usdc.setBalance(executor, 500e6);        // D.b: 500e18

        bytes32[] memory substrates = new bytes32[](3);
        substrates[0] = _depositVaultSubstrate(address(depositVault));
        substrates[1] = _redemptionVaultSubstrate(address(redemptionVault));
        substrates[2] = _assetSubstrate(address(usdc));
        harness.setMarketSubstrates(MARKET_ID, substrates);

        _addPendingDepositRequest(address(depositVault), 1, 0, 200e18);   // B: 200e18
        _addPendingRedemptionRequest(address(redemptionVault), 1, 0, 50e18); // C: 50e18

        // Expected total: 100 + 200 + 50 + 30 + 500 = 880e18
        uint256 componentA = IporMath.convertToWad(100e18 * 1e18, 36);
        uint256 componentB = 200e18;
        uint256 componentC = IporMath.convertToWad(50e18 * 1e18, 36);
        uint256 componentDA = IporMath.convertToWad(30e18 * 1e18, 36);
        uint256 componentDB = IporMath.convertToWad(500e6 * 1e8, 14);

        // When
        uint256 balance = harness.balanceOf();

        // Then
        assertEq(
            balance,
            componentA + componentB + componentC + componentDA + componentDB,
            "Should sum all four components correctly"
        );
        assertEq(balance, 880e18, "Total should be 880e18");
    }

    /// @dev All components are zero
    function test_balanceOf_ShouldReturnZero_WhenAllComponentsAreZero() public {
        // Given: deposit vault configured but all balances zero, no pending requests, no executor
        _setupDepositVault(depositVault, mTokenA, dataFeed, 1e18, 0);
        _grantDepositVault(depositVault);

        // When
        uint256 balance = harness.balanceOf();

        // Then
        assertEq(balance, 0, "Should return 0 when all components are zero");
    }

    // ============ Cross-Asset / Interaction Tests ============

    /// @dev Branches: B2, B3, B4, B5 — mixed substrate types
    function test_balanceOf_ShouldHandleMixedSubstrateTypes() public {
        // Given: mix of DEPOSIT_VAULT, REDEMPTION_VAULT, ASSET, M_TOKEN, INSTANT_REDEMPTION_VAULT
        _setupDepositVault(depositVault, mTokenA, dataFeed, 2e18, 10e18);
        redemptionVault.setMToken(address(mTokenA));
        harness.setExecutor(executor);
        harness.setPriceOracle(address(oracle));
        oracle.setAssetPrice(address(usdc), 1e8, 8);
        usdc.setBalance(executor, 100e6);

        bytes32[] memory substrates = new bytes32[](5);
        substrates[0] = _depositVaultSubstrate(address(depositVault));       // B2: processed
        substrates[1] = _redemptionVaultSubstrate(address(redemptionVault)); // B3: processed
        substrates[2] = _assetSubstrate(address(usdc));                      // B4: processed
        substrates[3] = _mTokenSubstrate(address(mTokenB));                  // B5: ignored
        substrates[4] = _instantRedemptionVaultSubstrate(makeAddr("irv"));   // B5: ignored
        harness.setMarketSubstrates(MARKET_ID, substrates);

        // When
        uint256 balance = harness.balanceOf();

        // Then: only DEPOSIT_VAULT (A), REDEMPTION_VAULT (C), ASSET (D.b) types contribute
        uint256 componentA = IporMath.convertToWad(10e18 * 2e18, 36); // 20e18
        uint256 componentDB = IporMath.convertToWad(100e6 * 1e8, 14); // 100e18
        assertEq(balance, componentA + componentDB, "Only DEPOSIT_VAULT, REDEMPTION_VAULT, ASSET should be processed");
        assertEq(balance, 120e18, "Should equal 120e18");
    }

    /// @dev Branch: E6 — multiple assets with different decimals on executor
    function test_balanceOf_ShouldHandleMultipleAssetsOnExecutor_WithDifferentDecimals() public {
        // Given
        _setupDepositVault(depositVault, mTokenA, dataFeed, 1e18, 0);
        harness.setExecutor(executor);
        harness.setPriceOracle(address(oracle));

        // USDC 6 decimals, price 1e8 (8 dec) → convertToWad(1000e6 * 1e8, 14) = 1000e18
        oracle.setAssetPrice(address(usdc), 1e8, 8);
        usdc.setBalance(executor, 1000e6);

        // DAI 18 decimals, price 1e18 (18 dec) → convertToWad(2000e18 * 1e18, 36) = 2000e18
        oracle.setAssetPrice(address(dai), 1e18, 18);
        dai.setBalance(executor, 2000e18);

        // WBTC 8 decimals, price 60000e8 (8 dec) → convertToWad(1e8 * 60000e8, 16) = 60000e18
        oracle.setAssetPrice(address(wbtc), 60000e8, 8);
        wbtc.setBalance(executor, 1e8);

        bytes32[] memory substrates = new bytes32[](4);
        substrates[0] = _depositVaultSubstrate(address(depositVault));
        substrates[1] = _assetSubstrate(address(usdc));
        substrates[2] = _assetSubstrate(address(dai));
        substrates[3] = _assetSubstrate(address(wbtc));
        harness.setMarketSubstrates(MARKET_ID, substrates);

        // When
        uint256 balance = harness.balanceOf();

        // Then: 1000 + 2000 + 60000 = 63000e18
        uint256 usdcValue = IporMath.convertToWad(1000e6 * 1e8, 14);
        uint256 daiValue = IporMath.convertToWad(2000e18 * 1e18, 36);
        uint256 wbtcValue = IporMath.convertToWad(1e8 * 60000e8, 16);
        assertEq(balance, usdcValue + daiValue + wbtcValue, "Should correctly value assets with different decimals");
        assertEq(balance, 63000e18, "Should equal 63000e18");
    }

    /// @dev Same mToken used by deposit vault and redemption vault
    function test_balanceOf_ShouldCorrectlySeparatePendingDepositsAndRedemptionsForSameVaultMToken() public {
        // Given: same mToken for deposit and redemption vault
        _setupDepositVault(depositVault, mTokenA, dataFeed, 2e18, 0);
        redemptionVault.setMToken(address(mTokenA));

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = _depositVaultSubstrate(address(depositVault));
        substrates[1] = _redemptionVaultSubstrate(address(redemptionVault));
        harness.setMarketSubstrates(MARKET_ID, substrates);

        _addPendingDepositRequest(address(depositVault), 1, 0, 500e18); // B=500e18
        _addPendingRedemptionRequest(address(redemptionVault), 1, 0, 100e18); // C=200e18

        // When
        uint256 balance = harness.balanceOf();

        // Then: B=500e18, C=100e18 * 2e18 / 1e18=200e18, Total=700e18
        uint256 expectedB = 500e18;
        uint256 expectedC = IporMath.convertToWad(100e18 * 2e18, 36);
        assertEq(balance, expectedB + expectedC, "Should separate pending deposits and redemptions");
        assertEq(balance, 700e18, "Should equal 700e18");
    }

    /// @dev One mToken balance zero, other non-zero — only non-zero counted
    function test_balanceOf_ShouldHandleOneAssetZeroBalance_OthersNonZero() public {
        // Given
        depositVault.setMToken(address(mTokenA));
        depositVault.setMTokenDataFeed(address(dataFeed));
        dataFeed.setPrice(1e18);
        mTokenA.setBalance(address(harness), 0); // contributes nothing

        depositVault2.setMToken(address(mTokenB));
        depositVault2.setMTokenDataFeed(address(dataFeed2));
        dataFeed2.setPrice(1.5e18);
        mTokenB.setBalance(address(harness), 200e18); // contributes 300e18

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = _depositVaultSubstrate(address(depositVault));
        substrates[1] = _depositVaultSubstrate(address(depositVault2));
        harness.setMarketSubstrates(MARKET_ID, substrates);

        // When
        uint256 balance = harness.balanceOf();

        // Then: only mTokenB contribution
        assertEq(balance, 300e18, "Should only count mTokenB (mTokenA balance is zero)");
    }

    // ============ Boundary Value & Decimal Scaling Tests ============

    /// @dev Decimal scaling: mToken * price = 36 total decimals → WAD
    function test_balanceOf_ComponentA_ShouldHandleConversion_WhenTotalDecimals36() public {
        // Given: balance=1e18 (18 dec), price=1e18 (18 dec) → 36 total
        _setupDepositVault(depositVault, mTokenA, dataFeed, 1e18, 1e18);
        _grantDepositVault(depositVault);

        // Expected: convertToWad(1e36, 36) = 1e18
        uint256 expected = IporMath.convertToWad(1e18 * 1e18, 36);

        // When
        uint256 balance = harness.balanceOf();

        // Then
        assertEq(balance, expected, "Should correctly convert 36-decimal product to WAD");
        assertEq(balance, 1e18, "Should equal 1e18");
    }

    /// @dev Asset with 0 decimals on executor
    function test_balanceOf_ComponentD_ShouldHandleAssetDecimals0() public {
        // Given: asset with 0 decimals, balance=100, price=1e8 (8 dec)
        MockERC20ForBalance zeroDecAsset = new MockERC20ForBalance(0);
        vm.label(address(zeroDecAsset), "ZeroDecAsset");

        _setupDepositVault(depositVault, mTokenA, dataFeed, 1e18, 0);
        harness.setExecutor(executor);
        harness.setPriceOracle(address(oracle));
        oracle.setAssetPrice(address(zeroDecAsset), 1e8, 8);
        zeroDecAsset.setBalance(executor, 100);

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = _depositVaultSubstrate(address(depositVault));
        substrates[1] = _assetSubstrate(address(zeroDecAsset));
        harness.setMarketSubstrates(MARKET_ID, substrates);

        // Expected: convertToWad(100 * 1e8, 0+8) = convertToWad(100e8, 8) = 100e18
        uint256 expected = IporMath.convertToWad(100 * 1e8, 8);

        // When
        uint256 balance = harness.balanceOf();

        // Then
        assertEq(balance, expected, "Should handle asset with 0 decimals");
        assertEq(balance, 100e18, "Should equal 100e18");
    }

    /// @dev Asset with 18 decimals on executor
    function test_balanceOf_ComponentD_ShouldHandleAssetDecimals18() public {
        // Given: asset with 18 decimals, balance=500e18, price=1e18 (18 dec)
        _setupDepositVault(depositVault, mTokenA, dataFeed, 1e18, 0);
        harness.setExecutor(executor);
        harness.setPriceOracle(address(oracle));
        oracle.setAssetPrice(address(dai), 1e18, 18);
        dai.setBalance(executor, 500e18);

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = _depositVaultSubstrate(address(depositVault));
        substrates[1] = _assetSubstrate(address(dai));
        harness.setMarketSubstrates(MARKET_ID, substrates);

        // Expected: convertToWad(500e18 * 1e18, 36) = 500e18
        uint256 expected = IporMath.convertToWad(500e18 * 1e18, 36);

        // When
        uint256 balance = harness.balanceOf();

        // Then
        assertEq(balance, expected, "Should handle asset with 18 decimals");
        assertEq(balance, 500e18, "Should equal 500e18");
    }

    /// @dev totalDecimals = 19 (scale down by 1)
    function test_balanceOf_ComponentD_ShouldHandleMinimalScaleDown_Decimals19() public {
        // Given: asset 1 decimal, price 18 dec → totalDecimals=19
        MockERC20ForBalance oneDecAsset = new MockERC20ForBalance(1);
        vm.label(address(oneDecAsset), "OneDecAsset");

        _setupDepositVault(depositVault, mTokenA, dataFeed, 1e18, 0);
        harness.setExecutor(executor);
        harness.setPriceOracle(address(oracle));
        oracle.setAssetPrice(address(oneDecAsset), 2e18, 18);
        oneDecAsset.setBalance(executor, 10); // 1.0 in 1-decimal

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = _depositVaultSubstrate(address(depositVault));
        substrates[1] = _assetSubstrate(address(oneDecAsset));
        harness.setMarketSubstrates(MARKET_ID, substrates);

        // Expected: convertToWad(10 * 2e18, 19) = convertToWad(20e18, 19) = 20e18 / 10 = 2e18
        uint256 expected = IporMath.convertToWad(10 * 2e18, 19);

        // When
        uint256 balance = harness.balanceOf();

        // Then
        assertEq(balance, expected, "Should handle totalDecimals=19 (scale down by 1)");
        assertEq(balance, 2e18, "Should equal 2e18");
    }

    /// @dev totalDecimals = 17 (scale up by 1)
    function test_balanceOf_ComponentD_ShouldHandleMinimalScaleUp_Decimals17() public {
        // Given: asset 9 decimals, price 8 dec → totalDecimals=17
        MockERC20ForBalance nineDecAsset = new MockERC20ForBalance(9);
        vm.label(address(nineDecAsset), "NineDecAsset");

        _setupDepositVault(depositVault, mTokenA, dataFeed, 1e18, 0);
        harness.setExecutor(executor);
        harness.setPriceOracle(address(oracle));
        oracle.setAssetPrice(address(nineDecAsset), 1e8, 8);
        nineDecAsset.setBalance(executor, 1e9); // 1.0 in 9-decimal

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = _depositVaultSubstrate(address(depositVault));
        substrates[1] = _assetSubstrate(address(nineDecAsset));
        harness.setMarketSubstrates(MARKET_ID, substrates);

        // Expected: convertToWad(1e9 * 1e8, 17) = convertToWad(1e17, 17) = 1e17 * 10 = 1e18
        uint256 expected = IporMath.convertToWad(1e9 * 1e8, 17);

        // When
        uint256 balance = harness.balanceOf();

        // Then
        assertEq(balance, expected, "Should handle totalDecimals=17 (scale up by 1)");
        assertEq(balance, 1e18, "Should equal 1e18");
    }

    /// @dev Edge: mToken price = 1 (minimum non-zero, extremely low)
    function test_balanceOf_ShouldHandlePriceEqualTo1() public {
        // Given: mToken balance=1e18, price=1 (minimum raw value)
        _setupDepositVault(depositVault, mTokenA, dataFeed, 1, 1e18);
        _grantDepositVault(depositVault);

        // Expected: convertToWad(1e18 * 1, 36) = convertToWad(1e18, 36) = 1e18 / 1e18 = 1
        uint256 expected = IporMath.convertToWad(1e18 * 1, 36);

        // When
        uint256 balance = harness.balanceOf();

        // Then: result is 1 (dust amount due to extremely low price)
        assertEq(balance, expected, "Should handle minimum price of 1");
        assertEq(balance, 1, "Should equal 1 (dust amount)");
    }

    // ============ Overflow / Large Value Tests ============

    /// @dev B8: max uint128 balance and price (no overflow since both are uint128 → product fits uint256)
    function test_balanceOf_ComponentA_ShouldNotOverflow_WhenBalanceAndPriceAreMaxUint128() public {
        uint256 maxU128 = type(uint128).max;
        _setupDepositVault(depositVault, mTokenA, dataFeed, maxU128, maxU128);
        _grantDepositVault(depositVault);

        // uint128.max * uint128.max fits in uint256 (max ~1.15e77, product ~3.4e76)
        uint256 expectedProduct = maxU128 * maxU128;
        uint256 expected = IporMath.convertToWad(expectedProduct, 36);

        // When
        uint256 balance = harness.balanceOf();

        // Then: no overflow, correct result
        assertEq(balance, expected, "Should handle max uint128 balance and price without overflow");
    }

    /// @dev B8: large but realistic values (1B tokens at $100K each)
    function test_balanceOf_ComponentA_ShouldHandleLargeButRealisticValues() public {
        uint256 bigBalance = 1_000_000_000e18; // 1B tokens
        uint256 bigPrice = 100_000e18; // $100K per token

        _setupDepositVault(depositVault, mTokenA, dataFeed, bigPrice, bigBalance);
        _grantDepositVault(depositVault);

        // Expected: convertToWad(1e27 * 1e23, 36) = convertToWad(1e50, 36) = 1e32
        uint256 expected = IporMath.convertToWad(bigBalance * bigPrice, 36);

        // When
        uint256 balance = harness.balanceOf();

        // Then: 100 trillion USD
        assertEq(balance, expected, "Should handle large realistic values without overflow");
        assertEq(balance, 1e32, "Should equal 1e32");
    }

    /// @dev PR5: max uint128 mToken amount and price
    function test_balanceOf_ComponentC_ShouldNotOverflow_WithMaxAmountAndPrice() public {
        uint256 maxU128 = type(uint128).max;
        _setupDepositVault(depositVault, mTokenA, dataFeed, maxU128, 0);
        redemptionVault.setMToken(address(mTokenA));

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = _depositVaultSubstrate(address(depositVault));
        substrates[1] = _redemptionVaultSubstrate(address(redemptionVault));
        harness.setMarketSubstrates(MARKET_ID, substrates);

        _addPendingRedemptionRequest(address(redemptionVault), 1, 0, maxU128);

        uint256 expected = IporMath.convertToWad(maxU128 * maxU128, 36);

        // When
        uint256 balance = harness.balanceOf();

        // Then: no overflow
        assertEq(balance, expected, "Component C should handle max uint128 amounts without overflow");
    }

    /// @dev E6: max uint128 asset balance and price — using 18+18=36 total decimals (division path) to avoid overflow
    function test_balanceOf_ComponentD_ShouldNotOverflow_AssetCalculation() public {
        uint256 maxU128 = type(uint128).max;

        // Use DAI (18 decimals) with oracle priceDecimals=18 → totalDecimals=36
        // convertToWad(maxU128 * maxU128, 36) divides by 1e18, no overflow
        _setupDepositVault(depositVault, mTokenA, dataFeed, 1e18, 0);
        harness.setExecutor(executor);
        harness.setPriceOracle(address(oracle));
        oracle.setAssetPrice(address(dai), maxU128, 18); // priceDecimals=18, combined=36
        dai.setBalance(executor, maxU128);

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = _depositVaultSubstrate(address(depositVault));
        substrates[1] = _assetSubstrate(address(dai));
        harness.setMarketSubstrates(MARKET_ID, substrates);

        // product = maxU128 * maxU128 ~ 1.157e77, convertToWad(_, 36) divides by 1e18 → result ~ 1.157e59 (no overflow)
        uint256 expected = IporMath.convertToWad(maxU128 * maxU128, 36);

        // When
        uint256 balance = harness.balanceOf();

        // Then: no overflow when using 36 combined decimals (division path)
        assertEq(balance, expected, "Component D should handle max uint128 asset calculation without overflow");
    }

    // ============ Edge Case Tests ============

    /// @dev Single DEPOSIT_VAULT substrate only
    function test_balanceOf_ShouldHandleSingleSubstrate_DepositVaultOnly() public {
        // Given: only deposit vault, mToken balance=10e18 at price=1e18
        _setupDepositVault(depositVault, mTokenA, dataFeed, 1e18, 10e18);
        _grantDepositVault(depositVault);

        // When
        uint256 balance = harness.balanceOf();

        // Then: A = 10e18 (no C, no D since no executor, no B since no pending requests)
        assertEq(balance, 10e18, "Single deposit vault should only contribute Component A");
    }

    /// @dev Single REDEMPTION_VAULT substrate only (no deposit vault → no mToken price → revert)
    function test_balanceOf_ShouldRevert_WhenRedemptionVaultOnly() public {
        // Given: only redemption vault, no deposit vault
        redemptionVault.setMToken(address(mTokenA));

        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = _redemptionVaultSubstrate(address(redemptionVault));
        harness.setMarketSubstrates(MARKET_ID, substrates);

        _addPendingRedemptionRequest(address(redemptionVault), 1, 0, 100e18);

        // When & Then: no deposit vault → mToken array is empty → mTokenPrice=0 → revert
        vm.expectRevert(abi.encodeWithSelector(MidasBalanceFuse.MTokenPriceIsZero.selector, address(mTokenA)));
        harness.balanceOf();
    }

    /// @dev Single ASSET substrate only
    function test_balanceOf_ShouldHandleSingleSubstrate_AssetOnly() public {
        // Given: only asset substrate, executor set with balance
        harness.setExecutor(executor);
        harness.setPriceOracle(address(oracle));
        oracle.setAssetPrice(address(usdc), 1e8, 8);
        usdc.setBalance(executor, 500e6);

        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = _assetSubstrate(address(usdc));
        harness.setMarketSubstrates(MARKET_ID, substrates);

        // When
        uint256 balance = harness.balanceOf();

        // Then: only D.b contributes
        uint256 expected = IporMath.convertToWad(500e6 * 1e8, 14);
        assertEq(balance, expected, "Single asset substrate should only contribute Component D.b");
        assertEq(balance, 500e18, "Should equal 500e18");
    }

    /// @dev PR4: redemption vault mToken does not match any deposit vault → revert
    function test_balanceOf_ComponentC_ShouldRevert_WhenRedemptionVaultMTokenDoesNotMatchAnyDepositVault()
        public
    {
        // Given: deposit vault has mTokenA, redemption vault has mTokenB
        _setupDepositVault(depositVault, mTokenA, dataFeed, 1e18, 0);
        redemptionVault.setMToken(address(mTokenB)); // different

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = _depositVaultSubstrate(address(depositVault));
        substrates[1] = _redemptionVaultSubstrate(address(redemptionVault));
        harness.setMarketSubstrates(MARKET_ID, substrates);

        _addPendingRedemptionRequest(address(redemptionVault), 1, 0, 50e18);

        // When & Then: mTokenB not found in deposit vaults → revert
        vm.expectRevert(abi.encodeWithSelector(MidasBalanceFuse.MTokenPriceIsZero.selector, address(mTokenB)));
        harness.balanceOf();
    }

    /// @dev Multiple pending requests for same deposit vault
    function test_balanceOf_ShouldHandleMultiplePendingRequestsForSameVault() public {
        // Given: 3 pending requests for same deposit vault
        _setupDepositVault(depositVault, mTokenA, dataFeed, 1e18, 0);
        _grantDepositVault(depositVault);

        _addPendingDepositRequest(address(depositVault), 1, 0, 100e18);
        _addPendingDepositRequest(address(depositVault), 2, 0, 200e18);
        _addPendingDepositRequest(address(depositVault), 3, 0, 300e18);

        // When
        uint256 balance = harness.balanceOf();

        // Then: 100 + 200 + 300 = 600e18
        assertEq(balance, 600e18, "Should sum all pending requests for the same vault");
    }

    // ============ Fuzz Tests ============

    /// @dev Fuzz: Component A matches manual WAD calculation
    function test_fuzz_balanceOf_ComponentA_ShouldMatchManualCalculation(
        uint128 mTokenBalance,
        uint128 mTokenPrice
    ) public {
        vm.assume(mTokenBalance > 0);
        vm.assume(mTokenPrice > 0);

        _setupDepositVault(depositVault, mTokenA, dataFeed, uint256(mTokenPrice), uint256(mTokenBalance));
        _grantDepositVault(depositVault);

        // Invariant: balanceOf == convertToWad(balance * price, 36) == balance * price / 1e18
        uint256 expectedProduct = uint256(mTokenBalance) * uint256(mTokenPrice);
        uint256 expected = IporMath.convertToWad(expectedProduct, 36);

        uint256 balance = harness.balanceOf();

        assertEq(balance, expected, "Fuzz: Component A should match convertToWad(balance * price, 36)");
    }

    /// @dev Fuzz: Component B matches depositedUsdAmount directly
    function test_fuzz_balanceOf_ComponentB_ShouldMatchDepositedUsdAmount(uint128 depositedAmount) public {
        vm.assume(depositedAmount > 0);

        _setupDepositVault(depositVault, mTokenA, dataFeed, 1e18, 0);
        _grantDepositVault(depositVault);
        _addPendingDepositRequest(address(depositVault), 1, 0, uint256(depositedAmount));

        uint256 balance = harness.balanceOf();

        // Invariant: balanceOf == depositedAmount (already in 18 decimals)
        assertEq(balance, uint256(depositedAmount), "Fuzz: Component B should equal depositedUsdAmount");
    }

    /// @dev Fuzz: Component C matches mToken amount * price calculation
    function test_fuzz_balanceOf_ComponentC_ShouldMatchRedemptionCalculation(
        uint128 amountMToken,
        uint128 mTokenPrice
    ) public {
        vm.assume(amountMToken > 0);
        vm.assume(mTokenPrice > 0);

        _setupDepositVault(depositVault, mTokenA, dataFeed, uint256(mTokenPrice), 0);
        redemptionVault.setMToken(address(mTokenA));

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = _depositVaultSubstrate(address(depositVault));
        substrates[1] = _redemptionVaultSubstrate(address(redemptionVault));
        harness.setMarketSubstrates(MARKET_ID, substrates);

        _addPendingRedemptionRequest(address(redemptionVault), 1, 0, uint256(amountMToken));

        uint256 expectedProduct = uint256(amountMToken) * uint256(mTokenPrice);
        uint256 expected = IporMath.convertToWad(expectedProduct, 36);
        uint256 balance = harness.balanceOf();

        assertEq(balance, expected, "Fuzz: Component C should match convertToWad(amountMToken * price, 36)");
    }

    /// @dev Fuzz: Component D asset valuation with varying decimals
    ///      Guards against overflow: when totalDecimals < 18, convertToWad multiplies by 10^(18-totalDecimals).
    ///      We only test inputs where the scaled product fits in uint256 (type(uint256).max / scaleFactor).
    function test_fuzz_balanceOf_ComponentD_AssetValuation(
        uint128 assetBalance,
        uint128 assetPrice,
        uint8 assetDecimals,
        uint8 priceDecimals
    ) public {
        vm.assume(assetBalance > 0);
        vm.assume(assetPrice > 0);
        vm.assume(assetDecimals <= 18);
        vm.assume(priceDecimals <= 18);

        uint256 product = uint256(assetBalance) * uint256(assetPrice);
        uint256 totalDecimals = uint256(assetDecimals) + uint256(priceDecimals);

        // Guard: if totalDecimals < 18, convertToWad multiplies by 10^(18-totalDecimals)
        // Ensure product * scaleFactor does not overflow uint256
        if (totalDecimals < 18) {
            uint256 scaleFactor = 10 ** (18 - totalDecimals);
            vm.assume(product <= type(uint256).max / scaleFactor);
        }

        MockERC20ForBalance fuzzAsset = new MockERC20ForBalance(assetDecimals);
        _setupDepositVault(depositVault, mTokenA, dataFeed, 1e18, 0);
        harness.setExecutor(executor);
        harness.setPriceOracle(address(oracle));
        oracle.setAssetPrice(address(fuzzAsset), uint256(assetPrice), uint256(priceDecimals));
        fuzzAsset.setBalance(executor, uint256(assetBalance));

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = _depositVaultSubstrate(address(depositVault));
        substrates[1] = _assetSubstrate(address(fuzzAsset));
        harness.setMarketSubstrates(MARKET_ID, substrates);

        uint256 expectedProduct = uint256(assetBalance) * uint256(assetPrice);
        uint256 expected = IporMath.convertToWad(expectedProduct, totalDecimals);
        uint256 balance = harness.balanceOf();

        assertEq(
            balance,
            expected,
            "Fuzz: Component D asset valuation should match IporMath.convertToWad formula"
        );
    }

    /// @dev Fuzz: no revert with realistic multi-vault inputs
    function test_fuzz_balanceOf_ShouldNotRevert_WithRealisticInputs(
        uint8 numDepositVaults,
        uint128 balance,
        uint128 price
    ) public {
        // Bound to realistic range (1-3 deposit vaults)
        numDepositVaults = uint8(bound(numDepositVaults, 1, 3));
        vm.assume(balance > 0);
        vm.assume(price > 0);
        vm.assume(uint256(balance) * uint256(price) <= type(uint256).max); // no overflow check

        bytes32[] memory substrates = new bytes32[](numDepositVaults);

        // We only have two deposit vault mocks, so cap at 2 for actual setup
        uint8 actualVaults = numDepositVaults > 2 ? 2 : numDepositVaults;

        if (actualVaults >= 1) {
            depositVault.setMToken(address(mTokenA));
            depositVault.setMTokenDataFeed(address(dataFeed));
            dataFeed.setPrice(uint256(price));
            mTokenA.setBalance(address(harness), uint256(balance));
            substrates[0] = _depositVaultSubstrate(address(depositVault));
        }
        if (actualVaults >= 2) {
            depositVault2.setMToken(address(mTokenB));
            depositVault2.setMTokenDataFeed(address(dataFeed2));
            dataFeed2.setPrice(uint256(price));
            mTokenB.setBalance(address(harness), uint256(balance));
            substrates[1] = _depositVaultSubstrate(address(depositVault2));
        }
        // Fill remaining with copy if numDepositVaults > 2
        for (uint8 i = actualVaults; i < numDepositVaults; i++) {
            substrates[i] = substrates[actualVaults - 1];
        }

        harness.setMarketSubstrates(MARKET_ID, substrates);

        // When: should not revert
        uint256 result = harness.balanceOf();

        // Invariant: result >= 0 (trivially true for uint256, but confirms no revert)
        assertGe(result, 0, "Fuzz: balanceOf should not revert and should return non-negative value");
    }
}
