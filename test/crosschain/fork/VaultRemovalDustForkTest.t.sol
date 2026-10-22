// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {CcipForkBase, CcipForkMessage} from "./CcipForkBase.sol";
import {CcipMsgType} from "../../../contracts/crosschain/ccip/lib/CcipMessages.sol";

/// @title VaultRemovalDustForkTest
/// @notice IL-8784 / D-065 over the REAL CCIP transport: an UPDATE_VAULTS removal of a real Arbitrum PlasmaVault
///         (IPOR USDC Prime) on a route whose `messageGasLimit` is 3,000,000 (the usual lane limit, which a CCIP RETRY
///         cannot raise). The message is delivered through the real destination `Router.routeMessage` at the message's
///         gas limit, cold (`isolate`), and the ACK/NACK is read from what the dispatcher sent back through the real
///         OnRamp. Shares are dealt to the dispatcher to stand in for a donation or a position.
/// @dev Every test lives in a contract of its own with its own fork blocks (see `CcipForkBase._forkBlocks`): forge runs
///      the tests of one contract in parallel, and tests that fork the same URL at the same block share one backend,
///      so a `vm.warp` of one could reach another and expire the command deadline (NACK, `response type: 7 != 6`,
///      seen in CI only, where forge runs multithreaded). Needs ETHEREUM_PROVIDER_URL
///      and ARBITRUM_PROVIDER_URL (archive nodes).
abstract contract VaultRemovalDustForkBase is CcipForkBase {
    address internal constant PRIME = 0xD855296f9868fF659F3f359C90B7D005EC049228; // IPOR USDC Prime (PlasmaVault)

    CcipForkMessage internal held;

    event TrackedVaultSweepResidual(
        address vault,
        uint256 sharesLeft,
        uint8 reason,
        bytes4 redeemError,
        bool untracked
    );

    function _deliver(CcipForkMessage memory m_, address destRouter_, string memory label_) internal override {
        (bool success, bytes memory ret, ) = _routeViaRouter(m_, destRouter_, m_.ccipReceiveGasLimit);
        if (!success) {
            emit log_named_bytes(label_, ret);
            fail();
        }
    }

    function _routeGasLimit() internal pure override returns (uint96) {
        return 3_000_000;
    }

    /// @dev Creates the dispatcher tracking PRIME, donates `shares_` of PRIME to it (or the shares worth
    ///      `assetsWorth_` when `shares_` is zero and `assetsWorth_` is not) and holds the removal message.
    function _setUpWithShares(uint256 assetsWorth_, uint256 shares_) internal returns (uint256 given) {
        _deployStack();
        _warmExecutorStorage();
        address[] memory vaults = new address[](1);
        vaults[0] = PRIME;
        vm.selectFork(arbFork);
        require(IERC4626(PRIME).asset() == ARBITRUM_USDC, "usdc vault");
        vm.selectFork(ethFork);
        _startCapture();
        factory.requestDispatcher(address(executor), ARBITRUM_CHAIN_ID, vaults, MAX_FEE);
        CcipForkMessage memory create = _sendFromExecutor();
        _roundTrip(create, "create", CcipMsgType.DEPLOYMENT_ACK, "ack");
        vm.selectFork(arbFork);
        assertTrue(dispatcher.isTrackedVault(PRIME), "tracked");
        vm.deal(address(dispatcher), 1 ether);

        given = shares_ != 0 ? shares_ : IERC4626(PRIME).convertToShares(assetsWorth_);
        if (given != 0) deal(PRIME, address(dispatcher), given);
        assertEq(IERC20(PRIME).balanceOf(address(dispatcher)), given, "dealt");

        vm.selectFork(ethFork);
        _startCapture();
        executor.updateVaults(ARBITRUM_CHAIN_ID, vaults, false, false, MAX_FEE, FEE_TOKEN, 0);
        held = _sendFromExecutor();
        assertEq(held.ccipReceiveGasLimit, 3_000_000, "3M route");
        vm.selectFork(arbFork);
    }

    struct Outcome {
        uint256 gasUsed;
        CcipMsgType response;
        bool tracked;
        uint256 sharesLeft;
        uint256 navBefore;
        uint256 navAfter;
        uint256 worthBefore;
        bytes[] residuals; // data of every TrackedVaultSweepResidual the dispatcher emitted
    }

    function _residuals(Vm.Log[] memory logs_) private view returns (bytes[] memory out) {
        bytes32 topic = TrackedVaultSweepResidual.selector;
        uint256 n;
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == address(dispatcher) && logs_[i].topics[0] == topic) ++n;
        }
        out = new bytes[](n);
        n = 0;
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == address(dispatcher) && logs_[i].topics[0] == topic) out[n++] = logs_[i].data;
        }
    }

    function _deliverMeasured() internal returns (Outcome memory o) {
        o.navBefore = dispatcher.accountedBalance();
        o.worthBefore = IERC4626(PRIME).convertToAssets(IERC20(PRIME).balanceOf(address(dispatcher)));
        vm.recordLogs();
        bool success;
        (success, , o.gasUsed) = _routeViaRouter(held, ARBITRUM_ROUTER, held.ccipReceiveGasLimit);
        assertTrue(success, "the receiver did not revert");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        CcipForkMessage[] memory out = _captured(logs, ARBITRUM_ROUTER, ETHEREUM_SELECTOR);
        o.residuals = _residuals(logs);
        assertEq(out.length, 1, "one response");
        o.response = _type(out[0]);
        o.tracked = dispatcher.isTrackedVault(PRIME);
        o.sharesLeft = IERC20(PRIME).balanceOf(address(dispatcher));
        o.navAfter = dispatcher.accountedBalance();
        emit log_named_uint("router gasUsed", o.gasUsed);
        emit log_named_uint("shares left", o.sharesLeft);
        emit log_named_uint("NAV before", o.navBefore);
        emit log_named_uint("NAV after", o.navAfter);
    }
}

