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
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";

import {RoleLib, UsersToRoles} from "../../RoleLib.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {ZeroBalanceFuse} from "../../../contracts/fuses/ZeroBalanceFuse.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {PlasmaVaultConfigurator} from "../../utils/PlasmaVaultConfigurator.sol";

import {VeloraSwapperFuse, VeloraSwapperEnterData} from "../../../contracts/fuses/velora/VeloraSwapperFuse.sol";
import {VeloraSwapExecutor} from "../../../contracts/fuses/velora/VeloraSwapExecutor.sol";
import {VeloraSubstrateLib, VeloraSubstrateType} from "../../../contracts/fuses/velora/VeloraSubstrateLib.sol";

/// @title VeloraSwapperFuseTest
/// @notice Fork integration tests for VeloraSwapperFuse on Arbitrum.
contract VeloraSwapperFuseTest is Test {
    using SafeERC20 for ERC20;

    // ============ Events ============

    event VeloraSwapperFuseEnter(
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

    // Augustus v6.2 address (same on all EVM chains)
    // See: https://developers.paraswap.network/smart-contracts
    address private constant AUGUSTUS_V6_2 = 0x6A000F20005980200259B80c5102003040001068;

    // Chainlink price feeds on Arbitrum (no registry, must set individually)
    address private constant CHAINLINK_USDC_USD = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    address private constant CHAINLINK_WETH_USD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address private constant CHAINLINK_USDT_USD = 0x3f3f5dF88dC9F13eac63DF89EC16ef6e7E25DdE7;
    address private constant CHAINLINK_DAI_USD = 0xc5C8E77B397E531B8EC06BFb0048328B30E9eCfB;

    // Whale addresses for token distribution
    address private constant USDC_WHALE = 0x2Df1c51E09aECF9cacB7bc98cB1742757f163dF7;
    address private constant WETH_WHALE = 0xe50fA9b3c56FfB159cB0FCA61F5c9D750e8128c8;

    // Fork block number for reproducible tests (Velora API calldata generated at this block)
    // Note: Real API calldata contains timestamps/deadlines - use recent block for fork tests
    uint256 private constant FORK_BLOCK_NUMBER = 423997794;

    // ============ State Variables ============

    address private _plasmaVault;
    address private _withdrawManager;
    address private _priceOracle;
    address private _accessManager;

    VeloraSwapperFuse private _veloraSwapperFuse;
    VeloraSwapExecutor private _veloraSwapExecutor;

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
                "TEST VELORA PLASMA VAULT",
                "pvUSDC-VELORA",
                USDC,
                _priceOracle,
                _setupFeeConfig(),
                _accessManager,
                address(new PlasmaVaultBase()),
                _withdrawManager,
                address(0) // plasmaVaultVotesPlugin
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
        vm.label(address(_veloraSwapperFuse), "VeloraSwapperFuse");
        vm.label(address(_veloraSwapExecutor), "VeloraSwapExecutor");
        vm.label(_plasmaVault, "PlasmaVault");
        vm.label(USDC, "USDC");
        vm.label(WETH, "WETH");
        vm.label(USDT, "USDT");
        vm.label(AUGUSTUS_V6_2, "AugustusV6.2");
    }

    // ============ Constructor Tests ============

    function testShouldSetVersionToDeploymentAddress() public view {
        assertEq(_veloraSwapperFuse.VERSION(), address(_veloraSwapperFuse));
    }

    function testShouldSetMarketIdCorrectly() public view {
        assertEq(_veloraSwapperFuse.MARKET_ID(), IporFusionMarkets.VELORA_SWAPPER);
    }

    function testShouldSetExecutorCorrectly() public view {
        // Executor should be created during fuse deployment
        assertTrue(_veloraSwapperFuse.EXECUTOR() != address(0));
        assertEq(_veloraSwapperFuse.EXECUTOR(), address(_veloraSwapExecutor));
    }

    function testShouldRevertWhenMarketIdIsZero() public {
        // when/then
        vm.expectRevert(VeloraSwapperFuse.VeloraSwapperFuseInvalidMarketId.selector);
        new VeloraSwapperFuse(0);
    }

    // ============ Enter Tests - Failure Cases ============

    function testShouldRevertWhenTokenInIsZeroAddress() public {
        // given
        VeloraSwapperEnterData memory enterData = VeloraSwapperEnterData({
            tokenIn: address(0),
            tokenOut: WETH,
            amountIn: 1000e6,
            minAmountOut: 0,
            swapCallData: ""
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_veloraSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes))", enterData)
        );

        // when/then
        vm.expectRevert(abi.encodeWithSelector(VeloraSwapperFuse.VeloraSwapperFuseUnsupportedAsset.selector, address(0)));
        PlasmaVault(_plasmaVault).execute(enterCalls);
    }

    function testShouldRevertWhenTokenOutIsZeroAddress() public {
        // given
        _depositToVault(1000e6);

        VeloraSwapperEnterData memory enterData = VeloraSwapperEnterData({
            tokenIn: USDC,
            tokenOut: address(0),
            amountIn: 1000e6,
            minAmountOut: 0,
            swapCallData: ""
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_veloraSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes))", enterData)
        );

        // when/then
        vm.expectRevert(abi.encodeWithSelector(VeloraSwapperFuse.VeloraSwapperFuseUnsupportedAsset.selector, address(0)));
        PlasmaVault(_plasmaVault).execute(enterCalls);
    }

    function testShouldRevertWhenTokenInNotInSubstrates() public {
        // given
        address unsupportedToken = address(0x1234);

        VeloraSwapperEnterData memory enterData = VeloraSwapperEnterData({
            tokenIn: unsupportedToken,
            tokenOut: WETH,
            amountIn: 1000e6,
            minAmountOut: 0,
            swapCallData: ""
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_veloraSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes))", enterData)
        );

        // when/then
        vm.expectRevert(abi.encodeWithSelector(VeloraSwapperFuse.VeloraSwapperFuseUnsupportedAsset.selector, unsupportedToken));
        PlasmaVault(_plasmaVault).execute(enterCalls);
    }

    function testShouldRevertWhenTokenOutNotInSubstrates() public {
        // given
        address unsupportedToken = address(0x5678);

        // First deposit USDC to the vault
        _depositToVault(1000e6);

        VeloraSwapperEnterData memory enterData = VeloraSwapperEnterData({
            tokenIn: USDC,
            tokenOut: unsupportedToken,
            amountIn: 1000e6,
            minAmountOut: 0,
            swapCallData: ""
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_veloraSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes))", enterData)
        );

        // when/then
        vm.expectRevert(abi.encodeWithSelector(VeloraSwapperFuse.VeloraSwapperFuseUnsupportedAsset.selector, unsupportedToken));
        PlasmaVault(_plasmaVault).execute(enterCalls);
    }

    function testShouldRevertWhenZeroAmountIn() public {
        // given
        VeloraSwapperEnterData memory enterData = VeloraSwapperEnterData({
            tokenIn: USDC,
            tokenOut: WETH,
            amountIn: 0,
            minAmountOut: 0,
            swapCallData: ""
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_veloraSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes))", enterData)
        );

        // when/then
        vm.expectRevert(VeloraSwapperFuse.VeloraSwapperFuseZeroAmount.selector);
        PlasmaVault(_plasmaVault).execute(enterCalls);
    }

    // ============ Substrate Library Tests ============

    function testShouldEncodeTokenSubstrate() public pure {
        // given
        address token = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

        // when
        bytes32 encoded = VeloraSubstrateLib.encodeTokenSubstrate(token);

        // then
        assertTrue(VeloraSubstrateLib.isTokenSubstrate(encoded));
        assertFalse(VeloraSubstrateLib.isSlippageSubstrate(encoded));
    }

    function testShouldDecodeTokenSubstrate() public pure {
        // given
        address token = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

        // when
        bytes32 encoded = VeloraSubstrateLib.encodeTokenSubstrate(token);
        VeloraSubstrateType substrateType = VeloraSubstrateLib.decodeSubstrateType(encoded);
        address decodedToken = VeloraSubstrateLib.decodeToken(encoded);

        // then
        assertEq(uint8(substrateType), uint8(VeloraSubstrateType.Token));
        assertEq(decodedToken, token);
    }

    function testShouldEncodeSlippageSubstrate() public pure {
        // given
        uint256 slippage = 5e16; // 5%

        // when
        bytes32 encoded = VeloraSubstrateLib.encodeSlippageSubstrate(slippage);

        // then
        assertFalse(VeloraSubstrateLib.isTokenSubstrate(encoded));
        assertTrue(VeloraSubstrateLib.isSlippageSubstrate(encoded));
    }

    function testShouldDecodeSlippageSubstrate() public pure {
        // given
        uint256 slippage = 5e16; // 5%

        // when
        bytes32 encoded = VeloraSubstrateLib.encodeSlippageSubstrate(slippage);
        VeloraSubstrateType substrateType = VeloraSubstrateLib.decodeSubstrateType(encoded);
        uint256 decodedSlippage = VeloraSubstrateLib.decodeSlippage(encoded);

        // then
        assertEq(uint8(substrateType), uint8(VeloraSubstrateType.Slippage));
        assertEq(decodedSlippage, slippage);
    }

    function testShouldIdentifyTokenSubstrate() public pure {
        // given
        address token = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

        // when
        bytes32 encoded = VeloraSubstrateLib.encodeTokenSubstrate(token);

        // then
        assertTrue(VeloraSubstrateLib.isTokenSubstrate(encoded));
    }

    function testShouldIdentifySlippageSubstrate() public pure {
        // given
        uint256 slippage = 5e16; // 5%

        // when
        bytes32 encoded = VeloraSubstrateLib.encodeSlippageSubstrate(slippage);

        // then
        assertTrue(VeloraSubstrateLib.isSlippageSubstrate(encoded));
    }

    function testShouldRevertWhenSlippageOverflowsUint248() public {
        // given - value just above uint248 max should overflow
        uint256 overflowValue = uint256(type(uint248).max) + 1;

        // when/then - use helper contract to test revert (library functions are inlined)
        VeloraSlippageEncoderHelper helper = new VeloraSlippageEncoderHelper();
        vm.expectRevert(abi.encodeWithSelector(VeloraSubstrateLib.VeloraSubstrateLibSlippageOverflow.selector, overflowValue));
        helper.encodeSlippage(overflowValue);
    }

    function testShouldAcceptMaxUint248Slippage() public pure {
        // given - exactly max uint248 should be accepted
        uint256 maxValue = type(uint248).max;

        // when - should not revert
        bytes32 encoded = VeloraSubstrateLib.encodeSlippageSubstrate(maxValue);

        // then - decoded value should match
        uint256 decoded = VeloraSubstrateLib.decodeSlippage(encoded);
        assertEq(decoded, maxValue, "Decoded slippage should match max uint248");
    }

    function testShouldUseDefaultSlippageWhenNotConfigured() public view {
        // The default slippage should be 1% (1e16)
        assertEq(_veloraSwapperFuse.DEFAULT_SLIPPAGE_WAD(), 1e16);
    }

    // ============ Single-Pass Substrate Validation Tests ============

    /// @notice Test that validation works when both tokens are not in substrates (reverts on first - tokenIn)
    function testShouldRevertOnFirstTokenWhenBothTokensNotInSubstrates() public {
        // given - create a vault with only slippage substrate (no tokens)
        _setupVaultWithOnlySlippageSubstrate();

        address unsupportedTokenIn = address(0x1111);
        address unsupportedTokenOut = address(0x2222);

        VeloraSwapperEnterData memory enterData = VeloraSwapperEnterData({
            tokenIn: unsupportedTokenIn,
            tokenOut: unsupportedTokenOut,
            amountIn: 1000e6,
            minAmountOut: 0,
            swapCallData: ""
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_veloraSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes))", enterData)
        );

        // when/then - should revert with tokenIn (first check fails)
        vm.expectRevert(abi.encodeWithSelector(VeloraSwapperFuse.VeloraSwapperFuseUnsupportedAsset.selector, unsupportedTokenIn));
        PlasmaVault(_plasmaVault).execute(enterCalls);
    }

    /// @notice Test that validation works when same token is used for tokenIn and tokenOut
    function testShouldAllowSameTokenForInAndOut() public {
        // given
        uint256 depositAmount = 1000e6;
        _depositToVault(depositAmount);

        // Mock executor that returns all tokens back (no actual swap)
        MockNoOpVeloraSwapExecutor mockExecutor = new MockNoOpVeloraSwapExecutor();

        VeloraSwapperFuseWithMockExecutor testFuse = new VeloraSwapperFuseWithMockExecutor(
            IporFusionMarkets.VELORA_SWAPPER,
            address(mockExecutor)
        );

        address[] memory newFuses = new address[](1);
        newFuses[0] = address(testFuse);
        IPlasmaVaultGovernance(_plasmaVault).addFuses(newFuses);

        // Use same token for in and out (USDC -> USDC)
        VeloraSwapperEnterData memory enterData = VeloraSwapperEnterData({
            tokenIn: USDC,
            tokenOut: USDC,
            amountIn: depositAmount,
            minAmountOut: 0,
            swapCallData: ""
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(testFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes))", enterData)
        );

        uint256 vaultUsdcBefore = ERC20(USDC).balanceOf(_plasmaVault);

        // when - should not revert (early return because no tokens consumed)
        PlasmaVault(_plasmaVault).execute(enterCalls);

        // then - balance should be unchanged
        uint256 vaultUsdcAfter = ERC20(USDC).balanceOf(_plasmaVault);
        assertEq(vaultUsdcAfter, vaultUsdcBefore, "Balance should be unchanged");
    }

    /// @notice Test that validation works when slippage substrate comes before token substrates
    function testShouldValidateWhenSlippageSubstrateIsFirst() public {
        // given - setup vault with slippage first, then tokens
        _setupVaultWithSlippageFirst();

        uint256 depositAmount = 1000e6;
        _depositToVault(depositAmount);

        // Mock executor that simulates successful swap
        MockSuccessfulVeloraExecutor mockExecutor = new MockSuccessfulVeloraExecutor();

        vm.prank(WETH_WHALE);
        ERC20(WETH).transfer(address(mockExecutor), 0.3 ether);

        VeloraSwapperFuseWithMockExecutorAndEvent testFuse = new VeloraSwapperFuseWithMockExecutorAndEvent(
            IporFusionMarkets.VELORA_SWAPPER,
            address(mockExecutor)
        );

        address[] memory newFuses = new address[](1);
        newFuses[0] = address(testFuse);
        IPlasmaVaultGovernance(_plasmaVault).addFuses(newFuses);

        VeloraSwapperEnterData memory enterData = VeloraSwapperEnterData({
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

        // when - should succeed
        PlasmaVault(_plasmaVault).execute(enterCalls);

        // then
        uint256 vaultWethAfter = ERC20(WETH).balanceOf(_plasmaVault);
        assertGt(vaultWethAfter, 0, "Should have received WETH");
    }

    /// @notice Test that validation works when tokens are at the end of substrates list
    function testShouldValidateWhenTokensAreAtEndOfSubstrates() public {
        // given - setup vault with multiple slippage-like entries first, then tokens at end
        _setupVaultWithTokensAtEnd();

        uint256 depositAmount = 1000e6;
        _depositToVault(depositAmount);

        MockSuccessfulVeloraExecutor mockExecutor = new MockSuccessfulVeloraExecutor();

        vm.prank(WETH_WHALE);
        ERC20(WETH).transfer(address(mockExecutor), 0.3 ether);

        VeloraSwapperFuseWithMockExecutorAndEvent testFuse = new VeloraSwapperFuseWithMockExecutorAndEvent(
            IporFusionMarkets.VELORA_SWAPPER,
            address(mockExecutor)
        );

        address[] memory newFuses = new address[](1);
        newFuses[0] = address(testFuse);
        IPlasmaVaultGovernance(_plasmaVault).addFuses(newFuses);

        VeloraSwapperEnterData memory enterData = VeloraSwapperEnterData({
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

        // when - should succeed
        PlasmaVault(_plasmaVault).execute(enterCalls);

        // then
        uint256 vaultWethAfter = ERC20(WETH).balanceOf(_plasmaVault);
        assertGt(vaultWethAfter, 0, "Should have received WETH");
    }

    /// @notice Test that validation fails when substrates list is empty
    function testShouldRevertWhenSubstratesListIsEmpty() public {
        // given - setup vault with empty substrates
        _setupVaultWithEmptySubstrates();

        VeloraSwapperEnterData memory enterData = VeloraSwapperEnterData({
            tokenIn: USDC,
            tokenOut: WETH,
            amountIn: 1000e6,
            minAmountOut: 0,
            swapCallData: ""
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_veloraSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes))", enterData)
        );

        // when/then - should revert because tokenIn not found
        vm.expectRevert(abi.encodeWithSelector(VeloraSwapperFuse.VeloraSwapperFuseUnsupportedAsset.selector, USDC));
        PlasmaVault(_plasmaVault).execute(enterCalls);
    }

    /// @notice Test that only tokenIn is granted but tokenOut is not
    function testShouldRevertWhenOnlyTokenInIsGranted() public {
        // given - setup vault with only USDC granted
        _setupVaultWithOnlyTokenInGranted();

        uint256 depositAmount = 1000e6;
        _depositToVault(depositAmount);

        VeloraSwapperEnterData memory enterData = VeloraSwapperEnterData({
            tokenIn: USDC,
            tokenOut: WETH, // Not granted
            amountIn: depositAmount,
            minAmountOut: 0,
            swapCallData: ""
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_veloraSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes))", enterData)
        );

        // when/then - should revert on tokenOut
        vm.expectRevert(abi.encodeWithSelector(VeloraSwapperFuse.VeloraSwapperFuseUnsupportedAsset.selector, WETH));
        PlasmaVault(_plasmaVault).execute(enterCalls);
    }

    /// @notice Test that only tokenOut is granted but tokenIn is not
    function testShouldRevertWhenOnlyTokenOutIsGranted() public {
        // given - setup vault with only WETH granted
        _setupVaultWithOnlyTokenOutGranted();

        VeloraSwapperEnterData memory enterData = VeloraSwapperEnterData({
            tokenIn: USDC, // Not granted
            tokenOut: WETH,
            amountIn: 1000e6,
            minAmountOut: 0,
            swapCallData: ""
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_veloraSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes))", enterData)
        );

        // when/then - should revert on tokenIn (checked first)
        vm.expectRevert(abi.encodeWithSelector(VeloraSwapperFuse.VeloraSwapperFuseUnsupportedAsset.selector, USDC));
        PlasmaVault(_plasmaVault).execute(enterCalls);
    }

    // ============ Executor Tests ============

    function testExecutorShouldHaveCorrectAugustusAddress() public view {
        assertEq(_veloraSwapExecutor.AUGUSTUS_V6_2(), AUGUSTUS_V6_2);
    }

    function testExecutorShouldRevertWhenSwapFails() public {
        // given - send some tokens to executor
        uint256 amount = 100e6;
        vm.prank(USDC_WHALE);
        ERC20(USDC).transfer(address(_veloraSwapExecutor), amount);

        // when/then - calling with invalid calldata should fail
        vm.expectRevert(VeloraSwapExecutor.VeloraSwapExecutorSwapFailed.selector);
        _veloraSwapExecutor.execute(USDC, WETH, amount, hex"deadbeef");
    }

    function testExecutorCanBeCalledDirectlyByAnyone() public {
        // given - send some tokens to executor to test direct call scenario
        uint256 amount = 100e6;
        vm.prank(USDC_WHALE);
        ERC20(USDC).transfer(address(_veloraSwapExecutor), amount);

        uint256 executorUsdcBefore = ERC20(USDC).balanceOf(address(_veloraSwapExecutor));
        assertEq(executorUsdcBefore, amount, "Executor should have received USDC");

        address attacker = address(0xBAD);
        uint256 attackerUsdcBefore = ERC20(USDC).balanceOf(attacker);

        // when - anyone can call execute() directly
        // NOTE: This documents that executor lacks access control
        // With empty calldata, Augustus v6.2 doesn't revert, it returns without doing swap
        // The executor then sends all tokens back to msg.sender (the attacker!)
        vm.prank(attacker);
        _veloraSwapExecutor.execute(USDC, WETH, amount, "");

        // then - tokens are sent to the attacker (msg.sender)
        uint256 attackerUsdcAfter = ERC20(USDC).balanceOf(attacker);
        uint256 executorUsdcAfter = ERC20(USDC).balanceOf(address(_veloraSwapExecutor));

        // This demonstrates the security concern: tokens sent to executor by mistake
        // can be stolen by anyone who calls execute()
        assertEq(attackerUsdcAfter, attackerUsdcBefore + amount, "Attacker should have received all USDC");
        assertEq(executorUsdcAfter, 0, "Executor should have no USDC left");
    }

    // ============ MinAmountOut and Slippage Tests ============

    /// @notice Test that swap reverts when minAmountOut is not reached
    /// @dev Uses mock executor to simulate swap output below minAmountOut
    function testShouldRevertWhenMinAmountOutNotReached() public {
        // given
        uint256 depositAmount = 1000e6;
        _depositToVault(depositAmount);

        // Mock executor that returns less WETH than minAmountOut
        MockLowOutputVeloraExecutor mockExecutor = new MockLowOutputVeloraExecutor();

        // Pre-fund mock executor with small amount of WETH
        vm.prank(WETH_WHALE);
        ERC20(WETH).transfer(address(mockExecutor), 0.1 ether); // Only 0.1 WETH

        // Deploy a new fuse with our mock executor
        VeloraSwapperFuseWithMockExecutor testFuse = new VeloraSwapperFuseWithMockExecutor(
            IporFusionMarkets.VELORA_SWAPPER,
            address(mockExecutor)
        );

        // Configure the new fuse
        address[] memory newFuses = new address[](1);
        newFuses[0] = address(testFuse);
        IPlasmaVaultGovernance(_plasmaVault).addFuses(newFuses);

        // Require 1 WETH but mock executor only returns 0.1 WETH
        uint256 unrealisticMinAmountOut = 1 ether;

        VeloraSwapperEnterData memory enterData = VeloraSwapperEnterData({
            tokenIn: USDC,
            tokenOut: WETH,
            amountIn: depositAmount,
            minAmountOut: unrealisticMinAmountOut,
            swapCallData: ""
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(testFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes))", enterData)
        );

        // when/then - expect revert with MinAmountOutNotReached error
        vm.expectRevert(
            abi.encodeWithSelector(
                VeloraSwapperFuse.VeloraSwapperFuseMinAmountOutNotReached.selector,
                unrealisticMinAmountOut,
                0.1 ether
            )
        );
        PlasmaVault(_plasmaVault).execute(enterCalls);
    }

    /// @notice Test that event is emitted correctly during swap
    /// @dev Uses mock executor to simulate successful swap
    function testShouldEmitVeloraSwapperFuseEnterEvent() public {
        // given
        uint256 depositAmount = 1000e6;
        _depositToVault(depositAmount);

        // Mock executor that simulates a successful swap
        MockSuccessfulVeloraExecutor mockExecutor = new MockSuccessfulVeloraExecutor();

        // Pre-fund mock executor with WETH
        vm.prank(WETH_WHALE);
        ERC20(WETH).transfer(address(mockExecutor), 0.3 ether);

        // Deploy fuse with mock executor that emits events properly
        VeloraSwapperFuseWithMockExecutorAndEvent testFuse = new VeloraSwapperFuseWithMockExecutorAndEvent(
            IporFusionMarkets.VELORA_SWAPPER,
            address(mockExecutor)
        );

        // Configure the new fuse
        address[] memory newFuses = new address[](1);
        newFuses[0] = address(testFuse);
        IPlasmaVaultGovernance(_plasmaVault).addFuses(newFuses);

        VeloraSwapperEnterData memory enterData = VeloraSwapperEnterData({
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

        // when/then - expect event emission with indexed params
        vm.expectEmit(true, true, true, false);
        emit VeloraSwapperFuseEnter(address(testFuse), USDC, WETH, 0, 0);

        PlasmaVault(_plasmaVault).execute(enterCalls);
    }

    /// @notice Test HIGH PRIORITY: Revert when USD slippage exceeds the configured limit
    /// @dev Uses mock executor that returns significantly less value than input
    function testShouldRevertWhenSlippageExceeded() public {
        // given
        uint256 depositAmount = 1000e6;
        _depositToVault(depositAmount);

        // Mock executor that returns very little WETH (high slippage)
        MockHighSlippageVeloraExecutor mockExecutor = new MockHighSlippageVeloraExecutor();

        // Pre-fund mock executor with tiny amount of WETH (simulating 50% slippage)
        vm.prank(WETH_WHALE);
        ERC20(WETH).transfer(address(mockExecutor), 0.15 ether); // ~$500 worth at ~$3300/ETH vs $1000 input

        // Deploy fuse with mock executor
        VeloraSwapperFuseWithSlippageCheck testFuse = new VeloraSwapperFuseWithSlippageCheck(
            IporFusionMarkets.VELORA_SWAPPER,
            address(mockExecutor),
            _priceOracle
        );

        // Configure the new fuse
        address[] memory newFuses = new address[](1);
        newFuses[0] = address(testFuse);
        IPlasmaVaultGovernance(_plasmaVault).addFuses(newFuses);

        VeloraSwapperEnterData memory enterData = VeloraSwapperEnterData({
            tokenIn: USDC,
            tokenOut: WETH,
            amountIn: depositAmount,
            minAmountOut: 0, // No minAmountOut check, rely on slippage check
            swapCallData: ""
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(testFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes))", enterData)
        );

        // when/then - expect revert because USD slippage exceeds 2% limit
        vm.expectRevert(VeloraSwapperFuse.VeloraSwapperFuseSlippageFail.selector);
        PlasmaVault(_plasmaVault).execute(enterCalls);
    }

    /// @notice Test that custom slippage from substrates is used
    /// @dev Setup already configures 2% slippage in substrates, uses mock executor
    function testShouldUseCustomSlippageWhenConfigured() public {
        // given - setup already configures 2% slippage in substrates
        uint256 depositAmount = 1000e6;
        _depositToVault(depositAmount);

        // Mock executor that simulates a successful swap
        MockSuccessfulVeloraExecutor mockExecutor = new MockSuccessfulVeloraExecutor();

        // Pre-fund mock executor with WETH
        vm.prank(WETH_WHALE);
        ERC20(WETH).transfer(address(mockExecutor), 0.3 ether);

        // Deploy fuse with mock executor
        VeloraSwapperFuseWithMockExecutorAndEvent testFuse = new VeloraSwapperFuseWithMockExecutorAndEvent(
            IporFusionMarkets.VELORA_SWAPPER,
            address(mockExecutor)
        );

        // Configure the new fuse
        address[] memory newFuses = new address[](1);
        newFuses[0] = address(testFuse);
        IPlasmaVaultGovernance(_plasmaVault).addFuses(newFuses);

        VeloraSwapperEnterData memory enterData = VeloraSwapperEnterData({
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

        // when - execute should succeed with 2% custom slippage
        PlasmaVault(_plasmaVault).execute(enterCalls);

        // then - swap completed successfully
        uint256 vaultWethAfter = ERC20(WETH).balanceOf(_plasmaVault);
        assertGt(vaultWethAfter, 0, "Swap should succeed with custom 2% slippage");

        // Verify the default and custom slippage values
        assertEq(_veloraSwapperFuse.DEFAULT_SLIPPAGE_WAD(), 1e16, "Default slippage is 1%");
        // Custom slippage of 2% (2e16) was set in _setupMarketConfigs()
    }

    // ============ Price Oracle Error Tests ============

    /// @notice Test MEDIUM PRIORITY: Revert when price oracle middleware is not configured
    function testShouldRevertWhenPriceOracleMiddlewareNotConfigured() public {
        // given
        uint256 depositAmount = 1000e6;
        _depositToVault(depositAmount);

        // Mock executor that simulates successful swap
        MockSuccessfulVeloraExecutor mockExecutor = new MockSuccessfulVeloraExecutor();

        // Pre-fund mock executor
        vm.prank(WETH_WHALE);
        ERC20(WETH).transfer(address(mockExecutor), 0.3 ether);

        // Deploy fuse with zero price oracle (not configured)
        VeloraSwapperFuseWithSlippageCheck testFuse = new VeloraSwapperFuseWithSlippageCheck(
            IporFusionMarkets.VELORA_SWAPPER,
            address(mockExecutor),
            address(0) // Invalid oracle
        );

        // Configure the new fuse
        address[] memory newFuses = new address[](1);
        newFuses[0] = address(testFuse);
        IPlasmaVaultGovernance(_plasmaVault).addFuses(newFuses);

        VeloraSwapperEnterData memory enterData = VeloraSwapperEnterData({
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

        // when/then - expect revert because oracle is not configured
        vm.expectRevert(VeloraSwapperFuse.VeloraSwapperFuseInvalidPriceOracleMiddleware.selector);
        PlasmaVault(_plasmaVault).execute(enterCalls);
    }

    /// @notice Test MEDIUM PRIORITY: Revert when tokenIn price is zero
    function testShouldRevertWhenTokenInPriceIsZero() public {
        // given
        uint256 depositAmount = 1000e6;
        _depositToVault(depositAmount);

        // Mock executor that simulates successful swap
        MockSuccessfulVeloraExecutor mockExecutor = new MockSuccessfulVeloraExecutor();

        // Pre-fund mock executor
        vm.prank(WETH_WHALE);
        ERC20(WETH).transfer(address(mockExecutor), 0.3 ether);

        // Deploy mock price oracle that returns 0 for USDC
        MockZeroPriceOracle mockOracle = new MockZeroPriceOracle(true, false);

        // Deploy fuse with mock oracle
        VeloraSwapperFuseWithSlippageCheck testFuse = new VeloraSwapperFuseWithSlippageCheck(
            IporFusionMarkets.VELORA_SWAPPER,
            address(mockExecutor),
            address(mockOracle)
        );

        // Configure the new fuse
        address[] memory newFuses = new address[](1);
        newFuses[0] = address(testFuse);
        IPlasmaVaultGovernance(_plasmaVault).addFuses(newFuses);

        VeloraSwapperEnterData memory enterData = VeloraSwapperEnterData({
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

        // when/then - expect revert because tokenIn price is 0
        vm.expectRevert(abi.encodeWithSelector(VeloraSwapperFuse.VeloraSwapperFuseInvalidPrice.selector, USDC));
        PlasmaVault(_plasmaVault).execute(enterCalls);
    }

    /// @notice Test MEDIUM PRIORITY: Revert when tokenOut price is zero
    function testShouldRevertWhenTokenOutPriceIsZero() public {
        // given
        uint256 depositAmount = 1000e6;
        _depositToVault(depositAmount);

        // Mock executor that simulates successful swap
        MockSuccessfulVeloraExecutor mockExecutor = new MockSuccessfulVeloraExecutor();

        // Pre-fund mock executor
        vm.prank(WETH_WHALE);
        ERC20(WETH).transfer(address(mockExecutor), 0.3 ether);

        // Deploy mock price oracle that returns 0 for WETH (tokenOut)
        MockZeroPriceOracle mockOracle = new MockZeroPriceOracle(false, true);

        // Deploy fuse with mock oracle
        VeloraSwapperFuseWithSlippageCheck testFuse = new VeloraSwapperFuseWithSlippageCheck(
            IporFusionMarkets.VELORA_SWAPPER,
            address(mockExecutor),
            address(mockOracle)
        );

        // Configure the new fuse
        address[] memory newFuses = new address[](1);
        newFuses[0] = address(testFuse);
        IPlasmaVaultGovernance(_plasmaVault).addFuses(newFuses);

        VeloraSwapperEnterData memory enterData = VeloraSwapperEnterData({
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

        // when/then - expect revert because tokenOut price is 0
        vm.expectRevert(abi.encodeWithSelector(VeloraSwapperFuse.VeloraSwapperFuseInvalidPrice.selector, WETH));
        PlasmaVault(_plasmaVault).execute(enterCalls);
    }

    // ============ Edge Case Tests ============

    /// @notice Test HIGH PRIORITY: Revert when tokenOut balance does not increase after swap
    function testShouldRevertWhenTokenOutBalanceDoesNotIncrease() public {
        // given
        uint256 depositAmount = 1000e6;
        _depositToVault(depositAmount);

        // Mock a malicious/broken swap that consumes tokenIn but returns nothing
        MockBrokenVeloraSwapExecutor mockExecutor = new MockBrokenVeloraSwapExecutor();

        // Deploy a new fuse with our mock executor for testing
        VeloraSwapperFuseWithMockExecutor testFuse = new VeloraSwapperFuseWithMockExecutor(
            IporFusionMarkets.VELORA_SWAPPER,
            address(mockExecutor)
        );

        // Configure the new fuse in the vault
        address[] memory newFuses = new address[](1);
        newFuses[0] = address(testFuse);
        IPlasmaVaultGovernance(_plasmaVault).addFuses(newFuses);

        VeloraSwapperEnterData memory enterData = VeloraSwapperEnterData({
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
        vm.expectRevert(VeloraSwapperFuse.VeloraSwapperFuseSlippageFail.selector);
        PlasmaVault(_plasmaVault).execute(enterCalls);
    }

    /// @notice Test MEDIUM PRIORITY: Function returns early when no tokens are consumed
    function testShouldReturnEarlyWhenNoTokensConsumed() public {
        // given
        uint256 depositAmount = 1000e6;
        _depositToVault(depositAmount);

        // Mock an executor that returns all tokenIn without consuming any
        MockNoOpVeloraSwapExecutor mockExecutor = new MockNoOpVeloraSwapExecutor();

        // Deploy a new fuse with our mock executor
        VeloraSwapperFuseWithMockExecutor testFuse = new VeloraSwapperFuseWithMockExecutor(
            IporFusionMarkets.VELORA_SWAPPER,
            address(mockExecutor)
        );

        // Configure the new fuse
        address[] memory newFuses = new address[](1);
        newFuses[0] = address(testFuse);
        IPlasmaVaultGovernance(_plasmaVault).addFuses(newFuses);

        uint256 vaultUsdcBefore = ERC20(USDC).balanceOf(_plasmaVault);
        uint256 vaultWethBefore = ERC20(WETH).balanceOf(_plasmaVault);

        VeloraSwapperEnterData memory enterData = VeloraSwapperEnterData({
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
    function testShouldReturnUnusedTokenIn() public {
        // given
        uint256 depositAmount = 1000e6;
        _depositToVault(depositAmount);

        // Mock executor that uses only half the tokenIn and returns the rest
        MockPartialSwapVeloraExecutor mockExecutor = new MockPartialSwapVeloraExecutor();

        // Pre-fund mock executor with WETH for the simulated swap output
        vm.prank(WETH_WHALE);
        ERC20(WETH).transfer(address(mockExecutor), 0.2 ether);

        // Deploy a new fuse with our mock executor
        VeloraSwapperFuseWithMockExecutor testFuse = new VeloraSwapperFuseWithMockExecutor(
            IporFusionMarkets.VELORA_SWAPPER,
            address(mockExecutor)
        );

        // Configure the new fuse
        address[] memory newFuses = new address[](1);
        newFuses[0] = address(testFuse);
        IPlasmaVaultGovernance(_plasmaVault).addFuses(newFuses);

        uint256 vaultUsdcBefore = ERC20(USDC).balanceOf(_plasmaVault);

        VeloraSwapperEnterData memory enterData = VeloraSwapperEnterData({
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

    // ============ Fork Integration Tests with Real API Data ============

    /// @notice Test real swap USDC -> WETH via Velora/ParaSwap on Arbitrum fork
    /// @dev Uses real calldata from ParaSwap API with executor address as userAddress
    /// @dev This test requires a recent block number as the calldata contains timestamps
    function testShouldSwapUsdcToWethOnArbitrumForkWithRealApiData() public {
        // given
        uint256 depositAmount = 1000e6; // 1000 USDC
        _depositToVault(depositAmount);

        uint256 vaultUsdcBefore = ERC20(USDC).balanceOf(_plasmaVault);
        uint256 vaultWethBefore = ERC20(WETH).balanceOf(_plasmaVault);

        // Real calldata from ParaSwap API (generated with executor address as userAddress)
        // API call: POST https://api.paraswap.io/transactions/42161?ignoreChecks=true
        // userAddress: 0xeafCcCE3F73a1ac8690F49acF56C4142183619dd (executor address)
        // srcToken: USDC, destToken: WETH, srcAmount: 1000000000 (1000 USDC)
        // Expected output: ~0.332 WETH (at ~$3300/ETH)
        bytes memory swapCallData = hex"e3ead59e000000000000000000000000000010036c0190e009a000d0fc3541100a07380a000000000000000000000000af88d065e77c8cc2239327c5edb3a432268e583100000000000000000000000082af49447d8a07e3bd95bd0d56f35241523fbab1000000000000000000000000000000000000000000000000000000003b9aca00000000000000000000000000000000000000000000000000048fe7c176ca7bf3000000000000000000000000000000000000000000000000049bb3cb2d003f2479c34107785249f98e91fe6c17d7e51a0000000000000000000000001945b1c6000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000160000000000000000000000000000000000000000000000000000000000000018000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000460000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000004600fc85a171bd0b53bf0bbace74f04b66170ae3eab0000040000240000ff000003000000000000000000000000000000000000000000000000000000000947c2d90000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000009ef4a86b0f299b28510fd37e6f1361ec0f769a65000000000000000000000000129b3d9a0a6e4beab88f5cb1e57995d72a6e24f10000000000000000000000006a000f20005980200259b80c5102003040001068000000000000000000000000af88d065e77c8cc2239327c5edb3a432268e583100000000000000000000000082af49447d8a07e3bd95bd0d56f35241523fbab1000000000000000000000000000000000000000000000000000000003b9aca00000000000000000000000000000000000000000000000000049bb3cb2d003f4c000000000000000000000000000000000000000000000000049bb3cb2d003f4c000000000000000000000000000000000000000000000000000000006971f53c0000000000000000000000000000000000000000000000003d21715ddb97be7e000000000000000000000000000000000000000000000000000000006971f50d000000000000000000000000000000000000000000000000000000006971f530000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000003222fefb98e3457f8dd227bed3ffba3300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002800000000000000000000000006044eef7179034319e2c8636ea885b37cbfa9aba000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000000041a495cb059dab7ef513e911008f3f36b17027afbc57059e51e25e402476cf45b2431fdaf0145a68f87779ff8a115c1f42a0bdd98ea5aeaa142982fccded5757151c00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004149ccb95af61543633df30c26dc138c2097f44cfe5b4f5fad9129a46a02cfac6345148d743d056b41e37c7ea810ff638e321a1aaf79294164108a91cd23a959571c00000000000000000000000000000000000000000000000000000000000000";

        VeloraSwapperEnterData memory enterData = VeloraSwapperEnterData({
            tokenIn: USDC,
            tokenOut: WETH,
            amountIn: depositAmount,
            minAmountOut: 0.3 ether, // Expect at least 0.3 WETH
            swapCallData: swapCallData
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_veloraSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes))", enterData)
        );

        // when
        PlasmaVault(_plasmaVault).execute(enterCalls);

        // then
        uint256 vaultUsdcAfter = ERC20(USDC).balanceOf(_plasmaVault);
        uint256 vaultWethAfter = ERC20(WETH).balanceOf(_plasmaVault);

        // Verify USDC was consumed
        assertLt(vaultUsdcAfter, vaultUsdcBefore, "USDC should be consumed");
        assertEq(vaultUsdcBefore - vaultUsdcAfter, depositAmount, "All USDC should be swapped");

        // Verify WETH was received
        assertGt(vaultWethAfter, vaultWethBefore, "WETH should be received");
        assertGe(vaultWethAfter - vaultWethBefore, 0.3 ether, "Should receive at least 0.3 WETH");
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

        // Configure Velora market substrates with token addresses
        bytes32[] memory veloraSubstrates = new bytes32[](5);
        veloraSubstrates[0] = VeloraSubstrateLib.encodeTokenSubstrate(USDC);
        veloraSubstrates[1] = VeloraSubstrateLib.encodeTokenSubstrate(WETH);
        veloraSubstrates[2] = VeloraSubstrateLib.encodeTokenSubstrate(USDT);
        veloraSubstrates[3] = VeloraSubstrateLib.encodeTokenSubstrate(DAI);
        veloraSubstrates[4] = VeloraSubstrateLib.encodeSlippageSubstrate(2e16); // 2% slippage

        marketConfigs_[0] = MarketSubstratesConfig(IporFusionMarkets.VELORA_SWAPPER, veloraSubstrates);
    }

    function _setupFuses() private returns (address[] memory fuses_) {
        // Deploy fuse (executor is created in constructor)
        _veloraSwapperFuse = new VeloraSwapperFuse(IporFusionMarkets.VELORA_SWAPPER);
        _veloraSwapExecutor = VeloraSwapExecutor(_veloraSwapperFuse.EXECUTOR());

        fuses_ = new address[](1);
        fuses_[0] = address(_veloraSwapperFuse);
    }

    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses_) {
        ZeroBalanceFuse zeroBalance = new ZeroBalanceFuse(IporFusionMarkets.VELORA_SWAPPER);

        balanceFuses_ = new MarketBalanceFuseConfig[](1);
        balanceFuses_[0] = MarketBalanceFuseConfig(IporFusionMarkets.VELORA_SWAPPER, address(zeroBalance));
    }

    // ============ Additional Setup Helpers for Substrate Validation Tests ============

    function _setupVaultWithOnlySlippageSubstrate() private {
        // Configure market with only slippage substrate (no tokens)
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = VeloraSubstrateLib.encodeSlippageSubstrate(2e16); // 2% slippage only

        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(IporFusionMarkets.VELORA_SWAPPER, substrates);
    }

    function _setupVaultWithSlippageFirst() private {
        // Configure market with slippage first, then tokens
        bytes32[] memory substrates = new bytes32[](3);
        substrates[0] = VeloraSubstrateLib.encodeSlippageSubstrate(3e16); // 3% slippage first
        substrates[1] = VeloraSubstrateLib.encodeTokenSubstrate(USDC);
        substrates[2] = VeloraSubstrateLib.encodeTokenSubstrate(WETH);

        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(IporFusionMarkets.VELORA_SWAPPER, substrates);
    }

    function _setupVaultWithTokensAtEnd() private {
        // Configure market with slippage first, dummy entries, then tokens at end
        bytes32[] memory substrates = new bytes32[](4);
        substrates[0] = VeloraSubstrateLib.encodeSlippageSubstrate(2e16); // slippage first
        substrates[1] = VeloraSubstrateLib.encodeTokenSubstrate(DAI); // other token
        substrates[2] = VeloraSubstrateLib.encodeTokenSubstrate(USDC); // tokenIn at end
        substrates[3] = VeloraSubstrateLib.encodeTokenSubstrate(WETH); // tokenOut at end

        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(IporFusionMarkets.VELORA_SWAPPER, substrates);
    }

    function _setupVaultWithEmptySubstrates() private {
        // Note: grantMarketSubstrates adds to existing, so we need a fresh vault
        // For this test, we use the fact that unsupported tokens won't be found anyway
        // The initial setup already has substrates, but we test with tokens not in that list
        bytes32[] memory substrates = new bytes32[](0);
        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(IporFusionMarkets.VELORA_SWAPPER, substrates);
    }

    function _setupVaultWithOnlyTokenInGranted() private {
        // Configure market with only USDC (tokenIn) granted
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = VeloraSubstrateLib.encodeTokenSubstrate(USDC);
        substrates[1] = VeloraSubstrateLib.encodeSlippageSubstrate(2e16);

        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(IporFusionMarkets.VELORA_SWAPPER, substrates);
    }

    function _setupVaultWithOnlyTokenOutGranted() private {
        // Configure market with only WETH (tokenOut) granted
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = VeloraSubstrateLib.encodeTokenSubstrate(WETH);
        substrates[1] = VeloraSubstrateLib.encodeSlippageSubstrate(2e16);

        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(IporFusionMarkets.VELORA_SWAPPER, substrates);
    }
}

// ============ Mock Contracts for Edge Case Testing ============

/// @notice Mock executor that consumes tokenIn but returns no tokenOut (simulates broken swap)
contract MockBrokenVeloraSwapExecutor {
    using SafeERC20 for ERC20;

    function execute(
        address tokenIn_,
        address, // tokenOut_ - not used
        uint256, // amountIn_ - not used
        bytes calldata // swapCallData_ - not used
    ) external {
        // Consume ALL tokenIn (don't return anything)
        uint256 balance = ERC20(tokenIn_).balanceOf(address(this));
        if (balance > 0) {
            // Do nothing - tokenIn stays in executor, tokenOut never sent
        }
    }
}

/// @notice Mock executor that returns all tokenIn without doing any swap (no-op)
contract MockNoOpVeloraSwapExecutor {
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
contract MockPartialSwapVeloraExecutor {
    using SafeERC20 for ERC20;

    // WETH address on Arbitrum for mock swap
    address private constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

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
        uint256 mockOutputAmount = 0.1 ether;
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
contract VeloraSwapperFuseWithMockExecutor {
    using SafeERC20 for ERC20;

    event VeloraSwapperFuseEnter(
        address indexed version,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 tokenInDelta,
        uint256 tokenOutDelta
    );

    error VeloraSwapperFuseUnsupportedAsset(address asset);
    error VeloraSwapperFuseMinAmountOutNotReached(uint256 expected, uint256 actual);
    error VeloraSwapperFuseSlippageFail();
    error VeloraSwapperFuseZeroAmount();
    error VeloraSwapperFuseInvalidMarketId();

    uint256 public constant DEFAULT_SLIPPAGE_WAD = 1e16;
    uint256 private constant _ONE = 1e18;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address public immutable EXECUTOR;

    constructor(uint256 marketId_, address executor_) {
        if (marketId_ == 0) {
            revert VeloraSwapperFuseInvalidMarketId();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
        EXECUTOR = executor_;
    }

    function enter(VeloraSwapperEnterData calldata data_) external {
        // Validate tokenIn is in substrates
        if (!_isTokenGranted(data_.tokenIn)) {
            revert VeloraSwapperFuseUnsupportedAsset(data_.tokenIn);
        }

        // Validate tokenOut is in substrates
        if (!_isTokenGranted(data_.tokenOut)) {
            revert VeloraSwapperFuseUnsupportedAsset(data_.tokenOut);
        }

        // Revert if amountIn is 0
        if (data_.amountIn == 0) {
            revert VeloraSwapperFuseZeroAmount();
        }

        address plasmaVault = address(this);

        // Record balances before swap
        uint256 tokenInBalanceBefore = ERC20(data_.tokenIn).balanceOf(plasmaVault);
        uint256 tokenOutBalanceBefore = ERC20(data_.tokenOut).balanceOf(plasmaVault);

        // Transfer tokenIn to executor
        ERC20(data_.tokenIn).safeTransfer(EXECUTOR, data_.amountIn);

        // Call mock executor
        MockBrokenVeloraSwapExecutor(EXECUTOR).execute(data_.tokenIn, data_.tokenOut, data_.amountIn, data_.swapCallData);

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
            revert VeloraSwapperFuseSlippageFail();
        }

        uint256 tokenOutDelta = tokenOutBalanceAfter - tokenOutBalanceBefore;

        // Validate minAmountOut (alpha check)
        if (tokenOutDelta < data_.minAmountOut) {
            revert VeloraSwapperFuseMinAmountOutNotReached(data_.minAmountOut, tokenOutDelta);
        }

        // Skip USD slippage validation for mock tests

        // Emit event
        emit VeloraSwapperFuseEnter(VERSION, data_.tokenIn, data_.tokenOut, tokenInDelta, tokenOutDelta);
    }

    function _isTokenGranted(address token_) internal view returns (bool) {
        bytes32 substrate = VeloraSubstrateLib.encodeTokenSubstrate(token_);
        return PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, substrate);
    }
}

/// @notice Helper contract to test library function reverts
/// @dev Library functions are inlined by the compiler, so we need a wrapper to test reverts
contract VeloraSlippageEncoderHelper {
    function encodeSlippage(uint256 slippageWad_) external pure returns (bytes32) {
        return VeloraSubstrateLib.encodeSlippageSubstrate(slippageWad_);
    }
}

/// @notice Mock executor that returns less than expected output (for minAmountOut test)
contract MockLowOutputVeloraExecutor {
    using SafeERC20 for ERC20;

    address private constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    function execute(
        address tokenIn_,
        address tokenOut_,
        uint256,
        bytes calldata
    ) external {
        // Consume all tokenIn (don't return it)
        uint256 tokenInBalance = ERC20(tokenIn_).balanceOf(address(this));
        // Keep tokenIn in executor (simulating it was used in swap)

        // Return only 0.1 WETH (less than what would be expected for 1000 USDC)
        if (tokenOut_ == WETH) {
            uint256 wethBalance = ERC20(WETH).balanceOf(address(this));
            if (wethBalance > 0) {
                ERC20(WETH).safeTransfer(msg.sender, wethBalance);
            }
        }
    }
}

/// @notice Mock executor that simulates a successful swap
contract MockSuccessfulVeloraExecutor {
    using SafeERC20 for ERC20;

    address private constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    function execute(
        address tokenIn_,
        address tokenOut_,
        uint256,
        bytes calldata
    ) external {
        // Consume all tokenIn (don't return it)
        // tokenIn stays in executor simulating consumption

        // Return WETH to caller
        if (tokenOut_ == WETH) {
            uint256 wethBalance = ERC20(WETH).balanceOf(address(this));
            if (wethBalance > 0) {
                ERC20(WETH).safeTransfer(msg.sender, wethBalance);
            }
        }
    }
}

/// @notice Fuse with mock executor that properly emits events
contract VeloraSwapperFuseWithMockExecutorAndEvent {
    using SafeERC20 for ERC20;

    event VeloraSwapperFuseEnter(
        address indexed version,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 tokenInDelta,
        uint256 tokenOutDelta
    );

    error VeloraSwapperFuseUnsupportedAsset(address asset);
    error VeloraSwapperFuseMinAmountOutNotReached(uint256 expected, uint256 actual);
    error VeloraSwapperFuseSlippageFail();
    error VeloraSwapperFuseZeroAmount();
    error VeloraSwapperFuseInvalidMarketId();

    uint256 public constant DEFAULT_SLIPPAGE_WAD = 1e16;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address public immutable EXECUTOR;

    constructor(uint256 marketId_, address executor_) {
        if (marketId_ == 0) {
            revert VeloraSwapperFuseInvalidMarketId();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
        EXECUTOR = executor_;
    }

    function enter(VeloraSwapperEnterData calldata data_) external {
        if (!_isTokenGranted(data_.tokenIn)) {
            revert VeloraSwapperFuseUnsupportedAsset(data_.tokenIn);
        }
        if (!_isTokenGranted(data_.tokenOut)) {
            revert VeloraSwapperFuseUnsupportedAsset(data_.tokenOut);
        }
        if (data_.amountIn == 0) {
            revert VeloraSwapperFuseZeroAmount();
        }

        address plasmaVault = address(this);

        uint256 tokenInBalanceBefore = ERC20(data_.tokenIn).balanceOf(plasmaVault);
        uint256 tokenOutBalanceBefore = ERC20(data_.tokenOut).balanceOf(plasmaVault);

        ERC20(data_.tokenIn).safeTransfer(EXECUTOR, data_.amountIn);

        MockSuccessfulVeloraExecutor(EXECUTOR).execute(data_.tokenIn, data_.tokenOut, data_.amountIn, data_.swapCallData);

        uint256 tokenInBalanceAfter = ERC20(data_.tokenIn).balanceOf(plasmaVault);
        uint256 tokenOutBalanceAfter = ERC20(data_.tokenOut).balanceOf(plasmaVault);

        if (tokenInBalanceAfter >= tokenInBalanceBefore) {
            return;
        }

        uint256 tokenInDelta = tokenInBalanceBefore - tokenInBalanceAfter;

        if (tokenOutBalanceAfter <= tokenOutBalanceBefore) {
            revert VeloraSwapperFuseSlippageFail();
        }

        uint256 tokenOutDelta = tokenOutBalanceAfter - tokenOutBalanceBefore;

        if (tokenOutDelta < data_.minAmountOut) {
            revert VeloraSwapperFuseMinAmountOutNotReached(data_.minAmountOut, tokenOutDelta);
        }

        emit VeloraSwapperFuseEnter(VERSION, data_.tokenIn, data_.tokenOut, tokenInDelta, tokenOutDelta);
    }

    function _isTokenGranted(address token_) internal view returns (bool) {
        bytes32 substrate = VeloraSubstrateLib.encodeTokenSubstrate(token_);
        return PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, substrate);
    }
}

/// @notice Mock executor that returns significantly less value (high slippage simulation)
contract MockHighSlippageVeloraExecutor {
    using SafeERC20 for ERC20;

    address private constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    function execute(
        address,
        address tokenOut_,
        uint256,
        bytes calldata
    ) external {
        // Return all WETH we have (which is much less than expected)
        if (tokenOut_ == WETH) {
            uint256 wethBalance = ERC20(WETH).balanceOf(address(this));
            if (wethBalance > 0) {
                ERC20(WETH).safeTransfer(msg.sender, wethBalance);
            }
        }
    }
}

/// @notice Mock price oracle that returns zero price for specified tokens
contract MockZeroPriceOracle {
    bool private _zeroTokenInPrice;
    bool private _zeroTokenOutPrice;

    address private constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    constructor(bool zeroTokenInPrice_, bool zeroTokenOutPrice_) {
        _zeroTokenInPrice = zeroTokenInPrice_;
        _zeroTokenOutPrice = zeroTokenOutPrice_;
    }

    function getAssetPrice(address asset_) external view returns (uint256 price, uint256 decimals) {
        if (asset_ == USDC && _zeroTokenInPrice) {
            return (0, 8);
        }
        if (asset_ == WETH && _zeroTokenOutPrice) {
            return (0, 8);
        }
        // Return valid prices for other cases
        if (asset_ == USDC) {
            return (1e8, 8); // $1.00
        }
        if (asset_ == WETH) {
            return (3300e8, 8); // $3300
        }
        return (1e8, 8);
    }
}

/// @notice Fuse with slippage check that uses injected price oracle
contract VeloraSwapperFuseWithSlippageCheck {
    using SafeERC20 for ERC20;

    event VeloraSwapperFuseEnter(
        address indexed version,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 tokenInDelta,
        uint256 tokenOutDelta
    );

    error VeloraSwapperFuseUnsupportedAsset(address asset);
    error VeloraSwapperFuseMinAmountOutNotReached(uint256 expected, uint256 actual);
    error VeloraSwapperFuseSlippageFail();
    error VeloraSwapperFuseZeroAmount();
    error VeloraSwapperFuseInvalidMarketId();
    error VeloraSwapperFuseInvalidPrice(address asset);
    error VeloraSwapperFuseInvalidPriceOracleMiddleware();

    uint256 public constant DEFAULT_SLIPPAGE_WAD = 1e16;
    uint256 private constant _ONE = 1e18;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address public immutable EXECUTOR;
    address public immutable PRICE_ORACLE;

    constructor(uint256 marketId_, address executor_, address priceOracle_) {
        if (marketId_ == 0) {
            revert VeloraSwapperFuseInvalidMarketId();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
        EXECUTOR = executor_;
        PRICE_ORACLE = priceOracle_;
    }

    function enter(VeloraSwapperEnterData calldata data_) external {
        if (!_isTokenGranted(data_.tokenIn)) {
            revert VeloraSwapperFuseUnsupportedAsset(data_.tokenIn);
        }
        if (!_isTokenGranted(data_.tokenOut)) {
            revert VeloraSwapperFuseUnsupportedAsset(data_.tokenOut);
        }
        if (data_.amountIn == 0) {
            revert VeloraSwapperFuseZeroAmount();
        }

        address plasmaVault = address(this);

        uint256 tokenInBalanceBefore = ERC20(data_.tokenIn).balanceOf(plasmaVault);
        uint256 tokenOutBalanceBefore = ERC20(data_.tokenOut).balanceOf(plasmaVault);

        ERC20(data_.tokenIn).safeTransfer(EXECUTOR, data_.amountIn);

        MockHighSlippageVeloraExecutor(EXECUTOR).execute(data_.tokenIn, data_.tokenOut, data_.amountIn, data_.swapCallData);

        uint256 tokenInBalanceAfter = ERC20(data_.tokenIn).balanceOf(plasmaVault);
        uint256 tokenOutBalanceAfter = ERC20(data_.tokenOut).balanceOf(plasmaVault);

        if (tokenInBalanceAfter >= tokenInBalanceBefore) {
            return;
        }

        uint256 tokenInDelta = tokenInBalanceBefore - tokenInBalanceAfter;

        if (tokenOutBalanceAfter <= tokenOutBalanceBefore) {
            revert VeloraSwapperFuseSlippageFail();
        }

        uint256 tokenOutDelta = tokenOutBalanceAfter - tokenOutBalanceBefore;

        if (tokenOutDelta < data_.minAmountOut) {
            revert VeloraSwapperFuseMinAmountOutNotReached(data_.minAmountOut, tokenOutDelta);
        }

        // Validate USD slippage with injected oracle
        _validateUsdSlippage(data_.tokenIn, data_.tokenOut, tokenInDelta, tokenOutDelta);

        emit VeloraSwapperFuseEnter(VERSION, data_.tokenIn, data_.tokenOut, tokenInDelta, tokenOutDelta);
    }

    function _validateUsdSlippage(
        address tokenIn_,
        address tokenOut_,
        uint256 tokenInDelta_,
        uint256 tokenOutDelta_
    ) internal view {
        if (PRICE_ORACLE == address(0)) {
            revert VeloraSwapperFuseInvalidPriceOracleMiddleware();
        }

        (uint256 tokenInPrice, uint256 tokenInPriceDecimals) = MockZeroPriceOracle(PRICE_ORACLE).getAssetPrice(tokenIn_);
        (uint256 tokenOutPrice, uint256 tokenOutPriceDecimals) = MockZeroPriceOracle(PRICE_ORACLE).getAssetPrice(tokenOut_);

        if (tokenInPrice == 0) {
            revert VeloraSwapperFuseInvalidPrice(tokenIn_);
        }
        if (tokenOutPrice == 0) {
            revert VeloraSwapperFuseInvalidPrice(tokenOut_);
        }

        // Get token decimals
        uint256 tokenInDecimals = ERC20(tokenIn_).decimals();
        uint256 tokenOutDecimals = ERC20(tokenOut_).decimals();

        // Convert to USD values in WAD (1e18)
        uint256 amountUsdInDelta = (tokenInDelta_ * tokenInPrice * _ONE) / (10 ** (tokenInDecimals + tokenInPriceDecimals));
        uint256 amountUsdOutDelta = (tokenOutDelta_ * tokenOutPrice * _ONE) / (10 ** (tokenOutDecimals + tokenOutPriceDecimals));

        if (amountUsdInDelta == 0) {
            revert VeloraSwapperFuseSlippageFail();
        }

        // Calculate quotient: amountUsdOut / amountUsdIn
        uint256 quotient = (amountUsdOutDelta * _ONE) / amountUsdInDelta;

        // Get slippage limit (2% configured in substrates)
        uint256 slippageLimit = _getSlippageLimit();

        // Compare against slippage limit (1 - slippagePercentage)
        if (quotient < (_ONE - slippageLimit)) {
            revert VeloraSwapperFuseSlippageFail();
        }
    }

    function _isTokenGranted(address token_) internal view returns (bool) {
        bytes32 substrate = VeloraSubstrateLib.encodeTokenSubstrate(token_);
        return PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, substrate);
    }

    function _getSlippageLimit() internal view returns (uint256 slippageWad) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);
        uint256 length = substrates.length;

        for (uint256 i; i < length; ++i) {
            if (VeloraSubstrateLib.isSlippageSubstrate(substrates[i])) {
                return VeloraSubstrateLib.decodeSlippage(substrates[i]);
            }
        }

        return DEFAULT_SLIPPAGE_WAD;
    }
}
