// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig, FeeConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {FuseAction, PlasmaVault, PlasmaVaultInitData} from "../../../contracts/vaults/PlasmaVault.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";

import {UniswapV3SwapFuse, UniswapV3SwapFuseEnterData} from "../../../contracts/fuses/uniswap/UniswapV3SwapFuse.sol";

import {RoleLib, UsersToRoles} from "../../RoleLib.sol";

import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {ZeroBalanceFuse} from "../../../contracts/fuses/ZeroBalanceFuse.sol";
import {UniswapV3Balance} from "../../../contracts/fuses/uniswap/UniswapV3Balance.sol";
import {UniswapV3NewPositionFuse, UniswapV3NewPositionFuseEnterData, UniswapV3NewPositionFuseExitData} from "../../../contracts/fuses/uniswap/UniswapV3NewPositionFuse.sol";
import {UniswapV3ModifyPositionFuse, UniswapV3ModifyPositionFuseEnterData, UniswapV3ModifyPositionFuseExitData} from "../../../contracts/fuses/uniswap/UniswapV3ModifyPositionFuse.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {UniswapV3CollectFuse, UniswapV3CollectFuseEnterData} from "../../../contracts/fuses/uniswap/UniswapV3CollectFuse.sol";
import {TransientStorageSetInputsFuse, TransientStorageSetInputsFuseEnterData} from "../../../contracts/fuses/transient_storage/TransientStorageSetInputsFuse.sol";
import {TypeConversionLib} from "../../../contracts/libraries/TypeConversionLib.sol";

import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {PlasmaVaultConfigurator} from "../../utils/PlasmaVaultConfigurator.sol";

