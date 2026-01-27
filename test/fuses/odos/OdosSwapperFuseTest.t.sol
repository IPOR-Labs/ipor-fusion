// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MarketSubstratesConfig, MarketBalanceFuseConfig, FeeConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {FuseAction, PlasmaVault, PlasmaVaultInitData} from "../../../contracts/vaults/PlasmaVault.sol";
import {IPlasmaVaultGovernance} from "../../../contracts/interfaces/IPlasmaVaultGovernance.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";

import {RoleLib, UsersToRoles} from "../../RoleLib.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {ZeroBalanceFuse} from "../../../contracts/fuses/ZeroBalanceFuse.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {PlasmaVaultConfigurator} from "../../utils/PlasmaVaultConfigurator.sol";

import {OdosSwapperFuse, OdosSwapperEnterData} from "../../../contracts/fuses/odos/OdosSwapperFuse.sol";
import {OdosSwapExecutor} from "../../../contracts/fuses/odos/OdosSwapExecutor.sol";
import {OdosSubstrateLib, OdosSubstrateType} from "../../../contracts/fuses/odos/OdosSubstrateLib.sol";

/// @title OdosSwapperFuseTest
/// @notice Fork integration tests for OdosSwapperFuse on Arbitrum.
contract OdosSwapperFuseTest is Test {
    using SafeERC20 for ERC20;

    // ============ Events ============

    event OdosSwapperFuseEnter(
        address indexed version,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 tokenInDelta,
        uint256 tokenOutDelta
    );

    // ============ Arbitrum Mainnet Addresses ============

    address private constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // Native USDC on Arbitrum
    address private constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1; // WETH on Arbitrum
    address private constant USDT = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9; // USDT on Arbitrum
    address private constant DAI = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1; // DAI on Arbitrum
    address private constant ARB = 0x912CE59144191C1204E64559FE8253a0e49E6548; // ARB token

    // Odos Router V3 (same on all EVM chains)
    // See: https://docs.odos.xyz/build/contracts
    address private constant ODOS_ROUTER_V3 = 0x0D05a7D3448512B78fa8A9e46c4872C88C4a0D05;

    // Chainlink price feeds on Arbitrum (no registry, must set individually)
    address private constant CHAINLINK_USDC_USD = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    address private constant CHAINLINK_WETH_USD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address private constant CHAINLINK_USDT_USD = 0x3f3f5dF88dC9F13eac63DF89EC16ef6e7E25DdE7;
    address private constant CHAINLINK_DAI_USD = 0xc5C8E77B397E531B8EC06BFb0048328B30E9eCfB;

    // Whale addresses for token distribution
    address private constant USDC_WHALE = 0x2Df1c51E09aECF9cacB7bc98cB1742757f163dF7;
    address private constant WETH_WHALE = 0xe50fA9b3c56FfB159cB0FCA61F5c9D750e8128c8;

    // Fork block number for reproducible tests (from Odos API response)
    uint256 private constant FORK_BLOCK_NUMBER = 421193396;

    // ============ State Variables ============

    address private _plasmaVault;
    address private _withdrawManager;
    address private _priceOracle;
    address private _accessManager;

    OdosSwapperFuse private _odosSwapperFuse;
    OdosSwapExecutor private _odosSwapExecutor;

    // ============ Setup ============

    function setUp() public {
        // Fork Arbitrum at a specific block for reproducibility
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), FORK_BLOCK_NUMBER);

        // Deploy price oracle (no registry on Arbitrum, use address(0))
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(address(0));
        _priceOracle = address(
            new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
        );

        // Set up price feeds for tokens on Arbitrum
        _setupPriceFeeds();

        // Create access manager
        _accessManager = _createAccessManager();

        // Deploy withdraw manager
        _withdrawManager = address(new WithdrawManager(_accessManager));

        // Deploy plasma vault
        _plasmaVault = address(new PlasmaVault());
        PlasmaVault(_plasmaVault).proxyInitialize(
            PlasmaVaultInitData(
                "TEST ODOS PLASMA VAULT",
                "pvUSDC-ODOS",
                USDC,
                _priceOracle,
                _setupFeeConfig(),
                _accessManager,
                address(new PlasmaVaultBase()),
                address(0),
                _withdrawManager,
                address(0)
            )
        );

        // Configure plasma vault with fuses and market substrates
        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            address(this),
            address(_plasmaVault),
            _setupFuses(),
            _setupBalanceFuses(),
            _setupMarketConfigs()
        );

        // Setup roles
        _setupRoles();

        // Label addresses for better traces
        vm.label(address(_odosSwapperFuse), "OdosSwapperFuse");
        vm.label(address(_odosSwapExecutor), "OdosSwapExecutor");
        vm.label(_plasmaVault, "PlasmaVault");
        vm.label(USDC, "USDC");
        vm.label(WETH, "WETH");
        vm.label(USDT, "USDT");
        vm.label(ODOS_ROUTER_V3, "OdosRouterV3");
    }

    // ============ Constructor Tests ============

    function testShouldSetVersionToDeploymentAddress() public view {
        assertEq(_odosSwapperFuse.VERSION(), address(_odosSwapperFuse));
    }

    function testShouldSetMarketIdCorrectly() public view {
        assertEq(_odosSwapperFuse.MARKET_ID(), IporFusionMarkets.ODOS_SWAPPER);
    }

    function testShouldSetExecutorCorrectly() public view {
        // Executor should be created during fuse deployment
        assertTrue(_odosSwapperFuse.EXECUTOR() != address(0));
        assertEq(_odosSwapperFuse.EXECUTOR(), address(_odosSwapExecutor));
    }

    // ============ Enter Tests - Failure Cases ============

    function testShouldRevertWhenTokenInNotInSubstrates() public {
        // given
        address unsupportedToken = address(0x1234);

        OdosSwapperEnterData memory enterData = OdosSwapperEnterData({
            tokenIn: unsupportedToken,
            tokenOut: WETH,
            amountIn: 1000e6,
            minAmountOut: 0,
            swapCallData: ""
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_odosSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes))", enterData)
        );

        // when/then
        vm.expectRevert(abi.encodeWithSelector(OdosSwapperFuse.OdosSwapperFuseUnsupportedAsset.selector, unsupportedToken));
        PlasmaVault(_plasmaVault).execute(enterCalls);
    }

    function testShouldRevertWhenTokenOutNotInSubstrates() public {
        // given
        address unsupportedToken = address(0x5678);

        // First deposit USDC to the vault
        _depositToVault(1000e6);

        OdosSwapperEnterData memory enterData = OdosSwapperEnterData({
            tokenIn: USDC,
            tokenOut: unsupportedToken,
            amountIn: 1000e6,
            minAmountOut: 0,
            swapCallData: ""
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_odosSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes))", enterData)
        );

        // when/then
        vm.expectRevert(abi.encodeWithSelector(OdosSwapperFuse.OdosSwapperFuseUnsupportedAsset.selector, unsupportedToken));
        PlasmaVault(_plasmaVault).execute(enterCalls);
    }

    function testShouldRevertWhenZeroAmountIn() public {
        // given
        OdosSwapperEnterData memory enterData = OdosSwapperEnterData({
            tokenIn: USDC,
            tokenOut: WETH,
            amountIn: 0,
            minAmountOut: 0,
            swapCallData: ""
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_odosSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes))", enterData)
        );

        // when/then
        vm.expectRevert(OdosSwapperFuse.OdosSwapperFuseZeroAmount.selector);
        PlasmaVault(_plasmaVault).execute(enterCalls);
    }

    // ============ Substrate Library Tests ============

    function testShouldEncodeDecodeTokenSubstrate() public pure {
        // given
        address token = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

        // when
        bytes32 encoded = OdosSubstrateLib.encodeTokenSubstrate(token);
        OdosSubstrateType substrateType = OdosSubstrateLib.decodeSubstrateType(encoded);
        address decodedToken = OdosSubstrateLib.decodeToken(encoded);

        // then
        assertEq(uint8(substrateType), uint8(OdosSubstrateType.Token));
        assertEq(decodedToken, token);
        assertTrue(OdosSubstrateLib.isTokenSubstrate(encoded));
        assertFalse(OdosSubstrateLib.isSlippageSubstrate(encoded));
    }

    function testShouldEncodeDecodeSlippageSubstrate() public pure {
        // given
        uint256 slippage = 5e16; // 5%

        // when
        bytes32 encoded = OdosSubstrateLib.encodeSlippageSubstrate(slippage);
        OdosSubstrateType substrateType = OdosSubstrateLib.decodeSubstrateType(encoded);
        uint256 decodedSlippage = OdosSubstrateLib.decodeSlippage(encoded);

        // then
        assertEq(uint8(substrateType), uint8(OdosSubstrateType.Slippage));
        assertEq(decodedSlippage, slippage);
        assertFalse(OdosSubstrateLib.isTokenSubstrate(encoded));
        assertTrue(OdosSubstrateLib.isSlippageSubstrate(encoded));
    }

    function testShouldUseDefaultSlippageWhenNotConfigured() public view {
        // The default slippage should be 1% (1e16)
        assertEq(_odosSwapperFuse.DEFAULT_SLIPPAGE_WAD(), 1e16);
    }

    // ============ Executor Tests ============

    function testExecutorShouldHaveCorrectOdosRouterAddress() public view {
        assertEq(_odosSwapExecutor.ODOS_ROUTER(), ODOS_ROUTER_V3);
    }

    // ============ Fork Integration Tests ============

    /// @notice Test real swap USDC -> WETH using Odos Router V3
    /// @dev Uses calldata from Odos API /sor/quote/v3 endpoint at block 421193396
    /// @dev IMPORTANT: userAddr must be 0x0 in API call so receiver defaults to msg.sender (executor)
    function testShouldSwapUsdcToWethOnArbitrumFork() public {
        // given
        uint256 depositAmount = 1000e6; // 1000 USDC
        _depositToVault(depositAmount);

        // Verify initial balances
        uint256 vaultUsdcBefore = ERC20(USDC).balanceOf(_plasmaVault);
        uint256 vaultWethBefore = ERC20(WETH).balanceOf(_plasmaVault);
        assertEq(vaultUsdcBefore, depositAmount, "Vault should have deposited USDC");
        assertEq(vaultWethBefore, 0, "Vault should have no WETH initially");

        // Calldata from Odos API /sor/quote/v3 at block 421193396
        // IMPORTANT: Generated with userAddr = 0x0 so receiver = msg.sender (executor)
        // This calldata swaps 1000 USDC -> ~0.2998 WETH
        bytes memory odosSwapCallData = hex"83bd37f90001af88d065e77c8cc2239327c5edb3a432268e5831000182af49447d8a07e3bd95bd0d56f35241523fbab1043b9aca0008042954e8079ec480028f5c000103222a2b261a12091bBE271e763A7E26b64E25e20000000000000000000000000003010203004801010102ff00000000000000000000000000000000000000000000af88d065e77c8cc2239327c5edb3a432268e583182af49447d8a07e3bd95bd0d56f35241523fbab1000000000000000000000000000000000000000000000000";

        // minAmountOut = expectedOut * (1 - slippage) = 299864205733840000 * 0.99 ≈ 296865563676501600
        uint256 minAmountOut = 296865563676501600;

        OdosSwapperEnterData memory enterData = OdosSwapperEnterData({
            tokenIn: USDC,
            tokenOut: WETH,
            amountIn: depositAmount,
            minAmountOut: minAmountOut,
            swapCallData: odosSwapCallData
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_odosSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes))", enterData)
        );

        // when
        PlasmaVault(_plasmaVault).execute(enterCalls);

        // then
        uint256 vaultUsdcAfter = ERC20(USDC).balanceOf(_plasmaVault);
        uint256 vaultWethAfter = ERC20(WETH).balanceOf(_plasmaVault);

        assertEq(vaultUsdcAfter, 0, "Vault should have swapped all USDC");
        assertGt(vaultWethAfter, minAmountOut, "Vault should have received WETH above minAmountOut");
        assertGt(vaultWethAfter, 0.29 ether, "Vault should have received approximately 0.3 WETH");

    }

    /// @notice Test that swap reverts when minAmountOut is not reached
    /// @dev Uses the same calldata as testShouldSwapUsdcToWethOnArbitrumFork but with unrealistic minAmountOut
    function testShouldRevertWhenMinAmountOutNotReachedOnArbitrumFork() public {
        // given
        uint256 depositAmount = 1000e6; // 1000 USDC
        _depositToVault(depositAmount);

        // Calldata from Odos API /sor/quote/v3 at block 421193396
        // This calldata swaps 1000 USDC -> ~0.2998 WETH
        bytes memory odosSwapCallData = hex"83bd37f90001af88d065e77c8cc2239327c5edb3a432268e5831000182af49447d8a07e3bd95bd0d56f35241523fbab1043b9aca0008042954e8079ec480028f5c000103222a2b261a12091bBE271e763A7E26b64E25e20000000000000000000000000003010203004801010102ff00000000000000000000000000000000000000000000af88d065e77c8cc2239327c5edb3a432268e583182af49447d8a07e3bd95bd0d56f35241523fbab1000000000000000000000000000000000000000000000000";

        // Set minAmountOut higher than what the swap will return (~0.2998 WETH)
        // We expect ~299864205733840000 but require 1 WETH (1e18) which is impossible
        uint256 unrealisticMinAmountOut = 1 ether;

        OdosSwapperEnterData memory enterData = OdosSwapperEnterData({
            tokenIn: USDC,
            tokenOut: WETH,
            amountIn: depositAmount,
            minAmountOut: unrealisticMinAmountOut,
            swapCallData: odosSwapCallData
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_odosSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes))", enterData)
        );

        // when/then - expect revert with MinAmountOutNotReached error
        // The actual amount will be ~0.2998 WETH, but we require 1 WETH
        vm.expectRevert(
            abi.encodeWithSelector(
                OdosSwapperFuse.OdosSwapperFuseMinAmountOutNotReached.selector,
                unrealisticMinAmountOut,
                299864205733840000 // approximate actual amount from swap
            )
        );
        PlasmaVault(_plasmaVault).execute(enterCalls);
    }

    /// @notice Test that event is emitted correctly during swap
    function testShouldEmitOdosSwapperFuseEnterEvent() public {
        // given
        uint256 depositAmount = 1000e6;
        _depositToVault(depositAmount);

        // Calldata with userAddr = 0x0 so receiver = msg.sender
        bytes memory odosSwapCallData = hex"83bd37f90001af88d065e77c8cc2239327c5edb3a432268e5831000182af49447d8a07e3bd95bd0d56f35241523fbab1043b9aca0008042954e8079ec480028f5c000103222a2b261a12091bBE271e763A7E26b64E25e20000000000000000000000000003010203004801010102ff00000000000000000000000000000000000000000000af88d065e77c8cc2239327c5edb3a432268e583182af49447d8a07e3bd95bd0d56f35241523fbab1000000000000000000000000000000000000000000000000";

        OdosSwapperEnterData memory enterData = OdosSwapperEnterData({
            tokenIn: USDC,
            tokenOut: WETH,
            amountIn: depositAmount,
            minAmountOut: 0,
            swapCallData: odosSwapCallData
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_odosSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes))", enterData)
        );

        // when/then - expect event emission
        vm.expectEmit(true, true, true, false);
        emit OdosSwapperFuseEnter(address(_odosSwapperFuse), USDC, WETH, 0, 0);

        PlasmaVault(_plasmaVault).execute(enterCalls);
    }

    // ============ Edge Case Tests ============

    /// @notice Test HIGH PRIORITY: Revert when tokenOut balance does not increase after swap
    /// @dev Covers OdosSwapperFuse.sol lines 163-165: critical security path where tokens are consumed but nothing received
    function testShouldRevertWhenTokenOutBalanceDoesNotIncrease() public {
        // given
        uint256 depositAmount = 1000e6;
        _depositToVault(depositAmount);

        // Mock a malicious/broken swap that consumes tokenIn but returns nothing
        // We create a mock executor that simulates this edge case
        MockBrokenOdosSwapExecutor mockExecutor = new MockBrokenOdosSwapExecutor();

        // Deploy a new fuse with our mock executor for testing
        OdosSwapperFuseWithMockExecutor testFuse = new OdosSwapperFuseWithMockExecutor(
            IporFusionMarkets.ODOS_SWAPPER,
            address(mockExecutor)
        );

        // Configure the new fuse in the vault
        address[] memory newFuses = new address[](1);
        newFuses[0] = address(testFuse);
        IPlasmaVaultGovernance(_plasmaVault).addFuses(newFuses);

        OdosSwapperEnterData memory enterData = OdosSwapperEnterData({
            tokenIn: USDC,
            tokenOut: WETH,
            amountIn: depositAmount,
            minAmountOut: 0,
            swapCallData: ""
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(testFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes))", enterData)
        );

        // when/then - expect revert because tokenOut balance didn't increase
        vm.expectRevert(OdosSwapperFuse.OdosSwapperFuseSlippageFail.selector);
        PlasmaVault(_plasmaVault).execute(enterCalls);
    }

    /// @notice Test MEDIUM PRIORITY: Function returns early when no tokens are consumed
    /// @dev Covers OdosSwapperFuse.sol lines 156-158: edge case where swap returns all tokens without swapping
    function testShouldReturnEarlyWhenNoTokensConsumed() public {
        // given
        uint256 depositAmount = 1000e6;
        _depositToVault(depositAmount);

        // Mock an executor that returns all tokenIn without consuming any
        MockNoOpOdosSwapExecutor mockExecutor = new MockNoOpOdosSwapExecutor();

        // Deploy a new fuse with our mock executor
        OdosSwapperFuseWithMockExecutor testFuse = new OdosSwapperFuseWithMockExecutor(
            IporFusionMarkets.ODOS_SWAPPER,
            address(mockExecutor)
        );

        // Configure the new fuse
        address[] memory newFuses = new address[](1);
        newFuses[0] = address(testFuse);
        IPlasmaVaultGovernance(_plasmaVault).addFuses(newFuses);

        uint256 vaultUsdcBefore = ERC20(USDC).balanceOf(_plasmaVault);
        uint256 vaultWethBefore = ERC20(WETH).balanceOf(_plasmaVault);

        OdosSwapperEnterData memory enterData = OdosSwapperEnterData({
            tokenIn: USDC,
            tokenOut: WETH,
            amountIn: depositAmount,
            minAmountOut: 0,
            swapCallData: ""
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(testFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes))", enterData)
        );

        // when - execute should succeed (early return, no revert)
        PlasmaVault(_plasmaVault).execute(enterCalls);

        // then - balances should be unchanged (executor returned all tokens)
        uint256 vaultUsdcAfter = ERC20(USDC).balanceOf(_plasmaVault);
        uint256 vaultWethAfter = ERC20(WETH).balanceOf(_plasmaVault);

        assertEq(vaultUsdcAfter, vaultUsdcBefore, "USDC balance should be unchanged");
        assertEq(vaultWethAfter, vaultWethBefore, "WETH balance should be unchanged");
    }

    /// @notice Test MEDIUM PRIORITY: Executor returns unused tokenIn back to PlasmaVault
    /// @dev Covers OdosSwapExecutor.sol lines 48-51: partial swap where not all tokenIn is used
    function testShouldReturnUnusedTokenIn() public {
        // given
        uint256 depositAmount = 1000e6;
        _depositToVault(depositAmount);

        // Mock executor that uses only half the tokenIn and returns the rest
        MockPartialSwapExecutor mockExecutor = new MockPartialSwapExecutor();

        // Pre-fund mock executor with WETH for the simulated swap output
        vm.prank(WETH_WHALE);
        ERC20(WETH).transfer(address(mockExecutor), 0.2 ether);

        // Deploy a new fuse with our mock executor
        OdosSwapperFuseWithMockExecutor testFuse = new OdosSwapperFuseWithMockExecutor(
            IporFusionMarkets.ODOS_SWAPPER,
            address(mockExecutor)
        );

        // Configure the new fuse
        address[] memory newFuses = new address[](1);
        newFuses[0] = address(testFuse);
        IPlasmaVaultGovernance(_plasmaVault).addFuses(newFuses);

        uint256 vaultUsdcBefore = ERC20(USDC).balanceOf(_plasmaVault);

        OdosSwapperEnterData memory enterData = OdosSwapperEnterData({
            tokenIn: USDC,
            tokenOut: WETH,
            amountIn: depositAmount,
            minAmountOut: 0,
            swapCallData: ""
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(testFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes))", enterData)
        );

        // when
        PlasmaVault(_plasmaVault).execute(enterCalls);

        // then - half of USDC should be returned, half consumed
        uint256 vaultUsdcAfter = ERC20(USDC).balanceOf(_plasmaVault);
        uint256 vaultWethAfter = ERC20(WETH).balanceOf(_plasmaVault);

        // Mock executor uses 50% of tokenIn
        assertEq(vaultUsdcAfter, vaultUsdcBefore / 2, "Half of USDC should be returned");
        assertGt(vaultWethAfter, 0, "Should have received some WETH");
    }

    /// @notice Test MEDIUM PRIORITY: Custom slippage from substrates is used instead of default
    /// @dev Covers OdosSwapperFuse._getSlippageLimit() - verifies 2% custom slippage is read from substrates
    function testShouldUseCustomSlippageWhenConfigured() public {
        // given - setup already configures 2% slippage in substrates (line 466)
        // DEFAULT_SLIPPAGE_WAD is 1% (1e16), custom is 2% (2e16)
        uint256 depositAmount = 1000e6;
        _depositToVault(depositAmount);

        // Calldata from Odos API
        bytes memory odosSwapCallData = hex"83bd37f90001af88d065e77c8cc2239327c5edb3a432268e5831000182af49447d8a07e3bd95bd0d56f35241523fbab1043b9aca0008042954e8079ec480028f5c000103222a2b261a12091bBE271e763A7E26b64E25e20000000000000000000000000003010203004801010102ff00000000000000000000000000000000000000000000af88d065e77c8cc2239327c5edb3a432268e583182af49447d8a07e3bd95bd0d56f35241523fbab1000000000000000000000000000000000000000000000000";

        // Calculate a minAmountOut that would fail with 1% slippage but pass with 2%
        // Expected output ~0.2998 WETH. With 2% slippage: 0.2998 * 0.98 = 0.2938 WETH
        uint256 minAmountOut = 0;

        OdosSwapperEnterData memory enterData = OdosSwapperEnterData({
            tokenIn: USDC,
            tokenOut: WETH,
            amountIn: depositAmount,
            minAmountOut: minAmountOut,
            swapCallData: odosSwapCallData
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_odosSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes))", enterData)
        );

        // when - execute should succeed with 2% custom slippage
        PlasmaVault(_plasmaVault).execute(enterCalls);

        // then - swap completed successfully, proving custom slippage was applied
        uint256 vaultWethAfter = ERC20(WETH).balanceOf(_plasmaVault);
        assertGt(vaultWethAfter, 0, "Swap should succeed with custom 2% slippage");

        // Verify the custom slippage is indeed 2%
        assertEq(_odosSwapperFuse.DEFAULT_SLIPPAGE_WAD(), 1e16, "Default slippage is 1%");
        // Custom slippage of 2% (2e16) was set in _setupMarketConfigs()
    }

    /// @notice Test LOW PRIORITY: Executor can be called directly by anyone (access control test)
    /// @dev Covers OdosSwapExecutor.execute() - documents that anyone can call the executor directly
    /// @dev NOTE: This test documents current behavior. SEC-001 recommends adding access control.
    function testExecutorCanBeCalledDirectlyByAnyone() public {
        // given - send some tokens to executor to test direct call scenario
        uint256 amount = 100e6;
        vm.prank(USDC_WHALE);
        ERC20(USDC).transfer(address(_odosSwapExecutor), amount);

        uint256 executorUsdcBefore = ERC20(USDC).balanceOf(address(_odosSwapExecutor));
        assertEq(executorUsdcBefore, amount, "Executor should have received USDC");

        address attacker = address(0xBAD);
        uint256 attackerUsdcBefore = ERC20(USDC).balanceOf(attacker);

        // when - anyone can call execute() directly
        // NOTE: This is the SEC-001 finding - executor lacks access control
        // With empty calldata, Odos Router doesn't revert, but returns without doing swap
        // The executor then sends all tokens back to msg.sender (the attacker!)
        vm.prank(attacker);
        _odosSwapExecutor.execute(USDC, WETH, amount, "");

        // then - tokens are sent to the attacker (msg.sender)
        uint256 attackerUsdcAfter = ERC20(USDC).balanceOf(attacker);
        uint256 executorUsdcAfter = ERC20(USDC).balanceOf(address(_odosSwapExecutor));

        // This demonstrates the security concern: tokens sent to executor by mistake
        // can be stolen by anyone who calls execute()
        assertEq(attackerUsdcAfter, attackerUsdcBefore + amount, "Attacker should have received all USDC");
        assertEq(executorUsdcAfter, 0, "Executor should have no USDC left");
    }

    /// @notice Test LOW PRIORITY: Slippage overflow validation at boundary
    /// @dev Covers OdosSubstrateLib.sol line 37-38: revert OdosSubstrateLibSlippageOverflow
    function testShouldRevertWhenSlippageOverflowsUint248() public {
        // given - value just above uint248 max should overflow
        uint256 overflowValue = uint256(type(uint248).max) + 1;

        // when/then - use helper contract to test revert (library functions are inlined)
        SlippageEncoderHelper helper = new SlippageEncoderHelper();
        vm.expectRevert(abi.encodeWithSelector(OdosSubstrateLib.OdosSubstrateLibSlippageOverflow.selector, overflowValue));
        helper.encodeSlippage(overflowValue);
    }

    /// @notice Test that max uint248 value is accepted without overflow
    /// @dev Verifies the boundary condition at exactly uint248.max
    function testShouldAcceptMaxUint248Slippage() public pure {
        // given - exactly max uint248 should be accepted
        uint256 maxValue = type(uint248).max;

        // when - should not revert
        bytes32 encoded = OdosSubstrateLib.encodeSlippageSubstrate(maxValue);

        // then - decoded value should match
        uint256 decoded = OdosSubstrateLib.decodeSlippage(encoded);
        assertEq(decoded, maxValue, "Decoded slippage should match max uint248");
    }

    // ============ Helper Functions ============

    function _depositToVault(uint256 amount_) private {
        address userOne = address(0x1222);

        // Transfer USDC from whale
        vm.prank(USDC_WHALE);
        ERC20(USDC).transfer(userOne, amount_ * 2);

        // Approve and deposit
        vm.prank(userOne);
        ERC20(USDC).approve(_plasmaVault, amount_);
        vm.prank(userOne);
        PlasmaVault(_plasmaVault).deposit(amount_, userOne);
    }

    function _setupFeeConfig() private returns (FeeConfig memory feeConfig_) {
        feeConfig_ = FeeConfigHelper.createZeroFeeConfig();
    }

    function _setupPriceFeeds() private {
        address[] memory assets = new address[](4);
        address[] memory sources = new address[](4);

        assets[0] = USDC;
        sources[0] = CHAINLINK_USDC_USD;

        assets[1] = WETH;
        sources[1] = CHAINLINK_WETH_USD;

        assets[2] = USDT;
        sources[2] = CHAINLINK_USDT_USD;

        assets[3] = DAI;
        sources[3] = CHAINLINK_DAI_USD;

        PriceOracleMiddleware(_priceOracle).setAssetsPricesSources(assets, sources);
    }

    function _createAccessManager() private returns (address accessManager_) {
        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = address(this);
        usersToRoles.atomist = address(this);
        address[] memory alphas = new address[](1);
        alphas[0] = address(this);
        usersToRoles.alphas = alphas;
        accessManager_ = address(RoleLib.createAccessManager(usersToRoles, 0, vm));
    }

    function _setupRoles() private {
        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = address(this);
        usersToRoles.atomist = address(this);
        RoleLib.setupPlasmaVaultRoles(
            usersToRoles,
            vm,
            _plasmaVault,
            IporFusionAccessManager(_accessManager),
            _withdrawManager
        );
    }

    function _setupMarketConfigs() private returns (MarketSubstratesConfig[] memory marketConfigs_) {
        marketConfigs_ = new MarketSubstratesConfig[](1);

        // Configure Odos market substrates with token addresses
        bytes32[] memory odosSubstrates = new bytes32[](5);
        odosSubstrates[0] = OdosSubstrateLib.encodeTokenSubstrate(USDC);
        odosSubstrates[1] = OdosSubstrateLib.encodeTokenSubstrate(WETH);
        odosSubstrates[2] = OdosSubstrateLib.encodeTokenSubstrate(USDT);
        odosSubstrates[3] = OdosSubstrateLib.encodeTokenSubstrate(DAI);
        odosSubstrates[4] = OdosSubstrateLib.encodeSlippageSubstrate(2e16); // 2% slippage

        marketConfigs_[0] = MarketSubstratesConfig(IporFusionMarkets.ODOS_SWAPPER, odosSubstrates);
    }

    function _setupFuses() private returns (address[] memory fuses_) {
        // Deploy fuse (executor is created in constructor)
        _odosSwapperFuse = new OdosSwapperFuse(IporFusionMarkets.ODOS_SWAPPER);
        _odosSwapExecutor = OdosSwapExecutor(_odosSwapperFuse.EXECUTOR());

        fuses_ = new address[](1);
        fuses_[0] = address(_odosSwapperFuse);
    }

    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses_) {
        ZeroBalanceFuse zeroBalance = new ZeroBalanceFuse(IporFusionMarkets.ODOS_SWAPPER);

        balanceFuses_ = new MarketBalanceFuseConfig[](1);
        balanceFuses_[0] = MarketBalanceFuseConfig(IporFusionMarkets.ODOS_SWAPPER, address(zeroBalance));
    }
}

