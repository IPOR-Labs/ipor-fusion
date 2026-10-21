// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {EnsoExecutor, EnsoExecutorData} from "./EnsoExecutor.sol";
import {EnsoSubstrateLib, EnsoSubstrate} from "./lib/EnsoSubstrateLib.sol";
import {EnsoStorageLib} from "./lib/EnsoStorageLib.sol";

/// @notice Data structure used for entering an Enso shortcut operation
/// @dev This structure contains all necessary data for executing an Enso routing operation via the executor
/// @param tokenOut_ The token address that will be transferred from PlasmaVault to EnsoExecutor
/// @param amountOut_ The amount of tokenOut to transfer to the executor (in tokenOut decimals)
/// @param wEthAmount_ The amount of WETH to unwrap to ETH and transfer to the executor (in WETH decimals, 0 if not needed)
/// @param accountId_ The bytes32 value representing an API user identifier from Enso
/// @param requestId_ The bytes32 value representing a unique API request identifier from Enso
/// @param commands_ An array of bytes32 values encoding the sequence of calls to execute (target, selector, flags)
/// @param state_ An array of bytes providing the calldata parameters for each corresponding command
/// @param tokensToReturn_ Array of token addresses expected to be returned to PlasmaVault after
///        execution. A non-empty array declares that the route's outputs are delivered to
///        PlasmaVault within this `enter()` call, so no pending balance is recorded for it.
///        Leave empty for cross-chain / delayed legs, where the pending-balance placeholder
///        must be kept until a later `exit()`.
/// @param tokensToRevoke_ Array of token addresses whose allowance to the paired spender in
///        `spendersToRevoke_` must be revoked (set to 0) after the shortcut executes. Pair i is
///        (tokensToRevoke_[i], spendersToRevoke_[i]). Declared by the caller (the alpha), who
///        builds the shortcut and therefore knows every approval it makes; revocation is
///        unconditional and not substrate-validated, since revoking to zero is strictly
///        risk-reducing. Any approval whose pair is not declared here persists on the executor
///        indefinitely - see contracts/fuses/enso/README.md.
/// @param spendersToRevoke_ Array of spender addresses paired with `tokensToRevoke_` (see above)
struct EnsoFuseEnterData {
    address tokenOut;
    uint256 amountOut;
    uint256 wEthAmount;
    bytes32 accountId;
    bytes32 requestId;
    bytes32[] commands;
    bytes[] state;
    address[] tokensToReturn;
    address[] tokensToRevoke;
    address[] spendersToRevoke;
}

/// @notice Data structure used for exiting Enso positions and withdrawing tokens from the executor
/// @dev This structure is used to specify which tokens should be withdrawn back to PlasmaVault
/// @param tokens_ Array of token addresses to withdraw from EnsoExecutor back to PlasmaVault
struct EnsoFuseExitData {
    address[] tokens;
}

