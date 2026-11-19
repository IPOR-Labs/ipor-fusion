// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {CrosschainNavValidationPreHook} from "contracts/handlers/pre_hooks/pre_hooks/CrosschainNavValidationPreHook.sol";
import {CrosschainSubstrateLib} from "contracts/fuses/crosschain/lib/CrosschainSubstrateLib.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {IPlasmaVault} from "contracts/interfaces/IPlasmaVault.sol";
import {CcipCrosschainExecutor} from "contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";
import {MockExecutor} from "./mocks/MockExecutor.sol";
import {CrosschainWatchedVaultHarness} from "./mocks/CrosschainWatchedVaultHarness.sol";
import {CcipBandToken} from "./CcipLeveragedLegBandRegressionTest.t.sol";
import {EmptyReturnMock} from "./CrosschainNavHealthMalformedReturnTest.t.sol";

/// @dev A contract with no vault getters at all: every call reverts.
contract NoGettersMock {
    fallback() external {
        revert("no getters");
    }
}

/// @dev A contract that answers `getMarketSubstrates` with an empty list (it is not a vault, and it is "healthy").
contract EmptySubstratesMock {
    function getMarketSubstrates(uint256) external pure returns (bytes32[] memory list_) {
        list_ = new bytes32[](0);
    }
}

/// @title CrosschainNavWatchedVaultsBase
/// @notice IL-9720 (3sigma #26, part 3): `CrosschainNavValidationPreHook` gates a vault that holds shares of a CROSSCHAIN
///         vault on the watched vaults listed as pre-hook substrates of the called selector. Shared fixture: the hook, a
///         holder vault (no executor of its own unless a test grants one) and helpers to store the list and to compare
///         `run` with a direct `isNavHealthy` probe.
abstract contract CrosschainNavWatchedVaultsBase is Test {
    uint256 internal constant MARKET = 41;
    bytes4 internal constant DEPOSIT = bytes4(keccak256("deposit(uint256,address)"));
    bytes4 internal constant REDEEM = bytes4(keccak256("redeem(uint256,address,address)"));

    CrosschainNavValidationPreHook internal hook;
    CrosschainWatchedVaultHarness internal holder;

    function _baseSetUp() internal {
        hook = new CrosschainNavValidationPreHook(MARKET);
        holder = new CrosschainWatchedVaultHarness(address(0xA55E7));
    }

    function _entry(address vault_) internal pure returns (bytes32) {
        return PlasmaVaultConfigLib.addressToBytes32(vault_);
    }

    function _list1(address a_) internal pure returns (bytes32[] memory l_) {
        l_ = new bytes32[](1);
        l_[0] = _entry(a_);
    }

    function _list2(address a_, address b_) internal pure returns (bytes32[] memory l_) {
        l_ = new bytes32[](2);
        l_[0] = _entry(a_);
        l_[1] = _entry(b_);
    }

    function _setList(bytes4 selector_, bytes32[] memory list_) internal {
        holder.setPreHookSubstrates(address(hook), selector_, list_);
    }

    function _grantExecutor(CrosschainWatchedVaultHarness vault_, address executor_) internal {
        bytes32[] memory subs = new bytes32[](1);
        subs[0] = CrosschainSubstrateLib.executorSubstrate(executor_);
        vault_.grantSubstrates(MARKET, subs);
    }

    function _run(bytes4 selector_) internal returns (bool ok_, bytes memory ret_) {
        (ok_, ret_) = address(holder).call(abi.encodeCall(holder.runPreHook, (address(hook), selector_)));
    }

    function _unhealthyError(address vault_) internal pure returns (bytes memory) {
        return
            abi.encodeWithSelector(
                CrosschainNavValidationPreHook.CrosschainNavValidationPreHookWatchedVaultUnhealthy.selector,
                vault_
            );
    }

    /// @dev `run` on the watched list `[vault_]` must agree with a direct `hook.isNavHealthy(vault_)`: true -> passes,
    ///      false -> `WatchedVaultUnhealthy(vault_)`, revert -> `run` reverts (with the probe's data when it has any).
    function _assertRunMatchesProbe(address vault_, bytes4 selector_) internal {
        (bool pOk, bytes memory pRet) = address(hook).staticcall(abi.encodeCall(hook.isNavHealthy, (vault_)));
        _setList(selector_, _list1(vault_));
        (bool rOk, bytes memory rRet) = _run(selector_);
        if (!pOk) {
            assertFalse(rOk, "probe reverts -> run reverts");
            if (pRet.length > 0) assertEq(rRet, pRet, "run bubbles the probe's revert data");
        } else if (abi.decode(pRet, (bool))) {
            assertTrue(rOk, "probe true -> run passes");
        } else {
            assertFalse(rOk, "probe false -> run reverts");
            assertEq(rRet, _unhealthyError(vault_), "probe false -> WatchedVaultUnhealthy(vault)");
        }
    }
}

