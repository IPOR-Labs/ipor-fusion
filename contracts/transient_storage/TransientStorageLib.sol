// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

struct Data {
    bytes32[] inputs;
    bytes32[] outputs;
}

struct TransientStorage {
    mapping(address => Data) data;
}

enum TransientStorageParamTypes {
    UNKNOWN,
    INPUTS_BY_FUSE,
    OUTPUTS_BY_FUSE
}

/// @title TransientStorageLib
/// @notice Library for managing transient storage in the IPOR Fusion protocol
/// @author IPOR Labs
library TransientStorageLib {
    /**
     * @dev Storage slot for transient storage configuration following ERC-7201 namespaced storage pattern
     * @notice This storage location is used to store the transient data
     *
     * Calculation:
     * keccak256(abi.encode(uint256(keccak256("ipor.fusion.transient.storage")) - 1)) & ~bytes32(uint256(0xff))
     *
     * Storage Layout:
     * - Points to TransientStorage struct containing:
     *   - data: mapping(address => Data)
     */
    bytes32 internal constant TRANSIENT_STORAGE_SLOT =
        0x52e2674580d1653ba0725afccd4b28629470cf627aaa13843c2f3e8867c3b900;

    /// @notice Generic helper to store a value in transient storage
    /// @param slot_ The storage slot to write to
    /// @param value_ The value to write
    function tstore(bytes32 slot_, bytes32 value_) internal {
        assembly {
            tstore(slot_, value_)
        }
    }

    /// @notice Generic helper to load a value from transient storage
    /// @param slot_ The storage slot to read from
    /// @return value The value read from transient storage
    function tload(bytes32 slot_) internal view returns (bytes32 value) {
        assembly {
            value := tload(slot_)
        }
    }

    /// @notice Sets input parameters for a specific account in transient storage
    /// @param account_ The address of the account
    /// @param inputs_ Array of input values
    function setInputs(address account_, bytes32[] memory inputs_) internal {
        // Data struct is at keccak256(account . TRANSIENT_STORAGE_SLOT)
        // inputs array is at offset 0 of Data struct
        bytes32 inputsSlot = keccak256(abi.encode(account_, TRANSIENT_STORAGE_SLOT));

        // Store array length
        tstore(inputsSlot, bytes32(inputs_.length));

        // Store array elements at keccak256(inputsSlot) + index
        bytes32 dataStartSlot = keccak256(abi.encode(inputsSlot));
        for (uint256 i; i < inputs_.length; ++i) {
            bytes32 elementSlot = bytes32(uint256(dataStartSlot) + i);
            tstore(elementSlot, inputs_[i]);
        }
    }

    /// @notice Sets a single input parameter for a specific account at a given index
    /// @param account_ The address of the account
    /// @param index_ The index of the input parameter
    /// @param value_ The value to set
    function setInput(address account_, uint256 index_, bytes32 value_) internal {
        bytes32 inputsSlot = keccak256(abi.encode(account_, TRANSIENT_STORAGE_SLOT));
        bytes32 dataStartSlot = keccak256(abi.encode(inputsSlot));
        bytes32 elementSlot = bytes32(uint256(dataStartSlot) + index_);
        tstore(elementSlot, value_);
    }

    /// @notice Retrieves a single input parameter for a specific account at a given index
    /// @param account_ The address of the account
    /// @param index_ The index of the input parameter
    /// @return The input value at the specified index
    function getInput(address account_, uint256 index_) internal view returns (bytes32) {
        bytes32 inputsSlot = keccak256(abi.encode(account_, TRANSIENT_STORAGE_SLOT));
        bytes32 dataStartSlot = keccak256(abi.encode(inputsSlot));
        bytes32 elementSlot = bytes32(uint256(dataStartSlot) + index_);
        return tload(elementSlot);
    }

    /// @notice Retrieves all input parameters for a specific account
    /// @param account_ The address of the account
    /// @return inputs Array of input values
    function getInputs(address account_) internal view returns (bytes32[] memory inputs) {
        bytes32 inputsSlot = keccak256(abi.encode(account_, TRANSIENT_STORAGE_SLOT));
        uint256 len = uint256(tload(inputsSlot));
        inputs = new bytes32[](len);

        bytes32 dataStartSlot = keccak256(abi.encode(inputsSlot));
        for (uint256 i; i < len; ++i) {
            bytes32 elementSlot = bytes32(uint256(dataStartSlot) + i);
            inputs[i] = tload(elementSlot);
        }
    }

    /// @notice Sets output parameters for a specific account in transient storage
    /// @param account_ The address of the account
    /// @param outputs_ Array of output values
    function setOutputs(address account_, bytes32[] memory outputs_) internal {
        // outputs array is at offset 1 of Data struct
        bytes32 outputsSlot = bytes32(uint256(keccak256(abi.encode(account_, TRANSIENT_STORAGE_SLOT))) + 1);

        tstore(outputsSlot, bytes32(outputs_.length));

        bytes32 dataStartSlot = keccak256(abi.encode(outputsSlot));
        for (uint256 i = 0; i < outputs_.length; ++i) {
            bytes32 elementSlot = bytes32(uint256(dataStartSlot) + i);
            tstore(elementSlot, outputs_[i]);
        }
    }

    /// @notice Retrieves a single output parameter for a specific account at a given index
    /// @param account_ The address of the account
    /// @param index_ The index of the output parameter
    /// @return The output value at the specified index
    function getOutput(address account_, uint256 index_) internal view returns (bytes32) {
        bytes32 outputsSlot = bytes32(uint256(keccak256(abi.encode(account_, TRANSIENT_STORAGE_SLOT))) + 1);
        bytes32 dataStartSlot = keccak256(abi.encode(outputsSlot));
        bytes32 elementSlot = bytes32(uint256(dataStartSlot) + index_);
        return tload(elementSlot);
    }

    /// @notice Retrieves all output parameters for a specific account
    /// @param account_ The address of the account
    /// @return outputs Array of output values
    function getOutputs(address account_) internal view returns (bytes32[] memory outputs) {
        bytes32 outputsSlot = bytes32(uint256(keccak256(abi.encode(account_, TRANSIENT_STORAGE_SLOT))) + 1);
        uint256 len = uint256(tload(outputsSlot));
        outputs = new bytes32[](len);

        bytes32 dataStartSlot = keccak256(abi.encode(outputsSlot));
        for (uint256 i = 0; i < len; ++i) {
            bytes32 elementSlot = bytes32(uint256(dataStartSlot) + i);
            outputs[i] = tload(elementSlot);
        }
    }

    /// @notice Clears all output parameters for a specific account in transient storage
    /// @param account_ The address of the account
    function clearOutputs(address account_) internal {
        // outputs array is at offset 1 of Data struct
        bytes32 outputsSlot = bytes32(uint256(keccak256(abi.encode(account_, TRANSIENT_STORAGE_SLOT))) + 1);

        // Get current length to clear elements
        uint256 len = uint256(tload(outputsSlot));

        // Clear length
        tstore(outputsSlot, bytes32(0));

        // Clear elements (optional but good practice for cleanliness)
        bytes32 dataStartSlot = keccak256(abi.encode(outputsSlot));
        bytes32 elementSlot;
        for (uint256 i; i < len; ++i) {
            elementSlot = bytes32(uint256(dataStartSlot) + i);
            tstore(elementSlot, bytes32(0));
        }
    }
}
