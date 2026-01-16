// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {PlasmaVaultHelper, DeployMinimalPlasmaVaultParams} from "../../test_helpers/PlasmaVaultHelper.sol";
import {PriceOracleMiddlewareHelper, PriceOracleMiddleware} from "../../test_helpers/PriceOracleMiddlewareHelper.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {PlasmaVaultConfigurator} from "../../utils/PlasmaVaultConfigurator.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {TestAddresses} from "../../test_helpers/TestAddresses.sol";
import {IporFusionAccessManagerHelper} from "../../test_helpers/IporFusionAccessManagerHelper.sol";
import {RewardsClaimManager} from "../../../contracts/managers/rewards/RewardsClaimManager.sol";

import {IUniversalRouter} from "../../../contracts/fuses/napier/ext/IUniversalRouter.sol";
import {IPrincipalToken} from "../../../contracts/fuses/napier/ext/IPrincipalToken.sol";
import {ITokiPoolToken} from "../../../contracts/fuses/napier/ext/ITokiPoolToken.sol";
import {Commands} from "../../../contracts/fuses/napier/utils/Commands.sol";
import {Constants} from "../../../contracts/fuses/napier/utils/Constants.sol";
import {PoolKey, Currency} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {NapierSupplyFuse, NapierSupplyFuseEnterData} from "../../../contracts/fuses/napier/NapierSupplyFuse.sol";
import {NapierRedeemFuse, NapierRedeemFuseEnterData} from "../../../contracts/fuses/napier/NapierRedeemFuse.sol";
import {NapierCollectFuse, NapierCollectFuseEnterData} from "../../../contracts/fuses/napier/NapierCollectFuse.sol";
import {NapierUniversalRouterFuse} from "../../../contracts/fuses/napier/NapierUniversalRouterFuse.sol";
import {NapierCombineFuse, NapierCombineFuseEnterData} from "../../../contracts/fuses/napier/NapierCombineFuse.sol";
import {NapierSwapPtFuse, NapierSwapPtFuseData} from "../../../contracts/fuses/napier/NapierSwapPtFuse.sol";
import {NapierSwapYtFuse, NapierSwapYtEnterFuseData, NapierSwapYtExitFuseData} from "../../../contracts/fuses/napier/NapierSwapYtFuse.sol";
import {NapierZapDepositFuse, NapierZapDepositFuseEnterData, NapierZapDepositFuseExitData} from "../../../contracts/fuses/napier/NapierZapDepositFuse.sol";
import {NapierDepositFuse, NapierDepositFuseEnterData, NapierDepositFuseExitData} from "../../../contracts/fuses/napier/NapierDepositFuse.sol";

