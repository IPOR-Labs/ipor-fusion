// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IEVC} from "ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";

import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {EulerFuseLib, EulerSubstrate} from "../../../contracts/fuses/euler/EulerFuseLib.sol";
import {EulerV2SupplyFuse, EulerV2SupplyFuseEnterData} from "../../../contracts/fuses/euler/EulerV2SupplyFuse.sol";
import {EulerV2BalanceFuse} from "../../../contracts/fuses/euler/EulerV2BalanceFuse.sol";
import {
    EulerV2SwapDeployFuse,
    EulerV2SwapDeployFuseEnterData,
    EulerV2SwapDeployFuseExitData
} from "../../../contracts/fuses/euler/EulerV2SwapDeployFuse.sol";
import {IBorrowing} from "../../../contracts/fuses/euler/ext/IBorrowing.sol";
import {IEulerV2Swap} from "../../../contracts/fuses/euler/ext/IEulerV2Swap.sol";
import {IEulerV2SwapFactory} from "../../../contracts/fuses/euler/ext/IEulerV2SwapFactory.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {InstantWithdrawalFusesParamsStruct} from "../../../contracts/libraries/PlasmaVaultLib.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {
    PlasmaVault,
    PlasmaVaultInitData,
    MarketSubstratesConfig,
    MarketBalanceFuseConfig,
    FuseAction
} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {FeeAccount} from "../../../contracts/managers/fee/FeeAccount.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {
    IporFusionAccessManagerInitializerLibV1,
    InitializationData,
    DataForInitialization,
    PlasmaVaultAddress
} from "../../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {PlasmaVaultConfigurator} from "../../utils/PlasmaVaultConfigurator.sol";
import {PlasmaVaultCloneLib} from "../../test_helpers/PlasmaVaultCloneLib.sol";

