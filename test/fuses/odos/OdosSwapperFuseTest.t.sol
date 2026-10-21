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
    // Chainlink at this block: USDC = 0.99975919 USD, WETH = 3331.66731181 USD
    uint256 private constant FORK_BLOCK_NUMBER = 421193396;

    // ============ State Variables ============

    address private _plasmaVault;
    address private _withdrawManager;
    address private _priceOracle;
    address private _accessManager;

    OdosSwapperFuse private _odosSwapperFuse;
    OdosSwapExecutor private _odosSwapExecutor;

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
                "TEST ODOS PLASMA VAULT",
                "pvUSDC-ODOS",
                USDC,
                _priceOracle,
                _setupFeeConfig(),
                _accessManager,
                address(new PlasmaVaultBase()),
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
            swapCallData: "",
            tokensToReturn: new address[](0)
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_odosSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes,address[]))", enterData)
        );

        // when/then
        vm.expectRevert(
            abi.encodeWithSelector(OdosSwapperFuse.OdosSwapperFuseUnsupportedAsset.selector, unsupportedToken)
        );
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
            swapCallData: "",
            tokensToReturn: new address[](0)
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_odosSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes,address[]))", enterData)
        );

        // when/then
        vm.expectRevert(
            abi.encodeWithSelector(OdosSwapperFuse.OdosSwapperFuseUnsupportedAsset.selector, unsupportedToken)
        );
        PlasmaVault(_plasmaVault).execute(enterCalls);
    }

    function testShouldRevertWhenZeroAmountIn() public {
        // given
        OdosSwapperEnterData memory enterData = OdosSwapperEnterData({
            tokenIn: USDC,
            tokenOut: WETH,
            amountIn: 0,
            minAmountOut: 0,
            swapCallData: "",
            tokensToReturn: new address[](0)
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_odosSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes,address[]))", enterData)
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
        bytes
            memory odosSwapCallData = hex"83bd37f90001af88d065e77c8cc2239327c5edb3a432268e5831000182af49447d8a07e3bd95bd0d56f35241523fbab1043b9aca0008042954e8079ec480028f5c000103222a2b261a12091bBE271e763A7E26b64E25e20000000000000000000000000003010203004801010102ff00000000000000000000000000000000000000000000af88d065e77c8cc2239327c5edb3a432268e583182af49447d8a07e3bd95bd0d56f35241523fbab1000000000000000000000000000000000000000000000000";

        // minAmountOut = expectedOut * (1 - slippage) = 299864205733840000 * 0.99 ≈ 296865563676501600
        uint256 minAmountOut = 296865563676501600;

        OdosSwapperEnterData memory enterData = OdosSwapperEnterData({
            tokenIn: USDC,
            tokenOut: WETH,
            amountIn: depositAmount,
            minAmountOut: minAmountOut,
            swapCallData: odosSwapCallData,
            tokensToReturn: new address[](0)
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_odosSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes,address[]))", enterData)
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
        bytes
            memory odosSwapCallData = hex"83bd37f90001af88d065e77c8cc2239327c5edb3a432268e5831000182af49447d8a07e3bd95bd0d56f35241523fbab1043b9aca0008042954e8079ec480028f5c000103222a2b261a12091bBE271e763A7E26b64E25e20000000000000000000000000003010203004801010102ff00000000000000000000000000000000000000000000af88d065e77c8cc2239327c5edb3a432268e583182af49447d8a07e3bd95bd0d56f35241523fbab1000000000000000000000000000000000000000000000000";

        // Set minAmountOut higher than what the swap will return (~0.2998 WETH)
        // We expect ~299864205733840000 but require 1 WETH (1e18) which is impossible
        uint256 unrealisticMinAmountOut = 1 ether;

        OdosSwapperEnterData memory enterData = OdosSwapperEnterData({
            tokenIn: USDC,
            tokenOut: WETH,
            amountIn: depositAmount,
            minAmountOut: unrealisticMinAmountOut,
            swapCallData: odosSwapCallData,
            tokensToReturn: new address[](0)
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_odosSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes,address[]))", enterData)
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
        bytes
            memory odosSwapCallData = hex"83bd37f90001af88d065e77c8cc2239327c5edb3a432268e5831000182af49447d8a07e3bd95bd0d56f35241523fbab1043b9aca0008042954e8079ec480028f5c000103222a2b261a12091bBE271e763A7E26b64E25e20000000000000000000000000003010203004801010102ff00000000000000000000000000000000000000000000af88d065e77c8cc2239327c5edb3a432268e583182af49447d8a07e3bd95bd0d56f35241523fbab1000000000000000000000000000000000000000000000000";

        OdosSwapperEnterData memory enterData = OdosSwapperEnterData({
            tokenIn: USDC,
            tokenOut: WETH,
            amountIn: depositAmount,
            minAmountOut: 0,
            swapCallData: odosSwapCallData,
            tokensToReturn: new address[](0)
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_odosSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes,address[]))", enterData)
        );

        // when/then - expect event emission including the deltas (1000 USDC spent, the quoted WETH received)
        vm.expectEmit(true, true, true, true, _plasmaVault);
        emit OdosSwapperFuseEnter(address(_odosSwapperFuse), USDC, WETH, 1000e6, 299864205733840000);

        PlasmaVault(_plasmaVault).execute(enterCalls);
    }

    // ============ Edge Case Tests ============

    /// @notice tokenIn consumed but nothing received reverts (received == 0)
    function testShouldRevertWhenTokenOutBalanceDoesNotIncrease() public {
        // given
        _depositToVault(1000e6);
        _installPullRouter(0);

        // when/then
        vm.expectRevert(OdosSwapperFuse.OdosSwapperFuseSlippageFail.selector);
        _enterWithPullRouter(10000, 0);
    }

    /// @notice Swap output below minAmountOut reverts with the expected/actual pair
    function testShouldRevertWhenMinAmountOutNotReachedByRouter() public {
        // given
        _depositToVault(1000e6);
        _installPullRouter(0.1 ether);

        // when/then
        vm.expectRevert(
            abi.encodeWithSelector(OdosSwapperFuse.OdosSwapperFuseMinAmountOutNotReached.selector, 1 ether, 0.1 ether)
        );
        _enterWithPullRouter(10000, 1 ether);
    }

    /// @notice Output worth ~45% of the input fails the USD slippage quotient check
    function testShouldRevertWhenSlippageExceeded() public {
        // given
        _depositToVault(1000e6);
        _installPullRouter(0.15 ether);

        // when/then
        vm.expectRevert(OdosSwapperFuse.OdosSwapperFuseSlippageFail.selector);
        _enterWithPullRouter(10000, 0);
    }

    /// @notice An unset price oracle middleware in vault storage reverts the USD check
    function testShouldRevertWhenPriceOracleMiddlewareNotConfigured() public {
        // given
        _depositToVault(1000e6);
        _installPullRouter(0.2998 ether);
        // PlasmaVaultStorageLib.PRICE_ORACLE_MIDDLEWARE slot
        vm.store(_plasmaVault, 0x0d761ae54d86fc3be4f1f2b44ade677efb1c84a85fc6bb1d087dc42f1e319a00, bytes32(0));

        // when/then
        vm.expectRevert(OdosSwapperFuse.OdosSwapperFuseInvalidPriceOracleMiddleware.selector);
        _enterWithPullRouter(10000, 0);
    }

    /// @notice A zero tokenIn price from the oracle reverts with InvalidPrice(USDC)
    function testShouldRevertWhenTokenInPriceIsZero() public {
        // given
        _depositToVault(1000e6);
        _installPullRouter(0.2998 ether);
        vm.mockCall(
            _priceOracle,
            abi.encodeWithSignature("getAssetPrice(address)", USDC),
            abi.encode(uint256(0), uint256(8))
        );

        // when/then
        vm.expectRevert(abi.encodeWithSelector(OdosSwapperFuse.OdosSwapperFuseInvalidPrice.selector, USDC));
        _enterWithPullRouter(10000, 0);
    }

    /// @notice A zero tokenOut price from the oracle reverts with InvalidPrice(WETH)
    function testShouldRevertWhenTokenOutPriceIsZero() public {
        // given
        _depositToVault(1000e6);
        _installPullRouter(0.2998 ether);
        vm.mockCall(
            _priceOracle,
            abi.encodeWithSignature("getAssetPrice(address)", WETH),
            abi.encode(uint256(0), uint256(8))
        );

        // when/then
        vm.expectRevert(abi.encodeWithSelector(OdosSwapperFuse.OdosSwapperFuseInvalidPrice.selector, WETH));
        _enterWithPullRouter(10000, 0);
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
        _enterWithPullRouter(0, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // then
        assertEq(ERC20(USDC).balanceOf(_plasmaVault), vaultUsdcBefore, "USDC balance should be unchanged");
        assertEq(ERC20(WETH).balanceOf(_plasmaVault), vaultWethBefore, "WETH balance should be unchanged");
        assertEq(_countEnterEvents(logs), 0, "no Enter event on early return");
    }

    /// @notice Partial fill: the unused half of tokenIn comes back to the vault and the event reports the spent half
    function testShouldReturnUnusedTokenIn() public {
        // given - 50% of the USDC is pulled, 0.15 WETH is paid (~99.97% of the spent value)
        _depositToVault(1000e6);
        _installPullRouter(0.15 ether);

        // when
        vm.recordLogs();
        _enterWithPullRouter(5000, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // then
        assertEq(ERC20(USDC).balanceOf(_plasmaVault), 500e6, "Half of USDC should be returned");
        assertEq(ERC20(WETH).balanceOf(_plasmaVault), 0.15 ether, "WETH received");
        _assertSingleEnterEvent(logs, 500e6, 0.15 ether);
    }

    /// @notice The slippage substrate (2%) is honoured: an output ~98.5% of the input value passes at 2% and
    /// fails with the 1% default once the slippage substrate is removed
    function testShouldUseCustomSlippageWhenConfigured() public {
        // given - USDC=0.99975919 USD, WETH=3331.66731181 USD at the fork block: 0.2956 WETH is ~98.51% of 1000 USDC
        uint256 wethOut = 0.2956 ether;
        _depositToVault(2000e6);
        _installPullRouter(wethOut);

        // when - 2% slippage substrate from _setupMarketConfigs
        _enterWithPullRouter(10000, 0);

        // then
        assertEq(ERC20(WETH).balanceOf(_plasmaVault), wethOut, "swap passes at 2%");

        // given - same route again, slippage substrate removed (default 1% applies)
        _installPullRouter(wethOut);
        bytes32[] memory substrates = new bytes32[](4);
        substrates[0] = OdosSubstrateLib.encodeTokenSubstrate(USDC);
        substrates[1] = OdosSubstrateLib.encodeTokenSubstrate(WETH);
        substrates[2] = OdosSubstrateLib.encodeTokenSubstrate(USDT);
        substrates[3] = OdosSubstrateLib.encodeTokenSubstrate(DAI);
        IPlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(IporFusionMarkets.ODOS_SWAPPER, substrates);

        // when/then
        vm.expectRevert(OdosSwapperFuse.OdosSwapperFuseSlippageFail.selector);
        _enterWithPullRouter(10000, 0);
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
        _odosSwapExecutor.execute(USDC, WETH, amount, "", new address[](0));

        // then - tokens are sent to the attacker (msg.sender)
        uint256 attackerUsdcAfter = ERC20(USDC).balanceOf(attacker);
        uint256 executorUsdcAfter = ERC20(USDC).balanceOf(address(_odosSwapExecutor));

        // This demonstrates the security concern: tokens sent to executor by mistake
        // can be stolen by anyone who calls execute()
        assertEq(attackerUsdcAfter, attackerUsdcBefore + amount, "Attacker should have received all USDC");
        assertEq(executorUsdcAfter, 0, "Executor should have no USDC left");

        // and - the same vector applies to a token left over from a prior swap that was not listed in
        // tokensToReturn: DAI sitting in the executor (e.g. stranded by a prior multi-output swap) can be
        // taken by anyone via execute(DAI, DAI, 0, "", []), motivating listing every possible output token.
        uint256 daiAmount = 10e18;
        deal(DAI, address(_odosSwapExecutor), daiAmount);
        uint256 attackerDaiBefore = ERC20(DAI).balanceOf(attacker);

        vm.prank(attacker);
        _odosSwapExecutor.execute(DAI, DAI, 0, "", new address[](0));

        assertEq(
            ERC20(DAI).balanceOf(attacker),
            attackerDaiBefore + daiAmount,
            "Attacker should have received the stranded DAI"
        );
        assertEq(ERC20(DAI).balanceOf(address(_odosSwapExecutor)), 0, "Executor should have no DAI left");
    }

    /// @notice Test LOW PRIORITY: Slippage overflow validation at boundary
    /// @dev Covers OdosSubstrateLib.sol line 37-38: revert OdosSubstrateLibSlippageOverflow
    function testShouldRevertWhenSlippageOverflowsUint248() public {
        // given - value just above uint248 max should overflow
        uint256 overflowValue = uint256(type(uint248).max) + 1;

        // when/then - use helper contract to test revert (library functions are inlined)
        SlippageEncoderHelper helper = new SlippageEncoderHelper();
        vm.expectRevert(
            abi.encodeWithSelector(OdosSubstrateLib.OdosSubstrateLibSlippageOverflow.selector, overflowValue)
        );
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

    // ============ tokensToReturn Tests (IL-7944) ============

    /// @notice Installs a mock Odos router at ODOS_ROUTER_V3 (via vm.etch, code only, no storage/immutables) whose
    /// fallback pulls the executor's full USDC allowance and pushes a fixed WETH amount (tokenOut) plus a fixed
    /// DAI amount (a third, unlisted-by-default output) to the caller (the real OdosSwapExecutor).
    function _installMultiOutputMockRouter() private returns (uint256 wethOut, uint256 daiOut) {
        wethOut = 0.297 ether; // ~0.99 USD ratio against 1000 USDC at this fork's Chainlink prices, margin over the 2% limit
        daiOut = 10e18; // third output token, within s * USD(in) = 20 USDC bound

        MockOdosRouterMultiOutput mock = new MockOdosRouterMultiOutput();
        vm.etch(ODOS_ROUTER_V3, address(mock).code);
        deal(WETH, ODOS_ROUTER_V3, wethOut);
        deal(DAI, ODOS_ROUTER_V3, daiOut);
    }

    /// @notice Test 1: a third output token (DAI) left in the executor by a multi-output route is swept to the
    /// vault when listed in tokensToReturn.
    /// Pre-fix (tokensToReturn loop removed from OdosSwapExecutor.execute): executor holds 10e18 DAI, vault 0 -
    /// the first assertion below fails.
    function testShouldReturnTokensToReturnToVaultAfterSwap() public {
        uint256 depositAmount = 1000e6;
        _depositToVault(depositAmount);

        (, uint256 daiOut) = _installMultiOutputMockRouter();

        address[] memory tokensToReturn = new address[](1);
        tokensToReturn[0] = DAI;

        OdosSwapperEnterData memory enterData = OdosSwapperEnterData({
            tokenIn: USDC,
            tokenOut: WETH,
            amountIn: depositAmount,
            minAmountOut: 0,
            swapCallData: "",
            tokensToReturn: tokensToReturn
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_odosSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes,address[]))", enterData)
        );

        PlasmaVault(_plasmaVault).execute(enterCalls);

        assertEq(ERC20(DAI).balanceOf(address(_odosSwapExecutor)), 0, "Executor should have no DAI left");
        assertEq(ERC20(DAI).balanceOf(_plasmaVault), daiOut, "Vault should have received the DAI");
        assertGt(ERC20(WETH).balanceOf(_plasmaVault), 0, "Vault should have received WETH");
        assertEq(ERC20(USDC).balanceOf(_plasmaVault), 0, "Vault should have swapped all USDC");
    }

    /// @notice Test 2 (control): same route, tokensToReturn empty. DAI stays in the executor before and after the
    /// fix and is not counted in totalAssets(); pins the documented residual behaviour. Not regression evidence.
    function testShouldLeaveThirdTokenInExecutorWhenNotListed() public {
        uint256 depositAmount = 1000e6;
        _depositToVault(depositAmount);

        (, uint256 daiOut) = _installMultiOutputMockRouter();

        OdosSwapperEnterData memory enterData = OdosSwapperEnterData({
            tokenIn: USDC,
            tokenOut: WETH,
            amountIn: depositAmount,
            minAmountOut: 0,
            swapCallData: "",
            tokensToReturn: new address[](0)
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_odosSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes,address[]))", enterData)
        );

        PlasmaVault(_plasmaVault).execute(enterCalls);

        assertEq(ERC20(DAI).balanceOf(address(_odosSwapExecutor)), daiOut, "DAI should remain stranded in executor");
        assertEq(ERC20(DAI).balanceOf(_plasmaVault), 0, "Vault should not have received the DAI");
        // The stranded DAI is not counted anywhere: market ODOS_SWAPPER uses ZeroBalanceFuse and no market
        // carries a placeholder balance for it (assessment IL-7944 section 2.4).
        assertGt(ERC20(WETH).balanceOf(_plasmaVault), 0, "Vault should still have received WETH from the swap");
    }

    /// @notice Test 3: tokenIn/tokenOut duplicated in tokensToReturn (and DAI listed twice) are no-ops; no revert,
    /// and DAI still ends up swept exactly once. Pre-fix: DAI stranded, first DAI assertion fails.
    function testShouldSkipTokenInTokenOutAndDuplicatesInTokensToReturn() public {
        uint256 depositAmount = 1000e6;
        _depositToVault(depositAmount);

        (, uint256 daiOut) = _installMultiOutputMockRouter();

        address[] memory tokensToReturn = new address[](4);
        tokensToReturn[0] = USDC;
        tokensToReturn[1] = WETH;
        tokensToReturn[2] = DAI;
        tokensToReturn[3] = DAI;

        OdosSwapperEnterData memory enterData = OdosSwapperEnterData({
            tokenIn: USDC,
            tokenOut: WETH,
            amountIn: depositAmount,
            minAmountOut: 0,
            swapCallData: "",
            tokensToReturn: tokensToReturn
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_odosSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes,address[]))", enterData)
        );

        PlasmaVault(_plasmaVault).execute(enterCalls);

        assertEq(ERC20(USDC).balanceOf(address(_odosSwapExecutor)), 0, "Executor should have no USDC left");
        assertEq(ERC20(WETH).balanceOf(address(_odosSwapExecutor)), 0, "Executor should have no WETH left");
        assertEq(ERC20(DAI).balanceOf(address(_odosSwapExecutor)), 0, "Executor should have no DAI left");
        assertEq(ERC20(DAI).balanceOf(_plasmaVault), daiOut, "Vault should have received the DAI exactly once");
    }

    /// @notice Test 4: a tokensToReturn entry that is not a granted token substrate reverts the whole enter.
    /// This is a validation-guard test, not evidence for the executor-side fix; covered separately by the
    /// fuse-side re-injection (removing the substrate check).
    function testShouldRevertWhenTokenToReturnNotGranted() public {
        uint256 depositAmount = 1000e6;
        _depositToVault(depositAmount);

        _installMultiOutputMockRouter();

        address[] memory tokensToReturn = new address[](1);
        tokensToReturn[0] = ARB; // not granted per _setupMarketConfigs()

        OdosSwapperEnterData memory enterData = OdosSwapperEnterData({
            tokenIn: USDC,
            tokenOut: WETH,
            amountIn: depositAmount,
            minAmountOut: 0,
            swapCallData: "",
            tokensToReturn: tokensToReturn
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_odosSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes,address[]))", enterData)
        );

        vm.expectRevert(abi.encodeWithSelector(OdosSwapperFuse.OdosSwapperFuseUnsupportedAsset.selector, ARB));
        PlasmaVault(_plasmaVault).execute(enterCalls);
    }

    // ============ Slippage Range Tests (IL-8033) ============

    /// @notice IL-8033 test 8: a slippage substrate above 1e18 (100%) is rejected at read time with a
    /// named error instead of the opaque Panic(0x11) that OdosSwapperFuse._getSlippageLimit produced
    /// before the fix (the Odos encoder still accepts the value on purpose - it is not the control).
    /// Fails without part C (Panic(0x11) at the checked subtraction), passes with it.
    function testShouldRevertWhenSlippageSubstrateAbove100PercentAtReadTime() public {
        uint256 depositAmount = 1000e6;
        _depositToVault(depositAmount);
        _installMultiOutputMockRouter();

        uint256 aboveOneHundredPercent = 1e18 + 1;
        _grantSubstratesWithSlippage(OdosSubstrateLib.encodeSlippageSubstrate(aboveOneHundredPercent));

        OdosSwapperEnterData memory enterData = OdosSwapperEnterData({
            tokenIn: USDC,
            tokenOut: WETH,
            amountIn: depositAmount,
            minAmountOut: 0,
            swapCallData: "",
            tokensToReturn: new address[](0)
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_odosSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes,address[]))", enterData)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                OdosSwapperFuse.OdosSwapperFuseSlippageExceeds100Percent.selector,
                aboveOneHundredPercent
            )
        );
        PlasmaVault(_plasmaVault).execute(enterCalls);
    }

    // ============ Helper Functions ============

    /// @notice Installs the calldata-driven pull router at ODOS_ROUTER_V3 (via vm.etch, code only) and funds it with
    /// {wethOut_} WETH
    function _installPullRouter(uint256 wethOut_) private {
        _routerWethOut = wethOut_;
        vm.etch(ODOS_ROUTER_V3, address(new OdosMockRouterPull()).code);
        deal(WETH, ODOS_ROUTER_V3, wethOut_);
    }

    /// @notice Runs the production fuse through the vault with 1000 USDC; the swap calldata tells the router to pull
    /// {pullBps_}/10000 of the executor's allowance and to pay `_routerWethOut` WETH
    function _enterWithPullRouter(uint16 pullBps_, uint256 minAmountOut_) private {
        OdosSwapperEnterData memory enterData = OdosSwapperEnterData({
            tokenIn: USDC,
            tokenOut: WETH,
            amountIn: 1000e6,
            minAmountOut: minAmountOut_,
            swapCallData: abi.encode(pullBps_, _routerWethOut),
            tokensToReturn: new address[](0)
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_odosSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes,address[]))", enterData)
        );
        PlasmaVault(_plasmaVault).execute(enterCalls);
    }

    function _countEnterEvents(Vm.Log[] memory logs_) private view returns (uint256 count_) {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == _plasmaVault && logs_[i].topics[0] == OdosSwapperFuseEnter.selector) {
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
            if (logs_[i].emitter == _plasmaVault && logs_[i].topics[0] == OdosSwapperFuseEnter.selector) {
                (uint256 tokenInDelta, uint256 tokenOutDelta) = abi.decode(logs_[i].data, (uint256, uint256));
                assertEq(tokenInDelta, tokenInDelta_, "event tokenInDelta");
                assertEq(tokenOutDelta, tokenOutDelta_, "event tokenOutDelta");
            }
        }
    }

    /// @notice IL-8033: grants {Token USDC, Token WETH, Token USDT, Token DAI, slippageSubstrate_} to
    /// the Odos market, revoking any previously granted substrates (grantMarketSubstrates replaces
    /// the list).
    function _grantSubstratesWithSlippage(bytes32 slippageSubstrate_) private {
        bytes32[] memory substrates = new bytes32[](5);
        substrates[0] = OdosSubstrateLib.encodeTokenSubstrate(USDC);
        substrates[1] = OdosSubstrateLib.encodeTokenSubstrate(WETH);
        substrates[2] = OdosSubstrateLib.encodeTokenSubstrate(USDT);
        substrates[3] = OdosSubstrateLib.encodeTokenSubstrate(DAI);
        substrates[4] = slippageSubstrate_;

        IPlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(IporFusionMarkets.ODOS_SWAPPER, substrates);
    }

    // ============ Net-delta measurement tests (IL-8767) ============

    /// @notice Installs a router mock whose behaviour is selected by the swap calldata (vm.etch copies code only,
    /// so no storage is used) and a permissionless claim distributor paying {rewardToken} to the vault.
    function _installNetDeltaRouter(address rewardToken_, uint256 rewardAmount_) private returns (address distributor) {
        OdosMockRouterNetDelta mock = new OdosMockRouterNetDelta();
        vm.etch(ODOS_ROUTER_V3, address(mock).code);
        distributor = address(new OdosMockClaimDistributor(rewardToken_, rewardAmount_));
        deal(rewardToken_, distributor, rewardAmount_);
    }

    function _netDeltaEnter(uint8 mode_, address claimTarget_, uint256 wethOut_) private {
        bytes memory swapCallData = abi.encode(mode_, address(0xA1FA), claimTarget_, _plasmaVault, wethOut_);
        OdosSwapperEnterData memory enterData = OdosSwapperEnterData({
            tokenIn: USDC,
            tokenOut: WETH,
            amountIn: 1000e6,
            minAmountOut: 0,
            swapCallData: swapCallData,
            tokensToReturn: new address[](0)
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_odosSwapperFuse),
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

        vm.expectRevert(OdosSwapperFuse.OdosSwapperFuseSlippageFail.selector);
        _netDeltaEnter(1, distributor, 0);

        assertEq(ERC20(USDC).balanceOf(address(0xA1FA)), 0, "thief got nothing");
    }

    /// @notice (b) Mirror: the route steals tokenIn while a claim pays the vault tokenOut; the claim must not be
    /// counted as swap output. Pre-fix: tokenOutDelta = claim amount passes minAmountOut and the USD check.
    function testShouldRevertWhenClaimPaysTokenOutAfterTheft() public {
        _depositToVault(1000e6);
        address distributor = _installNetDeltaRouter(WETH, 0.33 ether);

        vm.expectRevert(OdosSwapperFuse.OdosSwapperFuseSlippageFail.selector);
        _netDeltaEnter(2, distributor, 0);

        assertEq(ERC20(USDC).balanceOf(address(0xA1FA)), 0, "thief got nothing");
        assertEq(ERC20(WETH).balanceOf(_plasmaVault), 0, "claim rolled back");
    }

    /// @notice (c) Control: an honest swap passes and the emitted deltas are the executor-measured spent/received.
    function testShouldEmitExecutorDeltasForHonestSwap() public {
        _depositToVault(1000e6);
        // unrelated claim paying the vault tokenIn in the same call must not change the reported deltas
        address distributor = _installNetDeltaRouter(USDC, 50e6);
        uint256 wethOut = 0.297 ether;
        deal(WETH, ODOS_ROUTER_V3, wethOut);

        vm.expectEmit(false, false, false, true, _plasmaVault);
        emit OdosSwapperFuseEnter(address(_odosSwapperFuse), USDC, WETH, 1000e6, wethOut);
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

/// @notice Mock Odos Router V3 fallback that simulates a multi-output swap: pulls the caller's (the real
/// OdosSwapExecutor's) full USDC allowance and pushes fixed WETH and DAI amounts back to the caller. Installed
/// via `vm.etch` at the real ODOS_ROUTER_V3 address so the real OdosSwapExecutor bytecode runs unmodified.
/// Uses only compile-time constants (no storage, no constructor-set state), so `vm.etch` - which copies runtime
/// code only - is safe: there is no constructor to run and nothing to lose.
contract MockOdosRouterMultiOutput {
    address private constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address private constant DAI = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;

    uint256 private constant WETH_OUT = 0.297 ether;
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

/// @notice IL-8767 router mock selected by calldata `abi.encode(mode, thief, claimTarget, vault, wethOut)`.
/// mode 0: honest swap (pull the USDC allowance, pay `wethOut` WETH to the caller, then claim for the vault);
/// mode 1/2: pull the USDC allowance to `thief`, then `claimTarget.claim(vault)` (refills the vault with USDC / WETH).
/// Only constants are used, so `vm.etch` of the runtime code is safe.
contract OdosMockRouterNetDelta {
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
        OdosMockClaimDistributor(claimTarget).claim(vault);
    }
}

/// @notice Permissionless reward distributor (anyone may claim on behalf of an account, payout goes to the account).
contract OdosMockClaimDistributor {
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
contract SlippageEncoderHelper {
    function encodeSlippage(uint256 slippageWad_) external pure returns (bytes32) {
        return OdosSubstrateLib.encodeSlippageSubstrate(slippageWad_);
    }
}

/// @notice Router mock whose behaviour is selected by the swap calldata `abi.encode(uint16 pullBps, uint256 wethOut)`:
/// pulls `allowance * pullBps / 10000` USDC from the caller (the real OdosSwapExecutor) and pays `wethOut` WETH to
/// it. Installed via `vm.etch` at the real ODOS_ROUTER_V3 address (code only; constants only, no storage), so the real
/// executor and the production fuse run unmodified.
contract OdosMockRouterPull {
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
