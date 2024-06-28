// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PlasmaVault, FeeConfig, FuseAction, MarketBalanceFuseConfig, MarketSubstratesConfig, PlasmaVaultInitData} from "./../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultConfigLib} from "./../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {ICurveStableswapNG} from "./../../../contracts/fuses/curve_stableswap_ng/ext/ICurveStableswapNG.sol";
import {CurveStableswapNGSingleSideSupplyFuse, CurveStableswapNGSingleSideSupplyFuseEnterData, CurveStableswapNGSingleSideSupplyFuseExitData} from "./../../../contracts/fuses/curve_stableswap_ng/CurveStableswapNGSingleSideSupplyFuse.sol";
import {CurveStableswapNGSingleSideBalanceFuse} from "./../../../contracts/fuses/curve_stableswap_ng/CurveStableswapNGSingleSideBalanceFuse.sol";
import {IporFusionAccessManager} from "./../../../contracts/managers/IporFusionAccessManager.sol";
import {RoleLib, UsersToRoles} from "./../../RoleLib.sol";
import {PriceOracleMock} from "./PriceOracleMock.sol";

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

    address public constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address public constant USDM = 0x59D9356E565Ab3A36dD77763Fc0d87fEaf85508C;
    address public constant DAI = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;
    address public constant USD = 0x0000000000000000000000000000000000000348;

    ICurveStableswapNG public constant CURVE_STABLESWAP_NG = ICurveStableswapNG(CURVE_STABLESWAP_NG_POOL);

    PriceOracleMock public priceOracleMock;

    PlasmaVault public plasmaVault;

    address public atomist = address(this);
    address public alpha = address(0x1);

    SupportedToken public activeToken = SupportedToken({asset: USDM, name: "USDM"});

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 202220653);
    }

    function testShouldBeAbleToCalculateBalanceWhenSupplySingleAsset() external {
        // given
        priceOracleMock = new PriceOracleMock(USD, 8);

        CurveStableswapNGSingleSideSupplyFuse fuse = new CurveStableswapNGSingleSideSupplyFuse(
            1,
            address(CURVE_STABLESWAP_NG)
        );
        CurveStableswapNGSingleSideBalanceFuse balanceFuse = new CurveStableswapNGSingleSideBalanceFuse(
            1,
            address(priceOracleMock)
        );

        MarketSubstratesConfig[] memory marketConfigs = createMarketConfigs(fuse);
        address[] memory fuses = createFuses(fuse);
        address[] memory alphas = createAlphas();
        MarketBalanceFuseConfig[] memory balanceFuses = createBalanceFuses(fuse, balanceFuse);
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0;
        amounts[1] = 100 * 10 ** ERC20(USDM).decimals();

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                "Plasma Vault",
                "PLASMA",
                activeToken.asset,
                address(priceOracleMock),
                alphas,
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );

        setupRoles(plasmaVault, accessManager);

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(fuse),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(
                    CurveStableswapNGSingleSideSupplyFuseEnterData({
                        asset: activeToken.asset,
                        amounts: amounts,
                        minMintAmount: 0
                    })
                )
            )
        );

        _supplyTokensToMockVault(activeToken.asset, address(alpha), 1_000 * 10 ** ERC20(activeToken.asset).decimals());

        vm.startPrank(alpha);
        ERC20(activeToken.asset).approve(address(plasmaVault), 1_000 * 10 ** ERC20(activeToken.asset).decimals());
        plasmaVault.deposit(1_000 * 10 ** ERC20(activeToken.asset).decimals(), address(alpha));

        PlasmaVaultState memory beforeState = getPlasmaVaultState(plasmaVault, fuse, activeToken);

        // when
        plasmaVault.execute(calls);
        vm.stopPrank();

        // then
        PlasmaVaultState memory afterState = getPlasmaVaultState(plasmaVault, fuse, activeToken);

        assertEq(beforeState.vaultBalance, 999999999999999999999, "Balance before should be 999999999999999999999");
        assertEq(
            beforeState.vaultTotalAssets,
            999999999999999999999,
            "Total assets before should be 999999999999999999999"
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
            afterState.vaultBalance + amounts[1],
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
        priceOracleMock = new PriceOracleMock(USD, 8);

        CurveStableswapNGSingleSideSupplyFuse fuse = new CurveStableswapNGSingleSideSupplyFuse(
            1,
            address(CURVE_STABLESWAP_NG)
        );
        CurveStableswapNGSingleSideBalanceFuse balanceFuse = new CurveStableswapNGSingleSideBalanceFuse(
            1,
            address(priceOracleMock)
        );

        MarketSubstratesConfig[] memory marketConfigs = createMarketConfigs(fuse);
        address[] memory fuses = createFuses(fuse);
        address[] memory alphas = createAlphas();
        MarketBalanceFuseConfig[] memory balanceFuses = createBalanceFuses(fuse, balanceFuse);
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0;
        amounts[1] = 100 * 10 ** ERC20(USDM).decimals();

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                "Plasma Vault",
                "PLASMA",
                activeToken.asset,
                address(priceOracleMock),
                alphas,
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );

        setupRoles(plasmaVault, accessManager);

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(fuse),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(
                    CurveStableswapNGSingleSideSupplyFuseEnterData({
                        asset: activeToken.asset,
                        amounts: amounts,
                        minMintAmount: 0
                    })
                )
            )
        );

        _supplyTokensToMockVault(activeToken.asset, address(alpha), 1_000 * 10 ** ERC20(activeToken.asset).decimals());

        vm.startPrank(alpha);
        ERC20(activeToken.asset).approve(address(plasmaVault), 1_000 * 10 ** ERC20(activeToken.asset).decimals());
        plasmaVault.deposit(1_000 * 10 ** ERC20(activeToken.asset).decimals(), address(alpha));

        plasmaVault.execute(calls);
        vm.stopPrank();

        PlasmaVaultState memory beforeExitState = getPlasmaVaultState(plasmaVault, fuse, activeToken);

        FuseAction[] memory callsSecond = new FuseAction[](1);
        callsSecond[0] = FuseAction(
            address(fuse),
            abi.encodeWithSignature(
                "exit(bytes)",
                abi.encode(
                    CurveStableswapNGSingleSideSupplyFuseExitData({
                        burnAmount: beforeExitState.vaultLpTokensBalance,
                        asset: activeToken.asset,
                        minReceived: 0
                    })
                )
            )
        );
        vm.warp(block.timestamp + 100 days);

        // when
        vm.prank(alpha);
        plasmaVault.execute(callsSecond);

        // then
        PlasmaVaultState memory afterExitState = getPlasmaVaultState(plasmaVault, fuse, activeToken);
        assertEq(beforeExitState.vaultBalance, 900000000000000000000, "Balance before should be 900000000000000000000");
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

    function _supplyTokensToMockVault(address asset, address to, uint256 amount) private {
        if (asset == USDC) {
            vm.prank(0x05e3a758FdD29d28435019ac453297eA37b61b62); // holder
            ERC20(asset).transfer(to, amount);
        } else if (asset == USDM) {
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
        PlasmaVault plasmaVault,
        CurveStableswapNGSingleSideSupplyFuse fuse,
        SupportedToken memory activeToken
    ) private view returns (PlasmaVaultState memory) {
        return
            PlasmaVaultState({
                vaultBalance: ERC20(activeToken.asset).balanceOf(address(plasmaVault)),
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
