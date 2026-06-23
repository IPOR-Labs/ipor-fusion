// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IEVC} from "ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";

import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {EulerFuseLib, EulerSubstrate} from "../../../contracts/fuses/euler/EulerFuseLib.sol";
import {EulerV2SupplyFuse, EulerV2SupplyFuseEnterData} from "../../../contracts/fuses/euler/EulerV2SupplyFuse.sol";
import {EulerV2BalanceFuse} from "../../../contracts/fuses/euler/EulerV2BalanceFuse.sol";
import {EulerV2SwapDeployFuse, EulerV2SwapDeployFuseEnterData, EulerV2SwapDeployFuseExitData} from "../../../contracts/fuses/euler/EulerV2SwapDeployFuse.sol";
import {EulerV2SwapRegistryFuse, EulerV2SwapRegistryFuseEnterData, EulerV2SwapRegistryFuseExitData} from "../../../contracts/fuses/euler/EulerV2SwapRegistryFuse.sol";
import {IEulerV2Swap} from "../../../contracts/fuses/euler/ext/IEulerV2Swap.sol";
import {IEulerV2SwapFactory} from "../../../contracts/fuses/euler/ext/IEulerV2SwapFactory.sol";
import {IEulerV2SwapRegistry} from "../../../contracts/fuses/euler/ext/IEulerV2SwapRegistry.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";

