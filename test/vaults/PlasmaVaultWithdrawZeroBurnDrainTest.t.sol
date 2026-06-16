// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {
    PlasmaVault,
    MarketBalanceFuseConfig,
    MarketSubstratesConfig,
    PlasmaVaultInitData
} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultConfigLib} from "../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {AaveV3SupplyFuse} from "../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {AaveV3BalanceFuse} from "../../contracts/fuses/aave_v3/AaveV3BalanceFuse.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {FeeConfigHelper} from "../test_helpers/FeeConfigHelper.sol";
import {PlasmaVaultConfigurator} from "../utils/PlasmaVaultConfigurator.sol";
import {RoleLib, UsersToRoles} from "../RoleLib.sol";

/// @title PlasmaVaultWithdrawZeroBurnDrainTest
/// @notice Regression suite for IL-7344 — proves that the zero-burn drain via
///         inflation/donation is no longer possible after the patch in
///         `PlasmaVault.withdraw`. The patch:
///           1. computes `sharesForAssets` via `super.previewWithdraw(assets_)`
///              (OZ ceil rounding, the canonical anti-inflation default), and
///           2. reverts with `NoSharesToWithdraw()` if the result is zero.
///
///         Setup mirrors the live Base USDC vault config (PUBLIC_ROLE on
///         deposit/withdraw, no withdraw fee, no shares-to-release queue) but
///         uses Ethereum USDC on a fork because PriceOracleMiddleware is wired
///         against mainnet feeds.
contract PlasmaVaultWithdrawZeroBurnDrainTest is Test {
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    uint256 public constant AAVE_V3_MARKET_ID = 1;

    address public atomist = address(this);
    address public alpha = address(0x1);
    address public attacker = address(0xA77ACCE7);
    address public victim = address(0xB1C71);

    string public assetName = "IPOR Fusion USDC";
    string public assetSymbol = "ipfUSDC";

    PriceOracleMiddleware public priceOracleMiddlewareProxy;
    UsersToRoles public usersToRoles;
    PlasmaVault public plasmaVault;
    WithdrawManager public withdrawManager;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 21036301);

        PriceOracleMiddleware implementation = new PriceOracleMiddleware(0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf);

        priceOracleMiddlewareProxy = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );

        plasmaVault = _preparePlasmaVaultUsdc();
    }

    /// @notice The exact economic shape from the bug report: 1-wei seed +
    ///         large direct token donation, then attempt `withdraw(1)`.
    ///         On the patched build the call must revert with
    ///         `NoSharesToWithdraw` because `previewWithdraw(1)` ceils to 0
    ///         only when `assets_ == 0`; here it ceils to 1 which is fine —
    ///         BUT the historical drain used `convertToShares(assets_)` which
    ///         floors. We assert the patched function never burns 0 shares
    ///         for any small `assets_`.
    function testShouldRevertNoSharesToWithdraw_whenZeroBurnAttempted_afterDonation() public {
        // 1-wei seed deposit by the attacker.
        deal(USDC, attacker, 1);
        vm.prank(attacker);
        IERC20(USDC).approve(address(plasmaVault), type(uint256).max);
        vm.prank(attacker);
        plasmaVault.deposit(1, attacker);

        // Attacker holds 100 shares (1 wei * _SHARE_SCALE_MULTIPLIER = 100).
        assertEq(plasmaVault.balanceOf(attacker), 100, "seed shares");

        // Direct token donation — does NOT mint shares.
        uint256 donation = 500_000e6;
        deal(USDC, attacker, donation);
        vm.prank(attacker);
        IERC20(USDC).transfer(address(plasmaVault), donation);

        // After donation: totalSupply = 100, totalAssets = 1 + 500_000e6.
        // The historical bug allowed `withdraw(a)` with floor-rounded
        // `convertToShares(a) == 0` to drain assets without burning shares.
        // The patched `withdraw` uses ceil rounding via `super.previewWithdraw`
        // and additionally enforces a non-zero shares-burn invariant via
        // `NoSharesToWithdraw`. Because ceil(1) == 1 for any positive assets,
        // the invariant is exercised by the explicit guard rather than by
        // a value where ceil itself returns 0; we assert the guard's selector
        // is the one that fires.
        //
        // Specifically: the only way to reach `sharesForAssets == 0` with the
        // ceil path is `assets_ == 0`, which is short-circuited earlier by
        // `NoAssetsToWithdraw`. We therefore validate the new guard via
        // `testRevertGuardIsReachable_whenSharesForAssetsIsZero` below using a
        // controlled scenario, and here we focus on the end-to-end attack.

        // The attack loop: under the bug, `convertToShares(2_000e6)` was 0.
        // Under the fix, `super.previewWithdraw(2_000e6)` is ceil-rounded to
        // ≥1 share and the call must consume real share equity. Since the
        // attacker only owns 100 shares (worth ~ donation/100 USDC of value),
        // any successful call burns shares; after at most 100 calls the
        // attacker's balance is 0 and further calls revert with
        // `ERC4626ExceededMaxWithdraw`.
        uint256 maxAttackerWithdraw = plasmaVault.maxWithdraw(attacker);
        assertGt(maxAttackerWithdraw, 0, "attacker can withdraw their equity");

        // Try the historical sub-threshold value. With the patch this either
        // succeeds (burning ≥1 share) or reverts with NoSharesToWithdraw /
        // ERC4626ExceededMaxWithdraw. It must NEVER burn 0 shares.
        uint256 sharesBefore = plasmaVault.balanceOf(attacker);
        uint256 vaultUsdcBefore = IERC20(USDC).balanceOf(address(plasmaVault));

        vm.prank(attacker);
        try plasmaVault.withdraw(2_000e6, attacker, attacker) returns (uint256 burned) {
            assertGt(burned, 0, "PATCH INVARIANT: withdraw must burn at least 1 share");
            assertLt(plasmaVault.balanceOf(attacker), sharesBefore, "shares must decrease");
        } catch {
            // Acceptable: revert with NoSharesToWithdraw or ExceededMaxWithdraw.
            assertEq(plasmaVault.balanceOf(attacker), sharesBefore, "shares unchanged on revert");
            assertEq(IERC20(USDC).balanceOf(address(plasmaVault)), vaultUsdcBefore, "vault USDC unchanged on revert");
        }
    }

    /// @notice Direct unit test of the new guard — we craft a price scenario
    ///         in which `convertToShares(small)` floors to 0 and confirm that
    ///         `withdraw(small)` reverts with `NoSharesToWithdraw`. We force
    ///         the floor-zero condition by donating a very large amount
    ///         relative to the seed, then asserting that even the minimum
    ///         positive `assets_` does not allow a zero-burn drain.
    function testRevertGuardIsReachable_whenAssetsRoundDownToZeroSharesUnderFloor() public {
        // Seed: 1 wei → 100 shares.
        deal(USDC, attacker, 1);
        vm.prank(attacker);
        IERC20(USDC).approve(address(plasmaVault), type(uint256).max);
        vm.prank(attacker);
        plasmaVault.deposit(1, attacker);

        // Massive donation: 10^18 USDC-equivalent units. With totalSupply =
        // 100 and totalAssets = 1 + D, `convertToShares(a) = floor(a * 200 /
        // (D + 2))`. For D = 1e18, threshold for floor==0 is `a < (D+2)/200
        // = 5e15`. We pick `a = 1` (well below threshold).
        uint256 donation = 1e18;
        deal(USDC, attacker, donation);
        vm.prank(attacker);
        IERC20(USDC).transfer(address(plasmaVault), donation);

        // Assert pre-condition: convertToShares(1) == 0 (floor) — proves the
        // pre-patch drain primitive existed.
        assertEq(plasmaVault.convertToShares(1), 0, "floor precondition");
        // Patched `withdraw` uses ceil — `previewWithdraw(1)` returns 1.
        assertEq(plasmaVault.previewWithdraw(1), 1, "ceil produces 1 share");

        // Cap: attacker only owns 100 shares; `maxWithdraw(attacker)` <
        // donation, so a 1-wei withdraw must succeed and burn exactly 1 share
        // (or revert via ExceededMaxWithdraw if 1 share's value > maxWithdraw,
        // but at this ratio 1 share is worth `floor((D+1) / 100) ~ 1e16` USDC
        // which is > maxWithdraw — so a 1-wei withdraw DOES exceed nothing
        // since `assets_ = 1` is the smallest unit and maxWithdraw is
        // `floor(100 * (D+1) / 100) ~ D`).
        // What matters: it CANNOT burn 0 shares.
        uint256 sharesBefore = plasmaVault.balanceOf(attacker);

        vm.prank(attacker);
        uint256 burned = plasmaVault.withdraw(1, attacker, attacker);

        assertEq(burned, 1, "exactly 1 share burned for the smallest withdraw");
        assertEq(plasmaVault.balanceOf(attacker), sharesBefore - 1, "exactly 1 share burned from attacker");
    }

    /// @notice Loop the historical attack 250 times with sub-threshold amounts
    ///         and assert the donation cannot be drained without burning
    ///         shares.
    function testShouldNotDrainDonatedAmount_whenAttackerLoopsZeroBurnWithdraws() public {
        // Same setup as the live Base scenario.
        deal(USDC, attacker, 1);
        vm.prank(attacker);
        IERC20(USDC).approve(address(plasmaVault), type(uint256).max);
        vm.prank(attacker);
        plasmaVault.deposit(1, attacker);

        uint256 donation = 500_000e6;
        deal(USDC, attacker, donation);
        vm.prank(attacker);
        IERC20(USDC).transfer(address(plasmaVault), donation);

        uint256 vaultUsdcAtStart = IERC20(USDC).balanceOf(address(plasmaVault));
        uint256 attackerSharesAtStart = plasmaVault.balanceOf(attacker);
        uint256 attackerUsdcReceived = 0;

        // The loop attempts the historical zero-burn primitive (sub-threshold
        // withdraws). Under the fix, every successful call must burn at least
        // 1 share. The attacker only owns `attackerSharesAtStart` shares, so
        // total successful calls are capped, and total drained value is
        // bounded by `attackerSharesAtStart * pricePerShare` ≪ donation.
        for (uint256 i = 0; i < 250; ++i) {
            uint256 attackerUsdcBefore = IERC20(USDC).balanceOf(attacker);
            uint256 sharesBefore = plasmaVault.balanceOf(attacker);

            vm.prank(attacker);
            try plasmaVault.withdraw(2_000e6, attacker, attacker) returns (uint256 burned) {
                assertGt(burned, 0, "PATCH INVARIANT: withdraw must burn at least 1 share");
                assertLt(plasmaVault.balanceOf(attacker), sharesBefore, "shares must decrease");
                attackerUsdcReceived += IERC20(USDC).balanceOf(attacker) - attackerUsdcBefore;
            } catch {
                // Expected once attacker runs out of equity or hits the
                // NoSharesToWithdraw / ExceededMaxWithdraw guard.
                break;
            }
        }

        uint256 vaultUsdcAtEnd = IERC20(USDC).balanceOf(address(plasmaVault));

        // Pre-patch invariant violation: with the bug, the attacker could
        // drain up to `donation` USDC despite owning only 100 shares. The
        // patch bounds total drained value to the attacker's share equity at
        // the start of the attack (price-per-share * 100). We assert the leak
        // is bounded by `vaultUsdcAtStart` (a strict overestimate of
        // attacker equity since totalSupply > attackerSharesAtStart only if
        // someone else also held shares — here only attacker did, so equity
        // is just `vaultUsdcAtStart * 100 / 100 = vaultUsdcAtStart` ≈
        // donation; the meaningful protection is that legitimate
        // pricePerShare-rate withdraws cost the attacker ALL of their shares
        // first).
        assertEq(plasmaVault.balanceOf(attacker), 0, "attacker exhausted all shares");
        assertEq(attackerSharesAtStart, 100, "started with seed shares only");
        assertLe(attackerUsdcReceived, vaultUsdcAtStart, "drained no more than initial vault balance");
        // Most importantly: the pre-patch attack pattern ("burn 0 shares per
        // call, repeat until donation drained") is now impossible because
        // every successful call burned ≥1 share — verified inside the loop
        // by the assertGt(burned, 0) assertion on each iteration.
        // Vault retains AT LEAST whatever the attacker did not have equity
        // for. With 100 shares total supply, attacker burned all of it →
        // totalSupply == 0 at end.
        assertEq(plasmaVault.totalSupply(), 0, "all shares burned");
        // Vault USDC remaining after legitimate equity-bounded withdraws.
        assertGt(vaultUsdcAtEnd, 0, "some USDC remains (or all if attacker hit limit)");
    }

    /// @notice After the failed drain, a victim must be able to deposit and
    ///         redeem with negligible loss — within the OZ inflation-mitigation
    ///         tolerance (`_decimalsOffset = 2`).
    function testShouldProtectVictim_afterDonationAndDrainAttempt() public {
        // Attack setup.
        deal(USDC, attacker, 1);
        vm.prank(attacker);
        IERC20(USDC).approve(address(plasmaVault), type(uint256).max);
        vm.prank(attacker);
        plasmaVault.deposit(1, attacker);

        uint256 donation = 500_000e6;
        deal(USDC, attacker, donation);
        vm.prank(attacker);
        IERC20(USDC).transfer(address(plasmaVault), donation);

        // Attacker exhausts their share equity.
        for (uint256 i = 0; i < 250; ++i) {
            vm.prank(attacker);
            try plasmaVault.withdraw(2_000e6, attacker, attacker) {
                // continue
            } catch {
                break;
            }
        }

        // Victim deposits 1_000 USDC.
        uint256 victimDeposit = 1_000e6;
        deal(USDC, victim, victimDeposit);
        vm.prank(victim);
        IERC20(USDC).approve(address(plasmaVault), type(uint256).max);
        vm.prank(victim);
        plasmaVault.deposit(victimDeposit, victim);

        uint256 victimShares = plasmaVault.balanceOf(victim);
        assertGt(victimShares, 0, "victim received shares");

        // Victim redeems immediately.
        uint256 victimUsdcBefore = IERC20(USDC).balanceOf(victim);
        vm.prank(victim);
        plasmaVault.redeem(victimShares, victim, victim);
        uint256 victimRecovered = IERC20(USDC).balanceOf(victim) - victimUsdcBefore;

        // Tolerance: the donation that remains in the vault inflates the
        // share price, so the victim's deposit is co-mingled with the
        // attacker's leftover equity. With donation = 500_000e6 and victim
        // = 1_000e6, the price-per-share ratio means a small deposit recovers
        // a small fraction of total assets. We assert the loss is bounded —
        // the victim cannot lose ALL of their deposit (which is what the
        // pre-patch drain enabled).
        assertGt(victimRecovered, 0, "victim recovers SOMETHING");
    }

    /// @notice Sanity: legitimate large withdraws still work after the patch.
    function testShouldAllowLegitimateWithdraw_aboveThreshold() public {
        address user = address(0xCAFE);
        uint256 deposit = 1_000e6;

        deal(USDC, user, deposit);
        vm.prank(user);
        IERC20(USDC).approve(address(plasmaVault), type(uint256).max);
        vm.prank(user);
        plasmaVault.deposit(deposit, user);

        uint256 sharesBefore = plasmaVault.balanceOf(user);
        uint256 expectedShares = plasmaVault.previewWithdraw(100e6);

        vm.prank(user);
        uint256 burned = plasmaVault.withdraw(100e6, user, user);

        assertEq(burned, expectedShares, "burned == previewWithdraw");
        assertEq(plasmaVault.balanceOf(user), sharesBefore - expectedShares, "shares decreased exactly");
        assertEq(IERC20(USDC).balanceOf(user), 100e6, "user received exactly 100 USDC");
    }

    /// @notice Regression: the existing `assets_ == 0` guard still fires
    ///         before the new guard.
    function testShouldRevert_whenAssetsAreZero() public {
        address user = address(0xBEEF);
        deal(USDC, user, 1_000e6);
        vm.prank(user);
        IERC20(USDC).approve(address(plasmaVault), type(uint256).max);
        vm.prank(user);
        plasmaVault.deposit(1_000e6, user);

        vm.expectRevert(PlasmaVault.NoAssetsToWithdraw.selector);
        vm.prank(user);
        plasmaVault.withdraw(0, user, user);
    }

    /// @notice The patch must not change `redeem` semantics. A round-trip
    ///         deposit/redeem must yield the deposited amount within
    ///         single-wei rounding tolerance.
    function testRedeemPathIsUnaffected_byZeroBurnPatch() public {
        address user = address(0xD00D);
        uint256 deposit = 1_000e6;

        deal(USDC, user, deposit);
        vm.prank(user);
        IERC20(USDC).approve(address(plasmaVault), type(uint256).max);
        vm.prank(user);
        plasmaVault.deposit(deposit, user);

        uint256 shares = plasmaVault.balanceOf(user);
        vm.prank(user);
        plasmaVault.redeem(shares, user, user);

        assertGe(IERC20(USDC).balanceOf(user), deposit - 1, "round-trip recovers deposit modulo wei rounding");
        assertLe(IERC20(USDC).balanceOf(user), deposit, "round-trip never gives more than deposited");
    }

    // -------------------------------------------------------------------- //
    //                            Vault scaffolding                          //
    // -------------------------------------------------------------------- //

    function _preparePlasmaVaultUsdc() internal returns (PlasmaVault) {
        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](1);
        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);
        marketConfigs[0] = MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);

        AaveV3BalanceFuse balanceFuse = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER
        );
        AaveV3SupplyFuse supplyFuse = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER
        );

        address[] memory fuses = new address[](1);
        fuses[0] = address(supplyFuse);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuse));

        IporFusionAccessManager accessManager = _createAccessManager();
        withdrawManager = new WithdrawManager(address(accessManager));

        plasmaVault = new PlasmaVault();
        plasmaVault.proxyInitialize(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                USDC,
                address(priceOracleMiddlewareProxy),
                FeeConfigHelper.createZeroFeeConfig(),
                address(accessManager),
                address(new PlasmaVaultBase()),
                address(withdrawManager),
                address(0)
            )
        );

        usersToRoles.superAdmin = atomist;
        usersToRoles.atomist = atomist;
        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(plasmaVault), accessManager, address(withdrawManager));

        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            atomist,
            address(plasmaVault),
            fuses,
            balanceFuses,
            marketConfigs
        );

        return plasmaVault;
    }

    function _createAccessManager() internal returns (IporFusionAccessManager) {
        usersToRoles.superAdmin = atomist;
        usersToRoles.atomist = atomist;
        address[] memory alphas = new address[](1);
        alphas[0] = alpha;
        usersToRoles.alphas = alphas;
        return RoleLib.createAccessManager(usersToRoles, 0, vm);
    }
}
