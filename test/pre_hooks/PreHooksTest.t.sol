// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVaultHelper, DeployMinimalPlasmaVaultParams} from "../test_helpers/PlasmaVaultHelper.sol";
import {TestAddresses} from "../test_helpers/TestAddresses.sol";
import {PriceOracleMiddlewareHelper} from "../test_helpers/PriceOracleMiddlewareHelper.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {PriceOracleMiddlewareHelper} from "../test_helpers/PriceOracleMiddlewareHelper.sol";
import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {ERC20BalanceFuse} from "../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IporFusionAccessManagerHelper} from "../test_helpers/IporFusionAccessManagerHelper.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {UpdateBalancesPreHook} from "../../contracts/handlers/pre_hooks/pre_hooks/UpdateBalancesPreHook.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {PreHookInfo, PreHooksInfoReader} from "../../contracts/readers/PreHooksInfoReader.sol";
import {PlasmaVaultMarketsLib} from "../../contracts/vaults/lib/PlasmaVaultMarketsLib.sol";

contract PreHooksTest is Test {
    using PlasmaVaultHelper for PlasmaVault;
    using PriceOracleMiddlewareHelper for PriceOracleMiddleware;
    using IporFusionAccessManagerHelper for IporFusionAccessManager;
    PriceOracleMiddleware private _priceOracleMiddleware;
    PlasmaVault private _plasmaVault;
    IporFusionAccessManager private _accessManager;
    UpdateBalancesPreHook private _updateBalancesPreHook;

    address private constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant _DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    address private constant _USER = TestAddresses.USER;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 21596204);

        _priceOracleMiddleware = PriceOracleMiddlewareHelper.getEthereumPriceOracleMiddleware();

        // Deploy minimal plasma vault
        DeployMinimalPlasmaVaultParams memory params = DeployMinimalPlasmaVaultParams({
            underlyingToken: _USDC,
            underlyingTokenName: "USDC",
            priceOracleMiddleware: _priceOracleMiddleware.addressOf(),
            atomist: TestAddresses.ATOMIST
        });

        vm.startPrank(TestAddresses.ATOMIST);
        (_plasmaVault, ) = PlasmaVaultHelper.deployMinimalPlasmaVault(params);

        _accessManager = _plasmaVault.accessManagerOf();
        _accessManager.setupInitRoles(_plasmaVault, address(0));
        vm.stopPrank();

        ERC20BalanceFuse erc20BalanceFuse = new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE);

        vm.startPrank(TestAddresses.FUSE_MANAGER);
        _plasmaVault.addBalanceFusesToVault(IporFusionMarkets.ERC20_VAULT_BALANCE, address(erc20BalanceFuse));

        vm.stopPrank();

        // add substrates
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = bytes32(uint256(uint160(_DAI)));

        vm.startPrank(TestAddresses.FUSE_MANAGER);
        _plasmaVault.addSubstratesToMarket(IporFusionMarkets.ERC20_VAULT_BALANCE, substrates);
        vm.stopPrank();

        deal(_DAI, _USER, 1000 ether);
        deal(_USDC, _USER, 100_000e6);

        vm.startPrank(_USER);
        IERC20(_DAI).transfer(address(_plasmaVault), 10 ether);
        IERC20(_USDC).approve(address(_plasmaVault), 10_000e6);
        _plasmaVault.deposit(10_000e6, _USER);
        vm.stopPrank();

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.ERC20_VAULT_BALANCE;

        address balanceUpdater = address(0x777);

        vm.startPrank(TestAddresses.ATOMIST);
        _accessManager.grantRole(Roles.UPDATE_MARKETS_BALANCES_ROLE, balanceUpdater, 0);
        vm.stopPrank();

        vm.startPrank(balanceUpdater);
        _plasmaVault.updateMarketsBalances(marketIds);
        vm.stopPrank();

        _updateBalancesPreHook = new UpdateBalancesPreHook();
    }

    function testShouldAddPreHook() public {
        // given
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = PlasmaVault.deposit.selector;

        address[] memory preHooks = new address[](1);
        preHooks[0] = address(_updateBalancesPreHook);

        bytes32[][] memory substrates = new bytes32[][](1);
        substrates[0] = new bytes32[](0);

        // when
        vm.startPrank(TestAddresses.ATOMIST);
        PlasmaVaultGovernance(address(_plasmaVault)).setPreHookImplementations(selectors, preHooks, substrates);
        vm.stopPrank();

        // then
        bytes4[] memory preHookSelectors = PlasmaVaultGovernance(address(_plasmaVault)).getPreHookSelectors();
        assertEq(preHookSelectors.length, 1);
        assertEq(preHookSelectors[0], PlasmaVault.deposit.selector);
        assertEq(
            PlasmaVaultGovernance(address(_plasmaVault)).getPreHookImplementation(PlasmaVault.deposit.selector),
            address(_updateBalancesPreHook)
        );
    }

    function testShouldRemovePreHook() public {
        // given
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = PlasmaVault.deposit.selector;

        address[] memory preHooks = new address[](1);
        preHooks[0] = address(_updateBalancesPreHook);

        bytes32[][] memory substrates = new bytes32[][](1);
        substrates[0] = new bytes32[](0);

        vm.startPrank(TestAddresses.ATOMIST);
        PlasmaVaultGovernance(address(_plasmaVault)).setPreHookImplementations(selectors, preHooks, substrates);

        // verify pre-hook was added
        bytes4[] memory preHookSelectors = PlasmaVaultGovernance(address(_plasmaVault)).getPreHookSelectors();
        assertEq(preHookSelectors.length, 1);
        assertEq(preHookSelectors[0], PlasmaVault.deposit.selector);
        assertEq(
            PlasmaVaultGovernance(address(_plasmaVault)).getPreHookImplementation(PlasmaVault.deposit.selector),
            address(_updateBalancesPreHook)
        );

        // when - remove pre-hook by setting implementation to address(0)
        address[] memory zeroAddresses = new address[](1);
        zeroAddresses[0] = address(0);
        PlasmaVaultGovernance(address(_plasmaVault)).setPreHookImplementations(selectors, zeroAddresses, substrates);
        vm.stopPrank();

        // then
        preHookSelectors = PlasmaVaultGovernance(address(_plasmaVault)).getPreHookSelectors();
        assertEq(preHookSelectors.length, 0);
        assertEq(
            PlasmaVaultGovernance(address(_plasmaVault)).getPreHookImplementation(PlasmaVault.deposit.selector),
            address(0)
        );
    }

    function testShouldAddSamePreHookForMultipleMethods() public {
        // given
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = PlasmaVault.deposit.selector;
        selectors[1] = PlasmaVault.withdraw.selector;

        address[] memory preHooks = new address[](2);
        preHooks[0] = address(_updateBalancesPreHook);
        preHooks[1] = address(_updateBalancesPreHook);

        bytes32[][] memory substrates = new bytes32[][](2);
        substrates[0] = new bytes32[](1);
        substrates[0][0] = bytes32(uint256(uint160(_DAI)));
        substrates[1] = new bytes32[](1);
        substrates[1][0] = bytes32(uint256(uint160(_USDC)));

        // when
        vm.startPrank(TestAddresses.ATOMIST);
        PlasmaVaultGovernance(address(_plasmaVault)).setPreHookImplementations(selectors, preHooks, substrates);
        vm.stopPrank();

        // then
        bytes4[] memory preHookSelectors = PlasmaVaultGovernance(address(_plasmaVault)).getPreHookSelectors();
        assertEq(preHookSelectors.length, 2);
        assertEq(preHookSelectors[0], PlasmaVault.deposit.selector);
        assertEq(preHookSelectors[1], PlasmaVault.withdraw.selector);

        // verify implementation for deposit
        assertEq(
            PlasmaVaultGovernance(address(_plasmaVault)).getPreHookImplementation(PlasmaVault.deposit.selector),
            address(_updateBalancesPreHook)
        );

        // verify implementation for withdraw
        assertEq(
            PlasmaVaultGovernance(address(_plasmaVault)).getPreHookImplementation(PlasmaVault.withdraw.selector),
            address(_updateBalancesPreHook)
        );
    }

    function testShouldRemoveOnePreHookFromTwo() public {
        // given - add pre-hooks for both deposit and withdraw
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = PlasmaVault.deposit.selector;
        selectors[1] = PlasmaVault.withdraw.selector;

        address[] memory preHooks = new address[](2);
        preHooks[0] = address(_updateBalancesPreHook);
        preHooks[1] = address(_updateBalancesPreHook);

        bytes32[][] memory substrates = new bytes32[][](2);
        substrates[0] = new bytes32[](1);
        substrates[0][0] = bytes32(uint256(uint160(_DAI)));
        substrates[1] = new bytes32[](1);
        substrates[1][0] = bytes32(uint256(uint160(_USDC)));

        vm.startPrank(TestAddresses.ATOMIST);
        PlasmaVaultGovernance(address(_plasmaVault)).setPreHookImplementations(selectors, preHooks, substrates);

        // verify both pre-hooks were added
        bytes4[] memory preHookSelectors = PlasmaVaultGovernance(address(_plasmaVault)).getPreHookSelectors();
        assertEq(preHookSelectors.length, 2);
        assertEq(preHookSelectors[0], PlasmaVault.deposit.selector);
        assertEq(preHookSelectors[1], PlasmaVault.withdraw.selector);

        // when - remove pre-hook only for deposit
        bytes4[] memory depositSelector = new bytes4[](1);
        depositSelector[0] = PlasmaVault.deposit.selector;

        address[] memory zeroAddress = new address[](1);
        zeroAddress[0] = address(0);

        bytes32[][] memory depositSubstrates = new bytes32[][](1);
        depositSubstrates[0] = new bytes32[](1);
        depositSubstrates[0][0] = bytes32(uint256(uint160(_DAI)));

        PlasmaVaultGovernance(address(_plasmaVault)).setPreHookImplementations(
            depositSelector,
            zeroAddress,
            depositSubstrates
        );
        vm.stopPrank();

        // then
        preHookSelectors = PlasmaVaultGovernance(address(_plasmaVault)).getPreHookSelectors();
        assertEq(preHookSelectors.length, 1);
        assertEq(preHookSelectors[0], PlasmaVault.withdraw.selector);

        // verify deposit pre-hook was removed
        assertEq(
            PlasmaVaultGovernance(address(_plasmaVault)).getPreHookImplementation(PlasmaVault.deposit.selector),
            address(0)
        );

        // verify withdraw pre-hook still exists
        assertEq(
            PlasmaVaultGovernance(address(_plasmaVault)).getPreHookImplementation(PlasmaVault.withdraw.selector),
            address(_updateBalancesPreHook)
        );
    }

    function testShouldUpdateTotalAssetsAfterDirectTransfer() public {
        // given
        uint256 initialTotalAssets = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.ERC20_VAULT_BALANCE);
        uint256 additionalDaiAmount = 10 ether;

        // when
        vm.startPrank(_USER);
        IERC20(_DAI).transfer(address(_plasmaVault), additionalDaiAmount);
        vm.stopPrank();

        // then
        assertEq(
            _plasmaVault.totalAssetsInMarket(IporFusionMarkets.ERC20_VAULT_BALANCE),
            initialTotalAssets,
            "Total assets should not change without updating balances"
        );

        // when - update balances
        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.ERC20_VAULT_BALANCE;
        vm.startPrank(TestAddresses.ATOMIST);
        _plasmaVault.updateMarketsBalances(marketIds);
        vm.stopPrank();

        // then
        assertGt(
            _plasmaVault.totalAssetsInMarket(IporFusionMarkets.ERC20_VAULT_BALANCE),
            initialTotalAssets,
            "Total assets should increase after updating balances"
        );
    }

    function testShouldUpdateTotalAssetsAfterDirectTransferAndDeposit() public {
        // given
        uint256 initialTotalAssets = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.ERC20_VAULT_BALANCE);
        uint256 additionalDaiAmount = 10 ether;
        uint256 depositAmount = 100e6; // 100 USDC

        // when - transfer DAI directly
        vm.startPrank(_USER);
        IERC20(_DAI).transfer(address(_plasmaVault), additionalDaiAmount);
        vm.stopPrank();

        // then
        assertEq(
            _plasmaVault.totalAssetsInMarket(IporFusionMarkets.ERC20_VAULT_BALANCE),
            initialTotalAssets,
            "Total assets should not change without updating balances"
        );

        // when - deposit USDC
        vm.startPrank(_USER);
        IERC20(_USDC).approve(address(_plasmaVault), depositAmount);
        _plasmaVault.deposit(depositAmount, _USER);
        vm.stopPrank();

        // update balances after deposit
        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.ERC20_VAULT_BALANCE;

        vm.startPrank(TestAddresses.ATOMIST);
        _plasmaVault.updateMarketsBalances(marketIds);
        vm.stopPrank();

        // then
        uint256 afterDepositAssets = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.ERC20_VAULT_BALANCE);
        assertGt(
            afterDepositAssets,
            initialTotalAssets,
            "Total assets should increase after deposit and balance update"
        );

        // when - update balances again to include direct transfer
        vm.startPrank(TestAddresses.ATOMIST);
        _plasmaVault.updateMarketsBalances(marketIds);
        vm.stopPrank();
        // then
        uint256 finalTotalAssets = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.ERC20_VAULT_BALANCE);
        assertEq(finalTotalAssets, afterDepositAssets, "Total assets should not change after second balance update");
    }

    function testShouldUpdateTotalAssetsWithPreHook() public {
        // given - add pre-hook for deposit
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = PlasmaVault.deposit.selector;

        address[] memory preHooks = new address[](1);
        preHooks[0] = address(_updateBalancesPreHook);

        bytes32[][] memory substrates = new bytes32[][](1);
        substrates[0] = new bytes32[](0);

        vm.startPrank(TestAddresses.ATOMIST);
        PlasmaVaultGovernance(address(_plasmaVault)).setPreHookImplementations(selectors, preHooks, substrates);
        vm.stopPrank();

        uint256 initialTotalAssets = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.ERC20_VAULT_BALANCE);
        uint256 additionalDaiAmount = 10 ether;
        uint256 depositAmount = 100e6; // 100 USDC

        // when - transfer DAI directly
        vm.startPrank(_USER);
        IERC20(_DAI).transfer(address(_plasmaVault), additionalDaiAmount);
        vm.stopPrank();

        // then
        assertEq(
            _plasmaVault.totalAssetsInMarket(IporFusionMarkets.ERC20_VAULT_BALANCE),
            initialTotalAssets,
            "Total assets should not change after direct transfer"
        );

        // when - deposit USDC (should trigger pre-hook)
        vm.startPrank(_USER);
        IERC20(_USDC).approve(address(_plasmaVault), depositAmount);

        // Expect MarketBalancesUpdated event during deposit
        uint256[] memory expectedMarketIds = new uint256[](1);
        expectedMarketIds[0] = IporFusionMarkets.ERC20_VAULT_BALANCE;
        vm.expectEmit(true, true, true, true);
        emit PlasmaVaultMarketsLib.MarketBalancesUpdated(expectedMarketIds, 10005297); // delta value will be checked in actual event data

        _plasmaVault.deposit(depositAmount, _USER);
        vm.stopPrank();

        // then - check if pre-hook updated balances including both deposit and direct transfer
        uint256 finalTotalAssets = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.ERC20_VAULT_BALANCE);
        assertGt(
            finalTotalAssets,
            initialTotalAssets,
            "Total assets should increase after deposit and pre-hook execution"
        );
    }

    function testShouldUpdatePreHookImplementationAndSubstrates() public {
        // given - add initial pre-hook with DAI substrate
        PreHooksInfoReader preHookReader = new PreHooksInfoReader();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = PlasmaVault.deposit.selector;

        address[] memory preHooks = new address[](1);
        preHooks[0] = address(_updateBalancesPreHook);

        bytes32[][] memory substrates = new bytes32[][](1);
        substrates[0] = new bytes32[](1);
        substrates[0][0] = bytes32(uint256(uint160(_DAI)));

        vm.startPrank(TestAddresses.ATOMIST);
        PlasmaVaultGovernance(address(_plasmaVault)).setPreHookImplementations(selectors, preHooks, substrates);
        vm.stopPrank();

        // verify initial setup
        PreHookInfo[] memory preHooksInfo = preHookReader.getPreHooksInfo(address(_plasmaVault));
        assertEq(preHooksInfo.length, 1);
        assertEq(preHooksInfo[0].selector, PlasmaVault.deposit.selector);
        assertEq(preHooksInfo[0].implementation, address(_updateBalancesPreHook));
        assertEq(preHooksInfo[0].substrates.length, 1);
        assertEq(preHooksInfo[0].substrates[0], bytes32(uint256(uint160(_DAI))));

        // when - update pre-hook with new implementation and USDC substrate
        address newPreHook = address(0x123); // Mock new pre-hook address
        address[] memory newPreHooks = new address[](1);
        newPreHooks[0] = newPreHook;

        bytes32[][] memory newSubstrates = new bytes32[][](1);
        newSubstrates[0] = new bytes32[](1);
        newSubstrates[0][0] = bytes32(uint256(uint160(_USDC)));

        vm.startPrank(TestAddresses.ATOMIST);
        PlasmaVaultGovernance(address(_plasmaVault)).setPreHookImplementations(selectors, newPreHooks, newSubstrates);
        vm.stopPrank();

        // then - verify changes
        PreHookInfo[] memory updatedPreHooksInfo = preHookReader.getPreHooksInfo(address(_plasmaVault));
        assertEq(updatedPreHooksInfo.length, 1);
        assertEq(updatedPreHooksInfo[0].selector, PlasmaVault.deposit.selector);
        assertEq(updatedPreHooksInfo[0].implementation, newPreHook);
        assertEq(updatedPreHooksInfo[0].substrates.length, 1);
        assertEq(updatedPreHooksInfo[0].substrates[0], bytes32(uint256(uint160(_USDC))));
    }
}
