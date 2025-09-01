// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {PlasmaVault, PlasmaVaultInitData, FuseAction, MarketSubstratesConfig, MarketBalanceFuseConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";
import {FusionFactory} from "../../../contracts/factory/FusionFactory.sol";
import {FusionFactoryLib} from "../../../contracts/factory/lib/FusionFactoryLib.sol";
import {FusionFactoryStorageLib} from "../../../contracts/factory/lib/FusionFactoryStorageLib.sol";
import {RewardsManagerFactory} from "../../../contracts/factory/RewardsManagerFactory.sol";
import {WithdrawManagerFactory} from "../../../contracts/factory/WithdrawManagerFactory.sol";
import {ContextManagerFactory} from "../../../contracts/factory/ContextManagerFactory.sol";
import {PriceManagerFactory} from "../../../contracts/factory/PriceManagerFactory.sol";
import {PlasmaVaultFactory} from "../../../contracts/factory/PlasmaVaultFactory.sol";
import {AccessManagerFactory} from "../../../contracts/factory/AccessManagerFactory.sol";
import {FeeManagerFactory} from "../../../contracts/managers/fee/FeeManagerFactory.sol";
import {MockERC20} from "../../test_helpers/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {BurnRequestFeeFuse} from "../../../contracts/fuses/burn_request_fee/BurnRequestFeeFuse.sol";
import {ZeroBalanceFuse} from "../../../contracts/fuses/ZeroBalanceFuse.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {IPriceFeed} from "../../../contracts/price_oracle/price_feed/IPriceFeed.sol";
import {PriceOracleMiddlewareManager} from "../../../contracts/managers/price/PriceOracleMiddlewareManager.sol";

import {TacStakingStorageLib} from "../../../contracts/fuses/tac/lib/TacStakingStorageLib.sol";
import {TacStakingDelegatorAddressReader} from "../../../contracts/readers/TacStakingDelegatorAddressReader.sol";
import {InstantWithdrawalFusesParamsStruct} from "../../../contracts/libraries/PlasmaVaultLib.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {TacValidatorAddressConverter} from "../../../contracts/fuses/tac/lib/TacValidatorAddressConverter.sol";
import {Description, CommissionRates} from "../../../contracts/fuses/tac/ext/IStaking.sol";
import {IporMath} from "../../../contracts/libraries/math/IporMath.sol";
import {IPriceOracleMiddleware} from "../../../contracts/price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultLib} from "../../../contracts/libraries/PlasmaVaultLib.sol";

import {BalanceFusesReader} from "../../../contracts/readers/BalanceFusesReader.sol";

// Import Yield Basis fuses
import {YieldBasisLtBalanceFuse} from "../../../contracts/fuses/yield_basis/YieldBasisLtBalanceFuse.sol";
import {YieldBasisLtSupplyFuse, YieldBasisLtSupplyFuseEnterData, YieldBasisLtSupplyFuseExitData} from "../../../contracts/fuses/yield_basis/YieldBasisLtSupplyFuse.sol";
import {IYieldBasisLT} from "../../../contracts/fuses/yield_basis/ext/IYieldBasisLT.sol";

// Import test helpers
import {PlasmaVaultHelper, DeployMinimalPlasmaVaultParams} from "../../test_helpers/PlasmaVaultHelper.sol";
import {IporFusionAccessManagerHelper} from "../../test_helpers/IporFusionAccessManagerHelper.sol";
import {RewardsClaimManager} from "../../../contracts/managers/rewards/RewardsClaimManager.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {PriceOracleMiddlewareHelper} from "../../test_helpers/PriceOracleMiddlewareHelper.sol";