import {PlasmaVault, PlasmaVaultInitData, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {FeeAccount} from "../../../contracts/managers/fee/FeeAccount.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {IporFusionAccessManagerInitializerLibV1, InitializationData, DataForInitialization, PlasmaVaultAddress} from "../../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {PlasmaVaultConfigurator} from "../../utils/PlasmaVaultConfigurator.sol";

/// @title EulerV2SwapRegistryForkTest
/// @notice Base-mainnet (chainId 8453) fork integration tests exercising EulerV2SwapRegistryFuse end-to-end
///         against the live deployed EulerSwap v2 factory, registry, Euler V2 eVaults and EVC. Reuses the
///         same harness pattern as EulerV2SwapForkTest: deploy a real cbETH/WETH pool for the vault
///         sub-account, then drive the registry fuse through the alpha FuseAction path.
contract EulerV2SwapRegistryForkTest is Test {
    // -----------------------------------------------------------------------
    // Deployed EulerSwap v2 + Euler V2 + EVC addresses on Base (chainId 8453)
    // -----------------------------------------------------------------------
    address private constant _EVC = 0x5301c7dD20bD945D2013b48ed0DEE3A284ca8989;
    address private constant _EULERSWAP_FACTORY = 0x6C5f4c239ceD289447737EAB8eEA64523bd9c05E;
    address private constant _EULERSWAP_REGISTRY = 0x35D410A5052c7362eCdD72cFb65651A71adFaf61;

    // Real Base Euler eVaults read from an existing registered EulerSwap pool's static params:
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

    address private _plasmaVault;
    address private _priceOracle;
    address private _accessManager;

    address private _eulerSupplyFuse;
    address private _eulerSwapDeployFuse;
    address private _eulerSwapRegistryFuse;

    address private _eulerAccount; // PlasmaVault XOR subAccount

    // Hook-flag constraint (Uniswap-v4 hook address bits) — identical to EulerV2SwapForkTest.
    uint160 private constant _HOOK_FLAG_MASK = uint160((1 << 14) - 1); // 0x3FFF
    uint160 private constant _HOOK_FLAG_REQUIRED =
        uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 5) | (1 << 3)); // 0x28A8

    function setUp() public {
        // Pinned recent Base block for deterministic state (same as EulerV2SwapForkTest).
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
        _grantMarketSubstratesForEuler();
        _initialDepositIntoPlasmaVault();

        _eulerAccount = EulerFuseLib.generateSubAccountAddress(_plasmaVault, _SUB_ACCOUNT);
    }

    // -----------------------------------------------------------------------
    // Setup helpers (mirrors EulerV2SwapForkTest)
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
        _eulerSwapDeployFuse = address(new EulerV2SwapDeployFuse(IporFusionMarkets.EULER_V2, _EVC, _EULERSWAP_FACTORY));
        _eulerSwapRegistryFuse = address(
            new EulerV2SwapRegistryFuse(IporFusionMarkets.EULER_V2, _EVC, _EULERSWAP_REGISTRY)
        );

        fuses = new address[](3);
        fuses[0] = _eulerSupplyFuse;
        fuses[1] = _eulerSwapDeployFuse;
        fuses[2] = _eulerSwapRegistryFuse;
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

    /// @notice Grants the two Euler-vault substrates (packed EulerSubstrate) for the dedicated sub-account.
    function _grantMarketSubstratesForEuler() private {
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: _EVAULT_CBETH, isCollateral: true, canBorrow: true, subAccounts: _SUB_ACCOUNT})
        );
        substrates[1] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: _EVAULT_WETH, isCollateral: true, canBorrow: true, subAccounts: _SUB_ACCOUNT})
        );

        vm.startPrank(_ATOMIST);
        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(IporFusionMarkets.EULER_V2, substrates);
        vm.stopPrank();
    }

    function _initialDepositIntoPlasmaVault() private {
        deal(_WETH, _USER, 50e18);
        vm.startPrank(_USER);
        ERC20(_WETH).approve(_plasmaVault, 50e18);
        PlasmaVault(_plasmaVault).deposit(50e18, _USER);
        vm.stopPrank();

        deal(_CBETH, _plasmaVault, 20e18);

        uint256[] memory marketIds = new uint256[](2);
        marketIds[0] = IporFusionMarkets.EULER_V2;
        marketIds[1] = IporFusionMarkets.ERC20_VAULT_BALANCE;
        PlasmaVault(_plasmaVault).updateMarketsBalances(marketIds);
    }

    // -----------------------------------------------------------------------
    // Pool deploy helpers (mirrors EulerV2SwapForkTest)
    // -----------------------------------------------------------------------

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
        dp = IEulerV2Swap.DynamicParams({
            equilibriumReserve0: uint112(5e18),
            equilibriumReserve1: uint112(5e18),
            minReserve0: 0,
            minReserve1: 0,
            priceX: uint80(1133090000000000000),
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

    function _execute(FuseAction memory action) private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = action;
        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // EulerV2SwapRegistryFuse tests
    // -----------------------------------------------------------------------

    function _registerAction(address pool) private view returns (FuseAction memory action) {
        EulerV2SwapRegistryFuseEnterData memory data = EulerV2SwapRegistryFuseEnterData({
            pool: pool,
            subAccount: _SUB_ACCOUNT
        });
        action = FuseAction({
            fuse: _eulerSwapRegistryFuse,
            data: abi.encodeWithSignature("enter((address,bytes1))", data)
        });
    }

    function _decommissionAction(address pool) private view returns (FuseAction memory action) {
        EulerV2SwapDeployFuseExitData memory data = EulerV2SwapDeployFuseExitData({pool: pool, subAccount: _SUB_ACCOUNT});
        action = FuseAction({
            fuse: _eulerSwapDeployFuse,
            data: abi.encodeWithSignature("exit((address,bytes1))", data)
        });
    }

    function _unregisterAction(address pool) private view returns (FuseAction memory action) {
        EulerV2SwapRegistryFuseExitData memory data = EulerV2SwapRegistryFuseExitData({
            pool: pool,
            subAccount: _SUB_ACCOUNT
        });
        action = FuseAction({
            fuse: _eulerSwapRegistryFuse,
            data: abi.encodeWithSignature("exit((address,bytes1))", data)
        });
    }

    function testShouldRegisterAndUnregisterPoolInLiveRegistry() public {
        // given
        address pool = _supplyAndDeploy();
        assertEq(
            IEulerV2SwapRegistry(_EULERSWAP_REGISTRY).poolByEulerAccount(_eulerAccount),
            address(0),
            "no pool registered initially"
        );

        // The fuse always registers zero-bond. Fund the vault with native ETH to prove it is never spent
        // (the PlasmaVault can neither source a bond nor receive a refund).
        vm.deal(_plasmaVault, 1 ether);

        // when — register
        _execute(_registerAction(pool));

        assertEq(_plasmaVault.balance, 1 ether, "vault native ETH untouched by registration");

        // then
        assertEq(
            IEulerV2SwapRegistry(_EULERSWAP_REGISTRY).poolByEulerAccount(_eulerAccount),
            pool,
            "pool registered for euler account"
        );

        // The live registry reverts unregisterPool with OldOperatorStillInstalled() while the pool is
        // still authorized as the EVC account operator. Decommission the pool (DeployFuse.exit removes
        // the operator) before unregistering — this mirrors the real teardown order.
        _execute(_decommissionAction(pool));
        assertFalse(
            IEVC(_EVC).isAccountOperatorAuthorized(_eulerAccount, pool),
            "operator removed before unregister"
        );

        // when — unregister
        _execute(_unregisterAction(pool));

        // then
        assertEq(
            IEulerV2SwapRegistry(_EULERSWAP_REGISTRY).poolByEulerAccount(_eulerAccount),
            address(0),
            "pool unregistered for euler account"
        );
    }

    function testShouldRevertUnregisterWhenNoPoolRegistered() public {
        // given — deploy a pool but do NOT register it
        address pool = _supplyAndDeploy();
        assertEq(
            IEulerV2SwapRegistry(_EULERSWAP_REGISTRY).poolByEulerAccount(_eulerAccount),
            address(0),
            "no pool registered"
        );

        // when / then
        bytes memory err = abi.encodeWithSignature(
            "EulerV2SwapRegistryFuseNotRegistered(address)",
            _eulerAccount
        );

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = _unregisterAction(pool);

        vm.startPrank(_ALPHA);
        vm.expectRevert(err);
        PlasmaVault(_plasmaVault).execute(actions);
        vm.stopPrank();
    }
}
