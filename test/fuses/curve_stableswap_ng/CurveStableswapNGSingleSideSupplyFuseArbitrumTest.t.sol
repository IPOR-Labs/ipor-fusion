// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ICurveStableswapNG} from "./../../../contracts/fuses/curve_stableswap_ng/ext/ICurveStableswapNG.sol";
import {CurveStableswapNGSingleSideSupplyFuse, CurveStableswapNGSingleSideSupplyFuseEnterData, CurveStableswapNGSingleSideSupplyFuseExitData} from "./../../../contracts/fuses/curve_stableswap_ng/CurveStableswapNGSingleSideSupplyFuse.sol";
import {CurveStableswapNGSingleSideBalanceFuse} from "./../../../contracts/fuses/curve_stableswap_ng/CurveStableswapNGSingleSideBalanceFuse.sol";
import {FeeConfig, FuseAction, MarketBalanceFuseConfig, MarketSubstratesConfig, PlasmaVaultInitData} from "./../../../contracts/vaults/PlasmaVault.sol";
import {IporPlasmaVault} from "./../../../contracts/vaults/IporPlasmaVault.sol";
import {PlasmaVaultConfigLib} from "./../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {IporFusionAccessManager} from "./../../../contracts/managers/access/IporFusionAccessManager.sol";
import {RoleLib, UsersToRoles} from "./../../RoleLib.sol";
import {PriceOracleMiddleware} from "../../../contracts/priceOracle/PriceOracleMiddleware.sol";
import {USDMPriceFeedArbitrum} from "./../../../contracts/priceOracle/priceFeed/USDMPriceFeedArbitrum.sol";
import {IChronicle, IToll} from "./../../../contracts/priceOracle/IChronicle.sol";