/// @title CrosschainNavWatchedVaultsTest
/// @notice Matrix on the harness with mock executors (the executor states themselves are covered on real executors in
///         `CrosschainNavWatchedVaultsCcipTest`).
contract CrosschainNavWatchedVaultsTest is CrosschainNavWatchedVaultsBase {
    CrosschainWatchedVaultHarness internal watchedA;
    CrosschainWatchedVaultHarness internal watchedB;
    MockExecutor internal executorA;
    MockExecutor internal executorB;

    function setUp() public {
        _baseSetUp();
        watchedA = new CrosschainWatchedVaultHarness(address(0xA55E7));
        watchedB = new CrosschainWatchedVaultHarness(address(0xA55E7));
        executorA = new MockExecutor(address(watchedA), address(0xA55E7));
        executorB = new MockExecutor(address(watchedB), address(0xA55E7));
        _grantExecutor(watchedA, address(executorA));
        _grantExecutor(watchedB, address(executorB));
    }

    // 1. empty list: as on the base ------------------------------------------------------------------------------

    function testShouldPassWithAnEmptyListAndNoOwnExecutor() public {
        (bool ok, ) = _run(DEPOSIT);
        assertTrue(ok, "no own executor, no list: the hook is a no-op");
    }

    function testShouldKeepGatingOwnExecutorsWithAnEmptyList() public {
        MockExecutor own = new MockExecutor(address(holder), address(0xA55E7));
        _grantExecutor(holder, address(own));
        (bool ok, ) = _run(DEPOSIT);
        assertTrue(ok, "own executor fresh");
        own.setBalanceReverts(true);
        (ok, ) = _run(DEPOSIT);
        assertFalse(ok, "own executor fail-closed: reverts as on the base");
    }

    // 2. watched vault passes / fails -----------------------------------------------------------------------------

    function testShouldPassWhenTheWatchedVaultPasses() public {
        _setList(DEPOSIT, _list1(address(watchedA)));
        (bool ok, ) = _run(DEPOSIT);
        assertTrue(ok);
    }

    function testShouldRevertWithTheWatchedVaultWhenItsExecutorFailsClosed() public {
        executorA.setBalanceReverts(true);
        _setList(DEPOSIT, _list1(address(watchedA)));
        (bool ok, bytes memory ret) = _run(DEPOSIT);
        assertFalse(ok);
        assertEq(ret, _unhealthyError(address(watchedA)));
    }

    // 4. wrong addresses --------------------------------------------------------------------------------------------

    function testShouldRevertForAZeroEntryAnEoaAndAContractWithoutGetters() public {
        _assertRunMatchesProbe(address(0), DEPOSIT);
        _assertRunMatchesProbe(address(0xE0A), DEPOSIT);
        _assertRunMatchesProbe(address(new NoGettersMock()), DEPOSIT);
        (bool ok, bytes memory ret) = _run(DEPOSIT);
        assertFalse(ok);
        assertEq(ret.length > 0, true, "reverts with the hook's error");
    }

    function testShouldRevertWithTheErrorOfTheHookForAZeroEntry() public {
        _setList(DEPOSIT, _list1(address(0)));
        (bool ok, bytes memory ret) = _run(DEPOSIT);
        assertFalse(ok);
        assertEq(ret, _unhealthyError(address(0)));
    }

    function testShouldRevertWhenTheWatchedContractReturnsMalformedData() public {
        address malformed = address(new EmptyReturnMock());
        _assertRunMatchesProbe(malformed, DEPOSIT);
        (bool ok, ) = _run(DEPOSIT);
        assertFalse(ok, "a malformed read reverts `run` (IL-9118), it is not read as healthy");
    }

    // 5. encoding and the predicate's limits ------------------------------------------------------------------------

    function testShouldIgnoreTheUpperBitsOfAnEntryWithACorrectAddress() public {
        bytes32[] memory dirty = new bytes32[](1);
        dirty[0] = bytes32(uint256(uint160(address(watchedA))) | (uint256(0xDEAD) << 200));
        _setList(DEPOSIT, dirty);
        (bool ok, ) = _run(DEPOSIT);
        assertTrue(ok, "the entry is truncated to its address (known limit)");
        executorA.setBalanceReverts(true);
        (bool ok2, bytes memory ret) = _run(DEPOSIT);
        assertFalse(ok2);
        assertEq(ret, _unhealthyError(address(watchedA)), "and the truncated address is what is reported");
    }

    function testShouldTreatAContractReturningNoSubstratesAsHealthy() public {
        _assertRunMatchesProbe(address(new EmptySubstratesMock()), DEPOSIT);
        (bool ok, ) = _run(DEPOSIT);
        assertTrue(ok, "any contract with an empty substrate list is healthy (known limit)");
    }

    function testShouldTreatAVaultWithoutAnExecutorSubstrateAsHealthy() public {
        CrosschainWatchedVaultHarness bare = new CrosschainWatchedVaultHarness(address(0xA55E7));
        _assertRunMatchesProbe(address(bare), DEPOSIT);
        (bool ok, ) = _run(DEPOSIT);
        assertTrue(ok, "a vault without an EXECUTOR substrate is healthy (known limit)");
    }

    function testShouldRevertWhenTheExecutorOfTheWatchedVaultHasAForeignManager() public {
        executorA.setManager(address(0xBEEF));
        _assertRunMatchesProbe(address(watchedA), DEPOSIT);
        (bool ok, bytes memory ret) = _run(DEPOSIT);
        assertFalse(ok);
        assertEq(ret, _unhealthyError(address(watchedA)));
    }

    // 6. order ------------------------------------------------------------------------------------------------------

    function testShouldReportTheSecondVaultWhenOnlyTheSecondIsUnhealthy() public {
        executorB.setBalanceReverts(true);
        _setList(DEPOSIT, _list2(address(watchedA), address(watchedB)));
        (bool ok, bytes memory ret) = _run(DEPOSIT);
        assertFalse(ok);
        assertEq(ret, _unhealthyError(address(watchedB)), "the first unhealthy vault in list order");
    }

    function testShouldReportTheFirstVaultWhenBothAreUnhealthy() public {
        executorA.setBalanceReverts(true);
        executorB.setBalanceReverts(true);
        _setList(DEPOSIT, _list2(address(watchedB), address(watchedA)));
        (bool ok, bytes memory ret) = _run(DEPOSIT);
        assertFalse(ok);
        assertEq(ret, _unhealthyError(address(watchedB)));
    }

    function testShouldCheckOwnExecutorsBeforeTheList() public {
        MockExecutor own = new MockExecutor(address(holder), address(0xA55E7));
        _grantExecutor(holder, address(own));
        own.setBalanceReverts(true);
        executorA.setBalanceReverts(true);
        _setList(DEPOSIT, _list1(address(watchedA)));
        // the own executor's revert (MockExecutor's `NavSettledStale`) surfaces, not the watched vault's error
        vm.expectRevert(abi.encodeWithSelector(MockExecutor.NavSettledStale.selector, uint256(1)));
        holder.runPreHook(address(hook), DEPOSIT);
    }

    // 7. execute and updateMarketsBalances ----------------------------------------------------------------------------

    function testShouldNotReadTheListForExecuteAndUpdateMarketsBalances() public {
        executorA.setBalanceReverts(true);
        _setList(IPlasmaVault.execute.selector, _list1(address(watchedA)));
        _setList(IPlasmaVault.updateMarketsBalances.selector, _list1(address(watchedA)));
        (bool ok, ) = _run(IPlasmaVault.execute.selector);
        assertTrue(ok, "execute passes");
        (ok, ) = _run(IPlasmaVault.updateMarketsBalances.selector);
        assertTrue(ok, "updateMarketsBalances passes");
        _setList(DEPOSIT, _list1(address(watchedA)));
        (ok, ) = _run(DEPOSIT);
        assertFalse(ok, "control: the same list closes deposit");
    }

    // 8. per-selector list and implementation swap -----------------------------------------------------------------

    function testShouldLetASelectorWithoutAListThrough() public {
        executorA.setBalanceReverts(true);
        _setList(DEPOSIT, _list1(address(watchedA)));
        (bool ok, ) = _run(DEPOSIT);
        assertFalse(ok);
        (ok, ) = _run(REDEEM);
        assertTrue(ok, "redeem has no list (known limit)");
    }

    function testShouldIgnoreTheListOfAnotherImplementation() public {
        executorA.setBalanceReverts(true);
        _setList(DEPOSIT, _list1(address(watchedA)));
        CrosschainNavValidationPreHook other = new CrosschainNavValidationPreHook(MARKET);
        // the substrates are keyed by (implementation, selector): a new implementation starts with no list (known limit)
        holder.runPreHook(address(other), DEPOSIT);
        vm.expectRevert(_unhealthyError(address(watchedA)));
        holder.runPreHook(address(hook), DEPOSIT);
    }

    // 9. equivalence with the probe ---------------------------------------------------------------------------------

    function testShouldMatchTheProbeInEveryState() public {
        _assertRunMatchesProbe(address(watchedA), DEPOSIT); // healthy
        executorA.setBalanceReverts(true);
        _assertRunMatchesProbe(address(watchedA), DEPOSIT); // fail-closed
        executorA.setBalanceReverts(false);
        executorA.setManager(address(0xBEEF));
        _assertRunMatchesProbe(address(watchedA), DEPOSIT); // foreign manager
        _assertRunMatchesProbe(address(0), DEPOSIT);
        _assertRunMatchesProbe(address(0xE0A), DEPOSIT);
        _assertRunMatchesProbe(address(new NoGettersMock()), DEPOSIT);
        _assertRunMatchesProbe(address(new EmptyReturnMock()), DEPOSIT);
        _assertRunMatchesProbe(address(new EmptySubstratesMock()), DEPOSIT);
    }

    function testShouldExposeTheImplementationAddressAsVersion() public view {
        assertEq(hook.VERSION(), address(hook));
        assertEq(hook.MARKET_ID(), MARKET);
    }
}

