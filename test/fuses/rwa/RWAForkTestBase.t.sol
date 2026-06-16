// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {
    RWAOperationFuse,
    RWAOperationFuseEnterData,
    RWAOperationFuseExitData
} from "../../../contracts/fuses/rwa/RWAOperationFuse.sol";
import {RWABalanceFuse} from "../../../contracts/fuses/rwa/RWABalanceFuse.sol";
import {RWAUnpauseFuse, RWAUnpauseData} from "../../../contracts/fuses/rwa/RWAUnpauseFuse.sol";
import {RWARescueFuse} from "../../../contracts/fuses/rwa/RWARescueFuse.sol";
import {RWAPausePreHook} from "../../../contracts/handlers/pre_hooks/pre_hooks/RWAPausePreHook.sol";

import {RWAExecutor} from "../../../contracts/fuses/rwa/RWAExecutor.sol";
import {IRWAExecutor, RWAExecutorAction} from "../../../contracts/fuses/rwa/IRWAExecutor.sol";
import {RWASubstrateLib} from "../../../contracts/fuses/rwa/lib/RWASubstrateLib.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";

import {MockPlasmaVaultForRWA} from "../../unitTest/fuses/rwa/mocks/MockPlasmaVaultForRWA.sol";
import {MockAccessManager} from "../../unitTest/fuses/rwa/mocks/MockAccessManager.sol";
import {MockPriceOracleMiddleware} from "../../unitTest/fuses/rwa/mocks/MockPriceOracleMiddleware.sol";
import {RWATestConstants, RWASlotHelpers} from "../../unitTest/fuses/rwa/RWATestHelpers.sol";