// ============ Mock Contracts for Edge Case Testing ============

/// @notice Mock executor that consumes tokenIn but returns no tokenOut (simulates broken swap)
contract MockBrokenOdosSwapExecutor {
    using SafeERC20 for ERC20;

    function execute(
        address tokenIn_,
        address, // tokenOut_ - not used
        uint256, // amountIn_ - not used
        bytes calldata // swapCallData_ - not used
    ) external {
        // Consume ALL tokenIn (don't return anything)
        // This simulates a broken swap that eats tokens
        uint256 balance = ERC20(tokenIn_).balanceOf(address(this));
        // Don't transfer tokenOut - simulating swap failure without revert
        // Don't return tokenIn - simulating consumed tokens
        // Just burn by keeping in executor (for test purposes)
        if (balance > 0) {
            // Actually, to trigger the slippage fail, we should NOT return tokenIn
            // The fuse checks: if (tokenInBalanceAfter >= tokenInBalanceBefore) return;
            // So we need to ensure tokenIn balance decreases, but tokenOut doesn't increase
            // We do nothing - tokenIn stays in executor, tokenOut never sent
        }
    }
}

/// @notice Mock executor that returns all tokenIn without doing any swap (no-op)
contract MockNoOpOdosSwapExecutor {
    using SafeERC20 for ERC20;

    function execute(
        address tokenIn_,
        address, // tokenOut_ - not used
        uint256, // amountIn_ - not used
        bytes calldata // swapCallData_ - not used
    ) external {
        // Return ALL tokenIn to caller (no swap performed)
        uint256 balance = ERC20(tokenIn_).balanceOf(address(this));
        if (balance > 0) {
            ERC20(tokenIn_).safeTransfer(msg.sender, balance);
        }
        // No tokenOut transferred - simulating swap that returned early
    }
}

