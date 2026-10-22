// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
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

    /// @dev WETH amount the calldata-driven pull router pays (set by {_installPullRouter})
    uint256 private _routerWethOut;

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
            swapCallData: "",
            tokensToReturn: new address[](0)
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_veloraSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes,address[]))", enterData)
        );

        // when/then
        vm.expectRevert(
            abi.encodeWithSelector(VeloraSwapperFuse.VeloraSwapperFuseUnsupportedAsset.selector, address(0))
        );
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
            swapCallData: "",
            tokensToReturn: new address[](0)
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_veloraSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes,address[]))", enterData)
        );

        // when/then
        vm.expectRevert(
            abi.encodeWithSelector(VeloraSwapperFuse.VeloraSwapperFuseUnsupportedAsset.selector, address(0))
        );
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
            swapCallData: "",
            tokensToReturn: new address[](0)
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_veloraSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes,address[]))", enterData)
        );

        // when/then
        vm.expectRevert(
            abi.encodeWithSelector(VeloraSwapperFuse.VeloraSwapperFuseUnsupportedAsset.selector, unsupportedToken)
        );
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
            swapCallData: "",
            tokensToReturn: new address[](0)
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_veloraSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes,address[]))", enterData)
        );

        // when/then
        vm.expectRevert(
            abi.encodeWithSelector(VeloraSwapperFuse.VeloraSwapperFuseUnsupportedAsset.selector, unsupportedToken)
        );
        PlasmaVault(_plasmaVault).execute(enterCalls);
    }

    function testShouldRevertWhenZeroAmountIn() public {
        // given
        VeloraSwapperEnterData memory enterData = VeloraSwapperEnterData({
            tokenIn: USDC,
            tokenOut: WETH,
            amountIn: 0,
            minAmountOut: 0,
            swapCallData: "",
            tokensToReturn: new address[](0)
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_veloraSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes,address[]))", enterData)
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
        vm.expectRevert(
            abi.encodeWithSelector(VeloraSubstrateLib.VeloraSubstrateLibSlippageOverflow.selector, overflowValue)
        );
        helper.encodeSlippage(overflowValue);
    }

    /// @notice IL-8033 test 6: type(uint248).max is above 1e18, so it is now rejected with the
    /// 100%-bound error rather than silently encoded. Fails without the fix (encodes fine today).
    function testShouldRevertWhenSlippageExceeds100PercentAtMaxUint248() public {
        // given - exactly max uint248 is above 1e18 and should be rejected
        uint256 maxValue = type(uint248).max;

        // when/then - use helper contract to test revert (library functions are inlined)
        VeloraSlippageEncoderHelper helper = new VeloraSlippageEncoderHelper();
        vm.expectRevert(
            abi.encodeWithSelector(VeloraSubstrateLib.VeloraSubstrateLibSlippageExceeds100Percent.selector, maxValue)
        );
        helper.encodeSlippage(maxValue);
    }

    /// @notice IL-8033 test 5: encoding a value just above 1e18 (100%) is rejected fail-fast by the
    /// encoder. Fails without the fix (encodes fine today), passes with it.
    function testShouldRevertWhenEncodingSlippageAbove100Percent() public {
        // given
        uint256 aboveOneHundredPercent = 1e18 + 1;

        // when/then
        VeloraSlippageEncoderHelper helper = new VeloraSlippageEncoderHelper();
        vm.expectRevert(
            abi.encodeWithSelector(
                VeloraSubstrateLib.VeloraSubstrateLibSlippageExceeds100Percent.selector,
                aboveOneHundredPercent
            )
        );
        helper.encodeSlippage(aboveOneHundredPercent);
    }

    /// @notice IL-8033 test 7 (positive control): exactly 1e18 (100%) still encodes successfully.
    /// Passes both before and after the fix; documents that the strict `>` bound keeps 1e18 valid.
    function testShouldEncodeSlippageOfExactly100Percent() public pure {
        // given - exactly 1e18 (100%) should be accepted
        uint256 oneHundredPercent = 1e18;

        // when - should not revert
        bytes32 encoded = VeloraSubstrateLib.encodeSlippageSubstrate(oneHundredPercent);

        // then - decoded value should match
        uint256 decoded = VeloraSubstrateLib.decodeSlippage(encoded);
        assertEq(decoded, oneHundredPercent, "Decoded slippage should match 1e18");
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
            swapCallData: "",
            tokensToReturn: new address[](0)
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_veloraSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes,address[]))", enterData)
        );

        // when/then - should revert with tokenIn (first check fails)
        vm.expectRevert(
            abi.encodeWithSelector(VeloraSwapperFuse.VeloraSwapperFuseUnsupportedAsset.selector, unsupportedTokenIn)
        );
        PlasmaVault(_plasmaVault).execute(enterCalls);
    }

    /// @notice tokenIn == tokenOut is rejected by the production fuse
    function testShouldRevertWhenTokenInEqualsTokenOut() public {
        // given
        _depositToVault(1000e6);

        // when/then
        vm.expectRevert(VeloraSwapperFuse.VeloraSwapperFuseSameTokens.selector);
        _enterWithPullRouter(USDC, USDC, 1000e6, 0, 0);
    }

    /// @notice An honest route passes the production substrate walk with this substrate order
    function testShouldValidateWhenSlippageSubstrateIsFirst() public {
        // given
        _setupVaultWithSlippageFirst();
        _depositToVault(1000e6);
        _installPullRouter(0.33 ether);

        // when
        _enterWithPullRouter(USDC, WETH, 1000e6, 0, 10000);

        // then
        assertEq(ERC20(WETH).balanceOf(_plasmaVault), 0.33 ether, "WETH received");
        assertEq(ERC20(USDC).balanceOf(_plasmaVault), 0, "USDC spent");
    }

    /// @notice An honest route passes the production substrate walk with this substrate order
    function testShouldValidateWhenTokensAreAtEndOfSubstrates() public {
        // given
        _setupVaultWithTokensAtEnd();
        _depositToVault(1000e6);
        _installPullRouter(0.33 ether);

        // when
        _enterWithPullRouter(USDC, WETH, 1000e6, 0, 10000);

        // then
        assertEq(ERC20(WETH).balanceOf(_plasmaVault), 0.33 ether, "WETH received");
        assertEq(ERC20(USDC).balanceOf(_plasmaVault), 0, "USDC spent");
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
            swapCallData: "",
            tokensToReturn: new address[](0)
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_veloraSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes,address[]))", enterData)
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
            swapCallData: "",
            tokensToReturn: new address[](0)
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_veloraSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes,address[]))", enterData)
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
            swapCallData: "",
            tokensToReturn: new address[](0)
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_veloraSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes,address[]))", enterData)
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
        _veloraSwapExecutor.execute(USDC, WETH, amount, hex"deadbeef", new address[](0));
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
        _veloraSwapExecutor.execute(USDC, WETH, amount, "", new address[](0));

        // then - tokens are sent to the attacker (msg.sender)
        uint256 attackerUsdcAfter = ERC20(USDC).balanceOf(attacker);
        uint256 executorUsdcAfter = ERC20(USDC).balanceOf(address(_veloraSwapExecutor));

        // This demonstrates the security concern: tokens sent to executor by mistake
        // can be stolen by anyone who calls execute()
        assertEq(attackerUsdcAfter, attackerUsdcBefore + amount, "Attacker should have received all USDC");
        assertEq(executorUsdcAfter, 0, "Executor should have no USDC left");
    }

    // ============ MinAmountOut and Slippage Tests ============

    /// @notice Swap output below minAmountOut reverts with the expected/actual pair
    function testShouldRevertWhenMinAmountOutNotReached() public {
        // given
        _depositToVault(1000e6);
        _installPullRouter(0.1 ether);

        // when/then - requires 1 WETH, the router pays 0.1 WETH
        vm.expectRevert(
            abi.encodeWithSelector(
                VeloraSwapperFuse.VeloraSwapperFuseMinAmountOutNotReached.selector,
                1 ether,
                0.1 ether
            )
        );
        _enterWithPullRouter(USDC, WETH, 1000e6, 1 ether, 10000);
    }

    /// @notice Output worth ~45% of the input fails the USD slippage quotient check
    function testShouldRevertWhenSlippageExceeded() public {
        // given
        _depositToVault(1000e6);
        _installPullRouter(0.15 ether);

        // when/then
        vm.expectRevert(VeloraSwapperFuse.VeloraSwapperFuseSlippageFail.selector);
        _enterWithPullRouter(USDC, WETH, 1000e6, 0, 10000);
    }

    /// @notice The slippage substrate (2%) is honoured: an output ~98.5% of the input value passes at 2% and
    /// fails with the 1% default once the slippage substrate is removed
    function testShouldUseCustomSlippageWhenConfigured() public {
        // given - USDC=0.99979828 USD, WETH=3012.16598784 USD at the fork block: 0.3269 WETH is ~98.49% of 1000 USDC
        uint256 wethOut = 0.3269 ether;
        _depositToVault(2000e6);
        _installPullRouter(wethOut);

        // when - 2% slippage substrate from _setupMarketConfigs
        _enterWithPullRouter(USDC, WETH, 1000e6, 0, 10000);

        // then
        assertEq(ERC20(WETH).balanceOf(_plasmaVault), wethOut, "swap passes at 2%");

        // given - same route again, slippage substrate removed (default 1% applies)
        _installPullRouter(wethOut);
        bytes32[] memory substrates = new bytes32[](4);
        substrates[0] = VeloraSubstrateLib.encodeTokenSubstrate(USDC);
        substrates[1] = VeloraSubstrateLib.encodeTokenSubstrate(WETH);
        substrates[2] = VeloraSubstrateLib.encodeTokenSubstrate(USDT);
        substrates[3] = VeloraSubstrateLib.encodeTokenSubstrate(DAI);
        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(IporFusionMarkets.VELORA_SWAPPER, substrates);

        // when/then
        vm.expectRevert(VeloraSwapperFuse.VeloraSwapperFuseSlippageFail.selector);
        _enterWithPullRouter(USDC, WETH, 1000e6, 0, 10000);
    }

    // ============ Price Oracle Error Tests ============

    /// @notice An unset price oracle middleware in vault storage reverts the USD check
    function testShouldRevertWhenPriceOracleMiddlewareNotConfigured() public {
        // given
        _depositToVault(1000e6);
        _installPullRouter(0.33 ether);
        // PlasmaVaultStorageLib.PRICE_ORACLE_MIDDLEWARE slot
        vm.store(_plasmaVault, 0x0d761ae54d86fc3be4f1f2b44ade677efb1c84a85fc6bb1d087dc42f1e319a00, bytes32(0));

        // when/then
        vm.expectRevert(VeloraSwapperFuse.VeloraSwapperFuseInvalidPriceOracleMiddleware.selector);
        _enterWithPullRouter(USDC, WETH, 1000e6, 0, 10000);
    }

    /// @notice A zero tokenIn price from the oracle reverts with InvalidPrice(USDC)
    function testShouldRevertWhenTokenInPriceIsZero() public {
        // given
        _depositToVault(1000e6);
        _installPullRouter(0.33 ether);
        vm.mockCall(
            _priceOracle,
            abi.encodeWithSignature("getAssetPrice(address)", USDC),
            abi.encode(uint256(0), uint256(8))
        );

        // when/then
        vm.expectRevert(abi.encodeWithSelector(VeloraSwapperFuse.VeloraSwapperFuseInvalidPrice.selector, USDC));
        _enterWithPullRouter(USDC, WETH, 1000e6, 0, 10000);
    }

    /// @notice A zero tokenOut price from the oracle reverts with InvalidPrice(WETH)
    function testShouldRevertWhenTokenOutPriceIsZero() public {
        // given
        _depositToVault(1000e6);
        _installPullRouter(0.33 ether);
        vm.mockCall(
            _priceOracle,
            abi.encodeWithSignature("getAssetPrice(address)", WETH),
            abi.encode(uint256(0), uint256(8))
        );

        // when/then
        vm.expectRevert(abi.encodeWithSelector(VeloraSwapperFuse.VeloraSwapperFuseInvalidPrice.selector, WETH));
        _enterWithPullRouter(USDC, WETH, 1000e6, 0, 10000);
    }

    // ============ Edge Case Tests ============

    /// @notice tokenIn consumed but nothing received reverts (received == 0)
    function testShouldRevertWhenTokenOutBalanceDoesNotIncrease() public {
        // given
        _depositToVault(1000e6);
        _installPullRouter(0);

        // when/then
        vm.expectRevert(VeloraSwapperFuse.VeloraSwapperFuseSlippageFail.selector);
        _enterWithPullRouter(USDC, WETH, 1000e6, 0, 10000);
    }

    /// @notice A route that consumes nothing returns early: no revert, no balance change, no Enter event
    function testShouldReturnEarlyWhenNoTokensConsumed() public {
        // given
        _depositToVault(1000e6);
        _installPullRouter(0);
        uint256 vaultUsdcBefore = ERC20(USDC).balanceOf(_plasmaVault);
        uint256 vaultWethBefore = ERC20(WETH).balanceOf(_plasmaVault);

        // when
        vm.recordLogs();
        _enterWithPullRouter(USDC, WETH, 1000e6, 0, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // then
        assertEq(ERC20(USDC).balanceOf(_plasmaVault), vaultUsdcBefore, "USDC balance should be unchanged");
        assertEq(ERC20(WETH).balanceOf(_plasmaVault), vaultWethBefore, "WETH balance should be unchanged");
        assertEq(_countEnterEvents(logs), 0, "no Enter event on early return");
    }

    /// @notice Partial fill: the unused half of tokenIn comes back to the vault and the event reports the spent half
    function testShouldReturnUnusedTokenIn() public {
        // given - 50% of the USDC is pulled, 0.165 WETH is paid (~99.4% of the spent value)
        _depositToVault(1000e6);
        _installPullRouter(0.165 ether);

        // when
        vm.recordLogs();
        _enterWithPullRouter(USDC, WETH, 1000e6, 0, 5000);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // then
        assertEq(ERC20(USDC).balanceOf(_plasmaVault), 500e6, "Half of USDC should be returned");
        assertEq(ERC20(WETH).balanceOf(_plasmaVault), 0.165 ether, "WETH received");
        _assertSingleEnterEvent(logs, 500e6, 0.165 ether);
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
        bytes
            memory swapCallData = hex"e3ead59e000000000000000000000000000010036c0190e009a000d0fc3541100a07380a000000000000000000000000af88d065e77c8cc2239327c5edb3a432268e583100000000000000000000000082af49447d8a07e3bd95bd0d56f35241523fbab1000000000000000000000000000000000000000000000000000000003b9aca00000000000000000000000000000000000000000000000000048fe7c176ca7bf3000000000000000000000000000000000000000000000000049bb3cb2d003f2479c34107785249f98e91fe6c17d7e51a0000000000000000000000001945b1c6000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000160000000000000000000000000000000000000000000000000000000000000018000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000460000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000004600fc85a171bd0b53bf0bbace74f04b66170ae3eab0000040000240000ff000003000000000000000000000000000000000000000000000000000000000947c2d90000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000009ef4a86b0f299b28510fd37e6f1361ec0f769a65000000000000000000000000129b3d9a0a6e4beab88f5cb1e57995d72a6e24f10000000000000000000000006a000f20005980200259b80c5102003040001068000000000000000000000000af88d065e77c8cc2239327c5edb3a432268e583100000000000000000000000082af49447d8a07e3bd95bd0d56f35241523fbab1000000000000000000000000000000000000000000000000000000003b9aca00000000000000000000000000000000000000000000000000049bb3cb2d003f4c000000000000000000000000000000000000000000000000049bb3cb2d003f4c000000000000000000000000000000000000000000000000000000006971f53c0000000000000000000000000000000000000000000000003d21715ddb97be7e000000000000000000000000000000000000000000000000000000006971f50d000000000000000000000000000000000000000000000000000000006971f530000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000003222fefb98e3457f8dd227bed3ffba3300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002800000000000000000000000006044eef7179034319e2c8636ea885b37cbfa9aba000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000000041a495cb059dab7ef513e911008f3f36b17027afbc57059e51e25e402476cf45b2431fdaf0145a68f87779ff8a115c1f42a0bdd98ea5aeaa142982fccded5757151c00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004149ccb95af61543633df30c26dc138c2097f44cfe5b4f5fad9129a46a02cfac6345148d743d056b41e37c7ea810ff638e321a1aaf79294164108a91cd23a959571c00000000000000000000000000000000000000000000000000000000000000";

        VeloraSwapperEnterData memory enterData = VeloraSwapperEnterData({
            tokenIn: USDC,
            tokenOut: WETH,
            amountIn: depositAmount,
            minAmountOut: 0.3 ether, // Expect at least 0.3 WETH
            swapCallData: swapCallData,
            tokensToReturn: new address[](0)
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_veloraSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes,address[]))", enterData)
        );

        // when
        vm.recordLogs();
        PlasmaVault(_plasmaVault).execute(enterCalls);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // then
        uint256 vaultUsdcAfter = ERC20(USDC).balanceOf(_plasmaVault);
        uint256 vaultWethAfter = ERC20(WETH).balanceOf(_plasmaVault);

        // The emitted deltas equal the vault deltas
        _assertSingleEnterEvent(logs, vaultUsdcBefore - vaultUsdcAfter, vaultWethAfter - vaultWethBefore);

        // Verify USDC was consumed
        assertLt(vaultUsdcAfter, vaultUsdcBefore, "USDC should be consumed");
        assertEq(vaultUsdcBefore - vaultUsdcAfter, depositAmount, "All USDC should be swapped");

        // Verify WETH was received
        assertGt(vaultWethAfter, vaultWethBefore, "WETH should be received");
        assertGe(vaultWethAfter - vaultWethBefore, 0.3 ether, "Should receive at least 0.3 WETH");
    }

    // ============ tokensToReturn Tests (IL-7944) ============

    /// @notice Installs a mock Augustus v6.2 router at AUGUSTUS_V6_2 (via vm.etch, code only, no
    /// storage/immutables) whose fallback pulls the executor's full USDC allowance and pushes a fixed WETH
    /// amount (tokenOut) plus a fixed DAI amount (a third, unlisted-by-default output) to the caller (the real
    /// VeloraSwapExecutor). The fallback does not revert on empty calldata, matching Augustus behaviour.
    function _installMultiOutputMockRouter() private returns (uint256 wethOut, uint256 daiOut) {
        wethOut = 0.33 ether; // USDC=0.99979828 USD, WETH=3012.16598784 USD at fork block 423997794 (cast latestRoundData); ratio ~0.9942, above the 2% limit with margin
        daiOut = 10e18; // third output token, within s * USD(in) = 20 USDC bound

        MockAugustusMultiOutput mock = new MockAugustusMultiOutput();
        vm.etch(AUGUSTUS_V6_2, address(mock).code);
        deal(WETH, AUGUSTUS_V6_2, wethOut);
        deal(DAI, AUGUSTUS_V6_2, daiOut);
    }

    /// @notice IL-8033: installs a mock Augustus v6.2 router at AUGUSTUS_V6_2 (via vm.etch, code only,
    /// no storage/immutables) whose fallback pulls the executor's full USDC allowance and pushes a
    /// single wei of WETH back - a "dust" route far outside any sane slippage bound, used to prove
    /// that a slippage substrate of exactly 1e18 (100%) disables the USD check.
    function _installDustMockRouter() private returns (uint256 wethOut) {
        wethOut = 1; // 1 wei WETH, satisfies USD_out > 0 but fails any bound below 100%

        MockAugustusDust mock = new MockAugustusDust();
        vm.etch(AUGUSTUS_V6_2, address(mock).code);
        deal(WETH, AUGUSTUS_V6_2, wethOut);
    }

    /// @notice IL-8033: grants {Token USDC, Token WETH, slippageSubstrate_} to the Velora market,
    /// revoking any previously granted substrates (PlasmaVaultConfigLib.grantMarketSubstrates
    /// replaces the list). Takes a raw bytes32 so callers can grant a word the encoder would now
    /// reject, bypassing it entirely.
    function _grantSubstratesWithSlippage(bytes32 slippageSubstrate_) private {
        bytes32[] memory substrates = new bytes32[](3);
        substrates[0] = VeloraSubstrateLib.encodeTokenSubstrate(USDC);
        substrates[1] = VeloraSubstrateLib.encodeTokenSubstrate(WETH);
        substrates[2] = slippageSubstrate_;

        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(IporFusionMarkets.VELORA_SWAPPER, substrates);
    }

    /// @notice Test 6: a third output token (DAI) left in the executor by a multi-output route is swept to the
    /// vault when listed in tokensToReturn.
    /// Pre-fix (tokensToReturn loop removed from VeloraSwapExecutor.execute): executor holds 10e18 DAI, vault 0 -
    /// the first assertion below fails.
    function testShouldReturnTokensToReturnToVaultAfterSwap() public {
        uint256 depositAmount = 1000e6;
        _depositToVault(depositAmount);

        (, uint256 daiOut) = _installMultiOutputMockRouter();

        address[] memory tokensToReturn = new address[](1);
        tokensToReturn[0] = DAI;

        VeloraSwapperEnterData memory enterData = VeloraSwapperEnterData({
            tokenIn: USDC,
            tokenOut: WETH,
            amountIn: depositAmount,
            minAmountOut: 0,
            swapCallData: "",
            tokensToReturn: tokensToReturn
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_veloraSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes,address[]))", enterData)
        );

        PlasmaVault(_plasmaVault).execute(enterCalls);

        assertEq(ERC20(DAI).balanceOf(address(_veloraSwapExecutor)), 0, "Executor should have no DAI left");
        assertEq(ERC20(DAI).balanceOf(_plasmaVault), daiOut, "Vault should have received the DAI");
        assertGt(ERC20(WETH).balanceOf(_plasmaVault), 0, "Vault should have received WETH");
        assertEq(ERC20(USDC).balanceOf(_plasmaVault), 0, "Vault should have swapped all USDC");
    }

    /// @notice Test 7: a tokensToReturn entry that is not a granted token substrate reverts the whole enter.
    /// This is a validation-guard test, not evidence for the executor-side fix; covered separately by the
    /// fuse-side re-injection (removing the substrate check).
    function testShouldRevertWhenTokenToReturnNotGranted() public {
        uint256 depositAmount = 1000e6;
        _depositToVault(depositAmount);

        _installMultiOutputMockRouter();

        address unsupportedToken = 0x912CE59144191C1204E64559FE8253a0e49E6548; // ARB, not in _setupMarketConfigs()
        address[] memory tokensToReturn = new address[](1);
        tokensToReturn[0] = unsupportedToken;

        VeloraSwapperEnterData memory enterData = VeloraSwapperEnterData({
            tokenIn: USDC,
            tokenOut: WETH,
            amountIn: depositAmount,
            minAmountOut: 0,
            swapCallData: "",
            tokensToReturn: tokensToReturn
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_veloraSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes,address[]))", enterData)
        );

        vm.expectRevert(
            abi.encodeWithSelector(VeloraSwapperFuse.VeloraSwapperFuseUnsupportedAsset.selector, unsupportedToken)
        );
        PlasmaVault(_plasmaVault).execute(enterCalls);
    }

    // ============ Slippage Range Tests (IL-8033) ============

    /// @notice IL-8033 test 1: a slippage substrate above 1e18 (100%) is rejected at read time with a
    /// named error instead of bricking the market with an opaque Panic(0x11). Granted via the raw
    /// bytes32 word (encoder now rejects > 1e18, see part B) with a fair multi-output route so the
    /// pre-fix panic is not masked by an unrelated failure.
    /// Fails without the fix (Panic(0x11), selector mismatch), passes with it.
    function testShouldRevertWhenSlippageSubstrateAbove100PercentAtReadTime() public {
        uint256 depositAmount = 1000e6;
        _depositToVault(depositAmount);
        _installMultiOutputMockRouter();

        uint256 aboveOneHundredPercent = 1e18 + 1;
        bytes32 rawSlippageSubstrate = bytes32((uint256(2) << 248) | aboveOneHundredPercent);
        _grantSubstratesWithSlippage(rawSlippageSubstrate);

        uint256 vaultUsdcBefore = ERC20(USDC).balanceOf(_plasmaVault);

        VeloraSwapperEnterData memory enterData = VeloraSwapperEnterData({
            tokenIn: USDC,
            tokenOut: WETH,
            amountIn: depositAmount,
            minAmountOut: 0,
            swapCallData: "",
            tokensToReturn: new address[](0)
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_veloraSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes,address[]))", enterData)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                VeloraSwapperFuse.VeloraSwapperFuseSlippageExceeds100Percent.selector,
                aboveOneHundredPercent
            )
        );
        PlasmaVault(_plasmaVault).execute(enterCalls);

        assertEq(ERC20(USDC).balanceOf(_plasmaVault), vaultUsdcBefore, "Vault USDC balance must be unchanged");
    }

    /// @notice IL-8033 test 2: the read-time guard covers the whole malformed field, not one value -
    /// a raw bytes32 with the maximum uint248 payload (never reachable through the encoder any more)
    /// still reverts with the named error. Pins that the encoder is not the control.
    /// Fails without the fix (Panic(0x11)), passes with it.
    function testShouldRevertWhenRawSlippageSubstrateIsMaxUint248AtReadTime() public {
        uint256 depositAmount = 1000e6;
        _depositToVault(depositAmount);
        _installMultiOutputMockRouter();

        bytes32 rawSlippageSubstrate = bytes32((uint256(2) << 248) | uint256(type(uint248).max));
        _grantSubstratesWithSlippage(rawSlippageSubstrate);

        VeloraSwapperEnterData memory enterData = VeloraSwapperEnterData({
            tokenIn: USDC,
            tokenOut: WETH,
            amountIn: depositAmount,
            minAmountOut: 0,
            swapCallData: "",
            tokensToReturn: new address[](0)
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_veloraSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes,address[]))", enterData)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                VeloraSwapperFuse.VeloraSwapperFuseSlippageExceeds100Percent.selector,
                type(uint248).max
            )
        );
        PlasmaVault(_plasmaVault).execute(enterCalls);
    }

    /// @notice IL-8033 test 3 (positive control): a slippage substrate of exactly 1e18 (100%) is a
    /// valid configuration - "disable the USD bound" - and the swap succeeds even for a 1-wei route
    /// when minAmountOut is 0. Passes both before and after the fix; documents the strict `>` bound.
    function testShouldAcceptSlippageSubstrateOfExactly100Percent() public {
        uint256 depositAmount = 1000e6;
        _depositToVault(depositAmount);
        uint256 wethOut = _installDustMockRouter();

        _grantSubstratesWithSlippage(VeloraSubstrateLib.encodeSlippageSubstrate(1e18));

        uint256 vaultUsdcBefore = ERC20(USDC).balanceOf(_plasmaVault);
        uint256 vaultWethBefore = ERC20(WETH).balanceOf(_plasmaVault);

        VeloraSwapperEnterData memory enterData = VeloraSwapperEnterData({
            tokenIn: USDC,
            tokenOut: WETH,
            amountIn: depositAmount,
            minAmountOut: 0,
            swapCallData: "",
            tokensToReturn: new address[](0)
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_veloraSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes,address[]))", enterData)
        );

        PlasmaVault(_plasmaVault).execute(enterCalls);

        assertEq(vaultUsdcBefore - ERC20(USDC).balanceOf(_plasmaVault), depositAmount, "All USDC should be spent");
        assertEq(ERC20(WETH).balanceOf(_plasmaVault) - vaultWethBefore, wethOut, "Vault should receive dust WETH");
    }

    /// @notice IL-8033 test 4 (positive control): with the slippage substrate at exactly 1e18 the USD
    /// bound is disabled, so the ALPHA-supplied minAmountOut is the only remaining floor and still
    /// reverts a dust route. Passes both before and after the fix.
    function testShouldRevertWithMinAmountOutWhenSlippageSubstrateIs100Percent() public {
        uint256 depositAmount = 1000e6;
        _depositToVault(depositAmount);
        uint256 wethOut = _installDustMockRouter();

        _grantSubstratesWithSlippage(VeloraSubstrateLib.encodeSlippageSubstrate(1e18));

        VeloraSwapperEnterData memory enterData = VeloraSwapperEnterData({
            tokenIn: USDC,
            tokenOut: WETH,
            amountIn: depositAmount,
            minAmountOut: 0.3 ether,
            swapCallData: "",
            tokensToReturn: new address[](0)
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_veloraSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes,address[]))", enterData)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                VeloraSwapperFuse.VeloraSwapperFuseMinAmountOutNotReached.selector,
                0.3 ether,
                wethOut
            )
        );
        PlasmaVault(_plasmaVault).execute(enterCalls);
    }

    // ============ Helper Functions ============

    /// @notice Installs the calldata-driven pull router at AUGUSTUS_V6_2 (via vm.etch, code only) and funds it with
    /// {wethOut_} WETH
    function _installPullRouter(uint256 wethOut_) private {
        _routerWethOut = wethOut_;
        vm.etch(AUGUSTUS_V6_2, address(new VeloraMockRouterPull()).code);
        deal(WETH, AUGUSTUS_V6_2, wethOut_);
    }

    /// @notice Runs the production fuse through the vault; the swap calldata tells the router to pull
    /// {pullBps_}/10000 of the executor's allowance and to pay `_routerWethOut` WETH
    function _enterWithPullRouter(
        address tokenIn_,
        address tokenOut_,
        uint256 amountIn_,
        uint256 minAmountOut_,
        uint16 pullBps_
    ) private {
        VeloraSwapperEnterData memory enterData = VeloraSwapperEnterData({
            tokenIn: tokenIn_,
            tokenOut: tokenOut_,
            amountIn: amountIn_,
            minAmountOut: minAmountOut_,
            swapCallData: abi.encode(pullBps_, _routerWethOut),
            tokensToReturn: new address[](0)
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_veloraSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes,address[]))", enterData)
        );
        PlasmaVault(_plasmaVault).execute(enterCalls);
    }

    function _countEnterEvents(Vm.Log[] memory logs_) private view returns (uint256 count_) {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == _plasmaVault && logs_[i].topics[0] == VeloraSwapperFuseEnter.selector) {
                ++count_;
            }
        }
    }

    function _assertSingleEnterEvent(
        Vm.Log[] memory logs_,
        uint256 tokenInDelta_,
        uint256 tokenOutDelta_
    ) private view {
        assertEq(_countEnterEvents(logs_), 1, "exactly one Enter event");
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == _plasmaVault && logs_[i].topics[0] == VeloraSwapperFuseEnter.selector) {
                (uint256 tokenInDelta, uint256 tokenOutDelta) = abi.decode(logs_[i].data, (uint256, uint256));
                assertEq(tokenInDelta, tokenInDelta_, "event tokenInDelta");
                assertEq(tokenOutDelta, tokenOutDelta_, "event tokenOutDelta");
            }
        }
    }

    // ============ Net-delta measurement tests (IL-8767) ============

    /// @notice Installs a router mock whose behaviour is selected by the swap calldata (vm.etch copies code only,
    /// so no storage is used) and a permissionless claim distributor paying {rewardToken} to the vault.
    function _installNetDeltaRouter(address rewardToken_, uint256 rewardAmount_) private returns (address distributor) {
        VeloraMockRouterNetDelta mock = new VeloraMockRouterNetDelta();
        vm.etch(AUGUSTUS_V6_2, address(mock).code);
        distributor = address(new VeloraMockClaimDistributor(rewardToken_, rewardAmount_));
        deal(rewardToken_, distributor, rewardAmount_);
    }

    function _netDeltaEnter(uint8 mode_, address claimTarget_, uint256 wethOut_) private {
        bytes memory swapCallData = abi.encode(mode_, address(0xA1FA), claimTarget_, _plasmaVault, wethOut_);
        VeloraSwapperEnterData memory enterData = VeloraSwapperEnterData({
            tokenIn: USDC,
            tokenOut: WETH,
            amountIn: 1000e6,
            minAmountOut: 0,
            swapCallData: swapCallData,
            tokensToReturn: new address[](0)
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_veloraSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes,address[]))", enterData)
        );
        PlasmaVault(_plasmaVault).execute(enterCalls);
    }

    /// @notice (a) The route sends the vault's tokenIn to a third party and a permissionless claim refills the vault
    /// with tokenIn: the vault balance is unchanged, but the executor returned nothing, so the enter must revert.
    /// Pre-fix (vault balance deltas): early return, the theft succeeds.
    function testShouldRevertWhenClaimRefillsTokenInAfterTheft() public {
        _depositToVault(1000e6);
        address distributor = _installNetDeltaRouter(USDC, 1000e6);

        vm.expectRevert(VeloraSwapperFuse.VeloraSwapperFuseSlippageFail.selector);
        _netDeltaEnter(1, distributor, 0);

        assertEq(ERC20(USDC).balanceOf(address(0xA1FA)), 0, "thief got nothing");
    }

    /// @notice (b) Mirror: the route steals tokenIn while a claim pays the vault tokenOut; the claim must not be
    /// counted as swap output. Pre-fix: tokenOutDelta = claim amount passes minAmountOut and the USD check.
    function testShouldRevertWhenClaimPaysTokenOutAfterTheft() public {
        _depositToVault(1000e6);
        address distributor = _installNetDeltaRouter(WETH, 0.33 ether);

        vm.expectRevert(VeloraSwapperFuse.VeloraSwapperFuseSlippageFail.selector);
        _netDeltaEnter(2, distributor, 0);

        assertEq(ERC20(USDC).balanceOf(address(0xA1FA)), 0, "thief got nothing");
        assertEq(ERC20(WETH).balanceOf(_plasmaVault), 0, "claim rolled back");
    }

    /// @notice (c) Control: an honest swap passes and the emitted deltas are the executor-measured spent/received.
    function testShouldEmitExecutorDeltasForHonestSwap() public {
        _depositToVault(1000e6);
        // unrelated claim paying the vault tokenIn in the same call must not change the reported deltas
        address distributor = _installNetDeltaRouter(USDC, 50e6);
        uint256 wethOut = 0.33 ether;
        deal(WETH, AUGUSTUS_V6_2, wethOut);

        vm.expectEmit(false, false, false, true, _plasmaVault);
        emit VeloraSwapperFuseEnter(address(_veloraSwapperFuse), USDC, WETH, 1000e6, wethOut);
        _netDeltaEnter(0, distributor, wethOut);

        assertEq(ERC20(WETH).balanceOf(_plasmaVault), wethOut, "tokenOut received");
        assertEq(ERC20(USDC).balanceOf(_plasmaVault), 50e6, "tokenIn spent, claim kept");
    }

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

