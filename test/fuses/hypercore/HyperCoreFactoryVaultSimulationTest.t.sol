// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {FuseAction} from "../../../contracts/interfaces/IPlasmaVault.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {PriceOracleMiddlewareManager} from "../../../contracts/managers/price/PriceOracleMiddlewareManager.sol";

import {FusionFactory} from "../../../contracts/factory/FusionFactory.sol";
import {FusionFactoryLogicLib} from "../../../contracts/factory/lib/FusionFactoryLogicLib.sol";

import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";

import {HyperCoreBalanceFuse} from "../../../contracts/fuses/hypercore/HyperCoreBalanceFuse.sol";
import {HyperCoreDepositFuse, HyperCoreDepositFuseEnterData} from "../../../contracts/fuses/hypercore/HyperCoreDepositFuse.sol";
import {HyperCoreMarginFuse, HyperCoreMarginFuseEnterData} from "../../../contracts/fuses/hypercore/HyperCoreMarginFuse.sol";
import {HyperCoreOrderFuse, HyperCoreOrderFuseEnterData} from "../../../contracts/fuses/hypercore/HyperCoreOrderFuse.sol";
import {
    HyperCoreCancelFuse,
    HyperCoreCancelFuseCancelByOidData
} from "../../../contracts/fuses/hypercore/HyperCoreCancelFuse.sol";
import {
    HyperCoreSendFuse,
    HyperCoreSendFuseSendAssetData
} from "../../../contracts/fuses/hypercore/HyperCoreSendFuse.sol";
import {HyperCoreBuilderFeeFuse} from "../../../contracts/fuses/hypercore/HyperCoreBuilderFeeFuse.sol";
import {HyperCoreSubstrateLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreSubstrateLib.sol";
import {HyperCoreLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreLib.sol";
import {HyperCorePendingLib} from "../../../contracts/fuses/hypercore/lib/HyperCorePendingLib.sol";
import {
    HyperCoreCapitalFlowPreHook
} from "../../../contracts/handlers/pre_hooks/pre_hooks/HyperCoreCapitalFlowPreHook.sol";
import {
    HyperCorePendingActionPreHook
} from "../../../contracts/handlers/pre_hooks/pre_hooks/HyperCorePendingActionPreHook.sol";

import {HyperCoreFactoryVaultHelper} from "./HyperCoreFactoryVaultHelper.sol";
import {HyperCoreMockUsdc} from "./HyperCoreTestHelper.sol";

import {CoreSimulatorLib} from "./simulation/CoreSimulatorLib.sol";
import {HyperCore} from "./simulation/HyperCore.sol";
import {PrecompileLib} from "./simulation/src/PrecompileLib.sol";
import {SimCoreDepositWallet} from "./simulation/SimCoreDepositWallet.sol";

/// @title HyperCoreFactoryVaultSimulationTest
/// @notice Offline, no-RPC proof that the HyperCore integration works end to end on a vault created
///         through `FusionFactory.clone()` with the full M4 production configuration
///         (`chat/M4-DEPLOYMENT.md` §"Preflight, deployment order, and readback"), against the same
///         vendored offline HyperCore simulator used by `HyperCoreFlowSimulationTest`
///         (`test/fuses/hypercore/simulation/VENDORED.md`). Unlike `HyperCoreFlowSimulationTest`
///         (which wires a hand-rolled minimal `PlasmaVault` via `PlasmaVaultHelper`), this test
///         builds the vault the way an institutional deployment would: through the factory, with
///         access-manager roles granted the way `FusionFactory.clone()` actually leaves them (only
///         `OWNER_ROLE` on the clone owner -- everything else, including the vault's own
///         `UPDATE_MARKETS_BALANCES_ROLE` self-grant, is exactly what the initializer library grants
///         by default; see `_wireRoles()`), then layering the HyperCore fuses/hooks on top.
/// @dev Production-configuration gaps found while writing this test are called out inline as
///      `PRODUCTION LIMITATION` comments with the exact file:line, per the task brief -- none were
///      worked around with shortcuts unavailable to a real factory-created vault.
///      - `FuseWhitelist` (`contracts/fuses/whitelist/FuseWhitelist.sol`) is never referenced by
///        `contracts/factory/FusionFactory.sol` or `contracts/factory/lib/FusionFactoryLogicLib.sol`
///        (confirmed by `grep -rn "FuseWhitelist" contracts/factory/`, no matches): the factory flow
///        has no whitelist step, so FuseTypes 106-113 registration is skipped here as instructed.
contract HyperCoreFactoryVaultSimulationTest is Test {
    uint256 private constant MARKET_ID = IporFusionMarkets.HYPERCORE;
    uint256 private constant UNDERLYING_MARKET_ID = IporFusionMarkets.ERC20_VAULT_BALANCE;
    uint64 private constant USDC_TOKEN = 0;
    uint32 private constant HYPE_PERP = 150;
    uint128 private constant CLOID_1 = 1;
    uint128 private constant CLOID_2 = 2;
    uint128 private constant CLOID_3 = 3;
    uint24 private constant ACTION_LIMIT_ORDER = 1;
    bytes32 private constant PENDING_SLOT = 0xff3841d45e92b4b113213ebf16e5e18527d87d1b739008d460c4a8565edaf200;

    address private _owner = makeAddr("OWNER");
    address private _daoFeeManager = makeAddr("DAO_FEE_MANAGER");
    address private _atomist = makeAddr("ATOMIST");
    address private _fuseManager = makeAddr("FUSE_MANAGER");
    address private _user = makeAddr("USER");
    address private _secondUser = makeAddr("SECOND_USER");
    address private _nonWhitelistedUser = makeAddr("NON_WHITELISTED_USER");
    address private _builder = makeAddr("BUILDER");

    FusionFactory private _fusionFactory;
    PlasmaVault private _vault;
    IporFusionAccessManager private _accessManager;
    PriceOracleMiddlewareManager private _priceManager;
    HyperCoreMockUsdc private _usdc;
    HyperCore private _hyperCore;
    SimCoreDepositWallet private _depositWallet;

    HyperCoreBalanceFuse private _balanceFuse;
    HyperCoreDepositFuse private _depositFuse;
    HyperCoreMarginFuse private _marginFuse;
    HyperCoreOrderFuse private _orderFuse;
    HyperCoreCancelFuse private _cancelFuse;
    HyperCoreSendFuse private _sendFuse;
    HyperCoreBuilderFeeFuse private _builderFeeFuse;
    ERC20BalanceFuse private _underlyingBalanceFuse;

    function setUp() public {
        // --- vendored offline HyperCore simulator (same fixture as HyperCoreFlowSimulationTest) ---
        _hyperCore = CoreSimulatorLib.init();
        CoreSimulatorLib.setOfflineMode(true);
        CoreSimulatorLib.setRevertOnFailure(true);

        _usdc = new HyperCoreMockUsdc();

        // --- deploy FusionFactory offline and create the vault through clone() (M4 §"Preflight") ---
        _fusionFactory = HyperCoreFactoryVaultHelper.deployFusionFactory(vm, _owner, _daoFeeManager, address(_usdc));
        FusionFactoryLogicLib.FusionInstance memory instance = _fusionFactory.clone(
            "HyperCore Institutional Vault",
            "hcvUSDC",
            address(_usdc),
            0,
            _owner,
            0
        );
        _vault = PlasmaVault(instance.plasmaVault);
        _accessManager = IporFusionAccessManager(instance.accessManager);
        _priceManager = PriceOracleMiddlewareManager(instance.priceManager);

        _wireRoles();
        _configurePriceOracle();
        _registerCoreUsdcToken();
        _deployAndAddFuses();
        _grantSubstrates();
        _installHooks();

        // --- an institutional vault stays PRIVATE: only WHITELIST_ROLE holders may deposit. The
        //     depositor allowlist (not convertToPublicVault/enableTransferShares) is the production
        //     posture for a factory-created vault under this checklist. ---
        vm.startPrank(_atomist);
        _accessManager.grantRole(Roles.WHITELIST_ROLE, _user, 0);
        _accessManager.grantRole(Roles.WHITELIST_ROLE, _secondUser, 0);
        vm.stopPrank();

        // --- fund the vault via a real deposit, as a real institutional user would ---
        _usdc.mint(_user, 1_000_000e6);
        vm.startPrank(_user);
        _usdc.approve(address(_vault), 1_000_000e6);
        _vault.deposit(1_000_000e6, _user);
        vm.stopPrank();
    }

    /// @notice A non-whitelisted account must never be able to deposit into a private,
    ///         factory-created institutional vault, regardless of HyperCore pending state.
    function testNonWhitelistedDepositReverts() public {
        _usdc.mint(_nonWhitelistedUser, 1_000e6);
        vm.startPrank(_nonWhitelistedUser);
        _usdc.approve(address(_vault), 1_000e6);
        vm.expectRevert(abi.encodeWithSignature("AccessManagedUnauthorized(address)", _nonWhitelistedUser));
        _vault.deposit(1_000e6, _nonWhitelistedUser);
        vm.stopPrank();
    }

    /// @dev `FusionFactory.clone()` (contracts/factory/lib/FusionFactoryLogicLib.sol:280-303) grants
    ///      only `OWNER_ROLE` to `owner_` (plus admins, unused here); every other role required by
    ///      the M4 checklist -- `ATOMIST_ROLE`, `FUSE_MANAGER_ROLE`, `ALPHA_ROLE`,
    ///      `PRE_HOOKS_MANAGER_ROLE`, `PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE`,
    ///      `UPDATE_MARKETS_BALANCES_ROLE` for the test's own `updateMarketsBalances` calls -- must
    ///      be granted afterward through the standard admin chain
    ///      (`IporFusionAccessManagerInitializerLibV1._generateAdminRoles()`:
    ///      OWNER_ROLE -> ATOMIST_ROLE/PRE_HOOKS_MANAGER_ROLE/GUARDIAN_ROLE,
    ///      ATOMIST_ROLE -> ALPHA_ROLE/FUSE_MANAGER_ROLE/UPDATE_MARKETS_BALANCES_ROLE/
    ///      PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE/WHITELIST_ROLE/...).
    ///      The vault's own `UPDATE_MARKETS_BALANCES_ROLE` self-grant (needed by
    ///      `HyperCoreCapitalFlowPreHook`'s self-call) is NOT part of this function: it is already
    ///      granted unconditionally by the initializer
    ///      (IporFusionAccessManagerInitializerLibV1.sol:301-308, "Always add
    ///      UPDATE_MARKETS_BALANCES_ROLE to the Plasma Vault"), including through the factory path.
    function _wireRoles() private {
        vm.startPrank(_owner);
        _accessManager.grantRole(Roles.ATOMIST_ROLE, _atomist, 0);
        // PRE_HOOKS_MANAGER_ROLE is administered by OWNER_ROLE, not ATOMIST_ROLE (see
        // IporFusionAccessManagerInitializerLibV1.sol:451): setPreHookImplementations would revert
        // for `_atomist` without this explicit grant, even though `_atomist` already holds
        // ATOMIST_ROLE.
        _accessManager.grantRole(Roles.PRE_HOOKS_MANAGER_ROLE, _atomist, 0);
        vm.stopPrank();

        vm.startPrank(_atomist);
        _accessManager.grantRole(Roles.FUSE_MANAGER_ROLE, _fuseManager, 0);
        _accessManager.grantRole(Roles.ALPHA_ROLE, address(this), 0);
        _accessManager.grantRole(Roles.PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE, _atomist, 0);
        _accessManager.grantRole(Roles.UPDATE_MARKETS_BALANCES_ROLE, _atomist, 0);
        vm.stopPrank();
    }

    function _configurePriceOracle() private {
        MockChainlinkFeed usdcFeed = new MockChainlinkFeed(1e8, 8);
        address[] memory assets = new address[](1);
        assets[0] = address(_usdc);
        address[] memory sources = new address[](1);
        sources[0] = address(usdcFeed);
        vm.prank(_atomist);
        _priceManager.setAssetsPriceSources(assets, sources);
    }

    /// @dev Same re-registration `HyperCoreFlowSimulationTest` performs: `CoreSimulatorLib.init()`
    ///      seeds USDC (token 0) with `evmContract == address(0)` offline, so it must be re-pointed
    ///      at a `SimCoreDepositWallet` shim wrapping this vault's mock USDC for
    ///      `HyperCoreDepositFuse`'s CoreDepositWallet routing to work (see
    ///      `simulation/SimCoreDepositWallet.sol` and `HyperCoreFlowSimulationTest`'s NatSpec).
    function _registerCoreUsdcToken() private {
        _depositWallet = new SimCoreDepositWallet(address(_usdc), USDC_TOKEN);
        PrecompileLib.TokenInfo memory usdcInfo = PrecompileLib.TokenInfo({
            name: "USDC",
            spots: new uint64[](0),
            deployerTradingFeeShare: 0,
            deployer: address(0),
            evmContract: address(_depositWallet),
            szDecimals: 8,
            weiDecimals: 8,
            evmExtraWeiDecimals: -2
        });
        _hyperCore.registerTokenInfo(USDC_TOKEN, usdcInfo);
    }

    /// @dev Deploys the six typed HyperCore action fuses plus HyperCoreBalanceFuse(55), and the
    ///      ERC20BalanceFuse(7) that would back a future market 55 -> 7 dependency graph (M4 §4;
    ///      see the PRODUCTION LIMITATION note below -- the dependency graph itself is not wired in
    ///      this test), then adds them all to the factory-created vault via FUSE_MANAGER_ROLE.
    function _deployAndAddFuses() private {
        _balanceFuse = new HyperCoreBalanceFuse(MARKET_ID);
        _depositFuse = new HyperCoreDepositFuse(MARKET_ID);
        _marginFuse = new HyperCoreMarginFuse(MARKET_ID);
        _orderFuse = new HyperCoreOrderFuse(MARKET_ID);
        _cancelFuse = new HyperCoreCancelFuse(MARKET_ID);
        _sendFuse = new HyperCoreSendFuse(MARKET_ID);
        _builderFeeFuse = new HyperCoreBuilderFeeFuse(MARKET_ID);
        _underlyingBalanceFuse = new ERC20BalanceFuse(UNDERLYING_MARKET_ID);

        address[] memory fuses = new address[](6);
        fuses[0] = address(_depositFuse);
        fuses[1] = address(_marginFuse);
        fuses[2] = address(_orderFuse);
        fuses[3] = address(_cancelFuse);
        fuses[4] = address(_sendFuse);
        fuses[5] = address(_builderFeeFuse);

        vm.startPrank(_fuseManager);
        PlasmaVaultGovernance(address(_vault)).addFuses(fuses);
        PlasmaVaultGovernance(address(_vault)).addBalanceFuse(MARKET_ID, address(_balanceFuse));
        PlasmaVaultGovernance(address(_vault)).addBalanceFuse(UNDERLYING_MARKET_ID, address(_underlyingBalanceFuse));
        vm.stopPrank();
    }

    /// @dev Grants the full production substrate set for market 55 (M4 §4): SpotToken(0, usdc),
    ///      PerpMarket(HYPE), Destination(vault) + Destination(USDC system address), Builder,
    ///      SendCap, the transfer window and MaxUsdClassTransferUsd6. Since IL-8543 there is no order window
    ///      or settlement-mode config (orders and cancels are TIMING-only).
    function _grantSubstrates() private {
        bytes32[] memory substrates = new bytes32[](8);
        substrates[0] = HyperCoreSubstrateLib.encodeSpotToken(USDC_TOKEN, address(_usdc));
        substrates[1] = HyperCoreSubstrateLib.encodePerpMarket(HYPE_PERP, 1_000_000e6, false);
        substrates[2] = HyperCoreSubstrateLib.encodeDestination(HyperCoreLib.systemAddress(USDC_TOKEN));
        substrates[3] = HyperCoreSubstrateLib.encodeDestination(address(_vault));
        substrates[4] = HyperCoreSubstrateLib.encodeBuilder(_builder, 100);
        substrates[5] = HyperCoreSubstrateLib.encodeSendCap(USDC_TOKEN, type(uint128).max);
        substrates[6] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.WindowTransferSeconds, 2);
        substrates[7] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.MaxUsdClassTransferUsd6, 1_000_000e6);
        vm.prank(_fuseManager);
        PlasmaVaultGovernance(address(_vault)).grantMarketSubstrates(MARKET_ID, substrates);
    }

    // PRODUCTION LIMITATION (M4-DEPLOYMENT.md §4, "Configure the vault's market-55 balance fuse and
    // dependency `55 -> 7` only when a non-underlying linked EVM token is granted and market 7
    // represents it"): the only linked EVM token granted in this test is USDC, which IS the vault's
    // underlying asset, so the 55 -> 7 dependency graph is deliberately NOT installed here.
    // `ERC20BalanceFuse(7)` is still added (harmless, unused) via `_deployAndAddFuses()` so a future
    // non-underlying Core-linked token could be granted without an extra fuse-registration step, but
    // wiring the dependency graph itself with no non-underlying grant would misrepresent this
    // deployment step as complete when M4 explicitly says it should be skipped in that case.

    function _marketIdsOf(uint256 marketId_) private pure returns (uint256[] memory marketIds) {
        marketIds = new uint256[](1);
        marketIds[0] = marketId_;
    }

    /// @dev M4 §5: installs `HyperCoreCapitalFlowPreHook` on every share-priced selector plus
    ///      `HyperCorePendingActionPreHook` (no caller exception, IL-8543) on `execute`/`updateMarketsBalances`.
    function _installHooks() private {
        address pendingHook = address(new HyperCorePendingActionPreHook());
        address capitalFlowHook = address(new HyperCoreCapitalFlowPreHook());

        // `depositWithPermit` exists on PlasmaVault (contracts/vaults/PlasmaVault.sol:615) and is
        // share-priced identically to `deposit`, so it gets the capital-flow hook too.
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = PlasmaVault.execute.selector;
        selectors[1] = PlasmaVault.updateMarketsBalances.selector;
        selectors[2] = PlasmaVault.deposit.selector;
        selectors[3] = PlasmaVault.depositWithPermit.selector;
        selectors[4] = PlasmaVault.mint.selector;
        selectors[5] = PlasmaVault.withdraw.selector;
        selectors[6] = PlasmaVault.redeem.selector;
        selectors[7] = PlasmaVault.redeemFromRequest.selector;

        address[] memory implementations = new address[](8);
        implementations[0] = pendingHook;
        implementations[1] = pendingHook;
        implementations[2] = capitalFlowHook;
        implementations[3] = capitalFlowHook;
        implementations[4] = capitalFlowHook;
        implementations[5] = capitalFlowHook;
        implementations[6] = capitalFlowHook;
        implementations[7] = capitalFlowHook;

        bytes32[][] memory hookSubstrates = new bytes32[][](8);
        for (uint256 i; i < 8; ++i) {
            hookSubstrates[i] = new bytes32[](0);
        }

        vm.prank(_atomist);
        PlasmaVaultGovernance(address(_vault)).setPreHookImplementations(selectors, implementations, hookSubstrates);
    }

    /// @dev Mirrors `HyperCoreFlowSimulationTest._settle`: advances the simulator far enough to both
    ///      let `CoreSimulatorLib.nextBlock()` process the queued CoreWriter action and satisfy
    ///      TIMING settlement (`block.timestamp >= pendingUntil` and a later
    ///      `HyperCoreLib.l1BlockNumber()`, backed here by `block.number`).
    function _settle(uint64 windowSeconds_) private {
        vm.warp(block.timestamp + uint256(windowSeconds_) + 1);
        CoreSimulatorLib.nextBlock();
    }

    function _refreshAndTotalAssets() private returns (uint256) {
        uint256[] memory marketIds = _marketIdsOf(MARKET_ID);
        vm.prank(_atomist);
        _vault.updateMarketsBalances(marketIds);
        return _vault.totalAssets();
    }

    function _isPending() private view returns (bool) {
        return uint64(uint256(vm.load(address(_vault), PENDING_SLOT))) != 0;
    }

    // Shared across the phase helpers below to keep each function's local-variable count small
    // enough to avoid "stack too deep" (no via-ir; see project CLAUDE.md).
    uint256 private _totalAssetsBefore;
    uint256 private _totalAssetsAfterDeposit;
    uint256 private _totalAssetsAfterMargin;
    int64 private _expectedSzi;

    /// @notice Full production route on the factory-created vault: deposit -> margin -> IOC short ->
    ///         GTC/cancel enqueue -> reduce-only close -> margin back -> sendAsset to the USDC system
    ///         address, (TIMING-only orders), plus the two capital-flow/pending-guard checks
    ///         from the task brief.
    function testFactoryVaultTimingFlow() public {
        _totalAssetsBefore = _vault.totalAssets();
        assertEq(_totalAssetsBefore, 1_000_000e6, "vault should hold the deposited USDC on the EVM side");

        _phaseDeposit();
        _phaseMarginToPerp();
        _phaseOpenShort();
        _phaseSecondDepositBlockedInSameCoreBlock();
        _phaseExternalRefreshNotBlockedByTimingOrder();
        _phaseGtcAndCancel();
        _phaseCloseShort();
        _phaseMarginToSpotAndSendBack();
    }

    function _phaseDeposit() private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_depositFuse),
            abi.encodeWithSelector(
                HyperCoreDepositFuse.enter.selector, HyperCoreDepositFuseEnterData({tokenIndex: USDC_TOKEN, amount: 100_000e6})
            )
        );
        _vault.execute(actions);
        _settle(2);

        assertEq(_depositWallet.depositForCallCount(), 1, "USDC deposit should route through the CoreDepositWallet");
        assertTrue(HyperCoreLib.coreUserExists(address(_vault)), "vault HyperCore account should now be activated");

        _totalAssetsAfterDeposit = _refreshAndTotalAssets();
        assertApproxEqAbs(
            _totalAssetsAfterDeposit, _totalAssetsBefore, 2e6, "NAV should be ~flat across an EVM<->Core deposit"
        );
    }

    function _phaseMarginToPerp() private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_marginFuse),
            abi.encodeWithSelector(
                HyperCoreMarginFuse.enter.selector, HyperCoreMarginFuseEnterData({usd6: 50_000e6, toPerp: true})
            )
        );
        _vault.execute(actions);
        _settle(2);

        _totalAssetsAfterMargin = _refreshAndTotalAssets();
        assertApproxEqAbs(
            _totalAssetsAfterMargin, _totalAssetsAfterDeposit, 1e6, "spot->perp margin move should be NAV neutral"
        );
    }

    function _phaseOpenShort() private {
        CoreSimulatorLib.forcePerpLeverage(address(_vault), HYPE_PERP, 10);
        CoreSimulatorLib.setMarkPx(HYPE_PERP, 400_000); // -> $40.00 in the 8-decimal comparison scale

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_orderFuse),
            abi.encodeWithSelector(
                HyperCoreOrderFuse.enter.selector,
                HyperCoreOrderFuseEnterData({
                    asset: HYPE_PERP,
                    isBuy: false,
                    limitPx: 35e8,
                    sz: 1e8,
                    reduceOnly: false,
                    tif: HyperCoreLib.TIF_IOC,
                    cloid: CLOID_1
                })
            )
        );
        _vault.execute(actions);

        _expectedSzi = -int64(uint64(1 * 10 ** HyperCoreLib.perpAssetInfo(HYPE_PERP).szDecimals));
        // Position/NAV assertions happen after _settle() at the top of _phaseGtcAndCancel(); the two
        // blocked-while-pending checks below must run BEFORE that settle so the order is still
        // pending.
    }

    /// @notice TIMING orders create no pending record; a user deposit is blocked only by the one-Core-block
    ///         mini-gate (`HyperCoreOrderInFlight`) and succeeds once the Core block advances (checked at the end).
    function _phaseSecondDepositBlockedInSameCoreBlock() private {
        _usdc.mint(_secondUser, 10_000e6);
        vm.startPrank(_secondUser);
        _usdc.approve(address(_vault), 10_000e6);
        vm.expectRevert(
            abi.encodeWithSelector(
                HyperCorePendingLib.HyperCoreOrderInFlight.selector, uint64(HyperCoreLib.l1BlockNumber())
            )
        );
        _vault.deposit(10_000e6, _secondUser);
        vm.stopPrank();
    }

    /// @notice The execute guard is record-based, so an external balance refresh is not blocked by a TIMING order.
    function _phaseExternalRefreshNotBlockedByTimingOrder() private {
        uint256[] memory marketIds = _marketIdsOf(MARKET_ID);
        vm.prank(_atomist);
        _vault.updateMarketsBalances(marketIds);
    }

    function _phaseGtcAndCancel() private {
        _settle(10);

        HyperCoreLib.Position memory position = HyperCoreLib.position(address(_vault), HYPE_PERP);
        assertEq(position.szi, _expectedSzi, "short IOC should have filled for 1.00 HYPE");

        uint256 totalAssetsAfterShort = _refreshAndTotalAssets();
        assertApproxEqAbs(
            totalAssetsAfterShort,
            _totalAssetsAfterMargin,
            1e6,
            "opening the short at mark should be ~NAV neutral before funding/fees"
        );

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_orderFuse),
            abi.encodeWithSelector(
                HyperCoreOrderFuse.enter.selector,
                HyperCoreOrderFuseEnterData({
                    asset: HYPE_PERP,
                    isBuy: false,
                    limitPx: 45e8, // above mark (40): a sell does NOT cross, order is dropped
                    sz: 1e8,
                    reduceOnly: false,
                    tif: HyperCoreLib.TIF_GTC,
                    cloid: CLOID_2
                })
            )
        );
        _vault.execute(actions);
        _settle(10);

        HyperCoreLib.Position memory positionAfterGtc = HyperCoreLib.position(address(_vault), HYPE_PERP);
        assertEq(positionAfterGtc.szi, _expectedSzi, "non-crossing GTC order must not change the position");

        actions[0] = FuseAction(
            address(_cancelFuse),
            abi.encodeWithSelector(
                HyperCoreCancelFuse.enterCancelByOid.selector, HyperCoreCancelFuseCancelByOidData({asset: HYPE_PERP, oid: 1})
            )
        );
        _vault.execute(actions);
        _settle(10);
    }

    function _phaseCloseShort() private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_orderFuse),
            abi.encodeWithSelector(
                HyperCoreOrderFuse.enter.selector,
                HyperCoreOrderFuseEnterData({
                    asset: HYPE_PERP,
                    isBuy: true,
                    limitPx: 45e8,
                    sz: 1e8,
                    reduceOnly: true,
                    tif: HyperCoreLib.TIF_IOC,
                    cloid: CLOID_3
                })
            )
        );
        _vault.execute(actions);
        _settle(10);

        HyperCoreLib.Position memory positionAfterClose = HyperCoreLib.position(address(_vault), HYPE_PERP);
        assertEq(positionAfterClose.szi, 0, "reduce-only IOC should have closed the short");
    }

    function _phaseMarginToSpotAndSendBack() private {
        uint64 perpBalanceUsd6 = HyperCoreLib.withdrawable(address(_vault));
        assertGt(perpBalanceUsd6, 0, "perp margin should be nonzero after the round trip");

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_marginFuse),
            abi.encodeWithSelector(
                HyperCoreMarginFuse.enter.selector, HyperCoreMarginFuseEnterData({usd6: perpBalanceUsd6, toPerp: false})
            )
        );
        _vault.execute(actions);
        _settle(2);

        HyperCoreLib.SpotBalance memory spotBalance = HyperCoreLib.spotBalance(address(_vault), USDC_TOKEN);
        uint64 sendable = spotBalance.total - spotBalance.hold;
        assertGt(sendable, 0, "vault should hold a spot USDC balance to send back to the EVM side");

        uint256 evmUsdcBefore = _usdc.balanceOf(address(_vault));
        actions[0] = FuseAction(
            address(_sendFuse),
            abi.encodeWithSelector(
                HyperCoreSendFuse.enterSendAsset.selector,
                HyperCoreSendFuseSendAssetData({
                    destination: HyperCoreLib.systemAddress(USDC_TOKEN),
                    sourceDex: HyperCoreLib.SPOT_DEX,
                    destinationDex: HyperCoreLib.SPOT_DEX,
                    tokenIndex: USDC_TOKEN,
                    amountWei: sendable
                })
            )
        );
        _vault.execute(actions);
        _settle(2);

        uint256 evmUsdcAfter = _usdc.balanceOf(address(_vault));
        assertGt(evmUsdcAfter, evmUsdcBefore, "USDC should be back on the vault's EVM balance after sendAsset");

        uint256 totalAssetsAfterRoundTrip = _refreshAndTotalAssets();
        assertApproxEqRel(
            totalAssetsAfterRoundTrip,
            _totalAssetsBefore,
            0.01e18,
            "NAV should be ~flat (within 1%) after the full round trip, minus fees"
        );

        // Now that the pending gate is clear, the second user's earlier-blocked deposit succeeds.
        vm.prank(_secondUser);
        uint256 shares = _vault.deposit(10_000e6, _secondUser);
        assertGt(shares, 0, "second user's deposit should succeed once the pending gate has cleared");
    }

    /// @notice IL-8543: an IOC order on the factory-created vault creates no pending record (TIMING-only), is
    ///         genuinely matched by the simulator, and a market-55 refresh afterwards is NAV-neutral.
    function testFactoryVaultOrderCreatesNoPendingRecordAndRefreshIsNeutral() public {
        // Activate the vault's HyperCore account and fund perp margin first, exactly like the TIMING
        // flow -- otherwise placing a perp order fails with no funded account/margin to trade against.
        _totalAssetsBefore = _vault.totalAssets();
        _phaseDeposit();
        _phaseMarginToPerp();

        uint256 navBefore = _vault.totalAssets();
        uint256 supplyBefore = _vault.totalSupply();

        CoreSimulatorLib.forcePerpLeverage(address(_vault), HYPE_PERP, 10);
        CoreSimulatorLib.setMarkPx(HYPE_PERP, 400_000);

        uint64 enqueuedL1Block = HyperCoreLib.l1BlockNumber();

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_orderFuse),
            abi.encodeWithSelector(
                HyperCoreOrderFuse.enter.selector,
                HyperCoreOrderFuseEnterData({
                    asset: HYPE_PERP,
                    isBuy: false,
                    limitPx: 35e8,
                    sz: 1e8,
                    reduceOnly: false,
                    tif: HyperCoreLib.TIF_IOC,
                    cloid: CLOID_1
                })
            )
        );
        _vault.execute(actions);
        assertFalse(_isPending(), "orders create no pending record (IL-8527/IL-8543)");

        // Advance the simulator (fills the IOC order against the mark price set above) and one L1 block so
        // the order mini-gate opens.
        CoreSimulatorLib.nextBlock();
        vm.warp(block.timestamp + 1);
        assertGt(HyperCoreLib.l1BlockNumber(), enqueuedL1Block, "L1 block advanced past the order");

        assertGt(_vault.totalAssetsInMarket(MARKET_ID), 0, "market 55 reads the live simulated Core state");
        // The IOC order is matched by CoreSimulatorLib against a live order book, so a few USDC-wei of
        // taker-side price/rounding noise between navBefore and the post-fill NAV is expected, not a bug.
        assertApproxEqAbs(_refreshAndTotalAssets(), navBefore, 1e4, "order fill is NAV-neutral");
        assertEq(_vault.totalSupply(), supplyBefore, "no performance fee shares are minted");
    }
}

/// @dev Minimal Chainlink-style price feed returning a constant price, matching the pattern used
///      elsewhere in this test suite (e.g. HyperCoreFlowSimulationTest.t.sol).
contract MockChainlinkFeed {
    int256 private immutable _price;
    uint8 private immutable _decimals;

    constructor(int256 price_, uint8 decimals_) {
        _price = price_;
        _decimals = decimals_;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, _price, block.timestamp, block.timestamp, 1);
    }
}
