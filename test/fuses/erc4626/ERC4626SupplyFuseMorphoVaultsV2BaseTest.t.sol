// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {PlasmaVault, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {IPlasmaVaultGovernance} from "../../../contracts/interfaces/IPlasmaVaultGovernance.sol";
import {InstantWithdrawalFusesParamsStruct} from "../../../contracts/libraries/PlasmaVaultLib.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {IporMath} from "../../../contracts/libraries/math/IporMath.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {RewardsClaimManager} from "../../../contracts/managers/rewards/RewardsClaimManager.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {
    Erc4626SupplyFuse,
    Erc4626SupplyFuseEnterData,
    Erc4626SupplyFuseExitData
} from "../../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {Erc4626BalanceFuse} from "../../../contracts/fuses/erc4626/Erc4626BalanceFuse.sol";
import {IporFusionAccessManagerHelper} from "../../test_helpers/IporFusionAccessManagerHelper.sol";
import {MockERC4626} from "../../test_helpers/MockErc4626.sol";
import {PlasmaVaultHelper, DeployMinimalPlasmaVaultParams} from "../../test_helpers/PlasmaVaultHelper.sol";
import {PriceOracleMiddlewareHelper} from "../../test_helpers/PriceOracleMiddlewareHelper.sol";
import {TestAddresses} from "../../test_helpers/TestAddresses.sol";