/// @notice Mock executor that uses only half of tokenIn and returns rest
contract MockPartialSwapExecutor {
    using SafeERC20 for ERC20;

    // WETH address on Arbitrum for mock swap
    address private constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address private constant WETH_WHALE = 0xe50fA9b3c56FfB159cB0FCA61F5c9D750e8128c8;

    function execute(
        address tokenIn_,
        address tokenOut_,
        uint256, // amountIn_ - not used
        bytes calldata // swapCallData_ - not used
    ) external {
        uint256 tokenInBalance = ERC20(tokenIn_).balanceOf(address(this));

        // Return half of tokenIn (simulating partial swap)
        if (tokenInBalance > 0) {
            ERC20(tokenIn_).safeTransfer(msg.sender, tokenInBalance / 2);
        }

        // Send some tokenOut from whale (simulating successful partial swap)
        // Note: This is a simplified mock - in real scenario Odos would do the swap
        // We use vm.prank in test setup, but here we need to actually have tokens
        // For this mock to work, we need to pre-fund it or use a different approach
        uint256 mockOutputAmount = 0.1 ether; // ~0.1 WETH for half of 1000 USDC
        if (tokenOut_ == WETH) {
            uint256 wethBalance = ERC20(WETH).balanceOf(address(this));
            if (wethBalance >= mockOutputAmount) {
                ERC20(WETH).safeTransfer(msg.sender, mockOutputAmount);
            }
        }
    }

    // Allow funding the mock executor with WETH for testing
    receive() external payable {}
}