contract CurveStableswapNGSingleSideSupplyFuseTest is Test {
    struct PlasmaVaultState {
        uint256 vaultBalance;
        uint256 vaultTotalAssets;
        uint256 vaultTotalAssetsInMarket;
        uint256 vaultLpTokensBalance;
    }

    UsersToRoles public usersToRoles;

    // Address USDC/USDM pool on Arbitrum: 0x4bD135524897333bec344e50ddD85126554E58B4
    // index 0 - USDC
    // index 1 - USDM

    address public constant CURVE_STABLESWAP_NG_POOL = 0x4bD135524897333bec344e50ddD85126554E58B4;

    address public constant BASE_CURRENCY = 0x0000000000000000000000000000000000000348;
    uint256 public constant BASE_CURRENCY_DECIMALS = 8;
    address public constant USDM = 0x59D9356E565Ab3A36dD77763Fc0d87fEaf85508C;
    address public constant DAI = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;

    ICurveStableswapNG public constant CURVE_STABLESWAP_NG = ICurveStableswapNG(CURVE_STABLESWAP_NG_POOL);

    address public constant CHRONICLE_ADMIN = 0x39aBD7819E5632Fa06D2ECBba45Dca5c90687EE3;
    address public constant WUSDM_USD_ORACLE_FEED = 0xdC6720c996Fad27256c7fd6E0a271e2A4687eF18;
    IChronicle public constant CHRONICLE = IChronicle(WUSDM_USD_ORACLE_FEED);
    USDMPriceFeedArbitrum public priceFeed;

    IporPlasmaVault public plasmaVault;

    address public atomist = address(this);
    address public alpha = address(0x1);
    address public depositor = address(0x2);

    address public constant OWNER = 0xD92E9F039E4189c342b4067CC61f5d063960D248;

    PriceOracleMiddleware private priceOracleMiddlewareProxy;

    event CurveSupplyStableswapNGSingleSideSupplyEnterFuse(
        address version,
        address curvePool,
        address asset,
        uint256 amount,
        uint256 minMintAmount
    );

    event CurveSupplyStableswapNGSingleSideSupplyExitFuse(
        address version,
        address curvePool,
        uint256 burnAmount,
        address asset,
        uint256 minReceived
    );

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 202220653);
        priceFeed = new USDMPriceFeedArbitrum();
        // price feed admin needs to whitelist the caller address for reading the price
        vm.prank(CHRONICLE_ADMIN);
        IToll(address(CHRONICLE)).kiss(address(priceFeed));
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(
            BASE_CURRENCY,
            BASE_CURRENCY_DECIMALS,
            0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf
        );
        priceOracleMiddlewareProxy = PriceOracleMiddleware(
            address(new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", OWNER)))
        );
        address[] memory assets = new address[](1);
        address[] memory sources = new address[](1);
        assets[0] = USDM;
        sources[0] = address(priceFeed);
        vm.prank(OWNER);
        priceOracleMiddlewareProxy.setAssetsPricesSources(assets, sources);
    }

    // ENTER TESTS

    function testShouldBeAbleToSupplyOneTokenSupportedByThePool() external {
        // given
        CurveStableswapNGSingleSideSupplyFuse fuse = new CurveStableswapNGSingleSideSupplyFuse(1);
        CurveStableswapNGSingleSideBalanceFuse balanceFuse = new CurveStableswapNGSingleSideBalanceFuse(
            1,
            address(priceOracleMiddlewareProxy)
        );

        MarketSubstratesConfig[] memory marketConfigs = createMarketConfigs(fuse);
        address[] memory fuses = createFuses(fuse);
        address[] memory alphas = createAlphas();
        MarketBalanceFuseConfig[] memory balanceFuses = createBalanceFuses(fuse, balanceFuse);
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0;
        amounts[1] = 100 * 10 ** ERC20(USDM).decimals();

        IporPlasmaVault plasmaVault = new IporPlasmaVault(
            PlasmaVaultInitData(
                "Plasma Vault",
                "PLASMA",
                USDM,
                address(priceOracleMiddlewareProxy),
                alphas,
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );

        setupRoles(plasmaVault, accessManager);

        _supplyTokens(USDM, address(depositor), 1_000 * 10 ** ERC20(USDM).decimals());

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(fuse),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(
                    CurveStableswapNGSingleSideSupplyFuseEnterData({
                        curveStableswapNG: CURVE_STABLESWAP_NG,
                        asset: USDM,
                        amount: amounts[1],
                        minMintAmount: 0
                    })
                )
            )
        );

        vm.startPrank(depositor);
        ERC20(USDM).approve(address(plasmaVault), 1_000 * 10 ** ERC20(USDM).decimals());
        plasmaVault.deposit(1_000 * 10 ** ERC20(USDM).decimals(), address(depositor));
        vm.stopPrank();

        PlasmaVaultState memory beforeState = getPlasmaVaultState(plasmaVault, fuse, USDM);

        uint256 expectedLpTokenAmount = CURVE_STABLESWAP_NG.calc_token_amount(amounts, true);

        vm.expectEmit(true, true, true, true);
        emit CurveSupplyStableswapNGSingleSideSupplyEnterFuse(
            address(fuse),
            address(CURVE_STABLESWAP_NG),
            USDM,
            amounts[1],
            0
        );
        // when
        vm.startPrank(alpha);
        plasmaVault.execute(calls);
        vm.stopPrank();

        // then
        PlasmaVaultState memory afterState = getPlasmaVaultState(plasmaVault, fuse, USDM);

        assertApproxEqAbs(
            afterState.vaultBalance + amounts[1],
            beforeState.vaultBalance,
            100,
            "vault balance should be decreased by amount"
        );
        assertEq(afterState.vaultLpTokensBalance, expectedLpTokenAmount);
    }

    function testShouldRevertWhenEnterWithUnsupportedPool() external {
        // given
        CurveStableswapNGSingleSideSupplyFuse fuse = new CurveStableswapNGSingleSideSupplyFuse(1);
        CurveStableswapNGSingleSideBalanceFuse balanceFuse = new CurveStableswapNGSingleSideBalanceFuse(
            1,
            address(priceOracleMiddlewareProxy)
        );

        ICurveStableswapNG curvePool = ICurveStableswapNG(address(0x888));

        MarketSubstratesConfig[] memory marketConfigs = createMarketConfigs(fuse);
        address[] memory fuses = createFuses(fuse);
        address[] memory alphas = createAlphas();
        MarketBalanceFuseConfig[] memory balanceFuses = createBalanceFuses(fuse, balanceFuse);
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles);

        uint256 amount = 100 * 10 ** ERC20(USDM).decimals();

        IporPlasmaVault plasmaVault = new IporPlasmaVault(
            PlasmaVaultInitData(
                "Plasma Vault",
                "PLASMA",
                USDM,
                address(priceOracleMiddlewareProxy),
                alphas,
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );

        setupRoles(plasmaVault, accessManager);

        _supplyTokens(USDM, address(depositor), 1_000 * 10 ** ERC20(USDM).decimals());

        bytes memory error = abi.encodeWithSignature(
            "CurveStableswapNGSingleSideSupplyFuseUnsupportedPool(address)",
            address(curvePool)
        );

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(fuse),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(
                    CurveStableswapNGSingleSideSupplyFuseEnterData({
                        curveStableswapNG: curvePool,
                        asset: USDM,
                        amount: amount,
                        minMintAmount: 0
                    })
                )
            )
        );

        vm.startPrank(depositor);
        ERC20(USDM).approve(address(plasmaVault), 1_000 * 10 ** ERC20(USDM).decimals());
        plasmaVault.deposit(1_000 * 10 ** ERC20(USDM).decimals(), address(depositor));
        vm.stopPrank();

        PlasmaVaultState memory beforeState = getPlasmaVaultState(plasmaVault, fuse, DAI);

        // when
        vm.startPrank(alpha);
        vm.expectRevert(error);
        plasmaVault.execute(calls);
        vm.stopPrank();

        // then
        PlasmaVaultState memory afterState = getPlasmaVaultState(plasmaVault, fuse, DAI);
        assertEq(afterState.vaultBalance, beforeState.vaultBalance, "vault balance should not be decreased");
        assertEq(afterState.vaultLpTokensBalance, 0);
    }

    function testShouldRevertWhenEnterWithUnsupportedPoolAsset() external {
        // given
        CurveStableswapNGSingleSideSupplyFuse fuse = new CurveStableswapNGSingleSideSupplyFuse(1);
        CurveStableswapNGSingleSideBalanceFuse balanceFuse = new CurveStableswapNGSingleSideBalanceFuse(
            1,
            address(priceOracleMiddlewareProxy)
        );

        MarketSubstratesConfig[] memory marketConfigs = createMarketConfigs(fuse);
        address[] memory fuses = createFuses(fuse);
        address[] memory alphas = createAlphas();
        MarketBalanceFuseConfig[] memory balanceFuses = createBalanceFuses(fuse, balanceFuse);
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles);

        uint256 amount = 100 * 10 ** ERC20(DAI).decimals();

        IporPlasmaVault plasmaVault = new IporPlasmaVault(
            PlasmaVaultInitData(
                "Plasma Vault",
                "PLASMA",
                USDM,
                address(priceOracleMiddlewareProxy),
                alphas,
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );

        setupRoles(plasmaVault, accessManager);

        _supplyTokens(DAI, address(plasmaVault), 1_000 * 10 ** ERC20(DAI).decimals());

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(fuse),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(
                    CurveStableswapNGSingleSideSupplyFuseEnterData({
                        curveStableswapNG: CURVE_STABLESWAP_NG,
                        asset: DAI,
                        amount: amount,
                        minMintAmount: 0
                    })
                )
            )
        );

        bytes memory error = abi.encodeWithSignature(
            "CurveStableswapNGSingleSideSupplyFuseUnsupportedPoolAsset(address)",
            address(DAI)
        );

        PlasmaVaultState memory beforeState = getPlasmaVaultState(plasmaVault, fuse, USDM);

        // when
        vm.startPrank(alpha);
        vm.expectRevert(error);
        plasmaVault.execute(calls);
        vm.stopPrank();

        // then
        PlasmaVaultState memory afterState = getPlasmaVaultState(plasmaVault, fuse, USDM);
        assertEq(afterState.vaultBalance, beforeState.vaultBalance, "vault balance should not be decreased");
        assertEq(afterState.vaultLpTokensBalance, 0);
    }

    function testShouldRevertWhenMinMintAmountRequestedIsNotMet() external {
        // given
        CurveStableswapNGSingleSideSupplyFuse fuse = new CurveStableswapNGSingleSideSupplyFuse(1);
        CurveStableswapNGSingleSideBalanceFuse balanceFuse = new CurveStableswapNGSingleSideBalanceFuse(
            1,
            address(priceOracleMiddlewareProxy)
        );

        MarketSubstratesConfig[] memory marketConfigs = createMarketConfigs(fuse);
        address[] memory fuses = createFuses(fuse);
        address[] memory alphas = createAlphas();
        MarketBalanceFuseConfig[] memory balanceFuses = createBalanceFuses(fuse, balanceFuse);
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0;
        amounts[1] = 100 * 10 ** ERC20(USDM).decimals();

        IporPlasmaVault plasmaVault = new IporPlasmaVault(
            PlasmaVaultInitData(
                "Plasma Vault",
                "PLASMA",
                USDM,
                address(priceOracleMiddlewareProxy),
                alphas,
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );

        setupRoles(plasmaVault, accessManager);

        _supplyTokens(USDM, address(depositor), 1_000 * 10 ** ERC20(USDM).decimals());

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(fuse),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(
                    CurveStableswapNGSingleSideSupplyFuseEnterData({
                        curveStableswapNG: CURVE_STABLESWAP_NG,
                        asset: USDM,
                        amount: amounts[1],
                        minMintAmount: CURVE_STABLESWAP_NG.calc_token_amount(amounts, true) + 1
                    })
                )
            )
        );

        vm.startPrank(depositor);
        ERC20(USDM).approve(address(plasmaVault), 1_000 * 10 ** ERC20(USDM).decimals());
        plasmaVault.deposit(1_000 * 10 ** ERC20(USDM).decimals(), address(depositor));
        vm.stopPrank();

        PlasmaVaultState memory beforeState = getPlasmaVaultState(plasmaVault, fuse, USDM);

        // when
        vm.startPrank(alpha);
        vm.expectRevert("Slippage screwed you"); // revert message from CurveStableswapNG
        plasmaVault.execute(calls);
        vm.stopPrank();

        // then
        PlasmaVaultState memory afterState = getPlasmaVaultState(plasmaVault, fuse, USDM);
        assertEq(afterState.vaultBalance, beforeState.vaultBalance, "vault balance should not be decreased");
        assertEq(afterState.vaultLpTokensBalance, 0);
    }

    function testShouldRevertWhenEnterWithAllZeroAmounts() external {
        // given
        CurveStableswapNGSingleSideSupplyFuse fuse = new CurveStableswapNGSingleSideSupplyFuse(1);
        CurveStableswapNGSingleSideBalanceFuse balanceFuse = new CurveStableswapNGSingleSideBalanceFuse(
            1,
            address(priceOracleMiddlewareProxy)
        );

        MarketSubstratesConfig[] memory marketConfigs = createMarketConfigs(fuse);
        address[] memory fuses = createFuses(fuse);
        address[] memory alphas = createAlphas();
        MarketBalanceFuseConfig[] memory balanceFuses = createBalanceFuses(fuse, balanceFuse);
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles);

        uint256 amount = 0;

        IporPlasmaVault plasmaVault = new IporPlasmaVault(
            PlasmaVaultInitData(
                "Plasma Vault",
                "PLASMA",
                USDM,
                address(priceOracleMiddlewareProxy),
                alphas,
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );

        setupRoles(plasmaVault, accessManager);

        _supplyTokens(USDM, address(depositor), 1_000 * 10 ** ERC20(USDM).decimals());

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(fuse),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(
                    CurveStableswapNGSingleSideSupplyFuseEnterData({
                        curveStableswapNG: CURVE_STABLESWAP_NG,
                        asset: USDM,
                        amount: amount,
                        minMintAmount: 0
                    })
                )
            )
        );

        bytes memory error = abi.encodeWithSignature("CurveStableswapNGSingleSideSupplyFuseZeroAmount()");

        vm.startPrank(depositor);
        ERC20(USDM).approve(address(plasmaVault), 1_000 * 10 ** ERC20(USDM).decimals());
        plasmaVault.deposit(1_000 * 10 ** ERC20(USDM).decimals(), address(depositor));
        vm.stopPrank();

        PlasmaVaultState memory beforeState = getPlasmaVaultState(plasmaVault, fuse, USDM);

        // when
        vm.startPrank(alpha);
        vm.expectRevert(error);
        plasmaVault.execute(calls);
        vm.stopPrank();

        // then
        PlasmaVaultState memory afterState = getPlasmaVaultState(plasmaVault, fuse, USDM);
        assertEq(afterState.vaultBalance, beforeState.vaultBalance, "vault balance should not be decreased");
        assertEq(afterState.vaultLpTokensBalance, 0);
    }

    // EXIT TESTS

    function testShouldBeAbleToExit() external {
        // given
        CurveStableswapNGSingleSideSupplyFuse fuse = new CurveStableswapNGSingleSideSupplyFuse(1);
        CurveStableswapNGSingleSideBalanceFuse balanceFuse = new CurveStableswapNGSingleSideBalanceFuse(
            1,
            address(priceOracleMiddlewareProxy)
        );

        MarketSubstratesConfig[] memory marketConfigs = createMarketConfigs(fuse);
        address[] memory fuses = createFuses(fuse);
        address[] memory alphas = createAlphas();
        MarketBalanceFuseConfig[] memory balanceFuses = createBalanceFuses(fuse, balanceFuse);
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0;
        amounts[1] = 100 * 10 ** ERC20(USDM).decimals();

        IporPlasmaVault plasmaVault = new IporPlasmaVault(
            PlasmaVaultInitData(
                "Plasma Vault",
                "PLASMA",
                USDM,
                address(priceOracleMiddlewareProxy),
                alphas,
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );

        setupRoles(plasmaVault, accessManager);

        _supplyTokens(USDM, address(depositor), 1_000 * 10 ** ERC20(USDM).decimals());

        FuseAction[] memory callsEnter = new FuseAction[](1);
        callsEnter[0] = FuseAction(
            address(fuse),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(
                    CurveStableswapNGSingleSideSupplyFuseEnterData({
                        curveStableswapNG: CURVE_STABLESWAP_NG,
                        asset: USDM,
                        amount: amounts[1],
                        minMintAmount: 0
                    })
                )
            )
        );

        vm.startPrank(depositor);
        ERC20(USDM).approve(address(plasmaVault), 1_000 * 10 ** ERC20(USDM).decimals());
        plasmaVault.deposit(1_000 * 10 ** ERC20(USDM).decimals(), address(depositor));
        vm.stopPrank();

        PlasmaVaultState memory beforeEnterState = getPlasmaVaultState(plasmaVault, fuse, USDM);

        vm.startPrank(alpha);
        vm.expectEmit(true, true, true, true);
        emit CurveSupplyStableswapNGSingleSideSupplyEnterFuse(
            address(fuse),
            address(CURVE_STABLESWAP_NG),
            USDM,
            amounts[1],
            0
        );
        plasmaVault.execute(callsEnter);
        vm.stopPrank();

        PlasmaVaultState memory beforeExitState = getPlasmaVaultState(plasmaVault, fuse, USDM);

        FuseAction[] memory callsExit = new FuseAction[](1);
        callsExit[0] = FuseAction(
            address(fuse),
            abi.encodeWithSignature(
                "exit(bytes)",
                abi.encode(
                    CurveStableswapNGSingleSideSupplyFuseExitData({
                        curveStableswapNG: CURVE_STABLESWAP_NG,
                        asset: USDM,
                        burnAmount: beforeExitState.vaultLpTokensBalance,
                        minReceived: 0
                    })
                )
            )
        );

        vm.expectEmit(true, true, true, true);
        emit CurveSupplyStableswapNGSingleSideSupplyExitFuse(
            address(fuse),
            address(CURVE_STABLESWAP_NG),
            beforeExitState.vaultLpTokensBalance,
            USDM,
            0
        );

        // when
        vm.startPrank(alpha);
        plasmaVault.execute(callsExit);
        vm.stopPrank();

        // then
        PlasmaVaultState memory afterExitState = getPlasmaVaultState(plasmaVault, fuse, USDM);
        assertApproxEqAbs(
            beforeEnterState.vaultBalance,
            beforeExitState.vaultBalance + amounts[1],
            100,
            "Vault balance should be increased by amount"
        );
        assertEq(afterExitState.vaultLpTokensBalance, 0, "LP token balance should be burnt to zero");
    }

    function testShouldRevertOnExitWithUnsupportedPoolAsset() external {
        // given
        CurveStableswapNGSingleSideSupplyFuse fuse = new CurveStableswapNGSingleSideSupplyFuse(1);
        CurveStableswapNGSingleSideBalanceFuse balanceFuse = new CurveStableswapNGSingleSideBalanceFuse(
            1,
            address(priceOracleMiddlewareProxy)
        );

        MarketSubstratesConfig[] memory marketConfigs = createMarketConfigs(fuse);
        address[] memory fuses = createFuses(fuse);
        address[] memory alphas = createAlphas();
        MarketBalanceFuseConfig[] memory balanceFuses = createBalanceFuses(fuse, balanceFuse);
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles);

        uint256 amount = 100 * 10 ** ERC20(USDM).decimals();

        IporPlasmaVault plasmaVault = new IporPlasmaVault(
            PlasmaVaultInitData(
                "Plasma Vault",
                "PLASMA",
                USDM,
                address(priceOracleMiddlewareProxy),
                alphas,
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );

        setupRoles(plasmaVault, accessManager);

        _supplyTokens(USDM, address(depositor), 1_000 * 10 ** ERC20(USDM).decimals());

        FuseAction[] memory callsEnter = new FuseAction[](1);
        callsEnter[0] = FuseAction(
            address(fuse),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(
                    CurveStableswapNGSingleSideSupplyFuseEnterData({
                        curveStableswapNG: CURVE_STABLESWAP_NG,
                        asset: USDM,
                        amount: amount,
                        minMintAmount: 0
                    })
                )
            )
        );

        vm.startPrank(depositor);
        ERC20(USDM).approve(address(plasmaVault), 1_000 * 10 ** ERC20(USDM).decimals());
        plasmaVault.deposit(1_000 * 10 ** ERC20(USDM).decimals(), address(depositor));
        vm.stopPrank();

        vm.startPrank(alpha);
        vm.expectEmit(true, true, true, true);
        emit CurveSupplyStableswapNGSingleSideSupplyEnterFuse(
            address(fuse),
            address(CURVE_STABLESWAP_NG),
            USDM,
            amount,
            0
        );
        plasmaVault.execute(callsEnter);
        vm.stopPrank();

        PlasmaVaultState memory afterEnterState = getPlasmaVaultState(plasmaVault, fuse, USDM);

        bytes memory error = abi.encodeWithSignature(
            "CurveStableswapNGSingleSideSupplyFuseUnsupportedPoolAsset(address)",
            address(DAI)
        );

        FuseAction[] memory callsExit = new FuseAction[](1);
        callsExit[0] = FuseAction(
            address(fuse),
            abi.encodeWithSignature(
                "exit(bytes)",
                abi.encode(
                    CurveStableswapNGSingleSideSupplyFuseExitData({
                        curveStableswapNG: CURVE_STABLESWAP_NG,
                        asset: DAI,
                        burnAmount: afterEnterState.vaultLpTokensBalance,
                        minReceived: 0
                    })
                )
            )
        );

        // when
        vm.startPrank(alpha);
        vm.expectRevert(error);
        plasmaVault.execute(callsExit);
        vm.stopPrank();

        // then
        PlasmaVaultState memory afterExitState = getPlasmaVaultState(plasmaVault, fuse, USDM);
        assertEq(afterEnterState.vaultBalance, afterExitState.vaultBalance, "vault balance should not be decreased");
        assertEq(
            afterEnterState.vaultLpTokensBalance,
            afterExitState.vaultLpTokensBalance,
            "LP token balance should not be decreased"
        );
    }

    function testShouldRevertWhenBurnAmountExitExceedsLPBalance() external {
        // given
        CurveStableswapNGSingleSideSupplyFuse fuse = new CurveStableswapNGSingleSideSupplyFuse(1);
        CurveStableswapNGSingleSideBalanceFuse balanceFuse = new CurveStableswapNGSingleSideBalanceFuse(
            1,
            address(priceOracleMiddlewareProxy)
        );

        MarketSubstratesConfig[] memory marketConfigs = createMarketConfigs(fuse);
        address[] memory fuses = createFuses(fuse);
        address[] memory alphas = createAlphas();
        MarketBalanceFuseConfig[] memory balanceFuses = createBalanceFuses(fuse, balanceFuse);
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles);

        uint256 amount = 100 * 10 ** ERC20(USDM).decimals();

        IporPlasmaVault plasmaVault = new IporPlasmaVault(
            PlasmaVaultInitData(
                "Plasma Vault",
                "PLASMA",
                USDM,
                address(priceOracleMiddlewareProxy),
                alphas,
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );

        setupRoles(plasmaVault, accessManager);

        _supplyTokens(USDM, address(depositor), 1_000 * 10 ** ERC20(USDM).decimals());

        FuseAction[] memory callsEnter = new FuseAction[](1);
        callsEnter[0] = FuseAction(
            address(fuse),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(
                    CurveStableswapNGSingleSideSupplyFuseEnterData({
                        curveStableswapNG: CURVE_STABLESWAP_NG,
                        asset: USDM,
                        amount: amount,
                        minMintAmount: 0
                    })
                )
            )
        );

        vm.startPrank(depositor);
        ERC20(USDM).approve(address(plasmaVault), 1_000 * 10 ** ERC20(USDM).decimals());
        plasmaVault.deposit(1_000 * 10 ** ERC20(USDM).decimals(), address(depositor));
        vm.stopPrank();

        vm.startPrank(alpha);
        plasmaVault.execute(callsEnter);
        vm.stopPrank();

        PlasmaVaultState memory afterEnterState = getPlasmaVaultState(plasmaVault, fuse, USDM);

        FuseAction[] memory callsExit = new FuseAction[](1);
        callsExit[0] = FuseAction(
            address(fuse),
            abi.encodeWithSignature(
                "exit(bytes)",
                abi.encode(
                    CurveStableswapNGSingleSideSupplyFuseExitData({
                        curveStableswapNG: CURVE_STABLESWAP_NG,
                        asset: USDM,
                        burnAmount: afterEnterState.vaultLpTokensBalance + 1,
                        minReceived: 0
                    })
                )
            )
        );

        // when
        vm.startPrank(alpha);
        vm.expectRevert();
        plasmaVault.execute(callsExit);
        vm.stopPrank();

        // then
        PlasmaVaultState memory afterExitState = getPlasmaVaultState(plasmaVault, fuse, USDM);
        assertEq(afterEnterState.vaultBalance, afterExitState.vaultBalance, "vault balance should not be decreased");
        assertEq(
            afterEnterState.vaultLpTokensBalance,
            afterExitState.vaultLpTokensBalance,
            "LP token balance should not be decreased"
        );
    }

    function testShouldRevertWhenMinReceivedIsNotMet() external {
        // given
        CurveStableswapNGSingleSideSupplyFuse fuse = new CurveStableswapNGSingleSideSupplyFuse(1);
        CurveStableswapNGSingleSideBalanceFuse balanceFuse = new CurveStableswapNGSingleSideBalanceFuse(
            1,
            address(priceOracleMiddlewareProxy)
        );

        MarketSubstratesConfig[] memory marketConfigs = createMarketConfigs(fuse);
        address[] memory fuses = createFuses(fuse);
        address[] memory alphas = createAlphas();
        MarketBalanceFuseConfig[] memory balanceFuses = createBalanceFuses(fuse, balanceFuse);
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles);

        uint256 amount = 100 * 10 ** ERC20(USDM).decimals();

        IporPlasmaVault plasmaVault = new IporPlasmaVault(
            PlasmaVaultInitData(
                "Plasma Vault",
                "PLASMA",
                USDM,
                address(priceOracleMiddlewareProxy),
                alphas,
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );

        setupRoles(plasmaVault, accessManager);

        _supplyTokens(USDM, address(depositor), 1_000 * 10 ** ERC20(USDM).decimals());

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(fuse),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(
                    CurveStableswapNGSingleSideSupplyFuseEnterData({
                        curveStableswapNG: CURVE_STABLESWAP_NG,
                        asset: USDM,
                        amount: amount,
                        minMintAmount: 0
                    })
                )
            )
        );

        vm.startPrank(depositor);
        ERC20(USDM).approve(address(plasmaVault), 1_000 * 10 ** ERC20(USDM).decimals());
        plasmaVault.deposit(1_000 * 10 ** ERC20(USDM).decimals(), address(depositor));
        vm.stopPrank();

        vm.startPrank(alpha);
        plasmaVault.execute(calls);
        vm.stopPrank();

        PlasmaVaultState memory afterEnterState = getPlasmaVaultState(plasmaVault, fuse, USDM);

        FuseAction[] memory callsExit = new FuseAction[](1);
        callsExit[0] = FuseAction(
            address(fuse),
            abi.encodeWithSignature(
                "exit(bytes)",
                abi.encode(
                    CurveStableswapNGSingleSideSupplyFuseExitData({
                        curveStableswapNG: CURVE_STABLESWAP_NG,
                        asset: USDM,
                        burnAmount: afterEnterState.vaultLpTokensBalance,
                        minReceived: CURVE_STABLESWAP_NG.calc_withdraw_one_coin(
                            afterEnterState.vaultLpTokensBalance,
                            1
                        ) + 1
                    })
                )
            )
        );

        // when
        vm.startPrank(alpha);
        vm.expectRevert("Not enough coins removed");
        plasmaVault.execute(callsExit);
        vm.stopPrank();

        // then
        PlasmaVaultState memory afterExitState = getPlasmaVaultState(plasmaVault, fuse, USDM);
        assertEq(afterEnterState.vaultBalance, afterExitState.vaultBalance, "vault balance should not be decreased");
        assertEq(
            afterEnterState.vaultLpTokensBalance,
            afterExitState.vaultLpTokensBalance,
            "LP token balance should not be decreased"
        );
    }

    function testShouldRevertWhenBurnAmountIsZero() external {
        // given
        CurveStableswapNGSingleSideSupplyFuse fuse = new CurveStableswapNGSingleSideSupplyFuse(1);
        CurveStableswapNGSingleSideBalanceFuse balanceFuse = new CurveStableswapNGSingleSideBalanceFuse(
            1,
            address(priceOracleMiddlewareProxy)
        );

        MarketSubstratesConfig[] memory marketConfigs = createMarketConfigs(fuse);
        address[] memory fuses = createFuses(fuse);
        address[] memory alphas = createAlphas();
        MarketBalanceFuseConfig[] memory balanceFuses = createBalanceFuses(fuse, balanceFuse);
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles);

        uint256 amount = 100 * 10 ** ERC20(USDM).decimals();

        IporPlasmaVault plasmaVault = new IporPlasmaVault(
            PlasmaVaultInitData(
                "Plasma Vault",
                "PLASMA",
                USDM,
                address(priceOracleMiddlewareProxy),
                alphas,
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );

        setupRoles(plasmaVault, accessManager);

        _supplyTokens(USDM, address(depositor), 1_000 * 10 ** ERC20(USDM).decimals());

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(fuse),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(
                    CurveStableswapNGSingleSideSupplyFuseEnterData({
                        curveStableswapNG: CURVE_STABLESWAP_NG,
                        asset: USDM,
                        amount: amount,
                        minMintAmount: 0
                    })
                )
            )
        );

        vm.startPrank(depositor);
        ERC20(USDM).approve(address(plasmaVault), 1_000 * 10 ** ERC20(USDM).decimals());
        plasmaVault.deposit(1_000 * 10 ** ERC20(USDM).decimals(), address(depositor));
        vm.stopPrank();

        vm.startPrank(alpha);
        plasmaVault.execute(calls);
        vm.stopPrank();

        bytes memory error = abi.encodeWithSignature("CurveStableswapNGSingleSideSupplyFuseZeroBurnAmount()");

        PlasmaVaultState memory afterEnterState = getPlasmaVaultState(plasmaVault, fuse, USDM);

        FuseAction[] memory callsExit = new FuseAction[](1);
        callsExit[0] = FuseAction(
            address(fuse),
            abi.encodeWithSignature(
                "exit(bytes)",
                abi.encode(
                    CurveStableswapNGSingleSideSupplyFuseExitData({
                        curveStableswapNG: CURVE_STABLESWAP_NG,
                        asset: USDM,
                        burnAmount: 0,
                        minReceived: 0
                    })
                )
            )
        );

        // when
        vm.startPrank(alpha);
        vm.expectRevert(error);
        plasmaVault.execute(callsExit);
        vm.stopPrank();

        // then
        PlasmaVaultState memory afterExitState = getPlasmaVaultState(plasmaVault, fuse, USDM);
        assertEq(afterEnterState.vaultBalance, afterExitState.vaultBalance, "vault balance should not be decreased");
        assertEq(
            afterEnterState.vaultLpTokensBalance,
            afterExitState.vaultLpTokensBalance,
            "LP token balance should not be decreased"
        );
    }

    // HELPERS

    function _supplyTokens(address asset, address to, uint256 amount) private {
        if (asset == USDM) {
            vm.prank(0x426c4966fC76Bf782A663203c023578B744e4C5E); // holder
            ERC20(asset).transfer(to, amount);
        } else {
            deal(asset, to, amount);
        }
    }

    function createAccessManager(UsersToRoles memory usersToRoles) public returns (IporFusionAccessManager) {
        if (usersToRoles.superAdmin == address(0)) {
            usersToRoles.superAdmin = atomist;
            usersToRoles.atomist = atomist;
            address[] memory alphas = new address[](1);
            alphas[0] = alpha;
            usersToRoles.alphas = alphas;
        }
        return RoleLib.createAccessManager(usersToRoles, vm);
    }

    function createMarketConfigs(
        CurveStableswapNGSingleSideSupplyFuse fuse
    ) private returns (MarketSubstratesConfig[] memory) {
        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](1);
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(CURVE_STABLESWAP_NG_POOL);
        marketConfigs[0] = MarketSubstratesConfig({marketId: fuse.MARKET_ID(), substrates: substrates});
        return marketConfigs;
    }

    function createFuses(CurveStableswapNGSingleSideSupplyFuse fuse) private returns (address[] memory) {
        address[] memory fuses = new address[](1);
        fuses[0] = address(fuse);
        return fuses;
    }

    function createAlphas() private returns (address[] memory) {
        address[] memory alphas = new address[](1);
        alphas[0] = address(0x1);
        return alphas;
    }

    function createBalanceFuses(
        CurveStableswapNGSingleSideSupplyFuse fuse,
        CurveStableswapNGSingleSideBalanceFuse balanceFuse
    ) private returns (MarketBalanceFuseConfig[] memory) {
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(fuse.MARKET_ID(), address(balanceFuse));
        return balanceFuses;
    }

    function getPlasmaVaultState(
        IporPlasmaVault plasmaVault,
        CurveStableswapNGSingleSideSupplyFuse fuse,
        address activeToken
    ) private view returns (PlasmaVaultState memory) {
        return
            PlasmaVaultState({
                vaultBalance: ERC20(activeToken).balanceOf(address(plasmaVault)),
                vaultTotalAssets: plasmaVault.totalAssets(),
                vaultTotalAssetsInMarket: plasmaVault.totalAssetsInMarket(fuse.MARKET_ID()),
                vaultLpTokensBalance: ERC20(CURVE_STABLESWAP_NG_POOL).balanceOf(address(plasmaVault))
            });
    }

    function setupRoles(IporPlasmaVault plasmaVault, IporFusionAccessManager accessManager) public {
        usersToRoles.superAdmin = atomist;
        usersToRoles.atomist = atomist;
        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(plasmaVault), accessManager);
    }
}