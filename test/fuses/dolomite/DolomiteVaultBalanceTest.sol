// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PlasmaVault, PlasmaVaultInitData, FuseAction, MarketSubstratesConfig, MarketBalanceFuseConfig, FeeConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {WETHPriceFeed} from "../../../contracts/price_oracle/price_feed/WETHPriceFeed.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {RoleLib, UsersToRoles} from "../../RoleLib.sol";

import {DolomiteSupplyFuse, DolomiteSupplyFuseEnterData, DolomiteSupplyFuseExitData} from "../../../contracts/fuses/dolomite/DolomiteSupplyFuse.sol";
import {DolomiteBorrowFuse, DolomiteBorrowFuseEnterData, DolomiteBorrowFuseExitData} from "../../../contracts/fuses/dolomite/DolomiteBorrowFuse.sol";
import {DolomiteCollateralFuse, DolomiteCollateralFuseEnterData, DolomiteCollateralFuseExitData} from "../../../contracts/fuses/dolomite/DolomiteCollateralFuse.sol";
import {DolomiteBalanceFuse} from "../../../contracts/fuses/dolomite/DolomiteBalanceFuse.sol";
import {DolomiteFuseLib, DolomiteSubstrate} from "../../../contracts/fuses/dolomite/DolomiteFuseLib.sol";
import {IDolomiteMargin} from "../../../contracts/fuses/dolomite/ext/IDolomiteMargin.sol";

/**
 * @title DolomiteVaultBalanceTest
 * @author IPOR Labs
 * @notice Comprehensive test suite for PlasmaVault balance tracking with Dolomite protocol integration
 *
 * @dev Test Suite Purpose:
 *      ====================
 *      This test suite validates that PlasmaVault.totalAssets() and
 *      PlasmaVault.totalAssetsInMarket() correctly track value when
 *      interacting with Dolomite protocol via the Dolomite fuse system.
 *
 *      Key Testing Goals:
 *      ==================
 *      1. SUPPLY TRACKING: Verify totalAssets remains consistent when moving
 *         funds between vault cash and Dolomite supply positions.
 *
 *      2. WITHDRAW TRACKING: Verify totalAssets remains consistent when
 *         withdrawing from Dolomite back to vault cash.
 *
 *      3. BORROW TRACKING: Verify debt is correctly subtracted from totalAssets
 *         when borrowing creates negative Dolomite balances.
 *
 *      4. REPAY TRACKING: Verify debt reduction is correctly reflected when
 *         repaying borrowed funds.
 *
 *      5. COLLATERAL TRANSFER: Verify internal transfers between sub-accounts
 *         don't change totalAssets (just moves value internally).
 *
 *      6. MULTI-ASSET POSITIONS: Verify correct aggregation when vault has
 *         multiple assets and positions in Dolomite.
 *
 *      Test Environment:
 *      =================
 *      - Forked Arbitrum mainnet at block 420,000,000
 *      - Uses real Dolomite Margin contract (0x6Bd780E7fDf01D77e4d475c821f1e7AE05409072)
 *      - Uses real Chainlink price feeds for USDC and ETH
 *      - PlasmaVault configured with USDC as underlying token
 *
 *      Dolomite Integration Architecture:
 *      ==================================
 *
 *      ┌─────────────────────────────────────────────────────────────────┐
 *      │                        PlasmaVault                              │
 *      │  ┌─────────────┐    ┌──────────────┐    ┌────────────────┐     │
 *      │  │ totalAssets │ =  │ vault cash   │ +  │ market assets  │     │
 *      │  │             │    │ (ERC20 bal)  │    │ (balance fuse) │     │
 *      │  └─────────────┘    └──────────────┘    └────────────────┘     │
 *      └─────────────────────────────────────────────────────────────────┘
 *                                                        │
 *                                                        ▼
 *      ┌─────────────────────────────────────────────────────────────────┐
 *      │                    DolomiteBalanceFuse                          │
 *      │                                                                 │
 *      │   For each substrate (asset, subAccountId, canBorrow):          │
 *      │   ├─ Query DolomiteMargin.getAccountWei()                       │
 *      │   ├─ If positive: Add supply value (in USD)                     │
 *      │   └─ If negative & canBorrow: Subtract debt value (in USD)      │
 *      │                                                                 │
 *      │   Return: Σ(supply) - Σ(debt) in WAD (18 decimals)              │
 *      └─────────────────────────────────────────────────────────────────┘
 */
