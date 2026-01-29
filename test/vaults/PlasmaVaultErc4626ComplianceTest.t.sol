// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PlasmaVault, PlasmaVaultInitData, FeeConfig} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {RewardsClaimManager} from "../../contracts/managers/rewards/RewardsClaimManager.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {FeeConfigHelper} from "../test_helpers/FeeConfigHelper.sol";
import {TestAddresses} from "../test_helpers/TestAddresses.sol";
import {IporFusionAccessManagerHelper} from "../test_helpers/IporFusionAccessManagerHelper.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title PlasmaVaultErc4626ComplianceTest
/// @notice Comprehensive test suite verifying ERC4626 compliance for PlasmaVault
/// @dev Tests the MUST NOT revert requirements and mathematical consistency of ERC4626 functions
contract PlasmaVaultErc4626ComplianceTest is Test {
    using Math for uint256;
    using IporFusionAccessManagerHelper for IporFusionAccessManager;

    // Test addresses from TestAddresses library
    address private constant ATOMIST = TestAddresses.ATOMIST;
    address private constant USER = TestAddresses.USER;
    address private constant USER2 = TestAddresses.ALPHA; // Use ALPHA as second user

    // Underlying token (mock USDC)
    MockERC20 private _underlyingToken;

    // Core contracts
    PlasmaVault private _plasmaVault;
    PlasmaVaultGovernance private _plasmaVaultGovernance;
    IporFusionAccessManager private _accessManager;
    WithdrawManager private _withdrawManager;
    PriceOracleMiddleware private _priceOracle;

    function setUp() public {
        // Deploy mock underlying token
        _underlyingToken = new MockERC20("Mock USDC", "mUSDC", 6);

        // Deploy access manager
        _accessManager = new IporFusionAccessManager(ATOMIST, 0);

        // Deploy PlasmaVaultBase
        address plasmaVaultBase = address(new PlasmaVaultBase());

        // Deploy withdraw manager
        _withdrawManager = new WithdrawManager(address(_accessManager));

        // Deploy price oracle middleware
        PriceOracleMiddleware priceOracleImpl = new PriceOracleMiddleware(address(0));
        _priceOracle = PriceOracleMiddleware(
            address(new ERC1967Proxy(address(priceOracleImpl), abi.encodeWithSignature("initialize(address)", ATOMIST)))
        );

        // Deploy mock price feed for the underlying token ($1 = 1e8 with 8 decimals)
        MockPriceFeed mockPriceFeed = new MockPriceFeed(1e8, 8);

        // Configure price source for mock token
        vm.startPrank(ATOMIST);
        address[] memory assets = new address[](1);
        assets[0] = address(_underlyingToken);
        address[] memory sources = new address[](1);
        sources[0] = address(mockPriceFeed);
        _priceOracle.setAssetsPricesSources(assets, sources);
        vm.stopPrank();

        // Create fee config
        FeeConfig memory feeConfig = FeeConfigHelper.createZeroFeeConfig();

        // Deploy and initialize PlasmaVault
        _plasmaVault = new PlasmaVault();

        vm.startPrank(ATOMIST);
        _plasmaVault.proxyInitialize(
            PlasmaVaultInitData({
                assetName: "Test Plasma Vault",
                assetSymbol: "tPLASMA",
                underlyingToken: address(_underlyingToken),
                priceOracleMiddleware: address(_priceOracle),
                feeConfig: feeConfig,
                accessManager: address(_accessManager),
                plasmaVaultBase: plasmaVaultBase,
                withdrawManager: address(_withdrawManager),
                plasmaVaultVotesPlugin: address(0)
            })
        );

        _plasmaVaultGovernance = PlasmaVaultGovernance(address(_plasmaVault));

        // Setup roles using the helper - this properly initializes the access manager
        RewardsClaimManager rewardsClaimManager = new RewardsClaimManager(
            address(_accessManager),
            address(_plasmaVault)
        );
        _accessManager.setupInitRoles(_plasmaVault, address(_withdrawManager), address(rewardsClaimManager));
        vm.stopPrank();

        // Provide tokens to users
        deal(address(_underlyingToken), USER, 1_000_000e6);
        deal(address(_underlyingToken), USER2, 1_000_000e6);
    }

    // ============ MUST NOT REVERT TESTS ============

    /// @notice Tests that previewDeposit MUST NOT revert for any valid input
    function testPreviewDepositMustNotRevert() public view {
        // Test with zero amount
        _plasmaVault.previewDeposit(0);

        // Test with small amount
        _plasmaVault.previewDeposit(1);

        // Test with typical amount
        _plasmaVault.previewDeposit(1000e6);

        // Test with large but realistic amount (1 trillion USDC)
        _plasmaVault.previewDeposit(1_000_000_000_000e6);
    }

    /// @notice Tests that previewMint MUST NOT revert for any valid input
    function testPreviewMintMustNotRevert() public view {
        // Test with zero amount
        _plasmaVault.previewMint(0);

        // Test with small amount
        _plasmaVault.previewMint(1);

        // Test with typical amount
        _plasmaVault.previewMint(1000e9); // 1000 shares (with 9 decimals)

        // Test with large but realistic amount (1 trillion shares)
        _plasmaVault.previewMint(1_000_000_000_000e9);
    }

    /// @notice Tests that previewRedeem MUST NOT revert for any valid input
    function testPreviewRedeemMustNotRevert() public {
        // First deposit some assets
        _depositAsUser(USER, 10_000e6);

        // Test with zero amount
        _plasmaVault.previewRedeem(0);

        // Test with small amount
        _plasmaVault.previewRedeem(1);

        // Test with typical amount
        _plasmaVault.previewRedeem(1000e9);

        // Test with large but realistic amount (more than balance is OK)
        _plasmaVault.previewRedeem(1_000_000_000_000e9);
    }

    /// @notice Tests that previewWithdraw MUST NOT revert for any valid input
    function testPreviewWithdrawMustNotRevert() public {
        // First deposit some assets
        _depositAsUser(USER, 10_000e6);

        // Test with zero amount
        _plasmaVault.previewWithdraw(0);

        // Test with small amount
        _plasmaVault.previewWithdraw(1);

        // Test with typical amount
        _plasmaVault.previewWithdraw(1000e6);

        // Test with large but realistic amount
        _plasmaVault.previewWithdraw(1_000_000_000_000e6);
    }

    /// @notice Tests that maxDeposit MUST NOT revert
    function testMaxDepositMustNotRevert() public view {
        // Test for zero address
        _plasmaVault.maxDeposit(address(0));

        // Test for regular user
        _plasmaVault.maxDeposit(USER);

        // Test for atomist
        _plasmaVault.maxDeposit(ATOMIST);
    }

    /// @notice Tests that maxMint MUST NOT revert
    function testMaxMintMustNotRevert() public view {
        // Test for zero address
        _plasmaVault.maxMint(address(0));

        // Test for regular user
        _plasmaVault.maxMint(USER);

        // Test for atomist
        _plasmaVault.maxMint(ATOMIST);
    }

    /// @notice Tests that maxWithdraw MUST NOT revert
    function testMaxWithdrawMustNotRevert() public {
        // Test for user with no balance
        _plasmaVault.maxWithdraw(address(0));
        _plasmaVault.maxWithdraw(USER);

        // Deposit and test again
        _depositAsUser(USER, 10_000e6);
        _plasmaVault.maxWithdraw(USER);
    }

    /// @notice Tests that maxRedeem MUST NOT revert
    function testMaxRedeemMustNotRevert() public {
        // Test for user with no balance
        _plasmaVault.maxRedeem(address(0));
        _plasmaVault.maxRedeem(USER);

        // Deposit and test again
        _depositAsUser(USER, 10_000e6);
        _plasmaVault.maxRedeem(USER);
    }

    // ============ ROUNDTRIP CONSISTENCY TESTS ============

    /// @notice Tests deposit->redeem roundtrip returns approximately same assets (minus fees/rounding)
    function testDepositRedeemRoundtrip() public {
        uint256 depositAmount = 10_000e6;

        // Deposit
        uint256 shares = _depositAsUser(USER, depositAmount);
        assertGt(shares, 0, "Should receive shares");

        // Redeem all shares
        uint256 userShares = _plasmaVault.balanceOf(USER);
        vm.startPrank(USER);
        uint256 assetsReceived = _plasmaVault.redeem(userShares, USER, USER);
        vm.stopPrank();

        // Should receive approximately the same amount (accounting for potential rounding)
        assertApproxEqRel(assetsReceived, depositAmount, 1e15, "Roundtrip should return approximately same assets");
    }

    /// @notice Tests mint->withdraw roundtrip consistency
    function testMintWithdrawRoundtrip() public {
        uint256 sharesToMint = 10_000e9; // 10,000 shares

        // Approve sufficient assets
        vm.startPrank(USER);
        _underlyingToken.approve(address(_plasmaVault), type(uint256).max);

        // Mint shares
        uint256 assetsPaid = _plasmaVault.mint(sharesToMint, USER);
        vm.stopPrank();

        assertGt(assetsPaid, 0, "Should pay some assets");

        // Withdraw all assets
        uint256 maxWithdrawable = _plasmaVault.maxWithdraw(USER);
        vm.startPrank(USER);
        uint256 sharesBurned = _plasmaVault.withdraw(maxWithdrawable, USER, USER);
        vm.stopPrank();

        // Shares burned should be approximately the shares minted
        assertApproxEqRel(sharesBurned, sharesToMint, 1e15, "Roundtrip should burn approximately same shares");
    }

    // ============ PREVIEW ACCURACY TESTS ============

    /// @notice Tests that previewDeposit returns accurate shares
    function testPreviewDepositAccuracy() public {
        uint256 depositAmount = 10_000e6;

        uint256 previewedShares = _plasmaVault.previewDeposit(depositAmount);
        uint256 actualShares = _depositAsUser(USER, depositAmount);

        // Actual shares should be >= previewed (previewDeposit should be pessimistic)
        assertGe(actualShares, previewedShares, "Actual shares should be >= previewed");
        // But should be close
        assertApproxEqRel(actualShares, previewedShares, 1e15, "Preview should be accurate");
    }

    /// @notice Tests that previewMint returns accurate assets
    function testPreviewMintAccuracy() public {
        uint256 sharesToMint = 10_000e9;

        uint256 previewedAssets = _plasmaVault.previewMint(sharesToMint);

        vm.startPrank(USER);
        _underlyingToken.approve(address(_plasmaVault), type(uint256).max);
        uint256 actualAssets = _plasmaVault.mint(sharesToMint, USER);
        vm.stopPrank();

        // Actual assets should be <= previewed (previewMint should be pessimistic - overestimate)
        assertLe(actualAssets, previewedAssets, "Actual assets should be <= previewed");
        // But should be close
        assertApproxEqRel(actualAssets, previewedAssets, 1e15, "Preview should be accurate");
    }

    /// @notice Tests that previewRedeem returns accurate assets
    function testPreviewRedeemAccuracy() public {
        // First deposit
        uint256 shares = _depositAsUser(USER, 10_000e6);

        uint256 previewedAssets = _plasmaVault.previewRedeem(shares);

        vm.startPrank(USER);
        uint256 actualAssets = _plasmaVault.redeem(shares, USER, USER);
        vm.stopPrank();

        // Actual assets should be >= previewed (previewRedeem should be pessimistic)
        assertGe(actualAssets, previewedAssets, "Actual assets should be >= previewed");
        // But should be close
        assertApproxEqRel(actualAssets, previewedAssets, 1e15, "Preview should be accurate");
    }

    /// @notice Tests that previewWithdraw returns accurate shares
    function testPreviewWithdrawAccuracy() public {
        // First deposit
        _depositAsUser(USER, 10_000e6);

        uint256 withdrawAmount = 5_000e6;
        uint256 previewedShares = _plasmaVault.previewWithdraw(withdrawAmount);

        vm.startPrank(USER);
        uint256 actualShares = _plasmaVault.withdraw(withdrawAmount, USER, USER);
        vm.stopPrank();

        // Actual shares should be <= previewed (previewWithdraw should be pessimistic - overestimate)
        assertLe(actualShares, previewedShares, "Actual shares should be <= previewed");
        // But should be close
        assertApproxEqRel(actualShares, previewedShares, 1e15, "Preview should be accurate");
    }

    // ============ MAX FUNCTIONS TESTS ============

    /// @notice Tests that deposit respects maxDeposit
    function testDepositRespectsMaxDeposit() public {
        uint256 maxDep = _plasmaVault.maxDeposit(USER);
        assertGt(maxDep, 0, "maxDeposit should be > 0");

        // Should be able to deposit up to maxDeposit
        uint256 depositAmount = maxDep > 100_000e6 ? 100_000e6 : maxDep;
        _depositAsUser(USER, depositAmount);
    }

    /// @notice Tests that mint respects maxMint
    function testMintRespectsMaxMint() public {
        uint256 maxMintShares = _plasmaVault.maxMint(USER);
        assertGt(maxMintShares, 0, "maxMint should be > 0");

        // Should be able to mint up to maxMint
        uint256 mintAmount = maxMintShares > 100_000e9 ? 100_000e9 : maxMintShares;
        vm.startPrank(USER);
        _underlyingToken.approve(address(_plasmaVault), type(uint256).max);
        _plasmaVault.mint(mintAmount, USER);
        vm.stopPrank();
    }

    /// @notice Tests that withdraw respects maxWithdraw
    function testWithdrawRespectsMaxWithdraw() public {
        // Deposit first
        _depositAsUser(USER, 10_000e6);

        uint256 maxWith = _plasmaVault.maxWithdraw(USER);
        assertGt(maxWith, 0, "maxWithdraw should be > 0 after deposit");

        // Should be able to withdraw up to maxWithdraw
        vm.startPrank(USER);
        _plasmaVault.withdraw(maxWith, USER, USER);
        vm.stopPrank();
    }

    /// @notice Tests that redeem respects maxRedeem
    function testRedeemRespectsMaxRedeem() public {
        // Deposit first
        _depositAsUser(USER, 10_000e6);

        uint256 maxRed = _plasmaVault.maxRedeem(USER);
        assertGt(maxRed, 0, "maxRedeem should be > 0 after deposit");

        // Should be able to redeem up to maxRedeem
        vm.startPrank(USER);
        _plasmaVault.redeem(maxRed, USER, USER);
        vm.stopPrank();
    }

    // ============ EDGE CASE TESTS ============

    /// @notice Tests ERC4626 functions with zero totalSupply
    function testFunctionsWithZeroTotalSupply() public view {
        // All preview functions should work with zero supply
        _plasmaVault.previewDeposit(1000e6);
        _plasmaVault.previewMint(1000e9);
        _plasmaVault.previewRedeem(1000e9);
        _plasmaVault.previewWithdraw(1000e6);

        // Max functions should work
        _plasmaVault.maxDeposit(USER);
        _plasmaVault.maxMint(USER);
        _plasmaVault.maxWithdraw(USER);
        _plasmaVault.maxRedeem(USER);
    }

    /// @notice Tests convertToShares and convertToAssets consistency
    function testConvertFunctionsConsistency() public {
        // Deposit to set up some state
        _depositAsUser(USER, 10_000e6);

        uint256 assets = 1000e6;
        uint256 shares = _plasmaVault.convertToShares(assets);
        uint256 assetsBack = _plasmaVault.convertToAssets(shares);

        // Should be approximately equal (within rounding)
        assertApproxEqAbs(assetsBack, assets, 1, "Convert functions should be consistent");
    }

    /// @notice Tests that multiple deposits/withdrawals maintain consistency
    function testMultipleOperationsConsistency() public {
        // Multiple users deposit
        uint256 deposit1 = 10_000e6;
        uint256 deposit2 = 20_000e6;

        uint256 shares1 = _depositAsUser(USER, deposit1);
        uint256 shares2 = _depositAsUser(USER2, deposit2);

        // Total supply should match
        uint256 expectedTotalShares = shares1 + shares2;
        assertEq(_plasmaVault.totalSupply(), expectedTotalShares, "Total supply should match deposits");

        // Both users withdraw
        vm.prank(USER);
        _plasmaVault.redeem(shares1, USER, USER);

        vm.prank(USER2);
        _plasmaVault.redeem(shares2, USER2, USER2);

        // Total supply should be 0 (or near 0 due to potential dust)
        assertLe(_plasmaVault.totalSupply(), 1000, "Total supply should be near 0 after full withdrawal");
    }

    // ============ HELPER FUNCTIONS ============

    function _depositAsUser(address user_, uint256 amount_) internal returns (uint256 shares) {
        vm.startPrank(user_);
        _underlyingToken.approve(address(_plasmaVault), amount_);
        shares = _plasmaVault.deposit(amount_, user_);
        vm.stopPrank();
    }
}

