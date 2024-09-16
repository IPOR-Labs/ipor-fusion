// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PlasmaVault, FeeConfig, FuseAction, MarketBalanceFuseConfig, MarketSubstratesConfig, PlasmaVaultInitData} from "./../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultConfigLib} from "./../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {ICurveStableswapNG} from "./../../../contracts/fuses/curve_stableswap_ng/ext/ICurveStableswapNG.sol";
import {CurveStableswapNGSingleSideSupplyFuse, CurveStableswapNGSingleSideSupplyFuseEnterData, CurveStableswapNGSingleSideSupplyFuseExitData} from "./../../../contracts/fuses/curve_stableswap_ng/CurveStableswapNGSingleSideSupplyFuse.sol";
import {CurveStableswapNGSingleSideBalanceFuse} from "./../../../contracts/fuses/curve_stableswap_ng/CurveStableswapNGSingleSideBalanceFuse.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {IporFusionAccessManager} from "./../../../contracts/managers/access/IporFusionAccessManager.sol";
import {RoleLib, UsersToRoles} from "./../../RoleLib.sol";
import {USDMPriceFeedArbitrum} from "../../../contracts/price_oracle/price_feed/chains/arbitrum/USDMPriceFeedArbitrum.sol";
import {IChronicle, IToll} from "../../../contracts/price_oracle/ext/IChronicle.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";