contract VaultRemovalDustForkTest is VaultRemovalDustForkBase {
    function _forkBlocks() internal pure override returns (uint256, uint256) {
        return (ETHEREUM_FORK_BLOCK + 10, ARBITRUM_FORK_BLOCK + 10);
    }

    /// forge-config: default.isolate = true
    function testShouldAckARemovalDonatedOneWeiAtThreeMillion() public {
        _setUpWithShares(0, 1);
        Outcome memory o = _deliverMeasured();
        assertEq(uint8(o.response), uint8(CcipMsgType.COMMAND_ACK), "acked");
        assertFalse(o.tracked, "untracked");
        assertEq(o.sharesLeft, 1, "dust stays, redeem never called");
        assertEq(o.residuals.length, 1, "dust residual event");
        assertEq(o.residuals[0], abi.encode(PRIME, uint256(1), uint8(4), bytes4(0), true), "reason 4");
    }
}

contract VaultRemovalDustAboveBoundForkTest is VaultRemovalDustForkBase {
    function _forkBlocks() internal pure override returns (uint256, uint256) {
        return (ETHEREUM_FORK_BLOCK + 8, ARBITRUM_FORK_BLOCK + 8);
    }

    /// forge-config: default.isolate = true
    function testShouldAckARemovalDonatedJustAboveTheDustBoundAtThreeMillion() public {
        _setUpWithShares(10_200, 0); // ~0.0102 USDC: above the 0.01 bound, so the redeem runs
        Outcome memory o = _deliverMeasured();
        assertEq(uint8(o.response), uint8(CcipMsgType.COMMAND_ACK), "acked");
        assertFalse(o.tracked, "untracked");
        assertEq(o.sharesLeft, 0, "swept: nothing left");
        assertEq(o.residuals.length, 0, "no residual: swept");
        assertApproxEqAbs(o.navAfter, o.navBefore, 2, "the redeemed assets are in idle, NAV unchanged");
    }
}