/// @title Erc4626SupplyFuse against Morpho Vaults V2 on a Base fork
/// @notice IL-8505 / GitHub #554. Proves on a real Base fork that a Plasma Vault can enter and exit a Morpho Vaults V2
///         position through `Erc4626SupplyFuse` built from source, and that the currently published fuse (old clamp
///         `min(amount, maxWithdraw(this))`) cannot.
/// @dev Morpho Vaults V2 is an EIP-4626 vault whose `maxDeposit`, `maxMint`, `maxWithdraw` and `maxRedeem` are
///      hard-coded to 0 (EIP-4626 allows `max*` to under-report), while `deposit`, `withdraw`, `redeem` and the
///      `preview*` / `convertTo*` functions work. The old fuse used `maxWithdraw(this)` as the exit cap, so every exit
///      from such a vault silently became a no-op (0 returned, nothing withdrawn, no event). The fixed fuse falls back
///      to `previewRedeem(balanceOf(this))` when `maxWithdraw(this) == 0` and shares are held.
///
///      Vault under test: Steakhouse Prime USDC (Morpho Vaults V2) on Base, `receiveSharesGate` and `sendAssetsGate`
///      are address(0) (open), liquidity is served by its liquidity adapter.
///
///      The contract runs with `isolate = true` (foundry.toml defaults to `isolate = false`): every top-level call of
///      the test (alpha `execute`, user `redeem`) is a separate transaction, exactly like in production, so no
///      transient storage of the Plasma Vault, the fuses or the Morpho vault leaks from one operation to the next.
///      The suite also passes with `isolate = false` at the pinned block, i.e. the Morpho vault does not reject
///      several operations in one transaction.
/// forge-config: default.isolate = true
contract ERC4626SupplyFuseMorphoVaultsV2BaseTest is Test {
    using PriceOracleMiddlewareHelper for PriceOracleMiddleware;
    using PlasmaVaultHelper for PlasmaVault;
    using IporFusionAccessManagerHelper for IporFusionAccessManager;

    /// @dev Base block pinned on 2026-10-14 (head was 52,588,530 when the test was written)
    uint256 private constant FORK_BLOCK = 52_588_000;

    /// @dev Steakhouse Prime USDC, Morpho Vaults V2 on Base
    address private constant MORPHO_VAULT = 0xbeef0e0834849aCC03f0089F01f4F1Eeb06873C9;
    /// @dev Erc4626SupplyFuse (old clamp) published on Base, MARKET_ID() == 100004 (ERC4626_0004)
    address private constant PUBLISHED_FUSE = 0x0108FDaC9360F531fC208d56A02F88352FCFc434;
    address private constant USDC = TestAddresses.BASE_USDC;
    address private constant USER = TestAddresses.USER;

    uint256 private constant USER_DEPOSIT = 10_000e6;
    uint256 private constant ENTER_AMOUNT = 5_000e6;
    uint256 private constant PARTIAL_EXIT_AMOUNT = 1_000e6;

    /// @dev The only tolerance of the suite, in USDC wei: Morpho `convertToAssets` floors, so at the pinned block a
    ///      position entered with 5,000 USDC is worth 4,999,999,999 and `totalAssets` is 1 wei lower. Everything that
    ///      is not a position value (USDC moved, shares burned, events) is asserted exactly.
    uint256 private constant MORPHO_FLOOR_WEI = 1;

    PriceOracleMiddleware private _priceOracleMiddleware;
    PlasmaVault private _plasmaVault;
    Erc4626SupplyFuse private _supplyFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_PROVIDER_URL"), FORK_BLOCK);

        vm.startPrank(TestAddresses.ATOMIST);
        _priceOracleMiddleware = PriceOracleMiddlewareHelper.deployPriceOracleMiddleware(
            TestAddresses.ATOMIST,
            address(0)
        );
        _priceOracleMiddleware.addSource(USDC, TestAddresses.BASE_CHAINLINK_USDC_PRICE);
        vm.stopPrank();

        _supplyFuse = new Erc4626SupplyFuse(IporFusionMarkets.ERC4626_0001);
        address[] memory fuses = new address[](1);
        fuses[0] = address(_supplyFuse);
        _plasmaVault = _buildVault(
            IporFusionMarkets.ERC4626_0001,
            fuses,
            address(new Erc4626BalanceFuse(IporFusionMarkets.ERC4626_0001))
        );

        _deposit(_plasmaVault, USER_DEPOSIT);

        // precondition: the fallback (not maxWithdraw) is what is being tested. Vacuous here, the Plasma Vault holds
        // no Morpho shares yet (maxWithdraw is 0 for an empty position in any vault): the real precondition is
        // asserted by `_enter` once the position exists.
        assertEq(IERC4626(MORPHO_VAULT).asset(), USDC, "Morpho vault underlying should be USDC");
        assertEq(
            IERC4626(MORPHO_VAULT).maxWithdraw(address(_plasmaVault)),
            0,
            "Morpho Vaults V2 maxWithdraw should be 0 for any owner"
        );
        assertEq(IERC20(USDC).balanceOf(address(_plasmaVault)), USER_DEPOSIT, "Plasma Vault should hold the deposit");
    }

    // ------------------------------------------------------------------------------------------------------------
    // enter
    // ------------------------------------------------------------------------------------------------------------

    function testShouldEnterMorphoVaultsV2() public {
        // given
        uint256 totalAssetsBefore = _plasmaVault.totalAssets();
        uint256 expectedShares = IERC4626(MORPHO_VAULT).previewDeposit(ENTER_AMOUNT);

        // when
        vm.recordLogs();
        _enter(_plasmaVault, address(_supplyFuse), ENTER_AMOUNT);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // then
        uint256 shares = IERC4626(MORPHO_VAULT).balanceOf(address(_plasmaVault));
        assertGt(shares, 0, "Plasma Vault should hold Morpho shares");
        assertEq(shares, expectedShares, "shares should match previewDeposit");
        assertEq(
            IERC20(USDC).balanceOf(address(_plasmaVault)),
            USER_DEPOSIT - ENTER_AMOUNT,
            "exactly the entered amount should leave the Plasma Vault"
        );
        assertApproxEqAbs(
            _plasmaVault.totalAssets(),
            totalAssetsBefore,
            MORPHO_FLOOR_WEI,
            "totalAssets should be unchanged by entering"
        );
        assertApproxEqAbs(
            _plasmaVault.totalAssetsInMarket(IporFusionMarkets.ERC4626_0001),
            ENTER_AMOUNT,
            MORPHO_FLOOR_WEI,
            "market balance should equal the entered amount"
        );

        Vm.Log[] memory enterLogs = _logsOf(
            logs,
            address(_plasmaVault),
            Erc4626SupplyFuse.Erc4626SupplyFuseEnter.selector
        );
        assertEq(enterLogs.length, 1, "exactly one Erc4626SupplyFuseEnter event");
        (address version, address asset, address vault, uint256 assets) = abi.decode(
            enterLogs[0].data,
            (address, address, address, uint256)
        );
        assertEq(version, address(_supplyFuse), "event version");
        assertEq(asset, USDC, "event asset");
        assertEq(vault, MORPHO_VAULT, "event vault");
        assertEq(assets, ENTER_AMOUNT, "event vaultAssetAmount");
    }

    function testShouldRevertEnterWhenMinSharesOutNotMet() public {
        // given
        uint256 expectedShares = IERC4626(MORPHO_VAULT).previewDeposit(ENTER_AMOUNT);
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(_supplyFuse),
            data: abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                Erc4626SupplyFuseEnterData({
                    vault: MORPHO_VAULT,
                    vaultAssetAmount: ENTER_AMOUNT,
                    minSharesOut: expectedShares + 1
                })
            )
        });

        // when / then
        vm.expectPartialRevert(Erc4626SupplyFuse.Erc4626SupplyFuseInsufficientShares.selector);
        vm.prank(TestAddresses.ALPHA);
        _plasmaVault.execute(actions);
    }

    // ------------------------------------------------------------------------------------------------------------
    // exit through the fixed fuse
    // ------------------------------------------------------------------------------------------------------------

    function testShouldPartiallyExitMorphoVaultsV2() public {
        // given
        _enter(_plasmaVault, address(_supplyFuse), ENTER_AMOUNT);
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(_plasmaVault));
        uint256 sharesBefore = IERC4626(MORPHO_VAULT).balanceOf(address(_plasmaVault));
        uint256 expectedBurn = IERC4626(MORPHO_VAULT).previewWithdraw(PARTIAL_EXIT_AMOUNT);

        // when
        vm.recordLogs();
        _exit(_plasmaVault, address(_supplyFuse), PARTIAL_EXIT_AMOUNT, expectedBurn);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // then
        uint256 sharesAfter = IERC4626(MORPHO_VAULT).balanceOf(address(_plasmaVault));
        assertEq(
            IERC20(USDC).balanceOf(address(_plasmaVault)) - usdcBefore,
            PARTIAL_EXIT_AMOUNT,
            "Plasma Vault should receive exactly the requested USDC"
        );
        assertLt(sharesAfter, sharesBefore, "Morpho shares should decrease");
        assertEq(sharesBefore - sharesAfter, expectedBurn, "burned shares should match previewWithdraw");

        Vm.Log[] memory exitLogs = _logsOf(
            logs,
            address(_plasmaVault),
            Erc4626SupplyFuse.Erc4626SupplyFuseExit.selector
        );
        assertEq(exitLogs.length, 1, "exactly one Erc4626SupplyFuseExit event");
        (address version, address asset, address vault, uint256 assets, uint256 shares) = abi.decode(
            exitLogs[0].data,
            (address, address, address, uint256, uint256)
        );
        assertEq(version, address(_supplyFuse), "event version");
        assertEq(asset, USDC, "event asset");
        assertEq(vault, MORPHO_VAULT, "event vault");
        assertEq(assets, PARTIAL_EXIT_AMOUNT, "event vaultAssetAmount");
        assertEq(shares, sharesBefore - sharesAfter, "event shares");
        assertEq(
            _logsOf(logs, address(_plasmaVault), Erc4626SupplyFuse.Erc4626SupplyFuseExitFailed.selector).length,
            0,
            "no Erc4626SupplyFuseExitFailed event"
        );
    }

    function testShouldFullyExitMorphoVaultsV2() public {
        // given
        _enter(_plasmaVault, address(_supplyFuse), ENTER_AMOUNT);
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(_plasmaVault));
        uint256 sharesBefore = IERC4626(MORPHO_VAULT).balanceOf(address(_plasmaVault));
        uint256 positionAssets = IERC4626(MORPHO_VAULT).previewRedeem(sharesBefore);

        // when: type(uint256).max is capped to previewRedeem(shares) by the fuse
        _exit(_plasmaVault, address(_supplyFuse), type(uint256).max, sharesBefore);

        // then
        uint256 sharesAfter = IERC4626(MORPHO_VAULT).balanceOf(address(_plasmaVault));
        assertEq(
            IERC20(USDC).balanceOf(address(_plasmaVault)) - usdcBefore,
            positionAssets,
            "Plasma Vault should receive previewRedeem(shares) USDC"
        );
        assertApproxEqAbs(
            positionAssets,
            ENTER_AMOUNT,
            MORPHO_FLOOR_WEI,
            "position should be worth the entered amount"
        );
        // The exit is a withdraw(assets): previewRedeem rounds the assets down, so a share dust stays in the Morpho
        // vault (957,680,009,278 share-wei at the pinned block). Morpho shares have 18 decimals for a 6-decimals
        // asset (1 USDC wei = ~1e12 share-wei), so this dust is worth less than 1 USDC wei and is accepted.
        assertLt(sharesAfter, sharesBefore, "Morpho shares should decrease");
        assertLt(sharesAfter, 10 ** 12, "remaining share dust should be below the value of 1 USDC wei");
        assertLe(
            IERC4626(MORPHO_VAULT).convertToAssets(sharesAfter),
            1,
            "remaining share dust should be worth at most 1 USDC wei"
        );
        assertApproxEqAbs(
            _plasmaVault.totalAssets(),
            USER_DEPOSIT,
            MORPHO_FLOOR_WEI,
            "totalAssets should be unchanged by a full exit"
        );
    }

    /// @dev A week of accrued interest between enter and exit: the position is worth more than what was entered and
    ///      the exit pays exactly `previewRedeem(shares)` read at the very timestamp of the exit (the Morpho Vaults V2
    ///      views and `withdraw` accrue interest to the same `block.timestamp`, so view and withdraw agree).
    function testShouldFullyExitAfterTimeWarpMorphoVaultsV2() public {
        // given: a position that has been earning for 7 days
        _enter(_plasmaVault, address(_supplyFuse), ENTER_AMOUNT);
        vm.warp(block.timestamp + 7 days);
        vm.roll(block.number + 1);

        uint256 usdcBefore = IERC20(USDC).balanceOf(address(_plasmaVault));
        uint256 sharesBefore = IERC4626(MORPHO_VAULT).balanceOf(address(_plasmaVault));
        uint256 positionAssets = IERC4626(MORPHO_VAULT).previewRedeem(sharesBefore);
        assertGt(positionAssets, ENTER_AMOUNT, "the position should have accrued interest during the warp");
        assertEq(IERC4626(MORPHO_VAULT).maxWithdraw(address(_plasmaVault)), 0, "maxWithdraw is still 0");

        // when: type(uint256).max is capped to previewRedeem(shares) by the fuse
        vm.recordLogs();
        _exit(_plasmaVault, address(_supplyFuse), type(uint256).max, sharesBefore);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // then
        uint256 received = IERC20(USDC).balanceOf(address(_plasmaVault)) - usdcBefore;
        uint256 sharesAfter = IERC4626(MORPHO_VAULT).balanceOf(address(_plasmaVault));
        assertEq(received, positionAssets, "Plasma Vault should receive previewRedeem(shares) USDC");
        assertLt(sharesAfter, sharesBefore, "Morpho shares should decrease");
        assertLt(sharesAfter, 10 ** 12, "remaining share dust should be below the value of 1 USDC wei");
        assertLe(
            IERC4626(MORPHO_VAULT).convertToAssets(sharesAfter),
            1,
            "remaining share dust should be worth at most 1 USDC wei"
        );

        Vm.Log[] memory exitLogs = _logsOf(
            logs,
            address(_plasmaVault),
            Erc4626SupplyFuse.Erc4626SupplyFuseExit.selector
        );
        assertEq(exitLogs.length, 1, "exactly one Erc4626SupplyFuseExit event");
        (address version, address asset, address vault, uint256 assets, uint256 shares) = abi.decode(
            exitLogs[0].data,
            (address, address, address, uint256, uint256)
        );
        assertEq(version, address(_supplyFuse), "event version");
        assertEq(asset, USDC, "event asset");
        assertEq(vault, MORPHO_VAULT, "event vault");
        assertEq(assets, received, "event vaultAssetAmount");
        assertEq(shares, sharesBefore - sharesAfter, "event shares");
        assertEq(
            _logsOf(logs, address(_plasmaVault), Erc4626SupplyFuse.Erc4626SupplyFuseExitFailed.selector).length,
            0,
            "no Erc4626SupplyFuseExitFailed event"
        );
    }

    function testShouldBeSilentNoOpOnSecondExitAfterFullExitMorphoVaultsV2() public {
        // given: a full exit (redeem of all shares, IL-8489) that leaves no shares behind
        _enter(_plasmaVault, address(_supplyFuse), ENTER_AMOUNT);
        _exit(
            _plasmaVault,
            address(_supplyFuse),
            type(uint256).max,
            IERC4626(MORPHO_VAULT).balanceOf(address(_plasmaVault))
        );

        uint256 dustShares = IERC4626(MORPHO_VAULT).balanceOf(address(_plasmaVault));
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(_plasmaVault));
        assertEq(dustShares, 0, "no shares should be left after the full redeem exit");
        assertEq(IERC4626(MORPHO_VAULT).maxWithdraw(address(_plasmaVault)), 0, "maxWithdraw is still 0");

        // when: exit again, nothing but dust is left
        vm.recordLogs();
        _exit(_plasmaVault, address(_supplyFuse), type(uint256).max, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // then: no shares held returns 0 before any withdraw/redeem: no revert, nothing moved, nothing emitted
        assertEq(IERC4626(MORPHO_VAULT).balanceOf(address(_plasmaVault)), dustShares, "share dust should be unchanged");
        assertEq(IERC20(USDC).balanceOf(address(_plasmaVault)), usdcBefore, "USDC should be unchanged");
        assertEq(_logsFrom(logs, MORPHO_VAULT), 0, "the Morpho vault should not be touched (no Withdraw event)");
        assertEq(
            _logsOf(logs, address(_plasmaVault), Erc4626SupplyFuse.Erc4626SupplyFuseExit.selector).length,
            0,
            "no Erc4626SupplyFuseExit event"
        );
        assertEq(
            _logsOf(logs, address(_plasmaVault), Erc4626SupplyFuse.Erc4626SupplyFuseExitFailed.selector).length,
            0,
            "no Erc4626SupplyFuseExitFailed event"
        );
    }

    function testShouldRevertExitWhenMaxSharesBurnedExceeded() public {
        // given
        _enter(_plasmaVault, address(_supplyFuse), ENTER_AMOUNT);
        uint256 expectedBurn = IERC4626(MORPHO_VAULT).previewWithdraw(PARTIAL_EXIT_AMOUNT);
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(_supplyFuse),
            data: abi.encodeWithSignature(
                "exit((address,uint256,uint256))",
                Erc4626SupplyFuseExitData({
                    vault: MORPHO_VAULT,
                    vaultAssetAmount: PARTIAL_EXIT_AMOUNT,
                    maxSharesBurned: expectedBurn - 1
                })
            )
        });

        // when / then: the share cap is enforced on the fallback path too. The burned shares are exactly
        // previewWithdraw(PARTIAL_EXIT_AMOUNT) (see testShouldPartiallyExitMorphoVaultsV2), so both arguments are known.
        vm.expectRevert(
            abi.encodeWithSelector(
                Erc4626SupplyFuse.Erc4626SupplyFuseExcessiveSharesBurned.selector,
                expectedBurn,
                expectedBurn - 1
            )
        );
        vm.prank(TestAddresses.ALPHA);
        _plasmaVault.execute(actions);
    }

    // ------------------------------------------------------------------------------------------------------------
    // instant withdrawal (user redeem)
    // ------------------------------------------------------------------------------------------------------------

    function testShouldRedeemFullyThroughInstantWithdrawalFromMorphoVaultsV2() public {
        // given: everything is invested, the Plasma Vault holds no idle USDC
        _enter(_plasmaVault, address(_supplyFuse), USER_DEPOSIT);
        assertEq(IERC20(USDC).balanceOf(address(_plasmaVault)), 0, "no idle USDC left");
        _configureInstantWithdrawal(_plasmaVault, address(_supplyFuse));

        uint256 userShares = _plasmaVault.balanceOf(USER);
        uint256 expectedAssets = _plasmaVault.convertToAssets(userShares);
        uint256 morphoSharesBefore = IERC4626(MORPHO_VAULT).balanceOf(address(_plasmaVault));

        // when
        vm.recordLogs();
        vm.prank(USER);
        uint256 received = _plasmaVault.redeem(userShares, USER, USER);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // then
        assertEq(IERC20(USDC).balanceOf(USER), received, "user USDC balance should match the redeemed amount");
        assertEq(received, expectedAssets, "user should receive exactly his share of the vault");
        assertApproxEqAbs(received, USER_DEPOSIT, MORPHO_FLOOR_WEI, "user should get the deposit back");
        assertEq(_plasmaVault.balanceOf(USER), 0, "user shares should be burned");
        assertLt(
            IERC4626(MORPHO_VAULT).balanceOf(address(_plasmaVault)),
            morphoSharesBefore,
            "Morpho shares should decrease"
        );
        // exactly one: the REDEEM_ATTEMPTS loop re-enters the fuse with the slippage buffer only, which must not turn
        // into a second (spurious) Exit on the share dust left behind by the first withdraw
        Vm.Log[] memory exitLogs = _logsOf(
            logs,
            address(_plasmaVault),
            Erc4626SupplyFuse.Erc4626SupplyFuseExit.selector
        );
        assertEq(exitLogs.length, 1, "instant withdrawal should emit exactly one Erc4626SupplyFuseExit");
        (address version, address asset, address vault, , ) = abi.decode(
            exitLogs[0].data,
            (address, address, address, uint256, uint256)
        );
        assertEq(version, address(_supplyFuse), "event version");
        assertEq(asset, USDC, "event asset");
        assertEq(vault, MORPHO_VAULT, "event vault");
        assertEq(
            _logsOf(logs, address(_plasmaVault), Erc4626SupplyFuse.Erc4626SupplyFuseExitFailed.selector).length,
            0,
            "instant withdrawal should not fail"
        );
    }

    function testShouldRedeemPartiallyThroughInstantWithdrawalFromMorphoVaultsV2() public {
        // given
        _enter(_plasmaVault, address(_supplyFuse), USER_DEPOSIT);
        assertEq(IERC20(USDC).balanceOf(address(_plasmaVault)), 0, "no idle USDC left");
        _configureInstantWithdrawal(_plasmaVault, address(_supplyFuse));

        uint256 userSharesBefore = _plasmaVault.balanceOf(USER);
        uint256 sharesToRedeem = userSharesBefore / 4;
        uint256 expectedAssets = _plasmaVault.convertToAssets(sharesToRedeem);

        // when
        vm.recordLogs();
        vm.prank(USER);
        uint256 received = _plasmaVault.redeem(sharesToRedeem, USER, USER);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // then
        assertGt(received, 0, "user should receive USDC");
        assertEq(IERC20(USDC).balanceOf(USER), received, "user USDC balance should match the redeemed amount");
        assertEq(received, expectedAssets, "user should receive exactly a quarter of the vault");
        assertEq(_plasmaVault.balanceOf(USER), userSharesBefore - sharesToRedeem, "remaining user shares");
        assertGt(IERC4626(MORPHO_VAULT).balanceOf(address(_plasmaVault)), 0, "the rest stays in Morpho");
        assertEq(
            _logsOf(logs, address(_plasmaVault), Erc4626SupplyFuse.Erc4626SupplyFuseExit.selector).length,
            1,
            "one Erc4626SupplyFuseExit event"
        );
        assertEq(
            _logsOf(logs, address(_plasmaVault), Erc4626SupplyFuse.Erc4626SupplyFuseExitFailed.selector).length,
            0,
            "instant withdrawal should not fail"
        );
    }

    /// @dev The revert of the Morpho `withdraw` is mocked on purpose: the behaviour under test is the `catch` of the
    ///      fuse in `instantWithdraw` (emit `Erc4626SupplyFuseExitFailed`, let the Plasma Vault go on with the next
    ///      instant-withdrawal fuse), not Morpho's liquidity or pause logic, which cannot be forced on a fork.
    ///      The second source is a standard ERC4626 vault (`maxWithdraw` works), served by the same fuse and market.
    function testShouldContinueToNextInstantWithdrawalFuseWhenMorphoWithdrawFails() public {
        // given: half of the assets in Morpho (its withdraw is going to fail), half in a standard vault
        MockERC4626 standardVault = new MockERC4626(IERC20(USDC), "Standard USDC Vault", "sUSDC");
        {
            // grantMarketSubstrates replaces the list: grant both vaults at once
            bytes32[] memory substrates = new bytes32[](2);
            substrates[0] = PlasmaVaultConfigLib.addressToBytes32(MORPHO_VAULT);
            substrates[1] = PlasmaVaultConfigLib.addressToBytes32(address(standardVault));
            vm.prank(TestAddresses.FUSE_MANAGER);
            _plasmaVault.addSubstratesToMarket(IporFusionMarkets.ERC4626_0001, substrates);
        }
        _enter(_plasmaVault, address(_supplyFuse), ENTER_AMOUNT);
        _enterVault(_plasmaVault, address(_supplyFuse), address(standardVault), ENTER_AMOUNT);
        assertEq(IERC20(USDC).balanceOf(address(_plasmaVault)), 0, "no idle USDC left");

        // the Morpho fuse is the first instant-withdrawal source, the standard vault the second one
        InstantWithdrawalFusesParamsStruct[] memory config = new InstantWithdrawalFusesParamsStruct[](2);
        config[0] = _instantWithdrawalEntry(address(_supplyFuse), MORPHO_VAULT);
        config[1] = _instantWithdrawalEntry(address(_supplyFuse), address(standardVault));
        vm.prank(TestAddresses.CONFIG_INSTANT_WITHDRAWAL_FUSES_MANAGER);
        IPlasmaVaultGovernance(address(_plasmaVault)).configureInstantWithdrawalFuses(config);

        uint256 userSharesBefore = _plasmaVault.balanceOf(USER);
        uint256 sharesToRedeem = userSharesBefore / 4;
        uint256 expectedAssets = _plasmaVault.convertToAssets(sharesToRedeem);
        // what the Plasma Vault asks each instant-withdrawal fuse for: the redeemed assets plus the slippage buffer,
        // there is no idle USDC and nothing to release from the withdraw manager
        uint256 requested = expectedAssets +
            IporMath.division(expectedAssets * _plasmaVault.DEFAULT_SLIPPAGE_IN_PERCENTAGE(), 100);
        uint256 morphoSharesBefore = IERC4626(MORPHO_VAULT).balanceOf(address(_plasmaVault));
        uint256 standardSharesBefore = standardVault.balanceOf(address(_plasmaVault));
        assertLt(requested, standardVault.maxWithdraw(address(_plasmaVault)), "the standard vault should cover it");

        vm.mockCallRevert(MORPHO_VAULT, abi.encodeWithSelector(IERC4626.withdraw.selector), "");

        // when
        vm.recordLogs();
        vm.prank(USER);
        uint256 received = _plasmaVault.redeem(sharesToRedeem, USER, USER);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // then: the redeem is served by the second source
        assertEq(IERC20(USDC).balanceOf(USER), received, "user USDC balance should match the redeemed amount");
        assertEq(received, expectedAssets, "user should receive exactly a quarter of the vault");
        assertEq(_plasmaVault.balanceOf(USER), userSharesBefore - sharesToRedeem, "remaining user shares");
        assertEq(
            IERC4626(MORPHO_VAULT).balanceOf(address(_plasmaVault)),
            morphoSharesBefore,
            "Morpho shares should be untouched"
        );
        assertEq(
            standardVault.balanceOf(address(_plasmaVault)),
            standardSharesBefore - requested,
            "the standard vault should pay the whole request (1:1 shares)"
        );

        // and: the failed Morpho withdraw is reported with the full context, and the only Exit is the standard vault's
        _assertSingleExitFailed(logs, MORPHO_VAULT, requested);
        _assertSingleExit(logs, address(standardVault), requested);
    }

    // ------------------------------------------------------------------------------------------------------------
    // negative control: the published fuse
    // ------------------------------------------------------------------------------------------------------------

    /// @dev Same position, same Morpho vault, same Plasma Vault configuration (market ERC4626_0004): the published fuse
    ///      exit is a silent no-op, the fuse built from source withdraws the position.
    function testPublishedFuseCannotExitMorphoVaultsV2WhileFixedFuseCan() public {
        // given: a Plasma Vault with the published fuse and the fixed fuse on the same market
        assertEq(
            Erc4626SupplyFuse(PUBLISHED_FUSE).MARKET_ID(),
            IporFusionMarkets.ERC4626_0004,
            "published fuse should serve ERC4626_0004"
        );
        assertGt(PUBLISHED_FUSE.code.length, 0, "published fuse should be deployed on the fork");

        Erc4626SupplyFuse fixedFuse = new Erc4626SupplyFuse(IporFusionMarkets.ERC4626_0004);
        address[] memory fuses = new address[](2);
        fuses[0] = PUBLISHED_FUSE;
        fuses[1] = address(fixedFuse);
        PlasmaVault vault = _buildVault(
            IporFusionMarkets.ERC4626_0004,
            fuses,
            address(new Erc4626BalanceFuse(IporFusionMarkets.ERC4626_0004))
        );
        _deposit(vault, USER_DEPOSIT);

        // the published fuse's enter works, only its exit cap breaks
        _enter(vault, PUBLISHED_FUSE, ENTER_AMOUNT);
        uint256 sharesBefore = IERC4626(MORPHO_VAULT).balanceOf(address(vault));
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(vault));
        assertGt(sharesBefore, 0, "the published fuse should enter the position");
        assertEq(IERC4626(MORPHO_VAULT).maxWithdraw(address(vault)), 0, "maxWithdraw is 0 while shares are held");

        // when: exit through the published fuse
        vm.recordLogs();
        _exit(vault, PUBLISHED_FUSE, PARTIAL_EXIT_AMOUNT, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // then: silent no-op, no revert
        assertEq(IERC20(USDC).balanceOf(address(vault)), usdcBefore, "published fuse withdraws nothing");
        assertEq(IERC4626(MORPHO_VAULT).balanceOf(address(vault)), sharesBefore, "published fuse burns no shares");
        assertEq(_logsFrom(logs, MORPHO_VAULT), 0, "published fuse never reaches the Morpho vault (no Withdraw event)");
        assertEq(
            _logsOf(logs, address(vault), Erc4626SupplyFuse.Erc4626SupplyFuseExit.selector).length,
            0,
            "published fuse emits no Erc4626SupplyFuseExit"
        );
        assertEq(
            _logsOf(logs, address(vault), Erc4626SupplyFuse.Erc4626SupplyFuseExitFailed.selector).length,
            0,
            "published fuse emits no Erc4626SupplyFuseExitFailed"
        );

        // and: the fixed fuse withdraws the very same position
        _exit(vault, address(fixedFuse), PARTIAL_EXIT_AMOUNT, 0);
        assertEq(
            IERC20(USDC).balanceOf(address(vault)) - usdcBefore,
            PARTIAL_EXIT_AMOUNT,
            "fixed fuse withdraws exactly the requested USDC"
        );
        assertLt(IERC4626(MORPHO_VAULT).balanceOf(address(vault)), sharesBefore, "fixed fuse burns shares");
    }

    // ------------------------------------------------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------------------------------------------------

    /// @dev Deploys a USDC Plasma Vault with `marketId_` granting the Morpho vault as its only substrate
    function _buildVault(
        uint256 marketId_,
        address[] memory fuses_,
        address balanceFuse_
    ) private returns (PlasmaVault plasmaVault) {
        address withdrawManager;
        vm.startPrank(TestAddresses.ATOMIST);
        (plasmaVault, withdrawManager) = PlasmaVaultHelper.deployMinimalPlasmaVault(
            DeployMinimalPlasmaVaultParams({
                underlyingToken: USDC,
                underlyingTokenName: "USDC",
                priceOracleMiddleware: _priceOracleMiddleware.addressOf(),
                atomist: TestAddresses.ATOMIST
            })
        );
        IporFusionAccessManager accessManager = plasmaVault.accessManagerOf();
        accessManager.setupInitRoles(
            plasmaVault,
            withdrawManager,
            address(new RewardsClaimManager(address(accessManager), address(plasmaVault)))
        );
        vm.stopPrank();

        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(MORPHO_VAULT);

        vm.startPrank(TestAddresses.FUSE_MANAGER);
        plasmaVault.addSubstratesToMarket(marketId_, substrates);
        plasmaVault.addFusesToVault(fuses_);
        plasmaVault.addBalanceFusesToVault(marketId_, balanceFuse_);
        vm.stopPrank();
    }

    function _deposit(PlasmaVault plasmaVault_, uint256 assets_) private {
        deal(USDC, USER, assets_);
        vm.startPrank(USER);
        IERC20(USDC).approve(address(plasmaVault_), assets_);
        plasmaVault_.deposit(assets_, USER);
        vm.stopPrank();
    }

    function _configureInstantWithdrawal(PlasmaVault plasmaVault_, address fuse_) private {
        InstantWithdrawalFusesParamsStruct[] memory config = new InstantWithdrawalFusesParamsStruct[](1);
        config[0] = _instantWithdrawalEntry(fuse_, MORPHO_VAULT);

        vm.prank(TestAddresses.CONFIG_INSTANT_WITHDRAWAL_FUSES_MANAGER);
        IPlasmaVaultGovernance(address(plasmaVault_)).configureInstantWithdrawalFuses(config);
    }

    function _instantWithdrawalEntry(
        address fuse_,
        address vault_
    ) private pure returns (InstantWithdrawalFusesParamsStruct memory) {
        bytes32[] memory params = new bytes32[](2);
        /// @dev params[0] is the amount placeholder, the Plasma Vault overwrites it with the amount to withdraw
        params[0] = bytes32(0);
        params[1] = PlasmaVaultConfigLib.addressToBytes32(vault_);
        return InstantWithdrawalFusesParamsStruct({fuse: fuse_, params: params});
    }

    /// @dev Enters the Morpho vault and asserts the precondition every exit test relies on: the Plasma Vault holds
    ///      Morpho shares while `maxWithdraw` is still 0, so an exit can only work through the share-based fallback
    ///      (the same assert in `setUp` runs with no shares held and proves nothing)
    function _enter(PlasmaVault plasmaVault_, address fuse_, uint256 assets_) private {
        _enterVault(plasmaVault_, fuse_, MORPHO_VAULT, assets_);

        assertGt(IERC4626(MORPHO_VAULT).balanceOf(address(plasmaVault_)), 0, "position should hold Morpho shares");
        assertEq(
            IERC4626(MORPHO_VAULT).maxWithdraw(address(plasmaVault_)),
            0,
            "Morpho maxWithdraw should be 0 while shares are held"
        );
    }

    function _enterVault(PlasmaVault plasmaVault_, address fuse_, address vault_, uint256 assets_) private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: fuse_,
            data: abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                Erc4626SupplyFuseEnterData({
                    vault: vault_,
                    vaultAssetAmount: assets_,
                    minSharesOut: IERC4626(vault_).previewDeposit(assets_)
                })
            )
        });

        vm.prank(TestAddresses.ALPHA);
        plasmaVault_.execute(actions);
    }

    function _exit(PlasmaVault plasmaVault_, address fuse_, uint256 assets_, uint256 maxSharesBurned_) private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: fuse_,
            data: abi.encodeWithSignature(
                "exit((address,uint256,uint256))",
                Erc4626SupplyFuseExitData({
                    vault: MORPHO_VAULT,
                    vaultAssetAmount: assets_,
                    maxSharesBurned: maxSharesBurned_
                })
            )
        });

        vm.prank(TestAddresses.ALPHA);
        plasmaVault_.execute(actions);
    }

    /// @dev Exactly one `Erc4626SupplyFuseExitFailed` event, emitted by `_supplyFuse` for `vault_` and `assets_`
    function _assertSingleExitFailed(Vm.Log[] memory logs_, address vault_, uint256 assets_) private view {
        Vm.Log[] memory failedLogs = _logsOf(
            logs_,
            address(_plasmaVault),
            Erc4626SupplyFuse.Erc4626SupplyFuseExitFailed.selector
        );
        assertEq(failedLogs.length, 1, "exactly one Erc4626SupplyFuseExitFailed event");
        (address version, address asset, address vault, uint256 vaultAssetAmount) = abi.decode(
            failedLogs[0].data,
            (address, address, address, uint256)
        );
        assertEq(version, address(_supplyFuse), "failed event version");
        assertEq(asset, USDC, "failed event asset");
        assertEq(vault, vault_, "failed event vault");
        assertEq(vaultAssetAmount, assets_, "failed event vaultAssetAmount");
    }

    /// @dev Exactly one `Erc4626SupplyFuseExit` event (so none for any other vault, Morpho included), emitted by
    ///      `_supplyFuse` for `vault_` and `assets_`
    function _assertSingleExit(Vm.Log[] memory logs_, address vault_, uint256 assets_) private view {
        Vm.Log[] memory exitLogs = _logsOf(
            logs_,
            address(_plasmaVault),
            Erc4626SupplyFuse.Erc4626SupplyFuseExit.selector
        );
        assertEq(exitLogs.length, 1, "exactly one Erc4626SupplyFuseExit event");
        (address version, address asset, address vault, uint256 vaultAssetAmount, ) = abi.decode(
            exitLogs[0].data,
            (address, address, address, uint256, uint256)
        );
        assertEq(version, address(_supplyFuse), "exit event version");
        assertEq(asset, USDC, "exit event asset");
        assertEq(vault, vault_, "exit event vault");
        assertEq(vaultAssetAmount, assets_, "exit event vaultAssetAmount");
    }

    function _logsFrom(Vm.Log[] memory logs_, address emitter_) private pure returns (uint256 count) {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == emitter_) {
                ++count;
            }
        }
    }

    /// @dev Logs emitted by `emitter_` with `topic0_` (fuses run by delegatecall, so the Plasma Vault is the emitter)
    function _logsOf(
        Vm.Log[] memory logs_,
        address emitter_,
        bytes32 topic0_
    ) private pure returns (Vm.Log[] memory matches) {
        uint256 count;
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == emitter_ && logs_[i].topics.length > 0 && logs_[i].topics[0] == topic0_) {
                ++count;
            }
        }
        matches = new Vm.Log[](count);
        count = 0;
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == emitter_ && logs_[i].topics.length > 0 && logs_[i].topics[0] == topic0_) {
                matches[count] = logs_[i];
                ++count;
            }
        }
    }
}
