// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test, stdStorage, StdStorage} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipAppBase} from "../../contracts/crosschain/ccip/base/CcipAppBase.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {CcipClient} from "../../contracts/crosschain/ccip/interfaces/CcipClient.sol";
import {CcipMessages, CcipMsgType} from "../../contracts/crosschain/ccip/lib/CcipMessages.sol";
import {
    BusinessAction,
    CommandStatus,
    CommandResolution,
    CrosschainConstants
} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {Command, CrosschainMessages} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {
    MockRemoteVault,
    MockRemotePlasmaVault,
    MockPermissiveAuthority,
    MockWithdrawManager
} from "./mocks/MockRemoteVault.sol";
import {MockLegacyRemotePlasmaVault} from "./mocks/MockLegacyRemotePlasmaVault.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";
import {CcipExecutorAttestationLib} from "../../contracts/crosschain/ccip/lib/CcipExecutorAttestationLib.sol";
import {CcipExecutorTransferLib} from "../../contracts/crosschain/ccip/lib/CcipExecutorTransferLib.sol";
import {CcipDispatcherLib} from "../../contracts/crosschain/ccip/lib/CcipDispatcherLib.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";

contract CcipToken is ERC20 {
    constructor() ERC20("CCIP USDC", "cUSDC") {}

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }

    function burn(address from_, uint256 amount_) external {
        _burn(from_, amount_);
    }
}

