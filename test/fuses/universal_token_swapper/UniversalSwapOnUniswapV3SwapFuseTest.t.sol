// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

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

import {SwapExecutor} from "contracts/fuses/universal_token_swapper/SwapExecutor.sol";
import {SwapExecutorRestricted} from "contracts/fuses/universal_token_swapper/SwapExecutorRestricted.sol";
import {UniversalTokenSwapperFuse, UniversalTokenSwapperEnterData, UniversalTokenSwapperData} from "../../../contracts/fuses/universal_token_swapper/UniversalTokenSwapperFuse.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {PlasmaVaultConfigurator} from "../../utils/PlasmaVaultConfigurator.sol";

contract UniversalSwapOnUniswapV3SwapFuseTest is Test {
    using SafeERC20 for ERC20;

    event MarketBalancesUpdated(uint256[] marketIds, int256 deltaInUnderlying);

    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address private constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    address private constant _UNIVERSAL_ROUTER = 0xEf1c6E67703c7BD7107eed8303Fbe6EC2554BF6B;

    address private _plasmaVault;
    address private _withdrawManager;
    address private _priceOracle;
    address private _accessManager;

    UniversalTokenSwapperFuse private _universalTokenSwapperFuse;

    ///@dev this value is from the UniversalRouter contract https://github.com/Uniswap/universal-router/blob/main/contracts/libraries/Commands.sol
    uint256 private constant _V3_SWAP_EXACT_IN = 0x00;
    address private constant _INDICATOR_OF_SENDER_FROM_UNIVERSAL_ROUTER = address(1);

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 20590113);

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
    }

    function testTT() external {
        assertTrue(true);
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

        bytes memory path = abi.encodePacked(USDC, uint24(3000), USDT);

        address[] memory targets = new address[](2);
        targets[0] = USDC;
        targets[1] = _UNIVERSAL_ROUTER;

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(_INDICATOR_OF_SENDER_FROM_UNIVERSAL_ROUTER, depositAmount, 0, path, false);

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSignature("transfer(address,uint256)", _UNIVERSAL_ROUTER, depositAmount);
        data[1] = abi.encodeWithSignature(
            "execute(bytes,bytes[])",
            abi.encodePacked(bytes1(uint8(_V3_SWAP_EXACT_IN))),
            inputs
        );

        UniversalTokenSwapperEnterData memory enterData = UniversalTokenSwapperEnterData({
            tokenIn: USDC,
            tokenOut: USDT,
            amountIn: depositAmount,
            data: UniversalTokenSwapperData({targets: targets, data: data})
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_universalTokenSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,(address[],bytes[])))", enterData)
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

        bytes memory path = abi.encodePacked(USDC, uint24(3000), DAI, uint24(3000), USDT);
        address[] memory targets = new address[](2);
        targets[0] = USDC;
        targets[1] = _UNIVERSAL_ROUTER;

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(_INDICATOR_OF_SENDER_FROM_UNIVERSAL_ROUTER, depositAmount, 0, path, false);

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSignature("transfer(address,uint256)", _UNIVERSAL_ROUTER, depositAmount);
        data[1] = abi.encodeWithSignature(
            "execute(bytes,bytes[])",
            abi.encodePacked(bytes1(uint8(_V3_SWAP_EXACT_IN))),
            inputs
        );

        UniversalTokenSwapperEnterData memory enterData = UniversalTokenSwapperEnterData({
            tokenIn: USDC,
            tokenOut: USDT,
            amountIn: depositAmount,
            data: UniversalTokenSwapperData({targets: targets, data: data})
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_universalTokenSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,(address[],bytes[])))", enterData)
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

    function testShouldSwapWithRestrictedExecutor() external {
        // given
        address userOne = address(0x1222);
        uint256 depositAmount = 1_000e6;

        vm.prank(0xDa9CE944a37d218c3302F6B82a094844C6ECEb17);
        ERC20(USDC).transfer(userOne, 10_000e6);

        vm.prank(userOne);
        ERC20(USDC).approve(_plasmaVault, depositAmount);
        vm.prank(userOne);
        PlasmaVault(_plasmaVault).deposit(depositAmount, userOne);

        // Create SwapExecutorRestricted with the plasma vault as the restricted address
        SwapExecutorRestricted swapExecutorRestricted = new SwapExecutorRestricted(_plasmaVault);

        // Create a new UniversalTokenSwapperFuse with the restricted executor
        UniversalTokenSwapperFuse restrictedUniversalTokenSwapperFuse = new UniversalTokenSwapperFuse(
            IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER,
            address(swapExecutorRestricted),
            1e18
        );

        // Add the restricted fuse to the plasma vault
        address[] memory newFuses = new address[](1);
        newFuses[0] = address(restrictedUniversalTokenSwapperFuse);
        IPlasmaVaultGovernance(_plasmaVault).addFuses(newFuses);

        bytes memory path = abi.encodePacked(USDC, uint24(3000), USDT);

        address[] memory targets = new address[](2);
        targets[0] = USDC;
        targets[1] = _UNIVERSAL_ROUTER;

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(_INDICATOR_OF_SENDER_FROM_UNIVERSAL_ROUTER, depositAmount, 0, path, false);

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSignature("transfer(address,uint256)", _UNIVERSAL_ROUTER, depositAmount);
        data[1] = abi.encodeWithSignature(
            "execute(bytes,bytes[])",
            abi.encodePacked(bytes1(uint8(_V3_SWAP_EXACT_IN))),
            inputs
        );

        UniversalTokenSwapperEnterData memory enterData = UniversalTokenSwapperEnterData({
            tokenIn: USDC,
            tokenOut: USDT,
            amountIn: depositAmount,
            data: UniversalTokenSwapperData({targets: targets, data: data})
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(restrictedUniversalTokenSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,(address[],bytes[])))", enterData)
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
        marketConfigs_ = new MarketSubstratesConfig[](1);

        bytes32[] memory universalSwapTokens = new bytes32[](4);
        universalSwapTokens[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);
        universalSwapTokens[1] = PlasmaVaultConfigLib.addressToBytes32(USDT);
        universalSwapTokens[2] = PlasmaVaultConfigLib.addressToBytes32(DAI);
        universalSwapTokens[3] = PlasmaVaultConfigLib.addressToBytes32(_UNIVERSAL_ROUTER);

        marketConfigs_[0] = MarketSubstratesConfig(IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER, universalSwapTokens);
    }
    function _setupFuses() private returns (address[] memory fuses_) {
        SwapExecutor swapExecutor = new SwapExecutor();

        _universalTokenSwapperFuse = new UniversalTokenSwapperFuse(
            IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER,
            address(swapExecutor),
            1e18
        );

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
