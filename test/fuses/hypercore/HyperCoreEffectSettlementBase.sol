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

/// @title HyperCoreEffectSettlementBase (fixture copied from the IL-8416 reviewer PoC)
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
contract HyperCoreEffectSettlementBase is Test {
    uint256 internal constant MARKET_ID = IporFusionMarkets.HYPERCORE;
    uint256 internal constant UNDERLYING_MARKET_ID = IporFusionMarkets.ERC20_VAULT_BALANCE;
    uint64 internal constant USDC_TOKEN = 0;
    uint32 internal constant HYPE_PERP = 150;
    uint128 internal constant CLOID_1 = 1;
    uint128 internal constant CLOID_2 = 2;
    uint128 internal constant CLOID_3 = 3;
    uint24 internal constant ACTION_LIMIT_ORDER = 1;
    bytes32 internal constant PENDING_SLOT = 0xff3841d45e92b4b113213ebf16e5e18527d87d1b739008d460c4a8565edaf200;

    address internal _owner = makeAddr("OWNER");
    address internal _daoFeeManager = makeAddr("DAO_FEE_MANAGER");
    address internal _atomist = makeAddr("ATOMIST");
    address internal _fuseManager = makeAddr("FUSE_MANAGER");
    address internal _user = makeAddr("USER");
    address internal _secondUser = makeAddr("SECOND_USER");
    address internal _nonWhitelistedUser = makeAddr("NON_WHITELISTED_USER");
    address internal _builder = makeAddr("BUILDER");

    FusionFactory internal _fusionFactory;
    PlasmaVault internal _vault;
    IporFusionAccessManager internal _accessManager;
    PriceOracleMiddlewareManager internal _priceManager;
    HyperCoreMockUsdc internal _usdc;
    HyperCore internal _hyperCore;
    SimCoreDepositWallet internal _depositWallet;

    HyperCoreBalanceFuse internal _balanceFuse;
    HyperCoreDepositFuse internal _depositFuse;
    HyperCoreMarginFuse internal _marginFuse;
    HyperCoreOrderFuse internal _orderFuse;
    HyperCoreCancelFuse internal _cancelFuse;
    HyperCoreSendFuse internal _sendFuse;
    HyperCoreBuilderFeeFuse internal _builderFeeFuse;
    ERC20BalanceFuse internal _underlyingBalanceFuse;

    function setUp() public virtual {
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
    function _wireRoles() internal {
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

    function _configurePriceOracle() internal {
        MockEffectSettlementChainlinkFeed usdcFeed = new MockEffectSettlementChainlinkFeed(1e8, 8);
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
    function _registerCoreUsdcToken() internal {
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
    function _deployAndAddFuses() internal {
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
    ///      SendCap, the transfer window and MaxUsdClassTransferUsd6. Since IL-8543 no order window or
    ///      settlement mode is granted (orders and cancels are TIMING-only). `grantMarketSubstrates`
    ///      REPLACES the whole substrate list for the market on every call (see
    ///      `HyperCoreFlowSimulationTest`'s NOTE).
    function _grantSubstrates() internal {
        _grantSubstratesWindows(2);
    }

    function _grantSubstratesWindows(uint240 windowTransfer_) internal {
        _grantBaseSubstrates(windowTransfer_, new bytes32[](0));
    }

    /// @dev Grants the base set plus the legacy `Config{WindowOrderSeconds}` / `Config{SettlementMode}` keys that
    ///      IL-8543 reserved and ignores (a vault configured before the removal of REPORTED may still hold them).
    function _grantSubstratesWithLegacyKeys(uint240 settlementMode_, uint240 windowOrder_) internal {
        bytes32[] memory legacy = new bytes32[](2);
        legacy[0] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.WindowOrderSeconds, windowOrder_);
        legacy[1] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.SettlementMode, settlementMode_);
        _grantBaseSubstrates(2, legacy);
    }

    function _grantBaseSubstrates(uint240 windowTransfer_, bytes32[] memory extra_) private {
        bytes32[] memory substrates = new bytes32[](8 + extra_.length);
        substrates[0] = HyperCoreSubstrateLib.encodeSpotToken(USDC_TOKEN, address(_usdc));
        substrates[1] = HyperCoreSubstrateLib.encodePerpMarket(HYPE_PERP, 1_000_000e6, false);
        substrates[2] = HyperCoreSubstrateLib.encodeDestination(HyperCoreLib.systemAddress(USDC_TOKEN));
        substrates[3] = HyperCoreSubstrateLib.encodeDestination(address(_vault));
        substrates[4] = HyperCoreSubstrateLib.encodeBuilder(_builder, 100);
        substrates[5] = HyperCoreSubstrateLib.encodeSendCap(USDC_TOKEN, type(uint128).max);
        substrates[6] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.WindowTransferSeconds, windowTransfer_);
        substrates[7] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.MaxUsdClassTransferUsd6, 1_000_000e6);
        for (uint256 i; i < extra_.length; ++i) {
            substrates[8 + i] = extra_[i];
        }
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

    function _marketIdsOf(uint256 marketId_) internal pure returns (uint256[] memory marketIds) {
        marketIds = new uint256[](1);
        marketIds[0] = marketId_;
    }

    /// @dev M4 §5: installs `HyperCoreCapitalFlowPreHook` on every share-priced selector plus
    ///      `HyperCorePendingActionPreHook` on `execute`/`updateMarketsBalances` (no caller exception, IL-8543).
    function _installHooks() internal {
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
    function _settle(uint64 windowSeconds_) internal {
        vm.warp(block.timestamp + uint256(windowSeconds_) + 1);
        CoreSimulatorLib.nextBlock();
    }

    function _refreshAndTotalAssets() internal returns (uint256) {
        uint256[] memory marketIds = _marketIdsOf(MARKET_ID);
        vm.prank(_atomist);
        _vault.updateMarketsBalances(marketIds);
        return _vault.totalAssets();
    }

    function _isPending() internal view returns (bool) {
        return uint64(uint256(vm.load(address(_vault), PENDING_SLOT))) != 0;
    }
}

/// @dev Minimal Chainlink-style price feed returning a constant price, matching the pattern used
///      elsewhere in this test suite (e.g. HyperCoreFlowSimulationTest.t.sol).
contract MockEffectSettlementChainlinkFeed {
    int256 internal immutable _price;
    uint8 internal immutable _decimals;

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
