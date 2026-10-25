// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {PlasmaVault, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {
    StakeDaoV2SupplyFuse,
    StakeDaoV2SupplyFuseEnterData
} from "../../../contracts/fuses/stake_dao_v2/StakeDaoV2SupplyFuse.sol";
import {StakeDaoV2BalanceFuse} from "../../../contracts/fuses/stake_dao_v2/StakeDaoV2BalanceFuse.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {InstantWithdrawalFusesParamsStruct} from "../../../contracts/libraries/PlasmaVaultLib.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {IPlasmaVaultGovernance} from "../../../contracts/interfaces/IPlasmaVaultGovernance.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {MockERC4626} from "../../test_helpers/MockErc4626.sol";
import {IPriceOracleMiddleware} from "../../../contracts/price_oracle/IPriceOracleMiddleware.sol";
import {PriceOracleMiddlewareManager} from "../../../contracts/managers/price/PriceOracleMiddlewareManager.sol";
import {IporMath} from "../../../contracts/libraries/math/IporMath.sol";
import {PlasmaVaultLib} from "../../../contracts/libraries/PlasmaVaultLib.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {
    MarketSubstratesConfig,
    MarketBalanceFuseConfig,
    FeeConfig,
    PlasmaVaultInitData
} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {RoleLib, UsersToRoles} from "../../RoleLib.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {PlasmaVaultConfigurator} from "../../utils/PlasmaVaultConfigurator.sol";
import {ERC4626PriceFeed} from "../../../contracts/price_oracle/price_feed/ERC4626PriceFeed.sol";
import {PlasmaVaultCloneLib} from "../../test_helpers/PlasmaVaultCloneLib.sol";

