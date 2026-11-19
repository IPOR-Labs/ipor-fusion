// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IEVC} from "ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";

import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig} from "../../contracts/vaults/PlasmaVault.sol";
import {EulerFuseLib, EulerSubstrate} from "../../contracts/fuses/euler/EulerFuseLib.sol";
import {EulerV2SupplyFuse, EulerV2SupplyFuseEnterData} from "../../contracts/fuses/euler/EulerV2SupplyFuse.sol";
import {EulerV2BalanceFuse} from "../../contracts/fuses/euler/EulerV2BalanceFuse.sol";
import {
    EulerV2SwapDeployFuse,
    EulerV2SwapDeployFuseEnterData,
    EulerV2SwapDeployFuseExitData
} from "../../contracts/fuses/euler/EulerV2SwapDeployFuse.sol";
import {
    EulerV2SwapReconfigureFuse,
    EulerV2SwapReconfigureFuseEnterData
} from "../../contracts/fuses/euler/EulerV2SwapReconfigureFuse.sol";
import {IBorrowing} from "../../contracts/fuses/euler/ext/IBorrowing.sol";
import {IEulerV2Swap} from "../../contracts/fuses/euler/ext/IEulerV2Swap.sol";
import {IEulerV2SwapFactory} from "../../contracts/fuses/euler/ext/IEulerV2SwapFactory.sol";
import {EulerV2SwapCurveLib} from "../../contracts/fuses/euler/EulerV2SwapCurveLib.sol";
import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultConfigLib} from "../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {ERC20BalanceFuse} from "../../contracts/fuses/erc20/Erc20BalanceFuse.sol";

import {
    PlasmaVault,
    PlasmaVaultInitData,
    MarketBalanceFuseConfig,
    FuseAction,
    FeeConfig
} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {FeeAccount} from "../../contracts/managers/fee/FeeAccount.sol";
import {FeeConfigHelper} from "../test_helpers/FeeConfigHelper.sol";
import {
    IporFusionAccessManagerInitializerLibV1,
    InitializationData,
    DataForInitialization,
    PlasmaVaultAddress
} from "../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {PlasmaVaultConfigurator} from "../utils/PlasmaVaultConfigurator.sol";
import {PlasmaVaultCloneLib} from "../test_helpers/PlasmaVaultCloneLib.sol";
import {UpdateBalancesPreHook} from "../../contracts/handlers/pre_hooks/pre_hooks/UpdateBalancesPreHook.sol";
import {UpdateBalancesExcludeMarketsPreHook} from "../../contracts/handlers/pre_hooks/pre_hooks/UpdateBalancesExcludeMarketsPreHook.sol";

