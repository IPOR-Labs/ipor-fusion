// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
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
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IporFusionAccessManagerHelper} from "../test_helpers/IporFusionAccessManagerHelper.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {UpdateBalancesPreHook} from "../../contracts/handlers/pre_hooks/pre_hooks/UpdateBalancesPreHook.sol";
import {UpdateBalancesIgnoreDustPreHook} from "../../contracts/handlers/pre_hooks/pre_hooks/UpdateBalancesIgnoreDustPreHook.sol";
import {Erc4626BalanceFuse} from "../../contracts/fuses/erc4626/Erc4626BalanceFuse.sol";
import {MockERC4626} from "../test_helpers/MockErc4626.sol";

contract UpdateBalancesIgnoreDustPreHookTest is Test {
    using PlasmaVaultHelper for PlasmaVault;
    using PriceOracleMiddlewareHelper for PriceOracleMiddleware;
    using IporFusionAccessManagerHelper for IporFusionAccessManager;
    PriceOracleMiddleware private _priceOracleMiddleware;
    PlasmaVault private _plasmaVault;
    IporFusionAccessManager private _accessManager;

    UpdateBalancesIgnoreDustPreHook private _updateBalancesIgnoreDustPreHook;

    address private constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    address private constant _USER = TestAddresses.USER;

    ERC4626 private _erc4626_1;
    ERC4626 private _erc4626_2;
    ERC4626 private _erc4626_3;

    uint256[] private _marketIds;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 21596204);

        _updateBalancesIgnoreDustPreHook = new UpdateBalancesIgnoreDustPreHook();

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
        _plasmaVault.addBalanceFusesToVault(
            IporFusionMarkets.ERC4626_0001,
            address(new Erc4626BalanceFuse(IporFusionMarkets.ERC4626_0001))
        );
        _plasmaVault.addBalanceFusesToVault(
            IporFusionMarkets.ERC4626_0002,
            address(new Erc4626BalanceFuse(IporFusionMarkets.ERC4626_0002))
        );
        _plasmaVault.addBalanceFusesToVault(
            IporFusionMarkets.ERC4626_0003,
            address(new Erc4626BalanceFuse(IporFusionMarkets.ERC4626_0003))
        );

        vm.stopPrank();

        _erc4626_1 = new MockERC4626(IERC20(_USDC), "ERC4626_1", "ERC4626_1");
        _erc4626_2 = new MockERC4626(IERC20(_USDC), "ERC4626_2", "ERC4626_2");
        _erc4626_3 = new MockERC4626(IERC20(_USDC), "ERC4626_3", "ERC4626_3");

        vm.startPrank(TestAddresses.USER);
        IERC20(_USDC).approve(address(_erc4626_1), type(uint256).max);
        IERC20(_USDC).approve(address(_erc4626_2), type(uint256).max);
        IERC20(_USDC).approve(address(_erc4626_3), type(uint256).max);
        vm.stopPrank();

        // add substrates
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = bytes32(uint256(uint160(_USDC)));

        vm.startPrank(TestAddresses.ATOMIST);
        _plasmaVault.addSubstratesToMarket(IporFusionMarkets.ERC20_VAULT_BALANCE, substrates);

        substrates[0] = bytes32(uint256(uint160(address(_erc4626_1))));
        _plasmaVault.addSubstratesToMarket(IporFusionMarkets.ERC4626_0001, substrates);

        substrates[0] = bytes32(uint256(uint160(address(_erc4626_2))));
        _plasmaVault.addSubstratesToMarket(IporFusionMarkets.ERC4626_0002, substrates);

        substrates[0] = bytes32(uint256(uint160(address(_erc4626_3))));
        _plasmaVault.addSubstratesToMarket(IporFusionMarkets.ERC4626_0003, substrates);
        vm.stopPrank();

        deal(_USDC, _USER, 100_000e6);

        vm.startPrank(_USER);
        IERC20(_USDC).approve(address(_plasmaVault), type(uint256).max);
        _plasmaVault.deposit(1_000e6, _USER);
        vm.stopPrank();

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = PlasmaVault.deposit.selector;

        address[] memory preHooks = new address[](1);
        preHooks[0] = address(_updateBalancesIgnoreDustPreHook);

        bytes32[][] memory preHookSubstrates = new bytes32[][](1);
        preHookSubstrates[0] = new bytes32[](1);
        preHookSubstrates[0][0] = bytes32(uint256(1e6));
        vm.startPrank(TestAddresses.ATOMIST);
        PlasmaVaultGovernance(address(_plasmaVault)).setPreHookImplementations(selectors, preHooks, preHookSubstrates);
        vm.stopPrank();

        _marketIds = new uint256[](3);
        _marketIds[0] = IporFusionMarkets.ERC4626_0001;
        _marketIds[1] = IporFusionMarkets.ERC4626_0002;
        _marketIds[2] = IporFusionMarkets.ERC4626_0003;
    }

    function testShouldNotUpdateBalancesOnDeposit() public {
        // given
        vm.startPrank(_USER);
        _erc4626_1.deposit(1e5, address(_plasmaVault));
        _erc4626_2.deposit(2e5, address(_plasmaVault));
        _erc4626_3.deposit(3e5, address(_plasmaVault));
        vm.stopPrank();

        _plasmaVault.updateMarketsBalances(_marketIds);

        uint256 erc4626BalanceBefore1 = _plasmaVault.totalAssetsInMarket(_marketIds[0]);
        uint256 erc4626BalanceBefore2 = _plasmaVault.totalAssetsInMarket(_marketIds[1]);
        uint256 erc4626BalanceBefore3 = _plasmaVault.totalAssetsInMarket(_marketIds[2]);

        vm.startPrank(_USER);
        _erc4626_1.deposit(1e5, address(_plasmaVault));
        _erc4626_2.deposit(2e5, address(_plasmaVault));
        _erc4626_3.deposit(3e5, address(_plasmaVault));
        vm.stopPrank();

        // when
        vm.startPrank(_USER);
        _plasmaVault.deposit(1e5, _USER);
        vm.stopPrank();

        // then
        assertEq(erc4626BalanceBefore1, _plasmaVault.totalAssetsInMarket(_marketIds[0]));
        assertEq(erc4626BalanceBefore2, _plasmaVault.totalAssetsInMarket(_marketIds[1]));
        assertEq(erc4626BalanceBefore3, _plasmaVault.totalAssetsInMarket(_marketIds[2]));
    }

    function testShouldUpdateOnlyOneMarket() public {
        // given
        vm.startPrank(_USER);
        _erc4626_1.deposit(1e7, address(_plasmaVault));
        _erc4626_2.deposit(2e5, address(_plasmaVault));
        _erc4626_3.deposit(3e5, address(_plasmaVault));
        vm.stopPrank();

        _plasmaVault.updateMarketsBalances(_marketIds);

        uint256 erc4626BalanceBefore1 = _plasmaVault.totalAssetsInMarket(_marketIds[0]);
        uint256 erc4626BalanceBefore2 = _plasmaVault.totalAssetsInMarket(_marketIds[1]);
        uint256 erc4626BalanceBefore3 = _plasmaVault.totalAssetsInMarket(_marketIds[2]);

        vm.startPrank(_USER);
        _erc4626_1.deposit(1e6, address(_plasmaVault));
        _erc4626_2.deposit(2e5, address(_plasmaVault));
        _erc4626_3.deposit(3e5, address(_plasmaVault));
        vm.stopPrank();

        // when
        vm.startPrank(_USER);
        _plasmaVault.deposit(1e5, _USER);
        vm.stopPrank();

        // then
        assertEq(erc4626BalanceBefore1 + 1e6, _plasmaVault.totalAssetsInMarket(_marketIds[0]));
        assertEq(erc4626BalanceBefore2, _plasmaVault.totalAssetsInMarket(_marketIds[1]));
        assertEq(erc4626BalanceBefore3, _plasmaVault.totalAssetsInMarket(_marketIds[2]));
    }

    function testShouldUpdateOnlyTwoMarket() public {
        // given
        vm.startPrank(_USER);
        _erc4626_1.deposit(1e7, address(_plasmaVault));
        _erc4626_2.deposit(2e7, address(_plasmaVault));
        _erc4626_3.deposit(3e5, address(_plasmaVault));
        vm.stopPrank();

        _plasmaVault.updateMarketsBalances(_marketIds);

        uint256 erc4626BalanceBefore1 = _plasmaVault.totalAssetsInMarket(_marketIds[0]);
        uint256 erc4626BalanceBefore2 = _plasmaVault.totalAssetsInMarket(_marketIds[1]);
        uint256 erc4626BalanceBefore3 = _plasmaVault.totalAssetsInMarket(_marketIds[2]);

        vm.startPrank(_USER);
        _erc4626_1.deposit(2e6, address(_plasmaVault));
        _erc4626_2.deposit(3e6, address(_plasmaVault));
        _erc4626_3.deposit(5e5, address(_plasmaVault));
        vm.stopPrank();

        // when
        vm.startPrank(_USER);
        _plasmaVault.deposit(1e5, _USER);
        vm.stopPrank();

        // then
        // First market should be updated (2e6 > dust threshold of 1e6)
        assertEq(erc4626BalanceBefore1 + 2e6, _plasmaVault.totalAssetsInMarket(_marketIds[0]));
        // Second market should be updated (3e6 > dust threshold of 1e6)
        assertEq(erc4626BalanceBefore2 + 3e6, _plasmaVault.totalAssetsInMarket(_marketIds[1]));
        // Third market should not be updated (5e5 < dust threshold of 1e6)
        assertEq(erc4626BalanceBefore3, _plasmaVault.totalAssetsInMarket(_marketIds[2]));
    }

    function testShouldUpdateAllMarkets() public {
        // given
        vm.startPrank(_USER);
        _erc4626_1.deposit(1e7, address(_plasmaVault));
        _erc4626_2.deposit(2e7, address(_plasmaVault));
        _erc4626_3.deposit(3e7, address(_plasmaVault));
        vm.stopPrank();

        _plasmaVault.updateMarketsBalances(_marketIds);

        uint256 erc4626BalanceBefore1 = _plasmaVault.totalAssetsInMarket(_marketIds[0]);
        uint256 erc4626BalanceBefore2 = _plasmaVault.totalAssetsInMarket(_marketIds[1]);
        uint256 erc4626BalanceBefore3 = _plasmaVault.totalAssetsInMarket(_marketIds[2]);

        vm.startPrank(_USER);
        _erc4626_1.deposit(2e6, address(_plasmaVault));
        _erc4626_2.deposit(3e6, address(_plasmaVault));
        _erc4626_3.deposit(4e6, address(_plasmaVault));
        vm.stopPrank();

        // when
        vm.startPrank(_USER);
        _plasmaVault.deposit(1e5, _USER);
        vm.stopPrank();

        // then
        // All markets should be updated as all changes are above dust threshold (1e6)
        assertEq(erc4626BalanceBefore1 + 2e6, _plasmaVault.totalAssetsInMarket(_marketIds[0]));
        assertEq(erc4626BalanceBefore2 + 3e6, _plasmaVault.totalAssetsInMarket(_marketIds[1]));
        assertEq(erc4626BalanceBefore3 + 4e6, _plasmaVault.totalAssetsInMarket(_marketIds[2]));
    }
}