/// @notice Regression tests for IL-7947: StakeDaoV2BalanceFuse.balanceOf() must value loose
/// (unstaked) LP-vault shares held by the PlasmaVault, not just reward-vault shares. Without this,
/// StakeDaoV2SupplyFuse's instant withdraw (`_exit` with exception catching) can succeed on the
/// outer reward-vault redeem while the inner LP-vault redeem fails and is swallowed, leaving the
/// PlasmaVault holding LP-vault shares that the market values at zero, inside a permissionless
/// user `withdraw()`.
///
/// This first contract exercises the full end-to-end bug: a real user `withdraw()` on a forked,
/// freshly-deployed `StakeDaoV2SupplyFuse` + `StakeDaoV2BalanceFuse` pair, with the inner LP-vault
/// redeem forced to fail via `vm.mockCallRevert`.
contract StakeDaoV2StrandedLpSharesInstantWithdrawTest is Test {
    address public constant FUSION_PLASMA_VAULT = 0x4c4f752fa54dafB6d51B4A39018271c90bA1156F;
    address public constant FUSION_ACCESS_MANAGER = 0x497F8A5FcA953cd507A67e112B7D95bc712B23F1;
    address public constant CRV_USD = 0x498Bf2B1e120FeD3ad3D42EA2165E9b73f99C1e5;

    address public constant ATOMIST = 0x0Ed2fC947952896E6bf90001045f064Fe5dbC344;
    address public constant FUSE_MANAGER = 0x0Ed2fC947952896E6bf90001045f064Fe5dbC344;
    address public constant ALPHA = 0xd8a1087d6bbCd5533F819A4496a06AF452609b99;

    /// @dev A fresh, uninvolved address rather than the real crvUSD-holder EOA the sibling suites
    /// reuse as USER: that address turns out to also be a counterparty in the WETH LlamaLend
    /// vault's real redeem flow (observed on-chain: redeeming that vault's shares moves crvUSD
    /// through it), which would corrupt this test's before/after balance accounting once the WETH
    /// leg is exercised for real liquidity. `deal` funds this address directly instead.
    address public constant USER = address(0xBEEF7947);

    /// @dev "WBTC" LlamaLend reward vault — the market whose position gets fully stranded.
    address public constant STAKEDAO_V2_REWARD_VAULT_LLAMALEND_WBTC = 0x1544E663DD326a6d853a0cc4ceEf0860eb82B287;
    address public constant STAKEDAO_V2_REWARD_VAULT_LLAMALEND_WBTC_LP = 0xe07f1151887b8FDC6800f737252f6b91b46b5865;

    /// @dev "WETH" LlamaLend reward vault — kept healthy, supplies the real liquidity that lets the
    /// user's withdraw() succeed even though the WBTC market's instant withdraw silently fails.
    address public constant STAKEDAO_V2_REWARD_VAULT_LLAMALEND_WETH = 0x2abaD3D0c104fE1C9A412431D070e73108B4eFF8;

    StakeDaoV2SupplyFuse public supplyFuse;
    StakeDaoV2BalanceFuse public balanceFuse;

    uint256 public constant DEPOSIT_AMOUNT = 100_000e18;
    uint256 public constant WBTC_STAKE_AMOUNT = 35_000e18;
    uint256 public constant WETH_STAKE_AMOUNT = 55_000e18;
    /// @dev idle = 100_000e18 - 35_000e18 - 55_000e18 = 10_000e18

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 382806620);

        vm.startPrank(ATOMIST);
        PlasmaVaultGovernance(FUSION_PLASMA_VAULT).convertToPublicVault();
        vm.stopPrank();

        deal(CRV_USD, USER, DEPOSIT_AMOUNT);

        vm.startPrank(USER);
        IERC20(CRV_USD).approve(FUSION_PLASMA_VAULT, type(uint256).max);
        PlasmaVault(FUSION_PLASMA_VAULT).deposit(DEPOSIT_AMOUNT, USER);
        vm.stopPrank();

        supplyFuse = new StakeDaoV2SupplyFuse(IporFusionMarkets.STAKE_DAO_V2);
        balanceFuse = new StakeDaoV2BalanceFuse(IporFusionMarkets.STAKE_DAO_V2);

        address[] memory fuses = new address[](1);
        fuses[0] = address(supplyFuse);

        vm.startPrank(FUSE_MANAGER);
        PlasmaVaultGovernance(FUSION_PLASMA_VAULT).addFuses(fuses);
        /// @dev Replace whatever balance fuse market 31 already has configured with a freshly
        /// deployed one, so this test executes the MODIFIED StakeDaoV2BalanceFuse bytecode rather
        /// than whatever was deployed on-chain at the pinned fork block.
        PlasmaVaultGovernance(FUSION_PLASMA_VAULT).addBalanceFuse(IporFusionMarkets.STAKE_DAO_V2, address(balanceFuse));
        vm.stopPrank();

        _stakeIntoBothVaults();
        _configureInstantWithdrawalFuses();
    }

    function _stakeIntoBothVaults() private {
        FuseAction[] memory actions = new FuseAction[](2);
        actions[0] = FuseAction(
            address(supplyFuse),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                StakeDaoV2SupplyFuseEnterData({
                    rewardVault: STAKEDAO_V2_REWARD_VAULT_LLAMALEND_WBTC,
                    lpTokenUnderlyingAmount: WBTC_STAKE_AMOUNT,
                    minLpTokenUnderlyingAmount: (WBTC_STAKE_AMOUNT * 99) / 100
                })
            )
        );
        actions[1] = FuseAction(
            address(supplyFuse),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                StakeDaoV2SupplyFuseEnterData({
                    rewardVault: STAKEDAO_V2_REWARD_VAULT_LLAMALEND_WETH,
                    lpTokenUnderlyingAmount: WETH_STAKE_AMOUNT,
                    minLpTokenUnderlyingAmount: (WETH_STAKE_AMOUNT * 99) / 100
                })
            )
        );

        vm.startPrank(ALPHA);
        PlasmaVault(FUSION_PLASMA_VAULT).execute(actions);
        vm.stopPrank();
    }

    /// @dev Configures TWO instant-withdrawal fuse entries for the same StakeDaoV2SupplyFuse
    /// instance: WBTC first (the one whose inner redeem will be forced to fail), then WETH
    /// (healthy). `PlasmaVaultMarketsLib.withdrawFromMarkets` explicitly supports the same fuse
    /// appearing multiple times with different substrate params.
    function _configureInstantWithdrawalFuses() private {
        vm.startPrank(ATOMIST);
        IporFusionAccessManager(FUSION_ACCESS_MANAGER).grantRole(
            Roles.CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE,
            ATOMIST,
            0
        );
        vm.stopPrank();

        InstantWithdrawalFusesParamsStruct[] memory instantWithdrawFuses = new InstantWithdrawalFusesParamsStruct[](2);

        bytes32[] memory wbtcParams = new bytes32[](2);
        wbtcParams[0] = 0;
        wbtcParams[1] = PlasmaVaultConfigLib.addressToBytes32(STAKEDAO_V2_REWARD_VAULT_LLAMALEND_WBTC);
        instantWithdrawFuses[0] = InstantWithdrawalFusesParamsStruct({fuse: address(supplyFuse), params: wbtcParams});

        bytes32[] memory wethParams = new bytes32[](2);
        wethParams[0] = 0;
        wethParams[1] = PlasmaVaultConfigLib.addressToBytes32(STAKEDAO_V2_REWARD_VAULT_LLAMALEND_WETH);
        instantWithdrawFuses[1] = InstantWithdrawalFusesParamsStruct({fuse: address(supplyFuse), params: wethParams});

        vm.startPrank(ATOMIST);
        IPlasmaVaultGovernance(FUSION_PLASMA_VAULT).configureInstantWithdrawalFuses(instantWithdrawFuses);
        vm.stopPrank();
    }

    /// @notice The TODO's mandated test: an instant withdraw whose inner LP-vault redeem fails must
    /// not silently drop totalAssets() by more than the amount actually paid out to the withdrawer.
    /// @dev Fails without the fix: the WBTC market's entire staked position (reward-vault shares)
    /// gets redeemed to LP-vault shares (outer redeem succeeds) but those LP-vault shares are
    /// invisible to the balance fuse, so totalAssets() drops by the paid-out amount PLUS the whole
    /// stranded WBTC position value. Passes with the fix: loose LP-vault shares stay valued, so
    /// totalAssets() drops by only the paid-out amount.
    function test_instantWithdrawWithFailedInnerRedeemDoesNotDropTotalAssetsBeyondPaidAmount() public {
        // given
        vm.mockCallRevert(
            STAKEDAO_V2_REWARD_VAULT_LLAMALEND_WBTC_LP,
            abi.encodeWithSelector(IERC4626.redeem.selector),
            "MOCK_INNER_REDEEM_REVERT"
        );

        uint256 withdrawAmount = 55_000e18; // idle(10_000e18) + shortfall(~45_000e18), forcing a
        // shortfall (~45_000e18) that exceeds the WBTC position (35_000e18, forcing a full
        // drain) but stays within the WETH position's capacity (55_000e18) so the WETH leg can
        // cover the rest and the overall withdraw() succeeds.

        uint256 totalAssetsBefore = PlasmaVault(FUSION_PLASMA_VAULT).totalAssets();
        uint256 userCrvUsdBefore = IERC20(CRV_USD).balanceOf(USER);

        vm.warp(block.timestamp + 2);

        // when
        vm.startPrank(USER);
        PlasmaVault(FUSION_PLASMA_VAULT).withdraw(withdrawAmount, USER, USER);
        vm.stopPrank();

        // then
        uint256 totalAssetsAfter = PlasmaVault(FUSION_PLASMA_VAULT).totalAssets();
        uint256 userCrvUsdAfter = IERC20(CRV_USD).balanceOf(USER);

        uint256 paidOut = userCrvUsdAfter - userCrvUsdBefore;
        assertEq(paidOut, withdrawAmount, "User should receive exactly the requested withdraw amount");

        uint256 totalAssetsDrop = totalAssetsBefore - totalAssetsAfter;

        // @dev Tolerance is withdrawAmount / 10_000 (5.5e18) -- the independent cycle-1 verifier
        // measured the fixed code's real residual at ~1.94e14 (4 ppb of the paid amount), so this
        // bound still leaves ~4 orders of magnitude of margin over the true residual while being
        // ~6,364x tighter than the ~35,010e18 stranded-WBTC-position regression it must catch
        // (35,010e18 / 5.5e18 ~= 6,365x), a far larger safety margin than the previous
        // withdrawAmount / 100 (550e18) bound's ~64x.
        assertApproxEqAbs(
            totalAssetsDrop,
            paidOut,
            withdrawAmount / 10_000,
            "totalAssets() must drop by only the amount paid out, not also by the stranded WBTC LP-vault shares"
        );
    }
}