contract VaultRemovalRealPositionForkTest is VaultRemovalDustForkBase {
    function _forkBlocks() internal pure override returns (uint256, uint256) {
        return (ETHEREUM_FORK_BLOCK + 9, ARBITRUM_FORK_BLOCK + 9);
    }

    /// @dev A realistic 100k USDC position of Prime (allocated into its markets, redeemable) is swept fully on a 3M
    ///      lane: ACK, untracked, nothing left, NAV about unchanged (the assets move to idle; the vault's own
    ///      valuation differs from the redeem payout by under 0.1%).
    /// forge-config: default.isolate = true
    function testShouldSweepARealPositionOfOneHundredThousandAtThreeMillion() public {
        _setUpWithShares(100_000e6, 0);
        Outcome memory o = _deliverMeasured();
        assertEq(uint8(o.response), uint8(CcipMsgType.COMMAND_ACK), "acked");
        assertFalse(o.tracked, "untracked");
        assertEq(o.sharesLeft, 0, "swept: nothing left");
        assertEq(o.residuals.length, 0, "no residual: swept");
        assertApproxEqRel(o.navAfter, o.navBefore, 0.001e18, "the redeemed assets are in idle, NAV about unchanged");
    }
}

contract VaultRemovalUnredeemableForkTest is VaultRemovalDustForkBase {
    /// @dev OpenZeppelin `Address.FailedInnerCall()`: an inner call of the vault's redeem ran out of the forwarded gas
    ///      and the vault bubbled that up. This is the revert data when the test has its fork to itself (alone or in a
    ///      suite of its own); empty data (a plain out-of-gas) was seen only while it shared a fork backend with
    ///      sibling tests. Either way it is the reason 5 gas-limited failure this test is about.
    bytes4 internal constant FAILED_INNER_CALL = 0x1425ea42;

    function _forkBlocks() internal pure override returns (uint256, uint256) {
        return (ETHEREUM_FORK_BLOCK + 7, ARBITRUM_FORK_BLOCK + 7);
    }

    /// @dev An UNREDEEMABLE position (exceeds the vault's liquidity), exercising the residual path: 2M USDC of Prime
    ///      shares is about 8x the vault's whole TVL (about 240k USDC), so an uncapped `redeem` of them reverts (Panic
    ///      0x11 at about 2.0M gas) whatever gas it gets; on the 3M lane the forwarded gas runs out first (less than
    ///      `VAULT_SWEEP_GAS`, so reason 5). It is NOT a realistic position: genuine allocated positions of 100k to
    ///      200k USDC are swept fine at 3M (see VaultRemovalRealPositionForkTest). The command is still ACKed
    ///      (variant B), the vault is untracked, and the shares left are reported by the residual event; the NAV
    ///      drops by exactly the residual's worth until the vault is allowlisted again.
    /// forge-config: default.isolate = true
    function testShouldAckARemovalOfAnUnredeemablePositionWithAResidualAtThreeMillion() public {
        uint256 shares = _setUpWithShares(2_000_000e6, 0);
        Outcome memory o = _deliverMeasured();
        assertEq(o.residuals.length, 1, "one residual event");
        assertEq(
            o.residuals[0],
            abi.encode(PRIME, shares, uint8(5), FAILED_INNER_CALL, true),
            "reason 5: redeem failed on the gas the 3M lane left"
        );
        assertEq(uint8(o.response), uint8(CcipMsgType.COMMAND_ACK), "acked");
        assertFalse(o.tracked, "untracked");
        assertEq(o.sharesLeft, shares, "the whole position is the residual");
        assertGt(o.navBefore, 1_999_000e6, "the position was in NAV");
        assertEq(o.navAfter, 0, "NAV impact equals the residual: it drops out of NAV");
        assertEq(o.navBefore - o.navAfter, o.worthBefore, "dropped value is the residual's worth");
    }
}
