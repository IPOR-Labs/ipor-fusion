// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {EnsoExecutor, EnsoExecutorData} from "./EnsoExecutor.sol";
import {EnsoSubstrateLib, Substrate} from "./EnsoSubstrateLib.sol";
import {EnsoStorageLib} from "./EnsoStorageLib.sol";

/// @notice Data structure used for entering an Enso shortcut operation.
/// @param tokensToTransfer_ - The array of token addresses to transfer from PlasmaVault to the executor
/// @param amounts_ - The array of amounts corresponding to each token in tokensToTransfer
/// @param accountId_ - The bytes32 value representing an API user
/// @param requestId_ - The bytes32 value representing an API request
/// @param commands_ - An array of bytes32 values that encode calls
/// @param state_ - An array of bytes that are used to generate call data for each command
/// @param tokensToReturn_ - Array of token addresses that should be returned from executor to PlasmaVault
struct EnsoFuseEnterData {
    address tokensOut;
    uint256 amountOut;
    uint256 wEthAmount;
    bytes32 accountId;
    bytes32 requestId;
    bytes32[] commands;
    bytes[] state;
    address[] tokensToReturn;
}

/// @notice Data structure used for exiting Enso positions and withdrawing tokens
/// @param tokens_ - Array of token addresses to withdraw from EnsoExecutor
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
    error EnsoFuseInvalidTokensOut();

    uint256 private constant FLAG_CT_CALL = 0x01;
    uint256 private constant FLAG_CT_STATICCALL = 0x02;
    uint256 private constant FLAG_CT_VALUECALL = 0x03;
    uint256 private constant FLAG_CT_MASK = 0x03;
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
        if (data_.tokensOut == address(0)) {
            revert EnsoFuseInvalidTokensOut();
        }

        _checkSubstrates(data_);
        _validateCommands(data_.commands);

        address executor = _createExecutorWhenNotExists();

        if (data_.amountOut > 0) {
            ERC20(data_.tokensOut).safeTransfer(executor, data_.amountOut);
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
                tokensOut: data_.tokensOut,
                amountOut: data_.amountOut
            })
        );

        emit EnsoFuseEnter(VERSION, data_.accountId, data_.requestId, new address[](0), new uint256[](0));
    }

    /// @notice Withdraw tokens from EnsoExecutor back to PlasmaVault
    /// @param data_ The data structure containing token addresses to withdraw
    function exit(EnsoFuseExitData calldata data_) external {
        _validateTokenSubstrates(data_.tokens);

        address executor = EnsoStorageLib.getEnsoExecutor();

        if (executor == address(0)) {
            revert EnsoFuseInvalidExecutorAddress();
        }

        EnsoExecutor(payable(executor)).withdrawTokens(data_.tokens);

        emit EnsoFuseExit(VERSION, data_.tokens);
    }

    /// @notice Validate that all substrates (tokens and return tokens) are granted
    /// @param data_ The data structure containing all parameters for validation
    function _checkSubstrates(EnsoFuseEnterData calldata data_) private view {
        // Validate tokensOut substrate
        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                EnsoSubstrateLib.encode(
                    Substrate({target_: data_.tokensOut, functionSelector_: ERC20.transfer.selector})
                )
            )
        ) {
            revert EnsoFuseUnsupportedAsset(data_.tokensOut);
        }

        // Validate WETH substrate if wEthAmount > 0
        if (data_.wEthAmount > 0) {
            if (
                !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                    MARKET_ID,
                    EnsoSubstrateLib.encode(Substrate({target_: WETH, functionSelector_: ERC20.transfer.selector}))
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
                        Substrate({target_: data_.tokensToReturn[i], functionSelector_: ERC20.transfer.selector})
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
        for (uint256 i; i < commandsLength; ++i) {
            bytes32 command = commands_[i];

            // Extract flags (byte at position 32)
            uint256 flags = uint256(uint8(bytes1(command << 32)));
            uint256 callType = flags & FLAG_CT_MASK;

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
            address target = address(uint160(uint256(command)));
            bytes4 selector = bytes4(command);

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
    function _validateTokenSubstrates(address[] calldata tokens_) private view {
        uint256 tokensLength = tokens_.length;
        for (uint256 i; i < tokensLength; ++i) {
            if (
                !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                    MARKET_ID,
                    EnsoSubstrateLib.encode(
                        Substrate({target_: tokens_[i], functionSelector_: ERC20.transfer.selector})
                    )
                )
            ) {
                revert EnsoFuseUnsupportedAsset(tokens_[i]);
            }
        }
    }
}