/// @notice Second contract: exercises `StakeDaoV2BalanceFuse.balanceOf()` directly against a
/// FusionFactory-deployed vault, using mock ERC4626 vaults so the two changes shipped in IL-7947
/// (valuing loose LP-vault shares at all, and deduplicating per LP token) can each be pinned in
/// isolation.
contract StakeDaoV2StrandedLpSharesBalanceFuseTest is Test {
    address constant FUSION_PLASMA_VAULT_sdSaveUSDC = 0xa4f39ec96B7A2178B381dE9CDc9021fB2490b409;
    address constant FUSION_ACCESS_MANAGER = 0x19BAf9a25D1a4619Be1f7065c6A8d181a524991D;
    address constant FUSION_PRICE_MANAGER = 0x40e2d65023ef964A673950Df587cE239Bb1CE43d;
    address constant FUSION_PLASMA_VAULT_OWNER = 0xB0552b6860CE5C0202976Db056b5e3Cc4f9CC765;

    address constant STAKEDAO_V2_REWARD_VAULT_LLAMALEND_EYWA = 0x555928DC8973F10f5bbA677d0EBB7cbac968e36A;

    address constant CHAINLINK_PRICE_FEED_USDC = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    /// @dev https://data.chain.link/feeds/arbitrum/mainnet/crvusd-usd
    address constant CHAINLINK_PRICE_FEED_CRV_USD = 0x0a32255dd4BB6177C994bAAc73E0606fDD568f66;

    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant CRV_USD = 0x498Bf2B1e120FeD3ad3D42EA2165E9b73f99C1e5;

    address CRV_USD_HOLDER = 0xB5c6082d3307088C98dA8D79991501E113e6365d;

    address atomist;
    address alpha;

    address stakeDaoV2SupplyFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 368270603);

        atomist = address(0x777);
        alpha = address(0x555);

        vm.startPrank(FUSION_PLASMA_VAULT_OWNER);
        IporFusionAccessManager(FUSION_ACCESS_MANAGER).grantRole(Roles.ATOMIST_ROLE, atomist, 0);
        vm.stopPrank();

        vm.startPrank(atomist);
        IporFusionAccessManager(FUSION_ACCESS_MANAGER).grantRole(Roles.FUSE_MANAGER_ROLE, atomist, 0);
        IporFusionAccessManager(FUSION_ACCESS_MANAGER).grantRole(Roles.ALPHA_ROLE, alpha, 0);
        IporFusionAccessManager(FUSION_ACCESS_MANAGER).grantRole(
            Roles.PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE,
            atomist,
            0
        );
        /// @dev Needed to force-refresh market 34's cached balance via `PlasmaVault.updateMarketsBalances`
        /// after minting loose LP-vault shares directly (i.e. outside of any FuseAction), since
        /// `totalAssetsInMarket()` reads a cached value that is otherwise only refreshed by execute()/
        /// deposit()/withdraw() flows.
        IporFusionAccessManager(FUSION_ACCESS_MANAGER).grantRole(Roles.UPDATE_MARKETS_BALANCES_ROLE, atomist, 0);
        vm.stopPrank();

        address[] memory assets = new address[](2);
        assets[0] = USDC;
        assets[1] = CRV_USD;
        address[] memory sources = new address[](2);
        sources[0] = CHAINLINK_PRICE_FEED_USDC;
        sources[1] = CHAINLINK_PRICE_FEED_CRV_USD;

        vm.startPrank(atomist);
        PriceOracleMiddlewareManager(FUSION_PRICE_MANAGER).setAssetsPriceSources(assets, sources);
        vm.stopPrank();

        stakeDaoV2SupplyFuse = address(new StakeDaoV2SupplyFuse(IporFusionMarkets.STAKE_DAO_V2));

        address[] memory fuses = new address[](1);
        fuses[0] = stakeDaoV2SupplyFuse;

        vm.startPrank(atomist);
        PlasmaVaultGovernance(FUSION_PLASMA_VAULT_sdSaveUSDC).addFuses(fuses);
        /// @dev Replace whatever balance fuse market 31 already has configured with a freshly
        /// deployed one, so these tests execute the MODIFIED StakeDaoV2BalanceFuse bytecode rather
        /// than whatever was deployed on-chain at the pinned fork block.
        PlasmaVaultGovernance(FUSION_PLASMA_VAULT_sdSaveUSDC).addBalanceFuse(
            IporFusionMarkets.STAKE_DAO_V2,
            address(new StakeDaoV2BalanceFuse(IporFusionMarkets.STAKE_DAO_V2))
        );
        vm.stopPrank();
    }

    /// @notice Loose (unstaked) LP-vault shares held by the PlasmaVault must be valued by the
    /// balance fuse.
    /// @dev Fails without the fix: totalAssetsInMarket() would not move at all when loose LP-vault
    /// shares are deposited directly (increase == 0). Passes with the fix. The expected increase is
    /// computed by replicating the exact conversion `PlasmaVaultMarketsLib.updateMarketsBalances`
    /// applies (WAD USD -> vault base-asset decimals), not by guessing a number, so the tolerance
    /// (10 units of the 6-decimal base asset, i.e. $0.00001) reflects only integer-division
    /// rounding, not fixture slack.
    function test_balanceFuseValuesLooseLpShares() public {
        // given
        MockERC4626 lpVault = new MockERC4626(IERC20(CRV_USD), "Mock LP Vault", "mLP");
        MockERC4626 rewardVault = new MockERC4626(IERC20(address(lpVault)), "Mock Reward Vault", "mRV");

        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(address(rewardVault));

        vm.prank(atomist);
        PlasmaVaultGovernance(FUSION_PLASMA_VAULT_sdSaveUSDC).grantMarketSubstrates(
            IporFusionMarkets.STAKE_DAO_V2,
            substrates
        );

        uint256 dealAmount = 1_000e18; // crvUSD, 18 decimals

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.STAKE_DAO_V2;

        // @dev totalAssetsInMarket() reads a cached balance that is only refreshed by execute()/
        // deposit()/withdraw() flows, so force a refresh here explicitly (mirrors granting the
        // substrate above, which by itself does not move the cached balance either).
        vm.prank(atomist);
        PlasmaVault(FUSION_PLASMA_VAULT_sdSaveUSDC).updateMarketsBalances(marketIds);

        uint256 balanceInMarketBefore = PlasmaVault(FUSION_PLASMA_VAULT_sdSaveUSDC).totalAssetsInMarket(
            IporFusionMarkets.STAKE_DAO_V2
        );

        // when: mint LOOSE LP-vault shares directly to the PlasmaVault (never staked in the reward
        // vault) -- exactly the state StakeDaoV2SupplyFuse's instant withdraw can leave behind.
        vm.prank(CRV_USD_HOLDER);
        IERC20(CRV_USD).transfer(address(this), dealAmount);
        IERC20(CRV_USD).approve(address(lpVault), dealAmount);
        lpVault.deposit(dealAmount, FUSION_PLASMA_VAULT_sdSaveUSDC);

        vm.prank(atomist);
        PlasmaVault(FUSION_PLASMA_VAULT_sdSaveUSDC).updateMarketsBalances(marketIds);

        uint256 balanceInMarketAfter = PlasmaVault(FUSION_PLASMA_VAULT_sdSaveUSDC).totalAssetsInMarket(
            IporFusionMarkets.STAKE_DAO_V2
        );

        // then
        uint256 actualIncrease = balanceInMarketAfter - balanceInMarketBefore;

        (uint256 crvUsdPrice, uint256 crvUsdPriceDecimals) = IPriceOracleMiddleware(FUSION_PRICE_MANAGER).getAssetPrice(
            CRV_USD
        );
        (uint256 usdcPrice, uint256 usdcPriceDecimals) = IPriceOracleMiddleware(FUSION_PRICE_MANAGER).getAssetPrice(
            USDC
        );

        // @dev lpVault is a freshly deployed, zero-fee ERC4626, so convertToAssets(dealAmount) ==
        // dealAmount for this first depositor -- replicates StakeDaoV2BalanceFuse.balanceOf()'s
        // own math exactly.
        uint256 expectedWadUsd = IporMath.convertToWad(dealAmount * crvUsdPrice, 18 + crvUsdPriceDecimals);
        uint256 expectedIncrease = IporMath.convertWadToAssetDecimals(
            (expectedWadUsd * (10 ** usdcPriceDecimals)) / usdcPrice,
            PlasmaVault(FUSION_PLASMA_VAULT_sdSaveUSDC).decimals() - PlasmaVaultLib.DECIMALS_OFFSET
        );

        assertGt(actualIncrease, 0, "Loose LP-vault shares must be valued (0 increase means the fix is missing)");
        assertApproxEqAbs(
            actualIncrease,
            expectedIncrease,
            10,
            "Loose LP-vault shares must be valued using the same WAD-USD -> base-asset conversion as staked shares"
        );
    }

    /// @notice Two granted reward vaults that share the same LP token must not double-count that
    /// LP token's loose balance.
    /// @dev Isolates the dedup change specifically: fails if the loose-LP-share addition exists but
    /// the per-LP-token dedup does not (balance would jump again when the second, still-unstaked,
    /// reward vault for the SAME LP token is granted). Passes with the dedup: granting a second
    /// reward vault for an already-counted LP token must not change the market balance at all.
    function test_balanceFuseDoesNotDoubleCountSharedLpToken() public {
        // given
        MockERC4626 lpVault = new MockERC4626(IERC20(CRV_USD), "Mock LP Vault 2", "mLP2");
        MockERC4626 rewardVaultA = new MockERC4626(IERC20(address(lpVault)), "Mock Reward Vault A", "mRVA");
        MockERC4626 rewardVaultB = new MockERC4626(IERC20(address(lpVault)), "Mock Reward Vault B", "mRVB");

        bytes32[] memory substratesWithOnlyA = new bytes32[](1);
        substratesWithOnlyA[0] = PlasmaVaultConfigLib.addressToBytes32(address(rewardVaultA));

        vm.prank(atomist);
        PlasmaVaultGovernance(FUSION_PLASMA_VAULT_sdSaveUSDC).grantMarketSubstrates(
            IporFusionMarkets.STAKE_DAO_V2,
            substratesWithOnlyA
        );

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.STAKE_DAO_V2;

        uint256 dealAmount = 500e18;
        vm.prank(CRV_USD_HOLDER);
        IERC20(CRV_USD).transfer(address(this), dealAmount);
        IERC20(CRV_USD).approve(address(lpVault), dealAmount);
        lpVault.deposit(dealAmount, FUSION_PLASMA_VAULT_sdSaveUSDC);

        // @dev totalAssetsInMarket() reads a cached balance; force a refresh after minting the
        // loose LP shares before reading it.
        vm.prank(atomist);
        PlasmaVault(FUSION_PLASMA_VAULT_sdSaveUSDC).updateMarketsBalances(marketIds);

        uint256 balanceWithOnlyA = PlasmaVault(FUSION_PLASMA_VAULT_sdSaveUSDC).totalAssetsInMarket(
            IporFusionMarkets.STAKE_DAO_V2
        );
        assertGt(balanceWithOnlyA, 0, "Sanity check: loose LP shares must already be valued via substrate A alone");

        // when: grant a SECOND reward vault whose asset() is the SAME LP token. grantMarketSubstrates
        // replaces the whole substrate list, so both A and B must be passed together to keep A granted.
        bytes32[] memory substratesWithBothAAndB = new bytes32[](2);
        substratesWithBothAAndB[0] = PlasmaVaultConfigLib.addressToBytes32(address(rewardVaultA));
        substratesWithBothAAndB[1] = PlasmaVaultConfigLib.addressToBytes32(address(rewardVaultB));

        vm.prank(atomist);
        PlasmaVaultGovernance(FUSION_PLASMA_VAULT_sdSaveUSDC).grantMarketSubstrates(
            IporFusionMarkets.STAKE_DAO_V2,
            substratesWithBothAAndB
        );

        vm.prank(atomist);
        PlasmaVault(FUSION_PLASMA_VAULT_sdSaveUSDC).updateMarketsBalances(marketIds);

        uint256 balanceWithBothAB = PlasmaVault(FUSION_PLASMA_VAULT_sdSaveUSDC).totalAssetsInMarket(
            IporFusionMarkets.STAKE_DAO_V2
        );

        // then
        assertEq(
            balanceWithBothAB,
            balanceWithOnlyA,
            "Granting a second reward vault that shares an already-counted LP token must not change the market balance"
        );
    }

    /// @notice Both terms of the summation `StakeDaoV2BalanceFuse.sol:81` (loose) + `:86`
    /// (`convertToAssets` of the combined staked+loose amount) must be exercised together on the
    /// SAME LP token in one call, not only separately (the other two tests in this contract each
    /// exercise only one of the two: `test_balanceFuseValuesLooseLpShares` is loose-only,
    /// `test_balanceFuseDoesNotDoubleCountSharedLpToken` has zero staked shares at all).
    /// @dev Fails if the addition/summation regresses to overwriting instead of adding (the staked
    /// term alone, or the loose term alone, would each undercount by exactly the missing half).
    /// Passes when both terms are correctly summed before `convertToAssets()`.
    function test_balanceFuseValuesStakedAndLooseSharesOfTheSameLpTokenTogether() public {
        // given
        MockERC4626 lpVault = new MockERC4626(IERC20(CRV_USD), "Mock LP Vault 3", "mLP3");
        MockERC4626 rewardVault = new MockERC4626(IERC20(address(lpVault)), "Mock Reward Vault 3", "mRV3");

        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(address(rewardVault));

        vm.prank(atomist);
        PlasmaVaultGovernance(FUSION_PLASMA_VAULT_sdSaveUSDC).grantMarketSubstrates(
            IporFusionMarkets.STAKE_DAO_V2,
            substrates
        );

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.STAKE_DAO_V2;

        uint256 stakedLpAmount = 300e18; // crvUSD, 18 decimals, ends up staked in rewardVault
        uint256 looseLpAmount = 400e18; // crvUSD, 18 decimals, stays loose (unstaked) in the LP vault

        vm.startPrank(CRV_USD_HOLDER);
        IERC20(CRV_USD).transfer(address(this), stakedLpAmount + looseLpAmount);
        vm.stopPrank();

        // Mint LP-vault shares for the staked leg, then stake them into the reward vault on the
        // PlasmaVault's behalf (this exercises the `:67` staked term).
        IERC20(CRV_USD).approve(address(lpVault), stakedLpAmount);
        uint256 lpSharesForStaking = lpVault.deposit(stakedLpAmount, address(this));
        IERC20(address(lpVault)).approve(address(rewardVault), lpSharesForStaking);
        rewardVault.deposit(lpSharesForStaking, FUSION_PLASMA_VAULT_sdSaveUSDC);

        // Mint LP-vault shares for the loose leg directly to the PlasmaVault, never staked (this
        // exercises the `:81` loose term on the SAME lpTokenAddress as the staked leg above).
        IERC20(CRV_USD).approve(address(lpVault), looseLpAmount);
        lpVault.deposit(looseLpAmount, FUSION_PLASMA_VAULT_sdSaveUSDC);

        vm.prank(atomist);
        PlasmaVault(FUSION_PLASMA_VAULT_sdSaveUSDC).updateMarketsBalances(marketIds);

        uint256 combinedBalance = PlasmaVault(FUSION_PLASMA_VAULT_sdSaveUSDC).totalAssetsInMarket(
            IporFusionMarkets.STAKE_DAO_V2
        );

        // then: the combined balance must be valued at all, i.e. the two terms are additive, not
        // one overwriting the other (a regression to "staked xor loose" would still be > 0 here,
        // but would fail the precise check below).
        assertGt(combinedBalance, 0, "Combined staked+loose balance for the shared LP token must be valued");

        // Precise check: the combined balance must equal (staked leg LP-vault shares + loose leg
        // LP-vault shares, both held directly by the PlasmaVault: rewardVault.balanceOf() for the
        // staked leg is 1:1 LP-vault shares per the fuse's own documented invariant, and
        // lpVault.balanceOf() for the loose leg) converted once through convertToAssets(), priced
        // exactly as StakeDaoV2BalanceFuse.sol:81+86 does it.
        uint256 stakedLpVaultShares = rewardVault.balanceOf(FUSION_PLASMA_VAULT_sdSaveUSDC);
        uint256 looseLpVaultShares = IERC20(address(lpVault)).balanceOf(FUSION_PLASMA_VAULT_sdSaveUSDC);
        uint256 combinedLpVaultShares = stakedLpVaultShares + looseLpVaultShares;
        uint256 combinedLpTokenAssets = lpVault.convertToAssets(combinedLpVaultShares);

        (uint256 crvUsdPrice, uint256 crvUsdPriceDecimals) = IPriceOracleMiddleware(FUSION_PRICE_MANAGER).getAssetPrice(
            CRV_USD
        );
        (uint256 usdcPrice, uint256 usdcPriceDecimals) = IPriceOracleMiddleware(FUSION_PRICE_MANAGER).getAssetPrice(
            USDC
        );

        uint256 expectedWadUsd = IporMath.convertToWad(combinedLpTokenAssets * crvUsdPrice, 18 + crvUsdPriceDecimals);
        uint256 expectedCombinedBalance = IporMath.convertWadToAssetDecimals(
            (expectedWadUsd * (10 ** usdcPriceDecimals)) / usdcPrice,
            PlasmaVault(FUSION_PLASMA_VAULT_sdSaveUSDC).decimals() - PlasmaVaultLib.DECIMALS_OFFSET
        );

        assertApproxEqAbs(
            combinedBalance,
            expectedCombinedBalance,
            10,
            "Staked and loose shares of the same LP token must be summed before convertToAssets(), matching StakeDaoV2BalanceFuse.sol:81+86 exactly"
        );
    }
}