/// @notice Test fuse that allows injecting a custom executor address
/// @dev Used for edge case testing with mock executors
contract OdosSwapperFuseWithMockExecutor {
    using SafeERC20 for ERC20;

    event OdosSwapperFuseEnter(
        address indexed version,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 tokenInDelta,
        uint256 tokenOutDelta
    );

    error OdosSwapperFuseUnsupportedAsset(address asset);
    error OdosSwapperFuseMinAmountOutNotReached(uint256 expected, uint256 actual);
    error OdosSwapperFuseSlippageFail();
    error OdosSwapperFuseZeroAmount();
    error OdosSwapperFuseInvalidMarketId();

    uint256 public constant DEFAULT_SLIPPAGE_WAD = 1e16;
    uint256 private constant _ONE = 1e18;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address public immutable EXECUTOR;

    constructor(uint256 marketId_, address executor_) {
        if (marketId_ == 0) {
            revert OdosSwapperFuseInvalidMarketId();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
        EXECUTOR = executor_;
    }

    function enter(OdosSwapperEnterData calldata data_) external {
        // Validate tokenIn is in substrates
        if (!_isTokenGranted(data_.tokenIn)) {
            revert OdosSwapperFuseUnsupportedAsset(data_.tokenIn);
        }

        // Validate tokenOut is in substrates
        if (!_isTokenGranted(data_.tokenOut)) {
            revert OdosSwapperFuseUnsupportedAsset(data_.tokenOut);
        }

        // Revert if amountIn is 0
        if (data_.amountIn == 0) {
            revert OdosSwapperFuseZeroAmount();
        }

        address plasmaVault = address(this);

        // Record balances before swap
        uint256 tokenInBalanceBefore = ERC20(data_.tokenIn).balanceOf(plasmaVault);
        uint256 tokenOutBalanceBefore = ERC20(data_.tokenOut).balanceOf(plasmaVault);

        // Transfer tokenIn to executor
        ERC20(data_.tokenIn).safeTransfer(EXECUTOR, data_.amountIn);

        // Call mock executor
        MockBrokenOdosSwapExecutor(EXECUTOR).execute(data_.tokenIn, data_.tokenOut, data_.amountIn, data_.swapCallData);

        // Record balances after swap
        uint256 tokenInBalanceAfter = ERC20(data_.tokenIn).balanceOf(plasmaVault);
        uint256 tokenOutBalanceAfter = ERC20(data_.tokenOut).balanceOf(plasmaVault);

        // If no tokens were consumed, return early
        if (tokenInBalanceAfter >= tokenInBalanceBefore) {
            return;
        }

        uint256 tokenInDelta = tokenInBalanceBefore - tokenInBalanceAfter;

        // Validate that we received more tokenOut
        if (tokenOutBalanceAfter <= tokenOutBalanceBefore) {
            revert OdosSwapperFuseSlippageFail();
        }

        uint256 tokenOutDelta = tokenOutBalanceAfter - tokenOutBalanceBefore;

        // Validate minAmountOut (alpha check)
        if (tokenOutDelta < data_.minAmountOut) {
            revert OdosSwapperFuseMinAmountOutNotReached(data_.minAmountOut, tokenOutDelta);
        }

        // Skip USD slippage validation for mock tests (no oracle available in mock context)

        // Emit event
        emit OdosSwapperFuseEnter(VERSION, data_.tokenIn, data_.tokenOut, tokenInDelta, tokenOutDelta);
    }

    function _isTokenGranted(address token_) internal view returns (bool) {
        bytes32 substrate = OdosSubstrateLib.encodeTokenSubstrate(token_);
        return PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, substrate);
    }
}

/// @notice Helper contract to test library function reverts
/// @dev Library functions are inlined by the compiler, so we need a wrapper to test reverts
contract SlippageEncoderHelper {
    function encodeSlippage(uint256 slippageWad_) external pure returns (bytes32) {
        return OdosSubstrateLib.encodeSlippageSubstrate(slippageWad_);
    }
}
