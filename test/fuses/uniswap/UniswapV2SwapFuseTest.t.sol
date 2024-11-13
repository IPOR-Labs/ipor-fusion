// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {FuseAction, PlasmaVault, FeeConfig, PlasmaVaultInitData} from "../../../contracts/vaults/PlasmaVault.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";

import {UniswapV2SwapFuse, UniswapV2SwapFuseEnterData} from "../../../contracts/fuses/uniswap/UniswapV2SwapFuse.sol";

import {Test} from "forge-std/Test.sol";
import {RoleLib, UsersToRoles} from "../../RoleLib.sol";

import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {ZeroBalanceFuse} from "../../../contracts/fuses/ZeroBalanceFuse.sol";
import {FeeManagerFactory} from "../../../contracts/managers/fee/FeeManagerFactory.sol";

contract UniswapV2SwapFuseTest is Test {
    using SafeERC20 for ERC20;

    event MarketBalancesUpdated(uint256[] marketIds, int256 deltaInUnderlying);

    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address private constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    address public constant UNIVERSAL_ROUTER = 0xEf1c6E67703c7BD7107eed8303Fbe6EC2554BF6B;

    address private _plasmaVault;
    address private _priceOracle;
    address private _accessManager;
    UniswapV2SwapFuse private _uniswapV2SwapFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 20590113);

        address[] memory alphas = new address[](1);
        alphas[0] = address(this);

        // price oracle
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf);
        _priceOracle = address(
            new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
        );

        // plasma vault
        _plasmaVault = address(new PlasmaVault());
         PlasmaVault(_plasmaVault).initialize(
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
                    type(uint256).max,
                    address(0)
            )
        );
        _setupRoles();
    }

    function testShouldSwapWhenOneHop() external {
        // given

        address userOne = address(0x1222);
        uint256 depositAmount = 1_000e6;

        vm.prank(0xDa9CE944a37d218c3302F6B82a094844C6ECEb17);
        ERC20(USDC).transfer(userOne, 10_000e6);

        vm.prank(userOne);
        ERC20(USDC).approve(_plasmaVault, depositAmount);
        vm.prank(userOne);
        PlasmaVault(_plasmaVault).deposit(depositAmount, userOne);

        address[] memory path = new address[](2);
        path[0] = USDC;
        path[1] = USDT;

        UniswapV2SwapFuseEnterData memory enterData = UniswapV2SwapFuseEnterData({
            tokenInAmount: depositAmount,
            path: path,
            minOutAmount: 0
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_uniswapV2SwapFuse),
            abi.encodeWithSignature("enter((uint256,address[],uint256))", enterData)
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

    function testShouldSwapWhenMultipleHop() external {
        // given

        address userOne = address(0x1222);
        uint256 depositAmount = 1_000e6;

        vm.prank(0xDa9CE944a37d218c3302F6B82a094844C6ECEb17);
        ERC20(USDC).transfer(userOne, 10_000e6);

        vm.prank(userOne);
        ERC20(USDC).approve(_plasmaVault, depositAmount);
        vm.prank(userOne);
        PlasmaVault(_plasmaVault).deposit(depositAmount, userOne);

        address[] memory path = new address[](3);
        path[0] = USDC;
        path[1] = DAI;
        path[2] = USDT;

        UniswapV2SwapFuseEnterData memory enterData = UniswapV2SwapFuseEnterData({
            tokenInAmount: depositAmount,
            path: path,
            minOutAmount: 0
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_uniswapV2SwapFuse),
            abi.encodeWithSignature("enter((uint256,address[],uint256))", enterData)
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

    function testShouldNotBeAbleSwapWhenDAIWasRemovedFromSubstrates() external {
        // given

        address userOne = address(0x1222);
        uint256 depositAmount = 1_000e6;

        vm.prank(0xDa9CE944a37d218c3302F6B82a094844C6ECEb17);
        ERC20(USDC).transfer(userOne, 10_000e6);

        vm.prank(userOne);
        ERC20(USDC).approve(_plasmaVault, depositAmount);
        vm.prank(userOne);
        PlasmaVault(_plasmaVault).deposit(depositAmount, userOne);

        address[] memory path = new address[](3);
        path[0] = USDC;
        path[1] = DAI;
        path[2] = USDT;

        UniswapV2SwapFuseEnterData memory enterData = UniswapV2SwapFuseEnterData({
            tokenInAmount: depositAmount,
            path: path,
            minOutAmount: 0
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_uniswapV2SwapFuse),
            abi.encodeWithSignature("enter((uint256,address[],uint256))", enterData)
        );

        bytes32[] memory uniswapTokens = new bytes32[](2);
        uniswapTokens[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);
        uniswapTokens[1] = PlasmaVaultConfigLib.addressToBytes32(USDT);

        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(IporFusionMarkets.UNISWAP_SWAP_V2, uniswapTokens);

        bytes memory error = abi.encodeWithSignature("UniswapV2SwapFuseUnsupportedToken(address)", DAI);

        //when
        vm.expectRevert(error);
        PlasmaVault(_plasmaVault).execute(enterCalls);
    }

    function testShouldRevertWhenUnsupportedToken() external {
        // given

        address userOne = address(0x1222);
        uint256 depositAmount = 1_000e6;

        vm.prank(0xDa9CE944a37d218c3302F6B82a094844C6ECEb17);
        ERC20(USDC).transfer(userOne, 10_000e6);

        vm.prank(userOne);
        ERC20(USDC).approve(_plasmaVault, depositAmount);
        vm.prank(userOne);
        PlasmaVault(_plasmaVault).deposit(depositAmount, userOne);

        address[] memory path = new address[](3);
        path[0] = USDC;
        path[1] = address(0x76543);
        path[2] = USDT;

        UniswapV2SwapFuseEnterData memory enterData = UniswapV2SwapFuseEnterData({
            tokenInAmount: depositAmount,
            path: path,
            minOutAmount: 0
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_uniswapV2SwapFuse),
            abi.encodeWithSignature("enter((uint256,address[],uint256))", enterData)
        );

        bytes memory error = abi.encodeWithSignature("UniswapV2SwapFuseUnsupportedToken(address)", address(0x76543));

        //when
        vm.expectRevert(error);
        PlasmaVault(_plasmaVault).execute(enterCalls);
    }

    function _setupFeeConfig() private returns (FeeConfig memory feeConfig_) {
        feeConfig_ = FeeConfig(0, 0, 0, 0, address(new FeeManagerFactory()), address(0), address(0));
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

    function _getFuses() private returns (address[] memory fuses_) {
        UniswapV2SwapFuse uniswapV2SwapFuse = new UniswapV2SwapFuse(
            IporFusionMarkets.UNISWAP_SWAP_V2,
            UNIVERSAL_ROUTER
        );

        fuses_ = new address[](1);
        fuses_[0] = address(uniswapV2SwapFuse);
    }

    function _setupMarketConfigs() private returns (MarketSubstratesConfig[] memory marketConfigs_) {
        marketConfigs_ = new MarketSubstratesConfig[](1);

        bytes32[] memory uniswapTokens = new bytes32[](3);
        uniswapTokens[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);
        uniswapTokens[1] = PlasmaVaultConfigLib.addressToBytes32(USDT);
        uniswapTokens[2] = PlasmaVaultConfigLib.addressToBytes32(DAI);

        marketConfigs_[0] = MarketSubstratesConfig(IporFusionMarkets.UNISWAP_SWAP_V2, uniswapTokens);
    }
    //
    function _setupFuses() private returns (address[] memory fuses_) {
        _uniswapV2SwapFuse = new UniswapV2SwapFuse(IporFusionMarkets.UNISWAP_SWAP_V2, UNIVERSAL_ROUTER);

        fuses_ = new address[](1);
        fuses_[0] = address(_uniswapV2SwapFuse);
    }
    //
    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses_) {
        // @Dev this setup is ignored for tests
        ZeroBalanceFuse uniswapBalance = new ZeroBalanceFuse(IporFusionMarkets.UNISWAP_SWAP_V2);

        balanceFuses_ = new MarketBalanceFuseConfig[](1);
        balanceFuses_[0] = MarketBalanceFuseConfig(IporFusionMarkets.UNISWAP_SWAP_V2, address(uniswapBalance));
    }
}
