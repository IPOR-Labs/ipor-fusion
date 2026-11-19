// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {CcipChainRescue} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {MockRemoteVault} from "./mocks/MockRemoteVault.sol";
import {CcipCommandLaneRealignTest} from "./CcipCommandLaneRealignTest.t.sol";

/// @title CcipRealignNewEpochZeroTest
/// @notice IL-9683 (Olympix L52): `REALIGN_COMMAND_LANE` must refuse a declared new config epoch of zero, which
///         would otherwise write 0 into the executor's epoch mirror with no way to arm a further rescue.
/// @dev Reuses the fixture of `CcipCommandLaneRealignTest` by inheriting it; the inherited tests are simply
///      re-run under this contract name. The expected error is built from its signature so the test also
///      compiles against the pre-fix library.
contract CcipRealignNewEpochZeroTest is CcipCommandLaneRealignTest {
    function _zeroEpochError() internal pure returns (bytes memory) {
        return abi.encodeWithSignature("RealignNewEpochZero(uint256)", REMOTE_CHAIN);
    }

    function _scheduleAndWait(uint256 arg_) internal returns (uint256 rescueId) {
        vm.prank(ADMIN);
        rescueId = executor.scheduleChainRescue(CcipChainRescue.REALIGN_COMMAND_LANE, REMOTE_CHAIN, arg_);
        vm.warp(block.timestamp + RESCUE_DELAY);
    }

    /// @notice The selector the SDK mirrors.
    function testShouldExposeTheRealignNewEpochZeroSelector() public pure {
        assertEq(bytes4(keccak256("RealignNewEpochZero(uint256)")), bytes4(0xe7635c04), "selector");
    }

    /// @notice A realign armed against the live mirrors that declares epoch 0 reverts and leaves both mirrors alone.
    function testShouldRevertRealignToEpochZeroAndLeaveMirrorsUntouched() public {
        uint64 sequenceBefore = executor.nextCommandSequence(REMOTE_CHAIN);
        uint64 epochBefore = executor.commandConfigEpoch(REMOTE_CHAIN);
        uint256 arg = _realignArg(0, 7);
        uint256 rescueId = _scheduleAndWait(arg);

        vm.prank(ADMIN);
        vm.expectRevert(_zeroEpochError());
        executor.executeChainRescue(rescueId, CcipChainRescue.REALIGN_COMMAND_LANE, REMOTE_CHAIN, arg);

        assertEq(executor.nextCommandSequence(REMOTE_CHAIN), sequenceBefore, "sequence mirror untouched");
        assertEq(executor.commandConfigEpoch(REMOTE_CHAIN), epochBefore, "epoch mirror untouched");
    }

    /// @notice Epoch 0 is refused whatever the declared sequence is (including 0).
    function testShouldRevertRealignToEpochZeroWithZeroSequence() public {
        uint256 arg = _realignArg(0, 0);
        uint256 rescueId = _scheduleAndWait(arg);

        vm.prank(ADMIN);
        vm.expectRevert(_zeroEpochError());
        executor.executeChainRescue(rescueId, CcipChainRescue.REALIGN_COMMAND_LANE, REMOTE_CHAIN, arg);
    }

    /// @notice The guard sits after the free-slot check: with a command active the older error still wins.
    function testShouldReportActiveCommandBeforeEpochZero() public {
        MockRemoteVault vault = _deployAndAllowVault();
        _fundRemoteIdle(100e18);
        _holdResponses();
        _sendDeposit(vault, 50e18);

        uint256 arg = _realignArg(0, 1);
        uint256 rescueId = _scheduleAndWait(arg);

        vm.prank(ADMIN);
        vm.expectPartialRevert(_activeCommandSelector());
        executor.executeChainRescue(rescueId, CcipChainRescue.REALIGN_COMMAND_LANE, REMOTE_CHAIN, arg);
    }

    /// @notice The guard sits after the binding check: a stale expected pair still reports `RealignStateMoved`.
    function testShouldReportStateMovedBeforeEpochZero() public {
        uint64 epoch = executor.commandConfigEpoch(REMOTE_CHAIN);
        uint64 sequence = executor.nextCommandSequence(REMOTE_CHAIN);
        uint256 arg = _realignArgFrom(epoch + 1, sequence, 0, 5);
        uint256 rescueId = _scheduleAndWait(arg);

        vm.prank(ADMIN);
        vm.expectPartialRevert(bytes4(keccak256("RealignStateMoved(uint256,uint64,uint64,uint64,uint64)")));
        executor.executeChainRescue(rescueId, CcipChainRescue.REALIGN_COMMAND_LANE, REMOTE_CHAIN, arg);
    }

    /// @notice A non-zero declared epoch still realigns (the smallest accepted value, 1).
    function testShouldStillRealignToEpochOne() public {
        _realign(1, 7);

        assertEq(executor.commandConfigEpoch(REMOTE_CHAIN), 1, "epoch mirror");
        assertEq(executor.nextCommandSequence(REMOTE_CHAIN), 7, "sequence mirror");
    }

    function _activeCommandSelector() internal pure returns (bytes4) {
        return bytes4(keccak256("ActiveCommandExists(uint256,bytes32)"));
    }
}
