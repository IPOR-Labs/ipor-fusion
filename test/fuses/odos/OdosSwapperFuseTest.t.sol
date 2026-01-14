// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
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
/// @notice Fork integration tests for OdosSwapperFuse on Arbitrum
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
                _withdrawManager
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

        console2.log("USDC swapped:", depositAmount);
        console2.log("WETH received:", vaultWethAfter);
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