/// @title EulerV2SwapPoolForkFixture
/// @notice Shared Base-mainnet (chainId 8453) fork fixture for the EulerSwap pool valuation suites (IL-9706): a
///         PlasmaVault with the Euler supply and deploy fuses, the Euler balance fuse on market 11, the real EulerSwap
///         factory / periphery / eVaults / EVC at the block of `EulerV2SwapForkTest`, and helpers to deploy a pool, swap,
///         donate and read the market value. It deliberately uses no symbol that is new in IL-9706 (the pool entry is
///         encoded as a raw bytes32), so the first suite below compiles on the base commit 69766843.
/// @dev No scenario moves time (`vm.warp`): suites with the same fork URL and block share one fork backend.
abstract contract EulerV2SwapPoolForkFixture is Test {
    address internal constant _EVC = 0x5301c7dD20bD945D2013b48ed0DEE3A284ca8989;
    address internal constant _EULERSWAP_FACTORY = 0x6C5f4c239ceD289447737EAB8eEA64523bd9c05E;
    address internal constant _EULERSWAP_PERIPHERY = 0xA564dAe65eA7B1ce049AbACFC4Cb1A32C93e127c;

    address internal constant _EVAULT_CBETH = 0x358f25F82644eaBb441d0df4AF8746614fb9ea49; // ecbETH-1
    address internal constant _EVAULT_WETH = 0x859160DB5841E5cfB8D3f144C6b3381A85A4b410; // eWETH-1
    address internal constant _CBETH = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22;
    address internal constant _WETH = 0x4200000000000000000000000000000000000006;
    address internal constant _CBETH_USD_FEED = 0xd7818272B9e248357d13057AAb0B417aF31E817d;
    address internal constant _ETH_USD_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;

    bytes1 internal constant _SUB_ACCOUNT = 0x01;
    bytes1 internal constant _PLAIN_SUB_ACCOUNT = 0x00;
    uint256 internal constant _PRICE_DEVIATION_WAD = 1e16;
    uint64 internal constant _FEE = 3e15;

    address internal constant _ATOMIST = address(1111111);
    address internal constant _ALPHA = address(2222222);
    address internal constant _USER = address(12121212);

    // EulerSwap v2 pools are Uniswap-v4 hooks: the low 14 bits of the pool address must equal the permission flags.
    uint160 internal constant _HOOK_FLAG_MASK = uint160((1 << 14) - 1);
    uint160 internal constant _HOOK_FLAG_REQUIRED = uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 5) | (1 << 3));

    address internal _plasmaVault;
    address internal _priceOracle;
    address internal _accessManager;
    address internal _withdrawManager;
    address internal _eulerSupplyFuse;
    address internal _eulerSwapDeployFuse;
    address internal _eulerAccount;

    /// @dev Salt and address of the pool the fixture deploys (mined once in setUp, depends on the static params only)
    bytes32 internal _salt;
    address internal _pool;

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("BASE_PROVIDER_URL"), 47493000);

        _priceOracle = _createPriceOracle();
        _accessManager = address(new IporFusionAccessManager(_ATOMIST, 0));
        _withdrawManager = address(new WithdrawManager(_accessManager));

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
                _withdrawManager,
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
        _eulerAccount = EulerFuseLib.generateSubAccountAddress(_plasmaVault, _SUB_ACCOUNT);
        (_salt, _pool) = _mineSalt(_staticParams());
        _grantSubstrates(address(0));
        _initialDepositIntoPlasmaVault();
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
        fuses = new address[](2);
        fuses[0] = _eulerSupplyFuse;
        fuses[1] = _eulerSwapDeployFuse;
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

    function _initialDepositIntoPlasmaVault() private {
        deal(_WETH, _USER, 50e18);
        vm.startPrank(_USER);
        ERC20(_WETH).approve(_plasmaVault, 50e18);
        PlasmaVault(_plasmaVault).deposit(50e18, _USER);
        vm.stopPrank();
        deal(_CBETH, _plasmaVault, 20e18);
        _refresh();
    }

    // -----------------------------------------------------------------------
    // Substrates, pool address, deployment
    // -----------------------------------------------------------------------

    /// @dev Raw bytes32 of a market-11 pool entry: [pool][flags 0][flags 0][sub-account][kind 1][padding] (IL-9706)
    function _poolEntry(address pool_, bytes1 subAccount_) internal pure returns (bytes32) {
        return bytes32((uint256(uint160(pool_)) << 96) | (uint256(uint8(subAccount_)) << 72) | (uint256(1) << 64));
    }

    /// @dev Grants the eVault rows of the pool sub-account (collateral + borrow), the plain eWETH row on sub-account
    ///      0x00 (instant withdraw) and, when `pool_ != address(0)`, the pool entry (replaces the previous grant).
    function _grantSubstrates(address pool_) internal {
        bytes32[] memory substrates = new bytes32[](pool_ == address(0) ? 3 : 4);
        substrates[0] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: _EVAULT_CBETH, isCollateral: true, canBorrow: true, subAccounts: _SUB_ACCOUNT})
        );
        substrates[1] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: _EVAULT_WETH, isCollateral: true, canBorrow: true, subAccounts: _SUB_ACCOUNT})
        );
        substrates[2] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({
                eulerVault: _EVAULT_WETH,
                isCollateral: false,
                canBorrow: false,
                subAccounts: _PLAIN_SUB_ACCOUNT
            })
        );
        if (pool_ != address(0)) {
            substrates[3] = _poolEntry(pool_, _SUB_ACCOUNT);
        }
        vm.prank(_ATOMIST);
        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(IporFusionMarkets.EULER_V2, substrates);
    }

    function _staticParams() internal view returns (IEulerV2Swap.StaticParams memory sp) {
        sp = IEulerV2Swap.StaticParams({
            supplyVault0: _EVAULT_CBETH,
            supplyVault1: _EVAULT_WETH,
            borrowVault0: _EVAULT_CBETH,
            borrowVault1: _EVAULT_WETH,
            eulerAccount: _eulerAccount,
            feeRecipient: address(0)
        });
    }

    /// @dev asset0 = cbETH, asset1 = WETH; priceX/priceY = 1.13309 is ~0.097% off the oracle ratio of the block
    function _dynamicParams(uint64 concentration_) internal pure returns (IEulerV2Swap.DynamicParams memory dp) {
        dp = IEulerV2Swap.DynamicParams({
            equilibriumReserve0: uint112(5e18),
            equilibriumReserve1: uint112(5e18),
            minReserve0: 0,
            minReserve1: 0,
            priceX: uint80(1133090000000000000),
            priceY: uint80(1e18),
            concentrationX: concentration_,
            concentrationY: concentration_,
            fee0: _FEE,
            fee1: _FEE,
            expiration: 0,
            swapHookedOperations: 0,
            swapHook: address(0)
        });
    }

    function _initialState() internal pure returns (IEulerV2Swap.InitialState memory st) {
        st = IEulerV2Swap.InitialState({reserve0: uint112(5e18), reserve1: uint112(5e18)});
    }

    function _mineSalt(IEulerV2Swap.StaticParams memory sp) internal view returns (bytes32 salt, address predicted) {
        for (uint256 i; i < 200000; ++i) {
            salt = bytes32(i);
            predicted = IEulerV2SwapFactory(_EULERSWAP_FACTORY).computePoolAddress(sp, salt);
            if (
                (uint160(predicted) & _HOOK_FLAG_MASK) == _HOOK_FLAG_REQUIRED &&
                !IEulerV2SwapFactory(_EULERSWAP_FACTORY).deployedPools(predicted)
            ) {
                return (salt, predicted);
            }
        }
        revert("salt mining failed");
    }

    function _supplyAction(
        address eVault_,
        uint256 amount_,
        bytes1 subAccount_
    ) internal view returns (FuseAction memory) {
        return
            FuseAction({
                fuse: _eulerSupplyFuse,
                data: abi.encodeWithSignature(
                    "enter((address,uint256,bytes1))",
                    EulerV2SupplyFuseEnterData({eulerVault: eVault_, maxAmount: amount_, subAccount: subAccount_})
                )
            });
    }

    function _deployAction(
        IEulerV2Swap.DynamicParams memory dp_,
        IEulerV2Swap.InitialState memory st_
    ) internal view returns (FuseAction memory) {
        EulerV2SwapDeployFuseEnterData memory data = EulerV2SwapDeployFuseEnterData({
            staticParams: _staticParams(),
            dynamicParams: dp_,
            initialState: st_,
            salt: _salt,
            predictedPool: _pool,
            subAccount: _SUB_ACCOUNT
        });
        return
            FuseAction({
                fuse: _eulerSwapDeployFuse,
                data: abi.encodeWithSignature(
                    "enter(((address,address,address,address,address,address),(uint112,uint112,uint112,uint112,uint80,uint80,uint64,uint64,uint64,uint64,uint40,uint8,address),(uint112,uint112),bytes32,address,bytes1))",
                    data
                )
            });
    }

    function _execute(FuseAction[] memory actions_) internal {
        vm.prank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(actions_);
    }

    /// @dev Supplies `cbEth_` cbETH and `weth_` WETH on the pool sub-account
    function _supplyActions(uint256 cbEth_, uint256 weth_) internal view returns (FuseAction[] memory actions) {
        actions = new FuseAction[](2);
        actions[0] = _supplyAction(_EVAULT_CBETH, cbEth_, _SUB_ACCOUNT);
        actions[1] = _supplyAction(_EVAULT_WETH, weth_, _SUB_ACCOUNT);
    }

    /// @dev Direct deployment as the vault, without the deploy fuse, without a pool entry: install the pool as EVC
    ///      operator of the sub-account and deploy it through `EVC.call` on behalf of that sub-account.
    function _deployDirect(uint64 concentration_) internal {
        vm.startPrank(_plasmaVault);
        IEVC(_EVC).setAccountOperator(_eulerAccount, _pool, true);
        IEVC(_EVC).call(
            _EULERSWAP_FACTORY,
            _eulerAccount,
            0,
            abi.encodeCall(
                IEulerV2SwapFactory.deployPool,
                (_staticParams(), _dynamicParams(concentration_), _initialState(), _salt)
            )
        );
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // Pool interaction helpers (low-level calls: no interface declared in tests)
    // -----------------------------------------------------------------------

    function _poolSwap(address pool_, uint256 out0_, uint256 out1_, address to_, bytes memory data_) internal {
        (bool ok, bytes memory ret) = pool_.call(
            abi.encodeWithSignature("swap(uint256,uint256,address,bytes)", out0_, out1_, to_, data_)
        );
        if (!ok) {
            _bubble(ret);
        }
    }

    function _bubble(bytes memory ret_) internal pure {
        assembly {
            revert(add(ret_, 32), mload(ret_))
        }
    }

    function _quoteExactOut(address tokenIn_, address tokenOut_, uint256 amountOut_) internal view returns (uint256) {
        (bool ok, bytes memory ret) = _pool.staticcall(
            abi.encodeWithSignature(
                "computeQuote(address,address,uint256,bool)",
                tokenIn_,
                tokenOut_,
                amountOut_,
                false
            )
        );
        require(ok, "computeQuote failed");
        return abi.decode(ret, (uint256));
    }

    /// @dev Swap through the periphery from a fresh EOA: gives it `amountIn_` of `tokenIn_`, returns what it received
    function _swapExactIn(
        address tokenIn_,
        address tokenOut_,
        uint256 amountIn_,
        address swapper_
    ) internal returns (uint256 received) {
        uint256 before = ERC20(tokenOut_).balanceOf(swapper_);
        deal(tokenIn_, swapper_, ERC20(tokenIn_).balanceOf(swapper_) + amountIn_);
        vm.startPrank(swapper_);
        ERC20(tokenIn_).approve(_EULERSWAP_PERIPHERY, amountIn_);
        (bool ok, bytes memory ret) = _EULERSWAP_PERIPHERY.call(
            abi.encodeWithSignature(
                "swapExactIn(address,address,address,uint256,address,uint256,uint256)",
                _pool,
                tokenIn_,
                tokenOut_,
                amountIn_,
                swapper_,
                0,
                0
            )
        );
        vm.stopPrank();
        if (!ok) {
            _bubble(ret);
        }
        received = ERC20(tokenOut_).balanceOf(swapper_) - before;
    }

    /// @dev Donation: `amount_` of `token_` is sent to the pool and a dust swap in the other asset lets the pool book
    ///      the whole balance as swap input (reserves go up by the donation minus the fee)
    function _donate(address token_, uint256 amount_) internal {
        deal(token_, _pool, ERC20(token_).balanceOf(_pool) + amount_);
        if (token_ == _CBETH) {
            _poolSwap(_pool, 0, 1e9, address(0xD057), "");
        } else {
            _poolSwap(_pool, 1e9, 0, address(0xD057), "");
        }
    }

    // -----------------------------------------------------------------------
    // Valuation helpers
    // -----------------------------------------------------------------------

    function _refresh() internal {
        uint256[] memory marketIds = new uint256[](2);
        marketIds[0] = IporFusionMarkets.EULER_V2;
        marketIds[1] = IporFusionMarkets.ERC20_VAULT_BALANCE;
        PlasmaVault(_plasmaVault).updateMarketsBalances(marketIds);
    }

    /// @dev Refreshes market 11 and returns its value in WETH (vault underlying)
    function _nav() internal returns (uint256) {
        _refresh();
        return PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.EULER_V2);
    }

    function _priceWad(address asset_) internal view returns (uint256 price) {
        (uint256 p, uint256 d) = PriceOracleMiddleware(_priceOracle).getAssetPrice(asset_);
        price = (p * 1e18) / 10 ** d;
    }

    /// @dev Value of `amount_` cbETH in WETH at the oracle
    function _cbEthInWeth(uint256 amount_) internal view returns (uint256) {
        return (amount_ * _priceWad(_CBETH)) / _priceWad(_WETH);
    }

    /// @dev Independent value of the pool sub-account holdings in WETH: collateral minus debt of both eVaults
    function _holdingsInWeth() internal view returns (uint256 net) {
        uint256 collateral;
        uint256 debt;
        address[2] memory evaults = [_EVAULT_CBETH, _EVAULT_WETH];
        for (uint256 i; i < 2; ++i) {
            uint256 price = _priceWad(ERC4626(evaults[i]).asset());
            collateral +=
                (ERC4626(evaults[i]).convertToAssets(ERC4626(evaults[i]).balanceOf(_eulerAccount)) * price) / 1e18;
            debt += (IBorrowing(evaults[i]).debtOf(_eulerAccount) * price) / 1e18;
        }
        uint256 wethPrice = _priceWad(_WETH);
        net = ((collateral - debt) * 1e18) / wethPrice;
    }

    /// @dev Outcome of `_redeemWhilePushed`: what the redeem paid and the two independent expectations
    struct RedeemProbe {
        uint256 assets;
        uint256 fairAssets;
        uint256 noPoolTermAssets;
        uint256 overpaymentShare;
        uint256 pulled;
        uint256 navAfter;
        uint256 navFair;
    }

    /// @dev Shares fixed before the manipulation, curve pushed, then a redeem with NO explicit refresh in between: the
    ///      redeem itself refreshes market 11 (the instant withdraw source). The idle balance is short, so the instant
    ///      withdraw from the plain position on sub-account 0x00 runs. The expectations are computed from the
    ///      sub-account holdings (collateral - debt priced at the oracle, no fuse involved) and the LP fee:
    ///      fair total = total before + fee; without the pool term the total would rise by the whole holdings gain.
    function _redeemWhilePushed() internal returns (RedeemProbe memory p) {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = _supplyAction(_EVAULT_WETH, 20e18, _PLAIN_SUB_ACCOUNT);
        _execute(actions);

        InstantWithdrawalFusesParamsStruct[] memory iw = new InstantWithdrawalFusesParamsStruct[](1);
        bytes32[] memory params = new bytes32[](3);
        params[0] = bytes32(0);
        params[1] = PlasmaVaultConfigLib.addressToBytes32(_EVAULT_WETH);
        params[2] = bytes32(_PLAIN_SUB_ACCOUNT);
        iw[0] = InstantWithdrawalFusesParamsStruct({fuse: _eulerSupplyFuse, params: params});
        vm.prank(_ATOMIST);
        PlasmaVaultGovernance(_plasmaVault).configureInstantWithdrawalFuses(iw);

        uint256 navBefore = _nav();
        uint256 totalBefore = PlasmaVault(_plasmaVault).totalAssets();
        uint256 supply = PlasmaVault(_plasmaVault).totalSupply();
        uint256 holdingsBefore = _holdingsInWeth();
        uint256 idle = ERC20(_WETH).balanceOf(_plasmaVault);
        uint256 shares = PlasmaVault(_plasmaVault).convertToShares(idle + 10e18);

        uint256 amountIn = _quoteExactOut(_WETH, _CBETH, 15e17);
        _swapExactIn(_WETH, _CBETH, amountIn, address(0xBEEF));
        uint256 fee = (amountIn * _FEE) / 1e18;
        uint256 holdingsGain = _holdingsInWeth() - holdingsBefore;
        assertGt(holdingsGain, fee + 1e15, "the push overpaid by more than the fee");

        p.fairAssets = (shares * (totalBefore + fee)) / supply;
        p.noPoolTermAssets = (shares * (totalBefore + holdingsGain)) / supply;
        p.overpaymentShare = (shares * (holdingsGain - fee)) / supply;
        p.navFair = navBefore + fee;

        uint256 userBefore = ERC20(_WETH).balanceOf(_USER);
        vm.prank(_USER);
        p.assets = PlasmaVault(_plasmaVault).redeem(shares, _USER, _USER);
        assertEq(ERC20(_WETH).balanceOf(_USER) - userBefore, p.assets, "user received the assets");

        // what the instant withdraw took out of the plain position (the vault keeps a small buffer above the payout)
        p.pulled = ERC20(_WETH).balanceOf(_plasmaVault) + p.assets - idle;
        assertGt(p.pulled, 10e18 - 1e15, "the instant withdraw paid the part idle could not cover");
        assertLt(p.pulled, 11e18, "the buffer stays small");
        p.navAfter = _nav();
    }

    function _poolReserves() internal view returns (uint256 reserve0, uint256 reserve1) {
        (uint112 r0, uint112 r1, ) = IEulerV2Swap(_pool).getReserves();
        return (r0, r1);
    }

    function _setCbEthFeedMove(int256 bps_) internal {
        (bool ok, bytes memory ret) = _CBETH_USD_FEED.staticcall(abi.encodeWithSignature("latestRoundData()"));
        require(ok, "feed read failed");
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = abi.decode(
            ret,
            (uint80, int256, uint256, uint256, uint80)
        );
        vm.mockCall(
            _CBETH_USD_FEED,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(roundId, (answer * (10_000 + bps_)) / 10_000, startedAt, updatedAt, answeredInRound)
        );
    }
}

