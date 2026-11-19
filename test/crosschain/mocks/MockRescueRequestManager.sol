// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

/// @title MockRescueRequestManager
/// @notice Stand-in for a WithdrawManager as the target of a `requestShares(uint256)` rescue (IL-9654). The vault it
///         reports through `getPlasmaVaultAddress()` is settable, and so is the shape of the answer, so the
///         `requestShares` rule of `RescueLogicLib` can be driven through every accepted and refused answer.
/// @dev `getPlasmaVaultAddress()` is served by the fallback so the raw returndata can be shaped freely.
contract MockRescueRequestManager {
    enum Mode {
        Normal, // one word: the vault
        Revert, // the getter reverts
        Empty, // the getter succeeds with no returndata
        TwoWords, // 64 bytes of returndata
        DirtyUpperBits // one word, the vault with a bit set above bit 159
    }

    error GetterReverted();
    error UnknownSelector(bytes4 selector);

    bytes4 private constant _GET_PLASMA_VAULT_ADDRESS_SELECTOR = 0x0bdcc726;

    address public vault;
    Mode public mode;

    uint256 public requestCount;
    uint256 public lastShares;
    address public lastCaller;

    constructor(address vault_) {
        vault = vault_;
    }

    function setVault(address vault_) external {
        vault = vault_;
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    /// @notice Records the call; it moves no shares and charges no fee.
    function requestShares(uint256 shares_) external {
        ++requestCount;
        lastShares = shares_;
        lastCaller = msg.sender;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        if (msg.sig != _GET_PLASMA_VAULT_ADDRESS_SELECTOR) revert UnknownSelector(msg.sig);
        Mode current = mode;
        if (current == Mode.Revert) revert GetterReverted();
        if (current == Mode.Empty) return "";
        if (current == Mode.TwoWords) return abi.encode(vault, vault);
        if (current == Mode.DirtyUpperBits) return abi.encode((uint256(1) << 160) | uint256(uint160(vault)));
        return abi.encode(vault);
    }
}