contract CurveStableswapNGSingleSideBalanceFuseTest is Test {
    using SafeERC20 for ERC20;

    struct SupportedToken {
        address asset;
        string name;
    }

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
    address public constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address public constant USDM = 0x59D9356E565Ab3A36dD77763Fc0d87fEaf85508C;
    address public constant DAI = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;
    address public constant USD = 0x0000000000000000000000000000000000000348;
    address public constant CHRONICLE_ADMIN = 0x39aBD7819E5632Fa06D2ECBba45Dca5c90687EE3;
    address public constant WUSDM_USD_ORACLE_FEED = 0xdC6720c996Fad27256c7fd6E0a271e2A4687eF18;

    IChronicle public constant CHRONICLE = IChronicle(WUSDM_USD_ORACLE_FEED);

    ICurveStableswapNG public constant CURVE_STABLESWAP_NG = ICurveStableswapNG(CURVE_STABLESWAP_NG_POOL);

    USDMPriceFeedArbitrum public priceFeed;

    PlasmaVault public plasmaVault;

    address public atomist = address(this);
    address public alpha = address(0x1);
    address public depositor = address(0x2);

    address public constant OWNER = 0xD92E9F039E4189c342b4067CC61f5d063960D248;

    PriceOracleMiddleware private priceOracleMiddlewareProxy;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 202220653);
        priceFeed = new USDMPriceFeedArbitrum();
        // price feed admin needs to whitelist the caller address for reading the price
        vm.prank(CHRONICLE_ADMIN);
        IToll(address(CHRONICLE)).kiss(address(priceFeed));
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf);
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

    function testShouldBeAbleToCalculateBalanceWhenSupplySingleAsset() external {
        // given
        CurveStableswapNGSingleSideSupplyFuse fuse = new CurveStableswapNGSingleSideSupplyFuse(1);
        CurveStableswapNGSingleSideBalanceFuse balanceFuse = new CurveStableswapNGSingleSideBalanceFuse(1);

        MarketSubstratesConfig[] memory marketConfigs = createMarketConfigs(fuse);
        address[] memory fuses = createFuses(fuse);
        MarketBalanceFuseConfig[] memory balanceFuses = createBalanceFuses(fuse, balanceFuse);
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles);

        uint256 amount = 100 * 10 ** ERC20(USDM).decimals();

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                "Plasma Vault",
                "PLASMA",
                USDM,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );

        setupRoles(plasmaVault, accessManager);

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(fuse),
            abi.encodeWithSignature(
                "enter((address,address,uint256,uint256))",
                CurveStableswapNGSingleSideSupplyFuseEnterData({
                    curveStableswapNG: CURVE_STABLESWAP_NG,
                    asset: USDM,
                    assetAmount: amount,
                    minLpTokenAmountReceived: 0
                })
            )
        );

        _supplyTokens(USDM, address(depositor), 1_000 * 10 ** ERC20(USDM).decimals());

        vm.startPrank(depositor);
        ERC20(USDM).approve(address(plasmaVault), 1_000 * 10 ** ERC20(USDM).decimals());
        plasmaVault.deposit(1_000 * 10 ** ERC20(USDM).decimals(), address(depositor));
        vm.stopPrank();

        PlasmaVaultState memory beforeState = getPlasmaVaultState(plasmaVault, fuse, USDM);

        // when
        vm.startPrank(alpha);
        plasmaVault.execute(calls);
        vm.stopPrank();

        // then
        PlasmaVaultState memory afterState = getPlasmaVaultState(plasmaVault, fuse, USDM);

        assertApproxEqAbs(
            beforeState.vaultBalance,
            1_000 * 10 ** ERC20(USDM).decimals(),
            100,
            "Balance before should be 1_000 * 10 ** ERC20(USDM).decimals()"
        );
        assertApproxEqAbs(
            beforeState.vaultTotalAssets,
            1_000 * 10 ** ERC20(USDM).decimals(),
            100,
            "Total assets before should be 1_000 * 10 ** ERC20(USDM).decimals()"
        );
        assertEq(
            beforeState.vaultBalance,
            beforeState.vaultTotalAssets,
            "Balance before should be equal to total assets"
        );
        assertEq(beforeState.vaultTotalAssetsInMarket, 0, "Total assets in market before should be 0");
        assertEq(beforeState.vaultLpTokensBalance, 0, "LP tokens balance before should be 0");
        assertGt(beforeState.vaultBalance, afterState.vaultBalance, "vaultBalance should decrease after supply");
        assertApproxEqAbs(
            afterState.vaultBalance + amount,
            beforeState.vaultBalance,
            100,
            "vaultBalance should decrease by amount"
        );
        assertApproxEqAbs(
            afterState.vaultTotalAssets,
            afterState.vaultBalance + afterState.vaultTotalAssetsInMarket,
            100
        );
        assertGt(
            afterState.vaultTotalAssetsInMarket,
            beforeState.vaultTotalAssetsInMarket,
            "vaultTotalAssetsInMarket should increase after supply"
        );
        assertTrue(
            afterState.vaultLpTokensBalance > beforeState.vaultLpTokensBalance,
            "vaultLpTokensBalance should increase after supply"
        );
        assertApproxEqAbs(
            CURVE_STABLESWAP_NG.calc_withdraw_one_coin(afterState.vaultLpTokensBalance, 1),
            afterState.vaultTotalAssetsInMarket,
            100
        );
    }

    function testShouldBeAbleToCalculateBalanceWhenSupplyAndExitSingleAsset() external {
        // given
        CurveStableswapNGSingleSideSupplyFuse fuse = new CurveStableswapNGSingleSideSupplyFuse(1);
        CurveStableswapNGSingleSideBalanceFuse balanceFuse = new CurveStableswapNGSingleSideBalanceFuse(1);

        MarketSubstratesConfig[] memory marketConfigs = createMarketConfigs(fuse);
        address[] memory fuses = createFuses(fuse);
        MarketBalanceFuseConfig[] memory balanceFuses = createBalanceFuses(fuse, balanceFuse);
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles);

        uint256 amount = 100 * 10 ** ERC20(USDM).decimals();

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                "Plasma Vault",
                "PLASMA",
                USDM,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );

        setupRoles(plasmaVault, accessManager);

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(fuse),
            abi.encodeWithSignature(
                "enter((address,address,uint256,uint256))",
                CurveStableswapNGSingleSideSupplyFuseEnterData({
                    curveStableswapNG: CURVE_STABLESWAP_NG,
                    asset: USDM,
                    assetAmount: amount,
                    minLpTokenAmountReceived: 0
                })
            )
        );

        _supplyTokens(USDM, address(depositor), 1_000 * 10 ** ERC20(USDM).decimals());

        vm.startPrank(depositor);
        ERC20(USDM).approve(address(plasmaVault), 1_000 * 10 ** ERC20(USDM).decimals());
        plasmaVault.deposit(1_000 * 10 ** ERC20(USDM).decimals(), address(depositor));
        vm.stopPrank();

        vm.startPrank(alpha);
        plasmaVault.execute(calls);
        vm.stopPrank();

        PlasmaVaultState memory beforeExitState = getPlasmaVaultState(plasmaVault, fuse, USDM);

        FuseAction[] memory callsSecond = new FuseAction[](1);
        callsSecond[0] = FuseAction(
            address(fuse),
            abi.encodeWithSignature(
                "exit((address,uint256,address,uint256))",
                CurveStableswapNGSingleSideSupplyFuseExitData({
                    curveStableswapNG: CURVE_STABLESWAP_NG,
                    lpTokenAmount: beforeExitState.vaultLpTokensBalance,
                    asset: USDM,
                    minCoinAmountReceived: 0
                })
            )
        );
        vm.warp(block.timestamp + 100 days);

        // when
        vm.prank(alpha);
        plasmaVault.execute(callsSecond);

        // then
        PlasmaVaultState memory afterExitState = getPlasmaVaultState(plasmaVault, fuse, USDM);
        assertApproxEqAbs(
            beforeExitState.vaultBalance,
            1_000 * 10 ** ERC20(USDM).decimals() - amount,
            100,
            "Balance before should be 900"
        );
        assertApproxEqAbs(
            beforeExitState.vaultTotalAssets,
            beforeExitState.vaultBalance + beforeExitState.vaultTotalAssetsInMarket,
            100,
            "vaulBalance + vaultTotalAssetsInMarket should equal vaultTotalAssets"
        );
        assertGt(
            beforeExitState.vaultTotalAssetsInMarket,
            afterExitState.vaultTotalAssetsInMarket,
            "vaultTotalAssetsInMarket should decrease after exit"
        );
        assertEq(afterExitState.vaultTotalAssetsInMarket, 0, "vaultTotalAssetsInMarket should be 0 after exit");
        assertGt(
            beforeExitState.vaultLpTokensBalance,
            afterExitState.vaultLpTokensBalance,
            "vaultLpTokensBalance should decrease after exit"
        );
        assertEq(afterExitState.vaultLpTokensBalance, 0, "vaultLpTokensBalance should be 0 after exit");
        assertEq(
            afterExitState.vaultBalance,
            afterExitState.vaultTotalAssets,
            "vaultBalance and vaultTotalAssets should be equal after exit"
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
        return RoleLib.createAccessManager(usersToRoles, 0, vm);
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
        PlasmaVault plasmaVault,
        CurveStableswapNGSingleSideSupplyFuse fuse,
        address asset
    ) private view returns (PlasmaVaultState memory) {
        return
            PlasmaVaultState({
                vaultBalance: ERC20(asset).balanceOf(address(plasmaVault)),
                vaultTotalAssets: plasmaVault.totalAssets(),
                vaultTotalAssetsInMarket: plasmaVault.totalAssetsInMarket(fuse.MARKET_ID()),
                vaultLpTokensBalance: ERC20(CURVE_STABLESWAP_NG_POOL).balanceOf(address(plasmaVault))
            });
    }

    function setupRoles(PlasmaVault plasmaVault, IporFusionAccessManager accessManager) public {
        usersToRoles.superAdmin = atomist;
        usersToRoles.atomist = atomist;
        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(plasmaVault), accessManager);
    }
}