/// @title EnsoFuse
/// @notice This contract is designed to execute Enso shortcuts through a delegatecall-based executor
contract EnsoFuse is IFuseCommon {
    using SafeERC20 for ERC20;

    event EnsoFuseEnter(
        address version,
        bytes32 accountId,
        bytes32 requestId,
        address[] tokensToTransfer,
        uint256[] amounts
    );

    event EnsoFuseExit(address version, address[] tokens);

    event EnsoExecutorCreated(address executor, address plasmaVault, address delegateEnsoShortcuts, address weth);

    error EnsoFuseUnsupportedAsset(address asset);
    error EnsoFuseUnsupportedCommand(address target, bytes4 selector);
    error EnsoFuseInvalidWethAddress();
    error EnsoFuseInvalidExecutorAddress();
    error EnsoFuseInvalidArrayLength();
    error EnsoFuseInvalidAddress();
    error EnsoFuseInvalidTokenOut();
    error EnsoFuseInvalidCommandsLength();
    error EnsoFuseInvalidStateIndex(uint256 index);
    error EnsoFuseInvalidStateCalldata(uint256 index);
    error EnsoFuseStateSlotOverwritten(uint256 index);

    /// @notice Flag indicating a standard CALL operation (state-changing, no ETH transfer)
    /// @dev This flag is extracted from command byte at position 32 and used to route the execution type
    uint256 private constant FLAG_CT_CALL = 0x01;

    /// @notice Flag indicating a STATICCALL operation (read-only, no state changes)
    /// @dev STATICCALL operations are skipped during substrate validation as they cannot modify state
    uint256 private constant FLAG_CT_STATICCALL = 0x02;

    /// @notice Flag indicating a CALL operation with ETH value transfer
    /// @dev Similar to FLAG_CT_CALL but includes msg.value in the call
    uint256 private constant FLAG_CT_VALUECALL = 0x03;

    /// @notice Bit mask to extract the call type from command flags
    /// @dev Applied via bitwise AND to isolate the lower 2 bits containing call type information
    uint256 private constant FLAG_CT_MASK = 0x03;

    /// @notice Flag indicating that the argument indices for this command are stored in the
    ///         next array element instead of inline in this word
    /// @dev The flagged command word is still a real call and MUST be validated like any other
    ///      command (target/selector are extracted from it and dispatched by the executor's VM
    ///      exactly as for a non-extended command). Only the FOLLOWING array element is metadata
    ///      (raw argument indices, not a call) and must be skipped during validation.
    uint256 private constant FLAG_EXTENDED_COMMAND = 0x40;

    /// @notice Flag indicating that the command takes its WHOLE calldata from a single state slot
    /// @dev When set, the executor's VM ignores the selector encoded in the command word and calls
    ///      the target with `state[idx & IDX_VALUE_MASK]` verbatim, where `idx` is the first
    ///      argument-index byte (the SECOND one for VALUECALL, whose first index carries the ETH
    ///      value). Validating `bytes4(command)` in that case would validate a selector the VM
    ///      never dispatches and would degrade the (target, selector) allowlist to target-only, so
    ///      the effective selector is read from the state slot instead.
    uint256 private constant FLAG_DATA = 0x20;

    /// @notice Bit mask applied to an argument-index byte to obtain the state slot number
    /// @dev Mirrors `CommandBuilder.IDX_VALUE_MASK` in the executor's VM; the high bit of an index
    ///      byte is the variable-length marker, not part of the slot number.
    uint256 private constant IDX_VALUE_MASK = 0x7f;

    /// @notice Flag indicating that the command's return data is stored as a raw tuple
    /// @dev Mirrors `VM.FLAG_TUPLE_RETURN`. Relevant only to write tracking: a tuple write always
    ///      lands in `state[out & IDX_VALUE_MASK]` and never replaces the whole state array.
    uint256 private constant FLAG_TUPLE_RETURN = 0x80;

    /// @notice Output-index value meaning "discard the return data"
    /// @dev Mirrors `CommandBuilder.IDX_END_OF_ARGS`.
    uint256 private constant IDX_END_OF_ARGS = 0xff;

    /// @notice Output-index value meaning "replace the whole state array with the return data"
    /// @dev Mirrors `CommandBuilder.IDX_USE_STATE` (non-tuple writes only).
    uint256 private constant IDX_USE_STATE = 0xfe;

    /// @notice Bit set in the written-slots bitmap once any earlier command replaced the whole state
    /// @dev Slot numbers are masked with IDX_VALUE_MASK, so bits 0-127 track individual slots and
    ///      this bit can never collide with one of them.
    uint256 private constant STATE_REPLACED_BIT = 1 << 128;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address public immutable WETH;
    address public immutable DELEGATE_ENSO_SHORTCUTS;

    constructor(uint256 marketId_, address weth_, address delegateEnsoShortcuts_) {
        if (weth_ == address(0)) {
            revert EnsoFuseInvalidWethAddress();
        }

        if (delegateEnsoShortcuts_ == address(0)) {
            revert EnsoFuseInvalidAddress();
        }

        VERSION = address(this);
        MARKET_ID = marketId_;
        WETH = weth_;
        DELEGATE_ENSO_SHORTCUTS = delegateEnsoShortcuts_;
    }

    /// @notice Execute an Enso shortcut through the executor
    /// @param data_ The data structure containing all parameters for the Enso operation
    function enter(EnsoFuseEnterData calldata data_) external {
        if (data_.tokenOut == address(0)) {
            revert EnsoFuseInvalidTokenOut();
        }

        if (data_.tokensToRevoke.length != data_.spendersToRevoke.length) {
            revert EnsoFuseInvalidArrayLength();
        }

        _validateEnterSubstrates(data_);
        _validateCommands(data_.commands, data_.state);

        address executor = _createExecutorWhenNotExists();

        if (data_.amountOut > 0) {
            ERC20(data_.tokenOut).safeTransfer(executor, data_.amountOut);
        }

        if (data_.wEthAmount > 0) {
            ERC20(WETH).safeTransfer(executor, data_.wEthAmount);
        }

        // Execute Enso shortcut via executor
        EnsoExecutor(payable(executor)).execute(
            EnsoExecutorData({
                accountId: data_.accountId,
                requestId: data_.requestId,
                commands: data_.commands,
                state: data_.state,
                tokensToReturn: data_.tokensToReturn,
                wEthAmount: data_.wEthAmount,
                tokenOut: data_.tokenOut,
                amountOut: data_.amountOut,
                tokensToRevoke: data_.tokensToRevoke,
                spendersToRevoke: data_.spendersToRevoke
            })
        );

        emit EnsoFuseEnter(VERSION, data_.accountId, data_.requestId, new address[](0), new uint256[](0));
    }

    /// @notice Withdraw tokens from EnsoExecutor back to PlasmaVault
    /// @param data_ The data structure containing token addresses to withdraw
    function exit(EnsoFuseExitData calldata data_) external {
        _validateExitSubstrates(data_.tokens);

        address executor = EnsoStorageLib.getEnsoExecutor();

        if (executor == address(0)) {
            revert EnsoFuseInvalidExecutorAddress();
        }

        EnsoExecutor(payable(executor)).withdrawAll(data_.tokens);

        emit EnsoFuseExit(VERSION, data_.tokens);
    }

    /// @notice Validate that all substrates (tokens and return tokens) are granted
    /// @param data_ The data structure containing all parameters for validation
    function _validateEnterSubstrates(EnsoFuseEnterData calldata data_) private view {
        // Validate tokenOut substrate
        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                EnsoSubstrateLib.encode(
                    EnsoSubstrate({target_: data_.tokenOut, functionSelector_: ERC20.transfer.selector})
                )
            )
        ) {
            revert EnsoFuseUnsupportedAsset(data_.tokenOut);
        }

        // Validate WETH substrate if wEthAmount > 0
        if (data_.wEthAmount > 0) {
            if (
                !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                    MARKET_ID,
                    EnsoSubstrateLib.encode(EnsoSubstrate({target_: WETH, functionSelector_: ERC20.transfer.selector}))
                )
            ) {
                revert EnsoFuseUnsupportedAsset(WETH);
            }
        }

        // Validate tokensToReturn substrates
        uint256 tokensToReturnLength = data_.tokensToReturn.length;
        for (uint256 i; i < tokensToReturnLength; ++i) {
            if (
                !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                    MARKET_ID,
                    EnsoSubstrateLib.encode(
                        EnsoSubstrate({target_: data_.tokensToReturn[i], functionSelector_: ERC20.transfer.selector})
                    )
                )
            ) {
                revert EnsoFuseUnsupportedAsset(data_.tokensToReturn[i]);
            }
        }
    }

    /// @notice Validate that all commands (CALL, DELEGATECALL and VALUECALL) are granted in substrates
    /// @param commands_ Array of encoded commands to validate
    /// @param state_ Array of calldata slots the executor's VM reads arguments from; needed because
    ///        a FLAG_DATA command takes its whole calldata - and therefore its effective selector -
    ///        from one of these slots instead of from the command word
    /// @dev Skips validation for STATICCALL (read-only, cannot move value or change state).
    ///      For a command carrying FLAG_EXTENDED_COMMAND, the command word ITSELF is still a real
    ///      call and is validated like any other command; only the FOLLOWING array element (the
    ///      argument-index word) is metadata and is skipped. The extended-flag check and the
    ///      call-type check are independent: an extended command always consumes exactly one extra
    ///      array element regardless of its call type.
    ///      The argument-index word is resolved BEFORE the substrate check, because for a
    ///      FLAG_DATA command the effective selector is reached through its first index byte, which
    ///      for an extended command lives in the NEXT array element.
    ///      The VM writes every command's return data back into `state` (output byte 11) before the
    ///      next command runs, so the selector read out of `state_` is only the one dispatched if no
    ///      EARLIER command wrote that slot or replaced the whole array. Every command's write -
    ///      including unvalidated STATICCALLs, whose return data the caller fully controls - is
    ///      recorded in `writtenSlots`, and a FLAG_DATA command reading a written slot is rejected.
    function _validateCommands(bytes32[] calldata commands_, bytes[] calldata state_) private view {
        uint256 commandsLength = commands_.length;
        bytes32 command;
        uint256 flags;
        uint256 callType;
        bool extended;
        address target;
        bytes4 selector;
        uint256 writtenSlots;
        for (uint256 i; i < commandsLength; ++i) {
            command = commands_[i];

            // Extract flags (byte at position 32)
            flags = uint256(uint8(bytes1(command << 32)));
            callType = flags & FLAG_CT_MASK;
            extended = flags & FLAG_EXTENDED_COMMAND != 0;

            // An extended command always consumes one extra array element; a FLAG_DATA command
            // also READS its state index from that element, so its presence is checked up front.
            if (extended && i + 1 >= commandsLength) {
                revert EnsoFuseInvalidCommandsLength();
            }

            // The command word is always a real call dispatched by the executor's VM, unless it
            // is a read-only STATICCALL. This includes FLAG_CT_DELEGATECALL (0x00): on the
            // production VM that call type reverts with "Invalid calltype", so validating it is
            // a cheap hedge against a future VM that re-enables it rather than a live
            // mitigation - either way it is not exempt from the substrate check.
            if (callType != FLAG_CT_STATICCALL) {
                // Extract target address and function selector. With FLAG_DATA the VM discards
                // the selector in the command word and calls the target with a raw state slot,
                // so the selector that actually reaches the target is read from that slot. The
                // argument-index word is the NEXT array element when extended, otherwise the
                // command word past its selector and flags byte (the VM's SHORT_COMMAND_FILL
                // only touches trailing bytes, so the leading index bytes read identically).
                target = address(uint160(uint256(command)));
                selector = flags & FLAG_DATA == 0
                    ? bytes4(command)
                    : _effectiveSelectorFromState(
                        state_,
                        extended ? commands_[i + 1] : command << 40,
                        callType,
                        writtenSlots
                    );

                // Validate substrate is granted
                if (
                    !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                        MARKET_ID,
                        EnsoSubstrateLib.encodeRaw(target, selector)
                    )
                ) {
                    revert EnsoFuseUnsupportedCommand(target, selector);
                }
            }

            // Recorded after this command's own FLAG_DATA check (the VM dispatches before it writes)
            // and for every call type, STATICCALL included.
            writtenSlots = _recordStateWrite(writtenSlots, command, flags);

            // If extended, the NEXT array element holds the argument indices (not a call) and
            // must be skipped, independent of this command's call type.
            if (extended) {
                unchecked {
                    ++i; // Skip next command which contains indices
                }
            }
        }
    }

    /// @notice Resolve the selector a FLAG_DATA command actually dispatches, from the state slot
    ///         the executor's VM would pass as raw calldata
    /// @param state_ Array of calldata slots supplied with the shortcut
    /// @param indices_ Argument-index word for the command being validated
    /// @param callType_ Call type of the command (VALUECALL consumes one extra leading index)
    /// @param writtenSlots_ Bitmap of state slots written by earlier commands (see `_recordStateWrite`)
    /// @return selector The first four bytes of the referenced state slot
    /// @dev VALUECALL spends its FIRST index byte on the ETH value, so its calldata index is the
    ///      SECOND byte - matching `indices << 8` in the VM. A slot shorter than four bytes carries
    ///      no selector at all and cannot be checked against the allowlist, so it is rejected
    ///      rather than padded. A slot an earlier command wrote (or any slot, once the whole state
    ///      was replaced) no longer holds the supplied bytes at dispatch time, so its supplied
    ///      selector proves nothing and the command is rejected.
    function _effectiveSelectorFromState(
        bytes[] calldata state_,
        bytes32 indices_,
        uint256 callType_,
        uint256 writtenSlots_
    ) private pure returns (bytes4 selector) {
        bytes32 dataIndices = callType_ == FLAG_CT_VALUECALL ? indices_ << 8 : indices_;
        uint256 index = uint256(uint8(bytes1(dataIndices))) & IDX_VALUE_MASK;

        if (writtenSlots_ & (STATE_REPLACED_BIT | (1 << index)) != 0) {
            revert EnsoFuseStateSlotOverwritten(index);
        }

        if (index >= state_.length) {
            revert EnsoFuseInvalidStateIndex(index);
        }

        bytes calldata data = state_[index];

        if (data.length < 4) {
            revert EnsoFuseInvalidStateCalldata(index);
        }

        return bytes4(data[0:4]);
    }

    /// @notice Record the state write the executor's VM performs after dispatching a command
    /// @param writtenSlots_ Bitmap of state slots written so far
    /// @param command_ The command word (never an argument-index word)
    /// @param flags_ Flags byte of the command
    /// @return The bitmap with this command's write added
    /// @dev Mirrors the tail of `VM._execute`: the output index is byte 11 of the command word.
    ///      IDX_END_OF_ARGS discards the return data. A non-tuple IDX_USE_STATE replaces the whole
    ///      array (`writeOutputs`); every other value - tuple or not, fixed or variable length -
    ///      writes `state[out & IDX_VALUE_MASK]` (`writeOutputs` / `writeTuple`).
    function _recordStateWrite(uint256 writtenSlots_, bytes32 command_, uint256 flags_) private pure returns (uint256) {
        uint256 out = uint256(uint8(bytes1(command_ << 88)));

        if (out == IDX_END_OF_ARGS) {
            return writtenSlots_;
        }

        if (flags_ & FLAG_TUPLE_RETURN == 0 && out == IDX_USE_STATE) {
            return writtenSlots_ | STATE_REPLACED_BIT;
        }

        return writtenSlots_ | (1 << (out & IDX_VALUE_MASK));
    }

    /// @notice Creates a new EnsoExecutor and stores its address in storage if it doesn't exist
    /// @return executorAddress The address of the created executor
    function _createExecutorWhenNotExists() internal returns (address executorAddress) {
        executorAddress = EnsoStorageLib.getEnsoExecutor();

        if (executorAddress == address(0)) {
            executorAddress = address(new EnsoExecutor(DELEGATE_ENSO_SHORTCUTS, WETH, address(this)));
            EnsoStorageLib.setEnsoExecutor(executorAddress);
            emit EnsoExecutorCreated(executorAddress, address(this), DELEGATE_ENSO_SHORTCUTS, WETH);
        }
    }

    /// @notice Validate that all token addresses have transfer function granted as substrates
    /// @param tokens_ Array of token addresses to validate
    function _validateExitSubstrates(address[] calldata tokens_) private view {
        uint256 tokensLength = tokens_.length;
        for (uint256 i; i < tokensLength; ++i) {
            if (
                !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                    MARKET_ID,
                    EnsoSubstrateLib.encode(
                        EnsoSubstrate({target_: tokens_[i], functionSelector_: ERC20.transfer.selector})
                    )
                )
            ) {
                revert EnsoFuseUnsupportedAsset(tokens_[i]);
            }
        }
    }
}
