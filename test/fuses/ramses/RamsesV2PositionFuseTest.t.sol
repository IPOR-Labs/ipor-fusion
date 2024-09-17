// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {FuseAction, PlasmaVault, FeeConfig, PlasmaVaultInitData} from "../../../contracts/vaults/PlasmaVault.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";

import {RoleLib, UsersToRoles} from "../../RoleLib.sol";

import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {RamsesV2Balance} from "../../../contracts/fuses/ramses/RamsesV2Balance.sol";
import {RamsesV2NewPositionFuse, RamsesV2NewPositionFuseEnterData, RamsesV2NewPositionFuseExitData} from "../../../contracts/fuses/ramses/RamsesV2NewPositionFuse.sol";
import {RamsesV2ModifyPositionFuse, RamsesV2ModifyPositionFuseEnterData, RamsesV2ModifyPositionFuseExitData} from "../../../contracts/fuses/ramses/RamsesV2ModifyPositionFuse.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {RamsesV2CollectFuse, RamsesV2CollectFuseEnterData} from "../../../contracts/fuses/ramses/RamsesV2CollectFuse.sol";

contract RamsesV2PositionFuseTest is Test {
    using SafeERC20 for ERC20;

    event MarketBalancesUpdated(uint256[] marketIds, int256 deltaInUnderlying);

    address private constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant USDT = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
    address private constant DAI = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;

    address private constant _NONFUNGIBLE_POSITION_MANAGER = 0xAA277CB7914b7e5514946Da92cb9De332Ce610EF;
    address private constant _RAMSES_FACTORY = 0xAA2cd7477c451E703f3B9Ba5663334914763edF8;

    int24 private constant MIN_TICK = -887272;
    int24 private constant MAX_TICK = -MIN_TICK;
    int24 private constant TICK_SPACING = 60;

    address private _plasmaVault;
    address private _priceOracle;
    address private _accessManager;
    RamsesV2NewPositionFuse private _ramsesV2NewPositionFuse;
    RamsesV2ModifyPositionFuse private _ramsesV2ModifyPositionFuse;
    RamsesV2CollectFuse private _ramsesV2CollectFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 254261635);

        address[] memory alphas = new address[](1);
        alphas[0] = address(this);

        // price oracle
        _priceOracle = 0x9838c0d15b439816D25d5fD1AEbd259EeddB66B4;

        address[] memory assetsDai = new address[](1);
        assetsDai[0] = DAI;
        address[] memory sourcesDai = new address[](1);
        sourcesDai[0] = 0xc5C8E77B397E531B8EC06BFb0048328B30E9eCfB;

        vm.prank(PriceOracleMiddleware(_priceOracle).owner());
        PriceOracleMiddleware(_priceOracle).setAssetsPricesSources(assetsDai, sourcesDai);

        // plasma vault
        _plasmaVault = address(
            new PlasmaVault(
                PlasmaVaultInitData(
                    "TEST PLASMA VAULT",
                    "pvUSDC",
                    USDC,
                    _priceOracle,
                    _setupMarketConfigs(),
                    _setupFuses(),
                    _setupBalanceFuses(),
                    _setupFeeConfig(),
                    _createAccessManager(),
                    address(new PlasmaVaultBase()),
                    type(uint256).max
                )
            )
        );
        _setupRoles();
        _setupDependenceBalance();

        address userOne = address(0x1222);
        vm.prank(0xC6962004f452bE9203591991D15f6b388e09E8D0);
        ERC20(USDC).transfer(userOne, 100_000e6);

        vm.prank(userOne);
        ERC20(USDC).approve(_plasmaVault, 100_000e6);
        vm.prank(userOne);
        PlasmaVault(_plasmaVault).deposit(10_000e6, userOne);

        deal(USDT, userOne, 100_000e6);

        vm.prank(userOne);
        ERC20(USDT).transfer(_plasmaVault, 10_000e6);
    }

    function testShouldOpenNewPosition() external {
        // given
        RamsesV2NewPositionFuseEnterData memory mintParams = RamsesV2NewPositionFuseEnterData({
            token0: USDC,
            token1: USDT,
            fee: 50,
            tickLower: -1,
            tickUpper: 1,
            amount0Desired: 1_000e6,
            amount1Desired: 1_000e6,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 100,
            veRamTokenId: 0
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_ramsesV2NewPositionFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,uint256,uint256))",
                mintParams
            )
        );

        uint256 marketBalanceBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.RAMSES_V2_POSITIONS
        );

        // when
        vm.recordLogs();
        PlasmaVault(_plasmaVault).execute(enterCalls);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // then
        (, uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = _extractMarketIdsFromEvent(entries);

        uint256 marketBalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.RAMSES_V2_POSITIONS
        );

        assertEq(marketBalanceBefore, 0, "marketBalanceBefore");
        assertApproxEqAbs(marketBalanceAfter, amount0 + amount1, 1e6, "marketBalanceAfter");

        assertGt(tokenId, 0, "tokenId");
        assertGt(liquidity, 0, "liquidity");
    }

    function testShouldOpenTwoNewPosition() external {
        // given
        RamsesV2NewPositionFuseEnterData memory mintParams = RamsesV2NewPositionFuseEnterData({
            token0: USDC,
            token1: USDT,
            fee: 100,
            tickLower: -100,
            tickUpper: 101,
            amount0Desired: 1_000e6,
            amount1Desired: 1_000e6,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 100,
            veRamTokenId: 0
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_ramsesV2NewPositionFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,uint256,uint256))",
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

    function testShouldIncreaseLiquidity() external {
        // given
        RamsesV2NewPositionFuseEnterData memory mintParams = RamsesV2NewPositionFuseEnterData({
            token0: USDC,
            token1: USDT,
            fee: 100,
            tickLower: -100,
            tickUpper: 101,
            amount0Desired: 1_000e6,
            amount1Desired: 1_000e6,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 100,
            veRamTokenId: 0
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_ramsesV2NewPositionFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,uint256,uint256))",
                mintParams
            )
        );

        vm.recordLogs();
        PlasmaVault(_plasmaVault).execute(enterCalls);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        (, uint256 tokenId, , uint256 amount0, uint256 amount1) = _extractMarketIdsFromEvent(entries);

        uint256 marketBalanceBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.RAMSES_V2_POSITIONS
        );
        uint256 erc20BalanceBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.ERC20_VAULT_BALANCE
        );

        RamsesV2ModifyPositionFuseEnterData memory enterDataIncrease = RamsesV2ModifyPositionFuseEnterData({
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
            address(_ramsesV2ModifyPositionFuse),
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
            IporFusionMarkets.RAMSES_V2_POSITIONS
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
        RamsesV2NewPositionFuseEnterData memory mintParams = RamsesV2NewPositionFuseEnterData({
            token0: USDC,
            token1: USDT,
            fee: 100,
            tickLower: 100,
            tickUpper: 1000,
            amount0Desired: 1_000e6,
            amount1Desired: 1_000e6,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 100,
            veRamTokenId: 0
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_ramsesV2NewPositionFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,uint256,uint256))",
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

        RamsesV2ModifyPositionFuseExitData memory exitDataDecrease = RamsesV2ModifyPositionFuseExitData({
            tokenId: tokenIdMintPosition,
            liquidity: liquidity,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 100000
        });

        FuseAction[] memory exitCallsIncrease = new FuseAction[](1);

        exitCallsIncrease[0] = FuseAction(
            address(_ramsesV2ModifyPositionFuse),
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
        RamsesV2NewPositionFuseEnterData memory mintParams = RamsesV2NewPositionFuseEnterData({
            token0: USDC,
            token1: USDT,
            fee: 100,
            tickLower: 100,
            tickUpper: 1000,
            amount0Desired: 1_000e6,
            amount1Desired: 1_000e6,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 100,
            veRamTokenId: 0
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_ramsesV2NewPositionFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,uint256,uint256))",
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

        RamsesV2ModifyPositionFuseExitData memory exitDataDecrease = RamsesV2ModifyPositionFuseExitData({
            tokenId: tokenIdMintPosition,
            liquidity: liquidity / 2,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 100000
        });

        FuseAction[] memory exitCallsIncrease = new FuseAction[](1);

        exitCallsIncrease[0] = FuseAction(
            address(_ramsesV2ModifyPositionFuse),
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
        RamsesV2NewPositionFuseEnterData memory mintParams = RamsesV2NewPositionFuseEnterData({
            token0: USDC,
            token1: USDT,
            fee: 100,
            tickLower: 100,
            tickUpper: 1000,
            amount0Desired: 1_000e6,
            amount1Desired: 1_000e6,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 100,
            veRamTokenId: 0
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_ramsesV2NewPositionFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,uint256,uint256))",
                mintParams
            )
        );

        vm.recordLogs();
        PlasmaVault(_plasmaVault).execute(enterCalls);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        (, uint256 tokenIdMintPosition, uint128 liquidity, , ) = _extractMarketIdsFromEvent(entries);

        RamsesV2ModifyPositionFuseExitData memory exitDataDecrease = RamsesV2ModifyPositionFuseExitData({
            tokenId: tokenIdMintPosition,
            liquidity: liquidity,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 100000
        });

        FuseAction[] memory exitCallsIncrease = new FuseAction[](1);

        exitCallsIncrease[0] = FuseAction(
            address(_ramsesV2ModifyPositionFuse),
            abi.encodeWithSignature("exit((uint256,uint128,uint256,uint256,uint256))", exitDataDecrease)
        );
        PlasmaVault(_plasmaVault).execute(exitCallsIncrease);

        uint256 marketBalanceBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.RAMSES_V2_POSITIONS
        );
        uint256 erc20BalanceBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.ERC20_VAULT_BALANCE
        );

        uint256 usdcBalanceBefore = ERC20(USDC).balanceOf(_plasmaVault);

        RamsesV2CollectFuseEnterData memory collectFeesData;
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenIdMintPosition;
        collectFeesData.tokenIds = tokenIds;

        FuseAction[] memory enterCollect = new FuseAction[](1);
        enterCollect[0] = FuseAction(
            address(_ramsesV2CollectFuse),
            abi.encodeWithSignature("enter((uint256[]))", collectFeesData)
        );

        // when
        PlasmaVault(_plasmaVault).execute(enterCollect);
        Vm.Log[] memory entriesCollect = vm.getRecordedLogs();

        // then
        (, , uint256 amount0Collect, uint256 amount1Collect) = _extractCollectFeesFromEvent(entriesCollect);

        uint256 marketBalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.RAMSES_V2_POSITIONS
        );
        uint256 erc20BalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.ERC20_VAULT_BALANCE
        );

        uint256 usdcBalanceAfter = ERC20(USDC).balanceOf(_plasmaVault);

        assertApproxEqAbs(amount0Collect, 1000000000, 1e6, "amount0Collect");
        assertApproxEqAbs(amount1Collect, 0, 1e6, "amount1Collect");

        assertApproxEqAbs(marketBalanceBefore, 1000000000, 1e6, "marketBalanceBefore");
        assertApproxEqAbs(marketBalanceAfter, 0, 1e6, "marketBalanceAfter");

        assertApproxEqAbs(erc20BalanceBefore, 9999319143, 1e6, "erc20BalanceBefore");
        assertApproxEqAbs(erc20BalanceAfter, 9999319143, 1e6, "erc20BalanceAfter");

        assertApproxEqAbs(usdcBalanceBefore, 9000000000, 1e6, "usdcBalanceBefore");
        assertApproxEqAbs(usdcBalanceAfter, 9999999999, 1e6, "usdcBalanceAfter");
    }

    function testShouldCRemovePosition() external {
        // given
        RamsesV2NewPositionFuseEnterData memory mintParams = RamsesV2NewPositionFuseEnterData({
            token0: USDC,
            token1: USDT,
            fee: 100,
            tickLower: 100,
            tickUpper: 1000,
            amount0Desired: 1_000e6,
            amount1Desired: 1_000e6,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 100,
            veRamTokenId: 0
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_ramsesV2NewPositionFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,uint256,uint256))",
                mintParams
            )
        );

        vm.recordLogs();
        PlasmaVault(_plasmaVault).execute(enterCalls);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        (, uint256 tokenIdMintPosition, uint128 liquidity, , ) = _extractMarketIdsFromEvent(entries);

        RamsesV2ModifyPositionFuseExitData memory exitDataDecrease = RamsesV2ModifyPositionFuseExitData({
            tokenId: tokenIdMintPosition,
            liquidity: liquidity,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 100000
        });

        FuseAction[] memory exitCallsIncrease = new FuseAction[](1);

        exitCallsIncrease[0] = FuseAction(
            address(_ramsesV2ModifyPositionFuse),
            abi.encodeWithSignature("exit((uint256,uint128,uint256,uint256,uint256))", exitDataDecrease)
        );
        PlasmaVault(_plasmaVault).execute(exitCallsIncrease);

        RamsesV2CollectFuseEnterData memory collectFeesData;
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenIdMintPosition;
        collectFeesData.tokenIds = tokenIds;

        FuseAction[] memory enterCollect = new FuseAction[](1);
        enterCollect[0] = FuseAction(
            address(_ramsesV2CollectFuse),
            abi.encodeWithSignature("enter((uint256[]))", collectFeesData)
        );

        PlasmaVault(_plasmaVault).execute(enterCollect);

        RamsesV2NewPositionFuseExitData memory closePositions;
        closePositions.tokenIds = tokenIds;

        enterCalls[0] = FuseAction(
            address(_ramsesV2NewPositionFuse),
            abi.encodeWithSignature("exit((uint256[]))", closePositions)
        );

        // when
        PlasmaVault(_plasmaVault).execute(enterCalls);
        Vm.Log[] memory entriesClosePosition = vm.getRecordedLogs();

        // then
        (, uint256 closeTokenId) = _extractClosePositionFromEvent(entriesClosePosition);

        assertEq(tokenIdMintPosition, closeTokenId, "tokenIdMintPosition = closeTokenId");
    }

    function _setupFeeConfig() private view returns (FeeConfig memory feeConfig_) {
        feeConfig_ = FeeConfig({
            performanceFeeManager: address(this),
            performanceFeeInPercentage: 0,
            managementFeeManager: address(this),
            managementFeeInPercentage: 0
        });
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
        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, _plasmaVault, IporFusionAccessManager(_accessManager));
    }

    function _setupMarketConfigs() private returns (MarketSubstratesConfig[] memory marketConfigs_) {
        marketConfigs_ = new MarketSubstratesConfig[](2);

        bytes32[] memory ramsesTokens = new bytes32[](3);
        ramsesTokens[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);
        ramsesTokens[1] = PlasmaVaultConfigLib.addressToBytes32(USDT);
        ramsesTokens[2] = PlasmaVaultConfigLib.addressToBytes32(DAI);

        marketConfigs_[0] = MarketSubstratesConfig(IporFusionMarkets.RAMSES_V2_POSITIONS, ramsesTokens);
        marketConfigs_[1] = MarketSubstratesConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, ramsesTokens);
    }

    function _setupFuses() private returns (address[] memory fuses) {
        _ramsesV2NewPositionFuse = new RamsesV2NewPositionFuse(
            IporFusionMarkets.RAMSES_V2_POSITIONS,
            _NONFUNGIBLE_POSITION_MANAGER
        );

        _ramsesV2ModifyPositionFuse = new RamsesV2ModifyPositionFuse(
            IporFusionMarkets.RAMSES_V2_POSITIONS,
            _NONFUNGIBLE_POSITION_MANAGER
        );

        _ramsesV2CollectFuse = new RamsesV2CollectFuse(
            IporFusionMarkets.RAMSES_V2_POSITIONS,
            _NONFUNGIBLE_POSITION_MANAGER
        );

        fuses = new address[](3);
        fuses[0] = address(_ramsesV2NewPositionFuse);
        fuses[1] = address(_ramsesV2ModifyPositionFuse);
        fuses[2] = address(_ramsesV2CollectFuse);
    }

    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses_) {
        RamsesV2Balance ramsesBalance = new RamsesV2Balance(
            IporFusionMarkets.RAMSES_V2_POSITIONS,
            _NONFUNGIBLE_POSITION_MANAGER,
            _RAMSES_FACTORY
        );
        ERC20BalanceFuse erc20Balance = new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE);

        balanceFuses_ = new MarketBalanceFuseConfig[](2);
        balanceFuses_[0] = MarketBalanceFuseConfig(IporFusionMarkets.RAMSES_V2_POSITIONS, address(ramsesBalance));
        balanceFuses_[1] = MarketBalanceFuseConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, address(erc20Balance));
    }

    function _setupDependenceBalance() private {
        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.RAMSES_V2_POSITIONS;

        uint256[] memory dependence = new uint256[](1);
        dependence[0] = IporFusionMarkets.ERC20_VAULT_BALANCE;

        uint256[][] memory dependenceMarkets = new uint256[][](1);
        dependenceMarkets[0] = dependence;

        PlasmaVaultGovernance(_plasmaVault).updateDependencyBalanceGraphs(marketIds, dependenceMarkets);
    }

    function _extractMarketIdsFromEvent(
        Vm.Log[] memory entries
    ) private view returns (address version, uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        for (uint256 i = 0; i < entries.length; i++) {
            if (
                entries[i].topics[0] ==
                keccak256(
                    "RamsesV2NewPositionFuseEnter(address,uint256,uint128,uint256,uint256,address,address,uint24,int24,int24)"
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
                keccak256("RamsesV2ModifyPositionFuseEnter(address,uint256,uint128,uint256,uint256)")
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
            if (entries[i].topics[0] == keccak256("RamsesV2ModifyPositionFuseExit(address,uint256,uint256,uint256)")) {
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
            if (entries[i].topics[0] == keccak256("RamsesV2CollectFuseEnter(address,uint256,uint256,uint256)")) {
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
            if (entries[i].topics[0] == keccak256("RamsesV2NewPositionFuseExit(address,uint256)")) {
                (version, tokenId) = abi.decode(entries[i].data, (address, uint256));
                break;
            }
        }
    }
}