/// @notice Simple mock ERC20 token for testing
contract MockERC20 is ERC20 {
    uint8 private _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Simple mock price feed that returns a fixed price (Chainlink AggregatorV3Interface compatible)
contract MockPriceFeed {
    int256 private _price;
    uint8 private _decimals;

    constructor(int256 price_, uint8 decimals_) {
        _price = price_;
        _decimals = decimals_;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound)
    {
        return (1, _price, block.timestamp, block.timestamp, 1);
    }
}

// ============================================================================
// COMPREHENSIVE WITHDRAW FEE TESTS (ERC4626 Compliance)
// ============================================================================

/// @title PlasmaVaultErc4626WithdrawFeeTest
/// @notice Tests ERC4626 compliance with withdraw fee configurations
/// @dev Tests the previewWithdraw and previewRedeem formulas with various fee levels
///      This test suite specifically validates the fix for the previewWithdraw fee formula bug
contract PlasmaVaultErc4626WithdrawFeeTest is Test {
    using Math for uint256;
    using IporFusionAccessManagerHelper for IporFusionAccessManager;

    address private constant ATOMIST = TestAddresses.ATOMIST;
    address private constant USER = TestAddresses.USER;
    address private constant USER2 = TestAddresses.ALPHA;

    MockERC20 private _underlyingToken;
    PlasmaVault private _plasmaVault;
    PlasmaVaultGovernance private _plasmaVaultGovernance;
    IporFusionAccessManager private _accessManager;
    WithdrawManager private _withdrawManager;
    PriceOracleMiddleware private _priceOracle;

    function setUp() public {
        _underlyingToken = new MockERC20("Mock USDC", "mUSDC", 6);
        _accessManager = new IporFusionAccessManager(ATOMIST, 0);

        address plasmaVaultBase = address(new PlasmaVaultBase());

        _withdrawManager = new WithdrawManager(address(_accessManager));

        // Deploy price oracle
        PriceOracleMiddleware priceOracleImpl = new PriceOracleMiddleware(address(0));
        _priceOracle = PriceOracleMiddleware(
            address(new ERC1967Proxy(address(priceOracleImpl), abi.encodeWithSignature("initialize(address)", ATOMIST)))
        );

        MockPriceFeed mockPriceFeed = new MockPriceFeed(1e8, 8);

        vm.startPrank(ATOMIST);
        address[] memory assets = new address[](1);
        assets[0] = address(_underlyingToken);
        address[] memory sources = new address[](1);
        sources[0] = address(mockPriceFeed);
        _priceOracle.setAssetsPricesSources(assets, sources);
        vm.stopPrank();

        FeeConfig memory feeConfig = FeeConfigHelper.createZeroFeeConfig();

        _plasmaVault = new PlasmaVault();

        vm.startPrank(ATOMIST);
        _plasmaVault.proxyInitialize(
            PlasmaVaultInitData({
                assetName: "Test Plasma Vault Fee",
                assetSymbol: "tPLASMAFEE",
                underlyingToken: address(_underlyingToken),
                priceOracleMiddleware: address(_priceOracle),
                feeConfig: feeConfig,
                accessManager: address(_accessManager),
                plasmaVaultBase: plasmaVaultBase,
                withdrawManager: address(_withdrawManager),
                plasmaVaultVotesPlugin: address(0)
            })
        );

        _plasmaVaultGovernance = PlasmaVaultGovernance(address(_plasmaVault));

        RewardsClaimManager rewardsClaimManager = new RewardsClaimManager(
            address(_accessManager),
            address(_plasmaVault)
        );
        _accessManager.setupInitRoles(_plasmaVault, address(_withdrawManager), address(rewardsClaimManager));

        // Grant ATOMIST the role to update withdraw fee
        _accessManager.grantRole(Roles.WITHDRAW_MANAGER_WITHDRAW_FEE_ROLE, ATOMIST, 0);
        vm.stopPrank();

        deal(address(_underlyingToken), USER, 10_000_000e6);
        deal(address(_underlyingToken), USER2, 10_000_000e6);
    }

    // ============ WITHDRAW FEE TESTS ============

    /// @notice Tests previewRedeem accuracy with withdraw fees
    function testPreviewRedeemWithWithdrawFee() public {
        // First deposit
        uint256 shares = _depositAsUser(USER, 10_000e6);

        // Set 5% withdraw fee
        vm.prank(ATOMIST);
        _withdrawManager.updateWithdrawFee(5e16); // 5%

        uint256 previewedAssets = _plasmaVault.previewRedeem(shares);

        vm.startPrank(USER);
        uint256 actualAssets = _plasmaVault.redeem(shares, USER, USER);
        vm.stopPrank();

        // ERC4626: previewRedeem MUST return as close to actual as possible
        // Preview should underestimate assets received (pessimistic)
        assertGe(actualAssets, previewedAssets, "Actual assets should be >= previewed with withdraw fee");
        assertApproxEqRel(actualAssets, previewedAssets, 1e15, "Preview should be accurate with withdraw fee");
    }

    /// @notice Tests previewWithdraw accuracy with withdraw fees - CRITICAL TEST for fixed bug
    /// @dev This test validates the fix for the previewWithdraw formula:
    ///      CORRECT: shares = sharesForAssets * (1e18 + withdrawFee) / 1e18
    ///      BUG WAS: shares = sharesForAssets * 1e18 / (1e18 - withdrawFee) [WRONG!]
    function testPreviewWithdrawWithWithdrawFee() public {
        // First deposit
        _depositAsUser(USER, 10_000e6);

        // Set 5% withdraw fee
        vm.prank(ATOMIST);
        _withdrawManager.updateWithdrawFee(5e16); // 5%

        uint256 withdrawAmount = 5_000e6;
        uint256 previewedShares = _plasmaVault.previewWithdraw(withdrawAmount);

        vm.startPrank(USER);
        uint256 actualShares = _plasmaVault.withdraw(withdrawAmount, USER, USER);
        vm.stopPrank();

        // ERC4626: previewWithdraw MUST return as close to actual as possible
        // Preview should overestimate shares burned (pessimistic)
        assertLe(actualShares, previewedShares, "Actual shares should be <= previewed with withdraw fee");
        assertApproxEqRel(actualShares, previewedShares, 1e15, "Preview should be accurate with withdraw fee");
    }

    /// @notice Tests maxWithdraw with withdraw fee
    function testMaxWithdrawWithFee() public {
        _depositAsUser(USER, 10_000e6);

        // Set 10% withdraw fee
        vm.prank(ATOMIST);
        _withdrawManager.updateWithdrawFee(1e17); // 10%

        uint256 maxWith = _plasmaVault.maxWithdraw(USER);
        uint256 noFeeMaxWith = _plasmaVault.convertToAssets(_plasmaVault.balanceOf(USER));

        // With withdraw fee, maxWithdraw should be less than without fee
        assertLt(maxWith, noFeeMaxWith, "maxWithdraw should be reduced by withdraw fee");

        // User should be able to withdraw up to maxWithdraw
        vm.startPrank(USER);
        _plasmaVault.withdraw(maxWith, USER, USER);
        vm.stopPrank();
    }

    /// @notice Tests mathematical consistency of withdraw fee formula
    /// @dev Verifies: shares_burned = shares_for_assets * (1 + feeRate)
    function testWithdrawFeeFormulaConsistency() public {
        // Set various fee levels and verify formula
        uint256[] memory feeRates = new uint256[](4);
        feeRates[0] = 1e16;  // 1%
        feeRates[1] = 5e16;  // 5%
        feeRates[2] = 1e17;  // 10%
        feeRates[3] = 2e17;  // 20%

        for (uint256 i = 0; i < feeRates.length; i++) {
            // Reset state for each fee level
            setUp();
            _depositAsUser(USER, 10_000e6);

            vm.prank(ATOMIST);
            _withdrawManager.updateWithdrawFee(feeRates[i]);

            uint256 assets = 1000e6;
            uint256 sharesWithoutFee = _plasmaVault.convertToShares(assets);
            // Correct formula: totalShares = sharesForAssets * (1e18 + feeRate) / 1e18
            uint256 expectedSharesWithFee = sharesWithoutFee.mulDiv(1e18 + feeRates[i], 1e18, Math.Rounding.Ceil);
            uint256 previewedShares = _plasmaVault.previewWithdraw(assets);

            assertApproxEqRel(
                previewedShares,
                expectedSharesWithFee,
                1e15,
                "previewWithdraw formula should match expected calculation"
            );
        }
    }

    /// @notice Tests that previewRedeem formula is correct with withdraw fee
    /// @dev Verifies: assets_received = convertToAssets(shares * (1e18 - feeRate) / 1e18)
    function testRedeemFeeFormulaConsistency() public {
        // Set various fee levels and verify formula
        uint256[] memory feeRates = new uint256[](4);
        feeRates[0] = 1e16;  // 1%
        feeRates[1] = 5e16;  // 5%
        feeRates[2] = 1e17;  // 10%
        feeRates[3] = 2e17;  // 20%

        for (uint256 i = 0; i < feeRates.length; i++) {
            // Reset state for each fee level
            setUp();
            _depositAsUser(USER, 10_000e6);

            vm.prank(ATOMIST);
            _withdrawManager.updateWithdrawFee(feeRates[i]);

            uint256 shares = 1000e9;
            // Correct formula: effectiveShares = shares * (1e18 - feeRate) / 1e18
            uint256 effectiveShares = shares.mulDiv(1e18 - feeRates[i], 1e18, Math.Rounding.Floor);
            uint256 expectedAssets = _plasmaVault.convertToAssets(effectiveShares);
            uint256 previewedAssets = _plasmaVault.previewRedeem(shares);

            assertApproxEqRel(
                previewedAssets,
                expectedAssets,
                1e15,
                "previewRedeem formula should match expected calculation"
            );
        }
    }

    /// @notice Tests functions with extreme withdraw fee (50%)
    function testExtremeWithdrawFee() public {
        _depositAsUser(USER, 10_000e6);

        // Set high withdraw fee (50%)
        vm.prank(ATOMIST);
        _withdrawManager.updateWithdrawFee(5e17); // 50%

        // Preview functions MUST NOT revert (ERC4626 requirement)
        _plasmaVault.previewRedeem(1000e9);
        _plasmaVault.previewWithdraw(1000e6);
        _plasmaVault.maxWithdraw(USER);
        _plasmaVault.maxRedeem(USER);

        // Verify maxWithdraw calculation with 50% fee
        // Formula: effectiveShares = ownerShares * 1e18 / (1e18 + feeRate)
        // With 50% fee (5e17): effectiveShares = ownerShares * 1e18 / 1.5e18 = ownerShares * 2/3
        // So maxWithdraw ≈ 66.67% of full balance (not 50%)
        uint256 maxWith = _plasmaVault.maxWithdraw(USER);
        uint256 fullBalance = _plasmaVault.convertToAssets(_plasmaVault.balanceOf(USER));
        uint256 expectedMaxWith = fullBalance.mulDiv(1e18, 1e18 + 5e17, Math.Rounding.Floor);
        assertApproxEqRel(maxWith, expectedMaxWith, 1e15, "maxWithdraw should follow formula: balance / (1 + feeRate)");
    }

    /// @notice Tests preview functions return 0 for 0 input with withdraw fee
    function testPreviewReturnsZeroForZeroInputWithFee() public {
        vm.prank(ATOMIST);
        _withdrawManager.updateWithdrawFee(1e17); // 10%

        assertEq(_plasmaVault.previewRedeem(0), 0, "previewRedeem(0) should return 0");
        assertEq(_plasmaVault.previewWithdraw(0), 0, "previewWithdraw(0) should return 0");
    }

    /// @notice Tests deposit->redeem roundtrip with withdraw fee
    function testDepositRedeemRoundtripWithWithdrawFee() public {
        // Set 10% withdraw fee
        vm.prank(ATOMIST);
        _withdrawManager.updateWithdrawFee(1e17); // 10%

        uint256 depositAmount = 10_000e6;
        uint256 shares = _depositAsUser(USER, depositAmount);

        vm.startPrank(USER);
        uint256 assetsReceived = _plasmaVault.redeem(shares, USER, USER);
        vm.stopPrank();

        // With 10% withdraw fee: effective assets = depositAmount * 0.90 = 9000
        uint256 expectedMin = depositAmount * 90 / 100;

        assertApproxEqRel(assetsReceived, expectedMin, 1e15, "Roundtrip should account for withdraw fee");
        assertLt(assetsReceived, depositAmount, "Should receive less than deposited due to fee");
    }

    /// @notice Tests that maxWithdraw + fee calculation is consistent
    function testMaxWithdrawPlusFeeEqualsBalance() public {
        _depositAsUser(USER, 10_000e6);

        // Set 10% withdraw fee
        vm.prank(ATOMIST);
        _withdrawManager.updateWithdrawFee(1e17); // 10%

        uint256 maxWith = _plasmaVault.maxWithdraw(USER);
        uint256 sharesForMaxWith = _plasmaVault.previewWithdraw(maxWith);
        uint256 userBalance = _plasmaVault.balanceOf(USER);

        // The shares needed to withdraw maxWith should equal user's balance
        assertApproxEqRel(
            sharesForMaxWith,
            userBalance,
            1e15,
            "previewWithdraw(maxWithdraw) should equal user balance"
        );
    }

    // ============ TOTALASSETS COMPLIANCE TEST ============

    /// @notice Tests that totalAssets returns gross assets (ERC4626 compliant)
    function testTotalAssetsReturnsGrossAssets() public {
        uint256 depositAmount = 10_000e6;
        _depositAsUser(USER, depositAmount);

        uint256 totalAssets = _plasmaVault.totalAssets();

        // totalAssets should equal deposited assets (no external protocols in this test)
        assertEq(totalAssets, depositAmount, "totalAssets should return gross assets");

        // Even after time passes (management fee accrual), totalAssets should remain gross
        vm.warp(block.timestamp + 365 days);

        uint256 totalAssetsAfterTime = _plasmaVault.totalAssets();
        assertEq(totalAssetsAfterTime, depositAmount, "totalAssets should remain gross after time");
    }

    // ============ HELPER FUNCTIONS ============

    function _depositAsUser(address user_, uint256 amount_) internal returns (uint256 shares) {
        vm.startPrank(user_);
        _underlyingToken.approve(address(_plasmaVault), amount_);
        shares = _plasmaVault.deposit(amount_, user_);
        vm.stopPrank();
    }
}
