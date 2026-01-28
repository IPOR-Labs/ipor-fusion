// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {FusionFactory} from "../../contracts/factory/FusionFactory.sol";
import {FusionFactoryStorageLib} from "../../contracts/factory/lib/FusionFactoryStorageLib.sol";
import {FusionFactoryLib} from "../../contracts/factory/lib/FusionFactoryLib.sol";
import {FusionFactoryLogicLib} from "../../contracts/factory/lib/FusionFactoryLogicLib.sol";
import {ValidateAllAssetsPricesPreHook} from "../../contracts/handlers/pre_hooks/pre_hooks/ValidateAllAssetsPricesPreHook.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {MutableValuePriceFeed} from "../managers/MutableValuePriceFeed.sol";
import {PriceOracleMiddlewareManager} from "../../contracts/managers/price/PriceOracleMiddlewareManager.sol";
import {PriceOracleMiddlewareManagerLib} from "../../contracts/managers/price/PriceOracleMiddlewareManagerLib.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {RewardsClaimManager} from "../../contracts/managers/rewards/RewardsClaimManager.sol";
import {ContextManager} from "../../contracts/managers/context/ContextManager.sol";
import {PlasmaVaultFactory} from "../../contracts/factory/PlasmaVaultFactory.sol";
import {FeeManagerFactory} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {AccessManagerFactory} from "../../contracts/factory/AccessManagerFactory.sol";

