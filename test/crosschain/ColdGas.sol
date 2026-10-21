// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";

/// @title ColdGas
/// @notice Cold-state gas measurement helpers for the IL-8625 calibration (`CommandPreCheckPinTest`,
///         `StargatePreCheckForkTest`). `foundry.toml` has `isolate = false`, so a whole test is ONE transaction and every
///         slot and account touched earlier (bring-up, `_verify`, a previous trial) is WARM, which understates what a real
///         `lzReceive` costs by a lot (on the fork the ULN fee quote alone is about 204k gas cold and 72k warm).
///         The measurements are taken with forge 1.8.5 semantics (the CI forge). forge 1.7.1's `vm.cool` left the LayerZero
///         fee-quote path warm and under-measured the first delivery by about 130k, so the tests assert margins that are
///         valid under the CI forge and are conservative under 1.7.1 (no version-specific branches).
/// @dev `vm.cool(address)` clears the EIP-2929 warmth of every STORAGE SLOT of an account (values are kept) but, as probed
///      in forge 1.7.1 and 1.8.5, not the account's own warmth (a call to a "cooled" account costs the same). Only `vm.revertToState`
///      to a point before the first access, or a NEW fork, resets account warmth; `vm.selectFork` does not. The cold
///      account access cost (2,600 vs 100) is therefore added analytically: `COLD_ACCOUNT_EXTRA` per distinct address the
///      delivery touches (`_coldAccountPenalty`), which double-counts the accounts that were already cold (fresh fork) and
///      so errs on the conservative side. The touched set is recorded from one run of the delivery under
///      `startStateDiffRecording` and kept in MEMORY by the caller: a `vm.revertToState` after the recording would undo any
///      storage write of this contract.
abstract contract ColdGas is Test {
    /// @dev Cold account access (2,600) minus warm (100).
    uint256 internal constant COLD_ACCOUNT_EXTRA = 2_500;

    /// @dev Start recording the accounts one delivery touches. Pair with `_endRecording`.
    function _beginRecording() internal {
        vm.startStateDiffRecording();
    }

    /// @return touched The distinct accounts (precompiles, cheatcode, console and this contract excluded) the recording saw.
    function _endRecording() internal returns (address[] memory touched) {
        VmSafe.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        address[] memory buffer = new address[](accesses.length * 2);
        uint256 n;
        for (uint256 i; i < accesses.length; ++i) {
            n = _add(buffer, n, accesses[i].account);
            for (uint256 j; j < accesses[i].storageAccesses.length; ++j) {
                n = _add(buffer, n, accesses[i].storageAccesses[j].account);
            }
        }
        touched = new address[](n);
        for (uint256 i; i < n; ++i) {
            touched[i] = buffer[i];
        }
    }

    function _add(address[] memory buffer_, uint256 n_, address a_) private view returns (uint256) {
        if (
            uint160(a_) <= 0x100 || a_ == address(vm) || a_ == address(this)
                || a_ == 0x000000000000000000636F6e736F6c652e6c6f67
        ) {
            return n_;
        }
        for (uint256 i; i < n_; ++i) {
            if (buffer_[i] == a_) return n_;
        }
        buffer_[n_] = a_;
        return n_ + 1;
    }

    /// @dev Marks every slot of every given account cold again.
    function _cool(address[] memory touched_) internal {
        for (uint256 i; i < touched_.length; ++i) {
            vm.cool(touched_[i]);
        }
    }

    /// @dev Gas the cold account accesses add on top of a measurement taken with `_cool`.
    function _coldAccountPenalty(address[] memory touched_) internal pure returns (uint256) {
        return touched_.length * COLD_ACCOUNT_EXTRA;
    }
}