contract UniswapV3PositionFuseTest is Test {
    using SafeERC20 for ERC20;

    event MarketBalancesUpdated(uint256[] marketIds, int256 deltaInUnderlying);

    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address private constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    address private constant _UNIVERSAL_ROUTER = 0xEf1c6E67703c7BD7107eed8303Fbe6EC2554BF6B;
    address private constant _NONFUNGIBLE_POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address private constant _UNISWAP_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;

    int24 private constant MIN_TICK = -887272;
    int24 private constant MAX_TICK = -MIN_TICK;
    int24 private constant TICK_SPACING = 60;

    address private _plasmaVault;
    address private _priceOracle;
    address private _accessManager;
    address private _withdrawManager;
    UniswapV3SwapFuse private _uniswapV3SwapFuse;
    UniswapV3NewPositionFuse private _uniswapV3NewPositionFuse;
    UniswapV3ModifyPositionFuse private _uniswapV3ModifyPositionFuse;
    UniswapV3CollectFuse private _uniswapV3CollectFuse;
    address private _transientStorageSetInputsFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 20639326);
        //        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"));

        address[] memory alphas = new address[](1);
        alphas[0] = address(this);

        // price oracle
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf);
        _priceOracle = address(
            new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
        );

        _withdrawManager = address(new WithdrawManager(address(_accessManager)));
        // plasma vault
        _plasmaVault = address(new PlasmaVault());
        PlasmaVault(_plasmaVault).proxyInitialize(
            PlasmaVaultInitData(
                "TEST PLASMA VAULT",
                "pvUSDC",
                USDC,
                _priceOracle,
                _setupFeeConfig(),
                _createAccessManager(),
                address(new PlasmaVaultBase()),
                _withdrawManager
            )
        );
        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            address(this),
            address(_plasmaVault),
            _setupFuses(),
            _setupBalanceFuses(),
            _setupMarketConfigs()
        );
        _setupRoles();
        _setupDependenceBalance();

        address userOne = address(0x1222);
        vm.prank(0xDa9CE944a37d218c3302F6B82a094844C6ECEb17);
        ERC20(USDC).transfer(userOne, 100_000e6);

        vm.prank(userOne);
        ERC20(USDC).approve(_plasmaVault, 100_000e6);
        vm.prank(userOne);
        PlasmaVault(_plasmaVault).deposit(10_000e6, userOne);

        bytes memory path = abi.encodePacked(USDC, uint24(100), USDT);

        UniswapV3SwapFuseEnterData memory enterData = UniswapV3SwapFuseEnterData({
            tokenInAmount: 5_000e6,
            path: path,
            minOutAmount: 0
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_uniswapV3SwapFuse),
            abi.encodeWithSignature("enter((uint256,uint256,bytes))", enterData)
        );

        PlasmaVault(_plasmaVault).execute(enterCalls);
    }

    function testShouldOpenNewPosition() external {
        // given
        UniswapV3NewPositionFuseEnterData memory mintParams = UniswapV3NewPositionFuseEnterData({
            token0: USDC,
            token1: USDT,
            fee: 100,
            tickLower: -100,
            tickUpper: 101,
            amount0Desired: 1_000e6,
            amount1Desired: 1_000e6,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 100
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_uniswapV3NewPositionFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,uint256))",
                mintParams
            )
        );

        uint256 marketBalanceBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.UNISWAP_SWAP_V3_POSITIONS
        );
        uint256 erc20BalanceBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.ERC20_VAULT_BALANCE
        );
        // when
        vm.recordLogs();
        PlasmaVault(_plasmaVault).execute(enterCalls);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // then
        (, uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = _extractMarketIdsFromEvent(entries);

        uint256 marketBalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.UNISWAP_SWAP_V3_POSITIONS
        );
        uint256 erc20BalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.ERC20_VAULT_BALANCE
        );

        assertEq(marketBalanceBefore, 0, "marketBalanceBefore");
        assertApproxEqAbs(marketBalanceAfter, amount0 + amount1, 1e6, "marketBalanceAfter");

        assertGt(tokenId, 0, "tokenId");
        assertGt(liquidity, 0, "liquidity");

        assertGt(erc20BalanceBefore, erc20BalanceAfter, "erc20BalanceBefore>erc20BalanceAfter");
    }

    function testShouldOpenTwoNewPosition() external {
        // given
        UniswapV3NewPositionFuseEnterData memory mintParams = UniswapV3NewPositionFuseEnterData({
            token0: USDC,
            token1: USDT,
            fee: 100,
            tickLower: -100,
            tickUpper: 101,
            amount0Desired: 1_000e6,
            amount1Desired: 1_000e6,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 100
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_uniswapV3NewPositionFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,uint256))",
                mintParams
            )
        );

        // when
        vm.recordLogs();
        PlasmaVault(_plasmaVault).execute(enterCalls);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        vm.recordLogs();
        PlasmaVault(_plasmaVault).execute(enterCalls);
        Vm.Log[] memory entries2 = vm.getRecordedLogs();

        // then
        (, uint256 tokenId, , , ) = _extractMarketIdsFromEvent(entries);

        (, uint256 tokenId2, , , ) = _extractMarketIdsFromEvent(entries2);

        assertGt(tokenId, 0, "tokenId");
        assertEq(tokenId2, tokenId + 1, "tokenId2 = tokenId + 1");
    }

    function stestShouldIncreaseLiquidity() external {
        // given
        UniswapV3NewPositionFuseEnterData memory mintParams = UniswapV3NewPositionFuseEnterData({
            token0: USDC,
            token1: USDT,
            fee: 100,
            tickLower: -100,
            tickUpper: 101,
            amount0Desired: 1_000e6,
            amount1Desired: 1_000e6,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 100
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_uniswapV3NewPositionFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,uint256))",
                mintParams
            )
        );

        vm.recordLogs();
        PlasmaVault(_plasmaVault).execute(enterCalls);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        (, uint256 tokenId, , uint256 amount0, uint256 amount1) = _extractMarketIdsFromEvent(entries);

        uint256 marketBalanceBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.UNISWAP_SWAP_V3_POSITIONS
        );
        uint256 erc20BalanceBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.ERC20_VAULT_BALANCE
        );

        UniswapV3ModifyPositionFuseEnterData memory enterDataIncrease = UniswapV3ModifyPositionFuseEnterData({
            tokenId: tokenId,
            token0: USDC,
            token1: USDT,
            amount0Desired: 2_000e6,
            amount1Desired: 2_000e6,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 100
        });

        FuseAction[] memory enterCallsIncrease = new FuseAction[](1);

        enterCallsIncrease[0] = FuseAction(
            address(_uniswapV3ModifyPositionFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint256,uint256,uint256,uint256,uint256,uint256))",
                enterDataIncrease
            )
        );

        // when
        vm.recordLogs();
        PlasmaVault(_plasmaVault).execute(enterCallsIncrease);
        Vm.Log[] memory entriesIncreaseLiquidity = vm.getRecordedLogs();

        // then
        (
            ,
            uint256 tokenIdIncrease,
            ,
            uint256 amount0Increase,
            uint256 amount1Increase
        ) = _extractIncreaseLiquidityFromEvent(entriesIncreaseLiquidity);

        uint256 marketBalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.UNISWAP_SWAP_V3_POSITIONS
        );
        uint256 erc20BalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.ERC20_VAULT_BALANCE
        );

        assertGt(marketBalanceAfter, marketBalanceBefore, "marketBalanceAfter>marketBalanceBefore");
        assertGt(erc20BalanceBefore, erc20BalanceAfter, "erc20BalanceBefore>erc20BalanceAfter");

        assertGt(amount0Increase, amount0, "amount0Increase>ammount0");
        assertGt(amount1Increase, amount1, "amount1Increase>ammount1");
    }

    function testShouldDecreaseLiquidity() external {
        // given
        UniswapV3NewPositionFuseEnterData memory mintParams = UniswapV3NewPositionFuseEnterData({
            token0: USDC,
            token1: USDT,
            fee: 100,
            tickLower: 100,
            tickUpper: 1000,
            amount0Desired: 1_000e6,
            amount1Desired: 1_000e6,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 100
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_uniswapV3NewPositionFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,uint256))",
                mintParams
            )
        );

        vm.recordLogs();
        PlasmaVault(_plasmaVault).execute(enterCalls);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        (
            ,
            uint256 tokenIdMintPosition,
            uint128 liquidity,
            uint256 amount0MintPosition,
            uint256 amount1MintPosition
        ) = _extractMarketIdsFromEvent(entries);

        UniswapV3ModifyPositionFuseExitData memory exitDataDecrease = UniswapV3ModifyPositionFuseExitData({
            tokenId: tokenIdMintPosition,
            liquidity: liquidity,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 100000
        });

        FuseAction[] memory exitCallsIncrease = new FuseAction[](1);

        exitCallsIncrease[0] = FuseAction(
            address(_uniswapV3ModifyPositionFuse),
            abi.encodeWithSignature("exit((uint256,uint128,uint256,uint256,uint256))", exitDataDecrease)
        );

        // when
        PlasmaVault(_plasmaVault).execute(exitCallsIncrease);
        Vm.Log[] memory entriesIncreaseLiquidity = vm.getRecordedLogs();

        // then
        (
            ,
            uint256 tokenIdDecrease,
            uint256 amount0Decrease,
            uint256 amount1Decrease
        ) = _extractDecreaseLiquidityFromEvent(entriesIncreaseLiquidity);

        assertApproxEqAbs(amount0MintPosition, 1000000000, 1e6, "amount0MintPosition");
        assertApproxEqAbs(amount0Decrease, 1000000000, 1e6, "amount0Decrease");

        assertApproxEqAbs(amount1MintPosition, 0, 1e6, "amount1MintPosition");
        assertApproxEqAbs(amount1Decrease, 0, 1e6, "amount1Decrease");

        assertEq(tokenIdMintPosition, tokenIdDecrease, "tokenIdMintPosition = tokenIdDecrease");
    }

    function testShouldDecreaseHalfLiquidity() external {
        // given
        UniswapV3NewPositionFuseEnterData memory mintParams = UniswapV3NewPositionFuseEnterData({
            token0: USDC,
            token1: USDT,
            fee: 100,
            tickLower: 100,
            tickUpper: 1000,
            amount0Desired: 1_000e6,
            amount1Desired: 1_000e6,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 100
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_uniswapV3NewPositionFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,uint256))",
                mintParams
            )
        );

        vm.recordLogs();
        PlasmaVault(_plasmaVault).execute(enterCalls);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        (
            ,
            uint256 tokenIdMintPosition,
            uint128 liquidity,
            uint256 amount0MintPosition,
            uint256 amount1MintPosition
        ) = _extractMarketIdsFromEvent(entries);

        UniswapV3ModifyPositionFuseExitData memory exitDataDecrease = UniswapV3ModifyPositionFuseExitData({
            tokenId: tokenIdMintPosition,
            liquidity: liquidity / 2,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 100000
        });

        FuseAction[] memory exitCallsIncrease = new FuseAction[](1);

        exitCallsIncrease[0] = FuseAction(
            address(_uniswapV3ModifyPositionFuse),
            abi.encodeWithSignature("exit((uint256,uint128,uint256,uint256,uint256))", exitDataDecrease)
        );

        // when
        PlasmaVault(_plasmaVault).execute(exitCallsIncrease);
        Vm.Log[] memory entriesIncreaseLiquidity = vm.getRecordedLogs();

        // then
        (
            ,
            uint256 tokenIdDecrease,
            uint256 amount0Decrease,
            uint256 amount1Decrease
        ) = _extractDecreaseLiquidityFromEvent(entriesIncreaseLiquidity);

        assertApproxEqAbs(amount0MintPosition, 1000000000, 1e6, "amount0MintPosition");
        assertApproxEqAbs(amount0Decrease, 499999999, 1e6, "amount0Decrease");

        assertApproxEqAbs(amount1MintPosition, 0, 1e6, "amount1MintPosition");
        assertApproxEqAbs(amount1Decrease, 0, 1e6, "amount1Decrease");

        assertEq(tokenIdMintPosition, tokenIdDecrease, "tokenIdMintPosition = tokenIdDecrease");
    }

    function testShouldCollectAllAfterDecreaseLiquidity() external {
        // given
        UniswapV3NewPositionFuseEnterData memory mintParams = UniswapV3NewPositionFuseEnterData({
            token0: USDC,
            token1: USDT,
            fee: 100,
            tickLower: 100,
            tickUpper: 1000,
            amount0Desired: 1_000e6,
            amount1Desired: 1_000e6,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 100
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_uniswapV3NewPositionFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,uint256))",
                mintParams
            )
        );

        vm.recordLogs();
        PlasmaVault(_plasmaVault).execute(enterCalls);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        (, uint256 tokenIdMintPosition, uint128 liquidity, , ) = _extractMarketIdsFromEvent(entries);

        UniswapV3ModifyPositionFuseExitData memory exitDataDecrease = UniswapV3ModifyPositionFuseExitData({
            tokenId: tokenIdMintPosition,
            liquidity: liquidity,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 100000
        });

        FuseAction[] memory exitCallsIncrease = new FuseAction[](1);

        exitCallsIncrease[0] = FuseAction(
            address(_uniswapV3ModifyPositionFuse),
            abi.encodeWithSignature("exit((uint256,uint128,uint256,uint256,uint256))", exitDataDecrease)
        );
        PlasmaVault(_plasmaVault).execute(exitCallsIncrease);

        uint256 marketBalanceBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.UNISWAP_SWAP_V3_POSITIONS
        );
        uint256 erc20BalanceBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.ERC20_VAULT_BALANCE
        );

        uint256 usdcBalanceBefore = ERC20(USDC).balanceOf(_plasmaVault);

        UniswapV3CollectFuseEnterData memory collectFeesData;
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenIdMintPosition;
        collectFeesData.tokenIds = tokenIds;

        FuseAction[] memory enterCollect = new FuseAction[](1);
        enterCollect[0] = FuseAction(
            address(_uniswapV3CollectFuse),
            abi.encodeWithSignature("enter((uint256[]))", collectFeesData)
        );

        // when
        PlasmaVault(_plasmaVault).execute(enterCollect);
        Vm.Log[] memory entriesCollect = vm.getRecordedLogs();

        // then
        (, , uint256 amount0Collect, uint256 amount1Collect) = _extractCollectFeesFromEvent(entriesCollect);

        uint256 marketBalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.UNISWAP_SWAP_V3_POSITIONS
        );
        uint256 erc20BalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.ERC20_VAULT_BALANCE
        );

        uint256 usdcBalanceAfter = ERC20(USDC).balanceOf(_plasmaVault);

        assertApproxEqAbs(amount0Collect, 1000000000, 1e6, "amount0Collect");
        assertApproxEqAbs(amount1Collect, 0, 1e6, "amount1Collect");

        assertApproxEqAbs(marketBalanceBefore, 1000000000, 1e6, "marketBalanceBefore");
        assertApproxEqAbs(marketBalanceAfter, 0, 1e6, "marketBalanceAfter");

        assertApproxEqAbs(erc20BalanceBefore, 5000496924, 1e6, "erc20BalanceBefore");
        assertApproxEqAbs(erc20BalanceAfter, 5000496924, 1e6, "erc20BalanceAfter");

        assertApproxEqAbs(usdcBalanceBefore, 4000000000, 1e6, "usdcBalanceBefore");
        assertApproxEqAbs(usdcBalanceAfter, 4999999999, 1e6, "usdcBalanceAfter");
    }

    function testShouldCRemovePosition() external {
        // given
        UniswapV3NewPositionFuseEnterData memory mintParams = UniswapV3NewPositionFuseEnterData({
            token0: USDC,
            token1: USDT,
            fee: 100,
            tickLower: 100,
            tickUpper: 1000,
            amount0Desired: 1_000e6,
            amount1Desired: 1_000e6,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 100
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_uniswapV3NewPositionFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,uint256))",
                mintParams
            )
        );

        vm.recordLogs();
        PlasmaVault(_plasmaVault).execute(enterCalls);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        (, uint256 tokenIdMintPosition, uint128 liquidity, , ) = _extractMarketIdsFromEvent(entries);

        UniswapV3ModifyPositionFuseExitData memory exitDataDecrease = UniswapV3ModifyPositionFuseExitData({
            tokenId: tokenIdMintPosition,
            liquidity: liquidity,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 100000
        });

        FuseAction[] memory exitCallsIncrease = new FuseAction[](1);

        exitCallsIncrease[0] = FuseAction(
            address(_uniswapV3ModifyPositionFuse),
            abi.encodeWithSignature("exit((uint256,uint128,uint256,uint256,uint256))", exitDataDecrease)
        );
        PlasmaVault(_plasmaVault).execute(exitCallsIncrease);

        UniswapV3CollectFuseEnterData memory collectFeesData;
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenIdMintPosition;
        collectFeesData.tokenIds = tokenIds;

        FuseAction[] memory enterCollect = new FuseAction[](1);
        enterCollect[0] = FuseAction(
            address(_uniswapV3CollectFuse),
            abi.encodeWithSignature("enter((uint256[]))", collectFeesData)
        );

        PlasmaVault(_plasmaVault).execute(enterCollect);

        UniswapV3NewPositionFuseExitData memory closePositions;
        closePositions.tokenIds = tokenIds;

        enterCalls[0] = FuseAction(
            address(_uniswapV3NewPositionFuse),
            abi.encodeWithSignature("exit((uint256[]))", closePositions)
        );

        // when
        PlasmaVault(_plasmaVault).execute(enterCalls);
        Vm.Log[] memory entriesClosePosition = vm.getRecordedLogs();

        // then
        (, uint256 closeTokenId) = _extractClosePositionFromEvent(entriesClosePosition);

        assertEq(tokenIdMintPosition, closeTokenId, "tokenIdMintPosition = closeTokenId");
    }

    function _setupFeeConfig() private returns (FeeConfig memory feeConfig_) {
        feeConfig_ = FeeConfigHelper.createZeroFeeConfig();
    }

    function _createAccessManager() private returns (address accessManager_) {
        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = address(this);
        usersToRoles.atomist = address(this);
        address[] memory alphas = new address[](1);
        alphas[0] = address(this);
        usersToRoles.alphas = alphas;
        accessManager_ = address(RoleLib.createAccessManager(usersToRoles, 0, vm));
        _accessManager = accessManager_;
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
        marketConfigs_ = new MarketSubstratesConfig[](3);

        bytes32[] memory uniswapTokens = new bytes32[](3);
        uniswapTokens[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);
        uniswapTokens[1] = PlasmaVaultConfigLib.addressToBytes32(USDT);
        uniswapTokens[2] = PlasmaVaultConfigLib.addressToBytes32(DAI);

        marketConfigs_[0] = MarketSubstratesConfig(IporFusionMarkets.UNISWAP_SWAP_V3, uniswapTokens);
        marketConfigs_[1] = MarketSubstratesConfig(IporFusionMarkets.UNISWAP_SWAP_V3_POSITIONS, uniswapTokens);
        marketConfigs_[2] = MarketSubstratesConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, uniswapTokens);
    }

    function _setupFuses() private returns (address[] memory fuses) {
        _uniswapV3SwapFuse = new UniswapV3SwapFuse(IporFusionMarkets.UNISWAP_SWAP_V3, _UNIVERSAL_ROUTER);

        _uniswapV3NewPositionFuse = new UniswapV3NewPositionFuse(
            IporFusionMarkets.UNISWAP_SWAP_V3_POSITIONS,
            _NONFUNGIBLE_POSITION_MANAGER
        );

        _uniswapV3ModifyPositionFuse = new UniswapV3ModifyPositionFuse(
            IporFusionMarkets.UNISWAP_SWAP_V3_POSITIONS,
            _NONFUNGIBLE_POSITION_MANAGER
        );

        _uniswapV3CollectFuse = new UniswapV3CollectFuse(
            IporFusionMarkets.UNISWAP_SWAP_V3_POSITIONS,
            _NONFUNGIBLE_POSITION_MANAGER
        );

        _transientStorageSetInputsFuse = address(new TransientStorageSetInputsFuse());

        fuses = new address[](5);
        fuses[0] = address(_uniswapV3SwapFuse);
        fuses[1] = address(_uniswapV3NewPositionFuse);
        fuses[2] = address(_uniswapV3ModifyPositionFuse);
        fuses[3] = address(_uniswapV3CollectFuse);
        fuses[4] = _transientStorageSetInputsFuse;
    }

    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses_) {
        ZeroBalanceFuse uniswapZeroBalance = new ZeroBalanceFuse(IporFusionMarkets.UNISWAP_SWAP_V3);
        UniswapV3Balance uniswapBalance = new UniswapV3Balance(
            IporFusionMarkets.UNISWAP_SWAP_V3_POSITIONS,
            _NONFUNGIBLE_POSITION_MANAGER,
            _UNISWAP_FACTORY
        );
        ERC20BalanceFuse erc20Balance = new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE);

        balanceFuses_ = new MarketBalanceFuseConfig[](3);
        balanceFuses_[0] = MarketBalanceFuseConfig(IporFusionMarkets.UNISWAP_SWAP_V3, address(uniswapZeroBalance));
        balanceFuses_[1] = MarketBalanceFuseConfig(
            IporFusionMarkets.UNISWAP_SWAP_V3_POSITIONS,
            address(uniswapBalance)
        );
        balanceFuses_[2] = MarketBalanceFuseConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, address(erc20Balance));
    }

    function _setupDependenceBalance() private {
        uint256[] memory marketIds = new uint256[](2);
        marketIds[0] = IporFusionMarkets.UNISWAP_SWAP_V3;
        marketIds[1] = IporFusionMarkets.UNISWAP_SWAP_V3_POSITIONS;

        uint256[] memory dependence = new uint256[](1);
        dependence[0] = IporFusionMarkets.ERC20_VAULT_BALANCE;

        uint256[][] memory dependenceMarkets = new uint256[][](2);
        dependenceMarkets[0] = dependence;
        dependenceMarkets[1] = dependence;

        PlasmaVaultGovernance(_plasmaVault).updateDependencyBalanceGraphs(marketIds, dependenceMarkets);
    }

    function _extractMarketIdsFromEvent(
        Vm.Log[] memory entries
    ) private view returns (address version, uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        for (uint256 i = 0; i < entries.length; i++) {
            if (
                entries[i].topics[0] ==
                keccak256(
                    "UniswapV3NewPositionFuseEnter(address,uint256,uint128,uint256,uint256,address,address,uint24,int24,int24)"
                )
            ) {
                (version, tokenId, liquidity, amount0, amount1, , , , , ) = abi.decode(
                    entries[i].data,
                    (address, uint256, uint128, uint256, uint256, address, address, uint24, int24, int24)
                );
                break;
            }
        }
    }

    function _extractIncreaseLiquidityFromEvent(
        Vm.Log[] memory entries
    ) private view returns (address version, uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        for (uint256 i = 0; i < entries.length; i++) {
            if (
                entries[i].topics[0] ==
                keccak256("UniswapV3ModifyPositionFuseEnter(address,uint256,uint128,uint256,uint256)")
            ) {
                (version, tokenId, liquidity, amount0, amount1) = abi.decode(
                    entries[i].data,
                    (address, uint256, uint128, uint256, uint256)
                );
                break;
            }
        }
    }
    function _extractDecreaseLiquidityFromEvent(
        Vm.Log[] memory entries
    ) private view returns (address version, uint256 tokenId, uint256 amount0, uint256 amount1) {
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == keccak256("UniswapV3ModifyPositionFuseExit(address,uint256,uint256,uint256)")) {
                (version, tokenId, amount0, amount1) = abi.decode(
                    entries[i].data,
                    (address, uint256, uint256, uint256)
                );
                break;
            }
        }
    }

    function _extractCollectFeesFromEvent(
        Vm.Log[] memory entries
    ) private view returns (address version, uint256 tokenId, uint256 amount0, uint256 amount1) {
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == keccak256("UniswapV3CollectFuseEnter(address,uint256,uint256,uint256)")) {
                (version, tokenId, amount0, amount1) = abi.decode(
                    entries[i].data,
                    (address, uint256, uint256, uint256)
                );
                break;
            }
        }
    }

    function _extractClosePositionFromEvent(
        Vm.Log[] memory entries
    ) private view returns (address version, uint256 tokenId) {
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == keccak256("UniswapV3NewPositionFuseExit(address,uint256)")) {
                (version, tokenId) = abi.decode(entries[i].data, (address, uint256));
                break;
            }
        }
    }

    function testShouldEnterNewPositionUsingTransient() external {
        // given
        address[] memory fuses = new address[](1);
        fuses[0] = address(_uniswapV3NewPositionFuse);

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = new bytes32[](10);
        inputsByFuse[0][0] = TypeConversionLib.toBytes32(USDC); // token0
        inputsByFuse[0][1] = TypeConversionLib.toBytes32(USDT); // token1
        inputsByFuse[0][2] = TypeConversionLib.toBytes32(uint256(100)); // fee
        inputsByFuse[0][3] = TypeConversionLib.toBytes32(uint256(int256(-100))); // tickLower
        inputsByFuse[0][4] = TypeConversionLib.toBytes32(uint256(int256(101))); // tickUpper
        inputsByFuse[0][5] = TypeConversionLib.toBytes32(uint256(1_000e6)); // amount0Desired
        inputsByFuse[0][6] = TypeConversionLib.toBytes32(uint256(1_000e6)); // amount1Desired
        inputsByFuse[0][7] = TypeConversionLib.toBytes32(uint256(0)); // amount0Min
        inputsByFuse[0][8] = TypeConversionLib.toBytes32(uint256(0)); // amount1Min
        inputsByFuse[0][9] = TypeConversionLib.toBytes32(uint256(block.timestamp + 100)); // deadline

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fuses,
            inputsByFuse: inputsByFuse
        });

        FuseAction[] memory calls = new FuseAction[](2);
        calls[0] = FuseAction(
            _transientStorageSetInputsFuse,
            abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        );
        calls[1] = FuseAction(address(_uniswapV3NewPositionFuse), abi.encodeWithSignature("enterTransient()"));

        uint256 marketBalanceBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.UNISWAP_SWAP_V3_POSITIONS
        );
        uint256 erc20BalanceBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.ERC20_VAULT_BALANCE
        );

        // when
        vm.recordLogs();
        PlasmaVault(_plasmaVault).execute(calls);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // then
        (, uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = _extractMarketIdsFromEvent(entries);

        uint256 marketBalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.UNISWAP_SWAP_V3_POSITIONS
        );
        uint256 erc20BalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.ERC20_VAULT_BALANCE
        );

        assertEq(marketBalanceBefore, 0, "marketBalanceBefore");
        assertApproxEqAbs(marketBalanceAfter, amount0 + amount1, 1e6, "marketBalanceAfter");

        assertGt(tokenId, 0, "tokenId");
        assertGt(liquidity, 0, "liquidity");

        assertGt(erc20BalanceBefore, erc20BalanceAfter, "erc20BalanceBefore>erc20BalanceAfter");
    }

    function testShouldExitPositionUsingTransient() external {
        // given - first create a position
        UniswapV3NewPositionFuseEnterData memory mintParams = UniswapV3NewPositionFuseEnterData({
            token0: USDC,
            token1: USDT,
            fee: 100,
            tickLower: 100,
            tickUpper: 1000,
            amount0Desired: 1_000e6,
            amount1Desired: 1_000e6,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 100
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_uniswapV3NewPositionFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,uint256))",
                mintParams
            )
        );

        vm.recordLogs();
        PlasmaVault(_plasmaVault).execute(enterCalls);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        (, uint256 tokenIdMintPosition, uint128 liquidity, , ) = _extractMarketIdsFromEvent(entries);

        // Decrease liquidity first
        UniswapV3ModifyPositionFuseExitData memory exitDataDecrease = UniswapV3ModifyPositionFuseExitData({
            tokenId: tokenIdMintPosition,
            liquidity: liquidity,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 100000
        });

        FuseAction[] memory exitCallsDecrease = new FuseAction[](1);
        exitCallsDecrease[0] = FuseAction(
            address(_uniswapV3ModifyPositionFuse),
            abi.encodeWithSignature("exit((uint256,uint128,uint256,uint256,uint256))", exitDataDecrease)
        );
        PlasmaVault(_plasmaVault).execute(exitCallsDecrease);

        // Collect fees
        UniswapV3CollectFuseEnterData memory collectFeesData;
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenIdMintPosition;
        collectFeesData.tokenIds = tokenIds;

        FuseAction[] memory enterCollect = new FuseAction[](1);
        enterCollect[0] = FuseAction(
            address(_uniswapV3CollectFuse),
            abi.encodeWithSignature("enter((uint256[]))", collectFeesData)
        );
        PlasmaVault(_plasmaVault).execute(enterCollect);

        // Now test exitTransient
        address[] memory fuses = new address[](1);
        fuses[0] = address(_uniswapV3NewPositionFuse);

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = new bytes32[](2); // length + 1 tokenId
        inputsByFuse[0][0] = TypeConversionLib.toBytes32(uint256(1)); // length
        inputsByFuse[0][1] = TypeConversionLib.toBytes32(tokenIdMintPosition); // tokenId

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fuses,
            inputsByFuse: inputsByFuse
        });

        FuseAction[] memory calls = new FuseAction[](2);
        calls[0] = FuseAction(
            _transientStorageSetInputsFuse,
            abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        );
        calls[1] = FuseAction(address(_uniswapV3NewPositionFuse), abi.encodeWithSignature("exitTransient()"));

        // when
        vm.recordLogs();
        PlasmaVault(_plasmaVault).execute(calls);
        Vm.Log[] memory entriesClosePosition = vm.getRecordedLogs();

        // then
        (, uint256 closeTokenId) = _extractClosePositionFromEvent(entriesClosePosition);

        assertEq(tokenIdMintPosition, closeTokenId, "tokenIdMintPosition = closeTokenId");
    }

    function testShouldEnterModifyPositionUsingTransient() external {
        // given - first create a position
        UniswapV3NewPositionFuseEnterData memory mintParams = UniswapV3NewPositionFuseEnterData({
            token0: USDC,
            token1: USDT,
            fee: 100,
            tickLower: -100,
            tickUpper: 101,
            amount0Desired: 1_000e6,
            amount1Desired: 1_000e6,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 100
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_uniswapV3NewPositionFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,uint256))",
                mintParams
            )
        );

        vm.recordLogs();
        PlasmaVault(_plasmaVault).execute(enterCalls);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        (, uint256 tokenId, , uint256 amount0, uint256 amount1) = _extractMarketIdsFromEvent(entries);

        uint256 marketBalanceBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.UNISWAP_SWAP_V3_POSITIONS
        );
        uint256 erc20BalanceBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.ERC20_VAULT_BALANCE
        );

        // Prepare transient storage inputs for increase liquidity
        address[] memory fuses = new address[](1);
        fuses[0] = address(_uniswapV3ModifyPositionFuse);

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = new bytes32[](8);
        inputsByFuse[0][0] = TypeConversionLib.toBytes32(USDC); // token0
        inputsByFuse[0][1] = TypeConversionLib.toBytes32(USDT); // token1
        inputsByFuse[0][2] = TypeConversionLib.toBytes32(tokenId); // tokenId
        inputsByFuse[0][3] = TypeConversionLib.toBytes32(uint256(2_000e6)); // amount0Desired
        inputsByFuse[0][4] = TypeConversionLib.toBytes32(uint256(2_000e6)); // amount1Desired
        inputsByFuse[0][5] = TypeConversionLib.toBytes32(uint256(0)); // amount0Min
        inputsByFuse[0][6] = TypeConversionLib.toBytes32(uint256(0)); // amount1Min
        inputsByFuse[0][7] = TypeConversionLib.toBytes32(uint256(block.timestamp + 100)); // deadline

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fuses,
            inputsByFuse: inputsByFuse
        });

        FuseAction[] memory calls = new FuseAction[](2);
        calls[0] = FuseAction(
            _transientStorageSetInputsFuse,
            abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        );
        calls[1] = FuseAction(address(_uniswapV3ModifyPositionFuse), abi.encodeWithSignature("enterTransient()"));

        // when
        vm.recordLogs();
        PlasmaVault(_plasmaVault).execute(calls);
        Vm.Log[] memory entriesIncreaseLiquidity = vm.getRecordedLogs();

        // then
        (
            ,
            uint256 tokenIdIncrease,
            ,
            uint256 amount0Increase,
            uint256 amount1Increase
        ) = _extractIncreaseLiquidityFromEvent(entriesIncreaseLiquidity);

        uint256 marketBalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.UNISWAP_SWAP_V3_POSITIONS
        );
        uint256 erc20BalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.ERC20_VAULT_BALANCE
        );

        assertGt(marketBalanceAfter, marketBalanceBefore, "marketBalanceAfter>marketBalanceBefore");
        assertGt(erc20BalanceBefore, erc20BalanceAfter, "erc20BalanceBefore>erc20BalanceAfter");

        assertGt(amount0Increase, amount0, "amount0Increase>amount0");
        assertGt(amount1Increase, amount1, "amount1Increase>amount1");
        assertEq(tokenId, tokenIdIncrease, "tokenId = tokenIdIncrease");
    }

    function testShouldExitModifyPositionUsingTransient() external {
        // given - first create a position
        UniswapV3NewPositionFuseEnterData memory mintParams = UniswapV3NewPositionFuseEnterData({
            token0: USDC,
            token1: USDT,
            fee: 100,
            tickLower: 100,
            tickUpper: 1000,
            amount0Desired: 1_000e6,
            amount1Desired: 1_000e6,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 100
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_uniswapV3NewPositionFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,uint256))",
                mintParams
            )
        );

        vm.recordLogs();
        PlasmaVault(_plasmaVault).execute(enterCalls);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        (
            ,
            uint256 tokenIdMintPosition,
            uint128 liquidity,
            uint256 amount0MintPosition,
            uint256 amount1MintPosition
        ) = _extractMarketIdsFromEvent(entries);

        // Prepare transient storage inputs for decrease liquidity
        address[] memory fuses = new address[](1);
        fuses[0] = address(_uniswapV3ModifyPositionFuse);

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = new bytes32[](5);
        inputsByFuse[0][0] = TypeConversionLib.toBytes32(tokenIdMintPosition); // tokenId
        inputsByFuse[0][1] = TypeConversionLib.toBytes32(uint256(liquidity)); // liquidity (uint128)
        inputsByFuse[0][2] = TypeConversionLib.toBytes32(uint256(0)); // amount0Min
        inputsByFuse[0][3] = TypeConversionLib.toBytes32(uint256(0)); // amount1Min
        inputsByFuse[0][4] = TypeConversionLib.toBytes32(uint256(block.timestamp + 100000)); // deadline

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fuses,
            inputsByFuse: inputsByFuse
        });

        FuseAction[] memory calls = new FuseAction[](2);
        calls[0] = FuseAction(
            _transientStorageSetInputsFuse,
            abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        );
        calls[1] = FuseAction(address(_uniswapV3ModifyPositionFuse), abi.encodeWithSignature("exitTransient()"));

        // when
        vm.recordLogs();
        PlasmaVault(_plasmaVault).execute(calls);
        Vm.Log[] memory entriesDecreaseLiquidity = vm.getRecordedLogs();

        // then
        (
            ,
            uint256 tokenIdDecrease,
            uint256 amount0Decrease,
            uint256 amount1Decrease
        ) = _extractDecreaseLiquidityFromEvent(entriesDecreaseLiquidity);

        assertApproxEqAbs(amount0MintPosition, 1000000000, 1e6, "amount0MintPosition");
        assertApproxEqAbs(amount0Decrease, 1000000000, 1e6, "amount0Decrease");

        assertApproxEqAbs(amount1MintPosition, 0, 1e6, "amount1MintPosition");
        assertApproxEqAbs(amount1Decrease, 0, 1e6, "amount1Decrease");

        assertEq(tokenIdMintPosition, tokenIdDecrease, "tokenIdMintPosition = tokenIdDecrease");
    }

    function testShouldCollectUsingTransient() external {
        // given - first create a position
        UniswapV3NewPositionFuseEnterData memory mintParams = UniswapV3NewPositionFuseEnterData({
            token0: USDC,
            token1: USDT,
            fee: 100,
            tickLower: 100,
            tickUpper: 1000,
            amount0Desired: 1_000e6,
            amount1Desired: 1_000e6,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 100
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_uniswapV3NewPositionFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,uint256))",
                mintParams
            )
        );

        vm.recordLogs();
        PlasmaVault(_plasmaVault).execute(enterCalls);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        (, uint256 tokenIdMintPosition, uint128 liquidity, , ) = _extractMarketIdsFromEvent(entries);

        // Decrease liquidity first to generate fees
        UniswapV3ModifyPositionFuseExitData memory exitDataDecrease = UniswapV3ModifyPositionFuseExitData({
            tokenId: tokenIdMintPosition,
            liquidity: liquidity,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 100000
        });

        FuseAction[] memory exitCallsDecrease = new FuseAction[](1);
        exitCallsDecrease[0] = FuseAction(
            address(_uniswapV3ModifyPositionFuse),
            abi.encodeWithSignature("exit((uint256,uint128,uint256,uint256,uint256))", exitDataDecrease)
        );
        PlasmaVault(_plasmaVault).execute(exitCallsDecrease);

        uint256 marketBalanceBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.UNISWAP_SWAP_V3_POSITIONS
        );
        uint256 erc20BalanceBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.ERC20_VAULT_BALANCE
        );

        uint256 usdcBalanceBefore = ERC20(USDC).balanceOf(_plasmaVault);

        // Prepare transient storage inputs for collect
        address[] memory fuses = new address[](1);
        fuses[0] = address(_uniswapV3CollectFuse);

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = new bytes32[](2); // length + 1 tokenId
        inputsByFuse[0][0] = TypeConversionLib.toBytes32(uint256(1)); // length of tokenIds array
        inputsByFuse[0][1] = TypeConversionLib.toBytes32(tokenIdMintPosition); // tokenId

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fuses,
            inputsByFuse: inputsByFuse
        });

        FuseAction[] memory calls = new FuseAction[](2);
        calls[0] = FuseAction(
            _transientStorageSetInputsFuse,
            abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        );
        calls[1] = FuseAction(address(_uniswapV3CollectFuse), abi.encodeWithSignature("enterTransient()"));

        // when
        vm.recordLogs();
        PlasmaVault(_plasmaVault).execute(calls);
        Vm.Log[] memory entriesCollect = vm.getRecordedLogs();

        // then
        (, , uint256 amount0Collect, uint256 amount1Collect) = _extractCollectFeesFromEvent(entriesCollect);

        uint256 marketBalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.UNISWAP_SWAP_V3_POSITIONS
        );
        uint256 erc20BalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.ERC20_VAULT_BALANCE
        );

        uint256 usdcBalanceAfter = ERC20(USDC).balanceOf(_plasmaVault);

        assertApproxEqAbs(amount0Collect, 1000000000, 1e6, "amount0Collect");
        assertApproxEqAbs(amount1Collect, 0, 1e6, "amount1Collect");

        assertApproxEqAbs(marketBalanceBefore, 1000000000, 1e6, "marketBalanceBefore");
        assertApproxEqAbs(marketBalanceAfter, 0, 1e6, "marketBalanceAfter");

        assertApproxEqAbs(erc20BalanceBefore, 5000496924, 1e6, "erc20BalanceBefore");
        assertApproxEqAbs(erc20BalanceAfter, 5000496924, 1e6, "erc20BalanceAfter");

        assertApproxEqAbs(usdcBalanceBefore, 4000000000, 1e6, "usdcBalanceBefore");
        assertApproxEqAbs(usdcBalanceAfter, 4999999999, 1e6, "usdcBalanceAfter");
    }
}
