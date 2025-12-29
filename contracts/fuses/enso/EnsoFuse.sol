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
/// @param tokensToReturn_ Array of token addresses expected to be returned to PlasmaVault after execution
struct EnsoFuseEnterData {
    address tokenOut;
    uint256 amountOut;
    uint256 wEthAmount;
    bytes32 accountId;
    bytes32 requestId;
    bytes32[] commands;
    bytes[] state;
    address[] tokensToReturn;
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

    /// @notice Flag indicating that the next command contains indices rather than a call
    /// @dev When set, the following command in the array should be skipped during validation
    ///      as it contains array indices or other metadata, not an actual external call
    uint256 private constant FLAG_EXTENDED_COMMAND = 0x40;

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

        _validateEnterSubstrates(data_);
        _validateCommands(data_.commands);

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
                amountOut: data_.amountOut
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

    /// @notice Validate that all commands (CALL and VALUECALL) are granted in substrates
    /// @param commands_ Array of encoded commands to validate
    /// @dev Skips validation for STATICCALL (read-only) and handles FLAG_EXTENDED_COMMAND
    function _validateCommands(bytes32[] calldata commands_) private view {
        uint256 commandsLength = commands_.length;
        bytes32 command;
        uint256 flags;
        uint256 callType;
        address target;
        bytes4 selector;
        for (uint256 i; i < commandsLength; ++i) {
            command = commands_[i];

            // Extract flags (byte at position 32)
            flags = uint256(uint8(bytes1(command << 32)));
            callType = flags & FLAG_CT_MASK;

            // Skip validation for STATICCALL (read-only)
            if (callType == FLAG_CT_STATICCALL) {
                continue;
            }

            // Skip if FLAG_EXTENDED_COMMAND (next command is indices, not a call)
            if (flags & FLAG_EXTENDED_COMMAND != 0) {
                ++i; // Skip next command which contains indices
                continue;
            }

            // Extract target address and function selector
            target = address(uint160(uint256(command)));
            selector = bytes4(command);

            // Validate substrate is granted
            if (
                !PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, EnsoSubstrateLib.encodeRaw(target, selector))
            ) {
                revert EnsoFuseUnsupportedCommand(target, selector);
            }
        }
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