contract YieldBasisFuseTest is Test {
    // address constant FUSION_FACTORY = 0x134fCAce7a2C7Ef3dF2479B62f03ddabAEa922d5;
    address constant FUSION_PRICE_MANAGER = 0x134fCAce7a2C7Ef3dF2479B62f03ddabAEa922d5;

    address constant YIELD_BASIS_LT_WBTC = 0xcAcdDFb1a22EE46687a0ccE4955E311318DB698f;
    address constant YIELD_BASIS_LT_WBTC_ADMIN = 0xa614A6456189773CFC5f9Fb174577e1034803E28;

    address constant WBTC = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;
    address constant WBTC_HOLDER = 0x078f358208685046a11C85e8ad32895DED33A249;

    // Constants from StakeDaoV2FuseTest
    address constant CHAINLINK_PRICE_FEED_USDC = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    address constant CHAINLINK_PRICE_FEED_CRV_USD = 0x0a32255dd4BB6177C994bAAc73E0606fDD568f66;
    address constant CHAINLINK_PRICE_FEED_WBTC = 0x6ce185860a4963106506C203335A2910413708e9;
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant CRV_USD = 0x498Bf2B1e120FeD3ad3D42EA2165E9b73f99C1e5;

    // Custom market ID for Yield Basis
    uint256 constant YIELD_BASIS_MARKET_ID = IporFusionMarkets.YIELD_BASIS_LT;

    address user;
    address atomist;
    address alpha;

    bytes32[] substrates;
    address yieldBasisSupplyFuse;
    address yieldBasisBalanceFuse;

    // Fusion Factory related variables
    FusionFactory fusionFactory;
    PlasmaVault plasmaVault;
    IporFusionAccessManager accessManager;
    address withdrawManager;
    address priceOracle;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 373531486);

        user = address(0x333);
        atomist = address(0x777);
        alpha = address(0x555);

        _setupFusionFactory();
    }

    function testShouldCreateVaultWithFusionFactoryAndConfigureYieldBasisFuses() public {
        // Create vault using fusion factory
        _createVaultWithFusionFactory();

        // Verify vault was created successfully
        assertTrue(address(plasmaVault) != address(0), "Plasma vault should be created");
        assertTrue(address(accessManager) != address(0), "Access manager should be created");

        // Grant necessary roles to atomist
        vm.startPrank(atomist);
        accessManager.grantRole(Roles.ATOMIST_ROLE, atomist, 0);
        accessManager.grantRole(Roles.FUSE_MANAGER_ROLE, atomist, 0);
        vm.stopPrank();

        // Configure yield basis fuses after vault creation
        _addYieldBasisFuses();

        // Verify yield basis fuses are configured
        PlasmaVaultGovernance governanceVault = PlasmaVaultGovernance(address(plasmaVault));

        // Check if balance fuse is supported
        assertTrue(
            governanceVault.isBalanceFuseSupported(YIELD_BASIS_MARKET_ID, yieldBasisBalanceFuse),
            "Yield basis balance fuse should be supported"
        );

        // Check if supply fuse is in the fuses list
        address[] memory fuses = governanceVault.getFuses();
        bool foundSupplyFuse = false;
        for (uint256 i = 0; i < fuses.length; i++) {
            if (fuses[i] == yieldBasisSupplyFuse) {
                foundSupplyFuse = true;
                break;
            }
        }
        assertTrue(foundSupplyFuse, "Yield basis supply fuse should be in fuses list");

        // Verify substrates are granted
        bytes32[] memory grantedSubstrates = governanceVault.getMarketSubstrates(YIELD_BASIS_MARKET_ID);
        assertEq(grantedSubstrates.length, 1, "Should have one substrate granted");
        assertEq(
            PlasmaVaultConfigLib.bytes32ToAddress(grantedSubstrates[0]),
            YIELD_BASIS_LT_WBTC,
            "Substrate should be YIELD_BASIS_LT_WBTC"
        );

        // Test balance calculation by calling the balance fuse directly
        uint256 balance = YieldBasisLtBalanceFuse(yieldBasisBalanceFuse).balanceOf();
        assertTrue(balance >= 0, "Balance should be calculated successfully");

        // Test total assets in market
        uint256 totalAssetsInMarket = plasmaVault.totalAssetsInMarket(YIELD_BASIS_MARKET_ID);
        assertTrue(totalAssetsInMarket >= 0, "Total assets in market should be calculated successfully");
    }

    function _setupFusionFactory() private {
        FusionFactoryStorageLib.FactoryAddresses memory factoryAddresses = FusionFactoryStorageLib.FactoryAddresses({
            accessManagerFactory: address(new AccessManagerFactory()),
            plasmaVaultFactory: address(new PlasmaVaultFactory()),
            feeManagerFactory: address(new FeeManagerFactory()),
            withdrawManagerFactory: address(new WithdrawManagerFactory()),
            rewardsManagerFactory: address(new RewardsManagerFactory()),
            contextManagerFactory: address(new ContextManagerFactory()),
            priceManagerFactory: address(new PriceManagerFactory())
        });

        address plasmaVaultBase = address(new PlasmaVaultBase());
        address burnRequestFeeFuse = address(new BurnRequestFeeFuse(IporFusionMarkets.ZERO_BALANCE_MARKET));
        address burnRequestFeeBalanceFuse = address(new ZeroBalanceFuse(IporFusionMarkets.ZERO_BALANCE_MARKET));

        PriceOracleMiddleware priceOracleMiddlewareImplementation = new PriceOracleMiddleware(address(0));
        address priceOracleMiddleware = address(
            new ERC1967Proxy(
                address(priceOracleMiddlewareImplementation),
                abi.encodeWithSignature("initialize(address)", atomist)
            )
        );

        FusionFactory implementation = new FusionFactory();
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address[],(address,address,address,address,address,address,address),address,address,address,address)",
            atomist,
            new address[](0), // No plasma vault admins
            factoryAddresses,
            plasmaVaultBase,
            priceOracleMiddleware,
            burnRequestFeeFuse,
            burnRequestFeeBalanceFuse
        );
        fusionFactory = FusionFactory(address(new ERC1967Proxy(address(implementation), initData)));

        vm.startPrank(atomist);
        fusionFactory.grantRole(fusionFactory.DAO_FEE_MANAGER_ROLE(), atomist);
        vm.stopPrank();

        vm.startPrank(atomist);
        fusionFactory.updateDaoFee(atomist, 100, 100);
        vm.stopPrank();
    }

    function _setupPriceOracleMiddleware() private {
        address[] memory assets = new address[](1);
        address[] memory sources = new address[](1);
        assets[0] = WBTC;
        sources[0] = CHAINLINK_PRICE_FEED_WBTC;
        
        vm.startPrank(atomist);
        PriceOracleMiddlewareManager(priceOracle).setAssetsPriceSources(assets, sources);
        vm.stopPrank();
    }

    function _createVaultWithFusionFactory() private {
        FusionFactoryLib.FusionInstance memory instance = fusionFactory.create(
            "Yield Basis Vault",
            "yieldBasisVault",
            WBTC,
            1 seconds,
            atomist
        );

        plasmaVault = PlasmaVault(instance.plasmaVault);
        accessManager = IporFusionAccessManager(instance.accessManager);
        withdrawManager = instance.withdrawManager;
        priceOracle = instance.priceManager;
    }

    function _prepareLTContractConfig() private {
        vm.startPrank(YIELD_BASIS_LT_WBTC_ADMIN);
        IYieldBasisLT(YIELD_BASIS_LT_WBTC).set_admin(address(plasmaVault));
        vm.stopPrank();

        // No callback handlers needed - admin functions are handled by PlasmaVaultBase directly
    }

    function _addYieldBasisFuses() private {
        // Deploy yield basis fuses
        yieldBasisSupplyFuse = address(new YieldBasisLtSupplyFuse(YIELD_BASIS_MARKET_ID));
        yieldBasisBalanceFuse = address(new YieldBasisLtBalanceFuse(YIELD_BASIS_MARKET_ID));

        address[] memory fuses = new address[](1);
        fuses[0] = yieldBasisSupplyFuse;

        vm.startPrank(atomist);
        PlasmaVaultGovernance(address(plasmaVault)).addFuses(fuses);
        PlasmaVaultGovernance(address(plasmaVault)).addBalanceFuse(YIELD_BASIS_MARKET_ID, yieldBasisBalanceFuse);

        // Set up substrates for yield basis (LT addresses as assets)
        substrates = new bytes32[](1);
        substrates[0] = bytes32(uint256(uint160(YIELD_BASIS_LT_WBTC)));

        PlasmaVaultGovernance(address(plasmaVault)).grantMarketSubstrates(YIELD_BASIS_MARKET_ID, substrates);
        vm.stopPrank();
    }

    function _setupSimpleVault() private {
        // Use PlasmaVaultHelper to create a simple vault with proper role setup

        // Deploy price oracle middleware
        vm.startPrank(atomist);
        PriceOracleMiddleware priceOracleMiddleware = PriceOracleMiddlewareHelper.deployPriceOracleMiddleware(
            atomist,
            address(0)
        );
        vm.stopPrank();

        // Deploy minimal plasma vault
        DeployMinimalPlasmaVaultParams memory params = DeployMinimalPlasmaVaultParams({
            underlyingToken: WBTC,
            underlyingTokenName: "WBTC",
            priceOracleMiddleware: PriceOracleMiddlewareHelper.addressOf(priceOracleMiddleware),
            atomist: atomist
        });

        vm.startPrank(atomist);
        (plasmaVault, withdrawManager) = PlasmaVaultHelper.deployMinimalPlasmaVault(params);

        accessManager = IporFusionAccessManager(plasmaVault.authority());

        // Create custom role addresses for our test
        IporFusionAccessManagerHelper.RoleAddresses memory customRoles = IporFusionAccessManagerHelper.RoleAddresses({
            daos: new address[](1),
            admins: new address[](1),
            owners: new address[](1),
            atomists: new address[](1),
            alphas: new address[](1),
            guardians: new address[](1),
            fuseManagers: new address[](1),
            claimRewards: new address[](1),
            transferRewardsManagers: new address[](1),
            configInstantWithdrawalFusesManagers: new address[](1),
            updateMarketsBalancesAccounts: new address[](1),
            updateRewardsBalanceAccounts: new address[](1),
            withdrawManagerRequestFeeManagers: new address[](1),
            withdrawManagerWithdrawFeeManagers: new address[](1),
            priceOracleMiddlewareManagers: new address[](1),
            whitelist: new address[](0),
            preHooksManagers: new address[](1)
        });

        customRoles.daos[0] = atomist;
        customRoles.admins[0] = atomist;
        customRoles.owners[0] = atomist;
        customRoles.atomists[0] = atomist;
        customRoles.alphas[0] = alpha;
        customRoles.guardians[0] = atomist;
        customRoles.fuseManagers[0] = atomist;
        customRoles.claimRewards[0] = alpha;
        customRoles.transferRewardsManagers[0] = alpha;
        customRoles.configInstantWithdrawalFusesManagers[0] = atomist;
        customRoles.updateMarketsBalancesAccounts[0] = atomist;
        customRoles.updateRewardsBalanceAccounts[0] = alpha;
        customRoles.withdrawManagerRequestFeeManagers[0] = atomist;
        customRoles.withdrawManagerWithdrawFeeManagers[0] = atomist;
        customRoles.priceOracleMiddlewareManagers[0] = atomist;
        customRoles.preHooksManagers[0] = atomist;

        IporFusionAccessManagerHelper.setupInitRoles(
            accessManager,
            plasmaVault,
            customRoles,
            withdrawManager,
            address(new RewardsClaimManager(address(accessManager), address(plasmaVault)))
        );
    }

    function testShouldSupplyAndWithdrawFromYieldBasis() public {
        _createVaultWithFusionFactory();
        
        vm.startPrank(atomist);
        accessManager.grantRole(Roles.ATOMIST_ROLE, atomist, 0);
        accessManager.grantRole(Roles.FUSE_MANAGER_ROLE, atomist, 0);
        accessManager.grantRole(Roles.PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE, atomist, 0);
        vm.stopPrank();
        
        _setupPriceOracleMiddleware();

        _prepareLTContractConfig();

        vm.startPrank(atomist);
        accessManager.grantRole(Roles.ALPHA_ROLE, alpha, 0);
        vm.stopPrank();

        _addYieldBasisFuses();

        uint256 supplyAmount = 1e5; 
        _fundVaultWithWBTC(supplyAmount);

        // Check initial market balance
        uint256 totalAssetsInMarketBefore = plasmaVault.totalAssetsInMarket(YIELD_BASIS_MARKET_ID);
        assertEq(totalAssetsInMarketBefore, 0, "Market balance should be 0 before supply");

        // Prepare supply action
        YieldBasisLtSupplyFuseEnterData memory enterData = YieldBasisLtSupplyFuseEnterData({
            ltAddress: YIELD_BASIS_LT_WBTC,
            ltAssets: supplyAmount,
            minLtAssets: (supplyAmount * 99) / 100, // 1% slippage tolerance
            debt: 0, 
            minShares: (supplyAmount * 99) / 100 // 1% slippage tolerance
        });

        FuseAction[] memory supplyActions = new FuseAction[](1);
        supplyActions[0] = FuseAction({
            fuse: yieldBasisSupplyFuse,
            data: abi.encodeWithSignature("enter((address,uint256,uint256,uint256,uint256))", enterData)
        });

        uint256 totalAssetBefore = plasmaVault.totalAssets();
        uint256 wbtcBalanceBefore = IERC20(WBTC).balanceOf(address(plasmaVault));
// 0. 00052778 5065606808
        // Execute supply
        vm.prank(alpha);
        plasmaVault.execute(supplyActions);

        // Verify supply
        uint256 yieldBasisLtBalanceAfterSupply = IYieldBasisLT(YIELD_BASIS_LT_WBTC).balanceOf(address(plasmaVault));
        uint256 balanceInMarketAfterSupply = plasmaVault.totalAssetsInMarket(YIELD_BASIS_MARKET_ID);
        uint256 wbtcBalanceAfter = IERC20(WBTC).balanceOf(address(plasmaVault));

        assertGt(yieldBasisLtBalanceAfterSupply, 0, "Should have Yield Basis LT tokens after supply");
        assertGt(balanceInMarketAfterSupply, 0, "Market balance should be greater than 0 after supply");
        assertLt(wbtcBalanceAfter, wbtcBalanceBefore, "WBTC balance should decrease after supply");

        // Setup for withdrawal
        uint256 withdrawAmount = supplyAmount / 2; // Withdraw half

        // Prepare withdrawal action
        YieldBasisLtSupplyFuseExitData memory exitData = YieldBasisLtSupplyFuseExitData({
            ltAddress: YIELD_BASIS_LT_WBTC,
            ltShares: yieldBasisLtBalanceAfterSupply / 2, // Withdraw half of the shares
            minLtShares: ((yieldBasisLtBalanceAfterSupply / 2) * 99) / 100, // 1% slippage tolerance
            minLtAssets: (withdrawAmount * 99) / 100 // 1% slippage tolerance
        });

        FuseAction[] memory withdrawActions = new FuseAction[](1);
        withdrawActions[0] = FuseAction({
            fuse: yieldBasisSupplyFuse,
            data: abi.encodeWithSignature("exit((address,uint256,uint256,uint256))", exitData)
        });

        // Execute withdrawal
        vm.prank(alpha);
        plasmaVault.execute(withdrawActions);

        // Final verifications
        uint256 yieldBasisLtBalanceAfterWithdraw = IYieldBasisLT(YIELD_BASIS_LT_WBTC).balanceOf(address(plasmaVault));
        uint256 totalAssetAfter = plasmaVault.totalAssets();
        uint256 balanceInMarketAfter = plasmaVault.totalAssetsInMarket(YIELD_BASIS_MARKET_ID);
        uint256 wbtcBalanceFinal = IERC20(WBTC).balanceOf(address(plasmaVault));

        assertLt(
            yieldBasisLtBalanceAfterWithdraw,
            yieldBasisLtBalanceAfterSupply,
            "LT balance should decrease after withdrawal"
        );
        assertGt(wbtcBalanceFinal, wbtcBalanceAfter, "WBTC balance should increase after withdrawal");
        assertGt(balanceInMarketAfter, 0, "Market balance should still be greater than 0");
        
        console2.log("totalAssetAfter", totalAssetAfter);
        console2.log("totalAssetBefore", totalAssetBefore);
    }

    function testShouldVerifyAlphaRoleSetup() public {
        // Setup vault and fuses using the same approach as the existing test
        _createVaultWithFusionFactory();

        // Grant necessary roles to atomist and alpha
        vm.startPrank(atomist);
        accessManager.grantRole(Roles.ATOMIST_ROLE, atomist, 0);
        accessManager.grantRole(Roles.FUSE_MANAGER_ROLE, atomist, 0);
        vm.stopPrank();

        // Now grant alpha role using atomist who has ATOMIST_ROLE
        vm.startPrank(atomist);
        accessManager.grantRole(Roles.ALPHA_ROLE, alpha, 0);
        vm.stopPrank();

        // Configure yield basis fuses
        _addYieldBasisFuses();

        // Verify that alpha has the ALPHA_ROLE
        (bool hasAlphaRole, ) = accessManager.hasRole(Roles.ALPHA_ROLE, alpha);
        assertTrue(hasAlphaRole, "Alpha should have ALPHA_ROLE");

        // Verify that atomist has the ATOMIST_ROLE
        (bool hasAtomistRole, ) = accessManager.hasRole(Roles.ATOMIST_ROLE, atomist);
        assertTrue(hasAtomistRole, "Atomist should have ATOMIST_ROLE");

        // Try to execute a simple action to verify permissions
        FuseAction[] memory emptyActions = new FuseAction[](0);

        // This should not revert if alpha has proper permissions
        vm.prank(alpha);
        plasmaVault.execute(emptyActions);
    }

    function testShouldSupplyAndWithdrawMultipleTimes() public {
        // Setup vault and fuses
        _createVaultWithFusionFactory();
        _grantRoles();
        _addYieldBasisFuses();

        // Fund the vault with WBTC for testing
        uint256 initialAmount = 2e8; // 2 WBTC
        _fundVaultWithWBTC(initialAmount);

        // First supply: 1 WBTC
        uint256 firstSupplyAmount = 1e8;
        _executeSupply(firstSupplyAmount);

        // Verify first supply
        uint256 balanceInMarketAfterFirstSupply = plasmaVault.totalAssetsInMarket(YIELD_BASIS_MARKET_ID);
        uint256 ltBalanceAfterFirstSupply = IYieldBasisLT(YIELD_BASIS_LT_WBTC).balanceOf(address(plasmaVault));

        assertGt(balanceInMarketAfterFirstSupply, 0, "Market balance should be greater than 0 after first supply");
        assertGt(ltBalanceAfterFirstSupply, 0, "LT balance should be greater than 0 after first supply");

        // Second supply: 0.5 WBTC
        uint256 secondSupplyAmount = 5e7; // 0.5 WBTC
        _executeSupply(secondSupplyAmount);

        // Verify second supply
        uint256 balanceInMarketAfterSecondSupply = plasmaVault.totalAssetsInMarket(YIELD_BASIS_MARKET_ID);
        uint256 ltBalanceAfterSecondSupply = IYieldBasisLT(YIELD_BASIS_LT_WBTC).balanceOf(address(plasmaVault));

        assertGt(
            balanceInMarketAfterSecondSupply,
            balanceInMarketAfterFirstSupply,
            "Market balance should increase after second supply"
        );
        assertGt(
            ltBalanceAfterSecondSupply,
            ltBalanceAfterFirstSupply,
            "LT balance should increase after second supply"
        );

        // First withdrawal: 0.3 WBTC worth
        uint256 firstWithdrawShares = (ltBalanceAfterSecondSupply * 3) / 10; // 30% of shares
        _executeWithdraw(firstWithdrawShares);

        // Verify first withdrawal
        uint256 balanceInMarketAfterFirstWithdraw = plasmaVault.totalAssetsInMarket(YIELD_BASIS_MARKET_ID);
        uint256 ltBalanceAfterFirstWithdraw = IYieldBasisLT(YIELD_BASIS_LT_WBTC).balanceOf(address(plasmaVault));

        assertLt(
            balanceInMarketAfterFirstWithdraw,
            balanceInMarketAfterSecondSupply,
            "Market balance should decrease after first withdrawal"
        );
        assertLt(
            ltBalanceAfterFirstWithdraw,
            ltBalanceAfterSecondSupply,
            "LT balance should decrease after first withdrawal"
        );

        // Second withdrawal: remaining shares
        _executeWithdraw(ltBalanceAfterFirstWithdraw);

        // Verify final state
        uint256 finalLtBalance = IYieldBasisLT(YIELD_BASIS_LT_WBTC).balanceOf(address(plasmaVault));
        uint256 finalMarketBalance = plasmaVault.totalAssetsInMarket(YIELD_BASIS_MARKET_ID);

        assertApproxEqAbs(finalLtBalance, 0, 1e6, "Final LT balance should be approximately 0");
        assertApproxEqAbs(finalMarketBalance, 0, 1e6, "Final market balance should be approximately 0");
    }

    function testShouldInstantWithdrawFromYieldBasis() public {
        // Setup vault and fuses
        _createVaultWithFusionFactory();
        _grantRoles();
        _addYieldBasisFuses();
        _configureInstantWithdrawFuses();

        // Fund the vault with WBTC for testing
        uint256 supplyAmount = 1e8; // 1 WBTC
        _fundVaultWithWBTC(supplyAmount);

        // Supply to Yield Basis
        _executeSupply(supplyAmount);

        // Verify supply was successful
        uint256 ltBalanceAfterSupply = IYieldBasisLT(YIELD_BASIS_LT_WBTC).balanceOf(address(plasmaVault));
        assertGt(ltBalanceAfterSupply, 0, "Should have LT tokens after supply");

        // Setup user for instant withdrawal
        address testUser = address(0x123);
        uint256 userDepositAmount = 5e7; // 0.5 WBTC
        _setupUserForWithdrawal(testUser, userDepositAmount);

        // Get max withdraw amount for user
        uint256 userMaxWithdraw = plasmaVault.maxWithdraw(testUser);
        assertGt(userMaxWithdraw, 0, "User should have withdrawable amount");

        // Record balances before instant withdrawal
        uint256 vaultLtBalanceBefore = IYieldBasisLT(YIELD_BASIS_LT_WBTC).balanceOf(address(plasmaVault));
        uint256 userBalanceBefore = IERC20(WBTC).balanceOf(testUser);
        uint256 marketBalanceBefore = plasmaVault.totalAssetsInMarket(YIELD_BASIS_MARKET_ID);

        // Execute instant withdrawal
        vm.prank(testUser);
        plasmaVault.withdraw(userMaxWithdraw, testUser, testUser);

        // Verify instant withdrawal
        uint256 vaultLtBalanceAfter = IYieldBasisLT(YIELD_BASIS_LT_WBTC).balanceOf(address(plasmaVault));
        uint256 userBalanceAfter = IERC20(WBTC).balanceOf(testUser);
        uint256 marketBalanceAfter = plasmaVault.totalAssetsInMarket(YIELD_BASIS_MARKET_ID);

        assertGt(userBalanceAfter, userBalanceBefore, "User should receive WBTC after instant withdrawal");
        assertLt(
            vaultLtBalanceAfter,
            vaultLtBalanceBefore,
            "Vault LT balance should decrease after instant withdrawal"
        );
        assertLt(marketBalanceAfter, marketBalanceBefore, "Market balance should decrease after instant withdrawal");
    }

    function testShouldHandleZeroAmountSupplyAndWithdraw() public {
        // Setup vault and fuses
        _createVaultWithFusionFactory();
        _grantRoles();
        _addYieldBasisFuses();

        // Test zero amount supply
        YieldBasisLtSupplyFuseEnterData memory zeroEnterData = YieldBasisLtSupplyFuseEnterData({
            ltAddress: YIELD_BASIS_LT_WBTC,
            ltAssets: 0,
            minLtAssets: 0,
            debt: 0,
            minShares: 0
        });

        FuseAction[] memory zeroSupplyActions = new FuseAction[](1);
        zeroSupplyActions[0] = FuseAction({
            fuse: yieldBasisSupplyFuse,
            data: abi.encodeWithSignature("enter((address,uint256,uint256,uint256,uint256))", zeroEnterData)
        });

        // Should not revert with zero amount
        vm.prank(alpha);
        plasmaVault.execute(zeroSupplyActions);

        // Test zero amount withdrawal
        YieldBasisLtSupplyFuseExitData memory zeroExitData = YieldBasisLtSupplyFuseExitData({
            ltAddress: YIELD_BASIS_LT_WBTC,
            ltShares: 0,
            minLtShares: 0,
            minLtAssets: 0
        });

        FuseAction[] memory zeroWithdrawActions = new FuseAction[](1);
        zeroWithdrawActions[0] = FuseAction({
            fuse: yieldBasisSupplyFuse,
            data: abi.encodeWithSignature("exit((address,uint256,uint256,uint256))", zeroExitData)
        });

        // Should not revert with zero amount
        vm.prank(alpha);
        plasmaVault.execute(zeroWithdrawActions);
    }

    function testShouldRevertOnUnsupportedAsset() public {
        // Setup vault and fuses
        _createVaultWithFusionFactory();
        _grantRoles();
        _addYieldBasisFuses();

        // Try to supply with unsupported asset
        address unsupportedAsset = address(0x999);
        YieldBasisLtSupplyFuseEnterData memory enterData = YieldBasisLtSupplyFuseEnterData({
            ltAddress: unsupportedAsset,
            ltAssets: 1e8,
            minLtAssets: 1e8,
            debt: 1e8 * 50000,
            minShares: 1e8
        });

        FuseAction[] memory supplyActions = new FuseAction[](1);
        supplyActions[0] = FuseAction({
            fuse: yieldBasisSupplyFuse,
            data: abi.encodeWithSignature("enter((address,uint256,uint256,uint256,uint256))", enterData)
        });

        // Should revert with unsupported asset
        vm.prank(alpha);
        vm.expectRevert();
        plasmaVault.execute(supplyActions);
    }

    // Helper functions
    function _grantRoles() private {
        vm.startPrank(atomist);
        accessManager.grantRole(Roles.ATOMIST_ROLE, atomist, 0);
        accessManager.grantRole(Roles.FUSE_MANAGER_ROLE, atomist, 0);
        accessManager.grantRole(Roles.ALPHA_ROLE, alpha, 0);
        vm.stopPrank();
    }

    function _fundVaultWithWBTC(uint256 amount) private {
        // Fund the vault with WBTC by transferring from a holder
        vm.prank(WBTC_HOLDER);
        IERC20(WBTC).transfer(address(plasmaVault), amount);
    }

    function _executeSupply(uint256 amount) private {
        YieldBasisLtSupplyFuseEnterData memory enterData = YieldBasisLtSupplyFuseEnterData({
            ltAddress: YIELD_BASIS_LT_WBTC,
            ltAssets: amount,
            minLtAssets: (amount * 99) / 100,
            debt: amount * 50000,
            minShares: (amount * 99) / 100
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: yieldBasisSupplyFuse,
            data: abi.encodeWithSignature("enter((address,uint256,uint256,uint256,uint256))", enterData)
        });

        vm.prank(alpha);
        plasmaVault.execute(actions);
    }

    function _executeWithdraw(uint256 shares) private {
        YieldBasisLtSupplyFuseExitData memory exitData = YieldBasisLtSupplyFuseExitData({
            ltAddress: YIELD_BASIS_LT_WBTC,
            ltShares: shares,
            minLtShares: (shares * 99) / 100,
            minLtAssets: 0
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: yieldBasisSupplyFuse,
            data: abi.encodeWithSignature("exit((address,uint256,uint256,uint256))", exitData)
        });

        vm.prank(alpha);
        plasmaVault.execute(actions);
    }

    function _configureInstantWithdrawFuses() private {
        InstantWithdrawalFusesParamsStruct[] memory instantWithdrawFuses = new InstantWithdrawalFusesParamsStruct[](1);

        bytes32[] memory instantWithdrawParams = new bytes32[](2);
        instantWithdrawParams[0] = bytes32(0); // amount placeholder
        instantWithdrawParams[1] = bytes32(uint256(uint160(YIELD_BASIS_LT_WBTC))); // LT address

        instantWithdrawFuses[0] = InstantWithdrawalFusesParamsStruct({
            fuse: yieldBasisSupplyFuse,
            params: instantWithdrawParams
        });

        vm.prank(atomist);
        PlasmaVaultGovernance(address(plasmaVault)).configureInstantWithdrawalFuses(instantWithdrawFuses);
    }

    function _setupUserForWithdrawal(address testUser, uint256 amount) private {
        // Fund user with WBTC
        vm.prank(WBTC_HOLDER);
        IERC20(WBTC).transfer(testUser, amount);

        // User deposits to vault
        vm.startPrank(testUser);
        IERC20(WBTC).approve(address(plasmaVault), amount);
        plasmaVault.deposit(amount, testUser);
        vm.stopPrank();
    }
}