/// @title EulerV2SwapPoolFairValueForkTest
/// @notice IL-9706 (3sigma audit v3 #20): protected configuration. The pool is deployed through the deploy fuse with a
///         pool entry on market 11; the balance fuse values the sub-account minus the displacement of the pool reserves
///         from the oracle-fair point, so a donation, a curve push, a JIT swap or an arbitrage moves the market value
///         by the LP fee only. On the base commit the deploy fuse reverts on the pool entry (read as an eVault row), so
///         every test here fails in `execute`.
contract EulerV2SwapPoolFairValueForkTest is EulerV2SwapPoolForkFixture {
    uint64 internal constant _C_HALF = 5e17;
    uint64 internal constant _C_NEAR_ONE = 999e15;
    uint64 internal constant _C_ONE = 1e18;

    /// @dev Tolerance for rounding of the conversions (EVK shares, oracle WAD, round-up of the displacement)
    uint256 internal constant _TOL = 1e13;

    address internal constant _SWAPPER = address(0xBEEF);

    /// @dev Output of the dust swap of `_donate` (base units of the other asset)
    uint256 internal constant _DUST = 1e9;
    /// @dev Left in the reserve by the full reversals so that the swap stays on the curve despite rounding
    uint256 internal constant _REVERSAL_SHAVE = 1e3;
    /// @dev Explicit bound of the reserve restoration (base units): the shave plus the rounding of the swaps
    uint256 internal constant _RESERVE_BOUND = 1e6;

    /// @dev Recorded by the `eulerSwapCall` callback
    bool internal _callbackRefreshOk;
    bytes internal _callbackRefreshRet;
    uint256 internal _callbackPayIn;

    /// @dev Grants the entry, supplies and deploys through the deploy fuse at concentration `c_`; returns the market
    ///      value after the deploy
    function _deployProtected(uint64 c_, uint256 cbEthSupply_, uint256 wethSupply_) internal returns (uint256) {
        _grantSubstrates(_pool);
        FuseAction[] memory supply = _supplyActions(cbEthSupply_, wethSupply_);
        FuseAction[] memory actions = new FuseAction[](3);
        actions[0] = supply[0];
        actions[1] = supply[1];
        actions[2] = _deployAction(_dynamicParams(c_), _initialState());
        _execute(actions);
        return _nav();
    }

    // -----------------------------------------------------------------------
    // Donation (three concentrations)
    // -----------------------------------------------------------------------

    function testShouldNotMoveMarketValueByDonationAtHalfConcentration() public {
        _assertDonationHarmless(_C_HALF);
    }

    function testShouldNotMoveMarketValueByDonationAtNearOneConcentration() public {
        _assertDonationHarmless(_C_NEAR_ONE);
    }

    function testShouldNotMoveMarketValueByDonationAtConstantSumConcentration() public {
        _assertDonationHarmless(_C_ONE);
    }

    /// @dev Donate 1 cbETH + dust swap, refresh, pull the surplus out with a zero-input swap, refresh. The value moves
    ///      by the LP fee on the donation only (the donor's loss), never by the donation itself.
    function _assertDonationHarmless(uint64 c_) internal {
        uint256 donation = 1e18;
        uint256 navBefore = _deployProtected(c_, 10e18, 10e18);
        uint256 holdingsBefore = _holdingsInWeth();
        (uint256 start0, uint256 start1) = _poolReserves();

        _donate(_CBETH, donation);
        (uint256 donated0, ) = _poolReserves();
        assertGt(donated0, start0 + (donation * 99) / 100, "the donation went into the reserve");

        uint256 holdingsAfterDonation = _holdingsInWeth();
        assertGt(holdingsAfterDonation, holdingsBefore + _cbEthInWeth(donation) - 1e15, "holdings took the donation");
        uint256 navAfterDonation = _nav();
        uint256 fee = (_cbEthInWeth(donation) * _FEE) / 1e18;
        emit log_named_uint("protected: nav delta after donation", navAfterDonation - navBefore);
        emit log_named_uint("protected: fee on donation", fee);
        assertApproxEqAbs(navAfterDonation, navBefore + fee, _TOL, "donation moves value by the fee only");

        // zero-input swap pulling out 90% of the donation net of the fee
        uint256 out0 = (donation * 9 * (1e18 - _FEE)) / (10 * 1e18);
        _poolSwap(_pool, out0, 0, address(0xD058), "");
        uint256 navAfterExtract = _nav();
        assertApproxEqAbs(navAfterExtract, navAfterDonation, _TOL, "extraction leaves the value unchanged");
        assertLt(_holdingsInWeth(), holdingsAfterDonation, "holdings lost the extracted amount");

        _completeDonationReversal(start0, start1, navBefore + fee);
    }

    /// @dev Completes the reversal: the dust leg of the donation swap is paid back (grossed up by the fee, so the net
    ///      input of the leg is at least the dust taken) and the rest of the net donation is extracted; both reserves
    ///      are back at the start within `_RESERVE_BOUND` and the value is the start plus the cumulative fees
    function _completeDonationReversal(uint256 start0_, uint256 start1_, uint256 navSoFar_) internal {
        uint256 dustBack = (_DUST * 1e18) / (1e18 - _FEE) + 1;
        deal(_WETH, _pool, ERC20(_WETH).balanceOf(_pool) + dustBack);
        (uint256 mid0, ) = _poolReserves();
        _poolSwap(_pool, mid0 - start0_ - _REVERSAL_SHAVE, 0, address(0xD059), "");

        (uint256 end0, uint256 end1) = _poolReserves();
        assertApproxEqAbs(end0, start0_, _RESERVE_BOUND, "reserve0 restored after the full extraction");
        assertApproxEqAbs(end1, start1_, _RESERVE_BOUND, "reserve1 restored after the full extraction");
        assertApproxEqAbs(_nav(), navSoFar_ + (dustBack * _FEE) / 1e18, _TOL, "final value is the start plus the fees");
    }

    // -----------------------------------------------------------------------
    // Curve push (two concentrations)
    // -----------------------------------------------------------------------

    function testShouldNotMoveMarketValueByCurvePushAtHalfConcentration() public {
        _assertCurvePushHarmless(_C_HALF);
    }

    function testShouldNotMoveMarketValueByCurvePushAtNearOneConcentration() public {
        _assertCurvePushHarmless(_C_NEAR_ONE);
    }

    /// @dev Buy 2.5 cbETH (about half of the equilibrium reserve) through the periphery, refresh, sell it back,
    ///      refresh: the value moves by the LP fee on the two inputs only.
    function _assertCurvePushHarmless(uint64 c_) internal {
        uint256 navBefore = _deployProtected(c_, 10e18, 10e18);
        (uint256 start0, uint256 start1) = _poolReserves();

        uint256 out = 25e17;
        uint256 amountIn = _quoteExactOut(_WETH, _CBETH, out);
        uint256 received = _swapExactIn(_WETH, _CBETH, amountIn, _SWAPPER);
        assertApproxEqAbs(received, out, 1e6, "pushed to about half of the reserve");

        uint256 navPushed = _nav();
        uint256 fee1 = (amountIn * _FEE) / 1e18;
        emit log_named_uint("protected: nav delta after push", navPushed - navBefore);
        emit log_named_uint("protected: fee on push", fee1);
        assertApproxEqAbs(navPushed, navBefore + fee1, _TOL, "push moves value by the fee only");

        uint256 fee2 = (_cbEthInWeth(received) * _FEE) / 1e18;
        assertGt(_swapExactIn(_CBETH, _WETH, received, _SWAPPER), 0, "swapped back");
        assertApproxEqAbs(_nav(), navPushed + fee2, _TOL, "return swap moves value by the fee only");

        _completeCurvePushReversal(received, navBefore + fee1 + fee2, start0, start1);
    }

    /// @dev Completes the reversal: the fee left in the pool by the return swap is topped up with a second cbETH
    ///      input, grossed up by the fee so that the net inputs sum to the cbETH bought; both reserves are back at the
    ///      start within `_RESERVE_BOUND` and the value is the start plus the cumulative fees
    function _completeCurvePushReversal(
        uint256 received_,
        uint256 navSoFar_,
        uint256 start0_,
        uint256 start1_
    ) internal {
        uint256 topUp = (received_ * _FEE) / (1e18 - _FEE) + 2;
        _swapExactIn(_CBETH, _WETH, topUp, _SWAPPER);
        (uint256 end0, uint256 end1) = _poolReserves();
        assertApproxEqAbs(end0, start0_, _RESERVE_BOUND, "reserve0 restored after the full reversal");
        assertApproxEqAbs(end1, start1_, _RESERVE_BOUND, "reserve1 restored after the full reversal");
        assertApproxEqAbs(
            _nav(),
            navSoFar_ + (_cbEthInWeth(topUp) * _FEE) / 1e18,
            _TOL,
            "final value is the start plus the fees"
        );
    }

    // -----------------------------------------------------------------------
    // User redeem through the instant withdraw path of market 11
    // -----------------------------------------------------------------------

    /// @dev The payout of shares fixed before the push equals the independent fair value (total before plus the LP
    ///      fee, the holder's share of it) and is below the value without the pool term by that term's overpayment
    ///      share, so the assertion fails if the displacement deduction is dropped.
    function testShouldRedeemThroughInstantWithdrawWithLivePool() public {
        uint256 navDeployed = _deployProtected(_C_HALF, 10e18, 10e18);
        RedeemProbe memory p = _redeemWhilePushed();

        emit log_named_uint("protected: redeem payout", p.assets);
        emit log_named_uint("protected: fair payout", p.fairAssets);
        emit log_named_uint("protected: payout without the pool term", p.noPoolTermAssets);
        assertGt(p.overpaymentShare, 1e15, "the overpayment share is visible");
        assertApproxEqAbs(p.assets, p.fairAssets, _TOL, "redeem paid the fair value plus the fee share");
        assertApproxEqAbs(
            p.noPoolTermAssets - p.assets,
            p.overpaymentShare,
            _TOL,
            "payout is below the no-pool-term value by the overpayment share"
        );
        // the pool sub-account and its displacement did not move: the market value fell by what the plain position paid
        assertApproxEqAbs(p.navAfter, p.navFair - p.pulled, _TOL, "market value fell by the instant withdraw only");
        assertGt(navDeployed, 0, "pool value was counted");
    }

    // -----------------------------------------------------------------------
    // JIT pool with debt
    // -----------------------------------------------------------------------

    function testShouldValueJitPoolWithDebtByFeeOnly() public {
        uint256 navBefore = _deployProtected(_C_HALF, 1e18, 10e18);
        assertEq(IBorrowing(_EVAULT_CBETH).debtOf(_eulerAccount), 0, "no debt before the swap");

        uint256 amountIn = 3e18;
        uint256 received = _swapExactIn(_WETH, _CBETH, amountIn, _SWAPPER);
        assertGt(received, 1e18, "output exceeds the cbETH deposit");
        assertGt(IBorrowing(_EVAULT_CBETH).debtOf(_eulerAccount), 0, "JIT borrow opened cbETH debt");

        uint256 navAfter = _nav();
        uint256 fee = (amountIn * _FEE) / 1e18;
        emit log_named_uint("protected: JIT nav delta", navAfter - navBefore);
        emit log_named_uint("protected: JIT fee", fee);
        assertApproxEqAbs(navAfter, navBefore + fee, _TOL, "JIT swap moves value by the fee only");
    }

    // -----------------------------------------------------------------------
    // Refresh in the middle of a swap
    // -----------------------------------------------------------------------

    /// @dev Called by the pool in the middle of `swap`: the test contract holds the refresh role, so it refreshes
    ///      market 11 while the pool is locked, then pays the input.
    function eulerSwapCall(address, uint256, uint256, bytes calldata) external {
        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.EULER_V2;
        (_callbackRefreshOk, _callbackRefreshRet) = _plasmaVault.call(
            abi.encodeWithSignature("updateMarketsBalances(uint256[])", marketIds)
        );
        ERC20(_WETH).transfer(_pool, _callbackPayIn);
    }

    function testShouldRevertRefreshInTheMiddleOfSwapWithLocked() public {
        _deployProtected(_C_HALF, 10e18, 10e18);

        uint256 out = 1e18;
        _callbackPayIn = _quoteExactOut(_WETH, _CBETH, out);
        deal(_WETH, address(this), _callbackPayIn);
        _poolSwap(_pool, out, 0, address(this), hex"01");

        assertFalse(_callbackRefreshOk, "refresh in the middle of a swap must revert");
        assertEq(bytes4(_callbackRefreshRet), bytes4(keccak256("Locked()")), "revert selector is Locked()");
        // after the swap the refresh works again
        assertGt(_nav(), 0, "refresh works after the swap");
    }

    // -----------------------------------------------------------------------
    // Price move in the feed and arbitrage
    // -----------------------------------------------------------------------

    /// @dev cbETH gets 5% dearer in the feed: the refresh books the pool's pending arbitrage loss at once (value falls
    ///      by the displacement); the arbitrage that follows moves the value by the LP fee only.
    function testShouldBookPendingArbitrageLossAtPriceMoveAndNothingAtArbitrage() public {
        uint256 navMoved = _assertPriceMoveBooksDisplacement(500);

        // arbitrage: buy 0.2 cbETH from the pool with WETH (the curve sells below the new oracle price)
        uint256 out = 2e17;
        uint256 amountIn = _quoteExactOut(_WETH, _CBETH, out);
        _swapExactIn(_WETH, _CBETH, amountIn, _SWAPPER);
        uint256 navArb = _nav();
        uint256 fee = (amountIn * _FEE) / 1e18;
        assertApproxEqAbs(navArb, navMoved + fee, _TOL, "arbitrage moves value by the fee only");
    }

    function testShouldBookPendingArbitrageLossAtNegativePriceMove() public {
        _assertPriceMoveBooksDisplacement(-500);
    }

    /// @dev The feed moves by `bps_`: the refresh books the pool's pending arbitrage loss at once. The value equals the
    ///      holdings (collateral - debt at the oracle) minus the displacement d computed here from the closed-form
    ///      curve, independently of the fuse, within `_TOL`. Returns the value after the move.
    function _assertPriceMoveBooksDisplacement(int256 bps_) internal returns (uint256 navMoved) {
        uint256 navBefore = _deployProtected(_C_HALF, 10e18, 10e18);
        assertApproxEqAbs(navBefore, _holdingsInWeth(), _TOL, "no displacement at equilibrium");

        _setCbEthFeedMove(bps_);
        navMoved = _nav();
        uint256 holdingsMoved = _holdingsInWeth();
        uint256 displacement = _expectedDisplacementWeth();
        emit log_named_uint("protected: holdings at price move", holdingsMoved);
        emit log_named_uint("protected: nav at price move", navMoved);
        emit log_named_uint("protected: independent displacement", displacement);
        assertGt(displacement, 1e15, "the move puts the fair point well away from the equilibrium");
        assertApproxEqAbs(
            holdingsMoved - navMoved,
            displacement,
            _TOL,
            "holdings minus value equals the independent displacement"
        );
    }

    /// @dev Displacement d of the equilibrium reserves from the oracle-fair point at the current oracle price, WETH.
    ///      The curve is f(x) = y0 + (px/py)(x0 - x)(c + (1 - c) x0 / x) for x <= x0 (mirrored for y <= y0); its
    ///      marginal price equals the oracle price at x* = x0 sqrt((1 - c) / (k - c)), k = oracle / (px/py), and d is
    ///      the oracle value of the equilibrium reserves minus that of the fair point.
    function _expectedDisplacementWeth() internal view returns (uint256) {
        IEulerV2Swap.DynamicParams memory dp = IEulerV2Swap(_pool).getDynamicParams();
        uint256 oracle = _cbEthInWeth(1e18);
        uint256 curvePrice = (uint256(dp.priceX) * 1e18) / dp.priceY;
        uint256 c = dp.concentrationX;
        uint256 valueEquilibrium = (uint256(dp.equilibriumReserve0) * oracle) / 1e18 + dp.equilibriumReserve1;
        uint256 k = (oracle * 1e18) / curvePrice;

        uint256 x;
        uint256 y;
        if (k > 1e18) {
            x = (uint256(dp.equilibriumReserve0) * Math.sqrt((((1e18 - c) * 1e18) / (k - c)) * 1e18)) / 1e18;
            y =
                dp.equilibriumReserve1 +
                (((curvePrice * (dp.equilibriumReserve0 - x)) / 1e18) *
                    (c + ((1e18 - c) * dp.equilibriumReserve0) / x)) /
                    1e18;
        } else {
            y = (uint256(dp.equilibriumReserve1) * Math.sqrt((((1e18 - c) * 1e18) / (1e36 / k - c)) * 1e18)) / 1e18;
            x =
                dp.equilibriumReserve0 +
                ((((1e36 / curvePrice) * (dp.equilibriumReserve1 - y)) / 1e18) *
                    (c + ((1e18 - c) * dp.equilibriumReserve1) / y)) /
                    1e18;
        }
        uint256 valueFair = (x * oracle) / 1e18 + y;
        return valueEquilibrium > valueFair ? valueEquilibrium - valueFair : 0;
    }

    // -----------------------------------------------------------------------
    // Exit of the deploy fuse
    // -----------------------------------------------------------------------

    function testShouldValuePlainHoldingsAfterDeployFuseExit() public {
        uint256 navDeployed = _deployProtected(_C_HALF, 10e18, 10e18);
        uint256 amountIn = _quoteExactOut(_WETH, _CBETH, 25e17);
        _swapExactIn(_WETH, _CBETH, amountIn, _SWAPPER);
        uint256 navPushed = _nav();
        assertGt(navPushed, navDeployed, "fee came in");

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: _eulerSwapDeployFuse,
            data: abi.encodeWithSignature(
                "exit((address,bytes1))",
                EulerV2SwapDeployFuseExitData({pool: _pool, subAccount: _SUB_ACCOUNT})
            )
        });
        _execute(actions);
        assertFalse(IEVC(_EVC).isAccountOperatorAuthorized(_eulerAccount, _pool), "operator removed");

        // the uninstalled pool is skipped without a revert; the sub-account is worth its holdings
        uint256 navExited = _nav();
        assertApproxEqAbs(navExited, _holdingsInWeth(), _TOL, "value equals the holdings after the exit");
        assertGt(navExited, navPushed, "the displacement is released with the pool");
    }

    // -----------------------------------------------------------------------
    // Entry granted before the deploy
    // -----------------------------------------------------------------------

    function testShouldRefreshWithEntryGrantedBeforeDeploy() public {
        _grantSubstrates(_pool);
        _execute(_supplyActions(10e18, 10e18));
        assertEq(_pool.code.length, 0, "pool is not deployed yet");

        uint256 navNoPool = _nav();
        assertApproxEqAbs(navNoPool, _holdingsInWeth(), _TOL, "entry without a pool code is skipped");

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = _deployAction(_dynamicParams(_C_HALF), _initialState());
        _execute(actions);
        assertGt(_pool.code.length, 0, "pool deployed");
        assertApproxEqAbs(_nav(), navNoPool, _TOL, "a fresh pool at equilibrium does not move the value");
    }
}

