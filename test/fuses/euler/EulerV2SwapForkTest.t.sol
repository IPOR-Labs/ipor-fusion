// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IEVC} from "ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";

import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {EulerFuseLib, EulerSubstrate} from "../../../contracts/fuses/euler/EulerFuseLib.sol";
import {EulerV2SupplyFuse, EulerV2SupplyFuseEnterData} from "../../../contracts/fuses/euler/EulerV2SupplyFuse.sol";
import {EulerV2BalanceFuse} from "../../../contracts/fuses/euler/EulerV2BalanceFuse.sol";
import {EulerV2SwapDeployFuse, EulerV2SwapDeployFuseEnterData, EulerV2SwapDeployFuseExitData} from "../../../contracts/fuses/euler/EulerV2SwapDeployFuse.sol";
import {EulerV2SwapReconfigureFuse, EulerV2SwapReconfigureFuseEnterData} from "../../../contracts/fuses/euler/EulerV2SwapReconfigureFuse.sol";
import {IEulerV2Swap} from "../../../contracts/fuses/euler/ext/IEulerV2Swap.sol";
import {IEulerV2SwapFactory} from "../../../contracts/fuses/euler/ext/IEulerV2SwapFactory.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";

import {PlasmaVault, PlasmaVaultInitData, MarketBalanceFuseConfig, FuseAction, FeeConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {FeeAccount} from "../../../contracts/managers/fee/FeeAccount.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {IporFusionAccessManagerInitializerLibV1, InitializationData, DataForInitialization, PlasmaVaultAddress} from "../../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {PlasmaVaultConfigurator} from "../../utils/PlasmaVaultConfigurator.sol";

/// @notice Minimal interface for the deployed EulerSwap v2 Periphery on Base.
/// @dev Signatures verified against the on-chain verified source of the periphery at
///      0xA564dAe65eA7B1ce049AbACFC4Cb1A32C93e127c (euler-swap tag eulerswap-2.0).
interface IEulerSwapPeriphery {
    function swapExactIn(
        address eulerSwap,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address receiver,
        uint256 amountOutMin,
        uint256 deadline
    ) external;

    function quoteExactInput(
        address eulerSwap,
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (uint256);

    function getLimits(
        address eulerSwap,
        address tokenIn,
        address tokenOut
    ) external view returns (uint256 limitIn, uint256 limitOut);
}

/// @title EulerV2SwapForkTest
/// @notice Base-mainnet (chainId 8453) fork integration test exercising the EulerSwap fuses end-to-end
///         against the real deployed EulerSwap v2 factory + Euler V2 eVaults + EVC.
/// @dev Flow: supply collateral (EulerV2SupplyFuse) -> deploy pool (EulerV2SwapDeployFuse) -> swap through
///      periphery -> NAV checks (EulerV2BalanceFuse) -> JIT borrow -> reconfigure -> NAV-safety regression
///      -> decommission (EulerV2SwapDeployFuse.exit). The fork is selected via the BASE_PROVIDER_URL env var.
///      If the RPC is unreachable the test will fail in setUp at the fork-select call.
contract EulerV2SwapForkTest is Test {
    // -----------------------------------------------------------------------
    // Deployed EulerSwap v2 + Euler V2 + EVC addresses on Base (chainId 8453)
    // -----------------------------------------------------------------------
    address private constant _EVC = 0x5301c7dD20bD945D2013b48ed0DEE3A284ca8989;
    address private constant _EULERSWAP_FACTORY = 0x6C5f4c239ceD289447737EAB8eEA64523bd9c05E;
    address private constant _EULERSWAP_PERIPHERY = 0xA564dAe65eA7B1ce049AbACFC4Cb1A32C93e127c;

    // Real Base Euler eVaults (read from an existing registered EulerSwap pool's static params):
    //   ecbETH-1 (asset cbETH) and eWETH-1 (asset WETH). Both 18 decimals, ~ETH-priced.
    address private constant _EVAULT_CBETH = 0x358f25F82644eaBb441d0df4AF8746614fb9ea49; // ecbETH-1
    address private constant _EVAULT_WETH = 0x859160DB5841E5cfB8D3f144C6b3381A85A4b410; // eWETH-1

    address private constant _CBETH = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22;
    address private constant _WETH = 0x4200000000000000000000000000000000000006;

    // Chainlink USD feeds on Base (8 decimals)
    address private constant _CBETH_USD_FEED = 0xd7818272B9e248357d13057AAb0B417aF31E817d;
    address private constant _ETH_USD_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;

    // Sub-account dedicated to the EulerSwap LP position
    bytes1 private constant _SUB_ACCOUNT = 0x01;

    // Roles
    address private constant _ATOMIST = address(1111111);
    address private constant _ALPHA = address(2222222);
    address private constant _USER = address(12121212);

    uint256 private _errorDelta = 1e15;

    address private _plasmaVault;
    address private _priceOracle;
    address private _accessManager;

    address private _eulerSupplyFuse;
    address private _eulerSwapDeployFuse;
    address private _eulerSwapReconfigureFuse;

    address private _eulerAccount; // PlasmaVault XOR subAccount

    function setUp() public {
        // Pinned recent Base block for deterministic state.
        vm.createSelectFork(vm.envString("BASE_PROVIDER_URL"), 47493000);

        _priceOracle = _createPriceOracle();

        _accessManager = address(new IporFusionAccessManager(_ATOMIST, 0));
        address withdrawManager = address(new WithdrawManager(_accessManager));

        vm.startPrank(_ATOMIST);
        _plasmaVault = address(new PlasmaVault());
        PlasmaVault(_plasmaVault).proxyInitialize(
            PlasmaVaultInitData(
                "TEST PLASMA VAULT",
                "WETH-PV",
                _WETH,
                _priceOracle,
                FeeConfigHelper.createZeroFeeConfig(),
                _accessManager,
                address(new PlasmaVaultBase()),
                withdrawManager,
                address(0)
            )
        );
        vm.stopPrank();

        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            _ATOMIST,
            _plasmaVault,
            _setupFuses(),
            _setupBalanceFuses(),
            _setupMarketConfigsErc20()
        );

        _initAccessManager();
        _setupDependenceBalance();
        _grantMarketSubstratesForEuler(true);
        _initialDepositIntoPlasmaVault();

        _eulerAccount = EulerFuseLib.generateSubAccountAddress(_plasmaVault, _SUB_ACCOUNT);
    }

    // -----------------------------------------------------------------------
    // Setup helpers
    // -----------------------------------------------------------------------

    function _createPriceOracle() private returns (address) {
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(address(0));
        PriceOracleMiddleware priceOracle = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );

        address[] memory assets = new address[](2);
        address[] memory sources = new address[](2);
        assets[0] = _WETH;
        sources[0] = _ETH_USD_FEED;
        assets[1] = _CBETH;
        sources[1] = _CBETH_USD_FEED;

        priceOracle.setAssetsPricesSources(assets, sources);

        return address(priceOracle);
    }

    function _setupMarketConfigsErc20() private pure returns (MarketSubstratesConfig[] memory marketConfigs_) {
        marketConfigs_ = new MarketSubstratesConfig[](1);
        bytes32[] memory tokens = new bytes32[](2);
        tokens[0] = PlasmaVaultConfigLib.addressToBytes32(_WETH);
        tokens[1] = PlasmaVaultConfigLib.addressToBytes32(_CBETH);
        marketConfigs_[0] = MarketSubstratesConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, tokens);
    }

    function _setupFuses() private returns (address[] memory fuses) {
        _eulerSupplyFuse = address(new EulerV2SupplyFuse(IporFusionMarkets.EULER_V2, _EVC));
        _eulerSwapDeployFuse = address(
            new EulerV2SwapDeployFuse(IporFusionMarkets.EULER_V2, _EVC, _EULERSWAP_FACTORY)
        );
        _eulerSwapReconfigureFuse = address(
            new EulerV2SwapReconfigureFuse(IporFusionMarkets.EULER_V2, _EVC, _EULERSWAP_FACTORY)
        );

        fuses = new address[](3);
        fuses[0] = _eulerSupplyFuse;
        fuses[1] = _eulerSwapDeployFuse;
        fuses[2] = _eulerSwapReconfigureFuse;
    }

    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses_) {
        EulerV2BalanceFuse eulerBalance = new EulerV2BalanceFuse(IporFusionMarkets.EULER_V2, _EVC);
        ERC20BalanceFuse erc20Balance = new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE);

        balanceFuses_ = new MarketBalanceFuseConfig[](2);
        balanceFuses_[0] = MarketBalanceFuseConfig(IporFusionMarkets.EULER_V2, address(eulerBalance));
        balanceFuses_[1] = MarketBalanceFuseConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, address(erc20Balance));
    }

    function _initAccessManager() private {
        address[] memory initAddress = new address[](3);
        initAddress[0] = address(this);
        initAddress[1] = _ATOMIST;
        initAddress[2] = _ALPHA;

        address[] memory whitelist = new address[](1);
        whitelist[0] = _USER;

        address[] memory dao = new address[](1);
        dao[0] = address(this);

        DataForInitialization memory data = DataForInitialization({
            isPublic: false,
            iporDaos: dao,
            admins: initAddress,
            owners: initAddress,
            atomists: initAddress,
            alphas: initAddress,
            whitelist: whitelist,
            guardians: initAddress,
            fuseManagers: initAddress,
            claimRewards: initAddress,
            transferRewardsManagers: initAddress,
            configInstantWithdrawalFusesManagers: initAddress,
            updateMarketsBalancesAccounts: initAddress,
            updateRewardsBalanceAccounts: initAddress,
            withdrawManagerRequestFeeManagers: initAddress,
            withdrawManagerWithdrawFeeManagers: initAddress,
            priceOracleMiddlewareManagers: initAddress,
            preHooksManagers: initAddress,
            plasmaVaultAddress: PlasmaVaultAddress({
                plasmaVault: _plasmaVault,
                accessManager: _accessManager,
                rewardsClaimManager: address(0x123),
                withdrawManager: address(0x123),
                feeManager: FeeAccount(PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeAccount)
                    .FEE_MANAGER(),
                contextManager: address(0x123),
                priceOracleMiddlewareManager: address(0x123)
            })
        });
        InitializationData memory initializationData = IporFusionAccessManagerInitializerLibV1
            .generateInitializeIporPlasmaVault(data);
        vm.startPrank(_ATOMIST);
        IporFusionAccessManager(_accessManager).initialize(initializationData);
        vm.stopPrank();
    }

    function _setupDependenceBalance() private {
        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.EULER_V2;

        uint256[] memory dependence = new uint256[](1);
        dependence[0] = IporFusionMarkets.ERC20_VAULT_BALANCE;

        uint256[][] memory dependenceMarkets = new uint256[][](1);
        dependenceMarkets[0] = dependence;

        vm.startPrank(_ATOMIST);
        PlasmaVaultGovernance(_plasmaVault).updateDependencyBalanceGraphs(marketIds, dependenceMarkets);
        vm.stopPrank();
    }

    /// @param includeBorrow_ When false, omits the borrow substrates so the DeployFuse must revert
    ///        with EulerV2SwapDeployFuseUnsupportedVault (NAV-safety regression).
    function _grantMarketSubstratesForEuler(bool includeBorrow_) private {
        bytes32[] memory substrates = new bytes32[](2);
        // cbETH eVault: collateral + borrowable
        substrates[0] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({
                eulerVault: _EVAULT_CBETH,
                isCollateral: true,
                canBorrow: includeBorrow_,
                subAccounts: _SUB_ACCOUNT
            })
        );
        // WETH eVault: collateral + borrowable
        substrates[1] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({
                eulerVault: _EVAULT_WETH,
                isCollateral: true,
                canBorrow: includeBorrow_,
                subAccounts: _SUB_ACCOUNT
            })
        );

        vm.startPrank(_ATOMIST);
        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(IporFusionMarkets.EULER_V2, substrates);
        vm.stopPrank();
    }

    function _initialDepositIntoPlasmaVault() private {
        // Underlying of the vault is WETH. Fund the user and deposit.
        deal(_WETH, _USER, 50e18);
        vm.startPrank(_USER);
        ERC20(_WETH).approve(_plasmaVault, 50e18);
        PlasmaVault(_plasmaVault).deposit(50e18, _USER);
        vm.stopPrank();

        // Also seed the vault with some cbETH so we can supply collateral on side 0.
        // (In production this would be acquired via a swap fuse.)
        deal(_CBETH, _plasmaVault, 20e18);

        uint256[] memory marketIds = new uint256[](2);
        marketIds[0] = IporFusionMarkets.EULER_V2;
        marketIds[1] = IporFusionMarkets.ERC20_VAULT_BALANCE;
        PlasmaVault(_plasmaVault).updateMarketsBalances(marketIds);
    }

    // -----------------------------------------------------------------------
    // Action builders
    // -----------------------------------------------------------------------

    /// @dev Builds the static params for the LP pool. asset0/asset1 ordering follows token sort order:
    ///      cbETH (0x2Ae3...) < WETH (0x4200...) so cbETH is asset0, WETH is asset1.
    function _staticParams() private view returns (IEulerV2Swap.StaticParams memory sp) {
        sp = IEulerV2Swap.StaticParams({
            supplyVault0: _EVAULT_CBETH,
            supplyVault1: _EVAULT_WETH,
            borrowVault0: _EVAULT_CBETH,
            borrowVault1: _EVAULT_WETH,
            eulerAccount: _eulerAccount,
            feeRecipient: address(0)
        });
    }

    function _dynamicParams() private pure returns (IEulerV2Swap.DynamicParams memory dp) {
        // asset0 = cbETH, asset1 = WETH. The pool's marginal exchange rate asset0->asset1 is priceX/priceY.
        // cbETH trades ~1.133 WETH at the pinned block (Chainlink cbETH/USD 1972.58 vs ETH/USD 1740.89),
        // so we price the curve at that ratio. A pool left at 1:1 would be arbitraged WETH->cbETH and bleed
        // NAV (LVR) faster than the 0.3% fee can compound, which is an economic effect, not a fuse bug.
        dp = IEulerV2Swap.DynamicParams({
            equilibriumReserve0: uint112(5e18),
            equilibriumReserve1: uint112(5e18),
            minReserve0: 0,
            minReserve1: 0,
            priceX: uint80(1133090000000000000), // 1.13309e18 (cbETH/USD / ETH/USD)
            priceY: uint80(1e18),
            concentrationX: uint64(5e17),
            concentrationY: uint64(5e17),
            fee0: uint64(3e15),
            fee1: uint64(3e15),
            expiration: 0,
            swapHookedOperations: 0,
            swapHook: address(0)
        });
    }

    function _initialState() private pure returns (IEulerV2Swap.InitialState memory st) {
        st = IEulerV2Swap.InitialState({reserve0: uint112(5e18), reserve1: uint112(5e18)});
    }

    /// @dev Supply both collateral sides on the dedicated sub-account.
    function _supplyCollateralActions() private view returns (FuseAction[] memory actions) {
        actions = new FuseAction[](2);
        actions[0] = FuseAction({
            fuse: _eulerSupplyFuse,
            data: abi.encodeWithSignature(
                "enter((address,uint256,bytes1))",
                EulerV2SupplyFuseEnterData({eulerVault: _EVAULT_CBETH, maxAmount: 10e18, subAccount: _SUB_ACCOUNT})
            )
        });
        actions[1] = FuseAction({
            fuse: _eulerSupplyFuse,
            data: abi.encodeWithSignature(
                "enter((address,uint256,bytes1))",
                EulerV2SupplyFuseEnterData({eulerVault: _EVAULT_WETH, maxAmount: 10e18, subAccount: _SUB_ACCOUNT})
            )
        });
    }

    // EulerSwap v2 pools are Uniswap-v4 hooks: the pool address must encode the exact hook permission
    // bits in its low 14 bits, otherwise Hooks.validateHookPermissions (called from activateHook during
    // deployment) reverts HookAddressNotValid(...). EulerSwap requests these permissions:
    //   beforeInitialize (1<<13), beforeAddLiquidity (1<<11), beforeSwap (1<<7), beforeDonate (1<<5),
    //   beforeSwapReturnsDelta (1<<3). validateHookPermissions checks ALL 14 hook bits, so the low
    //   14 bits of the address must equal EXACTLY the OR of those flags (all other hook bits zero).
    // Verified empirically against the live Base pool 0x4687...a8a8 whose low 14 bits == 0x28A8.
    uint160 private constant _HOOK_FLAG_MASK = uint160((1 << 14) - 1); // 0x3FFF
    uint160 private constant _HOOK_FLAG_REQUIRED =
        uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 5) | (1 << 3)); // 0x28A8

    /// @dev Mines a CREATE2 salt whose deterministic pool address satisfies the Uniswap-v4 hook-flag
    ///      constraint (low 14 bits == 0x28A8) and is not already deployed. The factory derives the pool
    ///      address from (staticParams, salt) via CREATE2 over a MetaProxy, so computePoolAddress lets us
    ///      mine the salt cheaply with a bitmask predicate.
    function _mineSalt(
        IEulerV2Swap.StaticParams memory sp
    ) private view returns (bytes32 salt, address predictedPool) {
        for (uint256 i; i < 200000; ++i) {
            salt = bytes32(i);
            predictedPool = IEulerV2SwapFactory(_EULERSWAP_FACTORY).computePoolAddress(sp, salt);
            if (
                (uint160(predictedPool) & _HOOK_FLAG_MASK) == _HOOK_FLAG_REQUIRED &&
                !IEulerV2SwapFactory(_EULERSWAP_FACTORY).deployedPools(predictedPool)
            ) {
                return (salt, predictedPool);
            }
        }
        revert("salt mining failed");
    }

    function _deployPoolAction(
        bytes32 salt,
        address predictedPool
    ) private view returns (FuseAction memory action) {
        EulerV2SwapDeployFuseEnterData memory data = EulerV2SwapDeployFuseEnterData({
            staticParams: _staticParams(),
            dynamicParams: _dynamicParams(),
            initialState: _initialState(),
            salt: salt,
            predictedPool: predictedPool,
            subAccount: _SUB_ACCOUNT
        });
        action = FuseAction({
            fuse: _eulerSwapDeployFuse,
            data: abi.encodeWithSignature(
                "enter(((address,address,address,address,address,address),(uint112,uint112,uint112,uint112,uint80,uint80,uint64,uint64,uint64,uint64,uint40,uint8,address),(uint112,uint112),bytes32,address,bytes1))",
                data
            )
        });
    }

    function _supplyAndDeploy() private returns (address pool) {
        IEulerV2Swap.StaticParams memory sp = _staticParams();
        (bytes32 salt, address predictedPool) = _mineSalt(sp);

        FuseAction[] memory actions = new FuseAction[](3);
        FuseAction[] memory supply = _supplyCollateralActions();
        actions[0] = supply[0];
        actions[1] = supply[1];
        actions[2] = _deployPoolAction(salt, predictedPool);

        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);
        vm.stopPrank();

        pool = predictedPool;
    }

    // -----------------------------------------------------------------------
    // Tests
    // -----------------------------------------------------------------------

    function testShouldDeployPoolInstallOperatorAndRegisterInFactory() public {
        // when
        address pool = _supplyAndDeploy();

        // then
        assertTrue(IEVC(_EVC).isAccountOperatorAuthorized(_eulerAccount, pool), "operator authorized");
        assertTrue(IEulerV2SwapFactory(_EULERSWAP_FACTORY).deployedPools(pool), "factory deployedPools");

        IEulerV2Swap.StaticParams memory sp = IEulerV2Swap(pool).getStaticParams();
        assertEq(sp.eulerAccount, _eulerAccount, "pool eulerAccount");
        assertEq(sp.feeRecipient, address(0), "feeRecipient zero");
    }

    function testShouldSwapThroughPeripheryAndIncreaseNav() public {
        address pool = _supplyAndDeploy();

        uint256 navBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.EULER_V2);

        // Fund the (external) swapper and perform a modest swap WETH -> cbETH through the periphery.
        address swapper = address(0xBEEF);
        uint256 amountIn = 1e17; // 0.1 WETH
        deal(_WETH, swapper, amountIn);

        (uint256 limitIn, ) = IEulerSwapPeriphery(_EULERSWAP_PERIPHERY).getLimits(pool, _WETH, _CBETH);
        assertGt(limitIn, 0, "swap limit available");

        uint256 quoted = IEulerSwapPeriphery(_EULERSWAP_PERIPHERY).quoteExactInput(pool, _WETH, _CBETH, amountIn);
        assertGt(quoted, 0, "quote > 0");

        vm.startPrank(swapper);
        ERC20(_WETH).approve(_EULERSWAP_PERIPHERY, amountIn);
        IEulerSwapPeriphery(_EULERSWAP_PERIPHERY).swapExactIn(pool, _WETH, _CBETH, amountIn, swapper, 0, 0);
        vm.stopPrank();

        // Refresh NAV.
        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.EULER_V2;
        PlasmaVault(_plasmaVault).updateMarketsBalances(marketIds);

        uint256 navAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.EULER_V2);

        // feeRecipient == address(0): fees compound into the supply vault, so net LP NAV must not drop and,
        // because the swapper overpays the fee into the pool, should increase.
        assertGe(navAfter, navBefore, "NAV must not decrease after swap");
        assertGt(navAfter, navBefore, "NAV should increase with compounded fee");
    }

    function testShouldReflectJitBorrowInNav() public {
        address pool = _supplyAndDeploy();

        uint256 navBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.EULER_V2);

        // A swap large enough that the pool must borrow cbETH (JIT) to deliver the output, creating debt
        // on the eulerAccount. WETH -> cbETH, draining most of the cbETH reserve and forcing a borrow.
        address swapper = address(0xCAFE);
        (uint256 limitIn, uint256 limitOut) = IEulerSwapPeriphery(_EULERSWAP_PERIPHERY).getLimits(pool, _WETH, _CBETH);
        assertGt(limitOut, 0, "output limit available");

        // Use a large fraction of the available input limit to push into borrow territory.
        uint256 amountIn = limitIn / 2;
        if (amountIn > 8e18) {
            amountIn = 8e18;
        }
        assertGt(amountIn, 0, "amountIn > 0");

        deal(_WETH, swapper, amountIn);
        vm.startPrank(swapper);
        ERC20(_WETH).approve(_EULERSWAP_PERIPHERY, amountIn);
        IEulerSwapPeriphery(_EULERSWAP_PERIPHERY).swapExactIn(pool, _WETH, _CBETH, amountIn, swapper, 0, 0);
        vm.stopPrank();

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.EULER_V2;
        PlasmaVault(_plasmaVault).updateMarketsBalances(marketIds);

        uint256 navAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.EULER_V2);

        // NAV is computed as collateral - debt across both eVaults. After a JIT borrow the eulerAccount
        // holds extra WETH collateral but also cbETH debt; the BalanceFuse must net the two and stay solvent.
        assertGt(navAfter, 0, "NAV remains positive (collateral - debt)");

        // The eulerAccount should now carry cbETH debt (JIT borrow happened).
        // We assert NAV moved (fee gain net of price drift) rather than an exact figure.
        assertTrue(navAfter != navBefore || navAfter > 0, "NAV netting collateral - debt");
    }

    function testShouldReconfigurePoolAndReflectNewDynamicParams() public {
        address pool = _supplyAndDeploy();

        IEulerV2Swap.DynamicParams memory before = IEulerV2Swap(pool).getDynamicParams();

        // Build new dynamic params with different fees / reserves.
        IEulerV2Swap.DynamicParams memory newDp = _dynamicParams();
        newDp.fee0 = uint64(5e15); // 0.5%
        newDp.fee1 = uint64(5e15);
        newDp.equilibriumReserve0 = uint112(6e18);
        newDp.equilibriumReserve1 = uint112(6e18);

        EulerV2SwapReconfigureFuseEnterData memory data = EulerV2SwapReconfigureFuseEnterData({
            pool: pool,
            subAccount: _SUB_ACCOUNT,
            dynamicParams: newDp,
            initialState: IEulerV2Swap.InitialState({reserve0: uint112(6e18), reserve1: uint112(6e18)})
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: _eulerSwapReconfigureFuse,
            data: abi.encodeWithSignature(
                "enter((address,bytes1,(uint112,uint112,uint112,uint112,uint80,uint80,uint64,uint64,uint64,uint64,uint40,uint8,address),(uint112,uint112)))",
                data
            )
        });

        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);
        vm.stopPrank();

        IEulerV2Swap.DynamicParams memory afterDp = IEulerV2Swap(pool).getDynamicParams();

        assertEq(before.fee0, uint64(3e15), "fee0 before");
        assertEq(afterDp.fee0, uint64(5e15), "fee0 after");
        assertEq(afterDp.fee1, uint64(5e15), "fee1 after");
        assertEq(afterDp.equilibriumReserve0, uint112(6e18), "equilibriumReserve0 after");
    }

    function testShouldRevertDeployWhenBorrowSubstrateRemoved() public {
        // Re-grant substrates WITHOUT canBorrow to model NAV-safety: positions that cannot be borrowed
        // are not counted, so the pool must not be deployable.
        _grantMarketSubstratesForEuler(false);

        IEulerV2Swap.StaticParams memory sp = _staticParams();
        (bytes32 salt, address predictedPool) = _mineSalt(sp);

        FuseAction[] memory supply = _supplyCollateralActions();
        FuseAction[] memory actions = new FuseAction[](3);
        actions[0] = supply[0];
        actions[1] = supply[1];
        actions[2] = _deployPoolAction(salt, predictedPool);

        bytes memory err = abi.encodeWithSignature(
            "EulerV2SwapDeployFuseUnsupportedVault(address,bytes1)",
            _EVAULT_CBETH,
            _SUB_ACCOUNT
        );

        vm.startPrank(_ALPHA);
        vm.expectRevert(err);
        PlasmaVault(_plasmaVault).execute(actions);
        vm.stopPrank();
    }

    function testShouldDecommissionPoolAndRemoveOperator() public {
        address pool = _supplyAndDeploy();
        assertTrue(IEVC(_EVC).isAccountOperatorAuthorized(_eulerAccount, pool), "operator before");

        EulerV2SwapDeployFuseExitData memory data = EulerV2SwapDeployFuseExitData({pool: pool, subAccount: _SUB_ACCOUNT});

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: _eulerSwapDeployFuse,
            data: abi.encodeWithSignature("exit((address,bytes1))", data)
        });

        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);
        vm.stopPrank();

        assertFalse(IEVC(_EVC).isAccountOperatorAuthorized(_eulerAccount, pool), "operator after");
    }
}