/// @notice Mock Augustus v6.2 fallback that simulates a multi-output swap: pulls the caller's (the real
/// VeloraSwapExecutor's) full USDC allowance and pushes fixed WETH and DAI amounts back to the caller. Installed
/// via `vm.etch` at the real AUGUSTUS_V6_2 address so the real VeloraSwapExecutor bytecode runs unmodified.
/// Uses only compile-time constants (no storage, no constructor-set state), so `vm.etch` - which copies runtime
/// code only - is safe. Does not revert on empty calldata, matching Augustus v6.2 behaviour.
contract MockAugustusMultiOutput {
    address private constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address private constant DAI = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;

    uint256 private constant WETH_OUT = 0.33 ether;
    uint256 private constant DAI_OUT = 10e18;

    fallback() external {
        uint256 allowance = ERC20(USDC).allowance(msg.sender, address(this));
        if (allowance > 0) {
            ERC20(USDC).transferFrom(msg.sender, address(this), allowance);
        }
        ERC20(WETH).transfer(msg.sender, WETH_OUT);
        ERC20(DAI).transfer(msg.sender, DAI_OUT);
    }
}

/// @notice IL-8033: mock Augustus v6.2 fallback that simulates a "dust" swap: pulls the caller's (the
/// real VeloraSwapExecutor's) full USDC allowance and pushes back a single wei of WETH. Installed via
/// `vm.etch` at the real AUGUSTUS_V6_2 address so the real VeloraSwapExecutor bytecode runs
/// unmodified. Uses only compile-time constants (no storage, no constructor-set state), so `vm.etch`
/// - which copies runtime code only - is safe.
contract MockAugustusDust {
    address private constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    uint256 private constant WETH_OUT = 1;

    fallback() external {
        uint256 allowance = ERC20(USDC).allowance(msg.sender, address(this));
        if (allowance > 0) {
            ERC20(USDC).transferFrom(msg.sender, address(this), allowance);
        }
        ERC20(WETH).transfer(msg.sender, WETH_OUT);
    }
}

