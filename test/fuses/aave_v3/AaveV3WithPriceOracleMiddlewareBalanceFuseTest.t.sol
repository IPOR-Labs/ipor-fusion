// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {TestAddresses} from "../../test_helpers/TestAddresses.sol";
import {FusionFactoryDaoFeePackagesHelper} from "../../test_helpers/FusionFactoryDaoFeePackagesHelper.sol";
import {FusionFactoryLib} from "../../../contracts/factory/lib/FusionFactoryLib.sol";
import {FusionFactoryLogicLib} from "../../../contracts/factory/lib/FusionFactoryLogicLib.sol";
import {FusionFactory} from "../../../contracts/factory/FusionFactory.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVault, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";
import {AaveV3WithPriceOracleMiddlewareBalanceFuse} from "../../../contracts/fuses/aave_v3/AaveV3WithPriceOracleMiddlewareBalanceFuse.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {AaveV3SupplyFuseEnterData, AaveV3SupplyFuseExitData} from "../../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {AaveV3BorrowFuseEnterData, AaveV3BorrowFuseExitData} from "../../../contracts/fuses/aave_v3/AaveV3BorrowFuse.sol";

/*
Test description:
- Verifies the Aave V3 balance fuse integrated with the PriceOracleMiddleware inside the PlasmaVault.
- Checks updates of market balance for `AAVE_V3` in `PlasmaVault.totalAssetsInMarket(...)` after operations:
  - supply (enter) WETH and wstETH → balance increases,
  - withdraw (exit) WETH → balance decreases,
  - borrow WETH → balance decreases,
  - repay WETH → balance increases.
- Confirms dependency graph configuration: market `AAVE_V3` depends on `ERC20_VAULT_BALANCE`.

Fork environment:
- Chain: Base
- RPC source: env var `BASE_PROVIDER_URL`
- Block number: 34_381_896
*/
contract AaveV3WithPriceOracleMiddlewareBalanceFuseTest is Test {
    address private constant _WETH = 0x4200000000000000000000000000000000000006;
    address private constant _WST_ETH = 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452;
    address private constant _AAVE_V3_POOL_ADDRESSES_PROVIDER = 0xe20fCBdBfFC4Dd138cE8b2E6FBb6CB49777ad64D;

    address private constant _USER = TestAddresses.USER;
    address private constant _ATOMIST = TestAddresses.ATOMIST;
    address private constant _FUSE_MANAGER = TestAddresses.FUSE_MANAGER;
    address private constant _ALPHA = TestAddresses.ALPHA;

    address private constant _fusionFactory = 0x1455717668fA96534f675856347A973fA907e922;

    FusionFactoryLogicLib.FusionInstance private _fusionInstance;

    address private _supplyFuseAaveV3 = 0x44dcB8A4c40FA9941d99F409b2948FE91B6C15d5;
    address private _aaveV3BorrowFuse = 0x1Df60F2A046F3Dce8102427e091C1Ea99aE1d774;
    address private _balanceFuseAaveV3;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_PROVIDER_URL"), 34381896);

        FusionFactory fusionFactory = FusionFactory(_fusionFactory);

        // Setup fee packages before creating vault
        FusionFactoryDaoFeePackagesHelper.setupDefaultDaoFeePackages(vm, fusionFactory);

        _fusionInstance = fusionFactory.create("AaveV2WithPriceOracleMiddlewareBalanceFuse", "AV2", _WETH, 0, _ATOMIST, 0);

        vm.startPrank(_ATOMIST);
        IporFusionAccessManager(_fusionInstance.accessManager).grantRole(Roles.ATOMIST_ROLE, _ATOMIST, 0);
        IporFusionAccessManager(_fusionInstance.accessManager).grantRole(Roles.FUSE_MANAGER_ROLE, _FUSE_MANAGER, 0);
        IporFusionAccessManager(_fusionInstance.accessManager).grantRole(Roles.ALPHA_ROLE, _ALPHA, 0);
        IporFusionAccessManager(_fusionInstance.accessManager).grantRole(Roles.CLAIM_REWARDS_ROLE, _ALPHA, 0);
        IporFusionAccessManager(_fusionInstance.accessManager).grantRole(
            Roles.PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE,
            _ATOMIST,
            0
        );
        PlasmaVaultGovernance(_fusionInstance.plasmaVault).convertToPublicVault();
        PlasmaVaultGovernance(_fusionInstance.plasmaVault).enableTransferShares();
        vm.stopPrank();

        deal(_WETH, _USER, 1_000_000e18);
        deal(_WST_ETH, _USER, 1_000_000e18);

        _balanceFuseAaveV3 = address(
            new AaveV3WithPriceOracleMiddlewareBalanceFuse(IporFusionMarkets.AAVE_V3, _AAVE_V3_POOL_ADDRESSES_PROVIDER)
        );

        address[] memory fuses = new address[](2);
        fuses[0] = _supplyFuseAaveV3;
        fuses[1] = _aaveV3BorrowFuse;

        vm.startPrank(_FUSE_MANAGER);
        PlasmaVaultGovernance(_fusionInstance.plasmaVault).addFuses(fuses);
        PlasmaVaultGovernance(_fusionInstance.plasmaVault).addBalanceFuse(
            IporFusionMarkets.AAVE_V3,
            _balanceFuseAaveV3
        );

        PlasmaVaultGovernance(_fusionInstance.plasmaVault).addBalanceFuse(
            IporFusionMarkets.ERC20_VAULT_BALANCE,
            address(new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE))
        );
        vm.stopPrank();

        bytes32[] memory aaveV3Substrates = new bytes32[](2);
        aaveV3Substrates[0] = PlasmaVaultConfigLib.addressToBytes32(_WETH);
        aaveV3Substrates[1] = PlasmaVaultConfigLib.addressToBytes32(_WST_ETH);

        vm.startPrank(_FUSE_MANAGER);
        PlasmaVaultGovernance(_fusionInstance.plasmaVault).grantMarketSubstrates(
            IporFusionMarkets.AAVE_V3,
            aaveV3Substrates
        );
        PlasmaVaultGovernance(_fusionInstance.plasmaVault).grantMarketSubstrates(
            IporFusionMarkets.ERC20_VAULT_BALANCE,
            aaveV3Substrates
        );
        vm.stopPrank();

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.AAVE_V3;
        uint256[][] memory dependencies = new uint256[][](1);
        dependencies[0] = new uint256[](1);
        dependencies[0][0] = IporFusionMarkets.ERC20_VAULT_BALANCE;

        vm.startPrank(_FUSE_MANAGER);
        PlasmaVaultGovernance(_fusionInstance.plasmaVault).updateDependencyBalanceGraphs(marketIds, dependencies);
        vm.stopPrank();

        vm.startPrank(_USER);
        IERC20(_WETH).approve(address(_fusionInstance.plasmaVault), 10_000e18);
        PlasmaVault(_fusionInstance.plasmaVault).deposit(10_000e18, _USER);
        IERC20(_WST_ETH).transfer(_fusionInstance.plasmaVault, 1_000e18);
        vm.stopPrank();
    }

    function test_ShouldIncreaseBalanceInMarketAfterEnterWeth() public {
        // given
        uint256 amountToEnter = 1_000e18;

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                AaveV3SupplyFuseEnterData({asset: _WETH, amount: amountToEnter, userEModeCategoryId: 300})
            )
        );

        uint256 marketBalanceBefore = PlasmaVault(_fusionInstance.plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.AAVE_V3
        );

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(_fusionInstance.plasmaVault).execute(enterCalls);
        vm.stopPrank();

        // then
        uint256 marketBalanceAfter = PlasmaVault(_fusionInstance.plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.AAVE_V3
        );
        assertGt(marketBalanceAfter, marketBalanceBefore, "marketBalanceAfter > marketBalanceBefore");
        assertApproxEqAbs(marketBalanceAfter, marketBalanceBefore + amountToEnter, 1e18);
    }

    function test_ShouldIncreaseBalanceInMarketAfterEnterWstEth() public {
        // given
        uint256 amountToEnter = 1_000e18;

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                AaveV3SupplyFuseEnterData({asset: _WST_ETH, amount: amountToEnter, userEModeCategoryId: 300})
            )
        );

        uint256 marketBalanceBefore = PlasmaVault(_fusionInstance.plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.AAVE_V3
        );

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(_fusionInstance.plasmaVault).execute(enterCalls);
        vm.stopPrank();

        // then
        uint256 marketBalanceAfter = PlasmaVault(_fusionInstance.plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.AAVE_V3
        );
        assertGt(marketBalanceAfter, marketBalanceBefore, "marketBalanceAfter > marketBalanceBefore");
        assertApproxEqAbs(marketBalanceAfter, 1208451661235180296787, 1e18);
    }

    function test_ShouldIncreaseBalanceInMarketAfterEnterWethAndWstEth() public {
        // given
        uint256 amountToEnter = 1_000e18;

        FuseAction[] memory enterCalls = new FuseAction[](2);
        enterCalls[0] = FuseAction(
            address(_supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                AaveV3SupplyFuseEnterData({asset: _WETH, amount: amountToEnter, userEModeCategoryId: 300})
            )
        );

        enterCalls[1] = FuseAction(
            address(_supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                AaveV3SupplyFuseEnterData({asset: _WST_ETH, amount: amountToEnter, userEModeCategoryId: 300})
            )
        );

        uint256 marketBalanceBefore = PlasmaVault(_fusionInstance.plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.AAVE_V3
        );

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(_fusionInstance.plasmaVault).execute(enterCalls);
        vm.stopPrank();

        // then
        uint256 marketBalanceAfter = PlasmaVault(_fusionInstance.plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.AAVE_V3
        );
        assertGt(marketBalanceAfter, marketBalanceBefore, "marketBalanceAfter > marketBalanceBefore");
        assertApproxEqAbs(marketBalanceAfter, 1208451661235180296787 + amountToEnter, 1e18);
    }

    function test_ShouldDecreaseBalanceInMarketAfterExitWeth() public {
        // given
        test_ShouldIncreaseBalanceInMarketAfterEnterWeth();

        uint256 marketBalanceBefore = PlasmaVault(_fusionInstance.plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.AAVE_V3
        );

        FuseAction[] memory exitCalls = new FuseAction[](1);
        exitCalls[0] = FuseAction(
            address(_supplyFuseAaveV3),
            abi.encodeWithSignature("exit((address,uint256))", AaveV3SupplyFuseExitData({asset: _WETH, amount: 500e18}))
        );

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(_fusionInstance.plasmaVault).execute(exitCalls);
        vm.stopPrank();

        // then
        uint256 marketBalanceAfter = PlasmaVault(_fusionInstance.plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.AAVE_V3
        );
        assertGt(marketBalanceBefore, marketBalanceAfter, "marketBalanceBefore > marketBalanceAfter");
        assertApproxEqAbs(marketBalanceAfter, marketBalanceBefore - 500e18, 1e18);
    }

    function test_shouldDecreaseBalanceInMarketWhenBorrow() public {
        // given
        test_ShouldIncreaseBalanceInMarketAfterEnterWstEth();

        uint256 marketBalanceBefore = PlasmaVault(_fusionInstance.plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.AAVE_V3
        );

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_aaveV3BorrowFuse),
            abi.encodeWithSignature(
                "enter((address,uint256))",
                AaveV3BorrowFuseEnterData({asset: _WETH, amount: 100e18})
            )
        );

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(_fusionInstance.plasmaVault).execute(enterCalls);
        vm.stopPrank();

        // then
        uint256 marketBalanceAfter = PlasmaVault(_fusionInstance.plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.AAVE_V3
        );
        assertGt(marketBalanceBefore, marketBalanceAfter, "marketBalanceBefore > marketBalanceAfter");
    }

    function test_shouldIncreaseBalanceInMarketWhenRepay() public {
        // given
        test_shouldDecreaseBalanceInMarketWhenBorrow();

        uint256 marketBalanceBefore = PlasmaVault(_fusionInstance.plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.AAVE_V3
        );

        FuseAction[] memory exitCalls = new FuseAction[](1);
        exitCalls[0] = FuseAction(
            address(_aaveV3BorrowFuse),
            abi.encodeWithSignature("exit((address,uint256))", AaveV3BorrowFuseExitData({asset: _WETH, amount: 50e18}))
        );

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(_fusionInstance.plasmaVault).execute(exitCalls);
        vm.stopPrank();

        // then
        uint256 marketBalanceAfter = PlasmaVault(_fusionInstance.plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.AAVE_V3
        );
        assertGt(marketBalanceAfter, marketBalanceBefore, "marketBalanceAfter > marketBalanceBefore");
    }
}