/// @notice Minimal interface for the deployed EulerSwap v2 Periphery on Base.
/// @dev Signatures verified against the on-chain verified source of the periphery at
///      0xA564dAe65eA7B1ce049AbACFC4Cb1A32C93e127c (euler-swap tag eulerswap-2.0).
interface IEulerSwapPeripheryHookFork {
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

/// @title UpdateBalancesExcludeMarketsPreHookForkTest
/// @notice IL-9609 (T74, fork): UpdateBalancesExcludeMarketsPreHook on a vault with a real EulerSwap pool (Base fork).
/// @dev Setup copied from EulerV2SwapForkTest (Base block 47493000, dependency graph EULER_V2 (11) -> ERC20_VAULT_BALANCE (7),
///      both markets active). A real periphery swap moves the value of market 11 and a cbETH donation to the vault moves
///      market 7, both without a booked refresh. A user deposit and redeem then runs either the exclusion hook (market 11
///      excluded) or, as the control, UpdateBalancesPreHook. Expected values are taken from the vault itself
///      (`previewDeposit` / `previewRedeem` after a snapshot-scoped refresh of exactly the markets the hook must refresh).
contract UpdateBalancesExcludeMarketsPreHookForkTest is Test {
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

    // Curve pricing guard (IL-8039): max deviation of priceX/priceY from the oracle ratio.
    // The fixture's priceX = 1.13309e18 is ~0.097% off the block's oracle ratio (see _dynamicParams()),
    // so 1% comfortably covers it while still rejecting the off-market probes below.
    uint256 private constant _PRICE_DEVIATION_WAD = 1e16;

    // Roles
    address private constant _ATOMIST = address(1111111);
    address private constant _ALPHA = address(2222222);
    address private constant _USER = address(12121212);

    uint256 private _errorDelta = 1e15;

    address private _plasmaVault;
    address private _priceOracle;
    address private _accessManager;
    address private _withdrawManager;

    address private _eulerSupplyFuse;
    address private _eulerSwapDeployFuse;
    address private _eulerSwapReconfigureFuse;

    address private _eulerAccount; // PlasmaVault XOR subAccount

    function setUp() public {
        // Pinned recent Base block for deterministic state.
        vm.createSelectFork(vm.envString("BASE_PROVIDER_URL"), 47493000);

        _priceOracle = _createPriceOracle();

        _accessManager = address(new IporFusionAccessManager(_ATOMIST, 0));
        _withdrawManager = address(new WithdrawManager(_accessManager));
        address withdrawManager = _withdrawManager;

        vm.startPrank(_ATOMIST);
        _plasmaVault = address(PlasmaVaultCloneLib.newPlasmaVault());
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
            new EulerV2SwapDeployFuse(IporFusionMarkets.EULER_V2, _EVC, _EULERSWAP_FACTORY, _PRICE_DEVIATION_WAD)
        );
        _eulerSwapReconfigureFuse = address(
            new EulerV2SwapReconfigureFuse(IporFusionMarkets.EULER_V2, _EVC, _EULERSWAP_FACTORY, _PRICE_DEVIATION_WAD)
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
                withdrawManager: _withdrawManager,
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
        _grantMarketSubstratesForEuler(includeBorrow_, true);
    }

    function _grantMarketSubstratesForEuler(bool includeBorrow_, bool isCollateral_) private {
        bytes32[] memory substrates = new bytes32[](2);
        // cbETH eVault: collateral + borrowable
        substrates[0] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({
                eulerVault: _EVAULT_CBETH,
                isCollateral: isCollateral_,
                canBorrow: includeBorrow_,
                subAccounts: _SUB_ACCOUNT
            })
        );
        // WETH eVault: collateral + borrowable
        substrates[1] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({
                eulerVault: _EVAULT_WETH,
                isCollateral: isCollateral_,
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
        // cbETH trades ~1.132 WETH at the pinned block (Chainlink cbETH/USD 1975.23874403 vs
        // ETH/USD 1744.92130639, ratio 1.131993; curve priceX/priceY here is ~0.097% off that ratio,
        // comfortably inside the 1% PRICE_DEVIATION_WAD used by this fork test, see IL-8039),
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
    uint160 private constant _HOOK_FLAG_REQUIRED = uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 5) | (1 << 3)); // 0x28A8

    /// @dev Mines a CREATE2 salt whose deterministic pool address satisfies the Uniswap-v4 hook-flag
    ///      constraint (low 14 bits == 0x28A8) and is not already deployed. The factory derives the pool
    ///      address from (staticParams, salt) via CREATE2 over a MetaProxy, so computePoolAddress lets us
    ///      mine the salt cheaply with a bitmask predicate.
    function _mineSalt(IEulerV2Swap.StaticParams memory sp) private view returns (bytes32 salt, address predictedPool) {
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

    function _deployPoolAction(bytes32 salt, address predictedPool) private view returns (FuseAction memory action) {
        action = _deployPoolAction(salt, predictedPool, _dynamicParams(), _initialState());
    }

    /// @dev Overload allowing the curve pricing guard tests to inject an off-market/off-equilibrium
    ///      dynamicParams/initialState while keeping the rest of the fixture (staticParams, salt mining)
    ///      unchanged.
    function _deployPoolAction(
        bytes32 salt,
        address predictedPool,
        IEulerV2Swap.DynamicParams memory dynamicParams,
        IEulerV2Swap.InitialState memory initialState
    ) private view returns (FuseAction memory action) {
        action = _deployPoolActionWithStaticParams(_staticParams(), salt, predictedPool, dynamicParams, initialState);
    }

    function _deployPoolActionWithStaticParams(
        IEulerV2Swap.StaticParams memory sp,
        bytes32 salt,
        address predictedPool
    ) private view returns (FuseAction memory action) {
        action = _deployPoolActionWithStaticParams(sp, salt, predictedPool, _dynamicParams(), _initialState());
    }

    function _deployPoolActionWithStaticParams(
        IEulerV2Swap.StaticParams memory sp,
        bytes32 salt,
        address predictedPool,
        IEulerV2Swap.DynamicParams memory dynamicParams,
        IEulerV2Swap.InitialState memory initialState
    ) private view returns (FuseAction memory action) {
        EulerV2SwapDeployFuseEnterData memory data = EulerV2SwapDeployFuseEnterData({
            staticParams: sp,
            dynamicParams: dynamicParams,
            initialState: initialState,
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
        _grantPoolEntryForDeploy(predictedPool);

        FuseAction[] memory actions = new FuseAction[](3);
        FuseAction[] memory supply = _supplyCollateralActions();
        actions[0] = supply[0];
        actions[1] = supply[1];
        actions[2] = _deployPoolAction(salt, predictedPool);

        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);
        vm.stopPrank();

        // D-A13: the pool entry is needed only for the deploy; afterwards the market lists the eVault rows alone, the
        // live pool is invisible to the balance fuse and market 11 is valued from the sub-account state as before.
        _grantMarketSubstratesForEuler(true);

        pool = predictedPool;
    }

    /// @dev Grants the eVault rows plus the pool entry (pool, sub-account) that EulerV2SwapDeployFuse.enter requires
    ///      (IL-9706). Substrate grants replace the whole list, so the eVault rows are granted again.
    function _grantPoolEntryForDeploy(address pool_) private {
        bytes32[] memory substrates = new bytes32[](3);
        substrates[0] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: _EVAULT_CBETH, isCollateral: true, canBorrow: true, subAccounts: _SUB_ACCOUNT})
        );
        substrates[1] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: _EVAULT_WETH, isCollateral: true, canBorrow: true, subAccounts: _SUB_ACCOUNT})
        );
        substrates[2] = EulerFuseLib.swapPoolSubstrateToBytes32(pool_, _SUB_ACCOUNT);

        vm.prank(_ATOMIST);
        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(IporFusionMarkets.EULER_V2, substrates);
    }

    // -----------------------------------------------------------------------
    // Scenario helpers
    // -----------------------------------------------------------------------

    uint256 private constant _DEPOSIT = 1e18;

    function _wire(address hook_, bytes32[] memory substrates_) private {
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = PlasmaVault.deposit.selector;
        selectors[1] = PlasmaVault.redeem.selector;
        address[] memory hooks = new address[](2);
        hooks[0] = hook_;
        hooks[1] = hook_;
        bytes32[][] memory substrates = new bytes32[][](2);
        substrates[0] = substrates_;
        substrates[1] = substrates_;
        vm.prank(_ATOMIST);
        PlasmaVaultGovernance(_plasmaVault).setPreHookImplementations(selectors, hooks, substrates);
    }

    function _excludePoolMarket() private pure returns (bytes32[] memory list) {
        list = new bytes32[](1);
        list[0] = bytes32(IporFusionMarkets.EULER_V2);
    }

    function _market(uint256 marketId_) private view returns (uint256) {
        return PlasmaVault(_plasmaVault).totalAssetsInMarket(marketId_);
    }

    /// @dev Real swap through the EulerSwap periphery (moves the pool and the value of market 11) and a cbETH donation
    ///      to the vault (moves market 7). Neither refreshes any cache. Returns the cached values before the moves.
    function _swapAndDonate() private returns (uint256 cached11, uint256 cached7) {
        address pool = _pool;

        uint256[] memory both = new uint256[](2);
        both[0] = IporFusionMarkets.EULER_V2;
        both[1] = IporFusionMarkets.ERC20_VAULT_BALANCE;
        PlasmaVault(_plasmaVault).updateMarketsBalances(both);
        cached11 = _market(IporFusionMarkets.EULER_V2);
        cached7 = _market(IporFusionMarkets.ERC20_VAULT_BALANCE);

        address swapper = address(0xBEEF);
        uint256 amountIn = 2e18;
        deal(_WETH, swapper, amountIn);
        vm.startPrank(swapper);
        ERC20(_WETH).approve(_EULERSWAP_PERIPHERY, amountIn);
        IEulerSwapPeripheryHookFork(_EULERSWAP_PERIPHERY).swapExactIn(pool, _WETH, _CBETH, amountIn, swapper, 0, 0);
        vm.stopPrank();

        deal(_CBETH, _plasmaVault, ERC20(_CBETH).balanceOf(_plasmaVault) + 5e18);

        // The moves are real but not booked: both caches are unchanged.
        assertEq(_market(IporFusionMarkets.EULER_V2), cached11, "swap alone does not refresh market 11");
        assertEq(_market(IporFusionMarkets.ERC20_VAULT_BALANCE), cached7, "donation alone does not refresh market 7");
    }

    address private _pool;

    function _supplyAndDeployStoring() private {
        _pool = _supplyAndDeploy();
    }

    /// @dev Value of market 11 / 7 after a refresh of exactly `markets_`; the state is reverted afterwards.
    function _valueAfterRefresh(uint256[] memory markets_, uint256 marketId_) private returns (uint256 value) {
        uint256 snap = vm.snapshotState();
        PlasmaVault(_plasmaVault).updateMarketsBalances(markets_);
        value = _market(marketId_);
        assertTrue(vm.revertToState(snap));
    }

    function _previewDepositAfterRefresh(uint256[] memory markets_) private returns (uint256 shares) {
        uint256 snap = vm.snapshotState();
        PlasmaVault(_plasmaVault).updateMarketsBalances(markets_);
        shares = PlasmaVault(_plasmaVault).previewDeposit(_DEPOSIT);
        assertTrue(vm.revertToState(snap));
    }

    function _previewRedeemAfterRefresh(uint256[] memory markets_, uint256 shares_) private returns (uint256 assets) {
        uint256 snap = vm.snapshotState();
        PlasmaVault(_plasmaVault).updateMarketsBalances(markets_);
        assets = PlasmaVault(_plasmaVault).previewRedeem(shares_);
        assertTrue(vm.revertToState(snap));
    }

    function _only(uint256 marketId_) private pure returns (uint256[] memory list) {
        list = new uint256[](1);
        list[0] = marketId_;
    }

    function _bothMarkets() private pure returns (uint256[] memory list) {
        list = new uint256[](2);
        list[0] = IporFusionMarkets.EULER_V2;
        list[1] = IporFusionMarkets.ERC20_VAULT_BALANCE;
    }

    function _userDeposit() private returns (uint256 shares) {
        deal(_WETH, _USER, ERC20(_WETH).balanceOf(_USER) + _DEPOSIT);
        vm.startPrank(_USER);
        ERC20(_WETH).approve(_plasmaVault, _DEPOSIT);
        shares = PlasmaVault(_plasmaVault).deposit(_DEPOSIT, _USER);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // Tests
    // -----------------------------------------------------------------------

    /// @dev Exclusion hook with market 11 on deposit and redeem: the pool market keeps its pre-swap cached value, market 7
    ///      is refreshed, and shares / assets are priced with market 11 at the pre-swap value and market 7 refreshed.
    function testShouldKeepPoolMarketCachedAndRefreshOtherMarketOnDepositAndRedeem() public {
        _supplyAndDeployStoring();
        (uint256 cached11, uint256 cached7) = _swapAndDonate();
        _wire(address(new UpdateBalancesExcludeMarketsPreHook()), _excludePoolMarket());

        // The swap really moved market 11 and the donation market 7 (what a refresh would book).
        uint256 fresh11 = _valueAfterRefresh(_only(IporFusionMarkets.EULER_V2), IporFusionMarkets.EULER_V2);
        uint256 fresh7 = _valueAfterRefresh(
            _only(IporFusionMarkets.ERC20_VAULT_BALANCE),
            IporFusionMarkets.ERC20_VAULT_BALANCE
        );
        assertGt(fresh11, cached11, "swap fee moved the pool value of market 11");
        assertGt(fresh7, cached7, "donation moved market 7");

        // Expected price: only market 7 refreshed, market 11 at its pre-swap cache.
        uint256[] memory onlySeven = _only(IporFusionMarkets.ERC20_VAULT_BALANCE);
        uint256 expectedShares = _previewDepositAfterRefresh(onlySeven);
        uint256 sevenAtHook = _valueAfterRefresh(onlySeven, IporFusionMarkets.ERC20_VAULT_BALANCE);

        uint256 shares = _userDeposit();

        assertEq(_market(IporFusionMarkets.EULER_V2), cached11, "deposit: market 11 cache unchanged");
        assertEq(_market(IporFusionMarkets.ERC20_VAULT_BALANCE), sevenAtHook, "deposit: market 7 refreshed");
        assertEq(sevenAtHook, fresh7, "market 7 refreshed to the donated value");
        assertEq(shares, expectedShares, "deposit shares at the pre-swap pool value");

        uint256 expectedAssets = _previewRedeemAfterRefresh(onlySeven, shares);
        uint256 balanceBefore = ERC20(_WETH).balanceOf(_USER);
        vm.prank(_USER);
        uint256 assets = PlasmaVault(_plasmaVault).redeem(shares, _USER, _USER);

        assertEq(_market(IporFusionMarkets.EULER_V2), cached11, "redeem: market 11 cache unchanged");
        assertEq(assets, expectedAssets, "redeem assets at the pre-swap pool value");
        assertEq(ERC20(_WETH).balanceOf(_USER) - balanceBefore, assets, "redeem paid out");
    }

    /// @dev Control: UpdateBalancesPreHook on the same sequence refreshes market 11, books the moved pool value into the
    ///      share price, and the depositor gets fewer shares than under the exclusion hook.
    function testControlUpdateBalancesPreHookBooksMovedPoolValueIntoPrice() public {
        _supplyAndDeployStoring();
        (uint256 cached11, ) = _swapAndDonate();
        _wire(address(new UpdateBalancesPreHook()), new bytes32[](0));

        uint256 fresh11 = _valueAfterRefresh(_only(IporFusionMarkets.EULER_V2), IporFusionMarkets.EULER_V2);
        assertGt(fresh11, cached11, "swap fee moved the pool value of market 11");

        uint256 expectedShares = _previewDepositAfterRefresh(_bothMarkets());
        uint256 sharesIfExcluded = _previewDepositAfterRefresh(_only(IporFusionMarkets.ERC20_VAULT_BALANCE));

        uint256 shares = _userDeposit();

        assertEq(_market(IporFusionMarkets.EULER_V2), fresh11, "deposit: market 11 refreshed and booked");
        assertGt(_market(IporFusionMarkets.EULER_V2), cached11, "deposit: moved pool value is in the cache");
        assertEq(shares, expectedShares, "deposit shares at the refreshed pool value");
        assertLt(shares, sharesIfExcluded, "booked pool value raises the price: fewer shares than with the exclusion");

        uint256 expectedAssets = _previewRedeemAfterRefresh(_bothMarkets(), shares);
        vm.prank(_USER);
        uint256 assets = PlasmaVault(_plasmaVault).redeem(shares, _USER, _USER);
        assertEq(assets, expectedAssets, "redeem assets at the refreshed pool value");
    }

    /// @dev The dependency edge is 11 -> 7 (market 11 depends on 7). Refreshing 7 alone does not pull market 11 in; the
    ///      other direction (refreshing 11) refreshes 7 as well, which is why an exclusion of 11 only holds while no
    ///      refreshed market has an edge TO 11 (see the hook NatSpec).
    function testShouldNotRefreshPoolMarketThroughDependencyEdgeWhenMarketSevenIsRefreshed() public {
        _supplyAndDeployStoring();
        (uint256 cached11, uint256 cached7) = _swapAndDonate();

        PlasmaVault(_plasmaVault).updateMarketsBalances(_only(IporFusionMarkets.ERC20_VAULT_BALANCE));
        assertEq(_market(IporFusionMarkets.EULER_V2), cached11, "refreshing 7 leaves market 11 untouched");
        uint256 refreshed7 = _market(IporFusionMarkets.ERC20_VAULT_BALANCE);
        assertGt(refreshed7, cached7, "market 7 refreshed");

        // Move market 7 again, then refresh only 11: the edge 11 -> 7 drags market 7 along.
        deal(_CBETH, _plasmaVault, ERC20(_CBETH).balanceOf(_plasmaVault) + 1e18);
        PlasmaVault(_plasmaVault).updateMarketsBalances(_only(IporFusionMarkets.EULER_V2));
        assertGt(_market(IporFusionMarkets.EULER_V2), cached11, "refreshing 11 books the pool value");
        assertGt(
            _market(IporFusionMarkets.ERC20_VAULT_BALANCE),
            refreshed7,
            "refreshing 11 also refreshes 7 (edge 11 -> 7)"
        );
    }
}