/// @title RWAForkTestBase
/// @notice Shared fork-test fixture for the RWA fuse family.
/// @dev
///  Mainnet-fork strategy — minimal and pragmatic:
///   - We instantiate `MockPlasmaVaultForRWA` as the vault-shaped delegatecall harness. The mock
///     stores the RWA substrates and the price-oracle-middleware pointer in the canonical
///     `PlasmaVaultConfigLib` / `PlasmaVaultLib` storage slots, so the real `RWAOperationFuse`,
///     `RWABalanceFuse`, `RWAPausePreHook`, `RWAUnpauseFuse`, and `RWARescueFuse` read the exact
///     same storage they would on a real PlasmaVault deployment.
///   - We fork Ethereum mainnet only to source a real ERC20 (USDC) and a second decimals-variant
///     ERC20 (WETH) — these exercise the price oracle and decimals conversions in a way that
///     matches production scale. No existing mainnet vault, access manager, or RWA protocol is
///     required; everything around the fuses is deployed in-test, keeping the fixture resilient
///     against mainnet state drift.
///   - The "RWA protocol" itself is modeled as `MockRWAProtocolForFork` — a simple contract that
///     accepts a `deposit(address,uint256)` call from the executor. The TARGET substrate is
///     wired to that contract so the fuses' validation paths are exercised exactly as they
///     would be in production. The protocol does not need to be real for the fuses to be tested.
///   - Two custodians, one atomist, one alpha and the two balance accounts are EOAs created via
///     `makeAddr` / `makeAddrAndKey`. Roles are stored in `MockAccessManager` so
///     `RWAUnpauseFuse` can resolve `ATOMIST_ROLE` via the `IAccessManager` interface.
///
///  Because the tests fork a pinned block and re-deploy every harness piece in-test, they are
///  deterministic and not sensitive to mainnet state.
abstract contract RWAForkTestBase is Test {
    // ============================================================
    // Mainnet addresses (pinned-block-stable)
    // ============================================================

    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    /// @dev Pinned mainnet block used for every fork (matches the Midas fixtures).
    uint256 internal constant FORK_BLOCK = 21800000;

    // ============================================================
    // ERC-7201 slot of `RWAExecutorStorageLib.RWAStorage` (re-exported from RWATestConstants
    // so per-suite fork tests can keep referencing `RWA_SLOT` without a second import).
    // ============================================================

    bytes32 internal constant RWA_SLOT = RWATestConstants.RWA_SLOT;

    // ============================================================
    // Market identifiers & tunables
    // ============================================================

    /// @dev Production-aligned market id from the global registry — fork tests mirror real
    ///      deployment wiring. Unit tests use arbitrary local ids since they exercise the fuses
    ///      in isolation.
    uint256 internal constant MARKET_ID = IporFusionMarkets.RWA;

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

    MockPlasmaVaultForRWA internal vault;
    MockAccessManager internal access;
    MockPriceOracleMiddleware internal oracle;
    MockRWAProtocolForFork internal rwaProtocol;

    RWAOperationFuse internal opFuse;
    RWABalanceFuse internal balFuse;
    RWAUnpauseFuse internal unpauseFuse;
    RWARescueFuse internal rescueFuse;
    RWAPausePreHook internal preHook;

    // ============================================================
    // Fork setup
    // ============================================================

    /// @notice Forks mainnet at `FORK_BLOCK` and wires every RWA fixture piece.
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

        // Infra
        vault = new MockPlasmaVaultForRWA();
        access = new MockAccessManager();
        oracle = new MockPriceOracleMiddleware();
        rwaProtocol = new MockRWAProtocolForFork();

        vault.setUnderlying(USDC);
        vault.setAccessManager(address(access));
        vault.setPriceOracleMiddleware(address(oracle));

        // Oracle: USDC, USDT, DAI all at $1 (8-decimal quote, matching Fusion convention)
        oracle.setPrice(USDC, 1e8, 8);
        oracle.setPrice(USDT, 1e8, 8);
        oracle.setPrice(DAI, 1e8, 8);

        access.grantRole(Roles.ATOMIST_ROLE, atomist);

        // Fuses + pre-hook
        opFuse = new RWAOperationFuse(MARKET_ID);
        balFuse = new RWABalanceFuse(MARKET_ID);
        unpauseFuse = new RWAUnpauseFuse(MARKET_ID);
        rescueFuse = new RWARescueFuse(MARKET_ID);
        preHook = new RWAPausePreHook(MARKET_ID);

        // Default substrate set (per-test setUps extend as needed via _grantSubstrates(list))
        _grantDefaultSubstrates();

        // Labels improve forge traces
        vm.label(USDC, "USDC");
        vm.label(USDT, "USDT");
        vm.label(DAI, "DAI");
        vm.label(address(vault), "MockPlasmaVaultForRWA");
        vm.label(address(oracle), "MockPriceOracleMiddleware");
        vm.label(address(access), "MockAccessManager");
        vm.label(address(rwaProtocol), "MockRWAProtocolForFork");
        vm.label(address(opFuse), "RWAOperationFuse");
        vm.label(address(balFuse), "RWABalanceFuse");
        vm.label(address(unpauseFuse), "RWAUnpauseFuse");
        vm.label(address(rescueFuse), "RWARescueFuse");
        vm.label(address(preHook), "RWAPausePreHook");
        vm.label(atomist, "atomist");
        vm.label(alpha, "alpha");
        vm.label(custodianA, "custodianA");
        vm.label(custodianB, "custodianB");
        vm.label(balanceAccountA, "balanceAccountA");
        vm.label(balanceAccountB, "balanceAccountB");
        vm.label(user, "user");
    }

    // ============================================================
    // Substrate configuration
    // ============================================================

    /// @notice Default substrate set used by most tests. Child tests can re-grant via
    ///         `_grantSubstrates(list)` to change thresholds or replace accounts.
    function _grantDefaultSubstrates() internal {
        bytes32[] memory subs = new bytes32[](11);
        subs[0] = RWASubstrateLib.encodeAssetSubstrate(USDC);
        subs[1] = RWASubstrateLib.encodeAssetSubstrate(USDT);
        subs[2] = RWASubstrateLib.encodeBalanceAccountSubstrate(balanceAccountA);
        subs[3] = RWASubstrateLib.encodeBalanceAccountSubstrate(balanceAccountB);
        subs[4] = RWASubstrateLib.encodeCustodianSubstrate(custodianA);
        subs[5] = RWASubstrateLib.encodeCustodianSubstrate(custodianB);
        subs[6] = RWASubstrateLib.encodeTargetSubstrate(address(rwaProtocol), MockRWAProtocolForFork.deposit.selector);
        subs[7] = RWASubstrateLib.encodeStalenessMaxSubstrate(STALENESS_MAX_S);
        subs[8] = RWASubstrateLib.encodeBigChangeBpsSubstrate(BIG_CHANGE_BPS);
        subs[9] = RWASubstrateLib.encodeDustThresholdSubstrate(DUST_THRESHOLD);
        subs[10] = RWASubstrateLib.encodeMinUpdateIntervalSubstrate(MIN_UPDATE_INTERVAL_S);
        vault.grantMarketSubstrates(MARKET_ID, subs);
    }

    /// @notice Re-grant a custom substrate set (replaces the existing grants).
    function _grantSubstrates(bytes32[] memory subs_) internal {
        vault.grantMarketSubstrates(MARKET_ID, subs_);
    }

    // ============================================================
    // Executor helpers
    // ============================================================

    /// @notice Returns the executor address bound to the vault via ERC-7201. May be zero before
    ///         the first enter / createExecutor call.
    function _executorAddress() internal view returns (address) {
        bytes32 value = vm.load(address(vault), RWA_SLOT);
        return address(uint160(uint256(value)));
    }

    /// @notice Deploys the executor via a fuse createExecutor() call (idempotent).
    function _createExecutor() internal returns (address executor) {
        vault.delegateExecute(address(opFuse), abi.encodeCall(opFuse.createExecutor, ()));
        executor = _executorAddress();
        require(executor != address(0), "executor not deployed");
    }

    /// @notice Re-read substrate cache on the executor (e.g. after a new substrate grant).
    function _syncExecutorSubstrates() internal {
        address executor = _executorAddress();
        if (executor == address(0)) return;
        IRWAExecutor(executor).syncSubstrates();
    }

    // ============================================================
    // Enter / Exit wrappers (alpha-role semantics)
    // ============================================================

    function _enter(address asset_, uint256 amount_, address balanceAccount_) internal {
        RWAOperationFuseEnterData memory d = RWAOperationFuseEnterData({
            asset: asset_, amount: amount_, balanceAccount: balanceAccount_, actions: new RWAExecutorAction[](0)
        });
        vault.delegateExecute(address(opFuse), abi.encodeCall(opFuse.enter, (d)));
    }

    function _enter(address asset_, uint256 amount_, address balanceAccount_, RWAExecutorAction[] memory actions_)
        internal
    {
        RWAOperationFuseEnterData memory d = RWAOperationFuseEnterData({
            asset: asset_, amount: amount_, balanceAccount: balanceAccount_, actions: actions_
        });
        vault.delegateExecute(address(opFuse), abi.encodeCall(opFuse.enter, (d)));
    }

    function _exit(address asset_, uint256 amount_, address balanceAccount_) internal {
        RWAOperationFuseExitData memory d = RWAOperationFuseExitData({
            asset: asset_, amount: amount_, balanceAccount: balanceAccount_, actions: new RWAExecutorAction[](0)
        });
        vault.delegateExecute(address(opFuse), abi.encodeCall(opFuse.exit, (d)));
    }

    function _exit(address asset_, uint256 amount_, address balanceAccount_, RWAExecutorAction[] memory actions_)
        internal
    {
        RWAOperationFuseExitData memory d = RWAOperationFuseExitData({
            asset: asset_, amount: amount_, balanceAccount: balanceAccount_, actions: actions_
        });
        vault.delegateExecute(address(opFuse), abi.encodeCall(opFuse.exit, (d)));
    }

    /// @notice Call `RWABalanceFuse.balanceOf` on the vault and decode the returned USD WAD value.
    function _readBalanceOf() internal returns (uint256 value) {
        bytes memory ret = vault.delegateExecute(address(balFuse), abi.encodeCall(balFuse.balanceOf, ()));
        value = abi.decode(ret, (uint256));
    }

    // ============================================================
    // Custodian propose / confirm helpers
    // ============================================================

    /// @notice Proposes + confirms a balance update in one helper call. Uses `custodianA` as the
    ///         proposer and `custodianB` as the confirmer by default.
    function _custodianConfirm(address balanceAccount_, uint256 newValue_) internal {
        address executor = _executorAddress();
        require(executor != address(0), "executor not deployed");
        vm.prank(custodianA);
        IRWAExecutor(executor).proposeBalance(balanceAccount_, newValue_);
        (,, uint64 proposedAt, uint256 nonce) = RWAExecutor(executor).pendingProposals(balanceAccount_);
        bytes32 h = _proposalHash(executor, balanceAccount_, newValue_, custodianA, proposedAt, nonce);
        vm.prank(custodianB);
        IRWAExecutor(executor).confirmBalance(balanceAccount_, h);
    }

    /// @notice Explicit form used when tests want to pick the proposer / confirmer.
    function _custodianConfirm(address proposer_, address confirmer_, address balanceAccount_, uint256 newValue_)
        internal
    {
        address executor = _executorAddress();
        require(executor != address(0), "executor not deployed");
        vm.prank(proposer_);
        IRWAExecutor(executor).proposeBalance(balanceAccount_, newValue_);
        (,, uint64 proposedAt, uint256 nonce) = RWAExecutor(executor).pendingProposals(balanceAccount_);
        bytes32 h = _proposalHash(executor, balanceAccount_, newValue_, proposer_, proposedAt, nonce);
        vm.prank(confirmer_);
        IRWAExecutor(executor).confirmBalance(balanceAccount_, h);
    }

    /// @dev Mirror of RWAExecutor._proposalHash (H-1 binding: executor + chainid + balanceAccount).
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

    /// @notice Reads the RWA pause flag from vault storage.
    function _readPaused() internal view returns (bool) {
        return RWASlotHelpers.readPaused(address(vault));
    }

    /// @notice Forces the pause flag (useful when a test wants to skip the big-change trigger).
    function _forcePaused(bool value_) internal {
        RWASlotHelpers.setPaused(address(vault), value_);
    }

    /// @notice Builds a valid atomist-signed unpause payload (chain-id + vault-id + market-id bound).
    function _buildUnpauseData(uint256 confirmedBalance_, uint256 nonce_, uint256 expiration_)
        internal
        view
        returns (RWAUnpauseData memory data)
    {
        bytes32 digest = keccak256(
            abi.encodePacked(address(vault), MARKET_ID, confirmedBalance_, nonce_, expiration_, block.chainid)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(atomistPk, digest);
        data = RWAUnpauseData({
            confirmedTotalBalance: confirmedBalance_,
            nonce: nonce_,
            expirationTime: expiration_,
            signature: abi.encodePacked(r, s, v)
        });
    }
}

/// @notice Minimal RWA protocol for fork tests: records deposits without touching funds.
/// @dev Custodians settle balances off-chain; the protocol is a target that alpha can call. The
///      TARGET substrate is bound to `deposit(address,uint256)` in the default setup.
contract MockRWAProtocolForFork {
    /// @notice Emitted when `deposit` is invoked from the executor.
    event RWAMockDeposit(address asset, uint256 amount, address caller);

    uint256 public totalDeposits;

    function deposit(address asset_, uint256 amount_) external {
        totalDeposits += amount_;
        emit RWAMockDeposit(asset_, amount_, msg.sender);
    }
}