import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";
import {FeeAccount} from "../../../contracts/managers/fee/FeeAccount.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {Erc4626BalanceFuse} from "../../../contracts/fuses/erc4626/Erc4626BalanceFuse.sol";
import {ZeroBalanceFuse} from "../../../contracts/fuses/ZeroBalanceFuse.sol";
import {PlasmaVault, PlasmaVaultInitData, MarketBalanceFuseConfig, FuseAction, FeeConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {IporFusionAccessManagerInitializerLibV1, InitializationData, DataForInitialization, PlasmaVaultAddress} from "../../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {IBorrowing} from "../../../contracts/fuses/euler/ext/IBorrowing.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {NapierHelper, ITokiHook, ITokiOracle} from "./NapierHelper.sol";
import {LogExpMath} from "@pendle/core-v2/contracts/core/libraries/math/LogExpMath.sol";
import {NapierPtLpPriceFeed} from "../../../contracts/price_oracle/price_feed/NapierPtLpPriceFeed.sol";
import {ERC4626PriceFeed} from "../../../contracts/price_oracle/price_feed/ERC4626PriceFeed.sol";
import {ApproximationParams} from "../../../contracts/fuses/napier/ext/ApproximationParams.sol";
import {NapierConstants} from "./NapierConstants.sol";

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface INapierFactory {
    function isValidImplementation(
        NapierHelper.ModuleIndex moduleType,
        address implementation
    ) external view returns (bool);
}

interface IResolver {
    function scale() external view returns (uint256);
}

interface IChainlinkOracleFactory {
    function clone(
        address implementation,
        bytes calldata args,
        bytes calldata initializationData
    ) external returns (address instance);
}

contract NapierSupplyFuseTest is Test {
    using PriceOracleMiddlewareHelper for PriceOracleMiddleware;
    using PlasmaVaultHelper for PlasmaVault;
    using IporFusionAccessManagerHelper for IporFusionAccessManager;

    address private constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address private constant POOL_MANAGER = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;

    ///  assets
    address private constant GAUNTLET_USDC_PRIME = 0x7c574174DA4b2be3f705c6244B4BfA0815a8B3Ed;
    address private constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    ///  Plasma Vault tests config
    address private ATOMIST = makeAddr("atomist");
    address private ALPHA = makeAddr("alpha");
    address private PRICE_ORACLE_MIDDLEWARE_MANAGER = makeAddr("priceOracleMiddlewareManager");
    address private USER = makeAddr("user");
    address private ALICE = makeAddr("alice");

    uint256 private constant LP_TWAP_WINDOW = 1 hours;

    ///  Napier V2 Toki pool
    address private pool;
    address private principalToken;
    uint256 private expiry;

    /// Plasma Vault
    PlasmaVault private _plasmaVault;
    address private _priceOracle;
    IporFusionAccessManager private _accessManager;
    PriceOracleMiddleware private _priceOracleMiddleware;

    // Price feeds
    address private _ptLinarOracle;
    address private _napierPtPriceFeed;
    address private _napierLpPriceFeed;
    address private _lpTwapOracle;

    // Fuses
    address private _supplyFuse;
    address private _redeemFuse;
    address private _combineFuse;
    address private _collectFuse;
    address private _swapPtFuse;
    address private _swapYtFuse;
    address private _zapDepositFuse;
    address private _depositFuse;

    function setUp() external {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 399992224);

        vm.label(POOL_MANAGER, "poolManager");
        vm.label(PERMIT2, "permit2");
        vm.label(NapierConstants.ARB_UNIVERSAL_ROUTER, "router");
        vm.label(NapierConstants.ARB_CHAINLINK_COMPT_ORACLE_FACTORY, "tokiChainlinkFactory");
        vm.label(NapierConstants.ARB_TOKI_LINEAR_PRICE_ORACLE_IMPL, "linearPriceOracle");
        vm.label(NapierConstants.ARB_TOKI_TWAP_ORACLE_IMPL, "twapOracle");
        vm.label(GAUNTLET_USDC_PRIME, "gauntletUSDC");
        vm.label(USDC, "USDC");
        vm.label(WETH, "WETH");

        // Deploy price oracle middleware
        vm.startPrank(ATOMIST);
        _priceOracleMiddleware = PriceOracleMiddlewareHelper.getArbitrumPriceOracleMiddleware();
        vm.stopPrank();

        DeployMinimalPlasmaVaultParams memory params = DeployMinimalPlasmaVaultParams({
            underlyingToken: USDC,
            underlyingTokenName: "USDC",
            priceOracleMiddleware: address(_priceOracleMiddleware),
            atomist: ATOMIST
        });

        vm.startPrank(ATOMIST);
        (_plasmaVault, ) = PlasmaVaultHelper.deployMinimalPlasmaVault(params);

        _accessManager = _plasmaVault.accessManagerOf();

        // Grant OWNER_ROLE to ATOMIST BEFORE setupInitRoles
        // setupInitRoles calls initialize() which revokes ADMIN_ROLE from ATOMIST
        // So we need to grant OWNER_ROLE while ATOMIST still has ADMIN_ROLE
        _accessManager.grantRole(Roles.OWNER_ROLE, ATOMIST, 0);

        _accessManager.setupInitRoles(
            _plasmaVault,
            address(0x123),
            address(new RewardsClaimManager(address(_accessManager), address(_plasmaVault)))
        );

        // Now ATOMIST has OWNER_ROLE (from before initialization) and can grant themselves ATOMIST_ROLE
        _accessManager.grantRole(Roles.ATOMIST_ROLE, ATOMIST, 0);

        // Grant FUSE_MANAGER_ROLE to ATOMIST so it can add fuses and substrates
        _accessManager.grantRole(Roles.FUSE_MANAGER_ROLE, ATOMIST, 0);

        // Grant ALPHA_ROLE to ALPHA so it can call execute()
        _accessManager.grantRole(Roles.ALPHA_ROLE, ALPHA, 0);
        vm.stopPrank();

        vm.label(address(_plasmaVault), "plasma");
        vm.label(address(_priceOracleMiddleware), "priceOracleMiddleware");
        vm.label(address(_accessManager), "accessManager");

        _setupNapierPool();
        _setupNapierMarket();
        _initialDepositIntoPlasmaVault();
    }

    function _setupNapierPool() private {
        vm.startPrank(ATOMIST);

        uint256 scalarRoot = 16240223350842364143;
        int256 initialAnchor = 1098960161431879138;

        // Prepare Factory Suite
        NapierHelper.FactorySuite memory suite = NapierHelper.FactorySuite({
            accessManagerImplementation: NapierConstants.ARB_ACCESS_MANAGER_IMPLEMENTATION,
            ptBlueprint: NapierConstants.ARB_PT_BLUEPRINT,
            resolverBlueprint: NapierConstants.ARB_ERC4626_RESOLVER_BLUEPRINT,
            poolDeployerImplementation: NapierConstants.ARB_TOKI_POOL_DEPLOYER_IMPLEMENTATION,
            poolArgs: abi.encode(
                NapierHelper.TokiPoolDeploymentParams({
                    salt: bytes32(0),
                    hook: NapierConstants.ARB_TOKI_HOOK,
                    pausableFlags: 0,
                    hookParams: NapierHelper.encodeHookParams(scalarRoot, initialAnchor),
                    hooklet: address(0),
                    hookletParams: "",
                    vault0: address(0),
                    vault1: address(0),
                    vault0Params: NapierHelper.DEFAULT_VAULT_PARAMS,
                    vault1Params: NapierHelper.DEFAULT_VAULT_PARAMS,
                    liquidityTokenImplementation: NapierConstants.ARB_LIQUIDITY_TOKEN_IMPLEMENTATION,
                    liquidityTokenImmutableData: ""
                })
            ),
            resolverArgs: abi.encode(GAUNTLET_USDC_PRIME)
        });

        uint128 ammFeeParams = uint128((uint256(LogExpMath.ln(1.01e18)) * Constants.TOKI_SWAP_FEE_SCALE) / 1e18);

        NapierHelper.FactoryModuleParam[] memory modules = new NapierHelper.FactoryModuleParam[](2);
        modules[0] = NapierHelper.FactoryModuleParam({
            moduleType: NapierHelper.ModuleIndex.FEE_MODULE_INDEX,
            implementation: NapierConstants.ARB_FEE_MODULE_IMPLEMENTATION,
            immutableData: abi.encode(
                NapierHelper.packFeePcts(NapierConstants.ARB_NAPIER_FACTORY, 10, 1000, 0, Constants.BASIS_POINTS)
            )
        });
        modules[1] = NapierHelper.FactoryModuleParam({
            moduleType: NapierHelper.ModuleIndex.POOL_FEE_MODULE_INDEX,
            implementation: NapierConstants.ARB_POOL_FEE_MODULE_IMPLEMENTATION,
            immutableData: abi.encode(
                NapierHelper.packFeePctsPool(NapierConstants.ARB_NAPIER_FACTORY, ammFeeParams, 200)
            )
        });

        expiry = block.timestamp + 365 days;
        uint256 desiredImpliedRate = 0.05e18;

        // Convert USDC to gauntletUSDC shares via ERC4626 deposit
        // Deposit enough USDC to get at least amount0 gauntletUSDC shares
        deal(USDC, ATOMIST, 100_000e6);
        ERC20(USDC).approve(GAUNTLET_USDC_PRIME, 100_000e6);
        uint256 amount0 = IERC4626(GAUNTLET_USDC_PRIME).deposit(100_000e6, ATOMIST);

        // Approve gauntletUSDC to Permit2
        ERC20(GAUNTLET_USDC_PRIME).approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(
            GAUNTLET_USDC_PRIME,
            NapierConstants.ARB_UNIVERSAL_ROUTER,
            type(uint160).max,
            uint48(block.timestamp + 365 days)
        );

        // Mine salt to ensure PT address > underlying address
        bytes32 salt = NapierHelper.minePrincipalTokenSalt(
            GAUNTLET_USDC_PRIME,
            NapierConstants.ARB_PT_BLUEPRINT,
            NapierConstants.ARB_NAPIER_FACTORY,
            ATOMIST,
            NapierConstants.ARB_UNIVERSAL_ROUTER
        );

        // Deploy pool and add initial liquidity
        (address deployedPt, address deployedPool) = NapierHelper.deployTokiPoolAndAddLiquidity({
            router: NapierConstants.ARB_UNIVERSAL_ROUTER,
            suite: suite,
            modules: modules,
            expiry: expiry,
            curator: ATOMIST,
            salt: salt,
            amount0: amount0,
            receiver: ATOMIST,
            desiredImpliedRate: desiredImpliedRate,
            liquidityMinimum: 0,
            deadline: block.timestamp + 1 hours
        });

        principalToken = deployedPt;
        pool = deployedPool;
        vm.stopPrank();

        vm.label(pool, "pool");
        vm.label(principalToken, "principalToken");

        PoolKey memory poolKey = ITokiPoolToken(pool).i_poolKey();
        (bool needsCapacityIncrease, uint16 cardinalityRequired, ) = ITokiOracle(NapierConstants.ARB_TOKI_ORACLE)
            .checkTwapReadiness(pool, uint32(LP_TWAP_WINDOW));

        // Increase cardinality for LP Twap Oracle dependency
        if (needsCapacityIncrease) {
            ITokiHook(address(poolKey.hooks)).increaseObservationsCardinalityNext(poolKey, cardinalityRequired);
        }

        // Record some historical price data for oracle
        vm.startPrank(ALICE);
        deal(GAUNTLET_USDC_PRIME, ALICE, 1000 * 10 ** ERC20(GAUNTLET_USDC_PRIME).decimals());

        ERC20(GAUNTLET_USDC_PRIME).approve(principalToken, type(uint256).max);
        IPrincipalToken(principalToken).supply(100 * 10 ** ERC20(GAUNTLET_USDC_PRIME).decimals(), ALICE);

        ERC20(GAUNTLET_USDC_PRIME).approve(PERMIT2, type(uint256).max);
        ERC20(principalToken).approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(
            GAUNTLET_USDC_PRIME,
            NapierConstants.ARB_UNIVERSAL_ROUTER,
            type(uint160).max,
            type(uint48).max
        );
        IPermit2(PERMIT2).approve(
            principalToken,
            NapierConstants.ARB_UNIVERSAL_ROUTER,
            type(uint160).max,
            type(uint48).max
        );

        NapierHelper.swap({
            router: NapierConstants.ARB_UNIVERSAL_ROUTER,
            poolKey: poolKey,
            zeroForOne: false,
            amount: 2 * 10 ** ERC20(principalToken).decimals(),
            timeJump: 3 minutes
        });

        NapierHelper.swap({
            router: NapierConstants.ARB_UNIVERSAL_ROUTER,
            poolKey: poolKey,
            zeroForOne: false,
            amount: 10 ** ERC20(principalToken).decimals(),
            timeJump: 15 minutes
        });

        NapierHelper.swap({
            router: NapierConstants.ARB_UNIVERSAL_ROUTER,
            poolKey: poolKey,
            zeroForOne: false,
            amount: 10 ** ERC20(principalToken).decimals(),
            timeJump: 15 minutes
        });

        NapierHelper.swap({
            router: NapierConstants.ARB_UNIVERSAL_ROUTER,
            poolKey: poolKey,
            zeroForOne: true,
            amount: 10 ** ERC20(GAUNTLET_USDC_PRIME).decimals(),
            timeJump: 14 minutes
        });

        NapierHelper.swap({
            router: NapierConstants.ARB_UNIVERSAL_ROUTER,
            poolKey: poolKey,
            zeroForOne: true,
            amount: 10 ** ERC20(GAUNTLET_USDC_PRIME).decimals(),
            timeJump: 17 minutes
        });

        vm.warp(block.timestamp + 30 minutes);

        vm.stopPrank();

        // Check if oldest data is available
        (, , bool hasOldestData) = ITokiOracle(NapierConstants.ARB_TOKI_ORACLE).checkTwapReadiness(
            pool,
            uint32(LP_TWAP_WINDOW)
        );

        require(hasOldestData, "Oldest data not available after capacity increase");
    }

    function _setupNapierMarket() private {
        vm.startPrank(ATOMIST);

        // Add substrates - pool, PT, YT, router, underlying (ERC4626), and base asset must be granted
        IPrincipalToken pt = IPrincipalToken(principalToken);
        address yt = pt.i_yt();
        bytes32[] memory substrates = new bytes32[](5);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(pool);
        substrates[1] = PlasmaVaultConfigLib.addressToBytes32(principalToken);
        substrates[2] = PlasmaVaultConfigLib.addressToBytes32(yt);
        substrates[3] = PlasmaVaultConfigLib.addressToBytes32(pt.underlying());
        substrates[4] = PlasmaVaultConfigLib.addressToBytes32(pt.i_asset());

        bytes32[] memory erc20Substrates = new bytes32[](2);
        erc20Substrates[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);
        erc20Substrates[1] = PlasmaVaultConfigLib.addressToBytes32(WETH);

        _plasmaVault.addSubstratesToMarket(IporFusionMarkets.NAPIER, substrates);
        _plasmaVault.addSubstratesToMarket(IporFusionMarkets.ERC20_VAULT_BALANCE, erc20Substrates);

        // Add gauntletUSDC as substrate for ERC4626_0001 market
        bytes32[] memory erc4626Substrates = new bytes32[](1);
        erc4626Substrates[0] = PlasmaVaultConfigLib.addressToBytes32(GAUNTLET_USDC_PRIME);
        _plasmaVault.addSubstratesToMarket(IporFusionMarkets.ERC4626_0001, erc4626Substrates);

        // Add dependency graph
        uint256[] memory dependencies = new uint256[](1);
        dependencies[0] = IporFusionMarkets.ERC20_VAULT_BALANCE;
        _plasmaVault.addDependencyBalanceGraphs(IporFusionMarkets.NAPIER, dependencies);
        vm.stopPrank();

        // Configure price feeds for assets if needed.
        // By default, on Ethereum the system uses Chainlink registry for price feeds.
        // On all chains, it uses a general priceOracleMiddleware predefined by IPOR DAO.
        // However, any price feed can be overridden in the PriceOracleMiddlewareManager.
        _ptLinarOracle = IChainlinkOracleFactory(NapierConstants.ARB_CHAINLINK_COMPT_ORACLE_FACTORY).clone(
            NapierConstants.ARB_TOKI_LINEAR_PRICE_ORACLE_IMPL,
            abi.encode(pool, principalToken, USDC, 100), // liquidityToken, base, quote, discountRatePerYearBps
            ""
        );
        _lpTwapOracle = IChainlinkOracleFactory(NapierConstants.ARB_CHAINLINK_COMPT_ORACLE_FACTORY).clone(
            NapierConstants.ARB_TOKI_TWAP_ORACLE_IMPL,
            abi.encode(pool, pool, USDC, LP_TWAP_WINDOW), // liquidityToken, base, quote, twapWindow
            ""
        );
        _napierPtPriceFeed = address(new NapierPtLpPriceFeed(address(_priceOracleMiddleware), _ptLinarOracle));
        _napierLpPriceFeed = address(new NapierPtLpPriceFeed(address(_priceOracleMiddleware), _lpTwapOracle));
        address[] memory assets = new address[](2);
        assets[0] = principalToken;
        assets[1] = pool;
        address[] memory sources = new address[](2); // Price feed contract address
        sources[0] = _napierPtPriceFeed;
        sources[1] = _napierLpPriceFeed;
        vm.startPrank(_priceOracleMiddleware.owner());
        _priceOracleMiddleware.setAssetsPricesSources(assets, sources);
        vm.stopPrank();

        // Add fuses
        _supplyFuse = address(new NapierSupplyFuse(IporFusionMarkets.NAPIER, NapierConstants.ARB_UNIVERSAL_ROUTER));
        _redeemFuse = address(new NapierRedeemFuse(IporFusionMarkets.NAPIER, NapierConstants.ARB_UNIVERSAL_ROUTER));
        _collectFuse = address(new NapierCollectFuse(IporFusionMarkets.NAPIER));
        _combineFuse = address(new NapierCombineFuse(IporFusionMarkets.NAPIER, NapierConstants.ARB_UNIVERSAL_ROUTER));
        _swapPtFuse = address(new NapierSwapPtFuse(IporFusionMarkets.NAPIER, NapierConstants.ARB_UNIVERSAL_ROUTER));
        _swapYtFuse = address(new NapierSwapYtFuse(IporFusionMarkets.NAPIER, NapierConstants.ARB_UNIVERSAL_ROUTER));
        _zapDepositFuse = address(
            new NapierZapDepositFuse(IporFusionMarkets.NAPIER, NapierConstants.ARB_UNIVERSAL_ROUTER)
        );
        _depositFuse = address(new NapierDepositFuse(IporFusionMarkets.NAPIER, NapierConstants.ARB_UNIVERSAL_ROUTER));

        vm.startPrank(ATOMIST);
        address[] memory fuses = new address[](8);
        fuses[0] = _supplyFuse;
        fuses[1] = _redeemFuse;
        fuses[2] = _collectFuse;
        fuses[3] = _combineFuse;
        fuses[4] = _swapPtFuse;
        fuses[5] = _swapYtFuse;
        fuses[6] = _zapDepositFuse;
        fuses[7] = _depositFuse;
        _plasmaVault.addFusesToVault(fuses);

        // Add balance fuses
        ERC20BalanceFuse erc20Balance = new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE);
        _plasmaVault.addBalanceFusesToVault(IporFusionMarkets.ERC20_VAULT_BALANCE, address(erc20Balance));

        // Add ERC4626BalanceFuse for ERC4626_0001 market (tracks gauntletUSDC balance)
        Erc4626BalanceFuse erc4626Balance = new Erc4626BalanceFuse(IporFusionMarkets.ERC4626_0001);
        _plasmaVault.addBalanceFusesToVault(IporFusionMarkets.ERC4626_0001, address(erc4626Balance));

        // Add ZeroBalanceFuse for NAPIER market (balance is tracked through ERC20_VAULT_BALANCE dependency)
        ZeroBalanceFuse napierBalance = new ZeroBalanceFuse(IporFusionMarkets.NAPIER);
        _plasmaVault.addBalanceFusesToVault(IporFusionMarkets.NAPIER, address(napierBalance));

        // Convert vault from private to public mode.
        // By default, the vault starts in private mode, which blocks deposits and share transfers.
        // To enable these operations for testing, convert the vault to public mode.
        // This can be done by accounts with ATOMIST_ROLE.
        //
        // Example: Convert vault to public vault:
        vm.startPrank(ATOMIST);
        PlasmaVaultGovernance(address(_plasmaVault)).convertToPublicVault();
        vm.stopPrank();

        // Additionally, enable share transfers (required for public vault operation):
        vm.startPrank(ATOMIST);
        PlasmaVaultGovernance(address(_plasmaVault)).enableTransferShares();
        vm.stopPrank();
    }

    function _initialDepositIntoPlasmaVault() private {
        deal(USER, 100_000e18);
        deal(USDC, USER, 100_000e6);

        vm.startPrank(USER);
        uint256 usdcAmount = 1_000e6;
        ERC20(USDC).approve(address(_plasmaVault), usdcAmount);
        PlasmaVault(_plasmaVault).deposit(usdcAmount, USER);
        vm.stopPrank();

        vm.startPrank(USER);
        ERC20(USDC).approve(GAUNTLET_USDC_PRIME, 1_000e6);
        IERC4626(GAUNTLET_USDC_PRIME).deposit(1_000e6, address(_plasmaVault));
        vm.stopPrank();

        /// This transfer is only for testing purposes
        vm.startPrank(USER);
        deal(WETH, USER, 100e18);
        ERC20(WETH).transfer(address(_plasmaVault), 100e18);
        vm.stopPrank();

        // Note: updateMarketsBalances is called automatically by execute() function
        // so we don't need to call it manually in setUp
    }

    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    /*                       SUPPLY TESTS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_Supply_UnderlyingToken() public {
        uint256 amountIn = 10 ** ERC20(USDC).decimals();
        NapierSupplyFuseEnterData memory data = NapierSupplyFuseEnterData({
            principalToken: IPrincipalToken(principalToken),
            tokenIn: USDC,
            amountIn: amountIn
        });

        _test_Supply(data);
    }

    function test_Supply_AssetToken() public {
        uint256 amountIn = 10 ** ERC20(GAUNTLET_USDC_PRIME).decimals();
        NapierSupplyFuseEnterData memory data = NapierSupplyFuseEnterData({
            principalToken: IPrincipalToken(principalToken),
            tokenIn: GAUNTLET_USDC_PRIME,
            amountIn: amountIn
        });

        _test_Supply(data);
    }

    function test_Supply_RevertWhen_TokenNotGranted() public {
        address badToken = makeAddr("badToken");

        uint256 amountIn = 10 ** ERC20(USDC).decimals();
        NapierSupplyFuseEnterData memory data = NapierSupplyFuseEnterData({
            principalToken: IPrincipalToken(badToken),
            tokenIn: USDC,
            amountIn: amountIn
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({fuse: _supplyFuse, data: abi.encodeCall(NapierSupplyFuse.enter, data)});

        vm.prank(ALPHA);
        vm.expectRevert(NapierUniversalRouterFuse.NapierFuseIInvalidToken.selector);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    function testFuzz_Supply_RevertWhen_TokenInNotGranted(address tokenIn) public {
        IPrincipalToken pt = IPrincipalToken(principalToken);
        address underlying = pt.underlying();
        address asset = pt.i_asset();

        vm.assume(tokenIn != underlying && tokenIn != asset);

        NapierSupplyFuseEnterData memory data = NapierSupplyFuseEnterData({
            principalToken: pt,
            tokenIn: tokenIn,
            amountIn: 1298937
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({fuse: _supplyFuse, data: abi.encodeCall(NapierSupplyFuse.enter, data)});

        vm.prank(ALPHA);
        vm.expectRevert(NapierUniversalRouterFuse.NapierFuseIInvalidToken.selector);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    function _test_Supply(NapierSupplyFuseEnterData memory data) internal {
        uint256 ptBalanceBefore = data.principalToken.balanceOf(address(_plasmaVault));

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({fuse: _supplyFuse, data: abi.encodeCall(NapierSupplyFuse.enter, data)});

        uint256 preview;
        if (data.tokenIn == data.principalToken.underlying()) {
            // tokenIn is the ERC4626 vault shares, supply directly
            preview = data.principalToken.previewSupply(data.amountIn);
        } else if (data.tokenIn == data.principalToken.i_asset()) {
            // tokenIn is the underlying asset (e.g., USDC), convert via ERC4626 vault first
            address underlyingToken = data.principalToken.underlying();
            uint256 shares = IERC4626(underlyingToken).previewDeposit(data.amountIn);
            preview = data.principalToken.previewSupply(shares);
        } else {
            revert("Invalid token");
        }

        vm.prank(ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);

        // Then
        uint256 ptBalanceAfter = data.principalToken.balanceOf(address(_plasmaVault));
        assertApproxEqAbs(ptBalanceAfter, ptBalanceBefore + preview, 2, "PT balance");
    }

    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    /*                       REDEEM TESTS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_Redeem_UnderlyingToken() public {
        IPrincipalToken pt = IPrincipalToken(principalToken);

        _test_Supply(
            NapierSupplyFuseEnterData({principalToken: pt, tokenIn: USDC, amountIn: 10 ** ERC20(USDC).decimals()})
        );

        // Get the actual PT balance after supply
        uint256 ptBalance = pt.balanceOf(address(_plasmaVault));

        // Fast-forward time to after maturity for redemption
        vm.warp(pt.maturity() + 1);

        // Now redeem PTs for underlying token
        NapierRedeemFuseEnterData memory data = NapierRedeemFuseEnterData({
            principalToken: pt,
            tokenOut: GAUNTLET_USDC_PRIME,
            principals: ptBalance
        });
        _test_Redeem(data);
    }

    function test_Redeem_AssetToken() public {
        IPrincipalToken pt = IPrincipalToken(principalToken);

        _test_Supply(
            NapierSupplyFuseEnterData({
                principalToken: pt,
                tokenIn: GAUNTLET_USDC_PRIME,
                amountIn: 10 ** ERC20(GAUNTLET_USDC_PRIME).decimals()
            })
        );

        // Get the actual PT balance after supply
        uint256 ptBalance = pt.balanceOf(address(_plasmaVault));

        // Fast-forward time to after maturity for redemption
        vm.warp(pt.maturity() + 1);

        NapierRedeemFuseEnterData memory data = NapierRedeemFuseEnterData({
            principalToken: pt,
            tokenOut: USDC,
            principals: ptBalance
        });
        _test_Redeem(data);
    }

    function testFuzz_Redeem_RevertWhen_TokenOutNotGranted(address tokenOut) public {
        IPrincipalToken pt = IPrincipalToken(principalToken);
        address underlying = pt.underlying();
        address asset = pt.i_asset();
        vm.assume(tokenOut != underlying && tokenOut != asset);

        vm.warp(pt.maturity() + 1);

        NapierRedeemFuseEnterData memory data = NapierRedeemFuseEnterData({
            principalToken: pt,
            tokenOut: tokenOut,
            principals: 1298937
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({fuse: _redeemFuse, data: abi.encodeCall(NapierRedeemFuse.enter, data)});

        vm.prank(ALPHA);
        vm.expectRevert(NapierUniversalRouterFuse.NapierFuseIInvalidToken.selector);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    function _test_Redeem(NapierRedeemFuseEnterData memory data) internal {
        uint256 tokenOutBalanceBefore = ERC20(data.tokenOut).balanceOf(address(_plasmaVault));

        FuseAction[] memory redeemActions = new FuseAction[](1);
        redeemActions[0] = FuseAction({fuse: _redeemFuse, data: abi.encodeCall(NapierRedeemFuse.enter, data)});

        uint256 preview;
        address underlying = data.principalToken.underlying();
        address asset = data.principalToken.i_asset();

        if (data.tokenOut == underlying) {
            // tokenOut is the ERC4626 vault shares, redeem directly
            preview = data.principalToken.previewRedeem(data.principals);
        } else if (data.tokenOut == asset) {
            // tokenOut is the underlying asset (e.g., USDC), convert via ERC4626 vault first
            // Step 1: Redeem PT for ERC4626 vault shares
            uint256 shares = data.principalToken.previewRedeem(data.principals);
            // Step 2: Redeem ERC4626 vault shares for underlying asset
            preview = IERC4626(underlying).previewRedeem(shares);
        } else {
            revert("Invalid token");
        }

        vm.prank(ALPHA);
        PlasmaVault(_plasmaVault).execute(redeemActions);

        // Then
        uint256 tokenOutBalanceAfter = ERC20(data.tokenOut).balanceOf(address(_plasmaVault));
        assertApproxEqAbs(tokenOutBalanceAfter, tokenOutBalanceBefore + preview, 2, "Token out balance");
    }

    function test_Redeem_RevertWhen_TokenNotGranted() public {
        address badToken = makeAddr("badToken");

        uint256 amountIn = 10 ** ERC20(USDC).decimals();
        NapierRedeemFuseEnterData memory data = NapierRedeemFuseEnterData({
            principalToken: IPrincipalToken(badToken),
            tokenOut: USDC,
            principals: amountIn
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({fuse: _redeemFuse, data: abi.encodeCall(NapierRedeemFuse.enter, data)});

        vm.prank(ALPHA);
        vm.expectRevert(NapierUniversalRouterFuse.NapierFuseIInvalidToken.selector);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    /*                       COLLECT TESTS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_Collect() public {
        IPrincipalToken pt = IPrincipalToken(principalToken);

        // First, supply some PTs so the vault has a position to collect from
        _test_Supply(
            NapierSupplyFuseEnterData({principalToken: pt, tokenIn: USDC, amountIn: 10 ** ERC20(USDC).decimals()})
        );

        uint256 mockScale = (IResolver(pt.i_resolver()).scale() * 15) / 10;
        vm.mockCall(address(pt.i_resolver()), abi.encodeWithSelector(IResolver.scale.selector), abi.encode(mockScale));

        uint256 balanceBefore = ERC20(GAUNTLET_USDC_PRIME).balanceOf(address(_plasmaVault));
        uint256 preview = pt.previewCollect(address(_plasmaVault));

        // Prepare collect action
        NapierCollectFuseEnterData memory data = NapierCollectFuseEnterData({principalToken: pt});

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({fuse: _collectFuse, data: abi.encodeCall(NapierCollectFuse.enter, data)});

        // Expect the event to be emitted
        vm.expectEmit(true, true, true, false);
        emit NapierCollectFuse.NapierCollectFuseEnter(
            _collectFuse,
            address(pt),
            preview,
            new IPrincipalToken.TokenReward[](0)
        );

        // Execute collect
        vm.prank(ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);

        assertApproxEqAbs(
            ERC20(GAUNTLET_USDC_PRIME).balanceOf(address(_plasmaVault)),
            balanceBefore + preview,
            2,
            "Underlying balance"
        );
    }

    function test_Collect_RevertWhen_TokenNotGranted() public {
        address badToken = makeAddr("badToken");

        NapierCollectFuseEnterData memory data = NapierCollectFuseEnterData({
            principalToken: IPrincipalToken(badToken)
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({fuse: _collectFuse, data: abi.encodeCall(NapierCollectFuse.enter, data)});

        vm.prank(ALPHA);
        vm.expectRevert(NapierUniversalRouterFuse.NapierFuseIInvalidToken.selector);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    /*                       COMBINE TESTS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_Combine_UnderlyingToken() public {
        IPrincipalToken pt = IPrincipalToken(principalToken);
        address yt = pt.i_yt();

        // Arrange: ensure the vault holds PTs and YTs by supplying underlying
        _test_Supply(
            NapierSupplyFuseEnterData({principalToken: pt, tokenIn: USDC, amountIn: 10 ** ERC20(USDC).decimals()})
        );

        uint256 ptBalanceBefore = pt.balanceOf(address(_plasmaVault));
        uint256 ytBalanceBefore = ERC20(yt).balanceOf(address(_plasmaVault));

        uint256 principals = ptBalanceBefore < ytBalanceBefore ? ptBalanceBefore : ytBalanceBefore;
        assertGt(principals, 0, "Principals must be positive");

        NapierCombineFuseEnterData memory data = NapierCombineFuseEnterData({
            principalToken: pt,
            tokenOut: GAUNTLET_USDC_PRIME,
            principals: principals
        });

        _test_Combine(data);
    }

    function test_Combine_AssetToken() public {
        IPrincipalToken pt = IPrincipalToken(principalToken);
        address yt = pt.i_yt();

        // Arrange: ensure the vault holds PTs and YTs by supplying underlying
        _test_Supply(
            NapierSupplyFuseEnterData({
                principalToken: pt,
                tokenIn: GAUNTLET_USDC_PRIME,
                amountIn: 10 ** ERC20(GAUNTLET_USDC_PRIME).decimals()
            })
        );

        uint256 ptBalanceBefore = pt.balanceOf(address(_plasmaVault));
        uint256 ytBalanceBefore = ERC20(yt).balanceOf(address(_plasmaVault));

        uint256 principals = ptBalanceBefore < ytBalanceBefore ? ptBalanceBefore : ytBalanceBefore;
        assertGt(principals, 0, "Principals must be positive");

        NapierCombineFuseEnterData memory data = NapierCombineFuseEnterData({
            principalToken: pt,
            tokenOut: pt.i_asset(),
            principals: principals
        });

        _test_Combine(data);
    }

    function _test_Combine(NapierCombineFuseEnterData memory data) internal {
        IPrincipalToken pt = data.principalToken;
        address yt = pt.i_yt();

        FuseAction[] memory combineActions = new FuseAction[](1);
        combineActions[0] = FuseAction({fuse: _combineFuse, data: abi.encodeCall(NapierCombineFuse.enter, data)});

        uint256 ptBalanceBefore = pt.balanceOf(address(_plasmaVault));
        uint256 ytBalanceBefore = ERC20(yt).balanceOf(address(_plasmaVault));
        uint256 tokenOutBalanceBefore = ERC20(data.tokenOut).balanceOf(address(_plasmaVault));

        uint256 preview;
        if (data.tokenOut == pt.underlying()) {
            preview = pt.previewCombine(data.principals);
        } else if (data.tokenOut == pt.i_asset()) {
            uint256 shares = pt.previewCombine(data.principals);
            preview = IERC4626(GAUNTLET_USDC_PRIME).previewRedeem(shares);
        } else {
            revert("Invalid token");
        }

        vm.prank(ALPHA);
        PlasmaVault(_plasmaVault).execute(combineActions);

        uint256 ptBalanceAfter = pt.balanceOf(address(_plasmaVault));
        uint256 ytBalanceAfter = ERC20(yt).balanceOf(address(_plasmaVault));
        uint256 tokenOutBalanceAfter = ERC20(data.tokenOut).balanceOf(address(_plasmaVault));

        assertEq(ptBalanceBefore - ptBalanceAfter, data.principals, "PT principals consumed");
        assertEq(ytBalanceBefore - ytBalanceAfter, data.principals, "YT principals consumed");
        assertEq(tokenOutBalanceAfter, tokenOutBalanceBefore + preview, "Token out balance should increase");
    }

    function test_Combine_RevertWhen_TokenNotGranted() public {
        address badToken = makeAddr("badToken");

        NapierCombineFuseEnterData memory data = NapierCombineFuseEnterData({
            principalToken: IPrincipalToken(badToken),
            tokenOut: USDC,
            principals: 1000
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({fuse: _combineFuse, data: abi.encodeCall(NapierCombineFuse.enter, data)});

        vm.prank(ALPHA);
        vm.expectRevert(NapierUniversalRouterFuse.NapierFuseIInvalidToken.selector);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    /*                       SWAP PT TESTS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Test buying PT with underlying token via swap
    function test_SwapPt_Enter() public {
        // Ensure vault has underlying token to swap
        uint256 amountIn = 100 * 10 ** ERC20(GAUNTLET_USDC_PRIME).decimals();
        deal(GAUNTLET_USDC_PRIME, address(_plasmaVault), amountIn);

        uint256 underlyingBalanceBefore = ERC20(GAUNTLET_USDC_PRIME).balanceOf(address(_plasmaVault));
        uint256 ptBalanceBefore = IPrincipalToken(principalToken).balanceOf(address(_plasmaVault));

        NapierSwapPtFuseData memory data = NapierSwapPtFuseData({
            pool: ITokiPoolToken(pool),
            amountIn: amountIn,
            minimumAmount: 0
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({fuse: _swapPtFuse, data: abi.encodeCall(NapierSwapPtFuse.enter, data)});

        vm.prank(ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);

        uint256 underlyingBalanceAfter = ERC20(GAUNTLET_USDC_PRIME).balanceOf(address(_plasmaVault));
        assertEq(underlyingBalanceAfter, underlyingBalanceBefore - amountIn, "Underlying balance");

        uint256 ptBalanceAfter = IPrincipalToken(principalToken).balanceOf(address(_plasmaVault));
        assertGt(ptBalanceAfter, ptBalanceBefore, "PT balance");
    }

    /// @notice Test selling PT for underlying token via swap
    function test_SwapPt_Exit() public {
        // First, supply some PTs so the vault has PTs to swap
        _test_Supply(
            NapierSupplyFuseEnterData({
                principalToken: IPrincipalToken(principalToken),
                tokenIn: USDC,
                amountIn: 1000 * 10 ** ERC20(USDC).decimals()
            })
        );

        uint256 ptBalance = IPrincipalToken(principalToken).balanceOf(address(_plasmaVault));
        assertGt(ptBalance, 0, "Vault should have PT balance");

        uint256 underlyingBalanceBefore = ERC20(GAUNTLET_USDC_PRIME).balanceOf(address(_plasmaVault));

        uint256 amountIn = 43 * 10 ** ERC20(principalToken).decimals();
        NapierSwapPtFuseData memory data = NapierSwapPtFuseData({
            pool: ITokiPoolToken(pool),
            amountIn: amountIn,
            minimumAmount: 0
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({fuse: _swapPtFuse, data: abi.encodeCall(NapierSwapPtFuse.exit, data)});

        vm.prank(ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);

        uint256 underlyingBalanceAfter = ERC20(GAUNTLET_USDC_PRIME).balanceOf(address(_plasmaVault));
        assertGt(underlyingBalanceAfter, underlyingBalanceBefore, "Underlying balance");

        uint256 ptBalanceAfter = IPrincipalToken(principalToken).balanceOf(address(_plasmaVault));
        assertEq(ptBalanceAfter, ptBalance - amountIn, "PT balance");
    }

    /// @notice Test revert when pool is not granted as substrate (enter)
    function test_SwapPt_RevertWhen_PoolNotGranted() public {
        address badPool = makeAddr("badPool");

        NapierSwapPtFuseData memory data = NapierSwapPtFuseData({
            pool: ITokiPoolToken(badPool),
            amountIn: 1000,
            minimumAmount: 0
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({fuse: _swapPtFuse, data: abi.encodeCall(NapierSwapPtFuse.enter, data)});

        vm.prank(ALPHA);
        vm.expectRevert(NapierUniversalRouterFuse.NapierFuseIInvalidMarketId.selector);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    /// @notice Test revert when pool is not granted as substrate (exit)
    function test_SwapPt_Exit_RevertWhen_PoolNotGranted() public {
        address badPool = makeAddr("badPool");

        NapierSwapPtFuseData memory data = NapierSwapPtFuseData({
            pool: ITokiPoolToken(badPool),
            amountIn: 1000,
            minimumAmount: 0
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({fuse: _swapPtFuse, data: abi.encodeCall(NapierSwapPtFuse.exit, data)});

        vm.prank(ALPHA);
        vm.expectRevert(NapierUniversalRouterFuse.NapierFuseIInvalidMarketId.selector);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    function test_SwapPt_Enter_RevertWhen_TokenInNotGranted() public {
        _regrantNapierSubstrates(IPrincipalToken(principalToken).underlying());

        NapierSwapPtFuseData memory data = NapierSwapPtFuseData({
            pool: ITokiPoolToken(pool),
            amountIn: 20212898,
            minimumAmount: 0
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({fuse: _swapPtFuse, data: abi.encodeCall(NapierSwapPtFuse.enter, data)});

        vm.prank(ALPHA);
        vm.expectRevert(NapierUniversalRouterFuse.NapierFuseIInvalidToken.selector);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    function test_SwapPt_Enter_RevertWhen_TokenOutNotGranted() public {
        _regrantNapierSubstrates(principalToken);

        NapierSwapPtFuseData memory data = NapierSwapPtFuseData({
            pool: ITokiPoolToken(pool),
            amountIn: 5019201,
            minimumAmount: 0
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({fuse: _swapPtFuse, data: abi.encodeCall(NapierSwapPtFuse.enter, data)});

        vm.prank(ALPHA);
        vm.expectRevert(NapierUniversalRouterFuse.NapierFuseIInvalidToken.selector);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    function test_SwapPt_Exit_RevertWhen_TokenInNotGranted() public {
        _regrantNapierSubstrates(principalToken);

        NapierSwapPtFuseData memory data = NapierSwapPtFuseData({
            pool: ITokiPoolToken(pool),
            amountIn: 10982012,
            minimumAmount: 0
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({fuse: _swapPtFuse, data: abi.encodeCall(NapierSwapPtFuse.exit, data)});

        vm.prank(ALPHA);
        vm.expectRevert(NapierUniversalRouterFuse.NapierFuseIInvalidToken.selector);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    function test_SwapPt_Exit_RevertWhen_TokenOutNotGranted() public {
        _regrantNapierSubstrates(IPrincipalToken(principalToken).underlying());

        NapierSwapPtFuseData memory data = NapierSwapPtFuseData({
            pool: ITokiPoolToken(pool),
            amountIn: 1821928102,
            minimumAmount: 0
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({fuse: _swapPtFuse, data: abi.encodeCall(NapierSwapPtFuse.exit, data)});

        vm.prank(ALPHA);
        vm.expectRevert(NapierUniversalRouterFuse.NapierFuseIInvalidToken.selector);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    /*                       SWAP YT TESTS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Test buying YT with underlying token via swap
    function test_SwapYt_Enter() public {
        address yt = IPrincipalToken(principalToken).i_yt();
        uint256 amountIn = 7 * 10 ** ERC20(GAUNTLET_USDC_PRIME).decimals();
        deal(GAUNTLET_USDC_PRIME, address(_plasmaVault), amountIn);

        uint256 underlyingBalanceBefore = ERC20(GAUNTLET_USDC_PRIME).balanceOf(address(_plasmaVault));
        uint256 ytBalanceBefore = ERC20(yt).balanceOf(address(_plasmaVault));

        NapierSwapYtEnterFuseData memory data = NapierSwapYtEnterFuseData({
            pool: ITokiPoolToken(pool),
            amountIn: amountIn,
            minimumAmount: 0,
            approxParams: ApproximationParams({guessMin: 0, guessMax: 0, eps: 0})
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({fuse: _swapYtFuse, data: abi.encodeCall(NapierSwapYtFuse.enter, data)});

        vm.prank(ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);

        uint256 underlyingBalanceAfter = ERC20(GAUNTLET_USDC_PRIME).balanceOf(address(_plasmaVault));
        assertApproxEqRel(
            amountIn,
            underlyingBalanceBefore - underlyingBalanceAfter,
            0.005e18, // 0.005% relative error
            "Underlying balance"
        );

        uint256 ytBalanceAfter = ERC20(yt).balanceOf(address(_plasmaVault));
        assertGt(ytBalanceAfter, ytBalanceBefore, "YT balance");
    }

    /// @notice Test selling YT for underlying token via swap
    function test_SwapYt_Exit() public {
        address yt = IPrincipalToken(principalToken).i_yt();

        _test_Supply(
            NapierSupplyFuseEnterData({
                principalToken: IPrincipalToken(principalToken),
                tokenIn: USDC,
                amountIn: 100 * 10 ** ERC20(USDC).decimals()
            })
        );

        uint256 ytBalanceBefore = ERC20(yt).balanceOf(address(_plasmaVault));
        uint256 underlyingBalanceBefore = ERC20(GAUNTLET_USDC_PRIME).balanceOf(address(_plasmaVault));

        uint256 amountIn = ytBalanceBefore / 3;

        NapierSwapYtExitFuseData memory data = NapierSwapYtExitFuseData({
            pool: ITokiPoolToken(pool),
            amountIn: amountIn,
            minimumAmount: 0
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({fuse: _swapYtFuse, data: abi.encodeCall(NapierSwapYtFuse.exit, data)});

        vm.prank(ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);

        uint256 underlyingBalanceAfter = ERC20(GAUNTLET_USDC_PRIME).balanceOf(address(_plasmaVault));
        assertGt(underlyingBalanceAfter, underlyingBalanceBefore, "Underlying balance");

        uint256 ytBalanceAfter = ERC20(yt).balanceOf(address(_plasmaVault));
        assertEq(ytBalanceAfter, ytBalanceBefore - amountIn, "YT balance");
    }

    /// @notice Test revert when pool is not granted as substrate for YT swaps (enter)
    function test_SwapYt_RevertWhen_PoolNotGranted() public {
        address badPool = makeAddr("badPool");

        NapierSwapYtEnterFuseData memory data = NapierSwapYtEnterFuseData({
            pool: ITokiPoolToken(badPool),
            amountIn: 1000,
            minimumAmount: 0,
            approxParams: ApproximationParams({guessMin: 0, guessMax: 0, eps: 0})
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({fuse: _swapYtFuse, data: abi.encodeCall(NapierSwapYtFuse.enter, data)});

        vm.prank(ALPHA);
        vm.expectRevert(NapierUniversalRouterFuse.NapierFuseIInvalidMarketId.selector);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    function test_SwapYt_Enter_RevertWhen_TokenInNotGranted() public {
        _regrantNapierSubstrates(IPrincipalToken(principalToken).underlying());

        NapierSwapYtEnterFuseData memory data = NapierSwapYtEnterFuseData({
            pool: ITokiPoolToken(pool),
            amountIn: 20212,
            minimumAmount: 0,
            approxParams: ApproximationParams({guessMin: 0, guessMax: 0, eps: 0})
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({fuse: _swapYtFuse, data: abi.encodeCall(NapierSwapYtFuse.enter, data)});

        vm.prank(ALPHA);
        vm.expectRevert(NapierUniversalRouterFuse.NapierFuseIInvalidToken.selector);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    function test_SwapYt_Enter_RevertWhen_TokenOutNotGranted() public {
        _regrantNapierSubstrates(IPrincipalToken(principalToken).i_yt());

        NapierSwapYtEnterFuseData memory data = NapierSwapYtEnterFuseData({
            pool: ITokiPoolToken(pool),
            amountIn: 20212898,
            minimumAmount: 0,
            approxParams: ApproximationParams({guessMin: 0, guessMax: 0, eps: 0})
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({fuse: _swapYtFuse, data: abi.encodeCall(NapierSwapYtFuse.enter, data)});

        vm.prank(ALPHA);
        vm.expectRevert(NapierUniversalRouterFuse.NapierFuseIInvalidToken.selector);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    function test_SwapYt_Exit_RevertWhen_TokenInNotGranted() public {
        _regrantNapierSubstrates(IPrincipalToken(principalToken).i_yt());

        NapierSwapYtExitFuseData memory data = NapierSwapYtExitFuseData({
            pool: ITokiPoolToken(pool),
            amountIn: 3903901,
            minimumAmount: 0
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({fuse: _swapYtFuse, data: abi.encodeCall(NapierSwapYtFuse.exit, data)});

        vm.prank(ALPHA);
        vm.expectRevert(NapierUniversalRouterFuse.NapierFuseIInvalidToken.selector);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    function test_SwapYt_Exit_RevertWhen_TokenOutNotGranted() public {
        _regrantNapierSubstrates(IPrincipalToken(principalToken).underlying());

        NapierSwapYtExitFuseData memory data = NapierSwapYtExitFuseData({
            pool: ITokiPoolToken(pool),
            amountIn: 212121,
            minimumAmount: 0
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({fuse: _swapYtFuse, data: abi.encodeCall(NapierSwapYtFuse.exit, data)});

        vm.prank(ALPHA);
        vm.expectRevert(NapierUniversalRouterFuse.NapierFuseIInvalidToken.selector);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    /// @notice Test revert when pool is not granted as substrate for YT swaps (exit)
    function test_SwapYt_Exit_RevertWhen_PoolNotGranted() public {
        address badPool = makeAddr("badPool");

        NapierSwapYtExitFuseData memory data = NapierSwapYtExitFuseData({
            pool: ITokiPoolToken(badPool),
            amountIn: 1000,
            minimumAmount: 0
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({fuse: _swapYtFuse, data: abi.encodeCall(NapierSwapYtFuse.exit, data)});

        vm.prank(ALPHA);
        vm.expectRevert(NapierUniversalRouterFuse.NapierFuseIInvalidMarketId.selector);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    /*                    ZAP DEPOSIT FUSE TESTS                  */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_ZapDeposit_Enter() public {
        IPrincipalToken pt = IPrincipalToken(principalToken);
        uint256 amountIn = 25 * 10 ** ERC20(GAUNTLET_USDC_PRIME).decimals();
        deal(GAUNTLET_USDC_PRIME, address(_plasmaVault), amountIn);

        address yt = IPrincipalToken(principalToken).i_yt();
        uint256 poolBalanceBefore = ERC20(pool).balanceOf(address(_plasmaVault));
        uint256 ptBalanceBefore = pt.balanceOf(address(_plasmaVault));
        uint256 ytBalanceBefore = ERC20(yt).balanceOf(address(_plasmaVault));
        uint256 totalPtSupplyBefore = pt.totalSupply();

        NapierZapDepositFuseEnterData memory data = NapierZapDepositFuseEnterData({
            pool: ITokiPoolToken(pool),
            amountIn: amountIn,
            minLiquidity: 100
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({fuse: _zapDepositFuse, data: abi.encodeCall(NapierZapDepositFuse.enter, data)});

        vm.prank(ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);

        uint256 supplyIncrease = pt.totalSupply() - totalPtSupplyBefore;

        assertEq(pt.balanceOf(address(_plasmaVault)), ptBalanceBefore, "PT balance should not change");
        assertGt(ERC20(pool).balanceOf(address(_plasmaVault)), poolBalanceBefore, "Liquidity balance");
        assertEq(ERC20(yt).balanceOf(address(_plasmaVault)), ytBalanceBefore + supplyIncrease, "YT balance");
    }

    function test_ZapDeposit_Enter_RevertWhen_PoolNotGranted() public {
        NapierZapDepositFuseEnterData memory data = NapierZapDepositFuseEnterData({
            pool: ITokiPoolToken(makeAddr("badPool")),
            amountIn: 1,
            minLiquidity: 0
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({fuse: _zapDepositFuse, data: abi.encodeCall(NapierZapDepositFuse.enter, data)});

        vm.prank(ALPHA);
        vm.expectRevert(NapierUniversalRouterFuse.NapierFuseIInvalidMarketId.selector);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    function testFuzz_ZapDeposit_Enter_RevertWhen_TokenNotGranted(uint8 omitIndex) public {
        address[3] memory tokens = [
            principalToken,
            IPrincipalToken(principalToken).i_yt(),
            IPrincipalToken(principalToken).underlying()
        ];
        address omit = tokens[omitIndex % tokens.length];

        _regrantNapierSubstrates(omit);

        NapierZapDepositFuseEnterData memory data = NapierZapDepositFuseEnterData({
            pool: ITokiPoolToken(pool),
            amountIn: 1,
            minLiquidity: 0
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({fuse: _zapDepositFuse, data: abi.encodeCall(NapierZapDepositFuse.enter, data)});

        vm.prank(ALPHA);
        vm.expectRevert(NapierUniversalRouterFuse.NapierFuseIInvalidToken.selector);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    function test_ZapDeposit_Exit_WhenPreMaturity() public {
        // Arrange
        uint256 amountIn = 25 * 10 ** ERC20(GAUNTLET_USDC_PRIME).decimals();
        deal(GAUNTLET_USDC_PRIME, address(_plasmaVault), amountIn);

        NapierZapDepositFuseEnterData memory enterData = NapierZapDepositFuseEnterData({
            pool: ITokiPoolToken(pool),
            amountIn: amountIn,
            minLiquidity: 100
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({fuse: _zapDepositFuse, data: abi.encodeCall(NapierZapDepositFuse.enter, enterData)});

        vm.prank(ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);

        uint256 liquidity = ERC20(pool).balanceOf(address(_plasmaVault));
        assertGt(liquidity, 0, "liquidity minted");

        // Act
        NapierZapDepositFuseExitData memory exitData = NapierZapDepositFuseExitData({
            pool: ITokiPoolToken(pool),
            liquidity: liquidity,
            amount1OutMin: 0
        });

        actions[0] = FuseAction({fuse: _zapDepositFuse, data: abi.encodeCall(NapierZapDepositFuse.exit, exitData)});

        uint256 underlyingBalanceBeforeExit = ERC20(GAUNTLET_USDC_PRIME).balanceOf(address(_plasmaVault));
        uint256 poolBalanceBeforeExit = ERC20(pool).balanceOf(address(_plasmaVault));

        vm.prank(ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);

        // Assert
        assertApproxEqAbs(
            poolBalanceBeforeExit - ERC20(pool).balanceOf(address(_plasmaVault)),
            liquidity,
            2,
            "liquidity"
        );

        uint256 underlyingBalanceAfterExit = ERC20(GAUNTLET_USDC_PRIME).balanceOf(address(_plasmaVault));
        assertGt(underlyingBalanceAfterExit, underlyingBalanceBeforeExit, "underlying received");
    }

    function test_ZapDeposit_Exit_WhenPostMaturity() public {
        // Arrange
        uint256 amountIn = 25 * 10 ** ERC20(GAUNTLET_USDC_PRIME).decimals();
        deal(GAUNTLET_USDC_PRIME, address(_plasmaVault), amountIn);

        NapierZapDepositFuseEnterData memory enterData = NapierZapDepositFuseEnterData({
            pool: ITokiPoolToken(pool),
            amountIn: amountIn,
            minLiquidity: 100
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({fuse: _zapDepositFuse, data: abi.encodeCall(NapierZapDepositFuse.enter, enterData)});

        vm.prank(ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);

        uint256 liquidity = ERC20(pool).balanceOf(address(_plasmaVault));
        assertGt(liquidity, 0, "liquidity minted");

        // Act
        vm.warp(expiry + 1 days);

        NapierZapDepositFuseExitData memory exitData = NapierZapDepositFuseExitData({
            pool: ITokiPoolToken(pool),
            liquidity: liquidity,
            amount1OutMin: 0
        });

        actions[0] = FuseAction({fuse: _zapDepositFuse, data: abi.encodeCall(NapierZapDepositFuse.exit, exitData)});

        uint256 underlyingBalanceBeforeExit = ERC20(GAUNTLET_USDC_PRIME).balanceOf(address(_plasmaVault));
        uint256 poolBalanceBeforeExit = ERC20(pool).balanceOf(address(_plasmaVault));

        vm.prank(ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);

        // Assert
        assertApproxEqAbs(
            poolBalanceBeforeExit - ERC20(pool).balanceOf(address(_plasmaVault)),
            liquidity,
            2,
            "liquidity"
        );

        uint256 underlyingBalanceAfterExit = ERC20(GAUNTLET_USDC_PRIME).balanceOf(address(_plasmaVault));
        assertGt(underlyingBalanceAfterExit, underlyingBalanceBeforeExit, "underlying received");
    }

    function test_ZapDeposit_Exit_RevertWhen_PoolNotGranted() public {
        NapierZapDepositFuseExitData memory data = NapierZapDepositFuseExitData({
            pool: ITokiPoolToken(makeAddr("badPool")),
            liquidity: 1,
            amount1OutMin: 0
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({fuse: _zapDepositFuse, data: abi.encodeCall(NapierZapDepositFuse.exit, data)});

        vm.prank(ALPHA);
        vm.expectRevert(NapierUniversalRouterFuse.NapierFuseIInvalidMarketId.selector);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    function testFuzz_ZapDeposit_Exit_RevertWhen_TokenNotGranted(uint8 omitIndex) public {
        address[2] memory tokens = [principalToken, IPrincipalToken(principalToken).underlying()];
        address omit = tokens[omitIndex % tokens.length];

        _regrantNapierSubstrates(omit);

        NapierZapDepositFuseExitData memory data = NapierZapDepositFuseExitData({
            pool: ITokiPoolToken(pool),
            liquidity: 1,
            amount1OutMin: 0
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({fuse: _zapDepositFuse, data: abi.encodeCall(NapierZapDepositFuse.exit, data)});

        vm.prank(ALPHA);
        vm.expectRevert(NapierUniversalRouterFuse.NapierFuseIInvalidToken.selector);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    /*                     DEPOSIT FUSE TESTS                     */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_Deposit_Enter() public {
        IPrincipalToken pt = IPrincipalToken(principalToken);

        _test_Supply(
            NapierSupplyFuseEnterData({
                principalToken: pt,
                tokenIn: USDC,
                amountIn: 1_000 * 10 ** ERC20(USDC).decimals()
            })
        );

        uint256 ptBalanceBefore = pt.balanceOf(address(_plasmaVault));
        uint256 amount1In = ptBalanceBefore / 2;
        assertGt(amount1In, 0, "PT amount");

        uint256 amount0In = 20 * 10 ** ERC20(GAUNTLET_USDC_PRIME).decimals();
        deal(GAUNTLET_USDC_PRIME, address(_plasmaVault), amount0In);

        uint256 poolBalanceBefore = ERC20(pool).balanceOf(address(_plasmaVault));

        NapierDepositFuseEnterData memory data = NapierDepositFuseEnterData({
            pool: ITokiPoolToken(pool),
            amount0In: amount0In,
            amount1In: amount1In,
            minLiquidity: 0
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({fuse: _depositFuse, data: abi.encodeCall(NapierDepositFuse.enter, data)});

        vm.prank(ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);

        assertGt(ERC20(pool).balanceOf(address(_plasmaVault)), poolBalanceBefore, "Liquidity balance");
    }

    function test_Deposit_Enter_RevertWhen_PoolNotGranted() public {
        NapierDepositFuseEnterData memory data = NapierDepositFuseEnterData({
            pool: ITokiPoolToken(makeAddr("badPool")),
            amount0In: 1,
            amount1In: 1,
            minLiquidity: 0
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({fuse: _depositFuse, data: abi.encodeCall(NapierDepositFuse.enter, data)});

        vm.prank(ALPHA);
        vm.expectRevert(NapierUniversalRouterFuse.NapierFuseIInvalidMarketId.selector);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    function testFuzz_Deposit_Enter_RevertWhen_TokenNotGranted(uint8 omitIndex) public {
        address[2] memory tokens = [principalToken, IPrincipalToken(principalToken).underlying()];
        address omit = tokens[omitIndex % tokens.length];

        _regrantNapierSubstrates(omit);

        NapierDepositFuseEnterData memory data = NapierDepositFuseEnterData({
            pool: ITokiPoolToken(pool),
            amount0In: 1,
            amount1In: 1,
            minLiquidity: 0
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({fuse: _depositFuse, data: abi.encodeCall(NapierDepositFuse.enter, data)});

        vm.prank(ALPHA);
        vm.expectRevert(NapierUniversalRouterFuse.NapierFuseIInvalidToken.selector);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    function test_Deposit_Exit() public {
        // Arrange
        IPrincipalToken pt = IPrincipalToken(principalToken);
        _test_Supply(
            NapierSupplyFuseEnterData({
                principalToken: pt,
                tokenIn: USDC,
                amountIn: 1_000 * 10 ** ERC20(USDC).decimals()
            })
        );

        uint256 amount1In = pt.balanceOf(address(_plasmaVault)) / 2;
        assertGt(amount1In, 0, "PT amount");

        uint256 amount0In = 20 * 10 ** ERC20(GAUNTLET_USDC_PRIME).decimals();
        deal(GAUNTLET_USDC_PRIME, address(_plasmaVault), amount0In);

        uint256 poolBalanceBefore = ERC20(pool).balanceOf(address(_plasmaVault));

        NapierDepositFuseEnterData memory enterData = NapierDepositFuseEnterData({
            pool: ITokiPoolToken(pool),
            amount0In: amount0In,
            amount1In: amount1In,
            minLiquidity: 0
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({fuse: _depositFuse, data: abi.encodeCall(NapierDepositFuse.enter, enterData)});

        vm.prank(ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);

        uint256 poolBalanceAfterEnter = ERC20(pool).balanceOf(address(_plasmaVault));
        uint256 liquidity = poolBalanceAfterEnter - poolBalanceBefore;
        assertGt(liquidity, 0, "Minted liquidity");

        // Act
        NapierDepositFuseExitData memory exitData = NapierDepositFuseExitData({
            pool: ITokiPoolToken(pool),
            liquidity: liquidity,
            amount0OutMin: 0,
            amount1OutMin: 0
        });

        actions[0] = FuseAction({fuse: _depositFuse, data: abi.encodeCall(NapierDepositFuse.exit, exitData)});

        uint256 underlyingBalanceBeforeExit = ERC20(GAUNTLET_USDC_PRIME).balanceOf(address(_plasmaVault));
        uint256 ptBalanceBeforeExit = pt.balanceOf(address(_plasmaVault));
        uint256 poolBalanceBeforeExit = poolBalanceAfterEnter;

        vm.prank(ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);

        uint256 poolBalanceAfterExit = ERC20(pool).balanceOf(address(_plasmaVault));
        assertApproxEqAbs(poolBalanceBeforeExit - poolBalanceAfterExit, liquidity, 2, "Liquidity burned");

        assertGt(
            ERC20(GAUNTLET_USDC_PRIME).balanceOf(address(_plasmaVault)),
            underlyingBalanceBeforeExit,
            "Underlying received"
        );
        assertGt(pt.balanceOf(address(_plasmaVault)), ptBalanceBeforeExit, "PT received");
    }

    function test_Deposit_Exit_RevertWhen_PoolNotGranted() public {
        NapierDepositFuseExitData memory data = NapierDepositFuseExitData({
            pool: ITokiPoolToken(makeAddr("badPool")),
            liquidity: 1,
            amount0OutMin: 0,
            amount1OutMin: 0
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({fuse: _depositFuse, data: abi.encodeCall(NapierDepositFuse.exit, data)});

        vm.prank(ALPHA);
        vm.expectRevert(NapierUniversalRouterFuse.NapierFuseIInvalidMarketId.selector);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    function testFuzz_Deposit_Exit_RevertWhen_TokenNotGranted(uint8 omitIndex) public {
        address[2] memory tokens = [principalToken, IPrincipalToken(principalToken).underlying()];
        address omit = tokens[omitIndex % tokens.length];

        _regrantNapierSubstrates(omit);

        NapierDepositFuseExitData memory data = NapierDepositFuseExitData({
            pool: ITokiPoolToken(pool),
            liquidity: 1,
            amount0OutMin: 0,
            amount1OutMin: 0
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({fuse: _depositFuse, data: abi.encodeCall(NapierDepositFuse.exit, data)});

        vm.prank(ALPHA);
        vm.expectRevert(NapierUniversalRouterFuse.NapierFuseIInvalidToken.selector);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    function _regrantNapierSubstrates(address omit) private {
        address[] memory base = new address[](5);
        base[0] = pool;
        base[1] = principalToken;
        base[2] = IPrincipalToken(principalToken).i_yt();
        base[3] = IPrincipalToken(principalToken).underlying();
        base[4] = IPrincipalToken(principalToken).i_asset();

        uint256 count;
        for (uint256 i; i < base.length; ++i) {
            if (omit == address(0) || base[i] != omit) {
                ++count;
            }
        }

        bytes32[] memory substrates = new bytes32[](count);
        uint256 idx;
        for (uint256 i; i < base.length; ++i) {
            if (omit == address(0) || base[i] != omit) {
                substrates[idx++] = PlasmaVaultConfigLib.addressToBytes32(base[i]);
            }
        }

        vm.startPrank(ATOMIST);
        _plasmaVault.addSubstratesToMarket(IporFusionMarkets.NAPIER, substrates);
        vm.stopPrank();
    }
}
