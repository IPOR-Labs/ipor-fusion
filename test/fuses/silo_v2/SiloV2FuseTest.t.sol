// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "forge-std/Test.sol";

import {PlasmaVault, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {FusionFactory} from "../../../contracts/factory/FusionFactory.sol";
import {FusionFactoryLib} from "../../../contracts/factory/lib/FusionFactoryLib.sol";
import {FusionFactoryLogicLib} from "../../../contracts/factory/lib/FusionFactoryLogicLib.sol";

// SiloV2 Fuses
import {SiloV2BalanceFuse} from "../../../contracts/fuses/silo_v2/SiloV2BalanceFuse.sol";
import {SiloV2SupplyBorrowableCollateralFuse} from "../../../contracts/fuses/silo_v2/SiloV2SupplyBorrowableCollateralFuse.sol";
import {SiloV2SupplyNonBorrowableCollateralFuse} from "../../../contracts/fuses/silo_v2/SiloV2SupplyNonBorrowableCollateralFuse.sol";
import {SiloV2BorrowFuse} from "../../../contracts/fuses/silo_v2/SiloV2BorrowFuse.sol";
import {SiloV2SupplyCollateralFuseEnterData, SiloV2SupplyCollateralFuseExitData} from "../../../contracts/fuses/silo_v2/SiloV2SupplyCollateralFuseAbstract.sol";
import {SiloV2BorrowFuseEnterData, SiloV2BorrowFuseExitData} from "../../../contracts/fuses/silo_v2/SiloV2BorrowFuse.sol";
import {SiloIndex} from "../../../contracts/fuses/silo_v2/SiloIndex.sol";
import {ISiloConfig} from "../../../contracts/fuses/silo_v2/ext/ISiloConfig.sol";
import {IShareToken} from "../../../contracts/fuses/silo_v2/ext/IShareToken.sol";

// Libraries
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";
import {IPriceOracleMiddleware} from "../../../contracts/price_oracle/IPriceOracleMiddleware.sol";
import {PriceOracleMiddlewareManager} from "../../../contracts/managers/price/PriceOracleMiddlewareManager.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {DualCrossReferencePriceFeedFactory} from "../../../contracts/factory/price_feed/DualCrossReferencePriceFeedFactory.sol";

contract SiloV2FuseTest is Test {
    address constant SILO_CONFIG_WEETH_WETH = 0xeC7C5CAaEA12A1a6952F3a3D0e3ca5B678433934;

    address constant WE_ETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    address constant DUAL_CROSS_REFERENCE_PRICE_FEED_FACTORY = 0x8b94c156eBc20a3a385E898Bb7A7973d46d0b303;
    address constant CHAINLINK_WEETH_ETH = 0x5c9C449BbC9a6075A2c061dF312a35fd1E05fF22;

    address PRICE_FEED_WEETH_USD;
    address constant PRICE_FEED_WETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    address constant FUSION_FACTORY_PROXY = 0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852;

    // Test users
    address constant ATOMIST = 0x1111111111111111111111111111111111111111;
    address constant ALPHA = 0x2222222222222222222222222222222222222222;
    address constant USER = 0x3333333333333333333333333333333333333333;

    address constant WE_ETH_HOLDER = 0xBdfa7b7893081B35Fb54027489e2Bc7A38275129;

    // Contracts
    FusionFactory public fusionFactory;
    PlasmaVault public plasmaVault;
    IporFusionAccessManager public accessManager;
    PriceOracleMiddlewareManager public priceOracleMiddlewareManager;
    address public withdrawManager;

    // SiloV2 Fuses
    SiloV2BalanceFuse public siloV2BalanceFuse;
    SiloV2SupplyBorrowableCollateralFuse public siloV2SupplyBorrowableCollateralFuse;
    SiloV2SupplyNonBorrowableCollateralFuse public siloV2SupplyNonBorrowableCollateralFuse;
    SiloV2BorrowFuse public siloV2BorrowFuse;

    // Balance tracking variables
    uint256 public silo0ProtectedBefore;
    uint256 public silo0CollateralBefore;
    uint256 public silo0DebtBefore;
    uint256 public silo1ProtectedBefore;
    uint256 public silo1CollateralBefore;
    uint256 public silo1DebtBefore;

    uint256 public silo0ProtectedAfter;
    uint256 public silo0CollateralAfter;
    uint256 public silo0DebtAfter;
    uint256 public silo1ProtectedAfter;
    uint256 public silo1CollateralAfter;
    uint256 public silo1DebtAfter;

    // Test amounts
    uint256 constant DEPOSIT_WE_ETH_AMOUNT = 100e18; // 100 weETH
    uint256 constant SUPPLY_WE_ETH_AMOUNT = 75e18; // 75 weETH
    uint256 constant BORROW_WETH_AMOUNT = 50e18; // 100 wETH

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 23432022);

        PRICE_FEED_WEETH_USD = DualCrossReferencePriceFeedFactory(DUAL_CROSS_REFERENCE_PRICE_FEED_FACTORY).create(
            WE_ETH,
            CHAINLINK_WEETH_ETH,
            PRICE_FEED_WETH_USD
        );

        fusionFactory = FusionFactory(FUSION_FACTORY_PROXY);

        _createVaultWithFusionFactory();

        _deploySiloV2Fuses();
        _setupRoles();
        _configureSiloV2Fuses();

        _confugurePriceOracleMiddleware();

        vm.prank(WE_ETH_HOLDER);
        ERC20(WE_ETH).transfer(USER, DEPOSIT_WE_ETH_AMOUNT);
        vm.prank(USER);
        ERC20(WE_ETH).approve(address(plasmaVault), DEPOSIT_WE_ETH_AMOUNT);
        vm.prank(USER);
        plasmaVault.deposit(DEPOSIT_WE_ETH_AMOUNT, USER);
    }

    function testShouldSupplyBorrowableCollateral() public {
        // given
        // Get initial vault balance
        uint256 vaultBalanceBefore = plasmaVault.totalAssets();

        // Get initial balances for silo0 and silo1
        (silo0ProtectedBefore, silo0CollateralBefore, silo0DebtBefore) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO0
        );
        (silo1ProtectedBefore, silo1CollateralBefore, silo1DebtBefore) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO1
        );

        // Prepare supply data for borrowable collateral
        SiloV2SupplyCollateralFuseEnterData memory supplyData = SiloV2SupplyCollateralFuseEnterData({
            siloConfig: SILO_CONFIG_WEETH_WETH,
            siloIndex: SiloIndex.SILO0, // Using Silo0 (weETH)
            siloAssetAmount: SUPPLY_WE_ETH_AMOUNT,
            minSiloAssetAmount: SUPPLY_WE_ETH_AMOUNT - 1 // Allow small slippage
        });

        // Create fuse action for alpha execute
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(siloV2SupplyBorrowableCollateralFuse),
            abi.encodeWithSignature("enter((address,uint8,uint256,uint256))", supplyData)
        );

        // when - Execute via alpha
        vm.prank(ALPHA);
        plasmaVault.execute(actions);

        // then - Verify the operation was successful and check balances
        uint256 vaultBalanceAfter = plasmaVault.totalAssets();

        (silo0ProtectedAfter, silo0CollateralAfter, silo0DebtAfter) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO0
        );
        (silo1ProtectedAfter, silo1CollateralAfter, silo1DebtAfter) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO1
        );

        // Verify vault balance remains the same (assets are just moved from vault to SiloV2)
        assertEq(
            vaultBalanceAfter,
            vaultBalanceBefore,
            "Vault total assets should remain the same after supplying collateral"
        );

        // Verify silo0 balances (where we supplied collateral)
        assertEq(silo0ProtectedAfter, silo0ProtectedBefore, "Silo0 protectedShareToken should not change");
        assertGt(silo0CollateralAfter, silo0CollateralBefore, "Silo0 collateralShareToken should increase");
        assertEq(silo0DebtAfter, silo0DebtBefore, "Silo0 debtShareToken should not change");

        // Verify silo1 balances (should remain unchanged)
        assertEq(silo1ProtectedAfter, silo1ProtectedBefore, "Silo1 protectedShareToken should not change");
        assertEq(silo1CollateralAfter, silo1CollateralBefore, "Silo1 collateralShareToken should not change");
        assertEq(silo1DebtAfter, silo1DebtBefore, "Silo1 debtShareToken should not change");
    }

    function testShouldExitSupplyBorrowableCollateral() public {
        // given
        // First supply collateral to silo0 (75 weETH)
        SiloV2SupplyCollateralFuseEnterData memory supplyData = SiloV2SupplyCollateralFuseEnterData({
            siloConfig: SILO_CONFIG_WEETH_WETH,
            siloIndex: SiloIndex.SILO0, // Using Silo0 (weETH)
            siloAssetAmount: SUPPLY_WE_ETH_AMOUNT,
            minSiloAssetAmount: SUPPLY_WE_ETH_AMOUNT - 1 // Allow small slippage
        });

        FuseAction[] memory supplyActions = new FuseAction[](1);
        supplyActions[0] = FuseAction(
            address(siloV2SupplyBorrowableCollateralFuse),
            abi.encodeWithSignature("enter((address,uint8,uint256,uint256))", supplyData)
        );

        vm.prank(ALPHA);
        plasmaVault.execute(supplyActions);

        // Get balances after supply
        (silo0ProtectedBefore, silo0CollateralBefore, silo0DebtBefore) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO0
        );
        (silo1ProtectedBefore, silo1CollateralBefore, silo1DebtBefore) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO1
        );

        uint256 vaultBalanceBeforeExit = plasmaVault.totalAssets();

        // Now prepare exit data - withdraw all collateral shares
        SiloV2SupplyCollateralFuseExitData memory exitData = SiloV2SupplyCollateralFuseExitData({
            siloConfig: SILO_CONFIG_WEETH_WETH,
            siloIndex: SiloIndex.SILO0, // Using Silo0 (weETH)
            siloShares: silo0CollateralBefore, // Withdraw all collateral shares
            minSiloShares: silo0CollateralBefore - 1 // Allow small slippage
        });

        // Create fuse action for exit
        FuseAction[] memory exitActions = new FuseAction[](1);
        exitActions[0] = FuseAction(
            address(siloV2SupplyBorrowableCollateralFuse),
            abi.encodeWithSignature("exit((address,uint8,uint256,uint256))", exitData)
        );

        // when - Execute exit via alpha
        vm.prank(ALPHA);
        plasmaVault.execute(exitActions);

        // then - Verify the exit operation was successful and check balances
        uint256 vaultBalanceAfterExit = plasmaVault.totalAssets();

        (silo0ProtectedAfter, silo0CollateralAfter, silo0DebtAfter) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO0
        );
        (silo1ProtectedAfter, silo1CollateralAfter, silo1DebtAfter) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO1
        );

        // Verify vault balance remains approximately the same (assets are just moved back from SiloV2 to vault)
        assertApproxEqAbsDecimal(
            vaultBalanceAfterExit,
            vaultBalanceBeforeExit,
            1e15,
            18, // decimals
            "Vault total assets should remain approximately the same after exiting collateral"
        );

        // Verify silo0 balances (where we exited collateral)
        assertEq(silo0ProtectedAfter, silo0ProtectedBefore, "Silo0 protectedShareToken should not change");
        assertLt(silo0CollateralAfter, silo0CollateralBefore, "Silo0 collateralShareToken should decrease after exit");
        assertEq(silo0DebtAfter, silo0DebtBefore, "Silo0 debtShareToken should not change");

        // Verify silo1 balances (should remain unchanged)
        assertEq(silo1ProtectedAfter, silo1ProtectedBefore, "Silo1 protectedShareToken should not change");
        assertEq(silo1CollateralAfter, silo1CollateralBefore, "Silo1 collateralShareToken should not change");
        assertEq(silo1DebtAfter, silo1DebtBefore, "Silo1 debtShareToken should not change");
    }

    function testShouldSupplyNonBorrowableCollateral() public {
        // given
        // Get initial vault balance
        uint256 vaultBalanceBefore = plasmaVault.totalAssets();

        // Get initial balances for silo0 and silo1
        (silo0ProtectedBefore, silo0CollateralBefore, silo0DebtBefore) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO0
        );
        (silo1ProtectedBefore, silo1CollateralBefore, silo1DebtBefore) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO1
        );

        // Prepare supply data for non-borrowable collateral
        SiloV2SupplyCollateralFuseEnterData memory supplyData = SiloV2SupplyCollateralFuseEnterData({
            siloConfig: SILO_CONFIG_WEETH_WETH,
            siloIndex: SiloIndex.SILO0, // Using Silo0 (weETH)
            siloAssetAmount: SUPPLY_WE_ETH_AMOUNT,
            minSiloAssetAmount: SUPPLY_WE_ETH_AMOUNT - 1 // Allow small slippage
        });

        // Create fuse action for alpha execute
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(siloV2SupplyNonBorrowableCollateralFuse),
            abi.encodeWithSignature("enter((address,uint8,uint256,uint256))", supplyData)
        );

        // when - Execute via alpha
        vm.prank(ALPHA);
        plasmaVault.execute(actions);

        // then - Verify the operation was successful and check balances
        uint256 vaultBalanceAfter = plasmaVault.totalAssets();

        (silo0ProtectedAfter, silo0CollateralAfter, silo0DebtAfter) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO0
        );
        (silo1ProtectedAfter, silo1CollateralAfter, silo1DebtAfter) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO1
        );

        // Verify vault balance remains the same (assets are just moved from vault to SiloV2)
        assertEq(
            vaultBalanceAfter,
            vaultBalanceBefore,
            "Vault total assets should remain the same after supplying non-borrowable collateral"
        );

        // Verify silo0 balances (where we supplied non-borrowable collateral)
        assertGt(silo0ProtectedAfter, silo0ProtectedBefore, "Silo0 protectedShareToken should increase");
        assertEq(silo0CollateralAfter, silo0CollateralBefore, "Silo0 collateralShareToken should not change");
        assertEq(silo0DebtAfter, silo0DebtBefore, "Silo0 debtShareToken should not change");

        // Verify silo1 balances (should remain unchanged)
        assertEq(silo1ProtectedAfter, silo1ProtectedBefore, "Silo1 protectedShareToken should not change");
        assertEq(silo1CollateralAfter, silo1CollateralBefore, "Silo1 collateralShareToken should not change");
        assertEq(silo1DebtAfter, silo1DebtBefore, "Silo1 debtShareToken should not change");
    }

    function testShouldExitSupplyNonBorrowableCollateral() public {
        // given
        // First supply non-borrowable collateral to silo0 (75 weETH)
        SiloV2SupplyCollateralFuseEnterData memory supplyData = SiloV2SupplyCollateralFuseEnterData({
            siloConfig: SILO_CONFIG_WEETH_WETH,
            siloIndex: SiloIndex.SILO0, // Using Silo0 (weETH)
            siloAssetAmount: SUPPLY_WE_ETH_AMOUNT,
            minSiloAssetAmount: SUPPLY_WE_ETH_AMOUNT - 1 // Allow small slippage
        });

        FuseAction[] memory supplyActions = new FuseAction[](1);
        supplyActions[0] = FuseAction(
            address(siloV2SupplyNonBorrowableCollateralFuse),
            abi.encodeWithSignature("enter((address,uint8,uint256,uint256))", supplyData)
        );

        vm.prank(ALPHA);
        plasmaVault.execute(supplyActions);

        // Get balances after supply
        (silo0ProtectedAfter, silo0CollateralAfter, silo0DebtAfter) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO0
        );
        (silo1ProtectedAfter, silo1CollateralAfter, silo1DebtAfter) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO1
        );

        uint256 vaultBalanceBeforeExit = plasmaVault.totalAssets();

        // Now prepare exit data - withdraw all protected shares
        SiloV2SupplyCollateralFuseExitData memory exitData = SiloV2SupplyCollateralFuseExitData({
            siloConfig: SILO_CONFIG_WEETH_WETH,
            siloIndex: SiloIndex.SILO0, // Using Silo0 (weETH)
            siloShares: silo0ProtectedAfter, // Withdraw all protected shares (75000000000000000000000)
            minSiloShares: silo0ProtectedAfter - 100 // Allow small slippage
        });

        // Create fuse action for exit
        FuseAction[] memory exitActions = new FuseAction[](1);
        exitActions[0] = FuseAction(
            address(siloV2SupplyNonBorrowableCollateralFuse),
            abi.encodeWithSignature("exit((address,uint8,uint256,uint256))", exitData)
        );

        // when - Execute exit via alpha
        vm.prank(ALPHA);
        plasmaVault.execute(exitActions);

        // then - Verify the exit operation was successful and check balances
        uint256 vaultBalanceAfterExit = plasmaVault.totalAssets();

        // Store balances before exit for comparison
        uint256 silo0ProtectedBeforeExit = silo0ProtectedAfter;
        uint256 silo0CollateralBeforeExit = silo0CollateralAfter;
        uint256 silo0DebtBeforeExit = silo0DebtAfter;
        uint256 silo1ProtectedBeforeExit = silo1ProtectedAfter;
        uint256 silo1CollateralBeforeExit = silo1CollateralAfter;
        uint256 silo1DebtBeforeExit = silo1DebtAfter;

        (silo0ProtectedAfter, silo0CollateralAfter, silo0DebtAfter) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO0
        );
        (silo1ProtectedAfter, silo1CollateralAfter, silo1DebtAfter) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO1
        );

        // Log balance changes for debugging
        // Verify vault balance remains approximately the same (assets are just moved back from SiloV2 to vault)
        assertApproxEqAbsDecimal(
            vaultBalanceAfterExit,
            vaultBalanceBeforeExit,
            1e15,
            18, // decimals
            "Vault total assets should remain approximately the same after exiting non-borrowable collateral"
        );

        // Verify silo0 balances (where we exited non-borrowable collateral)
        assertLt(silo0ProtectedAfter, silo0ProtectedBeforeExit, "Silo0 protectedShareToken should decrease after exit");
        assertEq(silo0CollateralAfter, silo0CollateralBeforeExit, "Silo0 collateralShareToken should not change");
        assertEq(silo0DebtAfter, silo0DebtBeforeExit, "Silo0 debtShareToken should not change");

        // Verify silo1 balances (should remain unchanged)
        assertEq(silo1ProtectedAfter, silo1ProtectedBeforeExit, "Silo1 protectedShareToken should not change");
        assertEq(silo1CollateralAfter, silo1CollateralBeforeExit, "Silo1 collateralShareToken should not change");
        assertEq(silo1DebtAfter, silo1DebtBeforeExit, "Silo1 debtShareToken should not change");
    }

    function testShouldBorrowFromSilo1WhenCollateralIsInSilo0NoDependencyGraph() public {
        // given
        // Get initial vault balance

        // Get initial balances for silo0 and silo1
        (silo0ProtectedBefore, silo0CollateralBefore, silo0DebtBefore) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO0
        );
        (silo1ProtectedBefore, silo1CollateralBefore, silo1DebtBefore) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO1
        );

        // First supply collateral to silo0 (75 weETH)
        SiloV2SupplyCollateralFuseEnterData memory supplyData = SiloV2SupplyCollateralFuseEnterData({
            siloConfig: SILO_CONFIG_WEETH_WETH,
            siloIndex: SiloIndex.SILO0, // Using Silo0 (weETH)
            siloAssetAmount: SUPPLY_WE_ETH_AMOUNT,
            minSiloAssetAmount: SUPPLY_WE_ETH_AMOUNT - 1 // Allow small slippage
        });

        // Create fuse action for supplying collateral
        FuseAction[] memory supplyActions = new FuseAction[](1);
        supplyActions[0] = FuseAction(
            address(siloV2SupplyBorrowableCollateralFuse),
            abi.encodeWithSignature("enter((address,uint8,uint256,uint256))", supplyData)
        );

        // Supply collateral first
        vm.prank(ALPHA);
        plasmaVault.execute(supplyActions);

        // Prepare borrow data
        SiloV2BorrowFuseEnterData memory borrowData = SiloV2BorrowFuseEnterData({
            siloConfig: SILO_CONFIG_WEETH_WETH,
            siloIndex: SiloIndex.SILO1, // Using Silo1 (wETH)
            siloAssetAmount: BORROW_WETH_AMOUNT
        });

        // Create fuse action for alpha execute
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(siloV2BorrowFuse),
            abi.encodeWithSignature("enter((address,uint8,uint256))", borrowData)
        );

        uint256 vaultBalanceBeforeBorrow = plasmaVault.totalAssets();
        uint256 vaultBalanceBeforeBorrowInMarket = plasmaVault.totalAssetsInMarket(IporFusionMarkets.SILO_V2);

        // when - Execute via alpha
        vm.prank(ALPHA);
        plasmaVault.execute(actions);

        // then - Verify the operation was successful and check final balances
        uint256 vaultBalanceAfterBorrow = plasmaVault.totalAssets();
        uint256 vaultBalanceAfterBorrowInMarket = plasmaVault.totalAssetsInMarket(IporFusionMarkets.SILO_V2);

        (silo0ProtectedAfter, silo0CollateralAfter, silo0DebtAfter) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO0
        );
        (silo1ProtectedAfter, silo1CollateralAfter, silo1DebtAfter) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO1
        );

        assertLt(
            vaultBalanceAfterBorrow,
            vaultBalanceBeforeBorrow,
            "Vault total assets should increase after borrowing additional assets"
        );

        // Verify silo0 balances (where we supplied collateral)
        assertEq(silo0ProtectedAfter, silo0ProtectedBefore, "Silo0 protectedShareToken should not change");
        assertGt(
            silo0CollateralAfter,
            silo0CollateralBefore,
            "Silo0 collateralShareToken should increase after supply"
        );
        assertEq(silo0DebtAfter, silo0DebtBefore, "Silo0 debtShareToken should not change");

        // Verify silo1 balances (where we borrowed)
        assertEq(silo1ProtectedAfter, silo1ProtectedBefore, "Silo1 protectedShareToken should not change");
        assertEq(silo1CollateralAfter, silo1CollateralBefore, "Silo1 collateralShareToken should not change");
        assertGt(silo1DebtAfter, silo1DebtBefore, "Silo1 debtShareToken should increase after borrow");
    }

    function testShouldBorrowFromSilo1WhenCollateralIsInSilo0WithDependencyGraph() public {
        // given
        _setupDependencyGraphWithERC20Balance();

        // Get initial balances for silo0 and silo1
        (silo0ProtectedBefore, silo0CollateralBefore, silo0DebtBefore) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO0
        );
        (silo1ProtectedBefore, silo1CollateralBefore, silo1DebtBefore) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO1
        );

        // First supply collateral to silo0 (75 weETH)
        SiloV2SupplyCollateralFuseEnterData memory supplyData = SiloV2SupplyCollateralFuseEnterData({
            siloConfig: SILO_CONFIG_WEETH_WETH,
            siloIndex: SiloIndex.SILO0, // Using Silo0 (weETH)
            siloAssetAmount: SUPPLY_WE_ETH_AMOUNT,
            minSiloAssetAmount: SUPPLY_WE_ETH_AMOUNT - 1 // Allow small slippage
        });

        // Create fuse action for supplying collateral
        FuseAction[] memory supplyActions = new FuseAction[](1);
        supplyActions[0] = FuseAction(
            address(siloV2SupplyBorrowableCollateralFuse),
            abi.encodeWithSignature("enter((address,uint8,uint256,uint256))", supplyData)
        );

        // Supply collateral first
        vm.prank(ALPHA);
        plasmaVault.execute(supplyActions);

        // Prepare borrow data
        SiloV2BorrowFuseEnterData memory borrowData = SiloV2BorrowFuseEnterData({
            siloConfig: SILO_CONFIG_WEETH_WETH,
            siloIndex: SiloIndex.SILO1, // Using Silo1 (wETH)
            siloAssetAmount: BORROW_WETH_AMOUNT
        });

        // Create fuse action for alpha execute
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(siloV2BorrowFuse),
            abi.encodeWithSignature("enter((address,uint8,uint256))", borrowData)
        );

        uint256 vaultBalanceBeforeBorrow = plasmaVault.totalAssets();
        uint256 vaultBalanceBeforeBorrowInMarket = plasmaVault.totalAssetsInMarket(IporFusionMarkets.SILO_V2);

        // when - Execute via alpha
        vm.prank(ALPHA);
        plasmaVault.execute(actions);

        // then - Verify the operation was successful and check final balances
        uint256 vaultBalanceAfterBorrow = plasmaVault.totalAssets();
        uint256 vaultBalanceAfterBorrowInMarket = plasmaVault.totalAssetsInMarket(IporFusionMarkets.SILO_V2);

        (silo0ProtectedAfter, silo0CollateralAfter, silo0DebtAfter) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO0
        );
        (silo1ProtectedAfter, silo1CollateralAfter, silo1DebtAfter) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO1
        );

        assertApproxEqAbsDecimal(
            vaultBalanceAfterBorrow,
            vaultBalanceBeforeBorrow,
            5,
            18, // decimals
            "Vault total assets should be approximately equal after borrowing"
        );

        // Verify silo0 balances (where we supplied collateral)
        assertEq(silo0ProtectedAfter, silo0ProtectedBefore, "Silo0 protectedShareToken should not change");
        assertGt(
            silo0CollateralAfter,
            silo0CollateralBefore,
            "Silo0 collateralShareToken should increase after supply"
        );
        assertEq(silo0DebtAfter, silo0DebtBefore, "Silo0 debtShareToken should not change");

        // Verify silo1 balances (where we borrowed)
        assertEq(silo1ProtectedAfter, silo1ProtectedBefore, "Silo1 protectedShareToken should not change");
        assertEq(silo1CollateralAfter, silo1CollateralBefore, "Silo1 collateralShareToken should not change");
        assertGt(silo1DebtAfter, silo1DebtBefore, "Silo1 debtShareToken should increase after borrow");
    }

    function testShouldRepayBorrowFromSilo1WhenCollateralIsInSilo0WithDependencyGraph() public {
        // given
        _setupDependencyGraphWithERC20Balance();

        // Get initial balances for silo0 and silo1
        (silo0ProtectedBefore, silo0CollateralBefore, silo0DebtBefore) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO0
        );
        (silo1ProtectedBefore, silo1CollateralBefore, silo1DebtBefore) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO1
        );

        // First supply collateral to silo0 (75 weETH)
        SiloV2SupplyCollateralFuseEnterData memory supplyData = SiloV2SupplyCollateralFuseEnterData({
            siloConfig: SILO_CONFIG_WEETH_WETH,
            siloIndex: SiloIndex.SILO0, // Using Silo0 (weETH)
            siloAssetAmount: SUPPLY_WE_ETH_AMOUNT,
            minSiloAssetAmount: SUPPLY_WE_ETH_AMOUNT - 1 // Allow small slippage
        });

        // Create fuse action for supplying collateral
        FuseAction[] memory supplyActions = new FuseAction[](1);
        supplyActions[0] = FuseAction(
            address(siloV2SupplyBorrowableCollateralFuse),
            abi.encodeWithSignature("enter((address,uint8,uint256,uint256))", supplyData)
        );

        // Supply collateral first
        vm.prank(ALPHA);
        plasmaVault.execute(supplyActions);

        // Prepare borrow data
        SiloV2BorrowFuseEnterData memory borrowData = SiloV2BorrowFuseEnterData({
            siloConfig: SILO_CONFIG_WEETH_WETH,
            siloIndex: SiloIndex.SILO1, // Using Silo1 (wETH)
            siloAssetAmount: BORROW_WETH_AMOUNT
        });

        // Create fuse action for borrowing
        FuseAction[] memory borrowActions = new FuseAction[](1);
        borrowActions[0] = FuseAction(
            address(siloV2BorrowFuse),
            abi.encodeWithSignature("enter((address,uint8,uint256))", borrowData)
        );

        // Borrow first
        vm.prank(ALPHA);
        plasmaVault.execute(borrowActions);

        // Get balances after borrow (before repay)
        (silo0ProtectedAfter, silo0CollateralAfter, silo0DebtAfter) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO0
        );
        (silo1ProtectedAfter, silo1CollateralAfter, silo1DebtAfter) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO1
        );

        // Store balances before repay for comparison
        uint256 silo0ProtectedBeforeRepay = silo0ProtectedAfter;
        uint256 silo0CollateralBeforeRepay = silo0CollateralAfter;
        uint256 silo0DebtBeforeRepay = silo0DebtAfter;
        uint256 silo1ProtectedBeforeRepay = silo1ProtectedAfter;
        uint256 silo1CollateralBeforeRepay = silo1CollateralAfter;
        uint256 silo1DebtBeforeRepay = silo1DebtAfter;

        uint256 vaultBalanceBeforeRepay = plasmaVault.totalAssets();

        // Prepare repay data - repay all borrowed amount
        SiloV2BorrowFuseExitData memory repayData = SiloV2BorrowFuseExitData({
            siloConfig: SILO_CONFIG_WEETH_WETH,
            siloIndex: SiloIndex.SILO1, // Using Silo1 (wETH)
            siloAssetAmount: BORROW_WETH_AMOUNT
        });

        // Create fuse action for repaying
        FuseAction[] memory repayActions = new FuseAction[](1);
        repayActions[0] = FuseAction(
            address(siloV2BorrowFuse),
            abi.encodeWithSignature("exit((address,uint8,uint256))", repayData)
        );

        // when - Execute repay via alpha
        vm.prank(ALPHA);
        plasmaVault.execute(repayActions);

        // then - Verify the repay operation was successful and check balances
        uint256 vaultBalanceAfterRepay = plasmaVault.totalAssets();

        (silo0ProtectedAfter, silo0CollateralAfter, silo0DebtAfter) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO0
        );
        (silo1ProtectedAfter, silo1CollateralAfter, silo1DebtAfter) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO1
        );

        // Verify vault balance remains approximately the same (borrowed assets are returned)
        assertApproxEqAbsDecimal(
            vaultBalanceAfterRepay,
            vaultBalanceBeforeRepay,
            1e15,
            18, // decimals
            "Vault total assets should remain approximately the same after repaying"
        );

        // Verify silo0 balances remain unchanged (collateral should stay the same)
        assertEq(silo0ProtectedAfter, silo0ProtectedBeforeRepay, "Silo0 protectedShareToken should not change");
        assertEq(silo0CollateralAfter, silo0CollateralBeforeRepay, "Silo0 collateralShareToken should not change");
        assertEq(silo0DebtAfter, silo0DebtBeforeRepay, "Silo0 debtShareToken should not change");

        // Verify silo1 balances (debt should decrease after repay)
        assertEq(silo1ProtectedAfter, silo1ProtectedBeforeRepay, "Silo1 protectedShareToken should not change");
        assertEq(silo1CollateralAfter, silo1CollateralBeforeRepay, "Silo1 collateralShareToken should not change");
        assertLt(silo1DebtAfter, silo1DebtBeforeRepay, "Silo1 debtShareToken should decrease after repay");

        // Verify that debt is almost completely repaid (should be very small, like 1 wei)
        assertLt(silo1DebtAfter, 10, "Silo1 debtShareToken should be almost zero after repay (less than 10 wei)");
    }

    function testShouldNotRepayInWrongSilo() public {
        // given
        _setupDependencyGraphWithERC20Balance();

        // Get initial balances for silo0 and silo1
        (silo0ProtectedBefore, silo0CollateralBefore, silo0DebtBefore) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO0
        );
        (silo1ProtectedBefore, silo1CollateralBefore, silo1DebtBefore) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO1
        );

        // First supply collateral to silo0 (75 weETH)
        SiloV2SupplyCollateralFuseEnterData memory supplyData = SiloV2SupplyCollateralFuseEnterData({
            siloConfig: SILO_CONFIG_WEETH_WETH,
            siloIndex: SiloIndex.SILO0, // Using Silo0 (weETH)
            siloAssetAmount: SUPPLY_WE_ETH_AMOUNT,
            minSiloAssetAmount: SUPPLY_WE_ETH_AMOUNT - 1 // Allow small slippage
        });

        // Create fuse action for supplying collateral
        FuseAction[] memory supplyActions = new FuseAction[](1);
        supplyActions[0] = FuseAction(
            address(siloV2SupplyBorrowableCollateralFuse),
            abi.encodeWithSignature("enter((address,uint8,uint256,uint256))", supplyData)
        );

        // Supply collateral first
        vm.prank(ALPHA);
        plasmaVault.execute(supplyActions);

        // Prepare borrow data - borrow from silo1
        SiloV2BorrowFuseEnterData memory borrowData = SiloV2BorrowFuseEnterData({
            siloConfig: SILO_CONFIG_WEETH_WETH,
            siloIndex: SiloIndex.SILO1, // Using Silo1 (wETH)
            siloAssetAmount: BORROW_WETH_AMOUNT
        });

        // Create fuse action for borrowing
        FuseAction[] memory borrowActions = new FuseAction[](1);
        borrowActions[0] = FuseAction(
            address(siloV2BorrowFuse),
            abi.encodeWithSignature("enter((address,uint8,uint256))", borrowData)
        );

        // Borrow from silo1
        vm.prank(ALPHA);
        plasmaVault.execute(borrowActions);

        // Get balances after borrow
        (silo0ProtectedAfter, silo0CollateralAfter, silo0DebtAfter) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO0
        );
        (silo1ProtectedAfter, silo1CollateralAfter, silo1DebtAfter) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO1
        );

        // Store balances before wrong repay attempt
        uint256 silo0ProtectedBeforeWrongRepay = silo0ProtectedAfter;
        uint256 silo0CollateralBeforeWrongRepay = silo0CollateralAfter;
        uint256 silo0DebtBeforeWrongRepay = silo0DebtAfter;
        uint256 silo1ProtectedBeforeWrongRepay = silo1ProtectedAfter;
        uint256 silo1CollateralBeforeWrongRepay = silo1CollateralAfter;
        uint256 silo1DebtBeforeWrongRepay = silo1DebtAfter;

        // Prepare WRONG repay data - trying to repay in silo0 (where there's no debt)
        SiloV2BorrowFuseExitData memory wrongRepayData = SiloV2BorrowFuseExitData({
            siloConfig: SILO_CONFIG_WEETH_WETH,
            siloIndex: SiloIndex.SILO0, // WRONG: Trying to repay in Silo0 (weETH) instead of Silo1 (wETH)
            siloAssetAmount: BORROW_WETH_AMOUNT
        });

        // Create fuse action for wrong repay
        FuseAction[] memory wrongRepayActions = new FuseAction[](1);
        wrongRepayActions[0] = FuseAction(
            address(siloV2BorrowFuse),
            abi.encodeWithSignature("exit((address,uint8,uint256))", wrongRepayData)
        );

        // when - Try to execute wrong repay (should revert)
        vm.expectRevert(); // This should revert because we're trying to repay in wrong silo
        vm.prank(ALPHA);
        plasmaVault.execute(wrongRepayActions);

        // then - Verify that balances remain unchanged after failed repay attempt
        (silo0ProtectedAfter, silo0CollateralAfter, silo0DebtAfter) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO0
        );
        (silo1ProtectedAfter, silo1CollateralAfter, silo1DebtAfter) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO1
        );

        // Verify that all balances remain unchanged after failed repay attempt
        assertEq(
            silo0ProtectedAfter,
            silo0ProtectedBeforeWrongRepay,
            "Silo0 protectedShareToken should not change after failed repay"
        );
        assertEq(
            silo0CollateralAfter,
            silo0CollateralBeforeWrongRepay,
            "Silo0 collateralShareToken should not change after failed repay"
        );
        assertEq(
            silo0DebtAfter,
            silo0DebtBeforeWrongRepay,
            "Silo0 debtShareToken should not change after failed repay"
        );

        assertEq(
            silo1ProtectedAfter,
            silo1ProtectedBeforeWrongRepay,
            "Silo1 protectedShareToken should not change after failed repay"
        );
        assertEq(
            silo1CollateralAfter,
            silo1CollateralBeforeWrongRepay,
            "Silo1 collateralShareToken should not change after failed repay"
        );
        assertEq(
            silo1DebtAfter,
            silo1DebtBeforeWrongRepay,
            "Silo1 debtShareToken should not change after failed repay"
        );
    }

    function testShouldNotBorrowFromSilo1WhenCollateralIsInSilo1BalanceWithDependencyGraph() public {
        // given
        _setupDependencyGraphWithERC20Balance();

        // Get initial balances for silo0 and silo1
        (silo0ProtectedBefore, silo0CollateralBefore, silo0DebtBefore) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO0
        );
        (silo1ProtectedBefore, silo1CollateralBefore, silo1DebtBefore) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO1
        );

        // First supply collateral to silo0 (75 weETH)
        SiloV2SupplyCollateralFuseEnterData memory supplyData = SiloV2SupplyCollateralFuseEnterData({
            siloConfig: SILO_CONFIG_WEETH_WETH,
            siloIndex: SiloIndex.SILO0, // Using Silo0 (weETH)
            siloAssetAmount: SUPPLY_WE_ETH_AMOUNT,
            minSiloAssetAmount: SUPPLY_WE_ETH_AMOUNT - 1 // Allow small slippage
        });

        // Create fuse action for supplying collateral
        FuseAction[] memory supplyActions = new FuseAction[](1);
        supplyActions[0] = FuseAction(
            address(siloV2SupplyBorrowableCollateralFuse),
            abi.encodeWithSignature("enter((address,uint8,uint256,uint256))", supplyData)
        );

        // Supply collateral first
        vm.prank(ALPHA);
        plasmaVault.execute(supplyActions);

        // Get balances after supply (before borrow)
        (silo0ProtectedAfter, silo0CollateralAfter, silo0DebtAfter) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO0
        );
        (silo1ProtectedAfter, silo1CollateralAfter, silo1DebtAfter) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO1
        );

        // Store balances before borrow for comparison
        uint256 silo0ProtectedBeforeBorrow = silo0ProtectedAfter;
        uint256 silo0CollateralBeforeBorrow = silo0CollateralAfter;
        uint256 silo0DebtBeforeBorrow = silo0DebtAfter;
        uint256 silo1ProtectedBeforeBorrow = silo1ProtectedAfter;
        uint256 silo1CollateralBeforeBorrow = silo1CollateralAfter;
        uint256 silo1DebtBeforeBorrow = silo1DebtAfter;

        // Prepare borrow data
        SiloV2BorrowFuseEnterData memory borrowData = SiloV2BorrowFuseEnterData({
            siloConfig: SILO_CONFIG_WEETH_WETH,
            siloIndex: SiloIndex.SILO0, // Using Silo0 (weETH)
            siloAssetAmount: BORROW_WETH_AMOUNT
        });

        // Create fuse action for alpha execute
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(siloV2BorrowFuse),
            abi.encodeWithSignature("enter((address,uint8,uint256))", borrowData)
        );

        uint256 vaultBalanceBeforeBorrow = plasmaVault.totalAssets();

        // when - Execute via alpha (should fail)
        vm.prank(ALPHA);
        vm.expectRevert(); // Expect the transaction to revert
        plasmaVault.execute(actions);

        // then - Verify balances remain unchanged (no borrowing occurred)
        uint256 vaultBalanceAfterBorrow = plasmaVault.totalAssets();

        (silo0ProtectedAfter, silo0CollateralAfter, silo0DebtAfter) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO0
        );
        (silo1ProtectedAfter, silo1CollateralAfter, silo1DebtAfter) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO1
        );

        // Verify vault balance remains the same (no borrowing occurred)
        assertEq(
            vaultBalanceAfterBorrow,
            vaultBalanceBeforeBorrow,
            "Vault total assets should remain the same after failed borrow"
        );

        // Verify silo0 balances remain unchanged (no borrowing occurred)
        assertEq(silo0ProtectedAfter, silo0ProtectedBeforeBorrow, "Silo0 protectedShareToken should not change");
        assertEq(silo0CollateralAfter, silo0CollateralBeforeBorrow, "Silo0 collateralShareToken should not change");
        assertEq(silo0DebtAfter, silo0DebtBeforeBorrow, "Silo0 debtShareToken should not change");

        // Verify silo1 balances remain unchanged (no borrowing occurred)
        assertEq(silo1ProtectedAfter, silo1ProtectedBeforeBorrow, "Silo1 protectedShareToken should not change");
        assertEq(silo1CollateralAfter, silo1CollateralBeforeBorrow, "Silo1 collateralShareToken should not change");
        assertEq(silo1DebtAfter, silo1DebtBeforeBorrow, "Silo1 debtShareToken should not change");
    }

    function _createVaultWithFusionFactory() private {
        // Create vault using FusionFactory
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.create(
            "SiloV2 Test Vault",
            "SILO2",
            WE_ETH, // underlying token
            1 seconds, // redemption delay
            ATOMIST // owner
        );

        plasmaVault = PlasmaVault(instance.plasmaVault);
        accessManager = IporFusionAccessManager(instance.accessManager);
        withdrawManager = instance.withdrawManager;
        priceOracleMiddlewareManager = PriceOracleMiddlewareManager(instance.priceManager);
    }

    function _deploySiloV2Fuses() private {
        // Deploy all SiloV2 fuses
        siloV2BalanceFuse = new SiloV2BalanceFuse(IporFusionMarkets.SILO_V2);
        siloV2SupplyBorrowableCollateralFuse = new SiloV2SupplyBorrowableCollateralFuse(IporFusionMarkets.SILO_V2);
        siloV2SupplyNonBorrowableCollateralFuse = new SiloV2SupplyNonBorrowableCollateralFuse(
            IporFusionMarkets.SILO_V2
        );
        siloV2BorrowFuse = new SiloV2BorrowFuse(IporFusionMarkets.SILO_V2);
    }

    function _configureSiloV2Fuses() private {
        vm.startPrank(ATOMIST);

        // Add all fuses to the vault
        address[] memory fuses = new address[](3);
        fuses[0] = address(siloV2SupplyBorrowableCollateralFuse);
        fuses[1] = address(siloV2SupplyNonBorrowableCollateralFuse);
        fuses[2] = address(siloV2BorrowFuse);

        PlasmaVaultGovernance(address(plasmaVault)).addFuses(fuses);

        // Add balance fuse
        PlasmaVaultGovernance(address(plasmaVault)).addBalanceFuse(
            IporFusionMarkets.SILO_V2,
            address(siloV2BalanceFuse)
        );

        // Grant market substrates (SiloConfig addresses)
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(SILO_CONFIG_WEETH_WETH);

        PlasmaVaultGovernance(address(plasmaVault)).grantMarketSubstrates(IporFusionMarkets.SILO_V2, substrates);

        vm.stopPrank();
    }

    function _setupRoles() private {
        vm.startPrank(ATOMIST);

        // First grant ATOMIST_ROLE to ATOMIST (needed to grant other roles)
        accessManager.grantRole(Roles.ATOMIST_ROLE, ATOMIST, 0);

        // Grant other roles
        accessManager.grantRole(Roles.ALPHA_ROLE, ALPHA, 0);
        accessManager.grantRole(Roles.FUSE_MANAGER_ROLE, ATOMIST, 0);
        accessManager.grantRole(Roles.PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE, ATOMIST, 0);
        accessManager.grantRole(Roles.WHITELIST_ROLE, USER, 0);

        vm.stopPrank();
    }

    function _confugurePriceOracleMiddleware() private {
        address[] memory assets = new address[](2);
        assets[0] = WE_ETH;
        assets[1] = WETH;

        address[] memory sources = new address[](2);
        sources[0] = PRICE_FEED_WEETH_USD;
        sources[1] = PRICE_FEED_WETH_USD;

        vm.startPrank(ATOMIST);
        priceOracleMiddlewareManager.setAssetsPriceSources(assets, sources);
        vm.stopPrank();
    }

    function _setupDependencyGraphWithERC20Balance() private {
        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.SILO_V2;

        uint256[] memory dependence = new uint256[](1);
        dependence[0] = IporFusionMarkets.ERC20_VAULT_BALANCE;

        uint256[][] memory dependenceMarkets = new uint256[][](1);
        dependenceMarkets[0] = dependence;

        bytes32[] memory erc20VaultBalanceSubstrates = new bytes32[](2);
        erc20VaultBalanceSubstrates[0] = PlasmaVaultConfigLib.addressToBytes32(WE_ETH);
        erc20VaultBalanceSubstrates[1] = PlasmaVaultConfigLib.addressToBytes32(WETH);

        vm.startPrank(ATOMIST);
        PlasmaVaultGovernance(address(plasmaVault)).updateDependencyBalanceGraphs(marketIds, dependenceMarkets);
        PlasmaVaultGovernance(address(plasmaVault)).grantMarketSubstrates(
            IporFusionMarkets.ERC20_VAULT_BALANCE,
            erc20VaultBalanceSubstrates
        );

        PlasmaVaultGovernance(address(plasmaVault)).addBalanceFuse(
            IporFusionMarkets.ERC20_VAULT_BALANCE,
            0x6cEBf3e3392D0860Ed174402884b941DCBB30654
        );
        vm.stopPrank();
    }

    function _getSiloBalances(
        address siloConfig,
        SiloIndex siloIndex
    ) private view returns (uint256 protectedShareToken, uint256 collateralShareToken, uint256 debtShareToken) {
        // Get silo addresses from config
        (address silo0, address silo1) = ISiloConfig(siloConfig).getSilos();
        address silo = siloIndex == SiloIndex.SILO0 ? silo0 : silo1;

        // Get share token addresses
        (address protectedShareTokenAddr, address collateralShareTokenAddr, address debtShareTokenAddr) = ISiloConfig(
            siloConfig
        ).getShareTokens(silo);

        // Get balances
        protectedShareToken = IShareToken(protectedShareTokenAddr).balanceOf(address(plasmaVault));
        collateralShareToken = IShareToken(collateralShareTokenAddr).balanceOf(address(plasmaVault));
        debtShareToken = IShareToken(debtShareTokenAddr).balanceOf(address(plasmaVault));
    }

    function testShouldStillBorrowWithOnlyProtectedCollateral() public {
        // given
        _setupDependencyGraphWithERC20Balance();

        // Get initial balances for silo0 and silo1
        (silo0ProtectedBefore, silo0CollateralBefore, silo0DebtBefore) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO0
        );
        (silo1ProtectedBefore, silo1CollateralBefore, silo1DebtBefore) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO1
        );

        // Supply PROTECTED (non-borrowable) collateral to silo0 (75 weETH)
        SiloV2SupplyCollateralFuseEnterData memory supplyData = SiloV2SupplyCollateralFuseEnterData({
            siloConfig: SILO_CONFIG_WEETH_WETH,
            siloIndex: SiloIndex.SILO0, // Using Silo0 (weETH)
            siloAssetAmount: SUPPLY_WE_ETH_AMOUNT,
            minSiloAssetAmount: SUPPLY_WE_ETH_AMOUNT - 1 // Allow small slippage
        });

        // Create fuse action for supplying PROTECTED collateral (non-borrowable)
        FuseAction[] memory supplyActions = new FuseAction[](1);
        supplyActions[0] = FuseAction(
            address(siloV2SupplyNonBorrowableCollateralFuse), // Using NON-BORROWABLE fuse
            abi.encodeWithSignature("enter((address,uint8,uint256,uint256))", supplyData)
        );

        // Supply protected collateral first
        vm.prank(ALPHA);
        plasmaVault.execute(supplyActions);

        // Get balances after supply
        (silo0ProtectedAfter, silo0CollateralAfter, silo0DebtAfter) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO0
        );
        (silo1ProtectedAfter, silo1CollateralAfter, silo1DebtAfter) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO1
        );

        // Store balances before borrow
        uint256 silo0ProtectedBeforeBorrow = silo0ProtectedAfter;
        uint256 silo0CollateralBeforeBorrow = silo0CollateralAfter;
        uint256 silo0DebtBeforeBorrow = silo0DebtAfter;
        uint256 silo1ProtectedBeforeBorrow = silo1ProtectedAfter;
        uint256 silo1CollateralBeforeBorrow = silo1CollateralAfter;
        uint256 silo1DebtBeforeBorrow = silo1DebtAfter;

        uint256 vaultBalanceBeforeBorrow = plasmaVault.totalAssets();

        // Prepare borrow data - borrow from silo1
        SiloV2BorrowFuseEnterData memory borrowData = SiloV2BorrowFuseEnterData({
            siloConfig: SILO_CONFIG_WEETH_WETH,
            siloIndex: SiloIndex.SILO1, // Using Silo1 (wETH)
            siloAssetAmount: BORROW_WETH_AMOUNT
        });

        // Create fuse action for borrowing
        FuseAction[] memory borrowActions = new FuseAction[](1);
        borrowActions[0] = FuseAction(
            address(siloV2BorrowFuse),
            abi.encodeWithSignature("enter((address,uint8,uint256))", borrowData)
        );

        // when - Try to borrow using only protected collateral (should succeed and emit event)
        (, address silo1) = ISiloConfig(SILO_CONFIG_WEETH_WETH).getSilos();
        vm.expectEmit(true, true, true, false); // Don't check the last parameter (sharesBorrowed)
        emit SiloV2BorrowFuse.SiloV2BorrowFuseEvent(
            address(siloV2BorrowFuse),
            siloV2BorrowFuse.MARKET_ID(),
            SILO_CONFIG_WEETH_WETH,
            silo1,
            BORROW_WETH_AMOUNT,
            0 // This value won't be checked due to expectEmit flags
        );
        vm.prank(ALPHA);
        plasmaVault.execute(borrowActions);

        // then - Verify that borrow operation succeeded and balances changed accordingly
        (silo0ProtectedAfter, silo0CollateralAfter, silo0DebtAfter) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO0
        );
        (silo1ProtectedAfter, silo1CollateralAfter, silo1DebtAfter) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO1
        );

        uint256 vaultBalanceAfterBorrow = plasmaVault.totalAssets();

        // Verify that borrow operation succeeded and debt was created
        // Silo0 balances should remain the same (we're borrowing from Silo1)
        assertEq(
            silo0ProtectedAfter,
            silo0ProtectedBeforeBorrow,
            "Silo0 protectedShareToken should not change after borrow"
        );
        assertEq(
            silo0CollateralAfter,
            silo0CollateralBeforeBorrow,
            "Silo0 collateralShareToken should not change after borrow"
        );
        assertEq(silo0DebtAfter, silo0DebtBeforeBorrow, "Silo0 debtShareToken should not change after borrow");

        // Silo1 should have debt after borrowing
        assertEq(
            silo1ProtectedAfter,
            silo1ProtectedBeforeBorrow,
            "Silo1 protectedShareToken should not change after borrow"
        );
        assertEq(
            silo1CollateralAfter,
            silo1CollateralBeforeBorrow,
            "Silo1 collateralShareToken should not change after borrow"
        );
        assertGt(silo1DebtAfter, silo1DebtBeforeBorrow, "Silo1 should have debt after borrow");

        // Verify that vault balance changed due to borrowed assets
        // Note: The balance might decrease as we're borrowing assets out of the vault
        assertTrue(
            vaultBalanceAfterBorrow != vaultBalanceBeforeBorrow,
            "Vault total assets should change after borrow"
        );

        // Verify that we have protected collateral and debt was created
        assertGt(silo0ProtectedAfter, 0, "Silo0 should have protected collateral");
        assertEq(silo0CollateralAfter, 0, "Silo0 should have no borrowable collateral");
        assertEq(silo0DebtAfter, 0, "Silo0 should have no debt");
        assertGt(silo1DebtAfter, 0, "Silo1 should have debt after borrow");
    }

    function testShouldNotBorrowMoreThanCollateralValue() public {
        // given
        _setupDependencyGraphWithERC20Balance();

        // Get initial balances for silo0 and silo1
        (silo0ProtectedBefore, silo0CollateralBefore, silo0DebtBefore) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO0
        );
        (silo1ProtectedBefore, silo1CollateralBefore, silo1DebtBefore) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO1
        );

        // Supply borrowable collateral to silo0 (75 weETH)
        SiloV2SupplyCollateralFuseEnterData memory supplyData = SiloV2SupplyCollateralFuseEnterData({
            siloConfig: SILO_CONFIG_WEETH_WETH,
            siloIndex: SiloIndex.SILO0, // Using Silo0 (weETH)
            siloAssetAmount: SUPPLY_WE_ETH_AMOUNT, // 75 weETH
            minSiloAssetAmount: SUPPLY_WE_ETH_AMOUNT - 1 // Allow small slippage
        });

        // Create fuse action for supplying borrowable collateral
        FuseAction[] memory supplyActions = new FuseAction[](1);
        supplyActions[0] = FuseAction(
            address(siloV2SupplyBorrowableCollateralFuse), // Using BORROWABLE fuse
            abi.encodeWithSignature("enter((address,uint8,uint256,uint256))", supplyData)
        );

        // Supply borrowable collateral first
        vm.prank(ALPHA);
        plasmaVault.execute(supplyActions);

        // Get balances after supply
        (silo0ProtectedAfter, silo0CollateralAfter, silo0DebtAfter) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO0
        );
        (silo1ProtectedAfter, silo1CollateralAfter, silo1DebtAfter) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO1
        );

        // Store balances before borrow attempt
        uint256 silo0ProtectedBeforeBorrow = silo0ProtectedAfter;
        uint256 silo0CollateralBeforeBorrow = silo0CollateralAfter;
        uint256 silo0DebtBeforeBorrow = silo0DebtAfter;
        uint256 silo1ProtectedBeforeBorrow = silo1ProtectedAfter;
        uint256 silo1CollateralBeforeBorrow = silo1CollateralAfter;
        uint256 silo1DebtBeforeBorrow = silo1DebtAfter;

        uint256 vaultBalanceBeforeBorrow = plasmaVault.totalAssets();

        // Try to borrow MORE than collateral value (100 wETH instead of 75 weETH)
        // This should fail because we only have 75 weETH collateral
        uint256 excessiveBorrowAmount = 100 ether; // 100 wETH (more than 75 weETH collateral)

        // Prepare borrow data - try to borrow excessive amount from silo1
        SiloV2BorrowFuseEnterData memory borrowData = SiloV2BorrowFuseEnterData({
            siloConfig: SILO_CONFIG_WEETH_WETH,
            siloIndex: SiloIndex.SILO1, // Using Silo1 (wETH)
            siloAssetAmount: excessiveBorrowAmount // 100 wETH (more than collateral)
        });

        // Create fuse action for borrowing
        FuseAction[] memory borrowActions = new FuseAction[](1);
        borrowActions[0] = FuseAction(
            address(siloV2BorrowFuse),
            abi.encodeWithSignature("enter((address,uint8,uint256))", borrowData)
        );

        // when - Try to borrow more than collateral value (should revert)
        vm.expectRevert(); // This should revert because we're trying to borrow more than collateral allows
        vm.prank(ALPHA);
        plasmaVault.execute(borrowActions);

        // then - Verify that balances remain unchanged after failed borrow attempt
        (silo0ProtectedAfter, silo0CollateralAfter, silo0DebtAfter) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO0
        );
        (silo1ProtectedAfter, silo1CollateralAfter, silo1DebtAfter) = _getSiloBalances(
            SILO_CONFIG_WEETH_WETH,
            SiloIndex.SILO1
        );

        uint256 vaultBalanceAfterBorrow = plasmaVault.totalAssets();

        // Verify that all balances remain unchanged after failed borrow attempt
        assertEq(
            silo0ProtectedAfter,
            silo0ProtectedBeforeBorrow,
            "Silo0 protectedShareToken should not change after failed borrow"
        );
        assertEq(
            silo0CollateralAfter,
            silo0CollateralBeforeBorrow,
            "Silo0 collateralShareToken should not change after failed borrow"
        );
        assertEq(silo0DebtAfter, silo0DebtBeforeBorrow, "Silo0 debtShareToken should not change after failed borrow");

        assertEq(
            silo1ProtectedAfter,
            silo1ProtectedBeforeBorrow,
            "Silo1 protectedShareToken should not change after failed borrow"
        );
        assertEq(
            silo1CollateralAfter,
            silo1CollateralBeforeBorrow,
            "Silo1 collateralShareToken should not change after failed borrow"
        );
        assertEq(silo1DebtAfter, silo1DebtBeforeBorrow, "Silo1 debtShareToken should not change after failed borrow");

        // Verify that vault balance remains unchanged
        assertEq(
            vaultBalanceAfterBorrow,
            vaultBalanceBeforeBorrow,
            "Vault total assets should not change after failed borrow"
        );

        // Verify that we have borrowable collateral but no debt
        assertEq(silo0ProtectedAfter, 0, "Silo0 should have no protected collateral");
        assertGt(silo0CollateralAfter, 0, "Silo0 should have borrowable collateral");
        assertEq(silo0DebtAfter, 0, "Silo0 should have no debt");
        assertEq(silo1DebtAfter, 0, "Silo1 should have no debt");
    }
}