contract CcipLifecycleTest is Test {
    using stdStorage for StdStorage;

    // Mirrors of the dispatcher events (IL-8482), redeclared for `vm.expectEmit`.
    event SharesRequested(address vault, uint256 pendingShares, uint256 feeShares);
    event RedeemedFromRequest(address vault, uint256 sharesRedeemed, uint256 assetsDeltaSD);

    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;

    bytes32 internal constant ASSET_SENT_TOPIC = keccak256("AssetSent(uint256,bytes32,bytes32,uint256)");

    MockCcipRouter internal router;
    CcipToken internal token;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;
    address internal factory;

    function setUp() public {
        router = new MockCcipRouter();
        token = new CcipToken();
        MockCcipRouteValidator routeValidator = new MockCcipRouteValidator();
        factory = address(routeValidator);
        executor = new CcipCrosschainExecutor(
            address(router),
            factory,
            address(this),
            address(token),
            keccak256("USDC"),
            18,
            _safety()
        );
        CcipRouteConfig memory back = CcipRouteConfig({
            chainSelector: EXECUTOR_SELECTOR,
            peer: address(executor),
            feeToken: address(0),
            messageGasLimit: 2_000_000,
            tokenGasLimit: 2_000_000,
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
            messageGasLimit: 2_000_000,
            tokenGasLimit: 2_000_000,
            maxFee: 0,
            enabled: true
        });
        routeValidator.setRoute(REMOTE_CHAIN, executorRoute);
        routeValidator.registerExecutorRoute(address(executor), REMOTE_CHAIN, executorRoute);
        router.setSelector(address(executor), EXECUTOR_SELECTOR);
        router.setSelector(address(dispatcher), DISPATCHER_SELECTOR);
        vm.prank(factory);
        executor.markDispatcherReady(REMOTE_CHAIN);
    }

    function _safety() private view returns (CcipCrosschainExecutor.SafetyConfig memory) {
        return
            CcipCrosschainExecutor.SafetyConfig({
                rescueAdmin: address(0xA11),
                rescueGuardian: address(0xB22),
                balanceProposer: address(this),
                balanceApprover: address(0xA33),
                rescueDelay: 3 days,
                balanceStalenessMax: 7 days,
                bigChangeBps: 2_000, // == ATTESTATION_ANCHOR_BAND_BPS, the constructor ceiling (IL-8058)
                minUpdateInterval: 1 hours,
                transferStalenessMax: 1 days
            });
    }

    /// @dev `CcipDispatcherLib.configureVaults` enforces the tracked-vault cap with its own copy of the constant.
    function testShouldKeepLibraryTrackedVaultCapEqualToDispatcherCap() public view {
        assertEq(CcipDispatcherLib.MAX_TRACKED_VAULTS, dispatcher.MAX_TRACKED_VAULTS(), "tracked-vault cap");
    }

    function testShouldSendSettleRecallAndClaim() public {
        token.mint(address(executor), 100e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e18, 0, address(0), 2_000_000);
        _attestBalance(100e18);
        assertEq(executor.outboundInFlight(REMOTE_CHAIN), 0);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e18);
        assertEq(dispatcher.trackedIdle(), 100e18);
        assertEq(executor.getBalance(), 100e18);

        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 60e18, 60e18, 0, address(0), 2_000_000);
        assertEq(executor.idleLedger(), 60e18);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 40e18);
        assertEq(dispatcher.trackedIdle(), 40e18);
        assertEq(executor.getBalance(), 100e18);

        uint256 before = token.balanceOf(address(this));
        executor.claimAsset(type(uint256).max);
        assertEq(token.balanceOf(address(this)) - before, 60e18);
        assertEq(executor.getBalance(), 40e18);
    }

    event AssetClaimed(address manager, uint256 amount);

    function _recallToIdle60() private {
        token.mint(address(executor), 100e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e18, 0, address(0), 2_000_000);
        _attestBalance(100e18);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 60e18, 60e18, 0, address(0), 2_000_000);
        assertEq(executor.idleLedger(), 60e18);
    }

    function testShouldEmitAssetClaimedOnClaim() public {
        _recallToIdle60();
        uint256 before = token.balanceOf(address(this));

        vm.expectEmit(address(executor));
        emit AssetClaimed(address(this), 60e18);
        executor.claimAsset(60e18);

        assertEq(executor.idleLedger(), 0);
        assertEq(token.balanceOf(address(this)) - before, 60e18);
    }

    function testShouldEmitCappedAmountWhenClaimExceedsIdle() public {
        _recallToIdle60();
        uint256 before = token.balanceOf(address(this));

        vm.expectEmit(address(executor));
        emit AssetClaimed(address(this), 60e18);
        executor.claimAsset(1000e18);

        assertEq(executor.idleLedger(), 0);
        assertEq(token.balanceOf(address(this)) - before, 60e18);
    }

    function testShouldEmitAssetClaimedForZeroClaim() public {
        _recallToIdle60();

        vm.expectEmit(address(executor));
        emit AssetClaimed(address(this), 0);
        executor.claimAsset(0);

        assertEq(executor.idleLedger(), 60e18);
    }

    function testShouldRejectZeroAccountedRecallLocally() public {
        vm.expectRevert(abi.encodeWithSelector(CcipCrosschainExecutor.ZeroAccountedReturn.selector, REMOTE_CHAIN));
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 1e18, 0, 0, address(0), 2_000_000);
    }

    function testPendingRecallShouldNotPreDebitOrDoubleCountNav() public {
        _fundRemoteIdle(100e18);
        router.setAutoDeliver(false);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 60e18, 60e18, 0, address(0), 2_000_000);

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e18, "settled remains remote-owned");
        assertEq(executor.getBalance(), 100e18, "pending request counted exactly once");
        bytes memory expected = CcipClient.argsToBytes(
            CcipClient.GenericExtraArgsV2({gasLimit: 2_000_000, allowOutOfOrderExecution: true})
        );
        assertEq(router.lastExtraArgs(), expected, "executor requests remain independent/out-of-order");
    }

    function testShouldAllowOnlyOneActiveRecallPerChain() public {
        _fundRemoteIdle(100e18);
        router.setAutoDeliver(false);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 60e18, 60e18, 0, address(0), 2_000_000);
        bytes32 active = executor.activeReturn(REMOTE_CHAIN);

        vm.expectRevert(
            abi.encodeWithSelector(CcipCrosschainExecutor.ActiveReturnExists.selector, REMOTE_CHAIN, active)
        );
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 20e18, 20e18, 0, address(0), 2_000_000);
    }

    function testZeroIdleShouldReturnTerminalRejection() public {
        MockRemoteVault vault = _deployAndAllowVault();
        _fundRemoteIdle(100e18);
        _sendDeposit(vault, 100e18, keccak256("deposit-zero-idle"));

        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 60e18, 60e18, 0, address(0), 2_000_000);

        assertEq(executor.activeReturn(REMOTE_CHAIN), bytes32(0), "rejection reopens recall slot");
        assertEq(executor.getBalance(), 100e18, "remote position remains counted");
    }

    function testBelowMinimumShouldReturnTerminalRejection() public {
        MockRemoteVault vault = _deployAndAllowVault();
        _fundRemoteIdle(100e18);
        _sendDeposit(vault, 60e18, keccak256("deposit-partial-idle"));

        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 80e18, 70e18, 0, address(0), 2_000_000);

        assertEq(dispatcher.trackedIdle(), 40e18, "rejected recall moves no remote value");
        assertEq(executor.activeReturn(REMOTE_CHAIN), bytes32(0), "minimum rejection reopens slot");
        assertEq(executor.getBalance(), 100e18, "remote idle and position remain counted");
    }

    function testStaleRecallCanBePermissionlesslyCancelledAndLateReturnIsSafe() public {
        _fundRemoteIdle(100e18);
        router.setAutoDeliver(false);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 60e18, 60e18, 0, address(0), 2_000_000);
        bytes32 oldOperation = executor.activeReturn(REMOTE_CHAIN);
        uint256 requestedAt = block.timestamp;

        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(
            abi.encodeWithSelector(CcipExecutorTransferLib.TransferStale.selector, REMOTE_CHAIN, requestedAt)
        );
        executor.getBalance();
        executor.cancelStalePendingReturn(REMOTE_CHAIN);
        // IL-8590: the cancel carries the recall's clock over, so NAV stays fail-closed until the return lands.
        vm.expectRevert(
            abi.encodeWithSelector(CcipExecutorTransferLib.TransferStale.selector, REMOTE_CHAIN, requestedAt)
        );
        executor.getBalance();

        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 40e18, 40e18, 0, address(0), 2_000_000);
        bytes32 newOperation = executor.activeReturn(REMOTE_CHAIN);

        vm.prank(address(dispatcher));
        token.transfer(address(executor), 60e18);
        CcipClient.EVMTokenAmount[] memory delivered = new CcipClient.EVMTokenAmount[](1);
        delivered[0] = CcipClient.EVMTokenAmount({token: address(token), amount: 60e18});
        vm.prank(address(router));
        executor.ccipReceive(
            CcipClient.Any2EVMMessage({
                messageId: keccak256("late-return"),
                sourceChainSelector: DISPATCHER_SELECTOR,
                sender: abi.encode(address(dispatcher)),
                data: CcipMessages.encode(
                    CcipMsgType.RETURN_TRANSFER,
                    abi.encode(oldOperation, 60e18, 40e18, uint64(2))
                ),
                destTokenAmounts: delivered
            })
        );

        assertEq(executor.activeReturn(REMOTE_CHAIN), newOperation, "late old return cannot clear newer recall");
        assertEq(executor.idleLedger(), 60e18, "late authenticated tokens credited");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 40e18, "post-debit remote balance applied");
        assertEq(executor.getBalance(), 100e18, "late return preserves total NAV");
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 0, "late return resolved the cancelled recall");
    }

    event ReturnFinalized(uint256 chainId, bytes32 operationId, uint256 sentSD, uint256 received, uint256 debitedSD);
    event LateReturnFinalized(
        uint256 chainId,
        bytes32 operationId,
        uint256 sentSD,
        uint256 received,
        uint256 debitedSD
    );
    event ReturnDebitExceededAccountingBound(uint256 chainId, bytes32 operationId, uint256 sentSD, uint256 bound);

    /// @dev Hand-delivers the `RETURN_TRANSFER` of the active recall: the dispatcher declares `sentSD_` while
    ///      only `receivedLD_` reaches the executor (the transport fee is the difference), which the
    ///      synchronous mock router cannot simulate (IL-8497). The caller mints the received tokens to the
    ///      executor first, so an `expectEmit` set afterwards sees the executor's event first.
    function _deliverReturnWithFee(
        bytes32 operationId_,
        uint256 sentSD_,
        uint256 receivedLD_,
        uint256 remoteBalance_
    ) private {
        CcipClient.EVMTokenAmount[] memory delivered = new CcipClient.EVMTokenAmount[](1);
        delivered[0] = CcipClient.EVMTokenAmount({token: address(token), amount: receivedLD_});
        uint64 nextVersion = executor.lastRemoteStateVersion(REMOTE_CHAIN) + 1;
        vm.prank(address(router));
        executor.ccipReceive(
            CcipClient.Any2EVMMessage({
                messageId: keccak256(abi.encode("fee-return", operationId_)),
                sourceChainSelector: DISPATCHER_SELECTOR,
                sender: abi.encode(address(dispatcher)),
                data: CcipMessages.encode(
                    CcipMsgType.RETURN_TRANSFER,
                    abi.encode(operationId_, sentSD_, remoteBalance_, nextVersion)
                ),
                destTokenAmounts: delivered
            })
        );
    }

    /// @notice IL-8497: a full recall over a lane that takes a transfer fee debits `settled` by the declared
    ///         sent amount, so nothing is left behind and the bucket can be re-marked to zero. Before the fix
    ///         `settled` kept the fee (100 - 99.9) and the zero re-mark reverted `BigChangeExceeded`.
    function testShouldDebitSettledBySentAmountOnFullRecallWithFee() public {
        _fundRemoteIdle(100e18);
        router.setAutoDeliver(false);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 100e18, 100e18, 0, address(0), 2_000_000);
        bytes32 operationId = executor.activeReturn(REMOTE_CHAIN);

        token.mint(address(executor), 99.9e18);
        vm.expectEmit(address(executor));
        emit ReturnFinalized(REMOTE_CHAIN, operationId, 100e18, 99.9e18, 100e18);
        _deliverReturnWithFee(operationId, 100e18, 99.9e18, 0);

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "sent amount debited: no fee left in settled");
        assertEq(executor.idleLedger(), 99.9e18, "idle credited with the received amount");
        assertEq(executor.getBalanceByChain(REMOTE_CHAIN), 0, "no phantom remote value");
        assertEq(executor.getBalance(), 99.9e18, "NAV is the idle only");

        // The zero bucket re-marks and never goes stale.
        vm.warp(block.timestamp + 2 hours);
        _attestBalance(0);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0);
        vm.warp(block.timestamp + 8 days);
        assertEq(executor.getBalanceByChain(REMOTE_CHAIN), 0, "zero bucket does not fail closed");
        assertEq(executor.getBalance(), 99.9e18);
    }

    event AttestationAnchorUpdated(uint256 chainId, uint256 principalSD);

    /// @dev Fully recalls 100e18 with a declared sent amount `dust_` short of the settled value (remote
    ///      redeem rounding), leaving settled == `dust_` while the dispatcher reports 0 (IL-8499).
    function _fullRecallLeavingDust(uint256 dust_) private {
        _fundRemoteIdle(100e18);
        router.setAutoDeliver(false);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 100e18, 100e18, 0, address(0), 2_000_000);
        bytes32 operationId = executor.activeReturn(REMOTE_CHAIN);
        uint256 sent = 100e18 - dust_;
        token.mint(address(executor), sent);
        _deliverReturnWithFee(operationId, sent, sent, 0);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), dust_, "recall left the dust behind");
    }

    /// @notice IL-8499 (IL-8424 #6): dust left by a full recall is attestable to exactly zero, which resets
    ///         the anchor, and NAV stays live afterwards. Before the fix the 1 -> 0 attestation reverted
    ///         `BigChangeExceeded` and only the timelocked force-set could clear it.
    function testShouldAttestRecallDustToZeroAndKeepNavLive() public {
        _fullRecallLeavingDust(1);

        vm.warp(block.timestamp + 1 hours);
        vm.warp(block.timestamp + 1); // observation must postdate the last value-moving receipt
        uint256 proposalId = executor.proposeBalance(
            REMOTE_CHAIN,
            0,
            executor.lastRemoteStateVersion(REMOTE_CHAIN),
            uint64(block.number),
            uint64(block.timestamp),
            uint64(block.timestamp + 1 days),
            dispatcher.trackedPositionSetHash()
        );
        vm.expectEmit(address(executor));
        emit AttestationAnchorUpdated(REMOTE_CHAIN, 0);
        vm.prank(address(0xA33));
        executor.approveBalance(proposalId);

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "dust attested to zero");
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 0, "anchor reset to zero");

        vm.warp(block.timestamp + 8 days);
        assertEq(executor.getBalanceByChain(REMOTE_CHAIN), 0, "zero bucket does not fail closed");
        executor.getBalance();
    }

    function testShouldAttestZeroFromExactlyDustBoundButNotAbove() public {
        uint256 bound = CrosschainConstants.ATTESTATION_ZERO_DUST_SD;

        _fullRecallLeavingDust(bound);
        vm.warp(block.timestamp + 1 hours);
        _attestBalance(0);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "exactly the bound is accepted");
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 0, "anchor reset");
    }

    function testShouldRejectZeroAttestationAboveDustBound() public {
        uint256 bound = CrosschainConstants.ATTESTATION_ZERO_DUST_SD;

        _fullRecallLeavingDust(bound + 1);
        vm.warp(block.timestamp + 1 hours);
        vm.warp(block.timestamp + 1); // observation must postdate the last value-moving receipt
        uint256 proposalId = executor.proposeBalance(
            REMOTE_CHAIN,
            0,
            executor.lastRemoteStateVersion(REMOTE_CHAIN),
            uint64(block.number),
            uint64(block.timestamp),
            uint64(block.timestamp + 1 days),
            dispatcher.trackedPositionSetHash()
        );
        vm.expectRevert(
            abi.encodeWithSelector(CcipExecutorAttestationLib.BigChangeExceeded.selector, bound + 1, 0, 2_000)
        );
        vm.prank(address(0xA33));
        executor.approveBalance(proposalId);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), bound + 1, "bucket untouched");
    }

    function testShouldStillApplyRelativeRuleToNonZeroTargetBelowDustBound() public {
        _fullRecallLeavingDust(13);

        vm.warp(block.timestamp + 1 hours);
        vm.warp(block.timestamp + 1); // observation must postdate the last value-moving receipt
        uint256 proposalId = executor.proposeBalance(
            REMOTE_CHAIN,
            5,
            executor.lastRemoteStateVersion(REMOTE_CHAIN),
            uint64(block.number),
            uint64(block.timestamp),
            uint64(block.timestamp + 1 days),
            dispatcher.trackedPositionSetHash()
        );
        vm.expectRevert(abi.encodeWithSelector(CcipExecutorAttestationLib.BigChangeExceeded.selector, 13, 5, 2_000));
        vm.prank(address(0xA33));
        executor.approveBalance(proposalId);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 13, "only exactly-zero is special");
    }

    function testShouldDebitSettledBySentAmountOnPartialRecallWithFee() public {
        _fundRemoteIdle(100e18);
        router.setAutoDeliver(false);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 60e18, 60e18, 0, address(0), 2_000_000);
        bytes32 operationId = executor.activeReturn(REMOTE_CHAIN);

        token.mint(address(executor), 59.9e18);
        _deliverReturnWithFee(operationId, 60e18, 59.9e18, 40e18);

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 40e18, "settled decreases by the SENT amount");
        assertEq(executor.idleLedger(), 59.9e18, "idle increases by the received amount");
        assertEq(executor.getBalance(), 99.9e18, "the fee is a realized loss");
    }

    function testShouldClampReturnDebitToMaxAccountedAndAlarm() public {
        _fundRemoteIdle(100e18);
        router.setAutoDeliver(false);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 60e18, 60e18, 0, address(0), 2_000_000);
        bytes32 operationId = executor.activeReturn(REMOTE_CHAIN);

        token.mint(address(executor), 80e18);
        vm.expectEmit(address(executor));
        emit ReturnDebitExceededAccountingBound(REMOTE_CHAIN, operationId, 80e18, 60e18);
        _deliverReturnWithFee(operationId, 80e18, 80e18, 40e18);

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 40e18, "debit clamped to maxAccounted");
        assertEq(executor.idleLedger(), 80e18, "delivered tokens still credited");
    }

    /// @notice IL-8572: a declared debit above `settled` (but within `maxAccounted`) is clamped to `settled` and
    ///         alarmed with the effective bound, exactly as the Stargate executor does.
    function testShouldAlarmWhenReturnDebitClampedToSettled() public {
        bytes32 operationId = _recallWithSettledBelowBound();

        token.mint(address(executor), 45e18);
        vm.expectEmit(address(executor));
        emit ReturnDebitExceededAccountingBound(REMOTE_CHAIN, operationId, 45e18, 30e18);
        _deliverReturnWithFee(operationId, 45e18, 45e18, 0);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "debit clamped to settled");
    }

    /// @notice IL-8572: `ReturnFinalized` carries the debit actually applied next to the declared amount.
    function testShouldEmitActualDebitInReturnFinalized() public {
        bytes32 operationId = _recallWithSettledBelowBound();

        token.mint(address(executor), 45e18);
        vm.expectEmit(address(executor));
        emit ReturnFinalized(REMOTE_CHAIN, operationId, 45e18, 45e18, 30e18);
        _deliverReturnWithFee(operationId, 45e18, 45e18, 0);
    }

    /// @notice IL-8572: the late path (recall no longer active) also reports the applied debit.
    function testShouldEmitActualDebitInLateReturnFinalized() public {
        bytes32 oldOperation = _recallWithSettledBelowBound();
        vm.warp(block.timestamp + 1 days + 1);
        executor.cancelStalePendingReturn(REMOTE_CHAIN);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 10e18, 10e18, 0, address(0), 2_000_000);

        token.mint(address(executor), 45e18);
        vm.expectEmit(address(executor));
        emit LateReturnFinalized(REMOTE_CHAIN, oldOperation, 45e18, 45e18, 30e18);
        _deliverReturnWithFee(oldOperation, 45e18, 45e18, 0);
    }

    /// @dev Recall with `maxAccounted` = 60 while `settled` is 30 (lowered after the request, as a force-set
    ///      or a concurrent debit would), so the declared amount lies between the two bounds.
    function _recallWithSettledBelowBound() private returns (bytes32 operationId) {
        _fundRemoteIdle(100e18);
        router.setAutoDeliver(false);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 60e18, 60e18, 0, address(0), 2_000_000);
        operationId = executor.activeReturn(REMOTE_CHAIN);
        stdstore.target(address(executor)).sig("settledRemoteBalance(uint256)").with_key(REMOTE_CHAIN).checked_write(
            30e18
        );
    }

    /// @notice IL-8496: the dispatcher's responses go out unordered like every other CCIP message. CCIP 2.0
    ///         ignores `false`, and a 1.6 lane honouring it would hold every later response behind a failed one;
    ///         the executor orders them itself through its state-version frontier.
    function testDispatcherBalanceMessagesShouldUseOutOfOrderExecution() public {
        _fundRemoteIdle(1e18);
        bytes memory expected = CcipClient.argsToBytes(
            CcipClient.GenericExtraArgsV2({gasLimit: 2_000_000, allowOutOfOrderExecution: true})
        );
        assertEq(router.lastExtraArgs(), expected);
    }

    function testShouldQueueSettlementAndPermissionlesslyFlushAfterTransportRecovery() public {
        router.setFailSend(address(dispatcher), true);
        token.mint(address(executor), 100e18);

        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e18, 0, address(0), 2_000_000);

        assertEq(dispatcher.trackedIdle(), 100e18, "destination transition must commit");
        assertEq(dispatcher.responseQueueHead(), 1, "settlement retained in FIFO outbox");
        assertEq(executor.outboundInFlight(REMOTE_CHAIN), 100e18, "source waits for settlement");

        router.setFailSend(address(dispatcher), false);
        vm.prank(address(0xBEEF));
        dispatcher.flushResponse();

        assertEq(dispatcher.responseQueueHead(), 0, "outbox drained");
        assertEq(executor.outboundInFlight(REMOTE_CHAIN), 0);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e18);
    }

    function testQueuedHeadShouldFlushAfterFeeCeilingPolicyIncrease() public {
        router.setFailSend(address(dispatcher), true);
        token.mint(address(executor), 100e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e18, 0, address(0), 2_000_000);
        assertEq(dispatcher.responseQueueHead(), 1);

        router.setFailSend(address(dispatcher), false);
        router.setFee(0.1 ether);
        vm.deal(address(dispatcher), 0.1 ether);
        vm.expectRevert(abi.encodeWithSelector(CcipAppBase.CcipFeeTooHigh.selector, 0.1 ether, 0));
        dispatcher.flushResponse();
        assertEq(dispatcher.responseQueueHead(), 1, "failed flush preserves the head");

        CcipRouteConfig memory updated = dispatcher.ccipRoute(block.chainid);
        updated.maxFee = 0.1 ether;
        updated.messageGasLimit = 650_000;
        vm.prank(factory);
        dispatcher.syncRoutePolicy(updated.feeToken, _packedPolicy(updated), updated.maxFee);

        vm.prank(address(0xBEEF));
        dispatcher.flushResponse();
        assertEq(dispatcher.responseQueueHead(), 0);
        assertEq(executor.outboundInFlight(REMOTE_CHAIN), 0);
        bytes memory expected = CcipClient.argsToBytes(
            CcipClient.GenericExtraArgsV2({gasLimit: 650_000, allowOutOfOrderExecution: true})
        );
        assertEq(router.lastExtraArgs(), expected, "queued response uses current message gas policy");
    }

    function testQueuedTokenReturnShouldStayAccountedUntilPolicyRepairAndFlush() public {
        _fundRemoteIdle(100e18);
        router.setFailSend(address(dispatcher), true);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 60e18, 60e18, 0, address(0), 2_000_000);
        assertEq(dispatcher.queuedTokenAmount(), 60e18);

        router.setFailSend(address(dispatcher), false);
        router.setFee(0.1 ether);
        vm.deal(address(dispatcher), 0.1 ether);
        vm.expectRevert(abi.encodeWithSelector(CcipAppBase.CcipFeeTooHigh.selector, 0.1 ether, 0));
        dispatcher.flushResponse();
        assertEq(dispatcher.queuedTokenAmount(), 60e18, "failed flush preserves token accounting");

        CcipRouteConfig memory updated = dispatcher.ccipRoute(block.chainid);
        updated.maxFee = 0.1 ether;
        updated.tokenGasLimit = 750_000;
        vm.prank(factory);
        dispatcher.syncRoutePolicy(updated.feeToken, _packedPolicy(updated), updated.maxFee);
        dispatcher.flushResponse();

        assertEq(dispatcher.responseQueueHead(), 0);
        assertEq(dispatcher.queuedTokenAmount(), 0);
        assertEq(executor.idleLedger(), 60e18);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 40e18);
        bytes memory expected = CcipClient.argsToBytes(
            CcipClient.GenericExtraArgsV2({gasLimit: 750_000, allowOutOfOrderExecution: true})
        );
        assertEq(router.lastExtraArgs(), expected, "queued token response uses current token gas policy");
    }

    function testQueuedHeadShouldUseUpdatedFeeTokenPolicy() public {
        router.setFailSend(address(dispatcher), true);
        token.mint(address(executor), 1e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 1e18, 0, address(0), 2_000_000);

        CcipToken feeToken = new CcipToken();
        uint256 fee = 5e18;
        feeToken.mint(address(dispatcher), fee);
        router.setFee(fee);
        router.setFailSend(address(dispatcher), false);

        CcipRouteConfig memory updated = dispatcher.ccipRoute(block.chainid);
        updated.feeToken = address(feeToken);
        updated.maxFee = fee;
        vm.prank(factory);
        dispatcher.syncRoutePolicy(updated.feeToken, _packedPolicy(updated), updated.maxFee);
        dispatcher.flushResponse();

        assertEq(feeToken.balanceOf(address(router)), fee);
        assertEq(dispatcher.responseQueueHead(), 0);
    }

    function testDispatcherPolicyUpdateShouldRequireFactory() public {
        CcipRouteConfig memory updated = dispatcher.ccipRoute(block.chainid);
        updated.maxFee = 1 ether;
        vm.expectRevert(CcipCrosschainDispatcher.OnlyFactory.selector);
        dispatcher.syncRoutePolicy(updated.feeToken, _packedPolicy(updated), updated.maxFee);
    }

    function testShouldReserveQueuedReturnTokensUntilFifoFlush() public {
        _fundRemoteIdle(100e18);
        router.setFailSend(address(dispatcher), true);

        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 60e18, 60e18, 0, address(0), 2_000_000);

        assertEq(dispatcher.trackedIdle(), 40e18);
        assertEq(dispatcher.queuedTokenAmount(), 60e18, "queued return remains rescue-protected");
        assertEq(executor.idleLedger(), 0, "source has not received queued tokens");

        router.setFailSend(address(dispatcher), false);
        dispatcher.flushResponse();

        assertEq(dispatcher.queuedTokenAmount(), 0);
        assertEq(executor.idleLedger(), 60e18);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 40e18);
    }

    function testShouldRejectExecutorRouteThatDivergesFromFactorySourceOfTruth() public {
        CcipToken otherToken = new CcipToken();
        CcipCrosschainExecutor otherExecutor = new CcipCrosschainExecutor(
            address(router),
            factory,
            address(this),
            address(otherToken),
            keccak256("OTHER"),
            18,
            _safety()
        );
        CcipRouteConfig memory mismatched = CcipRouteConfig({
            chainSelector: DISPATCHER_SELECTOR + 1,
            peer: address(dispatcher),
            feeToken: address(0),
            messageGasLimit: 2_000_000,
            tokenGasLimit: 2_000_000,
            maxFee: 0,
            enabled: true
        });
        vm.expectRevert("route mismatch");
        MockCcipRouteValidator(factory).registerExecutorRoute(address(otherExecutor), REMOTE_CHAIN, mismatched);
    }

    function testShouldRejectWrongPeer() public {
        // A well-formed envelope of a type the executor handles, so the revert can only come from the peer check
        // (an empty payload would revert in the envelope decoder even with the peer check removed).
        router.setSelector(address(this), DISPATCHER_SELECTOR);
        CcipClient.EVM2AnyMessage memory message = _emptyMessage(address(executor));
        message.data = CcipMessages.encode(CcipMsgType.UPDATE_VAULTS_ACK, "");
        vm.expectRevert(
            abi.encodeWithSelector(CcipAppBase.CcipUnauthorizedPeer.selector, DISPATCHER_SELECTOR, address(this))
        );
        router.ccipSend(DISPATCHER_SELECTOR, message);
    }

    function testShouldExcludeDonationAndFailClosedOnStaleTransfer() public {
        token.mint(address(executor), 110e18);
        assertEq(executor.getBalance(), 0, "donation excluded");
        router.setAutoDeliver(false);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e18, 0, address(0), 2_000_000);
        assertEq(executor.getBalance(), 100e18);
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(
            abi.encodeWithSelector(CcipExecutorTransferLib.TransferStale.selector, REMOTE_CHAIN, uint256(1))
        );
        executor.getBalance();
    }

    function testShouldTimelockAndGuardianVetoOutboundForceResolution() public {
        token.mint(address(executor), 100e18);
        router.setAutoDeliver(false);
        vm.recordLogs();
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e18, 0, address(0), 2_000_000);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 operationId;
        for (uint256 i; i < logs.length; ++i) {
            // AssetSent has no indexed params: every field lives in the data section.
            if (logs[i].emitter == address(executor) && logs[i].topics[0] == ASSET_SENT_TOPIC) {
                (, operationId, , ) = abi.decode(logs[i].data, (uint256, bytes32, bytes32, uint256));
            }
        }
        assertTrue(operationId != bytes32(0));

        vm.prank(address(0xA11));
        uint256 rescueId = executor.scheduleForceResolveOutbound(operationId, false);
        vm.prank(address(0xB22));
        executor.cancelRescue(rescueId);
        vm.warp(block.timestamp + 3 days);
        vm.prank(address(0xA11));
        vm.expectRevert();
        executor.executeForceResolveOutbound(rescueId, operationId, false);

        vm.prank(address(0xA11));
        rescueId = executor.scheduleForceResolveOutbound(operationId, false);
        vm.warp(block.timestamp + 3 days);
        vm.prank(address(0xA11));
        executor.executeForceResolveOutbound(rescueId, operationId, false);
        assertEq(executor.outboundInFlight(REMOTE_CHAIN), 0);
        assertEq(executor.getBalance(), 0, "dropped transfer no longer freezes or inflates NAV");

        vm.prank(address(router));
        executor.ccipReceive(
            CcipClient.Any2EVMMessage({
                messageId: keccak256("late-settlement"),
                sourceChainSelector: DISPATCHER_SELECTOR,
                sender: abi.encode(address(dispatcher)),
                data: CcipMessages.encode(
                    CcipMsgType.TRANSFER_SETTLED,
                    abi.encode(operationId, 100e18, 100e18, uint64(1))
                ),
                destTokenAmounts: new CcipClient.EVMTokenAmount[](0)
            })
        );
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e18, "late authenticated credit recovered");
    }

    function testShouldRejectLargeBalanceChangeAndBlockNav() public {
        _fundRemoteIdle(100e18);
        executor.requestRemoteBalance(REMOTE_CHAIN, 0, address(0), 2_000_000);
        vm.warp(block.timestamp + 1); // observation must postdate the last value-moving receipt
        uint256 proposalId = executor.proposeBalance(
            REMOTE_CHAIN,
            200e18,
            executor.lastRemoteStateVersion(REMOTE_CHAIN),
            1,
            uint64(block.timestamp),
            uint64(block.timestamp + 1 days),
            dispatcher.trackedPositionSetHash()
        );
        vm.prank(address(0xA33));
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipExecutorAttestationLib.BigChangeExceeded.selector,
                uint256(100e18),
                uint256(200e18),
                uint256(2_000)
            )
        );
        executor.approveBalance(proposalId);
        vm.prank(address(0xA33));
        executor.rejectBalanceAndBlock(proposalId);
        vm.expectRevert(abi.encodeWithSelector(CcipExecutorTransferLib.ChainBlocked.selector, REMOTE_CHAIN));
        executor.getBalance();
    }

    /// @dev IL-8260: a blocked chain with nothing tracked adds nothing to NAV, so it must not gate NAV for
    ///      the whole vault. The block stays raised, and the first value booked on the chain gates NAV again.
    function testShouldNotGateNavOnBlockedChainWithZeroTrackedValue() public {
        vm.warp(block.timestamp + 1); // observation must postdate the last value-moving receipt
        uint256 proposalId = executor.proposeBalance(
            REMOTE_CHAIN,
            0,
            executor.lastRemoteStateVersion(REMOTE_CHAIN),
            1,
            uint64(block.timestamp),
            uint64(block.timestamp + 1 days),
            dispatcher.trackedPositionSetHash()
        );
        vm.prank(address(0xA33));
        executor.rejectBalanceAndBlock(proposalId);
        assertTrue(executor.chainBlocked(REMOTE_CHAIN));
        assertEq(executor.getBalance(), 0, "empty blocked chain does not gate NAV");
        assertEq(executor.getBalanceByChain(REMOTE_CHAIN), 0);

        token.mint(address(executor), 100e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e18, 0, address(0), 2_000_000);
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "send does not lift the block");
        vm.expectRevert(abi.encodeWithSelector(CcipExecutorTransferLib.ChainBlocked.selector, REMOTE_CHAIN));
        executor.getBalance();
    }

    function testShouldEnforceMaximumFee() public {
        router.setFee(1 ether);
        token.mint(address(executor), 1e18);
        vm.deal(address(executor), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(CcipAppBase.CcipFeeTooHigh.selector, 1 ether, 0));
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 1e18, 0, address(0), 2_000_000);
    }

    function testShouldReconcileRemoteVaultYieldAndLoss() public {
        MockRemoteVault vault = new MockRemoteVault(token, "Remote", "rUSDC");
        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        executor.updateVaults(REMOTE_CHAIN, vaults, true, false, 0, address(0), 2_000_000);

        token.mint(address(executor), 100e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e18, 0, address(0), 2_000_000);
        _attestBalance(100e18);
        executor.sendCommandToDispatcher(
            REMOTE_CHAIN,
            Command({
                commandId: keccak256("deposit"),
                sequence: 0,
                commandConfigEpoch: 0,
                action: uint8(BusinessAction.DEPOSIT),
                minExecutionGas: 0,
                actionData: CrosschainMessages.encodeDepositAction(address(vault), 100e18, 100e18)
            }),
            0,
            address(0),
            2_000_000
        );
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e18);
        assertEq(executor.nextCommandSequence(REMOTE_CHAIN), 2, "allowlist and deposit acknowledged");

        token.mint(address(vault), 10e18);
        vm.warp(block.timestamp + 1 hours);
        executor.requestRemoteBalance(REMOTE_CHAIN, 0, address(0), 2_000_000);
        _attestBalance(dispatcher.accountedBalance());
        assertApproxEqAbs(executor.settledRemoteBalance(REMOTE_CHAIN), 110e18, 1, "yield reflected");

        token.burn(address(vault), 20e18);
        vm.warp(block.timestamp + 1 hours);
        executor.requestRemoteBalance(REMOTE_CHAIN, 0, address(0), 2_000_000);
        _attestBalance(dispatcher.accountedBalance());
        assertApproxEqAbs(executor.settledRemoteBalance(REMOTE_CHAIN), 90e18, 1, "loss reflected");

        executor.sendCommandToDispatcher(
            REMOTE_CHAIN,
            Command({
                commandId: keccak256("redeem"),
                sequence: 1,
                commandConfigEpoch: 0,
                action: uint8(BusinessAction.REDEEM),
                minExecutionGas: 0,
                actionData: CrosschainMessages.encodeRedeemAction(
                    address(vault),
                    vault.balanceOf(address(dispatcher)),
                    89e18
                )
            }),
            0,
            address(0),
            2_000_000
        );
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 90e18, 89e18, 0, address(0), 2_000_000);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "no phantom NAV");
        assertApproxEqAbs(executor.idleLedger(), 90e18, 1);
    }

    // ---------------------------------------------------------------------
    // IL-8118: the REAL WithdrawManager REPLACES the stored request on every requestShares; a repeated or
    // shrinking request must succeed and leave exactly the manager's new value (IL-8410: the dispatcher no
    // longer keeps a copy). `nextCommandSequence` is the outcome oracle here (a SUCCEEDED command advances
    // it, a FAILED one does not) because the executor stamps its own commandId/sequence (`_buildCommand`),
    // so a caller-chosen id cannot be asserted against.
    // ---------------------------------------------------------------------

    /// @dev Deploys a real `WithdrawManager` behind a permissive authority, wired to a fresh
    ///      `MockRemotePlasmaVault`, with the given WAD-scale request fee, and allowlists the vault on the
    ///      dispatcher through the executor (plan §3.1).
    function _realWm(uint256 feeWad_) private returns (WithdrawManager wm, MockRemotePlasmaVault rv) {
        MockPermissiveAuthority authority = new MockPermissiveAuthority();
        wm = new WithdrawManager(address(authority));
        rv = new MockRemotePlasmaVault(token, "Real Remote", "rRVLT");
        rv.setWithdrawManager(address(wm));
        wm.updatePlasmaVaultAddress(address(rv));
        wm.updateWithdrawWindow(1 days);
        if (feeWad_ > 0) {
            wm.updateRequestFee(feeWad_);
        }
        assertEq(wm.getRequestFee(), feeWad_, "fee scale pinned in the test");

        address[] memory vaults = new address[](1);
        vaults[0] = address(rv);
        executor.updateVaults(REMOTE_CHAIN, vaults, true, false, 0, address(0), 2_000_000);
    }

    function _sendCcipCommand(uint8 action_, bytes memory actionData_) private {
        executor.sendCommandToDispatcher(
            REMOTE_CHAIN,
            Command({
                commandId: keccak256(abi.encode(action_, actionData_, block.timestamp, gasleft())),
                sequence: executor.nextCommandSequence(REMOTE_CHAIN),
                commandConfigEpoch: 0,
                action: action_,
                minExecutionGas: 0,
                actionData: actionData_
            }),
            0,
            address(0),
            2_000_000
        );
    }

    /// @dev Delivers a COMMAND directly to the dispatcher's `ccipReceive`, spoofing the authenticated
    ///      executor sender exactly the way `testStaleRecallCanBePermissionlesslyCancelledAndLateReturnIsSafe`
    ///      (`:211`) spoofs a message TO the executor. Used by the IL-8117 guard tests (C1-C3) so they can
    ///      assert on a commandId they chose, the way `DispatcherTest.t.sol` does for Stargate.
    /// @dev DEVIATION from plan §4 C1-C3: the plan's suggested `_sendCcipCommandReturningId` assumed the
    ///      caller-supplied `Command.commandId` on `executor.sendCommandToDispatcher` survives the round
    ///      trip. It does not — `sendCommandToDispatcher` discards the caller's `Command` entirely and
    ///      rebuilds one from the executor's own private nonce (`CcipCrosschainExecutor.sol:351`,
    ///      `_buildCommand` at `:453`, `CcipExecutorCommandLib.build` at `:134`), exactly as the existing
    ///      IL-8118 comment above already notes ("the executor stamps its own commandId/sequence... so a
    ///      caller-chosen id cannot be asserted against"). Delivering straight to the dispatcher, as this
    ///      helper does, sidesteps that relabeling and lets the id be asserted directly.
    function _deliverCcipCommand(bytes32 commandId_, uint8 action_, bytes memory actionData_) private {
        // Read dispatcher state BEFORE `vm.prank`: it only overrides `msg.sender` for the very next CALL,
        // and these are calls to `dispatcher` in their own right — issuing them after `vm.prank` would
        // consume the prank on `nextCommandSequence()`/`commandConfigEpoch()` instead of on `ccipReceive` below.
        uint64 sequence = dispatcher.nextCommandSequence();
        uint64 epoch = dispatcher.commandConfigEpoch();
        bytes memory data = CcipMessages.encode(
            CcipMsgType.COMMAND,
            abi.encode(
                CcipMsgType.COMMAND,
                Command({
                    commandId: commandId_,
                    sequence: sequence,
                    commandConfigEpoch: epoch,
                    action: action_,
                    minExecutionGas: 0,
                    actionData: actionData_
                }),
                bytes("")
            )
        );
        vm.prank(address(router));
        dispatcher.ccipReceive(
            CcipClient.Any2EVMMessage({
                messageId: commandId_,
                sourceChainSelector: EXECUTOR_SELECTOR,
                sender: abi.encode(address(executor)),
                data: data,
                destTokenAmounts: new CcipClient.EVMTokenAmount[](0)
            })
        );
    }

    function testShouldReplaceRealWithdrawManagerRequestAfterSecondRequestWithFeeOnCcip() public {
        (WithdrawManager wm, MockRemotePlasmaVault rv) = _realWm(1e16); // 1% WAD fee
        _fundRemoteIdle(100e18);
        _sendCcipCommand(
            uint8(BusinessAction.DEPOSIT),
            CrosschainMessages.encodeDepositAction(address(rv), 100e18, 100e18)
        );
        assertEq(rv.balanceOf(address(dispatcher)), 100e18, "deposit landed");

        uint64 seq1 = executor.nextCommandSequence(REMOTE_CHAIN);
        _sendCcipCommand(
            uint8(BusinessAction.REQUEST_SHARES),
            CrosschainMessages.encodeRequestSharesAction(address(wm), address(rv), 100e18, type(uint256).max)
        );
        assertEq(executor.nextCommandSequence(REMOTE_CHAIN), seq1 + 1, "request 1 succeeded and advanced the sequence");
        assertEq(wm.requestInfo(address(dispatcher)).shares, 99e18, "manager after request 1");
        assertEq(rv.balanceOf(address(dispatcher)), 99e18, "dispatcher balance net of fee");
        assertEq(rv.balanceOf(address(wm)), 1e18, "fee shares moved to the manager");

        uint64 seq2 = executor.nextCommandSequence(REMOTE_CHAIN);
        _sendCcipCommand(
            uint8(BusinessAction.REQUEST_SHARES),
            CrosschainMessages.encodeRequestSharesAction(address(wm), address(rv), 99e18, type(uint256).max)
        );
        assertEq(
            executor.nextCommandSequence(REMOTE_CHAIN),
            seq2 + 1,
            "re-request after a fee-bearing full request must succeed and advance the sequence"
        );
        assertEq(wm.requestInfo(address(dispatcher)).shares, 98_010_000_000_000_000_000, "manager after request 2");
    }

    function testShouldReplaceRealWithdrawManagerRequestWhenRequestShrinksOnCcip() public {
        (WithdrawManager wm, MockRemotePlasmaVault rv) = _realWm(0); // no fee: R_new = shares_ exactly
        _fundRemoteIdle(60e18);
        _sendCcipCommand(
            uint8(BusinessAction.DEPOSIT),
            CrosschainMessages.encodeDepositAction(address(rv), 60e18, 60e18)
        );

        _sendCcipCommand(
            uint8(BusinessAction.REQUEST_SHARES),
            CrosschainMessages.encodeRequestSharesAction(address(wm), address(rv), 60e18, type(uint256).max)
        );
        assertEq(wm.requestInfo(address(dispatcher)).shares, 60e18);

        uint64 seq2 = executor.nextCommandSequence(REMOTE_CHAIN);
        _sendCcipCommand(
            uint8(BusinessAction.REQUEST_SHARES),
            CrosschainMessages.encodeRequestSharesAction(address(wm), address(rv), 20e18, type(uint256).max)
        );
        assertEq(executor.nextCommandSequence(REMOTE_CHAIN), seq2 + 1, "a shrinking re-request must succeed");
        assertEq(wm.requestInfo(address(dispatcher)).shares, 20e18, "manager request replaced by the shrink");
    }

    /// @dev Guard: a request does not move NAV beyond the fee (`accountedBalance()` values a vault position
    ///      from `balanceOf` alone).
    function testShouldValueAccountedBalanceFromBalanceOfOnly() public {
        (WithdrawManager wm, MockRemotePlasmaVault rv) = _realWm(1e16);
        _fundRemoteIdle(100e18);
        _sendCcipCommand(
            uint8(BusinessAction.DEPOSIT),
            CrosschainMessages.encodeDepositAction(address(rv), 100e18, 100e18)
        );

        uint256 balanceBefore = dispatcher.accountedBalance();
        _sendCcipCommand(
            uint8(BusinessAction.REQUEST_SHARES),
            CrosschainMessages.encodeRequestSharesAction(address(wm), address(rv), 100e18, type(uint256).max)
        );
        uint256 feeAmount = 1e18; // 1% of 100e18
        uint256 balanceAfter = dispatcher.accountedBalance();
        assertEq(balanceBefore - balanceAfter, feeAmount, "NAV moved by exactly the fee (1:1 asset:share mock)");
    }

    // ---------------------------------------------------------------------
    // IL-8117: an authoritative `UniversalReader.read` of the vault's own configured manager. On
    // REQUEST_SHARES (G4) it REPLACES the self-attested check; on REDEEM_FROM_REQUEST (G5) it ADDS one,
    // since CCIP discarded the manager field there entirely — the divergence from Stargate the assessment
    // documented. Each test isolates one guard; the re-injection proof in the cycle file confirms this per guard
    // (plan §5).
    // ---------------------------------------------------------------------

    /// @dev Guard G4: a manager that self-attests `rv` but is not `rv`'s configured manager is rejected.
    function testShouldNackRequestSharesFromForeignWithdrawManagerOnCcip() public {
        (WithdrawManager wm, MockRemotePlasmaVault rv) = _realWm(0);
        _fundRemoteIdle(100e18);
        _sendCcipCommand(
            uint8(BusinessAction.DEPOSIT),
            CrosschainMessages.encodeDepositAction(address(rv), 50e18, 50e18)
        );

        MockWithdrawManager fake = new MockWithdrawManager(address(rv)); // self-attests rv; not rv's manager
        bytes32 commandId = keccak256("g4-foreign-request");
        _deliverCcipCommand(
            commandId,
            uint8(BusinessAction.REQUEST_SHARES),
            CrosschainMessages.encodeRequestSharesAction(address(fake), address(rv), 10e18, type(uint256).max)
        );
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED), "foreign manager NACKed");
        assertEq(rv.balanceOf(address(dispatcher)), 50e18, "no fee moved");
        assertEq(wm.requestInfo(address(dispatcher)).shares, 0, "real manager saw nothing");
    }

    /// @dev Guard G5, on the vault's own genuine request: a foreign manager named on REDEEM_FROM_REQUEST is
    ///      rejected even though the vault would enforce its own manager regardless (plan §2.4) — this is a
    ///      consistency check, proven independently of G4.
    function testShouldNackRedeemFromRequestFromForeignWithdrawManagerOnCcip() public {
        (WithdrawManager wm, MockRemotePlasmaVault rv) = _realWm(0);
        _fundRemoteIdle(100e18);
        _sendCcipCommand(
            uint8(BusinessAction.DEPOSIT),
            CrosschainMessages.encodeDepositAction(address(rv), 50e18, 50e18)
        );

        uint256 requestTs = block.timestamp;
        _sendCcipCommand(
            uint8(BusinessAction.REQUEST_SHARES),
            CrosschainMessages.encodeRequestSharesAction(address(wm), address(rv), 20e18, type(uint256).max)
        );
        assertEq(wm.requestInfo(address(dispatcher)).shares, 20e18);

        vm.warp(requestTs + 2);
        vm.prank(address(dispatcher));
        wm.releaseFunds(requestTs + 1, 20e18);

        MockWithdrawManager fake = new MockWithdrawManager(address(rv)); // self-attests rv; not rv's manager
        bytes32 commandId = keccak256("g5-foreign-redeem");
        _deliverCcipCommand(
            commandId,
            uint8(BusinessAction.REDEEM_FROM_REQUEST),
            CrosschainMessages.encodeRedeemFromRequestAction(address(fake), address(rv), 20e18, 0, address(dispatcher))
        );
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED), "foreign manager NACKed");
        assertEq(rv.balanceOf(address(dispatcher)), 50e18, "balance untouched");
        assertEq(wm.requestInfo(address(dispatcher)).shares, 20e18, "real manager request untouched");
    }

    /// @dev Guard, not a regression test: the first CCIP dispatcher-level REDEEM_FROM_REQUEST test in this
    ///      repo (none existed at HEAD, assessment §5). Passes before AND after the fix. It redeems the
    ///      WHOLE position: since IL-8784 the CCIP dispatcher has no business-flow untrack (tracked == allowlisted;
    ///      `_maybeUntrack` and force-untrack are gone), so a drained allowlisted vault stays tracked by construction.
    function testShouldRedeemFromRequestWithRealWithdrawManagerOnCcip() public {
        (WithdrawManager wm, MockRemotePlasmaVault rv) = _realWm(0);
        _fundRemoteIdle(100e18);
        _sendCcipCommand(
            uint8(BusinessAction.DEPOSIT),
            CrosschainMessages.encodeDepositAction(address(rv), 50e18, 50e18)
        );

        uint256 requestTs = block.timestamp;
        _sendCcipCommand(
            uint8(BusinessAction.REQUEST_SHARES),
            CrosschainMessages.encodeRequestSharesAction(address(wm), address(rv), 50e18, type(uint256).max)
        );
        assertEq(wm.requestInfo(address(dispatcher)).shares, 50e18);

        vm.warp(requestTs + 2);
        vm.prank(address(dispatcher));
        wm.releaseFunds(requestTs + 1, 50e18);

        uint256 idleBefore = dispatcher.trackedIdle();
        bytes32 commandId = keccak256("c3-genuine-redeem");
        _deliverCcipCommand(
            commandId,
            uint8(BusinessAction.REDEEM_FROM_REQUEST),
            CrosschainMessages.encodeRedeemFromRequestAction(address(wm), address(rv), 50e18, 0, address(dispatcher))
        );
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.SUCCEEDED));
        assertEq(wm.requestInfo(address(dispatcher)).shares, 0, "manager request closed");
        assertEq(dispatcher.trackedIdle(), idleBefore + 50e18, "assets moved to idle 1:1 (mock vault)");
        // Position fully drained: tracked == allowlisted on CCIP (IL-8784), so the vault stays tracked
        // although its balance is zero.
        assertEq(rv.balanceOf(address(dispatcher)), 0, "position fully redeemed");
        assertTrue(dispatcher.isTrackedVault(address(rv)), "still tracked: allowlisted, though drained");
    }

    /// @dev IL-8410 / IL-8336 regression: a direct REDEEM of the full share balance no longer leaves a stale
    ///      request cache behind. The vault stays tracked while allowlisted; once de-allowlisted it is
    ///      untracked even though the WithdrawManager still reports a non-zero request (which cannot be
    ///      exercised without shares). Pre-fix the cache pinned the tracked-vault slot forever.
    function testShouldUntrackVaultAfterDirectRedeemDespiteOutstandingRequestOnCcip() public {
        (WithdrawManager wm, MockRemotePlasmaVault rv) = _realWm(1e16);
        _fundRemoteIdle(100e18);
        _sendCcipCommand(
            uint8(BusinessAction.DEPOSIT),
            CrosschainMessages.encodeDepositAction(address(rv), 100e18, 100e18)
        );
        _sendCcipCommand(
            uint8(BusinessAction.REQUEST_SHARES),
            CrosschainMessages.encodeRequestSharesAction(address(wm), address(rv), 40e18, type(uint256).max)
        );
        assertEq(wm.requestInfo(address(dispatcher)).shares, 39.6e18, "request outstanding");
        uint256 balance = rv.balanceOf(address(dispatcher));
        assertEq(balance, 99.6e18, "balance net of the request fee");

        uint64 seq = executor.nextCommandSequence(REMOTE_CHAIN);
        _sendCcipCommand(uint8(BusinessAction.REDEEM), CrosschainMessages.encodeRedeemAction(address(rv), balance, 0));
        assertEq(executor.nextCommandSequence(REMOTE_CHAIN), seq + 1, "direct redeem succeeded");
        assertEq(rv.balanceOf(address(dispatcher)), 0, "share balance drained");
        assertEq(wm.requestInfo(address(dispatcher)).shares, 39.6e18, "manager still reports the request");
        assertTrue(dispatcher.isTrackedVault(address(rv)), "still tracked while allowlisted");

        address[] memory vaults = new address[](1);
        vaults[0] = address(rv);
        vm.expectEmit(address(dispatcher));
        emit CcipCrosschainDispatcher.VaultUntracked(address(rv));
        executor.updateVaults(REMOTE_CHAIN, vaults, false, false, 0, address(0), 2_000_000);

        assertFalse(dispatcher.isTrackedVault(address(rv)), "untracked after de-allowlisting, slot freed");
        assertEq(dispatcher.trackedVaultsLength(), 0, "tracked set empty");
    }

    /// @dev IL-8410 / IL-8336: REDEEM_FROM_REQUEST above the manager's request fails (the dispatcher no longer
    ///      pre-checks; the vault reverts via `canWithdrawFromRequest`) even with the window open and funds
    ///      released, the CCIP command is marked FAILED and nothing moves.
    function testShouldFailRedeemFromRequestAboveManagerRequestOnCcip() public {
        (WithdrawManager wm, MockRemotePlasmaVault rv) = _realWm(0);
        _fundRemoteIdle(100e18);
        _sendCcipCommand(
            uint8(BusinessAction.DEPOSIT),
            CrosschainMessages.encodeDepositAction(address(rv), 50e18, 50e18)
        );
        uint256 requestTs = block.timestamp;
        _sendCcipCommand(
            uint8(BusinessAction.REQUEST_SHARES),
            CrosschainMessages.encodeRequestSharesAction(address(wm), address(rv), 20e18, type(uint256).max)
        );
        vm.warp(requestTs + 2);
        vm.prank(address(dispatcher));
        wm.releaseFunds(requestTs + 1, 20e18);

        uint256 idleBefore = dispatcher.trackedIdle();
        bytes32 commandId = keccak256("il-8410-above-request");
        _deliverCcipCommand(
            commandId,
            uint8(BusinessAction.REDEEM_FROM_REQUEST),
            CrosschainMessages.encodeRedeemFromRequestAction(
                address(wm),
                address(rv),
                20e18 + 1,
                0,
                address(dispatcher)
            )
        );
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED), "above-request fails");
        assertEq(wm.requestInfo(address(dispatcher)).shares, 20e18, "request unchanged");
        assertEq(rv.balanceOf(address(dispatcher)), 50e18, "share balance unchanged");
        assertEq(dispatcher.trackedIdle(), idleBefore, "no assets credited");
    }

    /// @dev IL-8603: REQUEST_SHARES fee ceiling. Real manager at a 1% WAD fee takes 1e18 of 100e18 shares.
    function _requestSharesWithCeiling(
        uint256 maxFee_,
        bytes32 commandId_
    ) private returns (WithdrawManager wm, MockRemotePlasmaVault rv) {
        (wm, rv) = _realWm(1e16);
        _fundRemoteIdle(100e18);
        _sendCcipCommand(
            uint8(BusinessAction.DEPOSIT),
            CrosschainMessages.encodeDepositAction(address(rv), 100e18, 100e18)
        );
        _deliverCcipCommand(
            commandId_,
            uint8(BusinessAction.REQUEST_SHARES),
            CrosschainMessages.encodeRequestSharesAction(address(wm), address(rv), 100e18, maxFee_)
        );
    }

    function testShouldNackRequestSharesWhenFeeExceedsCeiling() public {
        bytes32 id = keccak256("fee-over");
        (WithdrawManager wm, MockRemotePlasmaVault rv) = _requestSharesWithCeiling(1e18 - 1, id);
        assertEq(uint8(dispatcher.commandStatus(id)), uint8(CommandStatus.FAILED), "NACKed");
        assertEq(rv.balanceOf(address(dispatcher)), 100e18, "fee transfer rolled back");
        assertEq(wm.requestInfo(address(dispatcher)).shares, 0, "no request recorded");
    }

    function testShouldSucceedRequestSharesWithinCeiling() public {
        bytes32 id = keccak256("fee-ok");
        vm.recordLogs();
        (, MockRemotePlasmaVault rv) = _requestSharesWithCeiling(1e18, id);
        assertEq(uint8(dispatcher.commandStatus(id)), uint8(CommandStatus.SUCCEEDED), "exact-ceiling fee passes");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(dispatcher) && logs[i].topics[0] == SharesRequested.selector) {
                (address vault, uint256 pending, uint256 fee) = abi.decode(logs[i].data, (address, uint256, uint256));
                assertEq(vault, address(rv));
                assertEq(pending, 99e18);
                assertEq(fee, 1e18, "event carries the measured deduction");
                seen = true;
            }
        }
        assertTrue(seen, "SharesRequested emitted");
    }

    function testShouldSucceedRequestSharesWithNoCeiling() public {
        bytes32 id = keccak256("fee-max");
        _requestSharesWithCeiling(type(uint256).max, id);
        assertEq(uint8(dispatcher.commandStatus(id)), uint8(CommandStatus.SUCCEEDED), "no ceiling");
    }

    /// @dev IL-8482: REQUEST_SHARES emits the manager's read-back outstanding request (post-fee), matching Stargate.
    function testShouldEmitSharesRequestedOnCcip() public {
        (WithdrawManager wm, MockRemotePlasmaVault rv) = _realWm(1e16); // 1% fee: pending != requested
        _fundRemoteIdle(100e18);
        _sendCcipCommand(
            uint8(BusinessAction.DEPOSIT),
            CrosschainMessages.encodeDepositAction(address(rv), 100e18, 100e18)
        );

        vm.expectEmit(address(dispatcher));
        emit SharesRequested(address(rv), 99e18, 1e18);
        _sendCcipCommand(
            uint8(BusinessAction.REQUEST_SHARES),
            CrosschainMessages.encodeRequestSharesAction(address(wm), address(rv), 100e18, type(uint256).max)
        );
        assertEq(wm.requestInfo(address(dispatcher)).shares, 99e18, "emitted value equals the manager's request");
    }

    /// @dev IL-8482: REDEEM_FROM_REQUEST emits the shares burned and the floored SD amount credited to idle.
    function testShouldEmitRedeemedFromRequestOnCcip() public {
        (WithdrawManager wm, MockRemotePlasmaVault rv) = _realWm(0);
        _fundRemoteIdle(100e18);
        _sendCcipCommand(
            uint8(BusinessAction.DEPOSIT),
            CrosschainMessages.encodeDepositAction(address(rv), 50e18, 50e18)
        );
        uint256 requestTs = block.timestamp;
        _sendCcipCommand(
            uint8(BusinessAction.REQUEST_SHARES),
            CrosschainMessages.encodeRequestSharesAction(address(wm), address(rv), 50e18, type(uint256).max)
        );
        vm.warp(requestTs + 2);
        vm.prank(address(dispatcher));
        wm.releaseFunds(requestTs + 1, 50e18);

        uint256 idleBefore = dispatcher.trackedIdle();
        uint256 sharesBefore = rv.balanceOf(address(dispatcher));
        bytes memory data = CrosschainMessages.encodeRedeemFromRequestAction(
            address(wm),
            address(rv),
            30e18,
            0,
            address(dispatcher)
        );

        vm.expectEmit(address(dispatcher));
        emit RedeemedFromRequest(address(rv), 30e18, 30e18);
        _deliverCcipCommand(keccak256("il-8482-redeem"), uint8(BusinessAction.REDEEM_FROM_REQUEST), data);

        assertEq(sharesBefore - rv.balanceOf(address(dispatcher)), 30e18, "shares == balance decrease");
        assertEq(dispatcher.trackedIdle() - idleBefore, 30e18, "assetsSD == trackedIdle increase");
    }

    function _attestBalance(uint256 balance_) private {
        vm.warp(block.timestamp + 1); // observation must postdate the last value-moving receipt
        uint256 proposalId = executor.proposeBalance(
            REMOTE_CHAIN,
            balance_,
            executor.lastRemoteStateVersion(REMOTE_CHAIN),
            uint64(block.number == 0 ? 1 : block.number),
            uint64(block.timestamp),
            uint64(block.timestamp + 1 days),
            dispatcher.trackedPositionSetHash()
        );
        vm.prank(address(0xA33));
        executor.approveBalance(proposalId);
    }

    function _emptyMessage(address receiver_) private pure returns (CcipClient.EVM2AnyMessage memory message) {
        CcipClient.EVMTokenAmount[] memory amounts = new CcipClient.EVMTokenAmount[](0);
        return
            CcipClient.EVM2AnyMessage({
                receiver: abi.encode(receiver_),
                data: "",
                tokenAmounts: amounts,
                feeToken: address(0),
                extraArgs: ""
            });
    }

    function _packedPolicy(CcipRouteConfig memory route_) private pure returns (uint256) {
        return
            uint256(route_.messageGasLimit) |
            (uint256(route_.tokenGasLimit) << 96) |
            (route_.enabled ? uint256(1) << 192 : 0);
    }

    function _fundRemoteIdle(uint256 amount_) private {
        token.mint(address(executor), amount_);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, amount_, 0, address(0), 2_000_000);
        _attestBalance(dispatcher.accountedBalance());
    }

    function _deployAndAllowVault() private returns (MockRemoteVault vault) {
        vault = new MockRemoteVault(token, "Remote", "rUSDC");
        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        executor.updateVaults(REMOTE_CHAIN, vaults, true, false, 0, address(0), 2_000_000);
    }

    function _sendDeposit(MockRemoteVault vault_, uint256 amount_, bytes32 commandId_) private {
        executor.sendCommandToDispatcher(
            REMOTE_CHAIN,
            Command({
                commandId: commandId_,
                sequence: dispatcher.nextCommandSequence(),
                commandConfigEpoch: 0,
                action: uint8(BusinessAction.DEPOSIT),
                minExecutionGas: 0,
                actionData: CrosschainMessages.encodeDepositAction(address(vault_), amount_, amount_)
            }),
            0,
            address(0),
            2_000_000
        );
    }

    // ---------------------------------------------------------------------
    // IL-8474: source-side command events emitted by `CcipExecutorCommandLib` (executor address emits them).
    // ---------------------------------------------------------------------

    bytes32 internal constant COMMAND_SENT_TOPIC = keccak256("CommandSent(uint256,bytes32,uint64,uint8,bool,uint64)");
    bytes32 internal constant COMMAND_RETRY_REQUESTED_TOPIC = keccak256("CommandRetryRequested(uint256,bytes32)");

    function _logsFrom(
        Vm.Log[] memory logs_,
        address emitter_,
        bytes32 topic0_
    ) private pure returns (Vm.Log[] memory found) {
        uint256 count;
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == emitter_ && logs_[i].topics[0] == topic0_) ++count;
        }
        found = new Vm.Log[](count);
        count = 0;
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == emitter_ && logs_[i].topics[0] == topic0_) found[count++] = logs_[i];
        }
    }

    function testShouldEmitCommandSentForBusinessCommandOnCcip() public {
        MockRemoteVault vault = _deployAndAllowVault();
        _fundRemoteIdle(100e18);
        uint64 sequence = executor.nextCommandSequence(REMOTE_CHAIN);
        uint64 epoch = executor.commandConfigEpoch(REMOTE_CHAIN);

        vm.recordLogs();
        _sendDeposit(vault, 10e18, bytes32(0));
        Vm.Log[] memory sent = _logsFrom(vm.getRecordedLogs(), address(executor), COMMAND_SENT_TOPIC);

        assertEq(sent.length, 1, "exactly one CommandSent");
        (uint256 dstChainId, bytes32 commandId, uint64 seq, uint8 action, bool advancesConfig, uint64 cfgEpoch) = abi
            .decode(sent[0].data, (uint256, bytes32, uint64, uint8, bool, uint64));
        assertEq(dstChainId, REMOTE_CHAIN);
        assertTrue(commandId != bytes32(0), "id stamped by the executor");
        assertEq(seq, sequence);
        assertEq(action, uint8(BusinessAction.DEPOSIT));
        assertFalse(advancesConfig, "business command does not advance config");
        assertEq(cfgEpoch, epoch);
    }

    function testShouldEmitCommandSentForAllowlistUpdateOnCcip() public {
        uint64 sequence = executor.nextCommandSequence(REMOTE_CHAIN);
        uint64 epoch = executor.commandConfigEpoch(REMOTE_CHAIN);
        address[] memory vaults = new address[](1);
        vaults[0] = address(0xCAFE);

        vm.recordLogs();
        executor.updateVaults(REMOTE_CHAIN, vaults, true, false, 0, address(0), 2_000_000);
        Vm.Log[] memory sent = _logsFrom(vm.getRecordedLogs(), address(executor), COMMAND_SENT_TOPIC);

        assertEq(sent.length, 1, "exactly one CommandSent");
        (uint256 dstChainId, bytes32 commandId, uint64 seq, uint8 action, bool advancesConfig, uint64 cfgEpoch) = abi
            .decode(sent[0].data, (uint256, bytes32, uint64, uint8, bool, uint64));
        assertEq(dstChainId, REMOTE_CHAIN);
        assertTrue(commandId != bytes32(0), "id stamped by the executor");
        assertEq(seq, sequence);
        assertEq(action, 0);
        assertTrue(advancesConfig, "allowlist update advances config");
        assertEq(cfgEpoch, epoch);
    }

    function testShouldEmitCommandRetryRequestedWhenRetryingFailedCommandOnCcip() public {
        // A codeless target passes the executor's shape check and NACKs on the dispatcher.
        bytes32 commandId_;
        {
            vm.recordLogs();
            _sendCcipCommand(
                uint8(BusinessAction.DEPOSIT),
                CrosschainMessages.encodeDepositAction(address(0xBEEF), 1e18, 1e18)
            );
            Vm.Log[] memory sent = _logsFrom(vm.getRecordedLogs(), address(executor), COMMAND_SENT_TOPIC);
            assertEq(sent.length, 1);
            (, commandId_, , , , ) = abi.decode(sent[0].data, (uint256, bytes32, uint64, uint8, bool, uint64));
        }
        assertEq(uint8(executor.commandStatus(commandId_)), uint8(CommandStatus.FAILED), "command NACKed");

        vm.recordLogs();
        executor.retryCommand(REMOTE_CHAIN, commandId_, 0, address(0), 2_000_000);
        Vm.Log[] memory retried = _logsFrom(vm.getRecordedLogs(), address(executor), COMMAND_RETRY_REQUESTED_TOPIC);

        assertEq(retried.length, 1, "exactly one CommandRetryRequested");
        (uint256 chainId, bytes32 id) = abi.decode(retried[0].data, (uint256, bytes32));
        assertEq(chainId, REMOTE_CHAIN);
        assertEq(id, commandId_);
    }

    // ---------------------------------------------------------------------
    // IL-8477: `CommandAcknowledged` carries the resolution, value delta, state version and epoch mirror.
    // ---------------------------------------------------------------------

    bytes32 internal constant COMMAND_ACKNOWLEDGED_TOPIC =
        keccak256("CommandAcknowledged(uint256,bytes32,uint64,uint64,int256,uint8,uint64)");
    bytes32 internal constant COMMAND_SUCCEEDED_TOPIC = keccak256("CommandSucceeded(bytes32,uint64,int256)");

    function _singleAck(
        Vm.Log[] memory logs_
    )
        private
        view
        returns (
            uint256 srcChainId,
            bytes32 commandId,
            uint64 sequence,
            uint64 stateVersion,
            int256 valueDelta,
            uint8 resolution,
            uint64 epoch
        )
    {
        Vm.Log[] memory acks = _logsFrom(logs_, address(executor), COMMAND_ACKNOWLEDGED_TOPIC);
        assertEq(acks.length, 1, "exactly one CommandAcknowledged");
        return abi.decode(acks[0].data, (uint256, bytes32, uint64, uint64, int256, uint8, uint64));
    }

    function testShouldEmitResolutionValueDeltaAndVersionOnAckOfSucceededCommandOnCcip() public {
        MockRemoteVault vault = _deployAndAllowVault();
        _fundRemoteIdle(100e18);
        uint64 sequence = executor.nextCommandSequence(REMOTE_CHAIN);

        vm.recordLogs();
        _sendDeposit(vault, 10e18, bytes32(0));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        Vm.Log[] memory sent = _logsFrom(logs, address(executor), COMMAND_SENT_TOPIC);
        (, bytes32 expectedId, , , , ) = abi.decode(sent[0].data, (uint256, bytes32, uint64, uint8, bool, uint64));
        Vm.Log[] memory succeeded = _logsFrom(logs, address(dispatcher), COMMAND_SUCCEEDED_TOPIC);
        assertEq(succeeded.length, 1, "dispatcher applied the command");
        (, , int256 dispatcherDelta) = abi.decode(succeeded[0].data, (bytes32, uint64, int256));

        (
            uint256 srcChainId,
            bytes32 commandId,
            uint64 seq,
            uint64 stateVersion,
            int256 valueDelta,
            uint8 resolution,
            uint64 epoch
        ) = _singleAck(logs);
        assertEq(srcChainId, REMOTE_CHAIN);
        assertEq(commandId, expectedId);
        assertEq(seq, sequence);
        assertEq(stateVersion, dispatcher.stateVersion(), "receipt state version");
        assertEq(valueDelta, dispatcherDelta, "receipt value delta");
        assertEq(resolution, uint8(CommandResolution.SUCCEEDED));
        assertEq(epoch, executor.commandConfigEpoch(REMOTE_CHAIN), "epoch mirror after apply");
    }

    function testShouldEmitCancelledResolutionOnAckClosingCancelledCommandOnCcip() public {
        // A codeless target passes the executor's shape check and NACKs on the dispatcher.
        vm.recordLogs();
        _sendCcipCommand(
            uint8(BusinessAction.DEPOSIT),
            CrosschainMessages.encodeDepositAction(address(0xBEEF), 1e18, 1e18)
        );
        Vm.Log[] memory sent = _logsFrom(vm.getRecordedLogs(), address(executor), COMMAND_SENT_TOPIC);
        (, bytes32 failedId, , , , ) = abi.decode(sent[0].data, (uint256, bytes32, uint64, uint8, bool, uint64));
        assertEq(uint8(executor.commandStatus(failedId)), uint8(CommandStatus.FAILED), "command NACKed");
        uint64 epochBefore = executor.commandConfigEpoch(REMOTE_CHAIN);

        vm.recordLogs();
        executor.cancelCommand(REMOTE_CHAIN, failedId, 0, address(0), 2_000_000);
        (
            uint256 srcChainId,
            bytes32 commandId,
            ,
            uint64 stateVersion,
            int256 valueDelta,
            uint8 resolution,
            uint64 epoch
        ) = _singleAck(vm.getRecordedLogs());

        assertEq(uint8(executor.commandStatus(failedId)), uint8(CommandStatus.CANCELLED));
        assertEq(srcChainId, REMOTE_CHAIN);
        assertEq(commandId, failedId);
        assertEq(resolution, uint8(CommandResolution.CANCELLED), "distinguishable from a succeeded ACK");
        assertEq(valueDelta, 0, "nothing applied");
        assertEq(stateVersion, dispatcher.stateVersion(), "receipt state version");
        assertEq(epoch, epochBefore, "a cancel does not advance the epoch");
    }

    function testShouldEmitAdvancedEpochOnAckOfAllowlistUpdateOnCcip() public {
        uint64 epochBefore = executor.commandConfigEpoch(REMOTE_CHAIN);
        MockRemoteVault vault = new MockRemoteVault(token, "Remote", "rUSDC");
        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);

        vm.recordLogs();
        executor.updateVaults(REMOTE_CHAIN, vaults, true, false, 0, address(0), 2_000_000);
        (, , , , , uint8 resolution, uint64 epoch) = _singleAck(vm.getRecordedLogs());

        assertEq(resolution, uint8(CommandResolution.SUCCEEDED));
        assertEq(epoch, epochBefore + 1, "allowlist update advances the epoch mirror");
        assertEq(epoch, executor.commandConfigEpoch(REMOTE_CHAIN));
        assertEq(epoch, dispatcher.commandConfigEpoch(), "mirror matches the dispatcher");
    }

    // ---------------------------------------------------------------------
    // IL-8608: remote vault keeping its withdraw manager in the legacy (pre-IL-6952) slot
    // ---------------------------------------------------------------------

    function _legacyWm(bool setManager_) private returns (MockWithdrawManager wm, MockLegacyRemotePlasmaVault lv) {
        lv = new MockLegacyRemotePlasmaVault(token, "Legacy Remote", "lRVLT");
        wm = new MockWithdrawManager(address(lv));
        if (setManager_) lv.setLegacyWithdrawManager(address(wm));
        address[] memory vaults = new address[](1);
        vaults[0] = address(lv);
        executor.updateVaults(REMOTE_CHAIN, vaults, true, false, 0, address(0), 2_000_000);
        _fundRemoteIdle(100e18);
        _sendCcipCommand(
            uint8(BusinessAction.DEPOSIT),
            CrosschainMessages.encodeDepositAction(address(lv), 50e18, 50e18)
        );
    }

    function testShouldRequestSharesAndRedeemFromRequestOnLegacySlotVaultOnCcip() public {
        (MockWithdrawManager wm, MockLegacyRemotePlasmaVault lv) = _legacyWm(true);
        bytes32 reqId = keccak256("legacy-request");
        _deliverCcipCommand(
            reqId,
            uint8(BusinessAction.REQUEST_SHARES),
            CrosschainMessages.encodeRequestSharesAction(address(wm), address(lv), 10e18, type(uint256).max)
        );
        assertEq(uint8(dispatcher.commandStatus(reqId)), uint8(CommandStatus.SUCCEEDED), "request accepted");
        assertEq(wm.requestInfo(address(dispatcher)).shares, 10e18);

        uint256 idleBefore = dispatcher.trackedIdle();
        bytes32 rfrId = keccak256("legacy-redeem");
        _deliverCcipCommand(
            rfrId,
            uint8(BusinessAction.REDEEM_FROM_REQUEST),
            CrosschainMessages.encodeRedeemFromRequestAction(address(wm), address(lv), 10e18, 0, address(dispatcher))
        );
        assertEq(uint8(dispatcher.commandStatus(rfrId)), uint8(CommandStatus.SUCCEEDED), "redeem accepted");
        assertGt(dispatcher.trackedIdle(), idleBefore, "assets added to idle");
    }

    /// @dev Replays a REQUEST_SHARES command through the self-only `runStoredCommand` and expects the dedicated
    ///      `WithdrawManagerUnresolved(vault)` revert (the NACK path swallows the selector).
    function _expectUnresolvedManager(address manager_, address vault_) private {
        Command memory c = Command({
            commandId: keccak256("unresolved-probe"),
            sequence: dispatcher.nextCommandSequence(),
            commandConfigEpoch: dispatcher.commandConfigEpoch(),
            action: uint8(BusinessAction.REQUEST_SHARES),
            minExecutionGas: 0,
            actionData: CrosschainMessages.encodeRequestSharesAction(manager_, vault_, 10e18, type(uint256).max)
        });
        vm.prank(address(dispatcher));
        vm.expectRevert(abi.encodeWithSelector(CcipCrosschainDispatcher.WithdrawManagerUnresolved.selector, vault_));
        dispatcher.runStoredCommand(CcipMsgType.COMMAND, c, bytes(""));
    }

    function testShouldNackZeroWithdrawManagerOnLegacySlotVaultOnCcip() public {
        (, MockLegacyRemotePlasmaVault lv) = _legacyWm(true);
        bytes32 reqId = keccak256("legacy-zero-manager");
        _deliverCcipCommand(
            reqId,
            uint8(BusinessAction.REQUEST_SHARES),
            CrosschainMessages.encodeRequestSharesAction(address(0), address(lv), 10e18, type(uint256).max)
        );
        assertEq(uint8(dispatcher.commandStatus(reqId)), uint8(CommandStatus.FAILED), "zero manager NACKed");
        _expectUnresolvedManager(address(0), address(lv));
    }

    function testShouldNackWhenVaultHasNoWithdrawManagerInEitherSlotOnCcip() public {
        (MockWithdrawManager wm, MockLegacyRemotePlasmaVault lv) = _legacyWm(false);
        bytes32 reqId = keccak256("no-manager-request");
        _deliverCcipCommand(
            reqId,
            uint8(BusinessAction.REQUEST_SHARES),
            CrosschainMessages.encodeRequestSharesAction(address(wm), address(lv), 10e18, type(uint256).max)
        );
        assertEq(uint8(dispatcher.commandStatus(reqId)), uint8(CommandStatus.FAILED), "unresolved manager NACKed");
        assertEq(wm.requestInfo(address(dispatcher)).shares, 0, "manager saw nothing");
        _expectUnresolvedManager(address(wm), address(lv));
    }
}
