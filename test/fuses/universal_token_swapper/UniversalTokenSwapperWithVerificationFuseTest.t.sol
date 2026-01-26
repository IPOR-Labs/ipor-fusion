// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

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
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";

import {SwapExecutorEth, SwapExecutorEthData} from "../../../contracts/fuses/universal_token_swapper/SwapExecutorEth.sol";
import {UniversalTokenSwapperWithVerificationFuse, UniversalTokenSwapperWithVerificationEnterData, UniversalTokenSwapperWithVerificationData, UniversalTokenSwapperSubstrate} from "../../../contracts/fuses/universal_token_swapper/UniversalTokenSwapperWithVerificationFuse.sol";
import {TransientStorageSetInputsFuse, TransientStorageSetInputsFuseEnterData} from "../../../contracts/fuses/transient_storage/TransientStorageSetInputsFuse.sol";
import {TypeConversionLib} from "../../../contracts/libraries/TypeConversionLib.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {PlasmaVaultConfigurator} from "../../utils/PlasmaVaultConfigurator.sol";

contract UniversalTokenSwapperWithVerificationFuseTest is Test {
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
    address private _executor;

    UniversalTokenSwapperWithVerificationFuse private _universalTokenSwapperFuse;
    address private _transientStorageSetInputsFuse;

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

        _createAccessManager();
        WithdrawManager withdrawManager = new WithdrawManager(_accessManager);

        // plasma vault
        _plasmaVault = address(new PlasmaVault());
        PlasmaVault(_plasmaVault).proxyInitialize(
            PlasmaVaultInitData(
                "TEST PLASMA VAULT",
                "pvUSDC",
                USDC,
                _priceOracle,
                _setupFeeConfig(),
                _accessManager,
                address(new PlasmaVaultBase()),
                address(0),
                address(withdrawManager)
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
        _setupRoles(address(withdrawManager));
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

        UniversalTokenSwapperWithVerificationEnterData
            memory enterData = UniversalTokenSwapperWithVerificationEnterData({
                tokenIn: USDC,
                tokenOut: USDT,
                amountIn: depositAmount,
                data: UniversalTokenSwapperWithVerificationData({
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
                "enter((address,address,uint256,(address[],bytes[],uint256[],address[])))",
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

        UniversalTokenSwapperWithVerificationEnterData
            memory enterData = UniversalTokenSwapperWithVerificationEnterData({
                tokenIn: W_ETH,
                tokenOut: STETH,
                amountIn: 10 ether,
                data: UniversalTokenSwapperWithVerificationData({
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
                "enter((address,address,uint256,(address[],bytes[],uint256[],address[])))",
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

        UniversalTokenSwapperWithVerificationEnterData
            memory enterData = UniversalTokenSwapperWithVerificationEnterData({
                tokenIn: W_ETH,
                tokenOut: ETHX,
                amountIn: 10 ether,
                data: UniversalTokenSwapperWithVerificationData({
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
                "enter((address,address,uint256,(address[],bytes[],uint256[],address[])))",
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
        callDatas[1] = abi.encodeWithSignature("submitAndDeposit(address)", _executor);

        uint256[] memory ethAmounts = new uint256[](2);
        ethAmounts[0] = 0;
        ethAmounts[1] = 10 ether;

        address[] memory dustToCheck = new address[](1);
        dustToCheck[0] = SFRXETH;

        UniversalTokenSwapperWithVerificationEnterData
            memory enterData = UniversalTokenSwapperWithVerificationEnterData({
                tokenIn: W_ETH,
                tokenOut: SFRXETH,
                amountIn: 10 ether,
                data: UniversalTokenSwapperWithVerificationData({
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
                "enter((address,address,uint256,(address[],bytes[],uint256[],address[])))",
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

    function testShouldNotStakeEthToRETH() external {
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

        UniversalTokenSwapperWithVerificationEnterData
            memory enterData = UniversalTokenSwapperWithVerificationEnterData({
                tokenIn: W_ETH,
                tokenOut: RETH,
                amountIn: 10 ether,
                data: UniversalTokenSwapperWithVerificationData({
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
                "enter((address,address,uint256,(address[],bytes[],uint256[],address[])))",
                enterData
            )
        );

        // when
        vm.expectRevert(
            abi.encodeWithSelector(
                UniversalTokenSwapperWithVerificationFuse.UniversalTokenSwapperFuseUnsupportedAsset.selector,
                ROCKET_DEPOSIT_POOL_ADDRESS
            )
        );
        PlasmaVault(_plasmaVault).execute(enterCalls);
    }

    function testShouldEnterUsingTransient() external {
        // given
        address userOne = address(0x1222);
        uint256 depositAmount = 1_000e6;

        vm.prank(0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341);
        ERC20(USDC).transfer(userOne, 10_000e6);

        vm.prank(userOne);
        ERC20(USDC).approve(_plasmaVault, depositAmount);
        vm.prank(userOne);
        PlasmaVault(_plasmaVault).deposit(depositAmount, userOne);

        bytes32[][] memory inputsByFuse;
        {
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

            // Calculate total inputs count dynamically
            uint256 totalInputs = 4 + targets.length + 1; // tokenIn, tokenOut, amountIn, targetsLength, targets[], callDatasLength
            for (uint256 i; i < callDatas.length; ++i) {
                totalInputs += 1 + (callDatas[i].length + 31) / 32; // length + chunks for each callData
            }
            totalInputs += 1 + ethAmounts.length + 1 + dustToCheck.length; // ethAmountsLength, ethAmounts[], tokensDustToCheckLength, tokensDustToCheck[]

            inputsByFuse = new bytes32[][](1);
            inputsByFuse[0] = new bytes32[](totalInputs);

            uint256 inputIndex = 0;
            inputsByFuse[0][inputIndex++] = TypeConversionLib.toBytes32(USDC);
            inputsByFuse[0][inputIndex++] = TypeConversionLib.toBytes32(USDT);
            inputsByFuse[0][inputIndex++] = TypeConversionLib.toBytes32(depositAmount);
            inputsByFuse[0][inputIndex++] = TypeConversionLib.toBytes32(targets.length);
            for (uint256 i; i < targets.length; ++i) {
                inputsByFuse[0][inputIndex++] = TypeConversionLib.toBytes32(targets[i]);
            }
            inputsByFuse[0][inputIndex++] = TypeConversionLib.toBytes32(callDatas.length);
            for (uint256 i; i < callDatas.length; ++i) {
                bytes memory callData = callDatas[i];
                uint256 dataLen = callData.length;
                inputsByFuse[0][inputIndex++] = TypeConversionLib.toBytes32(dataLen);
                uint256 chunksCount = (dataLen + 31) / 32;
                for (uint256 j; j < chunksCount; ++j) {
                    bytes32 chunk;
                    assembly {
                        chunk := mload(add(add(callData, 0x20), mul(j, 32)))
                    }
                    inputsByFuse[0][inputIndex++] = chunk;
                }
            }
            inputsByFuse[0][inputIndex++] = TypeConversionLib.toBytes32(ethAmounts.length);
            for (uint256 i; i < ethAmounts.length; ++i) {
                inputsByFuse[0][inputIndex++] = TypeConversionLib.toBytes32(ethAmounts[i]);
            }
            inputsByFuse[0][inputIndex++] = TypeConversionLib.toBytes32(dustToCheck.length);
            for (uint256 i; i < dustToCheck.length; ++i) {
                inputsByFuse[0][inputIndex++] = TypeConversionLib.toBytes32(dustToCheck[i]);
            }
        }

        // when
        uint256 plasmaVaultUsdcBalanceBefore = ERC20(USDC).balanceOf(_plasmaVault);
        uint256 plasmaVaultUsdtBalanceBefore = ERC20(USDT).balanceOf(_plasmaVault);

        address[] memory fusesToSet = new address[](1);
        fusesToSet[0] = address(_universalTokenSwapperFuse);

        FuseAction[] memory calls = new FuseAction[](2);
        calls[0] = FuseAction(
            _transientStorageSetInputsFuse,
            abi.encodeWithSignature(
                "enter((address[],bytes32[][]))",
                TransientStorageSetInputsFuseEnterData({fuse: fusesToSet, inputsByFuse: inputsByFuse})
            )
        );
        calls[1] = FuseAction(address(_universalTokenSwapperFuse), abi.encodeWithSignature("enterTransient()"));

        PlasmaVault(_plasmaVault).execute(calls);

        // then
        assertEq(plasmaVaultUsdcBalanceBefore, depositAmount, "plasmaVaultUsdcBalanceBefore");
        assertEq(ERC20(USDC).balanceOf(_plasmaVault), 0, "plasmaVaultUsdcBalanceAfter");
        assertEq(plasmaVaultUsdtBalanceBefore, 0, "plasmaVaultUsdtBalanceBefore");
        assertGt(ERC20(USDT).balanceOf(_plasmaVault), 0, "plasmaVaultUsdtBalanceAfter");
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

    function _setupRoles(address withdrawManager) private {
        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = address(this);
        usersToRoles.atomist = address(this);
        RoleLib.setupPlasmaVaultRoles(
            usersToRoles,
            vm,
            _plasmaVault,
            IporFusionAccessManager(_accessManager),
            withdrawManager
        );
    }

    function _setupMarketConfigs() private returns (MarketSubstratesConfig[] memory marketConfigs_) {
        marketConfigs_ = new MarketSubstratesConfig[](1);

        bytes32[] memory universalSwapTokens = new bytes32[](19);
        universalSwapTokens[0] = toBytes32(UniversalTokenSwapperSubstrate({functionSelector: bytes4(0), target: USDC}));
        universalSwapTokens[13] = toBytes32(
            UniversalTokenSwapperSubstrate({functionSelector: ERC20.transfer.selector, target: USDC})
        );
        universalSwapTokens[1] = toBytes32(UniversalTokenSwapperSubstrate({functionSelector: bytes4(0), target: USDT}));
        universalSwapTokens[2] = toBytes32(UniversalTokenSwapperSubstrate({functionSelector: bytes4(0), target: DAI}));
        universalSwapTokens[3] = toBytes32(
            UniversalTokenSwapperSubstrate({functionSelector: bytes4(0), target: _UNIVERSAL_ROUTER})
        );
        universalSwapTokens[14] = toBytes32(
            UniversalTokenSwapperSubstrate({functionSelector: bytes4(0x24856bc3), target: _UNIVERSAL_ROUTER})
        );
        universalSwapTokens[4] = toBytes32(
            UniversalTokenSwapperSubstrate({functionSelector: bytes4(0), target: STETH})
        );
        universalSwapTokens[16] = toBytes32(
            UniversalTokenSwapperSubstrate({functionSelector: bytes4(0xa1903eab), target: STETH})
        );
        universalSwapTokens[5] = toBytes32(
            UniversalTokenSwapperSubstrate({functionSelector: bytes4(0), target: W_ETH})
        );
        universalSwapTokens[15] = toBytes32(
            UniversalTokenSwapperSubstrate({functionSelector: bytes4(0x2e1a7d4d), target: W_ETH})
        );
        universalSwapTokens[6] = toBytes32(UniversalTokenSwapperSubstrate({functionSelector: bytes4(0), target: ETHX}));
        universalSwapTokens[7] = toBytes32(
            UniversalTokenSwapperSubstrate({functionSelector: bytes4(0), target: STADER_STAKING_POOL_MANAGER})
        );
        universalSwapTokens[17] = toBytes32(
            UniversalTokenSwapperSubstrate({functionSelector: bytes4(0xf340fa01), target: STADER_STAKING_POOL_MANAGER})
        );
        universalSwapTokens[8] = toBytes32(
            UniversalTokenSwapperSubstrate({functionSelector: bytes4(0), target: FRXETH})
        );
        universalSwapTokens[9] = toBytes32(
            UniversalTokenSwapperSubstrate({functionSelector: bytes4(0), target: FRAX_ETHER_MINTER_V2_ADDRESS})
        );
        universalSwapTokens[18] = toBytes32(
            UniversalTokenSwapperSubstrate({functionSelector: bytes4(0x4dcd4547), target: FRAX_ETHER_MINTER_V2_ADDRESS})
        );
        universalSwapTokens[10] = toBytes32(
            UniversalTokenSwapperSubstrate({functionSelector: bytes4(0), target: SFRXETH})
        );
        universalSwapTokens[11] = toBytes32(
            UniversalTokenSwapperSubstrate({functionSelector: bytes4(0), target: RETH})
        );
        universalSwapTokens[12] = toBytes32(
            UniversalTokenSwapperSubstrate({functionSelector: bytes4(0), target: ROCKET_DEPOSIT_POOL_ADDRESS})
        );
        marketConfigs_[0] = MarketSubstratesConfig(IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER, universalSwapTokens);
    }

    function _setupFuses() private returns (address[] memory fuses_) {
        SwapExecutorEth swapExecutor = new SwapExecutorEth(W_ETH);
        _executor = address(swapExecutor);
        _universalTokenSwapperFuse = new UniversalTokenSwapperWithVerificationFuse(
            IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER,
            _executor,
            1e18
        );
        _transientStorageSetInputsFuse = address(new TransientStorageSetInputsFuse());

        fuses_ = new address[](2);
        fuses_[0] = address(_universalTokenSwapperFuse);
        fuses_[1] = _transientStorageSetInputsFuse;
    }

    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses_) {
        ZeroBalanceFuse zeroBalance = new ZeroBalanceFuse(IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER);
        ERC20BalanceFuse erc20BalanceFuse = new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE);

        balanceFuses_ = new MarketBalanceFuseConfig[](2);
        balanceFuses_[0] = MarketBalanceFuseConfig(IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER, address(zeroBalance));
        balanceFuses_[1] = MarketBalanceFuseConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, address(erc20BalanceFuse));
    }

    /// @notice Converts UniversalTokenSwapperSubstrate to bytes32
    /// @param substrate_ The substrate to convert
    /// @return The packed bytes32 representation
    function toBytes32(UniversalTokenSwapperSubstrate memory substrate_) public pure returns (bytes32) {
        return bytes32((uint256(uint32(substrate_.functionSelector)) << 224) | (uint256(uint160(substrate_.target))));
    }
}
