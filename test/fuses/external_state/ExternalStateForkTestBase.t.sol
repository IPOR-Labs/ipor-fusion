// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {
    ExternalStateOperationFuse,
    ExternalStateOperationFuseEnterData,
    ExternalStateOperationFuseExitData
} from "../../../contracts/fuses/external_state/ExternalStateOperationFuse.sol";
import {ExternalStateBalanceFuse} from "../../../contracts/fuses/external_state/ExternalStateBalanceFuse.sol";
import {ExternalStateUnpauseFuse, ExternalStateUnpauseData} from "../../../contracts/fuses/external_state/ExternalStateUnpauseFuse.sol";
import {ExternalStateRescueFuse} from "../../../contracts/fuses/external_state/ExternalStateRescueFuse.sol";
import {ExternalStatePausePreHook} from "../../../contracts/handlers/pre_hooks/pre_hooks/ExternalStatePausePreHook.sol";

import {ExternalStateExecutor} from "../../../contracts/fuses/external_state/ExternalStateExecutor.sol";
import {IExternalStateExecutor, ExternalStateExecutorAction} from "../../../contracts/fuses/external_state/IExternalStateExecutor.sol";
import {ExternalStateSubstrateLib} from "../../../contracts/fuses/external_state/lib/ExternalStateSubstrateLib.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";

