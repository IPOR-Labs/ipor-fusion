// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PlazmaVaultFactory} from "../../contracts/vaults/PlazmaVaultFactory.sol";
import {PlazmaVault} from "../../contracts/vaults/PlazmaVault.sol";
import {AaveV3SupplyFuse} from "../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {AaveV3BalanceFuse} from "../../contracts/fuses/aave_v3/AaveV3BalanceFuse.sol";
import {CompoundV3BalanceFuse} from "../../contracts/fuses/compound_v3/CompoundV3BalanceFuse.sol";
import {CompoundV3SupplyFuse} from "../../contracts/fuses/compound_v3/CompoundV3SupplyFuse.sol";
import {MarketConfigurationLib} from "../../contracts/libraries/MarketConfigurationLib.sol";
import {IAavePoolDataProvider} from "../../contracts/fuses/aave_v3/IAavePoolDataProvider.sol";
import {IporPriceOracle} from "../../contracts/priceOracle/IporPriceOracle.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PlazmaVaultLib} from "../../contracts/libraries/PlazmaVaultLib.sol";

contract PlazmaVaultWithdrawTest is Test {
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    PlazmaVaultFactory internal vaultFactory;

    address public constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    uint256 public constant AAVE_V3_MARKET_ID = 1;

    address public constant COMET_V3_USDC = 0xc3d688B66703497DAA19211EEdff47f25384cdc3;
    uint256 public constant COMPOUND_V3_MARKET_ID = 2;

    IAavePoolDataProvider public constant AAVE_POOL_DATA_PROVIDER =
        IAavePoolDataProvider(0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3);

    address public owner = address(this);

    string public assetName;
    string public assetSymbol;
    address public underlyingToken;
    address[] public alphas;
    address public alpha;
    uint256 public amount;

    address public userOne;

    IporPriceOracle private iporPriceOracleProxy;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19591360);
        vaultFactory = new PlazmaVaultFactory(owner);
        userOne = address(0x777);

        IporPriceOracle implementation = new IporPriceOracle(
            0x0000000000000000000000000000000000000348,
            8,
            0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf
        );

        iporPriceOracleProxy = IporPriceOracle(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );
    }

    function testShouldImmediatelyWithdrawCashAvailableOnPlazmaVault() public {
        //given
        PlazmaVault plazmaVault = _preparePlazmaVaultDai();

        userOne = address(0x777);

        uint256 amount = 100 * 1e18;

        deal(DAI, address(userOne), amount);

        vm.prank(userOne);
        ERC20(DAI).approve(address(plazmaVault), 3 * amount);

        vm.prank(userOne);
        plazmaVault.deposit(amount, userOne);

        uint256 vaultTotalAssetsBefore = plazmaVault.totalAssets();
        uint256 userVaultBalanceBefore = plazmaVault.balanceOf(userOne);

        //when
        vm.prank(userOne);
        plazmaVault.withdraw(amount, userOne, userOne);

        //then
        uint256 vaultTotalAssetsAfter = plazmaVault.totalAssets();
        uint256 userVaultBalanceAfter = plazmaVault.balanceOf(userOne);

        assertEq(vaultTotalAssetsBefore - amount, vaultTotalAssetsAfter);
        assertEq(userVaultBalanceBefore - amount, userVaultBalanceAfter);

        assertEq(vaultTotalAssetsAfter, 0);
    }

    function testShouldNotImmediatelyWithdrawBecauseNoShares() public {
        // given
        PlazmaVault plazmaVault = _preparePlazmaVaultDai();

        userOne = address(0x777);

        uint256 amount = 100 * 1e18;

        deal(DAI, address(userOne), amount);

        vm.prank(userOne);
        ERC20(DAI).approve(address(plazmaVault), 3 * amount);

        bytes4 selector = bytes4(keccak256("ERC4626ExceededMaxWithdraw(address,uint256,uint256)"));
        //when
        vm.prank(userOne);
        vm.expectRevert(abi.encodeWithSelector(selector, userOne, amount, 0));
        plazmaVault.withdraw(amount, userOne, userOne);
    }

    function testShouldImmediatelyWithdrawRequiredExitFromOneMarketAaveV3() public {
        //given
        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        alphas = new address[](1);
        alpha = address(0x1);

        alphas[0] = alpha;

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlazmaVault.MarketSubstratesConfig[](1);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = MarketConfigurationLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = PlazmaVault.MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(AAVE_V3_MARKET_ID);
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(AAVE_POOL, AAVE_V3_MARKET_ID);

        address[] memory fuses = new address[](1);
        fuses[0] = address(supplyFuseAaveV3);

        PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlazmaVault.MarketBalanceFuseConfig[](1);
        balanceFuses[0] = PlazmaVault.MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));

        PlazmaVault plazmaVault = PlazmaVault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    address(iporPriceOracleProxy),
                    alphas,
                    marketConfigs,
                    fuses,
                    balanceFuses
                )
            )
        );

        amount = 100 * 1e6;

        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userOne), 2 * amount);

        vm.prank(userOne);
        ERC20(USDC).approve(address(plazmaVault), 3 * amount);

        vm.prank(userOne);
        plazmaVault.deposit(2 * amount, userOne);

        PlazmaVault.FuseAction[] memory calls = new PlazmaVault.FuseAction[](1);

        calls[0] = PlazmaVault.FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(
                    AaveV3SupplyFuse.AaveV3SupplyFuseEnterData({asset: USDC, amount: amount, userEModeCategoryId: 1e6})
                )
            )
        );

        /// @dev first call to move some assets to a external market
        vm.prank(alpha);
        plazmaVault.execute(calls);

        /// @dev prepare immediate withdraw config
        PlazmaVaultLib.ImmediateWithdrawalFusesParamsStruct[]
            memory immediateWithdrawFuses = new PlazmaVaultLib.ImmediateWithdrawalFusesParamsStruct[](1);
        bytes32[] memory immediateWithdrawParams = new bytes32[](2);
        immediateWithdrawParams[0] = 0;
        immediateWithdrawParams[1] = MarketConfigurationLib.addressToBytes32(USDC);

        immediateWithdrawFuses[0] = PlazmaVaultLib.ImmediateWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseAaveV3),
            params: immediateWithdrawParams
        });

        plazmaVault.updateImmediateWithdrawalFuses(immediateWithdrawFuses);

        //when
        vm.prank(userOne);
        plazmaVault.withdraw(199 * 1e6, userOne, userOne);

        //then
        uint256 userBalanceAfter = ERC20(USDC).balanceOf(userOne);

        uint256 vaultTotalAssetsAfter = plazmaVault.totalAssets();

        assertEq(userBalanceAfter, 199 * 1e6);
        assertGt(vaultTotalAssetsAfter, 0);
        assertLt(vaultTotalAssetsAfter, 1e6);
    }

    function testShouldImmediatelyWithdrawRequiredExitFromTwoMarketsAaveV3CompoundV3() public {
        //given
        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        alphas = new address[](1);
        alpha = address(0x1);

        alphas[0] = alpha;

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlazmaVault.MarketSubstratesConfig[](2);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = MarketConfigurationLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = PlazmaVault.MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(AAVE_V3_MARKET_ID);
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(AAVE_POOL, AAVE_V3_MARKET_ID);

        /// @dev Market Compound V3
        marketConfigs[1] = PlazmaVault.MarketSubstratesConfig(COMPOUND_V3_MARKET_ID, assets);
        CompoundV3BalanceFuse balanceFuseCompoundV3 = new CompoundV3BalanceFuse(COMET_V3_USDC, COMPOUND_V3_MARKET_ID);
        CompoundV3SupplyFuse supplyFuseCompoundV3 = new CompoundV3SupplyFuse(COMET_V3_USDC, COMPOUND_V3_MARKET_ID);

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuseAaveV3);
        fuses[1] = address(supplyFuseCompoundV3);

        PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlazmaVault.MarketBalanceFuseConfig[](2);
        balanceFuses[0] = PlazmaVault.MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));
        balanceFuses[1] = PlazmaVault.MarketBalanceFuseConfig(COMPOUND_V3_MARKET_ID, address(balanceFuseCompoundV3));

        PlazmaVault plazmaVault = PlazmaVault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    address(iporPriceOracleProxy),
                    alphas,
                    marketConfigs,
                    fuses,
                    balanceFuses
                )
            )
        );

        amount = 100 * 1e6;

        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userOne), 2 * amount);

        vm.prank(userOne);
        ERC20(USDC).approve(address(plazmaVault), 3 * amount);

        vm.prank(userOne);
        plazmaVault.deposit(2 * amount, userOne);

        PlazmaVault.FuseAction[] memory calls = new PlazmaVault.FuseAction[](2);

        calls[0] = PlazmaVault.FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(
                    AaveV3SupplyFuse.AaveV3SupplyFuseEnterData({
                        asset: USDC,
                        amount: 50 * 1e6,
                        userEModeCategoryId: 1e6
                    })
                )
            )
        );

        calls[1] = PlazmaVault.FuseAction(
            address(supplyFuseCompoundV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(CompoundV3SupplyFuse.CompoundV3SupplyFuseEnterData({asset: USDC, amount: 50 * 1e6}))
            )
        );

        /// @dev first call to move some assets to a external market
        vm.prank(alpha);
        plazmaVault.execute(calls);

        /// @dev prepare immediate withdraw config
        PlazmaVaultLib.ImmediateWithdrawalFusesParamsStruct[]
            memory immediateWithdrawFuses = new PlazmaVaultLib.ImmediateWithdrawalFusesParamsStruct[](2);
        bytes32[] memory immediateWithdrawParams = new bytes32[](2);
        immediateWithdrawParams[0] = 0;
        immediateWithdrawParams[1] = MarketConfigurationLib.addressToBytes32(USDC);

        immediateWithdrawFuses[0] = PlazmaVaultLib.ImmediateWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseAaveV3),
            params: immediateWithdrawParams
        });

        immediateWithdrawFuses[1] = PlazmaVaultLib.ImmediateWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseCompoundV3),
            params: immediateWithdrawParams
        });

        plazmaVault.updateImmediateWithdrawalFuses(immediateWithdrawFuses);

        //when
        vm.prank(userOne);
        plazmaVault.withdraw(175 * 1e6, userOne, userOne);

        //then
        uint256 userBalanceAfter = ERC20(USDC).balanceOf(userOne);
        uint256 vaultTotalAssetsAfter = plazmaVault.totalAssets();

        assertEq(userBalanceAfter, 175 * 1e6);

        assertGt(vaultTotalAssetsAfter, 24 * 1e6);
        assertLt(vaultTotalAssetsAfter, 25 * 1e6);
    }

    function _preparePlazmaVaultUsdc() public returns (PlazmaVault) {
        string memory assetName = "IPOR Fusion USDC";
        string memory assetSymbol = "ipfUSDC";
        address underlyingToken = USDC;
        address[] memory alphas = new address[](1);

        alphas[0] = address(0x1);

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlazmaVault.MarketSubstratesConfig[](2);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = MarketConfigurationLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = PlazmaVault.MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(AAVE_V3_MARKET_ID);
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(AAVE_POOL, AAVE_V3_MARKET_ID);

        /// @dev Market Compound V3
        marketConfigs[1] = PlazmaVault.MarketSubstratesConfig(COMPOUND_V3_MARKET_ID, assets);
        CompoundV3BalanceFuse balanceFuseCompoundV3 = new CompoundV3BalanceFuse(COMET_V3_USDC, COMPOUND_V3_MARKET_ID);
        CompoundV3SupplyFuse supplyFuseCompoundV3 = new CompoundV3SupplyFuse(COMET_V3_USDC, COMPOUND_V3_MARKET_ID);

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuseAaveV3);
        fuses[1] = address(supplyFuseCompoundV3);

        PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlazmaVault.MarketBalanceFuseConfig[](2);
        balanceFuses[0] = PlazmaVault.MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));
        balanceFuses[1] = PlazmaVault.MarketBalanceFuseConfig(COMPOUND_V3_MARKET_ID, address(balanceFuseCompoundV3));

        PlazmaVault plazmaVault = PlazmaVault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    address(iporPriceOracleProxy),
                    alphas,
                    marketConfigs,
                    fuses,
                    balanceFuses
                )
            )
        );
        return plazmaVault;
    }

    function _preparePlazmaVaultDai() public returns (PlazmaVault) {
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory alphas = new address[](1);

        address alpha = address(0x1);
        alphas[0] = alpha;

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlazmaVault.MarketSubstratesConfig[](1);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = MarketConfigurationLib.addressToBytes32(DAI);
        marketConfigs[0] = PlazmaVault.MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);

        AaveV3BalanceFuse balanceFuse = new AaveV3BalanceFuse(AAVE_V3_MARKET_ID);

        AaveV3SupplyFuse supplyFuse = new AaveV3SupplyFuse(AAVE_POOL, AAVE_V3_MARKET_ID);

        address[] memory fuses = new address[](1);
        fuses[0] = address(supplyFuse);

        PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlazmaVault.MarketBalanceFuseConfig[](1);
        balanceFuses[0] = PlazmaVault.MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuse));

        PlazmaVault plazmaVault = PlazmaVault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    address(iporPriceOracleProxy),
                    alphas,
                    marketConfigs,
                    fuses,
                    balanceFuses
                )
            )
        );

        return plazmaVault;
    }
}
