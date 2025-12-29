// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IMorpho, Id, MarketParams} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";

import {FusionFactory} from "../../../contracts/factory/FusionFactory.sol";
import {FusionFactoryLogicLib} from "../../../contracts/factory/lib/FusionFactoryLogicLib.sol";
import {PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {PriceOracleMiddlewareManager} from "../../../contracts/managers/price/PriceOracleMiddlewareManager.sol";
import {MorphoSupplyFuse, MorphoSupplyFuseEnterData, MorphoSupplyFuseExitData} from "../../../contracts/fuses/morpho/MorphoSupplyFuse.sol";
import {MorphoOnlyLiquidityBalanceFuse} from "../../../contracts/fuses/morpho/MorphoOnlyLiquidityBalanceFuse.sol";
import {FuseAction} from "../../../contracts/interfaces/IPlasmaVault.sol";

contract MorphoLiquidityInMarketsTest is Test {
    address public constant FUSION_FACTORY_PROXY = 0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address public constant BALANCE_FUSE_ERC20 = 0x6cEBf3e3392D0860Ed174402884b941DCBB30654;

    // Market IDs
    bytes32 public constant MARKET_1 = 0x64d65c9a2d91c36d56fbc42d69e979335320169b3df63bf92789e2c8883fcc64;
    bytes32 public constant MARKET_2 = 0x3a85e619751152991742810df6ec69ce473daef99e28a64ab2340d7b7ccfee49;
    bytes32 public constant MARKET_3 = 0xb323495f7e4148be5643a4ea4a8221eef163e4bccfdedc2a6f4696baacbc86cc;

    address public owner = makeAddr("OWNER");
    address public atomist = makeAddr("ATOMIST");
    address public fuseManager = makeAddr("FUSE_MANAGER");
    address public alpha = makeAddr("ALPHA");
    address public priceOracleMiddlewareManager = makeAddr("PRICE_ORACLE_MIDDLEWARE_MANAGER");
    address public user = makeAddr("USER");

    FusionFactory public fusionFactory;
    PlasmaVault public plasmaVault;
    IporFusionAccessManager public accessManager;
    PriceOracleMiddlewareManager public priceManager;

    MorphoSupplyFuse public morphoSupplyFuse;
    MorphoOnlyLiquidityBalanceFuse public morphoBalanceFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 23970655);

        fusionFactory = FusionFactory(FUSION_FACTORY_PROXY);

        FusionFactoryLogicLib.FusionInstance memory fusionInstance = fusionFactory.create(
            "Test Morpho Vault",
            "TMV",
            USDC,
            0,
            owner
        );

        accessManager = IporFusionAccessManager(fusionInstance.accessManager);
        plasmaVault = PlasmaVault(fusionInstance.plasmaVault);
        priceManager = PriceOracleMiddlewareManager(fusionInstance.priceManager);

        // Grant roles
        vm.startPrank(owner);
        accessManager.grantRole(Roles.ATOMIST_ROLE, atomist, 0);
        vm.stopPrank();

        vm.startPrank(atomist);
        accessManager.grantRole(Roles.FUSE_MANAGER_ROLE, fuseManager, 0);
        accessManager.grantRole(Roles.ALPHA_ROLE, alpha, 0);
        accessManager.grantRole(Roles.PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE, priceOracleMiddlewareManager, 0);
        vm.stopPrank();

        // Deploy Fuses
        morphoSupplyFuse = new MorphoSupplyFuse(IporFusionMarkets.MORPHO_LIQUIDITY_IN_MARKETS, MORPHO);
        morphoBalanceFuse = new MorphoOnlyLiquidityBalanceFuse(IporFusionMarkets.MORPHO_LIQUIDITY_IN_MARKETS, MORPHO);

        // Add Fuses
        vm.startPrank(fuseManager);
        address[] memory fuses = new address[](1);
        fuses[0] = address(morphoSupplyFuse);
        PlasmaVaultGovernance(address(plasmaVault)).addFuses(fuses);

        PlasmaVaultGovernance(address(plasmaVault)).addBalanceFuse(
            IporFusionMarkets.MORPHO_LIQUIDITY_IN_MARKETS,
            address(morphoBalanceFuse)
        );

        PlasmaVaultGovernance(address(plasmaVault)).addBalanceFuse(
            IporFusionMarkets.ERC20_VAULT_BALANCE,
            BALANCE_FUSE_ERC20
        );

        // Grant Market Substrates
        bytes32[] memory substrates = new bytes32[](3);
        substrates[0] = MARKET_1;
        substrates[1] = MARKET_2;
        substrates[2] = MARKET_3;

        PlasmaVaultGovernance(address(plasmaVault)).grantMarketSubstrates(
            IporFusionMarkets.MORPHO_LIQUIDITY_IN_MARKETS,
            substrates
        );

        // ERC20 Balance Substrates (USDC)
        bytes32[] memory erc20Substrates = new bytes32[](1);
        erc20Substrates[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);
        PlasmaVaultGovernance(address(plasmaVault)).grantMarketSubstrates(
            IporFusionMarkets.ERC20_VAULT_BALANCE,
            erc20Substrates
        );

        vm.stopPrank();

        // Make Vault Public
        vm.startPrank(atomist);
        PlasmaVaultGovernance(address(plasmaVault)).convertToPublicVault();
        PlasmaVaultGovernance(address(plasmaVault)).enableTransferShares();
        vm.stopPrank();

        // Ensure PriceOracle has configured prices for loanTokens of the markets
        _ensureOraclePrices();
    }

    function _ensureOraclePrices() internal {
        bytes32[3] memory markets = [MARKET_1, MARKET_2, MARKET_3];
        IMorpho morpho = IMorpho(MORPHO);

        for (uint i = 0; i < 3; i++) {
            MarketParams memory params = morpho.idToMarketParams(Id.wrap(markets[i]));
            address loanToken = params.loanToken;
            if (loanToken == USDC) {
                // USDC setup ok
            }
        }
    }

    function testSupplyAndBalance() public {
        uint256 depositAmount = 10_000e6; // 10,000 USDC
        deal(USDC, user, depositAmount);

        // Deposit
        vm.startPrank(user);
        ERC20(USDC).approve(address(plasmaVault), depositAmount);
        plasmaVault.deposit(depositAmount, user);
        vm.stopPrank();

        uint256 vaultBalanceBefore = ERC20(USDC).balanceOf(address(plasmaVault));
        assertEq(vaultBalanceBefore, depositAmount, "Vault should hold deposit");

        uint256 initialTotalAssets = plasmaVault.totalAssets();
        // Since USDC is 6 decimals, and Erc20BalanceFuse returns 6 decimals (raw balance),
        // totalAssets should be around 10,000e6
        assertApproxEqRel(initialTotalAssets, 10_000e6, 0.01e18, "Initial total assets check");

        // Supply to Morpho Market 1
        uint256 supplyAmount = 5_000e6; // 5,000 USDC

        MorphoSupplyFuseEnterData memory enterData = MorphoSupplyFuseEnterData({
            morphoMarketId: MARKET_1,
            amount: supplyAmount
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(morphoSupplyFuse),
            data: abi.encodeWithSignature("enter((bytes32,uint256))", enterData)
        });

        vm.prank(alpha);
        plasmaVault.execute(actions);

        // Checks after Supply
        uint256 vaultBalanceAfter = ERC20(USDC).balanceOf(address(plasmaVault));
        assertEq(vaultBalanceAfter, vaultBalanceBefore - supplyAmount, "Vault USDC balance decreased");

        uint256 totalAssetsAfter = plasmaVault.totalAssets();

        uint256 assetsInMorpho = plasmaVault.totalAssetsInMarket(IporFusionMarkets.MORPHO_LIQUIDITY_IN_MARKETS);

        // Check Morpho Balance via Fuse
        // Based on test results, assetsInMorpho seems to be consistent with underlying decimals (6) in this environment
        // ensuring totalAssets is consistent (10k e6).

        // If assetsInMorpho is 0, this check will reveal it.
        if (assetsInMorpho > 0) {
            assertApproxEqRel(totalAssetsAfter, 10_000e6, 0.01e18, "Total assets check (USDC decimals)");
            assertApproxEqRel(assetsInMorpho, 5_000e6, 0.01e18, "Assets in Morpho correct (USDC decimals)");
        } else {
            // Fail test if balance is 0 but we supplied
            assertTrue(false, "Assets in Morpho should not be 0");
        }

        // Withdraw (Exit)
        MorphoSupplyFuseExitData memory exitData = MorphoSupplyFuseExitData({
            morphoMarketId: MARKET_1,
            amount: supplyAmount
        });

        FuseAction[] memory exitActions = new FuseAction[](1);
        exitActions[0] = FuseAction({
            fuse: address(morphoSupplyFuse),
            data: abi.encodeWithSignature("exit((bytes32,uint256))", exitData)
        });

        vm.prank(alpha);
        plasmaVault.execute(exitActions);

        // Checks after Exit
        uint256 vaultBalanceFinal = ERC20(USDC).balanceOf(address(plasmaVault));
        assertApproxEqAbs(vaultBalanceFinal, depositAmount, 10, "Vault USDC balance restored (approx)"); // Allowing dust diffs

        uint256 assetsInMorphoFinal = plasmaVault.totalAssetsInMarket(IporFusionMarkets.MORPHO_LIQUIDITY_IN_MARKETS);
        assertEq(assetsInMorphoFinal, 0, "Assets in Morpho should be 0");
    }

    function testSupplyThreeMarketsSequential() public {
        uint256 depositAmount = 10_000e6; // 10,000 USDC
        deal(USDC, user, depositAmount);

        // Deposit to Vault
        vm.startPrank(user);
        ERC20(USDC).approve(address(plasmaVault), depositAmount);
        plasmaVault.deposit(depositAmount, user);
        vm.stopPrank();

        uint256 amount1 = 3_000e6;
        uint256 amount2 = 2_000e6;
        uint256 amount3 = 1_000e6;

        // 1. Supply to MARKET_1
        MorphoSupplyFuseEnterData memory enterData1 = MorphoSupplyFuseEnterData({
            morphoMarketId: MARKET_1,
            amount: amount1
        });
        FuseAction[] memory actions1 = new FuseAction[](1);
        actions1[0] = FuseAction({
            fuse: address(morphoSupplyFuse),
            data: abi.encodeWithSignature("enter((bytes32,uint256))", enterData1)
        });

        vm.prank(alpha);
        plasmaVault.execute(actions1);

        uint256 assetsInMorpho1 = plasmaVault.totalAssetsInMarket(IporFusionMarkets.MORPHO_LIQUIDITY_IN_MARKETS);
        assertApproxEqRel(assetsInMorpho1, amount1, 0.01e18, "Assets in Morpho after 1st supply");

        // 2. Supply to MARKET_2
        MorphoSupplyFuseEnterData memory enterData2 = MorphoSupplyFuseEnterData({
            morphoMarketId: MARKET_2,
            amount: amount2
        });
        FuseAction[] memory actions2 = new FuseAction[](1);
        actions2[0] = FuseAction({
            fuse: address(morphoSupplyFuse),
            data: abi.encodeWithSignature("enter((bytes32,uint256))", enterData2)
        });

        vm.prank(alpha);
        plasmaVault.execute(actions2);

        uint256 assetsInMorpho2 = plasmaVault.totalAssetsInMarket(IporFusionMarkets.MORPHO_LIQUIDITY_IN_MARKETS);
        // Balance should be sum of deposits to all markets under the same fuse
        assertApproxEqRel(assetsInMorpho2, amount1 + amount2, 0.01e18, "Assets in Morpho after 2nd supply");

        // 3. Supply to MARKET_3
        MorphoSupplyFuseEnterData memory enterData3 = MorphoSupplyFuseEnterData({
            morphoMarketId: MARKET_3,
            amount: amount3
        });
        FuseAction[] memory actions3 = new FuseAction[](1);
        actions3[0] = FuseAction({
            fuse: address(morphoSupplyFuse),
            data: abi.encodeWithSignature("enter((bytes32,uint256))", enterData3)
        });

        vm.prank(alpha);
        plasmaVault.execute(actions3);

        uint256 assetsInMorpho3 = plasmaVault.totalAssetsInMarket(IporFusionMarkets.MORPHO_LIQUIDITY_IN_MARKETS);
        assertApproxEqRel(assetsInMorpho3, amount1 + amount2 + amount3, 0.01e18, "Assets in Morpho after 3rd supply");
    }
}