import {PlasmaVault, PlasmaVaultInitData, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {IPriceOracleMiddleware} from "../../../contracts/price_oracle/IPriceOracleMiddleware.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IporMath} from "../../../contracts/libraries/math/IporMath.sol";

import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {RoleLib, UsersToRoles} from "../../RoleLib.sol";
import {MutableValuePriceFeed} from "../../managers/MutableValuePriceFeed.sol";
import {ExternalStateTestConstants, ExternalStateSlotHelpers} from "../../unitTest/fuses/external_state/ExternalStateTestHelpers.sol";

/// @title ExternalStateForkTestBase
/// @notice Shared fork-test fixture for the ExternalState fuse family, running against a REAL `PlasmaVault`.
/// @dev
///  Mainnet-fork strategy:
///   - A real `PlasmaVault` (with `PlasmaVaultBase`, `IporFusionAccessManager`, `WithdrawManager`,
///     `PriceOracleMiddleware`) is deployed in-test. Every fuse call goes through
///     `PlasmaVault.execute(FuseAction[])` as ALPHA — the exact production entry path, including
///     the `executeStarted` fallback gate that blocked the ExternalState bootstrap in IL-7895. No
///     vault-shaped mock is used anywhere.
///   - Ethereum mainnet is forked only to source real ERC20s (USDC, USDT, DAI) — these exercise
///     the price oracle and decimals conversions at production scale. No existing mainnet vault
///     is required, keeping the fixture resilient against mainnet state drift.
///   - Prices come from the real `PriceOracleMiddleware` fed by per-asset `MutableValuePriceFeed`
///     instances (18-decimals, USD-per-token). Tests change prices via `_setPrice`.
///   - The "ExternalState protocol" itself is modeled as `MockExternalStateProtocolForFork` — the off-chain custody
///     counterparty has no on-chain implementation, so a recording target stands in for it. The
///     TARGET substrate is wired to that contract so the fuses' validation paths are exercised
///     exactly as in production.
///   - The `ExternalStatePausePreHook` is registered on the vault for the four user-facing selectors
///     (deposit / mint / withdraw / redeem) via `setPreHookImplementations` — pre-hook suites
///     exercise it through real user operations, not by delegatecalling `run` directly.
///
///  Because the tests fork a pinned block and re-deploy every piece in-test, they are
///  deterministic and not sensitive to mainnet state.
abstract contract ExternalStateForkTestBase is Test {
    // ============================================================
    // Mainnet addresses (pinned-block-stable)
    // ============================================================

    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    /// @dev Pinned mainnet block used for every fork (matches the Midas fixtures).
    uint256 internal constant FORK_BLOCK = 21800000;

    // ============================================================
    // ERC-7201 slot of `ExternalStateExecutorStorageLib.ExternalStateStorage` (re-exported from ExternalStateTestConstants
    // so per-suite fork tests can keep referencing `EXTERNAL_STATE_SLOT` without a second import).
    // ============================================================

    bytes32 internal constant EXTERNAL_STATE_SLOT = ExternalStateTestConstants.EXTERNAL_STATE_SLOT;

    // ============================================================
    // Market identifiers & tunables
    // ============================================================

    /// @dev Production-aligned market id from the global registry — fork tests mirror real
    ///      deployment wiring. Unit tests use arbitrary local ids since they exercise the fuses
    ///      in isolation.
    uint256 internal constant MARKET_ID = IporFusionMarkets.EXTERNAL_STATE;

    uint256 internal constant STALENESS_MAX_S = 1 days;
    uint256 internal constant BIG_CHANGE_BPS = 1000; // 10%
    /// @dev Dust threshold is a "percent of one base token" where 100 = 1 token, 10_000 = 100
    ///      tokens, 1_000_000 = 10_000 tokens. We use a generous value so fork tests that leave
    ///      funds on the executor (pre-protocol-deposit state) are not spuriously blocked by the
    ///      dust check during custodian propose/confirm. Tests that want to exercise the dust
    ///      guard re-grant with a smaller threshold via `_grantSubstrates`.
    uint256 internal constant DUST_THRESHOLD = 1_000_000_000; // 10M tokens allowed on the executor
    uint256 internal constant MIN_UPDATE_INTERVAL_S = 5 minutes;

    // ============================================================
    // Actors
    // ============================================================

    address internal atomist;
    uint256 internal atomistPk;
    address internal alpha;
    address internal custodianA;
    address internal custodianB;
    address internal balanceAccountA;
    address internal balanceAccountB;
    address internal user;

    // ============================================================
    // Deployed pieces
    // ============================================================

    PlasmaVault internal vault;
    IporFusionAccessManager internal access;
    PriceOracleMiddleware internal oracle;
    MockExternalStateProtocolForFork internal externalStateProtocol;

    /// @dev Per-asset mutable price feeds registered in the real `PriceOracleMiddleware`.
    mapping(address asset => MutableValuePriceFeed feed) internal priceFeeds;

    ExternalStateOperationFuse internal opFuse;
    ExternalStateBalanceFuse internal balFuse;
    ExternalStateUnpauseFuse internal unpauseFuse;
    ExternalStateRescueFuse internal rescueFuse;
    ExternalStatePausePreHook internal preHook;

    UsersToRoles internal usersToRoles;

    // ============================================================
    // Fork setup
    // ============================================================

    /// @notice Forks mainnet at `FORK_BLOCK` and wires every ExternalState fixture piece around a real vault.
    function setUp() public virtual {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), FORK_BLOCK);

        // Actors
        (atomist, atomistPk) = makeAddrAndKey("atomist");
        alpha = makeAddr("alpha");
        custodianA = makeAddr("custodianA");
        custodianB = makeAddr("custodianB");
        balanceAccountA = makeAddr("balanceAccountA");
        balanceAccountB = makeAddr("balanceAccountB");
        user = makeAddr("user");

        externalStateProtocol = new MockExternalStateProtocolForFork();

        // Real price oracle middleware: USDC, USDT, DAI all at $1 (18-decimal feeds)
        oracle = new PriceOracleMiddleware(address(0));
        oracle.initialize(atomist);
        address[] memory assets = new address[](3);
        assets[0] = USDC;
        assets[1] = USDT;
        assets[2] = DAI;
        address[] memory sources = new address[](3);
        for (uint256 i; i < assets.length; ++i) {
            MutableValuePriceFeed feed = new MutableValuePriceFeed(1e18);
            priceFeeds[assets[i]] = feed;
            sources[i] = address(feed);
        }
        vm.prank(atomist);
        oracle.setAssetsPricesSources(assets, sources);

        // Real access manager + real vault. RoleLib's fee-manager wiring requires superAdmin to
        // also hold ATOMIST_ROLE, so one address plays both (mirrors PlasmaVaultNonceTest).
        usersToRoles.superAdmin = atomist;
        usersToRoles.atomist = atomist;
        usersToRoles.alphas = new address[](1);
        usersToRoles.alphas[0] = alpha;
        usersToRoles.performanceFeeManagers = new address[](0);
        usersToRoles.managementFeeManagers = new address[](0);
        usersToRoles.feeTimelock = 0;

        access = RoleLib.createAccessManager(usersToRoles, 0, vm);
        address withdrawManager = address(new WithdrawManager(address(access)));

        vm.startPrank(atomist);
        vault = new PlasmaVault();
        vault.proxyInitialize(
            PlasmaVaultInitData({
                assetName: "ExternalState Fork Plasma Vault",
                assetSymbol: "externalStatePV",
                underlyingToken: USDC,
                priceOracleMiddleware: address(oracle),
                feeConfig: FeeConfigHelper.createZeroFeeConfig(),
                accessManager: address(access),
                plasmaVaultBase: address(new PlasmaVaultBase()),
                withdrawManager: withdrawManager,
                plasmaVaultVotesPlugin: address(0)
            })
        );
        vm.stopPrank();

        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(vault), access, withdrawManager);

        // RoleLib does not wire these governance selectors — grant them to the atomist here.
        bytes4[] memory extraSig = new bytes4[](3);
        extraSig[0] = PlasmaVaultGovernance.grantMarketSubstrates.selector;
        extraSig[1] = PlasmaVaultGovernance.setPreHookImplementations.selector;
        extraSig[2] = PlasmaVault.updateMarketsBalances.selector;
        vm.prank(atomist);
        access.setTargetFunctionRole(address(vault), extraSig, Roles.ATOMIST_ROLE);

        // Fuses + pre-hook
        opFuse = new ExternalStateOperationFuse(MARKET_ID);
        balFuse = new ExternalStateBalanceFuse(MARKET_ID);
        unpauseFuse = new ExternalStateUnpauseFuse(MARKET_ID);
        rescueFuse = new ExternalStateRescueFuse(MARKET_ID);
        preHook = new ExternalStatePausePreHook(MARKET_ID);

        address[] memory fuses = new address[](3);
        fuses[0] = address(opFuse);
        fuses[1] = address(unpauseFuse);
        fuses[2] = address(rescueFuse);
        vm.startPrank(atomist);
        PlasmaVaultGovernance(address(vault)).addFuses(fuses);
        PlasmaVaultGovernance(address(vault)).addBalanceFuse(MARKET_ID, address(balFuse));
        vm.stopPrank();

        // Default substrate set (per-test setUps extend as needed via _grantSubstrates(list))
        _grantDefaultSubstrates();

        // Labels improve forge traces
        vm.label(USDC, "USDC");
        vm.label(USDT, "USDT");
        vm.label(DAI, "DAI");
        vm.label(address(vault), "PlasmaVault");
        vm.label(address(oracle), "PriceOracleMiddleware");
        vm.label(address(access), "IporFusionAccessManager");
        vm.label(address(externalStateProtocol), "MockExternalStateProtocolForFork");
        vm.label(address(opFuse), "ExternalStateOperationFuse");
        vm.label(address(balFuse), "ExternalStateBalanceFuse");
        vm.label(address(unpauseFuse), "ExternalStateUnpauseFuse");
        vm.label(address(rescueFuse), "ExternalStateRescueFuse");
        vm.label(address(preHook), "ExternalStatePausePreHook");
        vm.label(atomist, "atomist");
        vm.label(alpha, "alpha");
        vm.label(custodianA, "custodianA");
        vm.label(custodianB, "custodianB");
        vm.label(balanceAccountA, "balanceAccountA");
        vm.label(balanceAccountB, "balanceAccountB");
        vm.label(user, "user");
    }

    // ============================================================
    // Price helpers
    // ============================================================

    /// @notice Set the USD price of an asset in the real oracle (18-decimals, USD per whole token).
    function _setPrice(address asset_, uint256 priceWad_) internal {
        priceFeeds[asset_].setPrice(int256(priceWad_));
    }

    // ============================================================
    // Substrate configuration
    // ============================================================

    /// @notice Default substrate set used by most tests. Child tests can re-grant via
    ///         `_grantSubstrates(list)` to change thresholds or replace accounts.
    function _grantDefaultSubstrates() internal {
        bytes32[] memory subs = new bytes32[](11);
        subs[0] = ExternalStateSubstrateLib.encodeAssetSubstrate(USDC);
        subs[1] = ExternalStateSubstrateLib.encodeAssetSubstrate(USDT);
        subs[2] = ExternalStateSubstrateLib.encodeBalanceAccountSubstrate(balanceAccountA);
        subs[3] = ExternalStateSubstrateLib.encodeBalanceAccountSubstrate(balanceAccountB);
        subs[4] = ExternalStateSubstrateLib.encodeCustodianSubstrate(custodianA);
        subs[5] = ExternalStateSubstrateLib.encodeCustodianSubstrate(custodianB);
        subs[6] = ExternalStateSubstrateLib.encodeTargetSubstrate(address(externalStateProtocol), MockExternalStateProtocolForFork.deposit.selector);
        subs[7] = ExternalStateSubstrateLib.encodeStalenessMaxSubstrate(STALENESS_MAX_S);
        subs[8] = ExternalStateSubstrateLib.encodeBigChangeBpsSubstrate(BIG_CHANGE_BPS);
        subs[9] = ExternalStateSubstrateLib.encodeDustThresholdSubstrate(DUST_THRESHOLD);
        subs[10] = ExternalStateSubstrateLib.encodeMinUpdateIntervalSubstrate(MIN_UPDATE_INTERVAL_S);
        _grantSubstrates(subs);
    }

    /// @notice Re-grant a custom substrate set (replaces the existing grants) as the atomist.
    function _grantSubstrates(bytes32[] memory subs_) internal {
        vm.prank(atomist);
        PlasmaVaultGovernance(address(vault)).grantMarketSubstrates(MARKET_ID, subs_);
    }

    // ============================================================
    // Pre-hook wiring
    // ============================================================

    /// @notice Register `ExternalStatePausePreHook` for the four user-facing vault selectors
    ///         (deposit / mint / withdraw / redeem) — the production wiring. Alpha's `execute`
    ///         is intentionally NOT gated (see ExternalStatePausePreHook NatSpec).
    function _registerPausePreHook() internal {
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = PlasmaVault.deposit.selector;
        selectors[1] = PlasmaVault.mint.selector;
        selectors[2] = PlasmaVault.withdraw.selector;
        selectors[3] = PlasmaVault.redeem.selector;

        address[] memory implementations = new address[](4);
        bytes32[][] memory substrates = new bytes32[][](4);
        for (uint256 i; i < 4; ++i) {
            implementations[i] = address(preHook);
            substrates[i] = new bytes32[](0);
        }

        vm.prank(atomist);
        PlasmaVaultGovernance(address(vault)).setPreHookImplementations(selectors, implementations, substrates);
    }

    // ============================================================
    // Fuse execution through the real vault
    // ============================================================

    /// @notice Run a single fuse call through `PlasmaVault.execute` as ALPHA — the production path.
    function _executeFuse(address fuse_, bytes memory data_) internal {
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction({fuse: fuse_, data: data_});
        vm.prank(alpha);
        vault.execute(calls);
    }

    // ============================================================
    // Executor helpers
    // ============================================================

    /// @notice Returns the executor address bound to the vault via ERC-7201. May be zero before
    ///         the first enter / createExecutor call.
    function _executorAddress() internal view returns (address) {
        bytes32 value = vm.load(address(vault), EXTERNAL_STATE_SLOT);
        return address(uint160(uint256(value)));
    }

    /// @notice Deploys the executor via a fuse createExecutor() call (idempotent).
    function _createExecutor() internal returns (address executor) {
        _executeFuse(address(opFuse), abi.encodeCall(opFuse.createExecutor, ()));
        executor = _executorAddress();
        require(executor != address(0), "executor not deployed");
    }

    /// @notice Re-read substrate cache on the executor (e.g. after a new substrate grant).
    function _syncExecutorSubstrates() internal {
        address executor = _executorAddress();
        if (executor == address(0)) return;
        IExternalStateExecutor(executor).syncSubstrates();
    }

    // ============================================================
    // Enter / Exit wrappers (alpha-role semantics)
    // ============================================================

    function _enter(address asset_, uint256 amount_, address balanceAccount_) internal {
        _enter(asset_, amount_, balanceAccount_, new ExternalStateExecutorAction[](0));
    }

    function _enter(address asset_, uint256 amount_, address balanceAccount_, ExternalStateExecutorAction[] memory actions_)
        internal
    {
        ExternalStateOperationFuseEnterData memory d = ExternalStateOperationFuseEnterData({
            asset: asset_, amount: amount_, balanceAccount: balanceAccount_, actions: actions_
        });
        _executeFuse(address(opFuse), abi.encodeCall(opFuse.enter, (d)));
    }

    function _exit(address asset_, uint256 amount_, address balanceAccount_) internal {
        _exit(asset_, amount_, balanceAccount_, new ExternalStateExecutorAction[](0));
    }

    function _exit(address asset_, uint256 amount_, address balanceAccount_, ExternalStateExecutorAction[] memory actions_)
        internal
    {
        ExternalStateOperationFuseExitData memory d = ExternalStateOperationFuseExitData({
            asset: asset_, amount: amount_, balanceAccount: balanceAccount_, actions: actions_
        });
        _executeFuse(address(opFuse), abi.encodeCall(opFuse.exit, (d)));
    }

    /// @notice Trigger a real market-balance refresh (`PlasmaVault.updateMarketsBalances`) — which
    ///         delegatecalls `ExternalStateBalanceFuse.balanceOf()` with all its side effects (big-change
    ///         pause detection, snapshots) — and return the market balance as USD WAD, matching
    ///         the old direct-`balanceOf()` semantics.
    /// @dev The vault stores market balances in underlying-asset decimals (USD value divided by
    ///      the underlying's price); multiplying back by the current underlying price restores
    ///      the exact USD WAD figure `balanceOf()` returned.
    function _readBalanceOf() internal returns (uint256 value) {
        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = MARKET_ID;
        vm.prank(atomist);
        vault.updateMarketsBalances(marketIds);

        uint256 balanceInUnderlying = vault.totalAssetsInMarket(MARKET_ID);
        if (balanceInUnderlying == 0) return 0;

        address underlying = vault.asset();
        (uint256 price, uint256 priceDecimals) = IPriceOracleMiddleware(address(oracle)).getAssetPrice(underlying);
        uint256 underlyingDecimals = IERC20Metadata(underlying).decimals();
        value = IporMath.convertToWad(balanceInUnderlying * price, underlyingDecimals + priceDecimals);
    }

    // ============================================================
    // Custodian propose / confirm helpers
    // ============================================================

    /// @notice Proposes + confirms a balance update in one helper call. Uses `custodianA` as the
    ///         proposer and `custodianB` as the confirmer by default.
    function _custodianConfirm(address balanceAccount_, uint256 newValue_) internal {
        _custodianConfirm(custodianA, custodianB, balanceAccount_, newValue_);
    }

    /// @notice Explicit form used when tests want to pick the proposer / confirmer.
    function _custodianConfirm(address proposer_, address confirmer_, address balanceAccount_, uint256 newValue_)
        internal
    {
        address executor = _executorAddress();
        require(executor != address(0), "executor not deployed");
        vm.prank(proposer_);
        IExternalStateExecutor(executor).proposeBalance(balanceAccount_, newValue_);
        (,, uint64 proposedAt, uint256 nonce) = ExternalStateExecutor(executor).pendingProposals(balanceAccount_);
        bytes32 h = _proposalHash(executor, balanceAccount_, newValue_, proposer_, proposedAt, nonce);
        vm.prank(confirmer_);
        IExternalStateExecutor(executor).confirmBalance(balanceAccount_, h);
    }

    /// @dev Mirror of ExternalStateExecutor._proposalHash (H-1 binding: executor + chainid + balanceAccount).
    function _proposalHash(
        address executor_,
        address ba_,
        uint256 val_,
        address proposer_,
        uint64 at_,
        uint256 n_
    ) internal view returns (bytes32) {
        return keccak256(abi.encode(executor_, block.chainid, ba_, val_, proposer_, at_, n_));
    }

    // ============================================================
    // Pause / unpause helpers
    // ============================================================

    /// @notice Reads the ExternalState pause flag from vault storage.
    function _readPaused() internal view returns (bool) {
        return ExternalStateSlotHelpers.readPaused(address(vault));
    }

    /// @notice Forces the pause flag (useful when a test wants to skip the big-change trigger).
    function _forcePaused(bool value_) internal {
        ExternalStateSlotHelpers.setPaused(address(vault), value_);
    }

    /// @notice Builds a valid atomist-signed unpause payload (chain-id + vault-id + market-id bound).
    function _buildUnpauseData(uint256 confirmedBalance_, uint256 nonce_, uint256 expiration_)
        internal
        view
        returns (ExternalStateUnpauseData memory data)
    {
        bytes32 digest = keccak256(
            abi.encodePacked(address(vault), MARKET_ID, confirmedBalance_, nonce_, expiration_, block.chainid)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(atomistPk, digest);
        data = ExternalStateUnpauseData({
            confirmedTotalBalance: confirmedBalance_,
            nonce: nonce_,
            expirationTime: expiration_,
            signature: abi.encodePacked(r, s, v)
        });
    }
}

/// @notice Minimal ExternalState protocol for fork tests: records deposits without touching funds.
/// @dev Custodians settle balances off-chain; the protocol is a target that alpha can call. The
///      TARGET substrate is bound to `deposit(address,uint256)` in the default setup. This is the
///      only modeled counterparty — the vault, access manager, and oracle middleware are real.
contract MockExternalStateProtocolForFork {
    /// @notice Emitted when `deposit` is invoked from the executor.
    event ExternalStateMockDeposit(address asset, uint256 amount, address caller);

    uint256 public totalDeposits;

    function deposit(address asset_, uint256 amount_) external {
        totalDeposits += amount_;
        emit ExternalStateMockDeposit(asset_, amount_, msg.sender);
    }
}