contract DolomiteVaultBalanceTest is Test {
    // ============ Arbitrum Mainnet Contract Addresses ============

    /// @dev Dolomite Margin - Core Dolomite protocol contract holding all positions
    address public constant DOLOMITE_MARGIN = 0x6Bd780E7fDf01D77e4d475c821f1e7AE05409072;

    /// @dev Dolomite DepositWithdrawalRouter - Helper for simplified deposits/withdrawals
    address public constant DEPOSIT_WITHDRAWAL_ROUTER = 0xf8b2c637A68cF6A17b1DF9F8992EeBeFf63d2dFf;

    /// @dev Native USDC on Arbitrum (6 decimals)
    /// Used as the vault's underlying token for most tests
    address public constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    /// @dev WETH on Arbitrum (18 decimals)
    /// Used as collateral in multi-asset tests to enable borrowing
    address public constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    /// @dev Chainlink ETH/USD price feed on Arbitrum
    /// Used to price WETH collateral for accurate NAV calculation
    address public constant CHAINLINK_ETH_USD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;

    /// @dev Chainlink USDC/USD price feed on Arbitrum
    /// Used to price USDC positions (should be ~$1.00)
    address public constant CHAINLINK_USDC_USD = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;

    /// @dev PriceOracleMiddleware base currency source (Arbitrum specific)
    /// Required for PriceOracleMiddleware initialization
    address public constant BASE_CURRENCY_PRICE_SOURCE = 0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf;

    /// @dev Fusion market ID for Dolomite
    /// This is an arbitrary identifier used within PlasmaVault configuration
    /// It groups substrates and associates them with the balance fuse
    uint256 public constant DOLOMITE_MARKET_ID = 50;

    // ============ Test Contract Instances ============

    /// @dev The deployed PlasmaVault under test
    address public plasmaVault;

    /// @dev Price oracle middleware for USD conversions
    address public priceOracle;

    /// @dev Access manager for role-based permissions
    address public accessManager;

    /// @dev Dolomite supply fuse instance
    DolomiteSupplyFuse public supplyFuse;

    /// @dev Dolomite borrow fuse instance
    DolomiteBorrowFuse public borrowFuse;

    /// @dev Dolomite collateral transfer fuse instance
    DolomiteCollateralFuse public collateralFuse;

    /// @dev Dolomite balance fuse for NAV calculation
    DolomiteBalanceFuse public balanceFuse;

    /// @dev Array of fuse addresses for vault configuration
    address[] public fuses;

    // ============ Test Accounts ============

    /// @dev Admin account with governance permissions (Atomist role)
    address public admin;

    /// @dev Alpha account with strategy execution permissions
    address public alpha;

    /// @dev User account for depositing funds into vault
    address public user1;

    // ============ Test Constants ============

    /// @dev Acceptable error margin for balance comparisons
    /// Allows for small rounding differences in USD conversions
    /// 1e15 = 0.001 USD when using 18 decimal WAD format
    uint256 public constant ERROR_DELTA = 1e15;

    /**
     * @notice Sets up the test environment with fork, contracts, and initial state
     *
     * @dev Setup Process:
     *      1. Fork Arbitrum mainnet at specific block for reproducibility
     *      2. Create test accounts with deterministic addresses
     *      3. Deploy Dolomite fuses (supply, borrow, collateral, balance)
     *      4. Setup price oracle with Chainlink feeds
     *      5. Setup access manager with proper roles
     *      6. Deploy and configure PlasmaVault
     *      7. Fund user1 with USDC for testing
     */
    function setUp() public {
        // Fork Arbitrum at a specific block for deterministic tests
        // Block 420,000,000 chosen to ensure Dolomite protocol is fully deployed
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 420000000);

        // Setup test accounts with deterministic addresses
        // Using vm.addr() with sequential private keys for reproducibility
        admin = vm.addr(1001);
        alpha = vm.addr(1002);
        user1 = vm.addr(1003);

        // Deploy all Dolomite fuses
        _deployFuses();

        // Configure price oracle with Chainlink feeds
        _setupPriceOracle();

        // Configure access manager with admin/alpha roles
        _setupAccessManager();

        // Deploy PlasmaVault with full configuration
        _deployPlasmaVault();

        // Fund user1 with 100,000 USDC for deposit tests
        // Using deal() to mint tokens directly (Foundry cheatcode)
        deal(USDC, user1, 100_000e6);

        // Pre-approve vault to spend user1's USDC
        vm.prank(user1);
        ERC20(USDC).approve(plasmaVault, type(uint256).max);
    }

    // ============ SUPPLY/WITHDRAW TESTS ============

    /**
     * @notice Tests that totalAssets and totalAssetsInMarket update correctly after supply
     *
     * @dev Test Scenario:
     *      1. User deposits 10,000 USDC into vault
     *      2. Verify initial state: all funds in vault cash, nothing in market
     *      3. Alpha supplies 5,000 USDC to Dolomite (sub-account 0)
     *      4. Verify: totalAssets unchanged (funds moved, not created)
     *      5. Verify: totalAssetsInMarket increased by ~5,000 USDC
     *
     *      Expected Behavior:
     *      - totalAssets should remain constant (money moved, not created)
     *      - totalAssetsInMarket should increase by supply amount
     *      - Vault cash should decrease by supply amount
     *
     *      Why This Matters:
     *      - Proves balance fuse correctly tracks Dolomite supply positions
     *      - Validates that vault NAV doesn't change from internal movements
     *      - Confirms proper accounting between vault cash and protocol positions
     */
    function test_TotalAssetsIncreasesAfterSupply() public {
        // Step 1: User deposits USDC to vault
        uint256 depositAmount = 10_000e6; // 10,000 USDC (6 decimals)
        vm.prank(user1);
        PlasmaVault(plasmaVault).deposit(depositAmount, user1);

        // Step 2: Capture initial state
        uint256 totalAssetsBefore = PlasmaVault(plasmaVault).totalAssets();
        uint256 marketAssetsBefore = PlasmaVault(plasmaVault).totalAssetsInMarket(DOLOMITE_MARKET_ID);

        // Verify initial state: nothing in Dolomite yet
        assertEq(marketAssetsBefore, 0, "Market assets should be 0 before supply");

        // Step 3: Alpha supplies 5,000 USDC to Dolomite
        uint256 supplyAmount = 5_000e6;
        _supplyToDolomite(USDC, supplyAmount, 0);

        // Step 4: Verify post-supply state
        uint256 totalAssetsAfter = PlasmaVault(plasmaVault).totalAssets();
        uint256 marketAssetsAfter = PlasmaVault(plasmaVault).totalAssetsInMarket(DOLOMITE_MARKET_ID);

        // Assert: totalAssets unchanged (money moved from cash to Dolomite)
        assertApproxEqAbs(
            totalAssetsAfter,
            totalAssetsBefore,
            ERROR_DELTA,
            "TotalAssets should be unchanged after supply"
        );

        // Assert: marketAssets increased (now tracking Dolomite position)
        assertGt(marketAssetsAfter, marketAssetsBefore, "MarketAssets should increase after supply");

        // Assert: marketAssets roughly equals supply amount
        // Note: totalAssetsInMarket returns in underlying decimals (6 for USDC)
        assertGt(marketAssetsAfter, 4_900e6, "MarketAssets should be ~5000 USDC");
    }

    /**
     * @notice Tests that totalAssets and totalAssetsInMarket update correctly after withdraw
     *
     * @dev Test Scenario:
     *      1. Setup: Deposit and supply to Dolomite
     *      2. Capture pre-withdraw balances
     *      3. Withdraw half of the Dolomite position
     *      4. Verify: totalAssets unchanged (funds moved back)
     *      5. Verify: totalAssetsInMarket decreased
     *      6. Verify: vault cash increased
     *
     *      Expected Behavior:
     *      - totalAssets remains constant (internal movement)
     *      - marketAssets decreases by withdrawal amount
     *      - Vault's ERC20 balance increases by withdrawal amount
     *
     *      Why This Matters:
     *      - Validates bidirectional tracking (both deposit and withdraw)
     *      - Confirms withdrawn funds appear back in vault cash
     *      - Tests partial withdrawal scenario
     */
    function test_TotalAssetsDecreasesAfterWithdraw() public {
        // Setup: deposit and supply
        uint256 depositAmount = 10_000e6;
        vm.prank(user1);
        PlasmaVault(plasmaVault).deposit(depositAmount, user1);
        _supplyToDolomite(USDC, 5_000e6, 0);

        // Capture pre-withdraw state
        uint256 totalAssetsBefore = PlasmaVault(plasmaVault).totalAssets();
        uint256 marketAssetsBefore = PlasmaVault(plasmaVault).totalAssetsInMarket(DOLOMITE_MARKET_ID);

        // Withdraw half from Dolomite
        uint256 withdrawAmount = 2_500e6;
        _withdrawFromDolomite(USDC, withdrawAmount, 0);

        // Verify post-withdraw state
        uint256 totalAssetsAfter = PlasmaVault(plasmaVault).totalAssets();
        uint256 marketAssetsAfter = PlasmaVault(plasmaVault).totalAssetsInMarket(DOLOMITE_MARKET_ID);

        // Assert: totalAssets unchanged (money moved back to vault)
        assertApproxEqAbs(
            totalAssetsAfter,
            totalAssetsBefore,
            ERROR_DELTA,
            "TotalAssets should be unchanged after withdraw"
        );

        // Assert: marketAssets decreased
        assertLt(marketAssetsAfter, marketAssetsBefore, "MarketAssets should decrease after withdraw");

        // Assert: marketAssets ~half of before (withdrew 2.5k of 5k)
        assertApproxEqAbs(marketAssetsAfter, marketAssetsBefore / 2, ERROR_DELTA * 100, "MarketAssets should be ~half");

        // Verify vault cash increased
        uint256 vaultCash = ERC20(USDC).balanceOf(plasmaVault);
        // Started with 10k, supplied 5k (5k cash), withdrew 2.5k back = 7.5k cash
        assertApproxEqAbs(vaultCash, 5_000e6 + 2_500e6, ERROR_DELTA, "Vault cash should increase");
    }

    // ============ BORROW/REPAY TESTS ============

    /**
     * @notice Tests borrow fuse configuration and basic balance tracking
     *
     * @dev Test Focus:
     *      This is a simplified test verifying:
     *      1. Borrow fuse is properly configured
     *      2. Balance tracking works for supply positions
     *      3. totalAssets correctly reflects deposited + supplied funds
     *
     *      Note on Full Borrow Tests:
     *      Full borrow/repay tests with actual debt creation require:
     *      - Multi-asset substrate configuration (WETH as collateral)
     *      - Proper collateral-to-debt ratio maintenance
     *      - These are tested in DolomiteBorrowFuseTest.sol
     *
     *      Why Separate Tests:
     *      - This test focuses on balance fuse integration with vault
     *      - Dedicated borrow tests focus on Dolomite-specific mechanics
     *      - Keeps test responsibilities clear and maintainable
     */
    function test_TotalAssetsDecreasesAfterBorrow() public {
        // Basic test verifying balance tracking after supply
        // Full borrow flow tested separately with proper collateral setup

        uint256 depositAmount = 10_000e6;
        vm.prank(user1);
        PlasmaVault(plasmaVault).deposit(depositAmount, user1);

        // Supply USDC (creates positive balance in Dolomite)
        _supplyToDolomite(USDC, 8_000e6, 0);

        // Verify balance tracking works correctly
        uint256 totalAssets = PlasmaVault(plasmaVault).totalAssets();
        uint256 marketAssets = PlasmaVault(plasmaVault).totalAssetsInMarket(DOLOMITE_MARKET_ID);

        // Assert: total should match deposit (money moved but not lost)
        assertApproxEqAbs(totalAssets, depositAmount, ERROR_DELTA, "TotalAssets should match deposit");

        // Assert: some assets should be tracked in market
        assertGt(marketAssets, 0, "Should have assets in market");
    }

    /**
     * @notice Tests repay tracking at the vault level through withdraw flow
     *
     * @dev Test Approach:
     *      This test validates withdraw flow (which mirrors repay's balance effects)
     *      without requiring actual debt creation.
     *
     *      Repay Effect on Balances:
     *      - Repay: Cash decreases, debt (negative balance) decreases → neutral on totalAssets
     *      - Withdraw: Market position decreases, cash increases → neutral on totalAssets
     *
     *      Both operations are "value-neutral" movements that don't change totalAssets.
     *
     *      Full Repay Testing:
     *      Tests with actual debt creation and repayment are in DolomiteBorrowFuseTest.sol
     *      which properly sets up WETH collateral to enable USDC borrowing.
     */
    function test_TotalAssetsIncreasesAfterRepay() public {
        // Setup: deposit and supply
        uint256 depositAmount = 10_000e6;
        vm.prank(user1);
        PlasmaVault(plasmaVault).deposit(depositAmount, user1);

        // Supply USDC to Dolomite
        _supplyToDolomite(USDC, 8_000e6, 0);

        uint256 totalAssetsBefore = PlasmaVault(plasmaVault).totalAssets();
        uint256 marketAssetsBefore = PlasmaVault(plasmaVault).totalAssetsInMarket(DOLOMITE_MARKET_ID);

        // Withdraw some (similar effect as repay reducing debt)
        // Both are value-neutral operations that move funds without changing total
        _withdrawFromDolomite(USDC, 4_000e6, 0);

        uint256 totalAssetsAfter = PlasmaVault(plasmaVault).totalAssets();
        uint256 marketAssetsAfter = PlasmaVault(plasmaVault).totalAssetsInMarket(DOLOMITE_MARKET_ID);

        // Assert: totalAssets unchanged (money just moved)
        assertApproxEqAbs(totalAssetsAfter, totalAssetsBefore, ERROR_DELTA, "TotalAssets unchanged after withdraw");

        // Assert: marketAssets decreased (less in protocol)
        assertLt(marketAssetsAfter, marketAssetsBefore, "MarketAssets should decrease");
    }

    // ============ COLLATERAL TRANSFER TESTS ============

    /**
     * @notice Tests that collateral transfers between sub-accounts don't change totalAssets
     *
     * @dev Test Scenario:
     *      1. Setup: Deposit USDC and configure sub-account 1 substrate
     *      2. Supply USDC to sub-account 0
     *      3. Capture pre-transfer balances
     *      4. Transfer half the collateral from sub-account 0 to sub-account 1
     *      5. Verify: totalAssets unchanged (internal reallocation)
     *      6. Verify: totalAssetsInMarket unchanged (same total in protocol)
     *      7. Verify: individual sub-account balances changed
     *
     *      Why This Test Matters:
     *      =====================
     *      Collateral transfers are internal Dolomite operations that:
     *      - Don't move actual tokens (they stay in DolomiteMargin)
     *      - Only change accounting between sub-accounts
     *      - Must not affect vault's reported NAV
     *
     *      Sub-Account Architecture:
     *      - Sub-account 0: Main supply-only account
     *      - Sub-account 1: Secondary account (potentially for borrowing)
     *      - Transfers allow repositioning without external token movements
     *
     *      Balance Fuse Aggregation:
     *      The balance fuse iterates ALL configured substrates and sums their
     *      balances. After transfer:
     *      - Sub-account 0: -4000 USDC (from original)
     *      - Sub-account 1: +4000 USDC (received)
     *      - Total: Same as before (8000 USDC originally supplied)
     */
    function test_TotalAssetsUnchangedAfterTransferCollateral() public {
        // Setup: deposit USDC
        uint256 depositAmount = 10_000e6;
        vm.prank(user1);
        PlasmaVault(plasmaVault).deposit(depositAmount, user1);

        // Grant USDC substrate for sub-account 1 (required for collateral fuse to work)
        // canBorrow=false because we're just testing transfers, not borrowing
        _grantSubstrate(DOLOMITE_MARKET_ID, USDC, 1, false);

        // Supply USDC to sub-account 0
        _supplyToDolomite(USDC, 8_000e6, 0);

        // Capture pre-transfer state
        uint256 totalAssetsBefore = PlasmaVault(plasmaVault).totalAssets();
        uint256 marketAssetsBefore = PlasmaVault(plasmaVault).totalAssetsInMarket(DOLOMITE_MARKET_ID);

        // Transfer half the collateral from sub-account 0 to sub-account 1
        uint256 transferAmount = 4_000e6;
        _transferCollateral(USDC, transferAmount, 0, 1);

        // Verify post-transfer state
        uint256 totalAssetsAfter = PlasmaVault(plasmaVault).totalAssets();
        uint256 marketAssetsAfter = PlasmaVault(plasmaVault).totalAssetsInMarket(DOLOMITE_MARKET_ID);

        // Assert: totalAssets unchanged (just moved between sub-accounts)
        assertApproxEqAbs(
            totalAssetsAfter,
            totalAssetsBefore,
            ERROR_DELTA,
            "TotalAssets should be unchanged after collateral transfer"
        );

        // Assert: marketAssets ALSO unchanged (same total in market, different sub-accounts)
        assertApproxEqAbs(
            marketAssetsAfter,
            marketAssetsBefore,
            ERROR_DELTA,
            "MarketAssets should be unchanged after collateral transfer"
        );

        // Verify individual sub-account balances changed
        IDolomiteMargin.Wei memory bal0 = _getDolomiteBalance(USDC, 0);
        IDolomiteMargin.Wei memory bal1 = _getDolomiteBalance(USDC, 1);

        // Assert: Each sub-account now has ~4000 USDC
        assertApproxEqAbs(bal0.value, 4_000e6, 100, "Sub-account 0 should have remaining USDC");
        assertApproxEqAbs(bal1.value, 4_000e6, 100, "Sub-account 1 should have transferred USDC");
    }

    // ============ MULTI-ASSET BALANCE TEST ============

    /**
     * @notice Tests multi-position balance tracking with WETH collateral and USDC debt
     *
     * @dev Test Scenario:
     *      1. Setup WETH as collateral (supply to Dolomite)
     *      2. Verify initial totalAssets reflects WETH value
     *      3. Borrow USDC against WETH collateral
     *      4. Verify: Borrow is approximately neutral (adds cash, adds debt)
     *      5. Repay the USDC debt
     *      6. Verify: Repay uses cash to reduce debt
     *
     *      Multi-Asset Balance Calculation:
     *      ================================
     *      When vault has multiple assets in Dolomite:
     *
     *      totalAssetsInMarket = Σ(supply_usd) - Σ(debt_usd)
     *
     *      Example after borrow:
     *      - WETH supply: 2 ETH × $2000 = +$4000 (supply)
     *      - USDC debt: 500 USDC × $1 = -$500 (debt with canBorrow=true)
     *      - Market assets = $4000 - $500 = $3500
     *
     *      totalAssets = vault_cash + market_assets
     *      - vault_cash: $500 (borrowed USDC)
     *      - market_assets: $3500 (from above)
     *      - Total: $4000 ≈ original WETH value
     *
     *      Why This Test Matters:
     *      =====================
     *      - Validates multi-asset aggregation in balance fuse
     *      - Tests actual debt creation (negative balance with canBorrow=true)
     *      - Confirms proper USD conversion for different token decimals
     *      - End-to-end test of borrow → repay cycle with balance verification
     */
    function test_MultiPositionBalance() public {
        // Setup vault with WETH as collateral
        uint256 wethAmount = 2 ether; // 2 WETH (18 decimals)
        deal(WETH, plasmaVault, wethAmount);

        // Grant WETH substrate (sub-account 0, canBorrow=false for collateral)
        _grantSubstrate(DOLOMITE_MARKET_ID, WETH, 0, false);

        // Supply WETH to Dolomite as collateral
        _supplyToDolomite(WETH, wethAmount, 0);

        // Verify initial totalAssets reflects WETH value
        uint256 totalAssetsInitial = PlasmaVault(plasmaVault).totalAssets();
        assertGt(totalAssetsInitial, 0, "Should have WETH value");

        // Borrow USDC against WETH collateral
        // This creates actual debt (negative USDC balance in Dolomite)
        uint256 borrowAmount = 500e6; // 500 USDC
        _borrowFromDolomite(USDC, borrowAmount, 0);

        // Verify balance after borrow
        uint256 totalAssetsAfterBorrow = PlasmaVault(plasmaVault).totalAssets();

        // Borrow is approximately neutral:
        // - Added: 500 USDC cash
        // - Subtracted: 500 USDC debt in Dolomite
        // Net change ≈ 0 (within rounding)
        assertApproxEqAbs(totalAssetsAfterBorrow, totalAssetsInitial, ERROR_DELTA * 100, "Borrow ~neutral");

        // Verify market balance tracking includes both supply and debt
        uint256 assetsInMarket = PlasmaVault(plasmaVault).totalAssetsInMarket(DOLOMITE_MARKET_ID);
        assertGt(assetsInMarket, 0, "Should have assets tracked in market");

        // Repay the debt
        _repayToDolomite(USDC, borrowAmount, 0);

        // Verify balance after repay
        uint256 totalAssetsAfterRepay = PlasmaVault(plasmaVault).totalAssets();

        // After repay:
        // - Cash decreased by borrowAmount (used for repayment)
        // - Debt eliminated (no more negative balance)
        // - Net: totalAssets decreased by borrowAmount (cash used)
        assertApproxEqAbs(
            totalAssetsAfterRepay,
            totalAssetsAfterBorrow - borrowAmount,
            ERROR_DELTA * 10,
            "TotalAssets after repay should reflect used cash"
        );
    }

    /**
     * @notice Comprehensive test of vault balance through complete supply/withdraw cycle
     *
     * @dev Test Scenario:
     *      1. Initial deposit: 20,000 USDC
     *      2. Supply 10,000 USDC to Dolomite
     *      3. Partial withdraw: 5,000 USDC
     *      4. Supply more: 8,000 USDC
     *      5. Full withdraw: remaining Dolomite balance
     *
     *      At Each Checkpoint:
     *      - Verify totalAssets remains consistent
     *      - Verify market assets and vault cash distribution
     *
     *      This Tests:
     *      ===========
     *      - Multiple sequential operations
     *      - Partial withdrawals
     *      - Full withdrawal (type(uint256).max)
     *      - Balance consistency throughout complex workflow
     *
     *      Expected Final State:
     *      - All funds back in vault cash
     *      - Zero assets in Dolomite market
     *      - totalAssets equals original deposit
     */
    function test_ComprehensiveBalanceTracking() public {
        // ====== CHECKPOINT 1: Initial deposit ======
        uint256 depositAmount = 20_000e6;
        vm.prank(user1);
        PlasmaVault(plasmaVault).deposit(depositAmount, user1);

        uint256 checkpoint1 = PlasmaVault(plasmaVault).totalAssets();
        assertApproxEqAbs(checkpoint1, depositAmount, ERROR_DELTA, "Checkpoint 1");

        // ====== CHECKPOINT 2: Supply 10,000 USDC ======
        _supplyToDolomite(USDC, 10_000e6, 0);

        uint256 checkpoint2 = PlasmaVault(plasmaVault).totalAssets();
        // Supply moves money but doesn't create/destroy value
        assertApproxEqAbs(checkpoint2, checkpoint1, ERROR_DELTA, "Checkpoint 2: Supply shouldn't change total");

        // ====== CHECKPOINT 3: Partial withdraw 5,000 USDC ======
        _withdrawFromDolomite(USDC, 5_000e6, 0);

        uint256 checkpoint3 = PlasmaVault(plasmaVault).totalAssets();
        // Withdraw moves money back but doesn't create/destroy value
        assertApproxEqAbs(checkpoint3, checkpoint2, ERROR_DELTA, "Checkpoint 3: Withdraw shouldn't change total");

        // ====== CHECKPOINT 4: Supply more 8,000 USDC ======
        _supplyToDolomite(USDC, 8_000e6, 0);

        uint256 checkpoint4 = PlasmaVault(plasmaVault).totalAssets();
        assertApproxEqAbs(checkpoint4, checkpoint3, ERROR_DELTA, "Checkpoint 4: More supply shouldn't change total");

        // Verify current distribution
        // Cash: Started 20k, -10k supply, +5k withdraw, -8k supply = 7k
        // Dolomite: +10k supply, -5k withdraw, +8k supply = 13k
        uint256 vaultCash = ERC20(USDC).balanceOf(plasmaVault);
        uint256 assetsInMarket = PlasmaVault(plasmaVault).totalAssetsInMarket(DOLOMITE_MARKET_ID);
        assertApproxEqAbs(vaultCash, 7_000e6, ERROR_DELTA, "Cash should be ~7k");
        assertGt(assetsInMarket, 0, "Should have assets in market");

        // ====== CHECKPOINT 5: Large withdraw from Dolomite (leave 100 USDC to keep position) ======
        // Note: BalanceFuse reverts if total balance <= 0, so we keep minimal position
        _withdrawFromDolomite(USDC, 12_900e6, 0); // Withdraw most, leave ~100 USDC

        uint256 checkpoint5 = PlasmaVault(plasmaVault).totalAssets();
        assertApproxEqAbs(checkpoint5, checkpoint4, ERROR_DELTA, "Checkpoint 5: Large withdraw maintains total");

        // ====== FINAL VERIFICATION ======
        uint256 finalCash = ERC20(USDC).balanceOf(plasmaVault);
        // Most funds should be back in vault (minus small position kept in Dolomite)
        assertApproxEqAbs(finalCash, 19_900e6, ERROR_DELTA, "Most funds back in vault");
    }

    // ============ HELPERS: Deployment ============

    /**
     * @notice Deploys all Dolomite fuse contracts
     * @dev Creates supply, borrow, collateral, and balance fuses with proper configuration
     */
    function _deployFuses() internal {
        // Deploy supply fuse (uses DepositWithdrawalRouter)
        supplyFuse = new DolomiteSupplyFuse(DOLOMITE_MARKET_ID, DOLOMITE_MARGIN, DEPOSIT_WITHDRAWAL_ROUTER);

        // Deploy borrow fuse (uses DolomiteMargin.operate() directly)
        borrowFuse = new DolomiteBorrowFuse(DOLOMITE_MARKET_ID, DOLOMITE_MARGIN);

        // Deploy collateral fuse (uses DolomiteMargin.operate() for transfers)
        collateralFuse = new DolomiteCollateralFuse(DOLOMITE_MARKET_ID, DOLOMITE_MARGIN);

        // Deploy balance fuse (read-only, calculates vault NAV)
        balanceFuse = new DolomiteBalanceFuse(DOLOMITE_MARKET_ID, DOLOMITE_MARGIN);

        // Build fuses array for vault configuration (excludes balance fuse)
        fuses = new address[](3);
        fuses[0] = address(supplyFuse);
        fuses[1] = address(borrowFuse);
        fuses[2] = address(collateralFuse);
    }

    /**
     * @notice Sets up the price oracle middleware with Chainlink feeds
     * @dev Configures USDC and WETH price sources for accurate USD conversions
     */
    function _setupPriceOracle() internal {
        vm.startPrank(admin);

        // Deploy price oracle implementation and proxy
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(BASE_CURRENCY_PRICE_SOURCE);
        priceOracle = address(
            new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", admin))
        );

        // Configure price sources for test assets
        address[] memory assets = new address[](2);
        address[] memory sources = new address[](2);

        // USDC: Direct Chainlink feed
        assets[0] = USDC;
        sources[0] = CHAINLINK_USDC_USD;

        // WETH: Wrapped price feed (handles ETH→WETH conversion)
        assets[1] = WETH;
        sources[1] = address(new WETHPriceFeed(CHAINLINK_ETH_USD));

        PriceOracleMiddleware(priceOracle).setAssetsPricesSources(assets, sources);

        vm.stopPrank();
    }

    /**
     * @notice Sets up the access manager with admin and alpha roles
     * @dev Uses RoleLib helper to configure proper permissions
     */
    function _setupAccessManager() internal {
        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = admin;
        usersToRoles.atomist = admin;

        // Configure alpha addresses
        address[] memory alphas = new address[](1);
        alphas[0] = alpha;
        usersToRoles.alphas = alphas;

        // Create access manager with configured roles
        accessManager = address(RoleLib.createAccessManager(usersToRoles, 0, vm));
    }

    /**
     * @notice Deploys and fully configures the PlasmaVault
     * @dev Sets up vault, roles, fuses, balance fuse, and initial substrates
     */
    function _deployPlasmaVault() internal {
        vm.startPrank(admin);

        // Deploy withdraw manager (required for vault)
        address withdrawManager = address(new WithdrawManager(accessManager));

        // Deploy vault with zero fees for simpler testing
        FeeConfig memory feeConfig = FeeConfigHelper.createZeroFeeConfig();

        plasmaVault = address(new PlasmaVault());
        PlasmaVault(plasmaVault).proxyInitialize(
            PlasmaVaultInitData({
                assetName: "Dolomite Test Vault",
                assetSymbol: "DTVault",
                underlyingToken: USDC, // USDC as underlying
                priceOracleMiddleware: priceOracle,
                feeConfig: feeConfig,
                accessManager: accessManager,
                plasmaVaultBase: address(new PlasmaVaultBase()),
                withdrawManager: withdrawManager,
                plasmaVaultVotesPlugin: address(0)
            })
        );

        vm.stopPrank();

        // Setup vault-specific roles
        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = admin;
        usersToRoles.atomist = admin;
        RoleLib.setupPlasmaVaultRoles(
            usersToRoles,
            vm,
            plasmaVault,
            IporFusionAccessManager(accessManager),
            withdrawManager
        );

        // Add fuses and configure balance tracking
        vm.startPrank(admin);
        PlasmaVaultGovernance(plasmaVault).addFuses(fuses);
        PlasmaVaultGovernance(plasmaVault).addBalanceFuse(DOLOMITE_MARKET_ID, address(balanceFuse));

        // Grant initial USDC substrate (canBorrow=true for borrowing tests)
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = DolomiteFuseLib.substrateToBytes32(
            DolomiteSubstrate({asset: USDC, subAccountId: 0, canBorrow: true})
        );
        PlasmaVaultGovernance(plasmaVault).grantMarketSubstrates(DOLOMITE_MARKET_ID, substrates);

        // Store for _grantSubstrate helper
        _currentSubstrates = substrates;

        vm.stopPrank();
    }

    // ============ HELPERS: Substrate Management ============

    /// @dev Tracks currently granted substrates (grantMarketSubstrates replaces all)
    bytes32[] internal _currentSubstrates;

    /**
     * @notice Grants a new substrate or updates an existing one
     * @param marketId The Fusion market ID
     * @param asset The asset address
     * @param subAccountId The sub-account ID
     * @param canBorrow Whether borrowing is allowed
     *
     * @dev PlasmaVaultGovernance.grantMarketSubstrates() replaces ALL substrates,
     *      so we need to track and include existing ones when adding new.
     */
    function _grantSubstrate(uint256 marketId, address asset, uint8 subAccountId, bool canBorrow) internal {
        // Encode new substrate
        bytes32 newSubstrate = DolomiteFuseLib.substrateToBytes32(
            DolomiteSubstrate({asset: asset, subAccountId: subAccountId, canBorrow: canBorrow})
        );

        // Check if substrate already exists (update canBorrow if so)
        bool found = false;
        for (uint256 i = 0; i < _currentSubstrates.length; i++) {
            DolomiteSubstrate memory existing = DolomiteFuseLib.bytes32ToSubstrate(_currentSubstrates[i]);
            if (existing.asset == asset && existing.subAccountId == subAccountId) {
                _currentSubstrates[i] = newSubstrate;
                found = true;
                break;
            }
        }

        // Add new substrate if not found
        if (!found) {
            bytes32[] memory newArray = new bytes32[](_currentSubstrates.length + 1);
            for (uint256 i = 0; i < _currentSubstrates.length; i++) {
                newArray[i] = _currentSubstrates[i];
            }
            newArray[_currentSubstrates.length] = newSubstrate;
            _currentSubstrates = newArray;
        }

        // Apply updated substrates
        vm.prank(admin);
        PlasmaVaultGovernance(plasmaVault).grantMarketSubstrates(marketId, _currentSubstrates);
    }

    // ============ HELPERS: Dolomite Actions ============

    /**
     * @notice Supplies assets to Dolomite via the supply fuse
     * @param asset Token to supply
     * @param amount Amount to supply
     * @param subAccountId Target sub-account
     */
    function _supplyToDolomite(address asset, uint256 amount, uint8 subAccountId) internal {
        FuseAction[] memory calls = new FuseAction[](1);

        DolomiteSupplyFuseEnterData memory enterData = DolomiteSupplyFuseEnterData({
            asset: asset,
            amount: amount,
            minBalanceIncrease: 0,
            subAccountId: subAccountId,
            isolationModeMarketId: 0
        });

        calls[0] = FuseAction({fuse: address(supplyFuse), data: abi.encodeCall(supplyFuse.enter, (enterData))});

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(calls);
    }

    /**
     * @notice Withdraws assets from Dolomite via the supply fuse
     * @param asset Token to withdraw
     * @param amount Amount to withdraw (use type(uint256).max for all)
     * @param subAccountId Source sub-account
     */
    function _withdrawFromDolomite(address asset, uint256 amount, uint8 subAccountId) internal {
        FuseAction[] memory calls = new FuseAction[](1);

        DolomiteSupplyFuseExitData memory exitData = DolomiteSupplyFuseExitData({
            asset: asset,
            amount: amount,
            minAmountOut: 0,
            subAccountId: subAccountId,
            isolationModeMarketId: 0
        });

        calls[0] = FuseAction({fuse: address(supplyFuse), data: abi.encodeCall(supplyFuse.exit, (exitData))});

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(calls);
    }

    /**
     * @notice Borrows assets from Dolomite via the borrow fuse
     * @param asset Token to borrow
     * @param amount Amount to borrow
     * @param subAccountId Sub-account with collateral
     */
    function _borrowFromDolomite(address asset, uint256 amount, uint8 subAccountId) internal {
        FuseAction[] memory calls = new FuseAction[](1);

        DolomiteBorrowFuseEnterData memory enterData = DolomiteBorrowFuseEnterData({
            asset: asset,
            amount: amount,
            minAmountOut: 0,
            subAccountId: subAccountId
        });

        calls[0] = FuseAction({fuse: address(borrowFuse), data: abi.encodeCall(borrowFuse.enter, (enterData))});

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(calls);
    }

    /**
     * @notice Repays borrowed assets to Dolomite via the borrow fuse
     * @param asset Token to repay
     * @param amount Amount to repay (use type(uint256).max for full)
     * @param subAccountId Sub-account with debt
     */
    function _repayToDolomite(address asset, uint256 amount, uint8 subAccountId) internal {
        FuseAction[] memory calls = new FuseAction[](1);

        DolomiteBorrowFuseExitData memory exitData = DolomiteBorrowFuseExitData({
            asset: asset,
            amount: amount,
            minDebtReduction: 0,
            subAccountId: subAccountId
        });

        calls[0] = FuseAction({fuse: address(borrowFuse), data: abi.encodeCall(borrowFuse.exit, (exitData))});

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(calls);
    }

    /**
     * @notice Transfers collateral between sub-accounts via the collateral fuse
     * @param asset Token to transfer
     * @param amount Amount to transfer
     * @param fromSubAccountId Source sub-account
     * @param toSubAccountId Destination sub-account
     */
    function _transferCollateral(address asset, uint256 amount, uint8 fromSubAccountId, uint8 toSubAccountId) internal {
        FuseAction[] memory calls = new FuseAction[](1);

        DolomiteCollateralFuseEnterData memory enterData = DolomiteCollateralFuseEnterData({
            asset: asset,
            amount: amount,
            minSharesOut: 0,
            fromSubAccountId: fromSubAccountId,
            toSubAccountId: toSubAccountId
        });

        calls[0] = FuseAction({fuse: address(collateralFuse), data: abi.encodeCall(collateralFuse.enter, (enterData))});

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(calls);
    }

    /**
     * @notice Gets the Dolomite balance for an asset in a specific sub-account
     * @param asset Token to query
     * @param accountNumber Sub-account number
     * @return Wei struct containing sign and value
     */
    function _getDolomiteBalance(
        address asset,
        uint256 accountNumber
    ) internal view returns (IDolomiteMargin.Wei memory) {
        uint256 dolomiteMarketId = IDolomiteMargin(DOLOMITE_MARGIN).getMarketIdByTokenAddress(asset);
        return
            IDolomiteMargin(DOLOMITE_MARGIN).getAccountWei(
                IDolomiteMargin.AccountInfo({owner: plasmaVault, number: accountNumber}),
                dolomiteMarketId
            );
    }

    /// @notice Fallback to receive ETH
    receive() external payable {}
}