/// @notice IL-8767 router mock selected by calldata `abi.encode(mode, thief, claimTarget, vault, wethOut)`.
/// mode 0: honest swap (pull the USDC allowance, pay `wethOut` WETH to the caller, then claim for the vault);
/// mode 1/2: pull the USDC allowance to `thief`, then `claimTarget.claim(vault)` (refills the vault with USDC / WETH).
/// Only constants are used, so `vm.etch` of the runtime code is safe.
contract VeloraMockRouterNetDelta {
    address private constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    fallback() external {
        (uint8 mode, address thief, address claimTarget, address vault, uint256 wethOut) = abi.decode(
            msg.data,
            (uint8, address, address, address, uint256)
        );
        uint256 allowance = ERC20(USDC).allowance(msg.sender, address(this));
        if (mode == 0) {
            ERC20(USDC).transferFrom(msg.sender, address(this), allowance);
            ERC20(WETH).transfer(msg.sender, wethOut);
        } else {
            ERC20(USDC).transferFrom(msg.sender, thief, allowance);
        }
        VeloraMockClaimDistributor(claimTarget).claim(vault);
    }
}

/// @notice Permissionless reward distributor (anyone may claim on behalf of an account, payout goes to the account).
contract VeloraMockClaimDistributor {
    address public immutable TOKEN;
    uint256 public immutable AMOUNT;

    constructor(address token_, uint256 amount_) {
        TOKEN = token_;
        AMOUNT = amount_;
    }

    function claim(address account_) external {
        ERC20(TOKEN).transfer(account_, AMOUNT);
    }
}