/// @title CrosschainNavWatchedVaultsCcipTest
/// @notice The hook against REAL CCIP executors managed by a watched vault: the states in which `getBalance()` passes or
///         reverts (a blocked chain that tracks value, a stale attestation, a stale in-flight record, a blocked chain with
///         nothing tracked), and, together with part 2, an attested value above the band that blocks the chain and closes
///         the holder.
contract CrosschainNavWatchedVaultsCcipTest is CrosschainNavWatchedVaultsBase {
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;
    address internal constant APPROVER = address(0xA33);

    MockCcipRouter internal router;
    CcipBandToken internal token;
    CrosschainWatchedVaultHarness internal watched;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;

    function setUp() public {
        _baseSetUp();
        router = new MockCcipRouter();
        token = new CcipBandToken();
        MockCcipRouteValidator routeValidator = new MockCcipRouteValidator();
        address factory = address(routeValidator);
        watched = new CrosschainWatchedVaultHarness(address(token));
        executor = new CcipCrosschainExecutor(
            address(router),
            factory,
            address(watched), // MANAGER: the watched vault
            address(token),
            keccak256("USDC"),
            18,
            CcipCrosschainExecutor.SafetyConfig({
                rescueAdmin: address(0xA11),
                rescueGuardian: address(0xB22),
                balanceProposer: address(this),
                balanceApprover: APPROVER,
                rescueDelay: 3 days,
                balanceStalenessMax: 7 days,
                bigChangeBps: 2_000,
                anchorBandBps: 2_000,
                minUpdateInterval: 1 hours,
                transferStalenessMax: 1 days
            })
        );
        CcipRouteConfig memory back = CcipRouteConfig({
            chainSelector: EXECUTOR_SELECTOR,
            peer: address(executor),
            feeToken: address(0),
            messageGasLimit: 500_000,
            tokenGasLimit: 500_000,
            maxFee: 0,
            enabled: true
        });
        dispatcher = new CcipCrosschainDispatcher(
            address(router),
            factory,
            address(token),
            keccak256("USDC"),
            18,
            block.chainid,
            back,
            address(0xA11),
            address(0xB22),
            3 days
        );
        vm.prank(factory);
        dispatcher.configureVaults(new address[](0), true);
        CcipRouteConfig memory executorRoute = CcipRouteConfig({
            chainSelector: DISPATCHER_SELECTOR,
            peer: address(dispatcher),
            feeToken: address(0),
            messageGasLimit: 500_000,
            tokenGasLimit: 500_000,
            maxFee: 0,
            enabled: true
        });
        routeValidator.setRoute(REMOTE_CHAIN, executorRoute);
        routeValidator.registerExecutorRoute(address(executor), REMOTE_CHAIN, executorRoute);
        router.setSelector(address(executor), EXECUTOR_SELECTOR);
        router.setSelector(address(dispatcher), DISPATCHER_SELECTOR);
        vm.prank(factory);
        executor.markDispatcherReady(REMOTE_CHAIN);
        _grantExecutor(watched, address(executor));
        _setList(DEPOSIT, _list1(address(watched)));
    }

    function _bridge(uint256 amount_) internal {
        token.mint(address(executor), amount_);
        vm.prank(address(watched));
        executor.sendAssetToDispatcher(REMOTE_CHAIN, amount_, 0, address(0), 500_000);
    }

    function _propose(uint256 balance_) internal returns (uint256 proposalId) {
        vm.warp(block.timestamp + 1);
        proposalId = executor.proposeBalance(
            REMOTE_CHAIN,
            balance_,
            executor.lastRemoteStateVersion(REMOTE_CHAIN),
            uint64(block.number == 0 ? 1 : block.number),
            uint64(block.timestamp),
            uint64(block.timestamp + 1 days),
            dispatcher.trackedPositionSetHash()
        );
    }

    function _attest(uint256 balance_) internal {
        vm.warp(block.timestamp + 1 hours);
        uint256 proposalId = _propose(balance_);
        vm.prank(APPROVER);
        executor.approveBalance(proposalId);
    }

    function _block() internal {
        vm.warp(block.timestamp + 1 hours);
        uint256 proposalId = _propose(executor.settledRemoteBalance(REMOTE_CHAIN));
        vm.prank(APPROVER);
        executor.rejectBalanceAndBlock(proposalId);
        assertTrue(executor.chainBlocked(REMOTE_CHAIN));
    }

    /// @dev `run` of the holder agrees with the probe, and the expected verdict holds.
    function _expect(bool healthy_) internal {
        assertEq(hook.isNavHealthy(address(watched)), healthy_, "probe");
        _assertRunMatchesProbe(address(watched), DEPOSIT);
        (bool ok, bytes memory ret) = _run(DEPOSIT);
        assertEq(ok, healthy_, "run");
        if (!healthy_) assertEq(ret, _unhealthyError(address(watched)));
    }

    function testShouldPassForAFreshAttestedExecutor() public {
        _bridge(100e18);
        _attest(100e18);
        _expect(true);
    }

    function testShouldCloseOnABlockedChainThatTracksValue() public {
        _bridge(100e18);
        _attest(100e18);
        _block();
        _expect(false);
    }

    function testShouldCloseOnAStaleAttestationWithSettledValue() public {
        _bridge(100e18);
        _attest(100e18);
        vm.warp(block.timestamp + 8 days);
        _expect(false);
    }

    function testShouldCloseOnAStaleInFlightRecord() public {
        router.setAutoDeliver(false);
        _bridge(10e18);
        vm.warp(block.timestamp + 2 days);
        _expect(false);
    }

    function testShouldPassForABlockedChainWithNothingTracked() public {
        _block(); // propose 0 and block: settled 0, nothing in flight
        _expect(true);
    }

    function testShouldPassForAnExecutorNeverAttestedWithZeroSettled() public {
        _expect(true);
        vm.warp(block.timestamp + 30 days);
        _expect(true);
    }

    function testShouldCloseAgainWhenValueIsBookedOnABlockedChain() public {
        _block();
        _expect(true);
        _bridge(10e18);
        _expect(false);
    }

    /// @dev Parts 2 and 3 together: the attester pair approves a value above the band, the chain is blocked, the watched
    ///      vault stops answering `isNavHealthy` and the holder's gated selector is closed.
    function testShouldCloseTheHolderWhenAnAboveBandApprovalBlocksTheChain() public {
        _bridge(100e18);
        _attest(100e18);
        _expect(true);
        _attest(300e18); // far above the band (anchor 100, band 2_000): blocks the chain instead of reverting
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "part 2: the chain is blocked");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e18, "nothing was written");
        _expect(false);
    }
}
