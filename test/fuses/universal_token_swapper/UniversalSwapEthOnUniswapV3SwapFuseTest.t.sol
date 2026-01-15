// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig, FeeConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {FuseAction, PlasmaVault, PlasmaVaultInitData} from "../../../contracts/vaults/PlasmaVault.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";

import {RoleLib, UsersToRoles} from "../../RoleLib.sol";

import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {ZeroBalanceFuse} from "../../../contracts/fuses/ZeroBalanceFuse.sol";

import {SwapExecutorEth, SwapExecutorEthData} from "../../../contracts/fuses/universal_token_swapper/SwapExecutorEth.sol";
import {UniversalTokenSwapperEthFuse, UniversalTokenSwapperEthEnterData, UniversalTokenSwapperEthData} from "../../../contracts/fuses/universal_token_swapper/UniversalTokenSwapperEthFuse.sol";
import {UniversalTokenSwapperSubstrateLib} from "../../../contracts/fuses/universal_token_swapper/UniversalTokenSwapperSubstrateLib.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {PlasmaVaultConfigurator} from "../../utils/PlasmaVaultConfigurator.sol";

contract UniversalSwapEthOnUniswapV3SwapFuseTest is Test {
    using SafeERC20 for ERC20;

    event MarketBalancesUpdated(uint256[] marketIds, int256 deltaInUnderlying);

    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address private constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address private constant W_ETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address private constant ETHX = 0xA35b1B31Ce002FBF2058D22F30f95D405200A15b;
    address private constant STADER_STAKING_POOL_MANAGER = 0xcf5EA1b38380f6aF39068375516Daf40Ed70D299;

    address private constant FRXETH = 0x5E8422345238F34275888049021821E8E08CAa1f;
    address private constant SFRXETH = 0xac3E018457B222d93114458476f3E3416Abbe38F;
    address private constant FRAX_ETHER_MINTER_V2_ADDRESS = 0x7Bc6bad540453360F744666D625fec0ee1320cA3;

    address private constant RETH = 0xae78736Cd615f374D3085123A210448E74Fc6393;
    address private constant ROCKET_DEPOSIT_POOL_ADDRESS = 0xDD3f50F8A6CafbE9b31a427582963f465E745AF8;

    address private constant _UNIVERSAL_ROUTER = 0xEf1c6E67703c7BD7107eed8303Fbe6EC2554BF6B;

    address private _plasmaVault;
    address private _priceOracle;
    address private _accessManager;
    address private _withdrawManager;
    SwapExecutorEth private _swapExecutorEth;

    UniversalTokenSwapperEthFuse private _universalTokenSwapperFuse;

    ///@dev this value is from the UniversalRouter contract https://github.com/Uniswap/universal-router/blob/main/contracts/libraries/Commands.sol
    uint256 private constant _V3_SWAP_EXACT_IN = 0x00;
    address private constant _INDICATOR_OF_SENDER_FROM_UNIVERSAL_ROUTER = address(1);

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 22266405);

        address[] memory alphas = new address[](1);
        alphas[0] = address(this);

        // price oracle
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf);
        _priceOracle = address(
            new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
        );

        // only for test purposes
        address[] memory assets = new address[](6);
        assets[0] = W_ETH;
        assets[1] = STETH;
        assets[2] = ETHX;
        assets[3] = FRXETH;
        assets[4] = SFRXETH;
        assets[5] = RETH;
        address[] memory sources = new address[](6);
        sources[0] = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
        sources[1] = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
        sources[2] = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
        sources[3] = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
        sources[4] = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
        sources[5] = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
        PriceOracleMiddleware(_priceOracle).setAssetsPricesSources(assets, sources);

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
                _createWithdrawManager()
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
    }

    function testShouldSwapWhenOneHop() external {
        // given

        address userOne = address(0x1222);
        uint256 depositAmount = 1_000e6;

        vm.prank(0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341);
        ERC20(USDC).transfer(userOne, 10_000e6);

        vm.prank(userOne);
        ERC20(USDC).approve(_plasmaVault, depositAmount);
        vm.prank(userOne);
        PlasmaVault(_plasmaVault).deposit(depositAmount, userOne);

        bytes memory path = abi.encodePacked(USDC, uint24(3000), USDT);

        address[] memory targets = new address[](2);
        targets[0] = USDC;
        targets[1] = _UNIVERSAL_ROUTER;

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(_INDICATOR_OF_SENDER_FROM_UNIVERSAL_ROUTER, depositAmount, 0, path, false);

        bytes[] memory callDatas = new bytes[](2);
        callDatas[0] = abi.encodeWithSignature("transfer(address,uint256)", _UNIVERSAL_ROUTER, depositAmount);
        callDatas[1] = abi.encodeWithSignature(
            "execute(bytes,bytes[])",
            abi.encodePacked(bytes1(uint8(_V3_SWAP_EXACT_IN))),
            inputs
        );

        uint256[] memory ethAmounts = new uint256[](2);
        address[] memory dustToCheck = new address[](0);

        UniversalTokenSwapperEthEnterData memory enterData = UniversalTokenSwapperEthEnterData({
            tokenIn: USDC,
            tokenOut: USDT,
            amountIn: depositAmount,
            minAmountOut: 0,
            data: UniversalTokenSwapperEthData({
                targets: targets,
                callDatas: callDatas,
                ethAmounts: ethAmounts,
                tokensDustToCheck: dustToCheck
            })
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_universalTokenSwapperFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint256,uint256,(address[],bytes[],uint256[],address[])))",
                enterData
            )
        );

        uint256 plasmaVaultUsdcBalanceBefore = ERC20(USDC).balanceOf(_plasmaVault);
        uint256 plasmaVaultUsdtBalanceBefore = ERC20(USDT).balanceOf(_plasmaVault);

        //when
        PlasmaVault(_plasmaVault).execute(enterCalls);

        // then
        uint256 plasmaVaultUsdcBalanceAfter = ERC20(USDC).balanceOf(_plasmaVault);
        uint256 plasmaVaultUsdtBalanceAfter = ERC20(USDT).balanceOf(_plasmaVault);

        assertEq(plasmaVaultUsdcBalanceBefore, depositAmount, "plasmaVaultUsdcBalanceBefore");
        assertEq(plasmaVaultUsdcBalanceAfter, 0, "plasmaVaultUsdcBalanceAfter");
        assertEq(plasmaVaultUsdtBalanceBefore, 0, "plasmaVaultUsdtBalanceBefore");
        assertGt(plasmaVaultUsdtBalanceAfter, 0, "plasmaVaultUsdtBalanceAfter");
    }

    function testShouldStakeEthToSteth() external {
        // given

        address userOne = address(0x1222);
        uint256 depositAmount = 1_000e6;

        vm.prank(0xe9172Daf64b05B26eb18f07aC8d6D723aCB48f99);
        ERC20(USDC).transfer(userOne, 10_000e6);

        vm.prank(userOne);
        ERC20(USDC).approve(_plasmaVault, depositAmount);
        vm.prank(userOne);
        PlasmaVault(_plasmaVault).deposit(depositAmount, userOne);

        deal(W_ETH, address(this), 100 ether);

        ERC20(W_ETH).transfer(_plasmaVault, 50 ether);

        address[] memory targets = new address[](2);
        targets[0] = W_ETH;
        targets[1] = STETH;

        bytes[] memory callDatas = new bytes[](2);
        callDatas[0] = abi.encodeWithSignature("withdraw(uint256)", 10 ether);
        callDatas[1] = abi.encodeWithSignature("submit(address)", address(this));

        uint256[] memory ethAmounts = new uint256[](2);
        ethAmounts[0] = 0;
        ethAmounts[1] = 10 ether;

        address[] memory dustToCheck = new address[](1);
        dustToCheck[0] = STETH;

        UniversalTokenSwapperEthEnterData memory enterData = UniversalTokenSwapperEthEnterData({
            tokenIn: W_ETH,
            tokenOut: STETH,
            amountIn: 10 ether,
            minAmountOut: 0,
            data: UniversalTokenSwapperEthData({
                targets: targets,
                callDatas: callDatas,
                ethAmounts: ethAmounts,
                tokensDustToCheck: dustToCheck
            })
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_universalTokenSwapperFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint256,uint256,(address[],bytes[],uint256[],address[])))",
                enterData
            )
        );

        uint256 balanceStethBefore = ERC20(STETH).balanceOf(_plasmaVault);

        uint256 balanceWethBefore = ERC20(W_ETH).balanceOf(_plasmaVault);

        // when

        PlasmaVault(_plasmaVault).execute(enterCalls);
        // then

        uint256 balanceStethAfter = ERC20(STETH).balanceOf(_plasmaVault);
        assertApproxEqAbs(0, balanceStethBefore, 100);
        assertApproxEqAbs(10000000000000000000, balanceStethAfter, 100);

        uint256 balanceWethAfter = ERC20(W_ETH).balanceOf(_plasmaVault);
        assertApproxEqAbs(uint256(50 ether), balanceWethBefore, 100);
        assertApproxEqAbs(uint256(40 ether), balanceWethAfter, 100);
    }

    function testShouldStakeEthToETHx() external {
        // given
        address userOne = address(0x1222);
        uint256 depositAmount = 1_000e6;

        vm.prank(0xe9172Daf64b05B26eb18f07aC8d6D723aCB48f99);
        ERC20(USDC).transfer(userOne, 10_000e6);

        vm.prank(userOne);
        ERC20(USDC).approve(_plasmaVault, depositAmount);
        vm.prank(userOne);
        PlasmaVault(_plasmaVault).deposit(depositAmount, userOne);

        deal(W_ETH, address(this), 100 ether);

        ERC20(W_ETH).transfer(_plasmaVault, 50 ether);

        uint256 balanceWethBefore = ERC20(W_ETH).balanceOf(_plasmaVault);

        address[] memory targets = new address[](2);
        targets[0] = W_ETH;
        targets[1] = STADER_STAKING_POOL_MANAGER;

        bytes[] memory callDatas = new bytes[](2);
        callDatas[0] = abi.encodeWithSignature("withdraw(uint256)", 10 ether);
        callDatas[1] = abi.encodeWithSignature("deposit(address)", _plasmaVault);

        uint256[] memory ethAmounts = new uint256[](2);
        ethAmounts[0] = 0;
        ethAmounts[1] = 10 ether;

        address[] memory dustToCheck = new address[](1);
        dustToCheck[0] = ETHX;

        UniversalTokenSwapperEthEnterData memory enterData = UniversalTokenSwapperEthEnterData({
            tokenIn: W_ETH,
            tokenOut: ETHX,
            amountIn: 10 ether,
            minAmountOut: 0,
            data: UniversalTokenSwapperEthData({
                targets: targets,
                callDatas: callDatas,
                ethAmounts: ethAmounts,
                tokensDustToCheck: dustToCheck
            })
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_universalTokenSwapperFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint256,uint256,(address[],bytes[],uint256[],address[])))",
                enterData
            )
        );

        uint256 balanceEthxBefore = ERC20(ETHX).balanceOf(_plasmaVault);

        // when

        PlasmaVault(_plasmaVault).execute(enterCalls);
        // then

        uint256 balanceEthxAfter = ERC20(ETHX).balanceOf(_plasmaVault);
        assertApproxEqAbs(0, balanceEthxBefore, 100);
        assertApproxEqAbs(9452965376709245746, balanceEthxAfter, 100);

        uint256 balanceWethAfter = ERC20(W_ETH).balanceOf(_plasmaVault);
        assertApproxEqAbs(uint256(50 ether), balanceWethBefore, 100);
        assertApproxEqAbs(uint256(40 ether), balanceWethAfter, 100);
    }

    function testShouldStakeEthToFRXETH() external {
        // given

        address userOne = address(0x1222);
        uint256 depositAmount = 1_000e6;

        vm.prank(0xe9172Daf64b05B26eb18f07aC8d6D723aCB48f99);
        ERC20(USDC).transfer(userOne, 10_000e6);

        vm.prank(userOne);
        ERC20(USDC).approve(_plasmaVault, depositAmount);
        vm.prank(userOne);
        PlasmaVault(_plasmaVault).deposit(depositAmount, userOne);

        deal(W_ETH, address(this), 100 ether);

        ERC20(W_ETH).transfer(_plasmaVault, 50 ether);

        address[] memory targets = new address[](2);
        targets[0] = W_ETH;
        targets[1] = FRAX_ETHER_MINTER_V2_ADDRESS;

        bytes[] memory callDatas = new bytes[](2);
        callDatas[0] = abi.encodeWithSignature("withdraw(uint256)", 10 ether);
        callDatas[1] = abi.encodeWithSignature("submitAndDeposit(address)", _swapExecutorEth);

        uint256[] memory ethAmounts = new uint256[](2);
        ethAmounts[0] = 0;
        ethAmounts[1] = 10 ether;

        address[] memory dustToCheck = new address[](1);
        dustToCheck[0] = SFRXETH;

        UniversalTokenSwapperEthEnterData memory enterData = UniversalTokenSwapperEthEnterData({
            tokenIn: W_ETH,
            tokenOut: SFRXETH,
            amountIn: 10 ether,
            minAmountOut: 0,
            data: UniversalTokenSwapperEthData({
                targets: targets,
                callDatas: callDatas,
                ethAmounts: ethAmounts,
                tokensDustToCheck: dustToCheck
            })
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_universalTokenSwapperFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint256,uint256,(address[],bytes[],uint256[],address[])))",
                enterData
            )
        );

        uint256 balanceFrxethBefore = ERC20(SFRXETH).balanceOf(_plasmaVault);

        uint256 balanceWethBefore = ERC20(W_ETH).balanceOf(_plasmaVault);

        // when

        PlasmaVault(_plasmaVault).execute(enterCalls);
        // then

        uint256 balanceFrxethAfter = ERC20(SFRXETH).balanceOf(_plasmaVault);
        assertApproxEqAbs(uint256(0), balanceFrxethBefore, 100);
        assertApproxEqAbs(8932488782338790225, balanceFrxethAfter, 100);

        uint256 balanceWethAfter = ERC20(W_ETH).balanceOf(_plasmaVault);
        assertApproxEqAbs(uint256(50 ether), balanceWethBefore, 100);
        assertApproxEqAbs(uint256(40 ether), balanceWethAfter, 100);
    }

    function testShouldStakeEthToRETH() external {
        // given
        address userOne = address(0x1222);
        uint256 depositAmount = 1_000e6;

        vm.prank(0xe9172Daf64b05B26eb18f07aC8d6D723aCB48f99);
        ERC20(USDC).transfer(userOne, 10_000e6);

        vm.prank(userOne);
        ERC20(USDC).approve(_plasmaVault, depositAmount);
        vm.prank(userOne);
        PlasmaVault(_plasmaVault).deposit(depositAmount, userOne);

        deal(W_ETH, address(this), 100 ether);

        ERC20(W_ETH).transfer(_plasmaVault, 50 ether);

        address[] memory targets = new address[](2);
        targets[0] = W_ETH;
        targets[1] = ROCKET_DEPOSIT_POOL_ADDRESS;

        bytes[] memory callDatas = new bytes[](2);
        callDatas[0] = abi.encodeWithSignature("withdraw(uint256)", 10 ether);
        callDatas[1] = abi.encodeWithSignature("deposit()");

        uint256[] memory ethAmounts = new uint256[](2);
        ethAmounts[0] = 0;
        ethAmounts[1] = 10 ether;

        address[] memory dustToCheck = new address[](1);
        dustToCheck[0] = RETH;

        UniversalTokenSwapperEthEnterData memory enterData = UniversalTokenSwapperEthEnterData({
            tokenIn: W_ETH,
            tokenOut: RETH,
            amountIn: 10 ether,
            minAmountOut: 0,
            data: UniversalTokenSwapperEthData({
                targets: targets,
                callDatas: callDatas,
                ethAmounts: ethAmounts,
                tokensDustToCheck: dustToCheck
            })
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_universalTokenSwapperFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint256,uint256,(address[],bytes[],uint256[],address[])))",
                enterData
            )
        );

        uint256 balanceRethBefore = ERC20(RETH).balanceOf(_plasmaVault);

        uint256 balanceWethBefore = ERC20(W_ETH).balanceOf(_plasmaVault);

        // when

        PlasmaVault(_plasmaVault).execute(enterCalls);
        // then

        uint256 balanceRethAfter = ERC20(RETH).balanceOf(_plasmaVault);
        assertApproxEqAbs(uint256(0), balanceRethBefore, 100);
        assertApproxEqAbs(8815433984066101757, balanceRethAfter, 100);

        uint256 balanceWethAfter = ERC20(W_ETH).balanceOf(_plasmaVault);
        assertApproxEqAbs(uint256(50 ether), balanceWethBefore, 100);
        assertApproxEqAbs(uint256(40 ether), balanceWethAfter, 100);
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

    function _createWithdrawManager() private returns (address withdrawManager_) {
        withdrawManager_ = address(new WithdrawManager(address(_accessManager)));
        _withdrawManager = withdrawManager_;
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

        // Using new substrate encoding format with Token and Target types
        bytes32[] memory universalSwapSubstrates = new bytes32[](20);
        // Token substrates
        universalSwapSubstrates[0] = UniversalTokenSwapperSubstrateLib.encodeTokenSubstrate(USDC);
        universalSwapSubstrates[1] = UniversalTokenSwapperSubstrateLib.encodeTokenSubstrate(USDT);
        universalSwapSubstrates[2] = UniversalTokenSwapperSubstrateLib.encodeTokenSubstrate(DAI);
        universalSwapSubstrates[3] = UniversalTokenSwapperSubstrateLib.encodeTokenSubstrate(STETH);
        universalSwapSubstrates[4] = UniversalTokenSwapperSubstrateLib.encodeTokenSubstrate(W_ETH);
        universalSwapSubstrates[5] = UniversalTokenSwapperSubstrateLib.encodeTokenSubstrate(ETHX);
        universalSwapSubstrates[6] = UniversalTokenSwapperSubstrateLib.encodeTokenSubstrate(FRXETH);
        universalSwapSubstrates[7] = UniversalTokenSwapperSubstrateLib.encodeTokenSubstrate(SFRXETH);
        universalSwapSubstrates[8] = UniversalTokenSwapperSubstrateLib.encodeTokenSubstrate(RETH);
        // Target substrates
        universalSwapSubstrates[9] = UniversalTokenSwapperSubstrateLib.encodeTargetSubstrate(_UNIVERSAL_ROUTER);
        universalSwapSubstrates[10] = UniversalTokenSwapperSubstrateLib.encodeTargetSubstrate(STETH);
        universalSwapSubstrates[11] = UniversalTokenSwapperSubstrateLib.encodeTargetSubstrate(W_ETH);
        universalSwapSubstrates[12] = UniversalTokenSwapperSubstrateLib.encodeTargetSubstrate(USDC);
        universalSwapSubstrates[13] = UniversalTokenSwapperSubstrateLib.encodeTargetSubstrate(STADER_STAKING_POOL_MANAGER);
        universalSwapSubstrates[14] = UniversalTokenSwapperSubstrateLib.encodeTargetSubstrate(FRAX_ETHER_MINTER_V2_ADDRESS);
        universalSwapSubstrates[15] = UniversalTokenSwapperSubstrateLib.encodeTargetSubstrate(ROCKET_DEPOSIT_POOL_ADDRESS);
        // Slippage substrate - using 100% slippage for testing (same as original 1e18)
        universalSwapSubstrates[16] = UniversalTokenSwapperSubstrateLib.encodeSlippageSubstrate(1e18);
        // Unused slots can be zero
        universalSwapSubstrates[17] = bytes32(0);
        universalSwapSubstrates[18] = bytes32(0);
        universalSwapSubstrates[19] = bytes32(0);

        marketConfigs_[0] = MarketSubstratesConfig(IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER, universalSwapSubstrates);
    }

    function _setupFuses() private returns (address[] memory fuses_) {
        _universalTokenSwapperFuse = new UniversalTokenSwapperEthFuse(
            IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER,
            W_ETH
        );
        _swapExecutorEth = SwapExecutorEth(_universalTokenSwapperFuse.EXECUTOR());

        fuses_ = new address[](1);
        fuses_[0] = address(_universalTokenSwapperFuse);
    }

    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses_) {
        // @Dev this setup is ignored for tests
        ZeroBalanceFuse zeroBalance = new ZeroBalanceFuse(IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER);

        balanceFuses_ = new MarketBalanceFuseConfig[](1);
        balanceFuses_[0] = MarketBalanceFuseConfig(IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER, address(zeroBalance));
    }
}
