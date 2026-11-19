// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {CcipForkBase, CcipForkMessage} from "./CcipForkBase.sol";
import {CcipMsgType} from "../../../contracts/crosschain/ccip/lib/CcipMessages.sol";
import {SweepFloor} from "../../../contracts/crosschain/lib/CrosschainMessages.sol";
import {CrosschainVaultActionLib} from "../../../contracts/crosschain/lib/CrosschainVaultActionLib.sol";

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

    /// @dev The vault under test; PRIME unless a test overrides it.
    function _vault() internal view virtual returns (address) {
        return PRIME;
    }

    /// @dev Runs on the Arbitrum fork before the dispatcher is created (a test deploys its own vault here).
    function _prepareVault() internal virtual {}

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
        return _setUpWithSharesAndFloors(assetsWorth_, shares_, new SweepFloor[](0));
    }

    /// @dev `_setUpWithShares` whose removal carries `floors_` (IL-9629, `updateVaultsWithSweepFloors`, LOCAL decimals)
    ///      when the list is not empty.
    function _setUpWithSharesAndFloors(
        uint256 assetsWorth_,
        uint256 shares_,
        SweepFloor[] memory floors_
    ) internal returns (uint256 given) {
        _deployStack();
        _warmExecutorStorage();
        vm.selectFork(arbFork);
        _prepareVault();
        address[] memory vaults = new address[](1);
        vaults[0] = _vault();
        // A floor entry for address(0) stands for the vault under test, which a test may deploy only in the hook above.
        for (uint256 i; i < floors_.length; ++i) {
            if (floors_[i].vault == address(0)) floors_[i].vault = _vault();
        }
        require(IERC4626(_vault()).asset() == ARBITRUM_USDC, "usdc vault");
        vm.selectFork(ethFork);
        _startCapture();
        factory.requestDispatcher(address(executor), ARBITRUM_CHAIN_ID, vaults, MAX_FEE);
        CcipForkMessage memory create = _sendFromExecutor();
        _roundTrip(create, "create", CcipMsgType.DEPLOYMENT_ACK, "ack");
        vm.selectFork(arbFork);
        assertTrue(dispatcher.isTrackedVault(_vault()), "tracked");
        vm.deal(address(dispatcher), 1 ether);

        given = shares_ != 0 ? shares_ : IERC4626(_vault()).convertToShares(assetsWorth_);
        if (given != 0) deal(_vault(), address(dispatcher), given);
        assertEq(IERC20(_vault()).balanceOf(address(dispatcher)), given, "dealt");

        vm.selectFork(ethFork);
        _startCapture();
        if (floors_.length == 0) {
            executor.updateVaults(ARBITRUM_CHAIN_ID, vaults, false, false, MAX_FEE, FEE_TOKEN, 0);
        } else {
            executor.updateVaultsWithSweepFloors(
                ARBITRUM_CHAIN_ID,
                vaults,
                false,
                false,
                floors_,
                MAX_FEE,
                FEE_TOKEN,
                0
            );
        }
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
        o.worthBefore = IERC4626(_vault()).convertToAssets(IERC20(_vault()).balanceOf(address(dispatcher)));
        vm.recordLogs();
        bool success;
        (success, , o.gasUsed) = _routeViaRouter(held, ARBITRUM_ROUTER, held.ccipReceiveGasLimit);
        assertTrue(success, "the receiver did not revert");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        CcipForkMessage[] memory out = _captured(logs, ARBITRUM_ROUTER, ETHEREUM_SELECTOR);
        o.residuals = _residuals(logs);
        assertEq(out.length, 1, "one response");
        o.response = _type(out[0]);
        o.tracked = dispatcher.isTrackedVault(_vault());
        o.sharesLeft = IERC20(_vault()).balanceOf(address(dispatcher));
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
    ///      and the vault bubbled that up. This was the revert data when the test had its fork to itself; empty data (a
    ///      plain out-of-gas) was seen while it shared a fork backend with sibling tests. IL-9629 (two more stored
    ///      payload words, about 48k less gas left for the redeem on the same 3M lane) moved the point where the gas runs
    ///      out, and the redeem now reverts with empty data even alone (forge 1.9.0, 2026-11-10). Which of the two it is
    ///      depends only on where in the vault's call tree the forwarded gas ends; both are the reason 5 gas-limited
    ///      failure this test is about, so both are accepted and everything else in the event is pinned exactly.
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
        (, , , bytes4 redeemError, ) = abi.decode(o.residuals[0], (address, uint256, uint8, bytes4, bool));
        assertTrue(redeemError == FAILED_INNER_CALL || redeemError == bytes4(0), "out-of-gas revert data");
        assertEq(
            o.residuals[0],
            abi.encode(PRIME, shares, uint8(5), redeemError, true),
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

/// @dev IL-9629: the removal of a realistic position with a sweep FLOOR over the real CCIP transport on a 3M lane. The
///      floored redeem runs inside the dispatcher's `sweepRedeemSelf` frame (one more call frame than the IL-8784 sweep).
abstract contract VaultRemovalFloorForkBase is VaultRemovalDustForkBase {
    function _floorOnPrime(uint256 minAssets_) internal pure returns (SweepFloor[] memory floors) {
        floors = new SweepFloor[](1);
        floors[0] = SweepFloor({vault: PRIME, minAssets: minAssets_});
    }
}

contract VaultRemovalFloorReachedForkTest is VaultRemovalFloorForkBase {
    function _forkBlocks() internal pure override returns (uint256, uint256) {
        return (ETHEREUM_FORK_BLOCK + 11, ARBITRUM_FORK_BLOCK + 11);
    }

    /// @dev A 100k USDC Prime position removed with a 99k floor: the redeem pays about 100k, the floor is met, and the
    ///      whole position is swept on the 3M lane exactly as without a floor (ACK, untracked, NAV about unchanged).
    /// forge-config: default.isolate = true
    function testShouldSweepARealPositionWhoseFloorIsReachedAtThreeMillion() public {
        _setUpWithSharesAndFloors(100_000e6, 0, _floorOnPrime(99_000e6));
        Outcome memory o = _deliverMeasured();
        assertEq(uint8(o.response), uint8(CcipMsgType.COMMAND_ACK), "acked");
        assertFalse(o.tracked, "untracked");
        assertEq(o.sharesLeft, 0, "swept: nothing left");
        assertEq(o.residuals.length, 0, "no residual: swept");
        assertApproxEqRel(o.navAfter, o.navBefore, 0.001e18, "the redeemed assets are in idle, NAV about unchanged");
    }
}

contract VaultRemovalFloorNotReachedForkTest is VaultRemovalFloorForkBase {
    function _forkBlocks() internal pure override returns (uint256, uint256) {
        return (ETHEREUM_FORK_BLOCK + 12, ARBITRUM_FORK_BLOCK + 12);
    }

    /// @dev The same position removed with a floor above what the redeem pays (101k): the redeem is rolled back, the
    ///      command is still ACKed, the vault leaves the allowlist but stays tracked with all its shares and the NAV is
    ///      unchanged; the residual event reports reason 6 with the `SweepBelowMinimum` selector and `untracked` false.
    /// forge-config: default.isolate = true
    function testShouldKeepARealPositionTrackedWhenItsFloorIsNotReachedAtThreeMillion() public {
        uint256 shares = _setUpWithSharesAndFloors(100_000e6, 0, _floorOnPrime(101_000e6));
        Outcome memory o = _deliverMeasured();
        assertEq(uint8(o.response), uint8(CcipMsgType.COMMAND_ACK), "acked");
        assertTrue(o.tracked, "still tracked");
        assertFalse(dispatcher.isAllowedVault(PRIME), "off the allowlist");
        assertEq(o.sharesLeft, shares, "no share sold");
        assertEq(o.navAfter, o.navBefore, "the position still counts in NAV");
        assertEq(o.residuals.length, 1, "one residual event");
        assertEq(
            o.residuals[0],
            abi.encode(PRIME, shares, uint8(6), CrosschainVaultActionLib.SweepBelowMinimum.selector, false),
            "reason 6: below the floor, kept tracked"
        );
    }
}

contract VaultRemovalFloorUnredeemableForkTest is VaultRemovalFloorForkBase {
    /// @dev See `VaultRemovalUnredeemableForkTest.FAILED_INNER_CALL`.
    bytes4 internal constant FAILED_INNER_CALL = 0x1425ea42;

    function _forkBlocks() internal pure override returns (uint256, uint256) {
        return (ETHEREUM_FORK_BLOCK + 13, ARBITRUM_FORK_BLOCK + 13);
    }

    /// @dev IL-9699: the UNREDEEMABLE 2M USDC position (about 8x the vault's TVL) removed with a non-zero floor, the
    ///      expensive revert on the 3M CCIP lane. The floored redeem runs out of the forwarded gas (every sweep on this
    ///      lane is gas-limited, below `VAULT_SWEEP_GAS`). The vault bubbles up `FailedInnerCall` or reverts with empty
    ///      data, depending on where in its call tree the gas ends. The rule follows the data, not the gas:
    ///      - `FailedInnerCall` (error data present): reason 6, the vault stays tracked, off the allowlist, shares and
    ///        NAV unchanged (IL-9694 D-002);
    ///      - empty data (plain out-of-gas): reason 5, untracked, the shares are the residual (D-065).
    ///      Either way COMMAND_ACK is delivered. Measured router gas on the 3M lane: about 2.74M (forge 1.9.0,
    ///      2026-11-11), asserted only against the lane limit.
    /// forge-config: default.isolate = true
    function testShouldAckAnUnredeemablePositionWithAFloorAndFollowTheRevertDataAtThreeMillion() public {
        uint256 shares = _setUpWithSharesAndFloors(2_000_000e6, 0, _floorOnPrime(1_000_000e6));
        Outcome memory o = _deliverMeasured();
        assertEq(uint8(o.response), uint8(CcipMsgType.COMMAND_ACK), "acked");
        assertEq(o.residuals.length, 1, "one residual event");
        (, , , bytes4 redeemError, ) = abi.decode(o.residuals[0], (address, uint256, uint8, bytes4, bool));
        assertTrue(redeemError == FAILED_INNER_CALL || redeemError == bytes4(0), "out-of-gas revert data");
        assertEq(o.sharesLeft, shares, "no share sold");
        assertLe(o.gasUsed, 3_000_000, "within the 3M route");
        if (redeemError == FAILED_INNER_CALL) {
            assertEq(
                o.residuals[0],
                abi.encode(PRIME, shares, uint8(6), FAILED_INNER_CALL, false),
                "reason 6: error data under a floor keeps the vault tracked"
            );
            assertTrue(o.tracked, "still tracked");
            assertFalse(dispatcher.isAllowedVault(PRIME), "off the allowlist");
            assertEq(o.navAfter, o.navBefore, "the position still counts in NAV");
        } else {
            assertEq(
                o.residuals[0],
                abi.encode(PRIME, shares, uint8(5), bytes4(0), true),
                "reason 5: empty data untracks"
            );
            assertFalse(o.tracked, "untracked");
            assertEq(o.navAfter, 0, "the residual drops out of NAV");
        }
    }
}

/// @dev A vault whose `redeem` burns almost all the gas it is given in a nested call that returns, then reverts with a
///      custom error: a deterministic expensive revert that always carries error data.
contract ExpensiveRevertingVault {
    error ExpensiveVaultFailure();

    address public immutable asset;
    mapping(address => uint256) public balanceOf;

    constructor(address asset_) {
        asset = asset_;
    }

    function convertToAssets(uint256 shares_) external pure returns (uint256) {
        return shares_;
    }

    function maxRedeem(address owner_) external view returns (uint256) {
        return balanceOf[owner_];
    }

    function burn() external view {
        assembly {
            for {} gt(gas(), 20000) {} {}
        }
    }

    function redeem(uint256, address, address) external returns (uint256) {
        (bool ok, ) = address(this).call{gas: gasleft() - 50_000}(abi.encodeCall(this.burn, ()));
        ok;
        revert ExpensiveVaultFailure();
    }
}

contract VaultRemovalFloorExpensiveRevertForkTest is VaultRemovalFloorForkBase {
    ExpensiveRevertingVault internal mock;

    function _forkBlocks() internal pure override returns (uint256, uint256) {
        return (ETHEREUM_FORK_BLOCK + 14, ARBITRUM_FORK_BLOCK + 14);
    }

    function _vault() internal view override returns (address) {
        return address(mock);
    }

    function _prepareVault() internal override {
        mock = new ExpensiveRevertingVault(ARBITRUM_USDC);
    }

    /// @dev IL-9694 D-002 and "measure COMMAND_ACK gas after an expensive revert on the 3M route": a vault whose
    ///      redeem burns nearly all forwarded gas in a nested call and then reverts with its own custom error, removed
    ///      with a non-zero floor on the real 3M lane. The revert always carries data, so the result is deterministic:
    ///      reason 6 with that selector, the vault stays tracked, off the allowlist, shares and NAV unchanged, and the
    ///      COMMAND_ACK is still delivered within the lane limit.
    /// forge-config: default.isolate = true
    function testShouldKeepAVaultTrackedWhenItsRedeemBurnsGasThenRevertsWithAnErrorUnderAFloorAtThreeMillion() public {
        uint256 shares = 100_000e6;
        SweepFloor[] memory floors = new SweepFloor[](1);
        floors[0] = SweepFloor({vault: address(0), minAssets: 50_000e6});
        _setUpWithSharesAndFloors(0, shares, floors);
        Outcome memory o = _deliverMeasured();
        assertEq(uint8(o.response), uint8(CcipMsgType.COMMAND_ACK), "acked");
        assertEq(o.residuals.length, 1, "one residual event");
        assertEq(
            o.residuals[0],
            abi.encode(address(mock), shares, uint8(6), ExpensiveRevertingVault.ExpensiveVaultFailure.selector, false),
            "reason 6 with the vault's own error, still tracked"
        );
        assertTrue(o.tracked, "still tracked");
        assertFalse(dispatcher.isAllowedVault(address(mock)), "off the allowlist");
        assertEq(o.sharesLeft, shares, "no share sold");
        assertEq(o.navAfter, o.navBefore, "the position still counts in NAV");
        assertGt(o.gasUsed, 1_500_000, "the revert was expensive");
        assertLe(o.gasUsed, 3_000_000, "within the 3M route");
    }
}