/// @title ValidateAllAssetsPricesPreHookTest
/// @notice Placeholder test suite for `ValidateAllAssetsPricesPreHook`
contract ValidateAllAssetsPricesPreHookTest is Test {
    address private constant FACTORY = 0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852;
    address private constant ADMIN = 0xf2C6a2225BE9829eD77263b032E3D92C52aE6694;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    FusionFactoryLogicLib.FusionInstance private _fusionInstance;
    ValidateAllAssetsPricesPreHook private _validateAllAssetsPricesPreHook;
    MutableValuePriceFeed private _mutableValuePriceFeed;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 23784250);

        _validateAllAssetsPricesPreHook = new ValidateAllAssetsPricesPreHook();
        _mutableValuePriceFeed = new MutableValuePriceFeed(1e18);

        FusionFactory fusionFactoryImpl = new FusionFactory();
        FusionFactory factory = FusionFactory(FACTORY);

        vm.startPrank(ADMIN);
        factory.grantRole(keccak256("MAINTENANCE_MANAGER_ROLE"), ADMIN);
        factory.upgradeToAndCall(address(fusionFactoryImpl), "");

        // Update factory addresses with new PlasmaVaultFactory
        FusionFactoryStorageLib.FactoryAddresses memory factoryAddresses = factory.getFactoryAddresses();
        factoryAddresses.plasmaVaultFactory = address(new PlasmaVaultFactory());
        factoryAddresses.feeManagerFactory = address(new FeeManagerFactory());
        factoryAddresses.accessManagerFactory = address(new AccessManagerFactory());
        factory.updateFactoryAddresses(5, factoryAddresses);

        // Deploy all base addresses for cloning
        address plasmaVaultCoreBase = address(new PlasmaVault());
        address accessManagerBase = address(new IporFusionAccessManager(ADMIN, 0));
        address priceOracleMiddleware = factory.getPriceOracleMiddleware();
        address priceManagerBase = address(new PriceOracleMiddlewareManager(ADMIN, priceOracleMiddleware));
        address withdrawManagerBase = address(new WithdrawManager(accessManagerBase));
        address rewardsManagerBase = address(new RewardsClaimManager(accessManagerBase, plasmaVaultCoreBase));
        address[] memory approvedTargets = new address[](1);
        approvedTargets[0] = plasmaVaultCoreBase;
        address contextManagerBase = address(new ContextManager(accessManagerBase, approvedTargets));
        factory.updateBaseAddresses(
            5,
            plasmaVaultCoreBase,
            accessManagerBase,
            priceManagerBase,
            withdrawManagerBase,
            rewardsManagerBase,
            contextManagerBase
        );

        _fusionInstance = factory.clone("TEST PLASMA VAULT", "TPLASMA", USDC, 0, ADMIN);

        IporFusionAccessManager iporFusionAccessManager = IporFusionAccessManager(
            address(_fusionInstance.accessManager)
        );
        iporFusionAccessManager.grantRole(Roles.ATOMIST_ROLE, ADMIN, 0);
        iporFusionAccessManager.grantRole(Roles.PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE, ADMIN, 0);
        iporFusionAccessManager.grantRole(Roles.PRE_HOOKS_MANAGER_ROLE, ADMIN, 0);

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IERC4626.deposit.selector;
        address[] memory implementations = new address[](1);
        implementations[0] = address(_validateAllAssetsPricesPreHook);

        bytes32[][] memory substrates = new bytes32[][](1);
        substrates[0] = new bytes32[](1);
        substrates[0][0] = bytes32(0);

        address[] memory assets = new address[](1);
        assets[0] = DAI;

        address[] memory sources = new address[](1);
        sources[0] = address(_mutableValuePriceFeed);
        PriceOracleMiddlewareManager(_fusionInstance.priceManager).setAssetsPriceSources(assets, sources);

        uint256[] memory maxPriceDeltas = new uint256[](1);
        maxPriceDeltas[0] = 1e15;
        PriceOracleMiddlewareManager(_fusionInstance.priceManager).updatePriceValidation(assets, maxPriceDeltas);

        PlasmaVaultGovernance plasmaVaultGovernance = PlasmaVaultGovernance(address(_fusionInstance.plasmaVault));

        plasmaVaultGovernance.setPreHookImplementations(selectors, implementations, substrates);
        plasmaVaultGovernance.convertToPublicVault();
        vm.stopPrank();
    }

    function testShouldDeposit1000e6Usdc() public {
        uint256 depositAmount = 1_000e6;
        address plasmaVault = _fusionInstance.plasmaVault;

        uint256 expectedShares = IERC4626(plasmaVault).previewDeposit(depositAmount);
        uint256 expectedBaselinePrice = 1e18;

        deal(USDC, ADMIN, depositAmount);
        vm.startPrank(ADMIN);
        IERC20(USDC).approve(plasmaVault, depositAmount);
        vm.stopPrank();

        vm.expectEmit({emitter: address(_fusionInstance.priceManager)});
        emit PriceOracleMiddlewareManagerLib.PriceValidationBaselineUpdated(DAI, expectedBaselinePrice);

        vm.startPrank(ADMIN);
        uint256 mintedShares = IERC4626(plasmaVault).deposit(depositAmount, ADMIN);
        vm.stopPrank();

        assertEq(mintedShares, expectedShares, "Deposited shares mismatch");
        assertEq(IERC20(plasmaVault).balanceOf(ADMIN), mintedShares, "Share balance mismatch");
        assertEq(IERC20(USDC).balanceOf(plasmaVault), depositAmount, "Vault asset balance mismatch");
    }

    function testShouldRevertDepositWhenPriceValidationFails() public {
        uint256 depositAmount = 1_000e6;
        address plasmaVault = _fusionInstance.plasmaVault;
        uint256 baselinePrice = 1e18;
        uint256 newPrice = 3e18;
        uint256 maxPriceDelta = 1e15;

        deal(USDC, ADMIN, depositAmount);

        vm.startPrank(ADMIN);
        IERC20(USDC).approve(plasmaVault, type(uint256).max);
        IERC4626(plasmaVault).deposit(depositAmount, ADMIN);
        vm.stopPrank();

        _mutableValuePriceFeed.setPrice(int256(newPrice));

        deal(USDC, ADMIN, depositAmount);

        vm.startPrank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                PriceOracleMiddlewareManagerLib.PriceChangeExceeded.selector,
                DAI,
                baselinePrice,
                newPrice,
                maxPriceDelta
            )
        );
        IERC4626(plasmaVault).deposit(depositAmount, ADMIN);
        vm.stopPrank();
    }
}
