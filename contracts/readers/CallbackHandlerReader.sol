// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {CallbackHandlerLib} from "../libraries/CallbackHandlerLib.sol";
import {UniversalReader, ReadResult} from "../universal_reader/UniversalReader.sol";

/**
 * @title CallbackHandlerInfo Struct
 * @notice Structure containing information about a callback handler configuration
 * @dev Used to store and return callback handler related data from the PlasmaVault system
 */
struct CallbackHandlerInfo {
    /// @notice Address of the protocol contract that triggers callbacks
    address sender;
    /// @notice Function signature that identifies the callback
    bytes4 sig;
    /// @notice Address of the callback handler implementation contract
    address handler;
}

/**
 * @title CallbackHandlerReader
 * @notice Reader contract for accessing callback handler configuration data from PlasmaVault
 * @dev Provides methods to query callback handler information both directly and through the UniversalReader pattern
 */
contract CallbackHandlerReader {
    error CallbackHandlerReaderInvalidArrayLength();

    /**
     * @notice Retrieves callback handler information for a specific sender and signature from a PlasmaVault instance
     * @dev Uses UniversalReader pattern to safely read data from the target vault
     * @param plasmaVault_ Address of the PlasmaVault to read from
     * @param sender_ Address of the protocol contract that triggers callbacks
     * @param sig_ Function signature that identifies the callback
     * @return handler Address of the callback handler implementation contract
     */
    function getCallbackHandler(
        address plasmaVault_,
        address sender_,
        bytes4 sig_
    ) external view returns (address handler) {
        ReadResult memory readResult = UniversalReader(address(plasmaVault_)).read(
            address(this),
            abi.encodeWithSignature("getCallbackHandler(address,bytes4)", sender_, sig_)
        );
        handler = abi.decode(readResult.data, (address));
    }

    /**
     * @notice Internal helper that retrieves callback handler information for a specific sender and signature
     * @dev WARNING: This function MUST be called via UniversalReader (delegatecall in PlasmaVault context).
     *      Direct external calls will return incorrect data as it reads from the caller's storage context.
     *      Use getCallbackHandler(address plasmaVault_, address sender_, bytes4 sig_) for safe external access.
     * @dev Queries the callback handler mapping using the same key generation as CallbackHandlerLib
     * @param sender_ Address of the protocol contract that triggers callbacks
     * @param sig_ Function signature that identifies the callback
     * @return handler Address of the callback handler implementation contract
     */
    function getCallbackHandler(address sender_, bytes4 sig_) public view returns (address handler) {
        bytes32 key = keccak256(abi.encodePacked(sender_, sig_));
        handler = CallbackHandlerLib.getCallbackHandlerStorage().callbackHandler[key];
    }

    /**
     * @notice Internal helper that retrieves callback handler information for multiple sender-signature pairs
     * @dev WARNING: This function MUST be called via UniversalReader (delegatecall in PlasmaVault context).
     *      Direct external calls will return incorrect data as it reads from the caller's storage context.
     *      Use getCallbackHandlers(address plasmaVault_, address[] senders_, bytes4[] sigs_) for safe external access.
     * @dev Batch query for multiple callback handler configurations
     * @param senders_ Array of protocol contract addresses that trigger callbacks
     * @param sigs_ Array of function signatures that identify the callbacks
     * @return handlers Array of callback handler implementation contract addresses
     */
    function getCallbackHandlers(
        address[] calldata senders_,
        bytes4[] calldata sigs_
    ) public view returns (address[] memory handlers) {
        if (senders_.length != sigs_.length) {
            revert CallbackHandlerReaderInvalidArrayLength();
        }

        handlers = new address[](senders_.length);

        for (uint256 i; i < senders_.length; ++i) {
            bytes32 key = keccak256(abi.encodePacked(senders_[i], sigs_[i]));
            handlers[i] = CallbackHandlerLib.getCallbackHandlerStorage().callbackHandler[key];
        }
    }

    /**
     * @notice Retrieves callback handler information for multiple sender-signature pairs from a PlasmaVault instance
     * @dev Uses UniversalReader pattern to safely read data from the target vault
     * @param plasmaVault_ Address of the PlasmaVault to read from
     * @param senders_ Array of protocol contract addresses that trigger callbacks
     * @param sigs_ Array of function signatures that identify the callbacks
     * @return handlers Array of callback handler implementation contract addresses
     */
    function getCallbackHandlers(
        address plasmaVault_,
        address[] calldata senders_,
        bytes4[] calldata sigs_
    ) external view returns (address[] memory handlers) {
        ReadResult memory readResult = UniversalReader(address(plasmaVault_)).read(
            address(this),
            abi.encodeWithSignature("getCallbackHandlers(address[],bytes4[])", senders_, sigs_)
        );
        handlers = abi.decode(readResult.data, (address[]));
    }
}