/// @notice Correction 1 (IL-7947 cycle-2 verification, "Required corrections" #1): if a granted
/// reward vault's LP token IS the PlasmaVault's own underlying `asset()`, any loose (unstaked)
/// balance of that LP token must be counted exactly once -- as idle by
/// `PlasmaVault._getGrossTotalAssets()` (`IERC20(asset()).balanceOf(address(this))`) -- and NOT a
/// second time by `StakeDaoV2BalanceFuse.balanceOf()` inside market STAKE_DAO_V2. Without the
/// guard added in cycle 2, the loose-share addition at `StakeDaoV2BalanceFuse.sol:81` (introduced
/// by the cycle-1 fix) fires unconditionally, double counting this specific configuration.
///
/// This is a self-contained, freshly-deployed PlasmaVault (not the fork-pinned
/// FUSION_PLASMA_VAULT_sdSaveUSDC, whose `asset()` is fixed to USDC and so can never equal a
/// granted reward vault's LP token): its own underlying `asset()` is set to a mock ERC4626 "LP
/// vault" token, and a mock reward vault is granted whose `asset()` is that SAME LP vault token --
/// exactly the "vault's own asset is a granted reward vault's LP-vault share token" configuration
/// the verifier flagged as a latent hazard.
contract StakeDaoV2StrandedLpSharesIdleOverlapTest is Test {
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    // @dev https://data.chain.link/feeds/arbitrum/mainnet/usdc-usd
    address constant CHAINLINK_PRICE_FEED_USDC = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;

    address atomist;

    PlasmaVault plasmaVault;
    IporFusionAccessManager accessManager;
    IPriceOracleMiddleware priceOracle;
    MockERC4626 lpVault;
    MockERC4626 rewardVault;
    StakeDaoV2BalanceFuse balanceFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 368270603);

        atomist = address(this);

        // Mock LP-vault token: this becomes BOTH the PlasmaVault's own underlying `asset()` AND
        // the granted reward vault's `asset()`, i.e. the exact overlap configuration under test.
        lpVault = new MockERC4626(IERC20(USDC), "Mock LP Vault (Idle Overlap)", "mLPI");
        rewardVault = new MockERC4626(IERC20(address(lpVault)), "Mock Reward Vault (Idle Overlap)", "mRVI");

        // Price oracle: a freshly deployed, self-owned PriceOracleMiddleware (no dependency on any
        // fork-pinned FUSION_PRICE_MANAGER instance), with a real Chainlink USDC/USD feed so
        // `lpTokenUnderlyingAddress` (= USDC) can be priced exactly like the other tests in this
        // file. Chainlink Feed Registry is disabled (address(0)); only the custom feed is used.
        PriceOracleMiddleware priceOracleImpl = new PriceOracleMiddleware(address(0));
        priceOracle = IPriceOracleMiddleware(
            address(new ERC1967Proxy(address(priceOracleImpl), abi.encodeWithSignature("initialize(address)", atomist)))
        );
        // @dev PlasmaVaultMarketsLib.updateMarketsBalances also prices the vault's own asset()
        // (here: lpVault itself, since the vault's underlying IS the LP-vault token), so lpVault
        // needs its own price source too, derived from the USDC feed via ERC4626PriceFeed.
        address[] memory assets = new address[](2);
        assets[0] = USDC;
        assets[1] = address(lpVault);
        address[] memory sources = new address[](2);
        sources[0] = CHAINLINK_PRICE_FEED_USDC;
        sources[1] = address(new ERC4626PriceFeed(address(lpVault)));
        PriceOracleMiddleware(address(priceOracle)).setAssetsPricesSources(assets, sources);

        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = atomist;
        usersToRoles.atomist = atomist;
        address[] memory alphas = new address[](1);
        alphas[0] = atomist;
        usersToRoles.alphas = alphas;
        accessManager = RoleLib.createAccessManager(usersToRoles, 0, vm);

        address withdrawManager = address(new WithdrawManager(address(accessManager)));

        plasmaVault = PlasmaVaultCloneLib.newPlasmaVault();
        plasmaVault.proxyInitialize(
            PlasmaVaultInitData(
                "TEST STAKEDAO IDLE OVERLAP VAULT",
                "tSDIO",
                address(lpVault), // @dev the vault's own underlying IS the granted reward vault's LP token
                address(priceOracle),
                FeeConfigHelper.createZeroFeeConfig(),
                address(accessManager),
                address(new PlasmaVaultBase()),
                withdrawManager,
                address(0)
            )
        );

        balanceFuse = new StakeDaoV2BalanceFuse(IporFusionMarkets.STAKE_DAO_V2);

        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(address(rewardVault));

        MarketBalanceFuseConfig[] memory balanceFuses_ = new MarketBalanceFuseConfig[](1);
        balanceFuses_[0] = MarketBalanceFuseConfig(IporFusionMarkets.STAKE_DAO_V2, address(balanceFuse));

        MarketSubstratesConfig[] memory marketConfigs_ = new MarketSubstratesConfig[](1);
        marketConfigs_[0] = MarketSubstratesConfig(IporFusionMarkets.STAKE_DAO_V2, substrates);

        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            atomist,
            address(plasmaVault),
            new address[](0),
            balanceFuses_,
            marketConfigs_
        );

        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(plasmaVault), accessManager, withdrawManager);

        vm.prank(atomist);
        accessManager.grantRole(Roles.UPDATE_MARKETS_BALANCES_ROLE, atomist, 0);
    }

    /// @notice Fails without the guard (loose LP-vault shares double-counted: once as idle, once
    /// via market STAKE_DAO_V2), passes with it (counted once, as idle only).
    /// @dev Executes THIS worktree's `StakeDaoV2BalanceFuse` bytecode: the fuse is deployed fresh
    /// in `setUp()` above and installed via `PlasmaVaultGovernance.addBalanceFuse` (through
    /// `PlasmaVaultConfigurator.setupPlasmaVault`), exactly like the other two contracts in this
    /// file -- there is no pinned/pre-deployed balance fuse address anywhere in this contract.
    function test_balanceFuseDoesNotDoubleCountVaultsOwnAssetHeldAsLooseLpShares() public {
        // given
        uint256 dealAmount = 1_000e18; // USDC-denominated LP-vault shares, 18 decimals (mock)

        deal(USDC, address(this), dealAmount);
        IERC20(USDC).approve(address(lpVault), dealAmount);

        // when: mint LOOSE LP-vault shares directly to the PlasmaVault. Because lpVault IS the
        // PlasmaVault's own `asset()`, this single action simultaneously (a) raises the vault's
        // raw idle balance of its own asset, and (b) is the exact "loose LP-vault shares held by
        // the PlasmaVault" state the cycle-1 fix values inside market STAKE_DAO_V2 -- the overlap
        // under test.
        lpVault.deposit(dealAmount, address(plasmaVault));

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.STAKE_DAO_V2;
        vm.prank(atomist);
        plasmaVault.updateMarketsBalances(marketIds);

        // then
        uint256 idleBalance = IERC20(address(lpVault)).balanceOf(address(plasmaVault));
        uint256 marketBalance = plasmaVault.totalAssetsInMarket(IporFusionMarkets.STAKE_DAO_V2);
        uint256 totalAssets = plasmaVault.totalAssets();

        assertGt(idleBalance, 0, "sanity: the deposited LP-vault shares must be held by the PlasmaVault");

        // @dev The reward vault has zero staked shares (nothing was ever staked into it), and the
        // ONLY LP token in this market is the vault's own asset, so with the guard the market's
        // cached balance for STAKE_DAO_V2 must be exactly zero -- the loose balance is idle-only.
        assertEq(
            marketBalance,
            0,
            "market STAKE_DAO_V2 must not value the PlasmaVault's own-asset loose LP-vault shares (already counted as idle)"
        );

        // @dev totalAssets() = idle (raw balanceOf(asset())) + sum of cached market balances. With
        // market STAKE_DAO_V2 correctly at zero, totalAssets() must equal exactly the idle balance
        // -- an exact equality, not an approximation, since both sides read the same underlying
        // ERC20 balance with no unit conversion in between (the vault's own asset IS the LP token).
        assertEq(
            totalAssets,
            idleBalance,
            "totalAssets() must count the vault's own-asset loose LP-vault shares exactly once (as idle), not twice via market STAKE_DAO_V2"
        );
    }
}
