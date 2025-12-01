// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SupplyTest} from "../supplyFuseTemplate/SupplyTests.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig, FuseAction, PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {Erc4626SupplyFuse, Erc4626SupplyFuseEnterData, Erc4626SupplyFuseExitData} from "../../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {Erc4626BalanceFuse} from "../../../contracts/fuses/erc4626/Erc4626BalanceFuse.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {GearboxV3FarmdSupplyFuseExitData, GearboxV3FarmdSupplyFuseEnterData, GearboxV3FarmSupplyFuse} from "../../../contracts/fuses/gearbox_v3/GearboxV3FarmSupplyFuse.sol";
import {GearboxV3FarmBalanceFuse} from "../../../contracts/fuses/gearbox_v3/GearboxV3FarmBalanceFuse.sol";
import {TransientStorageSetInputsFuse, TransientStorageSetInputsFuseEnterData} from "../../../contracts/fuses/transient_storage/TransientStorageSetInputsFuse.sol";
import {TypeConversionLib} from "../../../contracts/libraries/TypeConversionLib.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";

/// @title Tests for Gearbox V3 Farmd USDC Arbitrum integration
/// @notice Integration tests for Gearbox V3 Farmd USDC Arbitrum fuses
/// @author IPOR Labs
contract GearboxV3FarmdUSDCArbitrum is SupplyTest {
    /// @notice USDC token address
    address private constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    /// @notice Chainlink USDC price feed address
    address private constant CHAINLINK_USDC = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    /// @notice Gearbox D_USDC token address
    address public constant D_USDC = 0x890A69EF363C9c7BdD5E36eb95Ceb569F63ACbF6;
    /// @notice Gearbox FARM_D_USDC token address
    address public constant FARM_D_USDC = 0xD0181a36B0566a8645B7eECFf2148adE7Ecf2BE9;
    /// @notice Price oracle middleware address
    address public constant PRICE_ORACLE_MIDDLEWARE_USD = 0x85a3Ee1688eE8D320eDF4024fB67734Fa8492cF4;

    /// @notice Gearbox V3 Farm Supply Fuse instance
    GearboxV3FarmSupplyFuse public gearboxV3FarmSupplyFuse;
    /// @notice Gearbox V3 DToken Fuse instance
    Erc4626SupplyFuse public gearboxV3DTokenFuse;
    /// @notice Transient Storage Set Inputs Fuse instance
    TransientStorageSetInputsFuse public transientStorageSetInputsFuse;

    /// @notice Setup the test environment
    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 226213814);
        init();
    }

    /// @notice Get the market ID
    /// @return Market ID
    function getMarketId() public view override returns (uint256) {
        return IporFusionMarkets.GEARBOX_FARM_DTOKEN_V3;
    }

    /// @notice Setup the asset
    function setupAsset() public override {
        asset = USDC;
    }

    /// @notice Deal assets to an account
    /// @param account_ The account to deal assets to
    /// @param amount_ The amount of assets to deal
    function dealAssets(address account_, uint256 amount_) public override {
        vm.prank(0x47c031236e19d024b42f8AE6780E44A573170703);
        ERC20(asset).transfer(account_, amount_);
    }

    /// @notice Setup the price oracle
    /// @return assets The assets
    /// @return sources The sources
    function setupPriceOracle() public override returns (address[] memory assets, address[] memory sources) {
        assets = new address[](1);
        sources = new address[](1);
        assets[0] = USDC;
        sources[0] = CHAINLINK_USDC;
    }

    /// @notice Setup the market configs
    /// @return marketConfigs The market configs
    function setupMarketConfigs() public override returns (MarketSubstratesConfig[] memory marketConfigs) {
        marketConfigs = new MarketSubstratesConfig[](2);
        bytes32[] memory assetsDUsdc = new bytes32[](1);
        assetsDUsdc[0] = PlasmaVaultConfigLib.addressToBytes32(D_USDC);
        marketConfigs[0] = MarketSubstratesConfig(IporFusionMarkets.GEARBOX_POOL_V3, assetsDUsdc);

        bytes32[] memory assetsFarmDUsdc = new bytes32[](1);
        assetsFarmDUsdc[0] = PlasmaVaultConfigLib.addressToBytes32(FARM_D_USDC);
        marketConfigs[1] = MarketSubstratesConfig(IporFusionMarkets.GEARBOX_FARM_DTOKEN_V3, assetsFarmDUsdc);
    }

    /// @notice Setup the fuses
    function setupFuses() public override {
        gearboxV3DTokenFuse = new Erc4626SupplyFuse(IporFusionMarkets.GEARBOX_POOL_V3);
        gearboxV3FarmSupplyFuse = new GearboxV3FarmSupplyFuse(IporFusionMarkets.GEARBOX_FARM_DTOKEN_V3);
        transientStorageSetInputsFuse = new TransientStorageSetInputsFuse();
        fuses = new address[](3);
        fuses[0] = address(gearboxV3DTokenFuse);
        fuses[1] = address(gearboxV3FarmSupplyFuse);
        fuses[2] = address(transientStorageSetInputsFuse);
    }

    /// @notice Setup the balance fuses
    /// @return balanceFuses The balance fuses
    function setupBalanceFuses() public override returns (MarketBalanceFuseConfig[] memory balanceFuses) {
        Erc4626BalanceFuse gearboxV3Balances = new Erc4626BalanceFuse(IporFusionMarkets.GEARBOX_POOL_V3);

        GearboxV3FarmBalanceFuse gearboxV3FarmdBalances = new GearboxV3FarmBalanceFuse(
            IporFusionMarkets.GEARBOX_FARM_DTOKEN_V3
        );

        balanceFuses = new MarketBalanceFuseConfig[](3);
        balanceFuses[0] = MarketBalanceFuseConfig(IporFusionMarkets.GEARBOX_POOL_V3, address(gearboxV3Balances));

        balanceFuses[1] = MarketBalanceFuseConfig(
            IporFusionMarkets.GEARBOX_FARM_DTOKEN_V3,
            address(gearboxV3FarmdBalances)
        );

        ERC20BalanceFuse erc20BalanceArbitrum = new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE);
        balanceFuses[2] = MarketBalanceFuseConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, address(erc20BalanceArbitrum));
    }

    /// @notice Get the enter fuse data
    /// @param amount_ The amount to enter
    /// @param data_ The additional data
    /// @return data The enter fuse data
    function getEnterFuseData(
        uint256 amount_,
        //solhint-disable-next-line
        bytes32[] memory data_
    ) public view virtual override returns (bytes[] memory data) {
        Erc4626SupplyFuseEnterData memory enterData = Erc4626SupplyFuseEnterData({
            vault: D_USDC,
            vaultAssetAmount: amount_
        });
        GearboxV3FarmdSupplyFuseEnterData memory enterDataFarm = GearboxV3FarmdSupplyFuseEnterData({
            farmdToken: FARM_D_USDC,
            dTokenAmount: amount_
        });
        data = new bytes[](2);
        data[0] = abi.encodeWithSignature("enter((address,uint256))", enterData);
        data[1] = abi.encodeWithSignature("enter((uint256,address))", enterDataFarm);
    }

    /// @notice Get the exit fuse data
    /// @param amount_ The amount to exit
    /// @param data_ The additional data
    /// @return fusesSetup The fuses setup
    /// @return data The exit fuse data
    function getExitFuseData(
        uint256 amount_,
        //solhint-disable-next-line
        bytes32[] memory data_
    ) public view virtual override returns (address[] memory fusesSetup, bytes[] memory data) {
        Erc4626SupplyFuseExitData memory exitData = Erc4626SupplyFuseExitData({
            vault: D_USDC,
            vaultAssetAmount: amount_
        });
        GearboxV3FarmdSupplyFuseExitData memory exitDataFarm = GearboxV3FarmdSupplyFuseExitData({
            farmdToken: FARM_D_USDC,
            dTokenAmount: amount_
        });
        data = new bytes[](2);
        data[1] = abi.encodeWithSignature("exit((address,uint256))", exitData);
        data[0] = abi.encodeWithSignature("exit((uint256,address))", exitDataFarm);

        fusesSetup = new address[](2);
        fusesSetup[0] = address(gearboxV3FarmSupplyFuse);
        fusesSetup[1] = address(gearboxV3DTokenFuse);
    }

    /// @notice Test entering using transient storage
    function testShouldEnterUsingTransient() external {
        // given
        address userOne = accounts[1];
        uint256 depositAmount = random.randomNumber(
            1 * 10 ** (ERC20(asset).decimals()),
            10_000 * 10 ** (ERC20(asset).decimals())
        );
        vm.prank(userOne);
        PlasmaVault(plasmaVault).deposit(depositAmount, userOne);

        uint256 totalSharesBefore = PlasmaVault(plasmaVault).totalSupply();
        uint256 totalAssetsBefore = PlasmaVault(plasmaVault).totalAssets();
        uint256 assetsInMarketBefore = PlasmaVault(plasmaVault).totalAssetsInMarket(getMarketId());

        FuseAction[] memory calls = _createEnterTransientCalls(depositAmount);

        // when
        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(calls);

        // then
        uint256 totalSharesAfter = PlasmaVault(plasmaVault).totalSupply();
        uint256 totalAssetsAfter = PlasmaVault(plasmaVault).totalAssets();
        uint256 assetsInMarketAfter = PlasmaVault(plasmaVault).totalAssetsInMarket(getMarketId());

        assertEq(totalSharesAfter, totalSharesBefore, "totalShares");
        assertApproxEqAbs(totalAssetsAfter, totalAssetsBefore, 100, "totalAssets");
        assertApproxEqAbs(assetsInMarketAfter, assetsInMarketBefore + depositAmount, 100, "assetsInMarket");
    }

    /// @notice Test exiting using transient storage
    function testShouldExitUsingTransient() external {
        // given
        address userOne = accounts[1];
        uint256 depositAmount = random.randomNumber(
            1 * 10 ** (ERC20(asset).decimals()),
            10_000 * 10 ** (ERC20(asset).decimals())
        );
        vm.prank(userOne);
        PlasmaVault(plasmaVault).deposit(depositAmount, userOne);

        // Enter first (standard way)
        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(generateEnterCallsData(depositAmount, new bytes32[](0)));

        uint256 totalSharesBefore = PlasmaVault(plasmaVault).totalSupply();
        uint256 totalAssetsBefore = PlasmaVault(plasmaVault).totalAssets();
        uint256 assetsInMarketBefore = PlasmaVault(plasmaVault).totalAssetsInMarket(getMarketId());

        FuseAction[] memory calls = _createExitTransientCalls(depositAmount);

        // when
        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(calls);

        // then
        uint256 totalSharesAfter = PlasmaVault(plasmaVault).totalSupply();
        uint256 totalAssetsAfter = PlasmaVault(plasmaVault).totalAssets();
        uint256 assetsInMarketAfter = PlasmaVault(plasmaVault).totalAssetsInMarket(getMarketId());

        assertEq(totalSharesAfter, totalSharesBefore, "totalShares");
        assertApproxEqAbs(totalAssetsAfter, totalAssetsBefore, 100, "totalAssets");
        assertApproxEqAbs(assetsInMarketAfter + depositAmount, assetsInMarketBefore, 100, "assetsInMarket");
    }

    /// @notice Helper to create enter transient calls
    /// @param amount_ The amount to enter
    /// @return calls The fuse actions
    function _createEnterTransientCalls(uint256 amount_) internal view returns (FuseAction[] memory calls) {
        address[] memory fusesToSet = new address[](2);
        fusesToSet[0] = address(gearboxV3DTokenFuse);
        fusesToSet[1] = address(gearboxV3FarmSupplyFuse);

        bytes32[][] memory inputsByFuse = new bytes32[][](2);

        inputsByFuse[0] = new bytes32[](2);
        inputsByFuse[0][0] = TypeConversionLib.toBytes32(D_USDC);
        inputsByFuse[0][1] = TypeConversionLib.toBytes32(amount_);

        inputsByFuse[1] = new bytes32[](2);
        inputsByFuse[1][0] = TypeConversionLib.toBytes32(amount_);
        inputsByFuse[1][1] = TypeConversionLib.toBytes32(FARM_D_USDC);

        calls = new FuseAction[](3);

        calls[0] = FuseAction({
            fuse: address(transientStorageSetInputsFuse),
            data: abi.encodeWithSignature(
                "enter((address[],bytes32[][]))",
                TransientStorageSetInputsFuseEnterData({fuse: fusesToSet, inputsByFuse: inputsByFuse})
            )
        });

        calls[1] = FuseAction({fuse: address(gearboxV3DTokenFuse), data: abi.encodeWithSignature("enterTransient()")});

        calls[2] = FuseAction({
            fuse: address(gearboxV3FarmSupplyFuse),
            data: abi.encodeWithSignature("enterTransient()")
        });
    }

    /// @notice Helper to create exit transient calls
    /// @param amount_ The amount to exit
    /// @return calls The fuse actions
    function _createExitTransientCalls(uint256 amount_) internal view returns (FuseAction[] memory calls) {
        address[] memory fusesToSet = new address[](2);
        fusesToSet[0] = address(gearboxV3FarmSupplyFuse);
        fusesToSet[1] = address(gearboxV3DTokenFuse);

        bytes32[][] memory inputsByFuse = new bytes32[][](2);

        inputsByFuse[0] = new bytes32[](2);
        inputsByFuse[0][0] = TypeConversionLib.toBytes32(amount_);
        inputsByFuse[0][1] = TypeConversionLib.toBytes32(FARM_D_USDC);

        inputsByFuse[1] = new bytes32[](2);
        inputsByFuse[1][0] = TypeConversionLib.toBytes32(D_USDC);
        inputsByFuse[1][1] = TypeConversionLib.toBytes32(amount_);

        calls = new FuseAction[](3);

        calls[0] = FuseAction({
            fuse: address(transientStorageSetInputsFuse),
            data: abi.encodeWithSignature(
                "enter((address[],bytes32[][]))",
                TransientStorageSetInputsFuseEnterData({fuse: fusesToSet, inputsByFuse: inputsByFuse})
            )
        });

        calls[1] = FuseAction({
            fuse: address(gearboxV3FarmSupplyFuse),
            data: abi.encodeWithSignature("exitTransient()")
        });

        calls[2] = FuseAction({fuse: address(gearboxV3DTokenFuse), data: abi.encodeWithSignature("exitTransient()")});
    }
}
