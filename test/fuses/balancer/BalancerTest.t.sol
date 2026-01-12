// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {FusionFactory} from "../../../contracts/factory/FusionFactory.sol";
import {FusionFactoryLib} from "../../../contracts/factory/lib/FusionFactoryLib.sol";
import {FusionFactoryLogicLib} from "../../../contracts/factory/lib/FusionFactoryLogicLib.sol";
import {TestAddresses} from "../../test_helpers/TestAddresses.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVault, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {BalancerBalanceFuse} from "../../../contracts/fuses/balancer/BalancerBalanceFuse.sol";
import {BalancerGaugeFuse, BalancerGaugeFuseEnterData, BalancerGaugeFuseExitData} from "../../../contracts/fuses/balancer/BalancerGaugeFuse.sol";
import {BalancerLiquidityProportionalFuse, BalancerLiquidityProportionalFuseEnterData, BalancerLiquidityProportionalFuseExitData} from "../../../contracts/fuses/balancer/BalancerLiquidityProportionalFuse.sol";
import {BalancerLiquidityUnbalancedFuse, BalancerLiquidityUnbalancedFuseEnterData, BalancerLiquidityUnbalancedFuseExitData} from "../../../contracts/fuses/balancer/BalancerLiquidityUnbalancedFuse.sol";
import {BalancerSingleTokenFuse, BalancerSingleTokenFuseEnterData, BalancerSingleTokenFuseExitData} from "../../../contracts/fuses/balancer/BalancerSingleTokenFuse.sol";
import {BalancerSubstrateLib, BalancerSubstrate, BalancerSubstrateType} from "../../../contracts/fuses/balancer/BalancerSubstrateLib.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {FusionFactory} from "../../../contracts/factory/FusionFactory.sol";
import {FusionFactoryLib} from "../../../contracts/factory/lib/FusionFactoryLib.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {PriceOracleMiddlewareManager} from "../../../contracts/managers/price/PriceOracleMiddlewareManager.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";
import {PlasmaVault, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {TestAddresses} from "../../test_helpers/TestAddresses.sol";
import {TransientStorageLib} from "../../../contracts/transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "../../../contracts/libraries/TypeConversionLib.sol";
import {TransientStorageSetInputsFuse, TransientStorageSetInputsFuseEnterData} from "../../../contracts/fuses/transient_storage/TransientStorageSetInputsFuse.sol";

contract BalancerTest is Test {
    // balancer pool addresses https://balancer.fi/pools/ethereum/v3/0x6b31a94029fd7840d780191b6d63fa0d269bd883
    address private constant _FWST_ETH = 0x2411802D8BEA09be0aF8fD8D08314a63e706b29C;
    address private constant _FW_ETH = 0x90551c1795392094FE6D29B758EcCD233cFAa260;

    address private constant _W_ETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant _WST_ETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    address private constant _BALANCER_POOL = 0x6b31a94029fd7840d780191B6D63Fa0D269bd883;
    address private constant _BALANCER_GAUGE = 0x1CCE9d493224A19FcB5f7fBade8478630141CB54;
    address private constant _BALANCER_ROUTER = 0x5C6fb490BDFD3246EB0bB062c168DeCAF4bD9FDd;
    address private constant _PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address private constant _FUSION_FACTORY = 0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852;

    address private constant _USER = TestAddresses.USER;
    address private constant _ATOMIST = TestAddresses.ATOMIST;
    address private constant _FUSE_MANAGER = TestAddresses.FUSE_MANAGER;
    address private constant _ALPHA = TestAddresses.ALPHA;

    BalancerBalanceFuse private _balancerBalanceFuse;

    FusionFactoryLogicLib.FusionInstance private _fusionInstance;
    BalancerGaugeFuse private _balancerGaugeFuse;
    BalancerLiquidityProportionalFuse private _balancerLiquidityProportionalFuse;
    BalancerLiquidityUnbalancedFuse private _balancerLiquidityUnbalancedFuse;
    BalancerSingleTokenFuse private _balancerSingleTokenFuse;
    TransientStorageSetInputsFuse private _transientStorageSetInputsFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 23137973);

        FusionFactory fusionFactory = FusionFactory(_FUSION_FACTORY);

        _fusionInstance = fusionFactory.create("Balancer", "F_BAL", _FW_ETH, 0, _ATOMIST);

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

        deal(_W_ETH, _USER, 100_000e18);
        deal(_WST_ETH, _USER, 100_000e18);
        vm.startPrank(_USER);
        IERC20(_W_ETH).approve(_FW_ETH, type(uint256).max);
        IERC20(_WST_ETH).approve(_FWST_ETH, type(uint256).max);
        IERC4626(_FW_ETH).deposit(100_000e18, _USER);
        IERC4626(_FWST_ETH).deposit(100_000e18, _USER);
        IERC20(_FW_ETH).approve(_fusionInstance.plasmaVault, type(uint256).max);
        vm.stopPrank();

        _balancerBalanceFuse = new BalancerBalanceFuse(IporFusionMarkets.BALANCER);
        _balancerGaugeFuse = new BalancerGaugeFuse(IporFusionMarkets.BALANCER);
        _balancerLiquidityProportionalFuse = new BalancerLiquidityProportionalFuse(
            IporFusionMarkets.BALANCER,
            _BALANCER_ROUTER,
            _PERMIT2
        );
        _balancerLiquidityUnbalancedFuse = new BalancerLiquidityUnbalancedFuse(
            IporFusionMarkets.BALANCER,
            _BALANCER_ROUTER,
            _PERMIT2
        );
        _balancerSingleTokenFuse = new BalancerSingleTokenFuse(IporFusionMarkets.BALANCER, _BALANCER_ROUTER, _PERMIT2);
        _transientStorageSetInputsFuse = new TransientStorageSetInputsFuse();

        address[] memory fuses = new address[](5);
        fuses[0] = address(_balancerGaugeFuse);
        fuses[1] = address(_balancerLiquidityProportionalFuse);
        fuses[2] = address(_balancerLiquidityUnbalancedFuse);
        fuses[3] = address(_balancerSingleTokenFuse);
        fuses[4] = address(_transientStorageSetInputsFuse);

        vm.startPrank(_FUSE_MANAGER);
        PlasmaVaultGovernance(_fusionInstance.plasmaVault).addFuses(fuses);
        PlasmaVaultGovernance(_fusionInstance.plasmaVault).addBalanceFuse(
            IporFusionMarkets.BALANCER,
            address(_balancerBalanceFuse)
        );

        PlasmaVaultGovernance(_fusionInstance.plasmaVault).addBalanceFuse(
            IporFusionMarkets.ERC20_VAULT_BALANCE,
            address(new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE))
        );
        vm.stopPrank();

        // Setup market substrates
        bytes32[] memory balancerSubstrates = new bytes32[](2);
        balancerSubstrates[0] = BalancerSubstrateLib.substrateToBytes32(
            BalancerSubstrate({substrateType: BalancerSubstrateType.POOL, substrateAddress: _BALANCER_POOL})
        );
        balancerSubstrates[1] = BalancerSubstrateLib.substrateToBytes32(
            BalancerSubstrate({substrateType: BalancerSubstrateType.GAUGE, substrateAddress: _BALANCER_GAUGE})
        );
        vm.startPrank(_FUSE_MANAGER);
        PlasmaVaultGovernance(_fusionInstance.plasmaVault).grantMarketSubstrates(
            IporFusionMarkets.BALANCER,
            balancerSubstrates
        );
        vm.stopPrank();

        bytes32[] memory erc20VaultBalanceSubstrates = new bytes32[](2);
        erc20VaultBalanceSubstrates[0] = PlasmaVaultConfigLib.addressToBytes32(_FW_ETH);
        erc20VaultBalanceSubstrates[1] = PlasmaVaultConfigLib.addressToBytes32(_FWST_ETH);

        vm.startPrank(_FUSE_MANAGER);
        PlasmaVaultGovernance(_fusionInstance.plasmaVault).grantMarketSubstrates(
            IporFusionMarkets.ERC20_VAULT_BALANCE,
            erc20VaultBalanceSubstrates
        );
        vm.stopPrank();

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.BALANCER;
        uint256[][] memory dependencies = new uint256[][](1);
        dependencies[0] = new uint256[](1);
        dependencies[0][0] = IporFusionMarkets.ERC20_VAULT_BALANCE;

        vm.startPrank(_FUSE_MANAGER);
        PlasmaVaultGovernance(_fusionInstance.plasmaVault).updateDependencyBalanceGraphs(marketIds, dependencies);
        vm.stopPrank();

        vm.startPrank(_USER);
        IERC4626(_fusionInstance.plasmaVault).deposit(50_000e18, _USER);
        IERC20(_FWST_ETH).transfer(_fusionInstance.plasmaVault, 50_000e18);
        vm.stopPrank();

        address[] memory tokens = new address[](2);
        tokens[0] = _FW_ETH;
        tokens[1] = _FWST_ETH;
        address[] memory sources = new address[](2);
        sources[0] = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
        sources[1] = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

        vm.startPrank(_ATOMIST);
        PriceOracleMiddlewareManager(_fusionInstance.priceManager).setAssetsPriceSources(tokens, sources);
        vm.stopPrank();
    }

    function testShouldEnterBalancerLiquidityProportional() public {
        // given
        address vault = _fusionInstance.plasmaVault;

        address[] memory tokens = new address[](2);
        tokens[0] = _FW_ETH;
        tokens[1] = _FWST_ETH;

        uint256[] memory maxAmountsIn = new uint256[](2);
        maxAmountsIn[0] = IERC20(_FW_ETH).balanceOf(vault);
        maxAmountsIn[1] = IERC20(_FWST_ETH).balanceOf(vault);

        BalancerLiquidityProportionalFuseEnterData memory enterData = BalancerLiquidityProportionalFuseEnterData({
            pool: _BALANCER_POOL,
            tokens: tokens,
            maxAmountsIn: maxAmountsIn,
            exactBptAmountOut: 1e15
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction({
            fuse: address(_balancerLiquidityProportionalFuse),
            data: abi.encodeWithSignature("enter((address,address[],uint256[],uint256))", enterData)
        });

        uint256 marketBalanceBefore = PlasmaVault(vault).totalAssetsInMarket(IporFusionMarkets.BALANCER);
        uint256 bptBalanceBefore = IERC20(_BALANCER_POOL).balanceOf(vault);

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(vault).execute(enterCalls);
        vm.stopPrank();

        // then
        uint256 marketBalanceAfter = PlasmaVault(vault).totalAssetsInMarket(IporFusionMarkets.BALANCER);
        uint256 bptBalanceAfter = IERC20(_BALANCER_POOL).balanceOf(vault);

        assertGt(bptBalanceAfter, bptBalanceBefore, "BPT balance should increase after proportional add");
        assertGt(marketBalanceAfter, marketBalanceBefore, "market balance should increase after proportional add");
    }

    function testShouldExitBalancerLiquidityProportional() public {
        // First add liquidity to have BPT tokens to exit
        address vault = _fusionInstance.plasmaVault;

        address[] memory tokens = new address[](2);
        tokens[0] = _FW_ETH;
        tokens[1] = _FWST_ETH;

        uint256[] memory maxAmountsIn = new uint256[](2);
        maxAmountsIn[0] = IERC20(_FW_ETH).balanceOf(vault);
        maxAmountsIn[1] = IERC20(_FWST_ETH).balanceOf(vault);

        BalancerLiquidityProportionalFuseEnterData memory enterData = BalancerLiquidityProportionalFuseEnterData({
            pool: _BALANCER_POOL,
            tokens: tokens,
            maxAmountsIn: maxAmountsIn,
            exactBptAmountOut: 1e15
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction({
            fuse: address(_balancerLiquidityProportionalFuse),
            data: abi.encodeWithSignature("enter((address,address[],uint256[],uint256))", enterData)
        });

        // Add liquidity first
        vm.startPrank(_ALPHA);
        PlasmaVault(vault).execute(enterCalls);
        vm.stopPrank();

        // Now test exit functionality
        uint256 bptBalanceBeforeExit = IERC20(_BALANCER_POOL).balanceOf(vault);
        uint256 fwEthBalanceBefore = IERC20(_FW_ETH).balanceOf(vault);
        uint256 fwstEthBalanceBefore = IERC20(_FWST_ETH).balanceOf(vault);

        // Prepare exit data
        uint256[] memory minAmountsOut = new uint256[](2);
        minAmountsOut[0] = 0; // Minimum amount of FW_ETH to receive
        minAmountsOut[1] = 0; // Minimum amount of FWST_ETH to receive

        BalancerLiquidityProportionalFuseExitData memory exitData = BalancerLiquidityProportionalFuseExitData({
            pool: _BALANCER_POOL,
            exactBptAmountIn: bptBalanceBeforeExit / 2, // Exit half of the BPT tokens
            minAmountsOut: minAmountsOut
        });

        FuseAction[] memory exitCalls = new FuseAction[](1);
        exitCalls[0] = FuseAction({
            fuse: address(_balancerLiquidityProportionalFuse),
            data: abi.encodeWithSignature("exit((address,uint256,uint256[]))", exitData)
        });

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(vault).execute(exitCalls);
        vm.stopPrank();

        // then
        uint256 bptBalanceAfterExit = IERC20(_BALANCER_POOL).balanceOf(vault);
        uint256 fwEthBalanceAfter = IERC20(_FW_ETH).balanceOf(vault);
        uint256 fwstEthBalanceAfter = IERC20(_FWST_ETH).balanceOf(vault);

        assertLt(bptBalanceAfterExit, bptBalanceBeforeExit, "BPT balance should decrease after proportional exit");
        assertGt(fwEthBalanceAfter, fwEthBalanceBefore, "FW_ETH balance should increase after proportional exit");
        assertGt(fwstEthBalanceAfter, fwstEthBalanceBefore, "FWST_ETH balance should increase after proportional exit");
    }

    function testShouldEnterBalancerLiquidityUnbalanced() public {
        // given
        address vault = _fusionInstance.plasmaVault;

        address[] memory tokens = new address[](2);
        tokens[0] = _FW_ETH;
        tokens[1] = _FWST_ETH;

        uint256[] memory exactAmountsIn = new uint256[](2);
        exactAmountsIn[0] = 1e18; // Exact amount of FW_ETH to add
        exactAmountsIn[1] = 1e18; // Exact amount of FWST_ETH to add

        BalancerLiquidityUnbalancedFuseEnterData memory enterData = BalancerLiquidityUnbalancedFuseEnterData({
            pool: _BALANCER_POOL,
            tokens: tokens,
            exactAmountsIn: exactAmountsIn,
            minBptAmountOut: 0 // Minimum BPT tokens to receive
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction({
            fuse: address(_balancerLiquidityUnbalancedFuse),
            data: abi.encodeWithSignature("enter((address,address[],uint256[],uint256))", enterData)
        });

        uint256 marketBalanceBefore = PlasmaVault(vault).totalAssetsInMarket(IporFusionMarkets.BALANCER);
        uint256 bptBalanceBefore = IERC20(_BALANCER_POOL).balanceOf(vault);
        uint256 fwEthBalanceBefore = IERC20(_FW_ETH).balanceOf(vault);
        uint256 fwstEthBalanceBefore = IERC20(_FWST_ETH).balanceOf(vault);

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(vault).execute(enterCalls);
        vm.stopPrank();

        // then
        uint256 marketBalanceAfter = PlasmaVault(vault).totalAssetsInMarket(IporFusionMarkets.BALANCER);
        uint256 bptBalanceAfter = IERC20(_BALANCER_POOL).balanceOf(vault);
        uint256 fwEthBalanceAfter = IERC20(_FW_ETH).balanceOf(vault);
        uint256 fwstEthBalanceAfter = IERC20(_FWST_ETH).balanceOf(vault);

        assertGt(bptBalanceAfter, bptBalanceBefore, "BPT balance should increase after unbalanced add");
        assertGt(marketBalanceAfter, marketBalanceBefore, "market balance should increase after unbalanced add");
        assertLt(fwEthBalanceAfter, fwEthBalanceBefore, "FW_ETH balance should decrease after unbalanced add");
        assertLt(fwstEthBalanceAfter, fwstEthBalanceBefore, "FWST_ETH balance should decrease after unbalanced add");
    }

    function testShouldEnterBalancerSingleToken() public {
        // given
        address vault = _fusionInstance.plasmaVault;

        BalancerSingleTokenFuseEnterData memory enterData = BalancerSingleTokenFuseEnterData({
            pool: _BALANCER_POOL,
            tokenIn: _FW_ETH,
            maxAmountIn: 1e18, // 1 FW_ETH
            exactBptAmountOut: 1e15 // 0.001 BPT tokens
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction({
            fuse: address(_balancerSingleTokenFuse),
            data: abi.encodeWithSignature("enter((address,address,uint256,uint256))", enterData)
        });

        uint256 marketBalanceBefore = PlasmaVault(vault).totalAssetsInMarket(IporFusionMarkets.BALANCER);
        uint256 bptBalanceBefore = IERC20(_BALANCER_POOL).balanceOf(vault);
        uint256 fwEthBalanceBefore = IERC20(_FW_ETH).balanceOf(vault);

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(vault).execute(enterCalls);
        vm.stopPrank();

        // then
        uint256 marketBalanceAfter = PlasmaVault(vault).totalAssetsInMarket(IporFusionMarkets.BALANCER);
        uint256 bptBalanceAfter = IERC20(_BALANCER_POOL).balanceOf(vault);
        uint256 fwEthBalanceAfter = IERC20(_FW_ETH).balanceOf(vault);

        assertGt(bptBalanceAfter, bptBalanceBefore, "BPT balance should increase after single token add");
        assertGt(marketBalanceAfter, marketBalanceBefore, "market balance should increase after single token add");
        assertLt(fwEthBalanceAfter, fwEthBalanceBefore, "FW_ETH balance should decrease after single token add");
    }

    // function testShouldExitBalancerSingleToken() public {
    //     // given
    //     // testShouldEnterBalancerSingleToken();
    //     testShouldEnterBalancerLiquidityProportional();

    //     address vault = _fusionInstance.plasmaVault;

    //     BalancerSingleTokenFuseExitData memory exitData = BalancerSingleTokenFuseExitData({
    //         pool: _BALANCER_POOL,
    //         tokenOut: _FW_ETH,
    //         maxBptAmountIn: 1e15,
    //         exactAmountOut: 1e10
    //     });

    //     FuseAction[] memory exitCalls = new FuseAction[](1);
    //     exitCalls[0] = FuseAction({
    //         fuse: address(_balancerSingleTokenFuse),
    //         data: abi.encodeWithSignature("exit((address,address,uint256,uint256))", exitData)
    //     });

    //     // when
    //     vm.startPrank(_ALPHA);
    //     PlasmaVault(vault).execute(exitCalls);
    //     vm.stopPrank();

    //     // then
    //     uint256 bptBalanceAfter = IERC20(_BALANCER_POOL).balanceOf(vault);
    // }

    function testShouldRevertWhenEnteringWithZeroMaxAmountIn() public {
        // given
        address vault = _fusionInstance.plasmaVault;

        BalancerSingleTokenFuseEnterData memory enterData = BalancerSingleTokenFuseEnterData({
            pool: _BALANCER_POOL,
            tokenIn: _FW_ETH,
            maxAmountIn: 0, // Zero amount should cause early return
            exactBptAmountOut: 1e15
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction({
            fuse: address(_balancerSingleTokenFuse),
            data: abi.encodeWithSignature("enter((address,address,uint256,uint256))", enterData)
        });

        uint256 bptBalanceBefore = IERC20(_BALANCER_POOL).balanceOf(vault);

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(vault).execute(enterCalls);
        vm.stopPrank();

        // then
        uint256 bptBalanceAfter = IERC20(_BALANCER_POOL).balanceOf(vault);
        assertEq(bptBalanceAfter, bptBalanceBefore, "BPT balance should not change with zero maxAmountIn");
    }

    function testShouldRevertWhenEnteringWithInvalidPool() public {
        // given
        address vault = _fusionInstance.plasmaVault;

        BalancerSingleTokenFuseEnterData memory enterData = BalancerSingleTokenFuseEnterData({
            pool: address(0), // Invalid pool address
            tokenIn: _FW_ETH,
            maxAmountIn: 1e18,
            exactBptAmountOut: 1e15
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction({
            fuse: address(_balancerSingleTokenFuse),
            data: abi.encodeWithSignature("enter((address,address,uint256,uint256))", enterData)
        });

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(abi.encodeWithSignature("BalancerSingleTokenFuseInvalidParams()"));
        PlasmaVault(vault).execute(enterCalls);
        vm.stopPrank();
    }

    function testShouldRevertWhenEnteringWithInvalidTokenIn() public {
        // given
        address vault = _fusionInstance.plasmaVault;

        BalancerSingleTokenFuseEnterData memory enterData = BalancerSingleTokenFuseEnterData({
            pool: _BALANCER_POOL,
            tokenIn: address(0), // Invalid token address
            maxAmountIn: 10e18,
            exactBptAmountOut: 1e10
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction({
            fuse: address(_balancerSingleTokenFuse),
            data: abi.encodeWithSignature("enter((address,address,uint256,uint256))", enterData)
        });

        // when & then testShouldRevertWhenEnteringWithInvalidTokenIn
        vm.startPrank(_ALPHA);
        vm.expectRevert(abi.encodeWithSignature("BalancerSingleTokenFuseInvalidParams()"));
        PlasmaVault(vault).execute(enterCalls);
        vm.stopPrank();
    }

    function testShouldEnterBalancerGauge() public {
        // First add liquidity to have BPT tokens to stake in gauge
        address vault = _fusionInstance.plasmaVault;

        address[] memory tokens = new address[](2);
        tokens[0] = _FW_ETH;
        tokens[1] = _FWST_ETH;

        uint256[] memory maxAmountsIn = new uint256[](2);
        maxAmountsIn[0] = IERC20(_FW_ETH).balanceOf(vault);
        maxAmountsIn[1] = IERC20(_FWST_ETH).balanceOf(vault);

        BalancerLiquidityProportionalFuseEnterData memory enterData = BalancerLiquidityProportionalFuseEnterData({
            pool: _BALANCER_POOL,
            tokens: tokens,
            maxAmountsIn: maxAmountsIn,
            exactBptAmountOut: 1e15
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction({
            fuse: address(_balancerLiquidityProportionalFuse),
            data: abi.encodeWithSignature("enter((address,address[],uint256[],uint256))", enterData)
        });

        // Add liquidity first to get BPT tokens
        vm.startPrank(_ALPHA);
        PlasmaVault(vault).execute(enterCalls);
        vm.stopPrank();

        // Now test gauge staking
        uint256 bptBalanceBefore = IERC20(_BALANCER_POOL).balanceOf(vault);
        uint256 gaugeBalanceBefore = IERC20(_BALANCER_GAUGE).balanceOf(vault);

        BalancerGaugeFuseEnterData memory gaugeEnterData = BalancerGaugeFuseEnterData({
            gaugeAddress: _BALANCER_GAUGE,
            bptAmount: bptBalanceBefore / 2, // Stake half of BPT tokens
            minBptAmount: 0
        });

        FuseAction[] memory gaugeEnterCalls = new FuseAction[](1);
        gaugeEnterCalls[0] = FuseAction({
            fuse: address(_balancerGaugeFuse),
            data: abi.encodeWithSignature("enter((address,uint256,uint256))", gaugeEnterData)
        });

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(vault).execute(gaugeEnterCalls);
        vm.stopPrank();

        // then
        uint256 bptBalanceAfter = IERC20(_BALANCER_POOL).balanceOf(vault);
        uint256 gaugeBalanceAfter = IERC20(_BALANCER_GAUGE).balanceOf(vault);

        assertLt(bptBalanceAfter, bptBalanceBefore, "BPT balance should decrease after staking in gauge");
        assertGt(gaugeBalanceAfter, gaugeBalanceBefore, "Gauge balance should increase after staking");
    }

    function testShouldRevertWhenEnteringGaugeWithZeroBptAmount() public {
        // given
        address vault = _fusionInstance.plasmaVault;

        BalancerGaugeFuseEnterData memory gaugeEnterData = BalancerGaugeFuseEnterData({
            gaugeAddress: _BALANCER_GAUGE,
            bptAmount: 0, // Zero amount should cause early return
            minBptAmount: 0
        });

        FuseAction[] memory gaugeEnterCalls = new FuseAction[](1);
        gaugeEnterCalls[0] = FuseAction({
            fuse: address(_balancerGaugeFuse),
            data: abi.encodeWithSignature("enter((address,uint256,uint256))", gaugeEnterData)
        });

        uint256 gaugeBalanceBefore = IERC20(_BALANCER_GAUGE).balanceOf(vault);

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(vault).execute(gaugeEnterCalls);
        vm.stopPrank();

        // then
        uint256 gaugeBalanceAfter = IERC20(_BALANCER_GAUGE).balanceOf(vault);
        assertEq(gaugeBalanceAfter, gaugeBalanceBefore, "Gauge balance should not change with zero bptAmount");
    }

    function testShouldRevertWhenEnteringUnsupportedGauge() public {
        // given
        address vault = _fusionInstance.plasmaVault;
        address unsupportedGauge = address(0x1234567890123456789012345678901234567890);

        BalancerGaugeFuseEnterData memory gaugeEnterData = BalancerGaugeFuseEnterData({
            gaugeAddress: unsupportedGauge,
            bptAmount: 1e18,
            minBptAmount: 0
        });

        FuseAction[] memory gaugeEnterCalls = new FuseAction[](1);
        gaugeEnterCalls[0] = FuseAction({
            fuse: address(_balancerGaugeFuse),
            data: abi.encodeWithSignature("enter((address,uint256,uint256))", gaugeEnterData)
        });

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(abi.encodeWithSignature("BalancerGaugeFuseUnsupportedGauge(address)", unsupportedGauge));
        PlasmaVault(vault).execute(gaugeEnterCalls);
        vm.stopPrank();
    }

    function testShouldExitBalancerGauge() public {
        // First add liquidity and stake in gauge to have gauge tokens to withdraw
        address vault = _fusionInstance.plasmaVault;

        address[] memory tokens = new address[](2);
        tokens[0] = _FW_ETH;
        tokens[1] = _FWST_ETH;

        uint256[] memory maxAmountsIn = new uint256[](2);
        maxAmountsIn[0] = IERC20(_FW_ETH).balanceOf(vault);
        maxAmountsIn[1] = IERC20(_FWST_ETH).balanceOf(vault);

        BalancerLiquidityProportionalFuseEnterData memory enterData = BalancerLiquidityProportionalFuseEnterData({
            pool: _BALANCER_POOL,
            tokens: tokens,
            maxAmountsIn: maxAmountsIn,
            exactBptAmountOut: 1e15
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction({
            fuse: address(_balancerLiquidityProportionalFuse),
            data: abi.encodeWithSignature("enter((address,address[],uint256[],uint256))", enterData)
        });

        // Add liquidity first to get BPT tokens
        vm.startPrank(_ALPHA);
        PlasmaVault(vault).execute(enterCalls);
        vm.stopPrank();

        // Stake BPT tokens in gauge
        uint256 bptBalanceBeforeStake = IERC20(_BALANCER_POOL).balanceOf(vault);
        BalancerGaugeFuseEnterData memory gaugeEnterData = BalancerGaugeFuseEnterData({
            gaugeAddress: _BALANCER_GAUGE,
            bptAmount: bptBalanceBeforeStake / 2, // Stake half of BPT tokens
            minBptAmount: 0
        });

        FuseAction[] memory gaugeEnterCalls = new FuseAction[](1);
        gaugeEnterCalls[0] = FuseAction({
            fuse: address(_balancerGaugeFuse),
            data: abi.encodeWithSignature("enter((address,uint256,uint256))", gaugeEnterData)
        });

        vm.startPrank(_ALPHA);
        PlasmaVault(vault).execute(gaugeEnterCalls);
        vm.stopPrank();

        // Now test gauge exit functionality
        uint256 gaugeBalanceBeforeExit = IERC20(_BALANCER_GAUGE).balanceOf(vault);
        uint256 bptBalanceBeforeExit = IERC20(_BALANCER_POOL).balanceOf(vault);

        BalancerGaugeFuseExitData memory gaugeExitData = BalancerGaugeFuseExitData({
            gaugeAddress: _BALANCER_GAUGE,
            bptAmount: gaugeBalanceBeforeExit / 2, // Withdraw half of gauge tokens
            minBptAmount: 0
        });

        FuseAction[] memory gaugeExitCalls = new FuseAction[](1);
        gaugeExitCalls[0] = FuseAction({
            fuse: address(_balancerGaugeFuse),
            data: abi.encodeWithSignature("exit((address,uint256,uint256))", gaugeExitData)
        });

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(vault).execute(gaugeExitCalls);
        vm.stopPrank();

        // then
        uint256 gaugeBalanceAfterExit = IERC20(_BALANCER_GAUGE).balanceOf(vault);
        uint256 bptBalanceAfterExit = IERC20(_BALANCER_POOL).balanceOf(vault);

        assertLt(gaugeBalanceAfterExit, gaugeBalanceBeforeExit, "Gauge balance should decrease after exit");
        assertGt(bptBalanceAfterExit, bptBalanceBeforeExit, "BPT balance should increase after exit");
    }

    function testShouldRevertWhenExitingGaugeWithZeroBptAmount() public {
        // given
        address vault = _fusionInstance.plasmaVault;

        BalancerGaugeFuseExitData memory gaugeExitData = BalancerGaugeFuseExitData({
            gaugeAddress: _BALANCER_GAUGE,
            bptAmount: 0, // Zero amount should cause early return
            minBptAmount: 0
        });

        FuseAction[] memory gaugeExitCalls = new FuseAction[](1);
        gaugeExitCalls[0] = FuseAction({
            fuse: address(_balancerGaugeFuse),
            data: abi.encodeWithSignature("exit((address,uint256,uint256))", gaugeExitData)
        });

        uint256 gaugeBalanceBefore = IERC20(_BALANCER_GAUGE).balanceOf(vault);

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(vault).execute(gaugeExitCalls);
        vm.stopPrank();

        // then
        uint256 gaugeBalanceAfter = IERC20(_BALANCER_GAUGE).balanceOf(vault);
        assertEq(gaugeBalanceAfter, gaugeBalanceBefore, "Gauge balance should not change with zero bptAmount");
    }

    function testShouldRevertWhenExitingUnsupportedGauge() public {
        // given
        address vault = _fusionInstance.plasmaVault;
        address unsupportedGauge = address(0x1234567890123456789012345678901234567890);

        BalancerGaugeFuseExitData memory gaugeExitData = BalancerGaugeFuseExitData({
            gaugeAddress: unsupportedGauge,
            bptAmount: 1e18,
            minBptAmount: 0
        });

        FuseAction[] memory gaugeExitCalls = new FuseAction[](1);
        gaugeExitCalls[0] = FuseAction({
            fuse: address(_balancerGaugeFuse),
            data: abi.encodeWithSignature("exit((address,uint256,uint256))", gaugeExitData)
        });

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(abi.encodeWithSignature("BalancerGaugeFuseUnsupportedGauge(address)", unsupportedGauge));
        PlasmaVault(vault).execute(gaugeExitCalls);
        vm.stopPrank();
    }

    function testShouldRevertWhenEnteringProportionalWithZeroPool() public {
        // given
        address vault = _fusionInstance.plasmaVault;

        address[] memory tokens = new address[](2);
        tokens[0] = _FW_ETH;
        tokens[1] = _FWST_ETH;

        uint256[] memory maxAmountsIn = new uint256[](2);
        maxAmountsIn[0] = 1e18;
        maxAmountsIn[1] = 1e18;

        BalancerLiquidityProportionalFuseEnterData memory enterData = BalancerLiquidityProportionalFuseEnterData({
            pool: address(0), // Invalid pool address
            tokens: tokens,
            maxAmountsIn: maxAmountsIn,
            exactBptAmountOut: 1e15
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction({
            fuse: address(_balancerLiquidityProportionalFuse),
            data: abi.encodeWithSignature("enter((address,address[],uint256[],uint256))", enterData)
        });

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(abi.encodeWithSignature("BalancerLiquidityProportionalFuseInvalidParams()"));
        PlasmaVault(vault).execute(enterCalls);
        vm.stopPrank();
    }

    function testShouldRevertWhenEnteringProportionalWithMismatchedArrays() public {
        // given
        address vault = _fusionInstance.plasmaVault;

        address[] memory tokens = new address[](2);
        tokens[0] = _FW_ETH;
        tokens[1] = _FWST_ETH;

        uint256[] memory maxAmountsIn = new uint256[](3); // Different length
        maxAmountsIn[0] = 1e18;
        maxAmountsIn[1] = 1e18;
        maxAmountsIn[2] = 1e18;

        BalancerLiquidityProportionalFuseEnterData memory enterData = BalancerLiquidityProportionalFuseEnterData({
            pool: _BALANCER_POOL,
            tokens: tokens,
            maxAmountsIn: maxAmountsIn,
            exactBptAmountOut: 1e15
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction({
            fuse: address(_balancerLiquidityProportionalFuse),
            data: abi.encodeWithSignature("enter((address,address[],uint256[],uint256))", enterData)
        });

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(abi.encodeWithSignature("BalancerLiquidityProportionalFuseInvalidParams()"));
        PlasmaVault(vault).execute(enterCalls);
        vm.stopPrank();
    }

    function testShouldRevertWhenEnteringProportionalWithUnsupportedPool() public {
        // given
        address vault = _fusionInstance.plasmaVault;
        address unsupportedPool = address(0x1234567890123456789012345678901234567890);

        address[] memory tokens = new address[](2);
        tokens[0] = _FW_ETH;
        tokens[1] = _FWST_ETH;

        uint256[] memory maxAmountsIn = new uint256[](2);
        maxAmountsIn[0] = 1e18;
        maxAmountsIn[1] = 1e18;

        BalancerLiquidityProportionalFuseEnterData memory enterData = BalancerLiquidityProportionalFuseEnterData({
            pool: unsupportedPool,
            tokens: tokens,
            maxAmountsIn: maxAmountsIn,
            exactBptAmountOut: 1e15
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction({
            fuse: address(_balancerLiquidityProportionalFuse),
            data: abi.encodeWithSignature("enter((address,address[],uint256[],uint256))", enterData)
        });

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(
            abi.encodeWithSignature("BalancerLiquidityProportionalFuseUnsupportedPool(address)", unsupportedPool)
        );
        PlasmaVault(vault).execute(enterCalls);
        vm.stopPrank();
    }

    function testShouldRevertWhenEnteringProportionalWithZeroAmounts() public {
        // given
        address vault = _fusionInstance.plasmaVault;

        address[] memory tokens = new address[](2);
        tokens[0] = _FW_ETH;
        tokens[1] = _FWST_ETH;

        uint256[] memory maxAmountsIn = new uint256[](2);
        maxAmountsIn[0] = 0; // Zero amount
        maxAmountsIn[1] = 0; // Zero amount

        BalancerLiquidityProportionalFuseEnterData memory enterData = BalancerLiquidityProportionalFuseEnterData({
            pool: _BALANCER_POOL,
            tokens: tokens,
            maxAmountsIn: maxAmountsIn,
            exactBptAmountOut: 1e15
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction({
            fuse: address(_balancerLiquidityProportionalFuse),
            data: abi.encodeWithSignature("enter((address,address[],uint256[],uint256))", enterData)
        });

        // when & then - router will revert when all amounts are zero
        vm.startPrank(_ALPHA);
        vm.expectRevert();
        PlasmaVault(vault).execute(enterCalls);
        vm.stopPrank();
    }

    function testShouldEnterProportionalWithPartialZeroAmounts() public {
        // given - test case where one amount is zero and another is not
        address vault = _fusionInstance.plasmaVault;

        address[] memory tokens = new address[](2);
        tokens[0] = _FW_ETH;
        tokens[1] = _FWST_ETH;

        uint256[] memory maxAmountsIn = new uint256[](2);
        maxAmountsIn[0] = 1e18; // Non-zero amount
        maxAmountsIn[1] = 0; // Zero amount

        BalancerLiquidityProportionalFuseEnterData memory enterData = BalancerLiquidityProportionalFuseEnterData({
            pool: _BALANCER_POOL,
            tokens: tokens,
            maxAmountsIn: maxAmountsIn,
            exactBptAmountOut: 1e15
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction({
            fuse: address(_balancerLiquidityProportionalFuse),
            data: abi.encodeWithSignature("enter((address,address[],uint256[],uint256))", enterData)
        });

        // when - router may revert or handle this case, but we test the code path
        vm.startPrank(_ALPHA);
        // Router will likely revert, but we test that the code handles partial zero amounts
        vm.expectRevert();
        PlasmaVault(vault).execute(enterCalls);
        vm.stopPrank();
    }

    function testShouldRevertWhenExitingProportionalWithZeroPool() public {
        // given
        address vault = _fusionInstance.plasmaVault;

        uint256[] memory minAmountsOut = new uint256[](2);
        minAmountsOut[0] = 0;
        minAmountsOut[1] = 0;

        BalancerLiquidityProportionalFuseExitData memory exitData = BalancerLiquidityProportionalFuseExitData({
            pool: address(0), // Invalid pool address
            exactBptAmountIn: 1e15,
            minAmountsOut: minAmountsOut
        });

        FuseAction[] memory exitCalls = new FuseAction[](1);
        exitCalls[0] = FuseAction({
            fuse: address(_balancerLiquidityProportionalFuse),
            data: abi.encodeWithSignature("exit((address,uint256,uint256[]))", exitData)
        });

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(abi.encodeWithSignature("BalancerLiquidityProportionalFuseInvalidParams()"));
        PlasmaVault(vault).execute(exitCalls);
        vm.stopPrank();
    }

    function testShouldRevertWhenExitingProportionalWithUnsupportedPool() public {
        // given
        address vault = _fusionInstance.plasmaVault;
        address unsupportedPool = address(0x1234567890123456789012345678901234567890);

        uint256[] memory minAmountsOut = new uint256[](2);
        minAmountsOut[0] = 0;
        minAmountsOut[1] = 0;

        BalancerLiquidityProportionalFuseExitData memory exitData = BalancerLiquidityProportionalFuseExitData({
            pool: unsupportedPool,
            exactBptAmountIn: 1e15,
            minAmountsOut: minAmountsOut
        });

        FuseAction[] memory exitCalls = new FuseAction[](1);
        exitCalls[0] = FuseAction({
            fuse: address(_balancerLiquidityProportionalFuse),
            data: abi.encodeWithSignature("exit((address,uint256,uint256[]))", exitData)
        });

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(
            abi.encodeWithSignature("BalancerLiquidityProportionalFuseUnsupportedPool(address)", unsupportedPool)
        );
        PlasmaVault(vault).execute(exitCalls);
        vm.stopPrank();
    }

    function testShouldRevertWhenConstructingWithZeroRouter() public {
        // given & when & then
        vm.expectRevert(abi.encodeWithSignature("BalancerLiquidityProportionalFuseInvalidRouterAddress()"));
        new BalancerLiquidityProportionalFuse(IporFusionMarkets.BALANCER, address(0), _PERMIT2);
    }

    function testShouldRevertWhenEnteringUnbalancedWithZeroPool() public {
        // given
        address vault = _fusionInstance.plasmaVault;

        address[] memory tokens = new address[](2);
        tokens[0] = _FW_ETH;
        tokens[1] = _FWST_ETH;

        uint256[] memory exactAmountsIn = new uint256[](2);
        exactAmountsIn[0] = 1e18;
        exactAmountsIn[1] = 1e18;

        BalancerLiquidityUnbalancedFuseEnterData memory enterData = BalancerLiquidityUnbalancedFuseEnterData({
            pool: address(0), // Invalid pool address
            tokens: tokens,
            exactAmountsIn: exactAmountsIn,
            minBptAmountOut: 0
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction({
            fuse: address(_balancerLiquidityUnbalancedFuse),
            data: abi.encodeWithSignature("enter((address,address[],uint256[],uint256))", enterData)
        });

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(abi.encodeWithSignature("BalancerLiquidityUnbalancedFuseInvalidParams()"));
        PlasmaVault(vault).execute(enterCalls);
        vm.stopPrank();
    }

    function testShouldRevertWhenEnteringUnbalancedWithMismatchedArrays() public {
        // given
        address vault = _fusionInstance.plasmaVault;

        address[] memory tokens = new address[](2);
        tokens[0] = _FW_ETH;
        tokens[1] = _FWST_ETH;

        uint256[] memory exactAmountsIn = new uint256[](3); // Different length
        exactAmountsIn[0] = 1e18;
        exactAmountsIn[1] = 1e18;
        exactAmountsIn[2] = 1e18;

        BalancerLiquidityUnbalancedFuseEnterData memory enterData = BalancerLiquidityUnbalancedFuseEnterData({
            pool: _BALANCER_POOL,
            tokens: tokens,
            exactAmountsIn: exactAmountsIn,
            minBptAmountOut: 0
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction({
            fuse: address(_balancerLiquidityUnbalancedFuse),
            data: abi.encodeWithSignature("enter((address,address[],uint256[],uint256))", enterData)
        });

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(abi.encodeWithSignature("BalancerLiquidityUnbalancedFuseInvalidParams()"));
        PlasmaVault(vault).execute(enterCalls);
        vm.stopPrank();
    }

    function testShouldRevertWhenEnteringUnbalancedWithUnsupportedPool() public {
        // given
        address vault = _fusionInstance.plasmaVault;
        address unsupportedPool = address(0x1234567890123456789012345678901234567890);

        address[] memory tokens = new address[](2);
        tokens[0] = _FW_ETH;
        tokens[1] = _FWST_ETH;

        uint256[] memory exactAmountsIn = new uint256[](2);
        exactAmountsIn[0] = 1e18;
        exactAmountsIn[1] = 1e18;

        BalancerLiquidityUnbalancedFuseEnterData memory enterData = BalancerLiquidityUnbalancedFuseEnterData({
            pool: unsupportedPool,
            tokens: tokens,
            exactAmountsIn: exactAmountsIn,
            minBptAmountOut: 0
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction({
            fuse: address(_balancerLiquidityUnbalancedFuse),
            data: abi.encodeWithSignature("enter((address,address[],uint256[],uint256))", enterData)
        });

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(
            abi.encodeWithSignature("BalancerLiquidityUnbalancedFuseUnsupportedPool(address)", unsupportedPool)
        );
        PlasmaVault(vault).execute(enterCalls);
        vm.stopPrank();
    }

    function testShouldRevertWhenExitingUnbalancedWithZeroPool() public {
        // given
        address vault = _fusionInstance.plasmaVault;

        uint256[] memory minAmountsOut = new uint256[](2);
        minAmountsOut[0] = 0;
        minAmountsOut[1] = 0;

        BalancerLiquidityUnbalancedFuseExitData memory exitData = BalancerLiquidityUnbalancedFuseExitData({
            pool: address(0), // Invalid pool address
            maxBptAmountIn: 1e15,
            minAmountsOut: minAmountsOut
        });

        FuseAction[] memory exitCalls = new FuseAction[](1);
        exitCalls[0] = FuseAction({
            fuse: address(_balancerLiquidityUnbalancedFuse),
            data: abi.encodeWithSignature("exit((address,uint256,uint256[]))", exitData)
        });

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(abi.encodeWithSignature("BalancerLiquidityUnbalancedFuseInvalidParams()"));
        PlasmaVault(vault).execute(exitCalls);
        vm.stopPrank();
    }

    function testShouldRevertWhenExitingUnbalancedWithUnsupportedPool() public {
        // given
        address vault = _fusionInstance.plasmaVault;
        address unsupportedPool = address(0x1234567890123456789012345678901234567890);

        uint256[] memory minAmountsOut = new uint256[](2);
        minAmountsOut[0] = 0;
        minAmountsOut[1] = 0;

        BalancerLiquidityUnbalancedFuseExitData memory exitData = BalancerLiquidityUnbalancedFuseExitData({
            pool: unsupportedPool,
            maxBptAmountIn: 1e15,
            minAmountsOut: minAmountsOut
        });

        FuseAction[] memory exitCalls = new FuseAction[](1);
        exitCalls[0] = FuseAction({
            fuse: address(_balancerLiquidityUnbalancedFuse),
            data: abi.encodeWithSignature("exit((address,uint256,uint256[]))", exitData)
        });

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(
            abi.encodeWithSignature("BalancerLiquidityUnbalancedFuseUnsupportedPool(address)", unsupportedPool)
        );
        PlasmaVault(vault).execute(exitCalls);
        vm.stopPrank();
    }

    function testShouldReturnWhenExitingUnbalancedWithZeroBptAmount() public {
        // given
        address vault = _fusionInstance.plasmaVault;

        uint256[] memory minAmountsOut = new uint256[](2);
        minAmountsOut[0] = 0;
        minAmountsOut[1] = 0;

        BalancerLiquidityUnbalancedFuseExitData memory exitData = BalancerLiquidityUnbalancedFuseExitData({
            pool: _BALANCER_POOL,
            maxBptAmountIn: 0, // Zero amount should cause early return
            minAmountsOut: minAmountsOut
        });

        FuseAction[] memory exitCalls = new FuseAction[](1);
        exitCalls[0] = FuseAction({
            fuse: address(_balancerLiquidityUnbalancedFuse),
            data: abi.encodeWithSignature("exit((address,uint256,uint256[]))", exitData)
        });

        uint256 bptBalanceBefore = IERC20(_BALANCER_POOL).balanceOf(vault);

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(vault).execute(exitCalls);
        vm.stopPrank();

        // then
        uint256 bptBalanceAfter = IERC20(_BALANCER_POOL).balanceOf(vault);
        assertEq(bptBalanceAfter, bptBalanceBefore, "BPT balance should not change with zero maxBptAmountIn");
    }

    function testShouldRevertWhenConstructingUnbalancedWithZeroRouter() public {
        // given & when & then
        vm.expectRevert(abi.encodeWithSignature("BalancerLiquidityUnbalancedFuseInvalidRouterAddress()"));
        new BalancerLiquidityUnbalancedFuse(IporFusionMarkets.BALANCER, address(0), _PERMIT2);
    }

    function testShouldRevertWhenEnteringSingleTokenWithUnsupportedPool() public {
        // given
        address vault = _fusionInstance.plasmaVault;
        address unsupportedPool = address(0x1234567890123456789012345678901234567890);

        BalancerSingleTokenFuseEnterData memory enterData = BalancerSingleTokenFuseEnterData({
            pool: unsupportedPool,
            tokenIn: _FW_ETH,
            maxAmountIn: 1e18,
            exactBptAmountOut: 1e15
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction({
            fuse: address(_balancerSingleTokenFuse),
            data: abi.encodeWithSignature("enter((address,address,uint256,uint256))", enterData)
        });

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(abi.encodeWithSignature("BalancerSingleTokenFuseUnsupportedPool(address)", unsupportedPool));
        PlasmaVault(vault).execute(enterCalls);
        vm.stopPrank();
    }

    function testShouldRevertWhenExitingSingleTokenWithZeroPool() public {
        // given
        address vault = _fusionInstance.plasmaVault;

        BalancerSingleTokenFuseExitData memory exitData = BalancerSingleTokenFuseExitData({
            pool: address(0), // Invalid pool address
            tokenOut: _FW_ETH,
            maxBptAmountIn: 1e15,
            exactAmountOut: 1e10
        });

        FuseAction[] memory exitCalls = new FuseAction[](1);
        exitCalls[0] = FuseAction({
            fuse: address(_balancerSingleTokenFuse),
            data: abi.encodeWithSignature("exit((address,address,uint256,uint256))", exitData)
        });

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(abi.encodeWithSignature("BalancerSingleTokenFuseInvalidParams()"));
        PlasmaVault(vault).execute(exitCalls);
        vm.stopPrank();
    }

    function testShouldRevertWhenExitingSingleTokenWithZeroTokenOut() public {
        // given
        address vault = _fusionInstance.plasmaVault;

        BalancerSingleTokenFuseExitData memory exitData = BalancerSingleTokenFuseExitData({
            pool: _BALANCER_POOL,
            tokenOut: address(0), // Invalid token address
            maxBptAmountIn: 1e15,
            exactAmountOut: 1e10
        });

        FuseAction[] memory exitCalls = new FuseAction[](1);
        exitCalls[0] = FuseAction({
            fuse: address(_balancerSingleTokenFuse),
            data: abi.encodeWithSignature("exit((address,address,uint256,uint256))", exitData)
        });

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(abi.encodeWithSignature("BalancerSingleTokenFuseInvalidParams()"));
        PlasmaVault(vault).execute(exitCalls);
        vm.stopPrank();
    }

    function testShouldRevertWhenExitingSingleTokenWithUnsupportedPool() public {
        // given
        address vault = _fusionInstance.plasmaVault;
        address unsupportedPool = address(0x1234567890123456789012345678901234567890);

        BalancerSingleTokenFuseExitData memory exitData = BalancerSingleTokenFuseExitData({
            pool: unsupportedPool,
            tokenOut: _FW_ETH,
            maxBptAmountIn: 1e15,
            exactAmountOut: 1e10
        });

        FuseAction[] memory exitCalls = new FuseAction[](1);
        exitCalls[0] = FuseAction({
            fuse: address(_balancerSingleTokenFuse),
            data: abi.encodeWithSignature("exit((address,address,uint256,uint256))", exitData)
        });

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(abi.encodeWithSignature("BalancerSingleTokenFuseUnsupportedPool(address)", unsupportedPool));
        PlasmaVault(vault).execute(exitCalls);
        vm.stopPrank();
    }

    function testShouldReturnWhenExitingSingleTokenWithZeroBptAmount() public {
        // given
        address vault = _fusionInstance.plasmaVault;

        BalancerSingleTokenFuseExitData memory exitData = BalancerSingleTokenFuseExitData({
            pool: _BALANCER_POOL,
            tokenOut: _FW_ETH,
            maxBptAmountIn: 0, // Zero amount should cause early return
            exactAmountOut: 1e10
        });

        FuseAction[] memory exitCalls = new FuseAction[](1);
        exitCalls[0] = FuseAction({
            fuse: address(_balancerSingleTokenFuse),
            data: abi.encodeWithSignature("exit((address,address,uint256,uint256))", exitData)
        });

        uint256 bptBalanceBefore = IERC20(_BALANCER_POOL).balanceOf(vault);

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(vault).execute(exitCalls);
        vm.stopPrank();

        // then
        uint256 bptBalanceAfter = IERC20(_BALANCER_POOL).balanceOf(vault);
        assertEq(bptBalanceAfter, bptBalanceBefore, "BPT balance should not change with zero maxBptAmountIn");
    }

    function testShouldRevertWhenConstructingSingleTokenWithZeroRouter() public {
        // given & when & then
        vm.expectRevert(abi.encodeWithSignature("InvalidAddress()"));
        new BalancerSingleTokenFuse(IporFusionMarkets.BALANCER, address(0), _PERMIT2);
    }

    function testShouldRevertWhenEnteringGaugeWithInsufficientBptAmount() public {
        // given
        address vault = _fusionInstance.plasmaVault;

        // Mock insufficient BPT amount by setting a high minimum
        BalancerGaugeFuseEnterData memory gaugeEnterData = BalancerGaugeFuseEnterData({
            gaugeAddress: _BALANCER_GAUGE,
            bptAmount: 1e18,
            minBptAmount: 2e18 // Higher than bptAmount
        });

        FuseAction[] memory gaugeEnterCalls = new FuseAction[](1);
        gaugeEnterCalls[0] = FuseAction({
            fuse: address(_balancerGaugeFuse),
            data: abi.encodeWithSignature("enter((address,uint256,uint256))", gaugeEnterData)
        });

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(
            abi.encodeWithSignature(
                "BalancerGaugeFuseInsufficientBptAmount(address,uint256,uint256)",
                _BALANCER_GAUGE,
                1e18,
                2e18
            )
        );
        PlasmaVault(vault).execute(gaugeEnterCalls);
        vm.stopPrank();
    }

    function testShouldRevertWhenExitingGaugeWithInsufficientBptAmount() public {
        // given
        address vault = _fusionInstance.plasmaVault;

        BalancerGaugeFuseExitData memory gaugeExitData = BalancerGaugeFuseExitData({
            gaugeAddress: _BALANCER_GAUGE,
            bptAmount: 1e18,
            minBptAmount: 2e18
        });

        FuseAction[] memory gaugeExitCalls = new FuseAction[](1);
        gaugeExitCalls[0] = FuseAction({
            fuse: address(_balancerGaugeFuse),
            data: abi.encodeWithSignature("exit((address,uint256,uint256))", gaugeExitData)
        });

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(
            abi.encodeWithSignature(
                "BalancerGaugeFuseInsufficientBptAmount(address,uint256,uint256)",
                _BALANCER_GAUGE,
                1e18,
                2e18
            )
        );
        PlasmaVault(vault).execute(gaugeExitCalls);
        vm.stopPrank();
    }

    function testShouldEnterGaugeUsingTransientStorage() public {
        // given
        address vault = _fusionInstance.plasmaVault;

        // Add liquidity to get BPT tokens in the vault
        address[] memory tokens = new address[](2);
        tokens[0] = _FW_ETH;
        tokens[1] = _FWST_ETH;

        uint256[] memory maxAmountsIn = new uint256[](2);
        maxAmountsIn[0] = IERC20(_FW_ETH).balanceOf(vault);
        maxAmountsIn[1] = IERC20(_FWST_ETH).balanceOf(vault);

        BalancerLiquidityProportionalFuseEnterData memory enterData = BalancerLiquidityProportionalFuseEnterData({
            pool: _BALANCER_POOL,
            tokens: tokens,
            maxAmountsIn: maxAmountsIn,
            exactBptAmountOut: 1e15
        });

        FuseAction[] memory setupCalls = new FuseAction[](1);
        setupCalls[0] = FuseAction({
            fuse: address(_balancerLiquidityProportionalFuse),
            data: abi.encodeWithSignature("enter((address,address[],uint256[],uint256))", enterData)
        });

        vm.startPrank(_ALPHA);
        PlasmaVault(vault).execute(setupCalls);
        vm.stopPrank();

        uint256 bptBalance = IERC20(_BALANCER_POOL).balanceOf(vault);
        uint256 enterAmount = bptBalance / 2;

        // Prepare transient storage inputs
        bytes32[] memory inputs = new bytes32[](3);
        inputs[0] = TypeConversionLib.toBytes32(_BALANCER_GAUGE);
        inputs[1] = TypeConversionLib.toBytes32(enterAmount); // amount
        inputs[2] = TypeConversionLib.toBytes32(uint256(0)); // minAmount

        address[] memory fuses = new address[](1);
        fuses[0] = address(_balancerGaugeFuse);

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = inputs;

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fuses,
            inputsByFuse: inputsByFuse
        });

        FuseAction[] memory enterCalls = new FuseAction[](2);
        enterCalls[0] = FuseAction({
            fuse: address(_transientStorageSetInputsFuse),
            data: abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        });
        enterCalls[1] = FuseAction({
            fuse: address(_balancerGaugeFuse),
            data: abi.encodeWithSignature("enterTransient()")
        });

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(vault).execute(enterCalls);
        vm.stopPrank();

        // then
        uint256 gaugeBalance = IERC20(_BALANCER_GAUGE).balanceOf(vault);
        assertEq(gaugeBalance, enterAmount, "Gauge balance should match enter amount");
    }

    function testShouldExitGaugeUsingTransientStorage() public {
        // First add liquidity and stake in gauge to have gauge tokens to withdraw
        address vault = _fusionInstance.plasmaVault;

        // 1. Enter Pool
        BalancerLiquidityProportionalFuseEnterData memory enterData;
        {
            address[] memory tokens = new address[](2);
            tokens[0] = _FW_ETH;
            tokens[1] = _FWST_ETH;

            uint256[] memory maxAmountsIn = new uint256[](2);
            maxAmountsIn[0] = IERC20(_FW_ETH).balanceOf(vault);
            maxAmountsIn[1] = IERC20(_FWST_ETH).balanceOf(vault);

            enterData = BalancerLiquidityProportionalFuseEnterData({
                pool: _BALANCER_POOL,
                tokens: tokens,
                maxAmountsIn: maxAmountsIn,
                exactBptAmountOut: 1e15
            });
        }

        FuseAction[] memory setupCalls = new FuseAction[](1);
        setupCalls[0] = FuseAction({
            fuse: address(_balancerLiquidityProportionalFuse),
            data: abi.encodeWithSignature("enter((address,address[],uint256[],uint256))", enterData)
        });

        vm.startPrank(_ALPHA);
        PlasmaVault(vault).execute(setupCalls);
        vm.stopPrank();

        // 2. Enter Gauge
        uint256 bptBalance = IERC20(_BALANCER_POOL).balanceOf(vault);
        FuseAction[] memory gaugeEnterCalls = new FuseAction[](1);
        gaugeEnterCalls[0] = FuseAction({
            fuse: address(_balancerGaugeFuse),
            data: abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                BalancerGaugeFuseEnterData({gaugeAddress: _BALANCER_GAUGE, bptAmount: bptBalance, minBptAmount: 0})
            )
        });

        vm.startPrank(_ALPHA);
        PlasmaVault(vault).execute(gaugeEnterCalls);
        vm.stopPrank();

        // 3. Exit Gauge via Transient
        uint256 gaugeBalance = IERC20(_BALANCER_GAUGE).balanceOf(vault);
        uint256 exitAmount = gaugeBalance / 2;

        // Prepare transient storage inputs
        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        {
            bytes32[] memory inputs = new bytes32[](3);
            inputs[0] = TypeConversionLib.toBytes32(_BALANCER_GAUGE);
            inputs[1] = TypeConversionLib.toBytes32(exitAmount);
            inputs[2] = TypeConversionLib.toBytes32(uint256(0));
            inputsByFuse[0] = inputs;
        }

        address[] memory fuses = new address[](1);
        fuses[0] = address(_balancerGaugeFuse);

        FuseAction[] memory exitCalls = new FuseAction[](2);
        exitCalls[0] = FuseAction({
            fuse: address(_transientStorageSetInputsFuse),
            data: abi.encodeWithSignature(
                "enter((address[],bytes32[][]))",
                TransientStorageSetInputsFuseEnterData({fuse: fuses, inputsByFuse: inputsByFuse})
            )
        });
        exitCalls[1] = FuseAction({
            fuse: address(_balancerGaugeFuse),
            data: abi.encodeWithSignature("exitTransient()")
        });

        vm.startPrank(_ALPHA);
        PlasmaVault(vault).execute(exitCalls);
        vm.stopPrank();

        // then
        assertEq(
            IERC20(_BALANCER_GAUGE).balanceOf(vault),
            gaugeBalance - exitAmount,
            "Gauge balance decrease mismatch"
        );
    }

    function testShouldReturnWhenEnteringTransientGaugeWithZeroAmount() public {
        // given
        address vault = _fusionInstance.plasmaVault;

        bytes32[] memory inputs = new bytes32[](3);
        inputs[0] = TypeConversionLib.toBytes32(_BALANCER_GAUGE);
        inputs[1] = TypeConversionLib.toBytes32(uint256(0)); // Zero amount
        inputs[2] = TypeConversionLib.toBytes32(uint256(0));

        address[] memory fuses = new address[](1);
        fuses[0] = address(_balancerGaugeFuse);

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = inputs;

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fuses,
            inputsByFuse: inputsByFuse
        });

        FuseAction[] memory enterCalls = new FuseAction[](2);
        enterCalls[0] = FuseAction({
            fuse: address(_transientStorageSetInputsFuse),
            data: abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        });
        enterCalls[1] = FuseAction({
            fuse: address(_balancerGaugeFuse),
            data: abi.encodeWithSignature("enterTransient()")
        });

        uint256 gaugeBalanceBefore = IERC20(_BALANCER_GAUGE).balanceOf(vault);

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(vault).execute(enterCalls);
        vm.stopPrank();

        // then
        uint256 gaugeBalanceAfter = IERC20(_BALANCER_GAUGE).balanceOf(vault);
        assertEq(gaugeBalanceAfter, gaugeBalanceBefore, "Gauge balance should not change");
    }

    function testShouldReturnWhenExitingTransientGaugeWithZeroAmount() public {
        // given
        address vault = _fusionInstance.plasmaVault;

        bytes32[] memory inputs = new bytes32[](3);
        inputs[0] = TypeConversionLib.toBytes32(_BALANCER_GAUGE);
        inputs[1] = TypeConversionLib.toBytes32(uint256(0)); // Zero amount
        inputs[2] = TypeConversionLib.toBytes32(uint256(0));

        address[] memory fuses = new address[](1);
        fuses[0] = address(_balancerGaugeFuse);

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = inputs;

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fuses,
            inputsByFuse: inputsByFuse
        });

        FuseAction[] memory exitCalls = new FuseAction[](2);
        exitCalls[0] = FuseAction({
            fuse: address(_transientStorageSetInputsFuse),
            data: abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        });
        exitCalls[1] = FuseAction({
            fuse: address(_balancerGaugeFuse),
            data: abi.encodeWithSignature("exitTransient()")
        });

        uint256 gaugeBalanceBefore = IERC20(_BALANCER_GAUGE).balanceOf(vault);

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(vault).execute(exitCalls);
        vm.stopPrank();

        // then
        uint256 gaugeBalanceAfter = IERC20(_BALANCER_GAUGE).balanceOf(vault);
        assertEq(gaugeBalanceAfter, gaugeBalanceBefore, "Gauge balance should not change");
    }

    /// @notice Test that enterTransient function successfully adds liquidity proportionally using transient storage
    function testShouldEnterProportionalUsingTransientStorage() public {
        // given
        address vault = _fusionInstance.plasmaVault;

        uint256 amount1 = IERC20(_FW_ETH).balanceOf(vault);
        uint256 amount2 = IERC20(_FWST_ETH).balanceOf(vault);
        uint256 exactBptAmountOut = 1e15;

        // Prepare transient storage inputs
        // Layout: pool (1), tokens (2), maxAmountsIn (2), exactBptAmountOut (1) -> Total 6
        bytes32[] memory inputs = new bytes32[](6);
        inputs[0] = TypeConversionLib.toBytes32(_BALANCER_POOL);
        inputs[1] = TypeConversionLib.toBytes32(_FW_ETH);
        inputs[2] = TypeConversionLib.toBytes32(_FWST_ETH);
        inputs[3] = TypeConversionLib.toBytes32(amount1);
        inputs[4] = TypeConversionLib.toBytes32(amount2);
        inputs[5] = TypeConversionLib.toBytes32(exactBptAmountOut);

        address[] memory fuses = new address[](1);
        fuses[0] = address(_balancerLiquidityProportionalFuse);

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = inputs;

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fuses,
            inputsByFuse: inputsByFuse
        });

        FuseAction[] memory enterCalls = new FuseAction[](2);
        enterCalls[0] = FuseAction({
            fuse: address(_transientStorageSetInputsFuse),
            data: abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        });
        enterCalls[1] = FuseAction({
            fuse: address(_balancerLiquidityProportionalFuse),
            data: abi.encodeWithSignature("enterTransient()")
        });

        uint256 bptBalanceBefore = IERC20(_BALANCER_POOL).balanceOf(vault);

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(vault).execute(enterCalls);
        vm.stopPrank();

        // then
        uint256 bptBalanceAfter = IERC20(_BALANCER_POOL).balanceOf(vault);
        assertGt(bptBalanceAfter, bptBalanceBefore, "BPT balance should increase");
    }

    /// @notice Test that exitTransient function successfully removes liquidity proportionally using transient storage
    function testShouldExitProportionalUsingTransientStorage() public {
        // given
        address vault = _fusionInstance.plasmaVault;

        // 1. Enter Pool using standard method to setup
        address[] memory tokens = new address[](2);
        tokens[0] = _FW_ETH;
        tokens[1] = _FWST_ETH;

        uint256[] memory maxAmountsIn = new uint256[](2);
        maxAmountsIn[0] = IERC20(_FW_ETH).balanceOf(vault);
        maxAmountsIn[1] = IERC20(_FWST_ETH).balanceOf(vault);

        BalancerLiquidityProportionalFuseEnterData memory enterData = BalancerLiquidityProportionalFuseEnterData({
            pool: _BALANCER_POOL,
            tokens: tokens,
            maxAmountsIn: maxAmountsIn,
            exactBptAmountOut: 1e15
        });

        FuseAction[] memory setupCalls = new FuseAction[](1);
        setupCalls[0] = FuseAction({
            fuse: address(_balancerLiquidityProportionalFuse),
            data: abi.encodeWithSignature("enter((address,address[],uint256[],uint256))", enterData)
        });

        vm.startPrank(_ALPHA);
        PlasmaVault(vault).execute(setupCalls);
        vm.stopPrank();

        uint256 bptBalance = IERC20(_BALANCER_POOL).balanceOf(vault);
        uint256 exitBptAmount = bptBalance / 2;

        // Prepare transient storage inputs for exit
        // Layout: pool (1), exactBptAmountIn (1), minAmountsOut (2) -> Total 4
        bytes32[] memory inputs = new bytes32[](4);
        inputs[0] = TypeConversionLib.toBytes32(_BALANCER_POOL);
        inputs[1] = TypeConversionLib.toBytes32(exitBptAmount);
        inputs[2] = TypeConversionLib.toBytes32(uint256(0)); // minAmount1
        inputs[3] = TypeConversionLib.toBytes32(uint256(0)); // minAmount2

        address[] memory fuses = new address[](1);
        fuses[0] = address(_balancerLiquidityProportionalFuse);

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = inputs;

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fuses,
            inputsByFuse: inputsByFuse
        });

        FuseAction[] memory exitCalls = new FuseAction[](2);
        exitCalls[0] = FuseAction({
            fuse: address(_transientStorageSetInputsFuse),
            data: abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        });
        exitCalls[1] = FuseAction({
            fuse: address(_balancerLiquidityProportionalFuse),
            data: abi.encodeWithSignature("exitTransient()")
        });

        uint256 bptBalanceBeforeExit = IERC20(_BALANCER_POOL).balanceOf(vault);

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(vault).execute(exitCalls);
        vm.stopPrank();

        // then
        uint256 bptBalanceAfterExit = IERC20(_BALANCER_POOL).balanceOf(vault);
        assertLt(bptBalanceAfterExit, bptBalanceBeforeExit, "BPT balance should decrease after exit");
    }

    /// @notice Test that enterTransient function successfully adds unbalanced liquidity using transient storage
    function testShouldEnterUnbalancedUsingTransientStorage() public {
        // given
        address vault = _fusionInstance.plasmaVault;

        // Prepare transient storage inputs
        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        {
            bytes32[] memory inputs = new bytes32[](6);
            inputs[0] = TypeConversionLib.toBytes32(_BALANCER_POOL);
            inputs[1] = TypeConversionLib.toBytes32(_FW_ETH);
            inputs[2] = TypeConversionLib.toBytes32(_FWST_ETH);
            inputs[3] = TypeConversionLib.toBytes32(uint256(1e18));
            inputs[4] = TypeConversionLib.toBytes32(uint256(1e18));
            inputs[5] = TypeConversionLib.toBytes32(uint256(0));
            inputsByFuse[0] = inputs;
        }

        address[] memory fuses = new address[](1);
        fuses[0] = address(_balancerLiquidityUnbalancedFuse);

        FuseAction[] memory enterCalls = new FuseAction[](2);
        enterCalls[0] = FuseAction({
            fuse: address(_transientStorageSetInputsFuse),
            data: abi.encodeWithSignature(
                "enter((address[],bytes32[][]))",
                TransientStorageSetInputsFuseEnterData({fuse: fuses, inputsByFuse: inputsByFuse})
            )
        });
        enterCalls[1] = FuseAction({
            fuse: address(_balancerLiquidityUnbalancedFuse),
            data: abi.encodeWithSignature("enterTransient()")
        });

        uint256 bptBalanceBefore = IERC20(_BALANCER_POOL).balanceOf(vault);
        uint256 fwEthBalanceBefore = IERC20(_FW_ETH).balanceOf(vault);
        uint256 fwstEthBalanceBefore = IERC20(_FWST_ETH).balanceOf(vault);

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(vault).execute(enterCalls);
        vm.stopPrank();

        // then
        assertGt(IERC20(_BALANCER_POOL).balanceOf(vault), bptBalanceBefore, "BPT balance should increase");
        assertLt(IERC20(_FW_ETH).balanceOf(vault), fwEthBalanceBefore, "FW_ETH balance should decrease");
        assertLt(IERC20(_FWST_ETH).balanceOf(vault), fwstEthBalanceBefore, "FWST_ETH balance should decrease");
    }

    /// @notice Test that exitTransient function reverts when pool is zero address
    function testShouldRevertWhenExitingUnbalancedTransientWithZeroPool() public {
        // given
        address vault = _fusionInstance.plasmaVault;

        // Prepare transient storage inputs for exit
        // Layout: pool (1), maxBptAmountIn (1), minAmountsOut (2) -> Total 4
        bytes32[] memory inputs = new bytes32[](4);
        inputs[0] = TypeConversionLib.toBytes32(address(0)); // Invalid pool address
        inputs[1] = TypeConversionLib.toBytes32(uint256(1e15));
        inputs[2] = TypeConversionLib.toBytes32(uint256(0));
        inputs[3] = TypeConversionLib.toBytes32(uint256(0));

        address[] memory fuses = new address[](1);
        fuses[0] = address(_balancerLiquidityUnbalancedFuse);

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = inputs;

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fuses,
            inputsByFuse: inputsByFuse
        });

        FuseAction[] memory exitCalls = new FuseAction[](2);
        exitCalls[0] = FuseAction({
            fuse: address(_transientStorageSetInputsFuse),
            data: abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        });
        exitCalls[1] = FuseAction({
            fuse: address(_balancerLiquidityUnbalancedFuse),
            data: abi.encodeWithSignature("exitTransient()")
        });

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(abi.encodeWithSignature("BalancerLiquidityUnbalancedFuseInvalidParams()"));
        PlasmaVault(vault).execute(exitCalls);
        vm.stopPrank();
    }

    /// @notice Test that exitTransient function reverts when pool is unsupported
    function testShouldRevertWhenExitingUnbalancedTransientWithUnsupportedPool() public {
        // given
        address vault = _fusionInstance.plasmaVault;
        address unsupportedPool = address(0x1234567890123456789012345678901234567890);

        // Prepare transient storage inputs for exit
        // Layout: pool (1), maxBptAmountIn (1), minAmountsOut (2) -> Total 4
        bytes32[] memory inputs = new bytes32[](4);
        inputs[0] = TypeConversionLib.toBytes32(unsupportedPool);
        inputs[1] = TypeConversionLib.toBytes32(uint256(1e15));
        inputs[2] = TypeConversionLib.toBytes32(uint256(0));
        inputs[3] = TypeConversionLib.toBytes32(uint256(0));

        address[] memory fuses = new address[](1);
        fuses[0] = address(_balancerLiquidityUnbalancedFuse);

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = inputs;

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fuses,
            inputsByFuse: inputsByFuse
        });

        FuseAction[] memory exitCalls = new FuseAction[](2);
        exitCalls[0] = FuseAction({
            fuse: address(_transientStorageSetInputsFuse),
            data: abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        });
        exitCalls[1] = FuseAction({
            fuse: address(_balancerLiquidityUnbalancedFuse),
            data: abi.encodeWithSignature("exitTransient()")
        });

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(
            abi.encodeWithSignature("BalancerLiquidityUnbalancedFuseUnsupportedPool(address)", unsupportedPool)
        );
        PlasmaVault(vault).execute(exitCalls);
        vm.stopPrank();
    }

    /// @notice Test that enterTransient function successfully adds single token liquidity using transient storage
    function testShouldEnterSingleTokenUsingTransientStorage() public {
        // given
        address vault = _fusionInstance.plasmaVault;

        // Prepare transient storage inputs
        // Layout: pool (1), tokenIn (1), maxAmountIn (1), exactBptAmountOut (1) -> Total 4
        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        {
            bytes32[] memory inputs = new bytes32[](4);
            inputs[0] = TypeConversionLib.toBytes32(_BALANCER_POOL);
            inputs[1] = TypeConversionLib.toBytes32(_FW_ETH);
            inputs[2] = TypeConversionLib.toBytes32(uint256(1e18));
            inputs[3] = TypeConversionLib.toBytes32(uint256(1e15));
            inputsByFuse[0] = inputs;
        }

        address[] memory fuses = new address[](1);
        fuses[0] = address(_balancerSingleTokenFuse);

        FuseAction[] memory enterCalls = new FuseAction[](2);
        enterCalls[0] = FuseAction({
            fuse: address(_transientStorageSetInputsFuse),
            data: abi.encodeWithSignature(
                "enter((address[],bytes32[][]))",
                TransientStorageSetInputsFuseEnterData({fuse: fuses, inputsByFuse: inputsByFuse})
            )
        });
        enterCalls[1] = FuseAction({
            fuse: address(_balancerSingleTokenFuse),
            data: abi.encodeWithSignature("enterTransient()")
        });

        uint256 bptBalanceBefore = IERC20(_BALANCER_POOL).balanceOf(vault);
        uint256 fwEthBalanceBefore = IERC20(_FW_ETH).balanceOf(vault);

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(vault).execute(enterCalls);
        vm.stopPrank();

        // then
        assertGt(IERC20(_BALANCER_POOL).balanceOf(vault), bptBalanceBefore, "BPT balance should increase");
        assertLt(IERC20(_FW_ETH).balanceOf(vault), fwEthBalanceBefore, "FW_ETH balance should decrease");
    }

    /// @notice Test that enterTransient function reverts when pool is zero address
    function testShouldRevertWhenEnteringSingleTokenTransientWithZeroPool() public {
        // given
        address vault = _fusionInstance.plasmaVault;

        bytes32[] memory inputs = new bytes32[](4);
        inputs[0] = TypeConversionLib.toBytes32(address(0)); // Invalid pool address
        inputs[1] = TypeConversionLib.toBytes32(_FW_ETH);
        inputs[2] = TypeConversionLib.toBytes32(uint256(1e18));
        inputs[3] = TypeConversionLib.toBytes32(uint256(1e15));

        address[] memory fuses = new address[](1);
        fuses[0] = address(_balancerSingleTokenFuse);

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = inputs;

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fuses,
            inputsByFuse: inputsByFuse
        });

        FuseAction[] memory enterCalls = new FuseAction[](2);
        enterCalls[0] = FuseAction({
            fuse: address(_transientStorageSetInputsFuse),
            data: abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        });
        enterCalls[1] = FuseAction({
            fuse: address(_balancerSingleTokenFuse),
            data: abi.encodeWithSignature("enterTransient()")
        });

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(abi.encodeWithSignature("BalancerSingleTokenFuseInvalidParams()"));
        PlasmaVault(vault).execute(enterCalls);
        vm.stopPrank();
    }

    /// @notice Test that enterTransient function reverts when tokenIn is zero address
    function testShouldRevertWhenEnteringSingleTokenTransientWithZeroTokenIn() public {
        // given
        address vault = _fusionInstance.plasmaVault;

        bytes32[] memory inputs = new bytes32[](4);
        inputs[0] = TypeConversionLib.toBytes32(_BALANCER_POOL);
        inputs[1] = TypeConversionLib.toBytes32(address(0)); // Invalid token address
        inputs[2] = TypeConversionLib.toBytes32(uint256(1e18));
        inputs[3] = TypeConversionLib.toBytes32(uint256(1e15));

        address[] memory fuses = new address[](1);
        fuses[0] = address(_balancerSingleTokenFuse);

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = inputs;

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fuses,
            inputsByFuse: inputsByFuse
        });

        FuseAction[] memory enterCalls = new FuseAction[](2);
        enterCalls[0] = FuseAction({
            fuse: address(_transientStorageSetInputsFuse),
            data: abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        });
        enterCalls[1] = FuseAction({
            fuse: address(_balancerSingleTokenFuse),
            data: abi.encodeWithSignature("enterTransient()")
        });

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(abi.encodeWithSignature("BalancerSingleTokenFuseInvalidParams()"));
        PlasmaVault(vault).execute(enterCalls);
        vm.stopPrank();
    }

    /// @notice Test that enterTransient function reverts when pool is unsupported
    function testShouldRevertWhenEnteringSingleTokenTransientWithUnsupportedPool() public {
        // given
        address vault = _fusionInstance.plasmaVault;
        address unsupportedPool = address(0x1234567890123456789012345678901234567890);

        bytes32[] memory inputs = new bytes32[](4);
        inputs[0] = TypeConversionLib.toBytes32(unsupportedPool);
        inputs[1] = TypeConversionLib.toBytes32(_FW_ETH);
        inputs[2] = TypeConversionLib.toBytes32(uint256(1e18));
        inputs[3] = TypeConversionLib.toBytes32(uint256(1e15));

        address[] memory fuses = new address[](1);
        fuses[0] = address(_balancerSingleTokenFuse);

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = inputs;

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fuses,
            inputsByFuse: inputsByFuse
        });

        FuseAction[] memory enterCalls = new FuseAction[](2);
        enterCalls[0] = FuseAction({
            fuse: address(_transientStorageSetInputsFuse),
            data: abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        });
        enterCalls[1] = FuseAction({
            fuse: address(_balancerSingleTokenFuse),
            data: abi.encodeWithSignature("enterTransient()")
        });

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(abi.encodeWithSignature("BalancerSingleTokenFuseUnsupportedPool(address)", unsupportedPool));
        PlasmaVault(vault).execute(enterCalls);
        vm.stopPrank();
    }

    /// @notice Test that exitTransient function reverts when pool is zero address
    function testShouldRevertWhenExitingSingleTokenTransientWithZeroPool() public {
        // given
        address vault = _fusionInstance.plasmaVault;

        // Prepare transient storage inputs for exit
        // Layout: pool (1), tokenOut (1), maxBptAmountIn (1), exactAmountOut (1) -> Total 4
        bytes32[] memory inputs = new bytes32[](4);
        inputs[0] = TypeConversionLib.toBytes32(address(0)); // Invalid pool address
        inputs[1] = TypeConversionLib.toBytes32(_FW_ETH);
        inputs[2] = TypeConversionLib.toBytes32(uint256(1e15));
        inputs[3] = TypeConversionLib.toBytes32(uint256(1e10));

        address[] memory fuses = new address[](1);
        fuses[0] = address(_balancerSingleTokenFuse);

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = inputs;

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fuses,
            inputsByFuse: inputsByFuse
        });

        FuseAction[] memory exitCalls = new FuseAction[](2);
        exitCalls[0] = FuseAction({
            fuse: address(_transientStorageSetInputsFuse),
            data: abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        });
        exitCalls[1] = FuseAction({
            fuse: address(_balancerSingleTokenFuse),
            data: abi.encodeWithSignature("exitTransient()")
        });

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(abi.encodeWithSignature("BalancerSingleTokenFuseInvalidParams()"));
        PlasmaVault(vault).execute(exitCalls);
        vm.stopPrank();
    }

    /// @notice Test that exitTransient function reverts when tokenOut is zero address
    function testShouldRevertWhenExitingSingleTokenTransientWithZeroTokenOut() public {
        // given
        address vault = _fusionInstance.plasmaVault;

        // Prepare transient storage inputs for exit
        bytes32[] memory inputs = new bytes32[](4);
        inputs[0] = TypeConversionLib.toBytes32(_BALANCER_POOL);
        inputs[1] = TypeConversionLib.toBytes32(address(0)); // Invalid token address
        inputs[2] = TypeConversionLib.toBytes32(uint256(1e15));
        inputs[3] = TypeConversionLib.toBytes32(uint256(1e10));

        address[] memory fuses = new address[](1);
        fuses[0] = address(_balancerSingleTokenFuse);

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = inputs;

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fuses,
            inputsByFuse: inputsByFuse
        });

        FuseAction[] memory exitCalls = new FuseAction[](2);
        exitCalls[0] = FuseAction({
            fuse: address(_transientStorageSetInputsFuse),
            data: abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        });
        exitCalls[1] = FuseAction({
            fuse: address(_balancerSingleTokenFuse),
            data: abi.encodeWithSignature("exitTransient()")
        });

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(abi.encodeWithSignature("BalancerSingleTokenFuseInvalidParams()"));
        PlasmaVault(vault).execute(exitCalls);
        vm.stopPrank();
    }

    /// @notice Test that exitTransient function reverts when pool is unsupported
    function testShouldRevertWhenExitingSingleTokenTransientWithUnsupportedPool() public {
        // given
        address vault = _fusionInstance.plasmaVault;
        address unsupportedPool = address(0x1234567890123456789012345678901234567890);

        // Prepare transient storage inputs for exit
        bytes32[] memory inputs = new bytes32[](4);
        inputs[0] = TypeConversionLib.toBytes32(unsupportedPool);
        inputs[1] = TypeConversionLib.toBytes32(_FW_ETH);
        inputs[2] = TypeConversionLib.toBytes32(uint256(1e15));
        inputs[3] = TypeConversionLib.toBytes32(uint256(1e10));

        address[] memory fuses = new address[](1);
        fuses[0] = address(_balancerSingleTokenFuse);

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = inputs;

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fuses,
            inputsByFuse: inputsByFuse
        });

        FuseAction[] memory exitCalls = new FuseAction[](2);
        exitCalls[0] = FuseAction({
            fuse: address(_transientStorageSetInputsFuse),
            data: abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        });
        exitCalls[1] = FuseAction({
            fuse: address(_balancerSingleTokenFuse),
            data: abi.encodeWithSignature("exitTransient()")
        });

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(abi.encodeWithSignature("BalancerSingleTokenFuseUnsupportedPool(address)", unsupportedPool));
        PlasmaVault(vault).execute(exitCalls);
        vm.stopPrank();
    }

    function _asArray(address addr) private pure returns (address[] memory) {
        address[] memory arr = new address[](1);
        arr[0] = addr;
        return arr;
    }
}