/// @notice Helper contract to test library function reverts
/// @dev Library functions are inlined by the compiler, so we need a wrapper to test reverts
contract VeloraSlippageEncoderHelper {
    function encodeSlippage(uint256 slippageWad_) external pure returns (bytes32) {
        return VeloraSubstrateLib.encodeSlippageSubstrate(slippageWad_);
    }
}

/// @notice Router mock whose behaviour is selected by the swap calldata `abi.encode(uint16 pullBps, uint256 wethOut)`:
/// pulls `allowance * pullBps / 10000` USDC from the caller (the real VeloraSwapExecutor) and pays `wethOut` WETH to
/// it. Installed via `vm.etch` at the real AUGUSTUS_V6_2 address (code only; constants only, no storage), so the real
/// executor and the production fuse run unmodified.
contract VeloraMockRouterPull {
    address private constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    fallback() external {
        (uint16 pullBps, uint256 wethOut) = abi.decode(msg.data, (uint16, uint256));
        uint256 pull = (ERC20(USDC).allowance(msg.sender, address(this)) * pullBps) / 10000;
        if (pull > 0) {
            ERC20(USDC).transferFrom(msg.sender, address(this), pull);
        }
        if (wethOut > 0) {
            ERC20(WETH).transfer(msg.sender, wethOut);
        }
    }
}