/// @title EulerV2SwapPoolDirectDeployControlForkTest
/// @notice Control: the pool is deployed directly as the vault (`EVC.setAccountOperator` and `EVC.call(factory, ...)`),
///         without the deploy fuse and without a pool entry, so the balance fuse of every version values only the
///         sub-account holdings. A donation or a curve push then moves the market value by the whole overpayment. The
///         suite passes on the base commit and after the change (a pool without an entry is valued as before).
contract EulerV2SwapPoolDirectDeployControlForkTest is EulerV2SwapPoolForkFixture {
    uint256 internal constant _TOL = 1e13;
    address internal constant _SWAPPER = address(0xBEEF);

    function _deployUnseen(uint64 c_) internal returns (uint256) {
        _execute(_supplyActions(10e18, 10e18));
        _deployDirect(c_);
        assertGt(_pool.code.length, 0, "pool deployed directly");
        assertTrue(IEVC(_EVC).isAccountOperatorAuthorized(_eulerAccount, _pool), "pool is an operator");
        return _nav();
    }

    function testControlDonationJumpsMarketValueAtHalfConcentration() public {
        _assertDonationJump(5e17);
    }

    function testControlDonationJumpsMarketValueAtNearOneConcentration() public {
        _assertDonationJump(999e15);
    }

    function testControlDonationJumpsMarketValueAtConstantSumConcentration() public {
        _assertDonationJump(1e18);
    }

    /// @dev The whole donation shows up in the market value, and an extraction takes it away again
    function _assertDonationJump(uint64 c_) internal {
        uint256 donation = 1e18;
        uint256 navBefore = _deployUnseen(c_);

        _donate(_CBETH, donation);
        uint256 navAfter = _nav();
        uint256 jump = navAfter - navBefore;
        emit log_named_uint("control: nav jump after donation", jump);
        assertApproxEqAbs(jump, _cbEthInWeth(donation), _TOL, "market value jumped by the whole donation");

        uint256 out0 = (donation * 9 * (1e18 - _FEE)) / (10 * 1e18);
        _poolSwap(_pool, out0, 0, address(0xD058), "");
        assertApproxEqAbs(
            _nav(),
            navAfter - _cbEthInWeth(out0),
            _TOL,
            "extracting the surplus takes the value back out"
        );
    }

    function testControlCurvePushJumpsMarketValueAtHalfConcentration() public {
        _assertPushJump(5e17);
    }

    function testControlCurvePushJumpsMarketValueAtNearOneConcentration() public {
        _assertPushJump(999e15);
    }

    /// @dev Buying 2.5 cbETH shows the swapper's overpayment (slippage plus fee) as a jump of the market value
    function _assertPushJump(uint64 c_) internal {
        uint256 navBefore = _deployUnseen(c_);

        uint256 out = 25e17;
        uint256 amountIn = _quoteExactOut(_WETH, _CBETH, out);
        uint256 received = _swapExactIn(_WETH, _CBETH, amountIn, _SWAPPER);

        uint256 overpayment = amountIn - _cbEthInWeth(received);
        uint256 jump = _nav() - navBefore;
        emit log_named_uint("control: nav jump after curve push", jump);
        assertApproxEqAbs(jump, overpayment, _TOL, "market value jumped by the overpayment");
        assertGt(jump, (amountIn * _FEE) / 1e18, "the jump exceeds the LP fee alone");
    }

    /// @dev Same redeem without the pool entry: the payout exceeds the fair value by the overpayment share (the
    ///      assertion of the protected twin discriminates)
    function testControlRedeemOverpaysWithoutPoolEntry() public {
        _deployUnseen(5e17);
        RedeemProbe memory p = _redeemWhilePushed();

        emit log_named_uint("control: redeem payout", p.assets);
        emit log_named_uint("control: fair payout", p.fairAssets);
        assertGt(p.overpaymentShare, 1e15, "the overpayment share is visible");
        assertApproxEqAbs(p.assets, p.noPoolTermAssets, _TOL, "payout follows the holdings only");
        assertApproxEqAbs(p.assets - p.fairAssets, p.overpaymentShare, _TOL, "payout exceeds the fair value");
    }
}
