// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {AsyncExecutor} from "./AsyncExecutor.sol";

enum AsyncActionFuseSubstrateType {
    ALLOWED_AMOUNT_TO_OUTSIDE,
    ALLOWED_TARGETS,
    ALLOWED_SLIPPAGE
}

struct AllowedAmountToOutside {
    address asset;
    uint256 amount;
}

struct AllowedTargets {
    address target;
    bytes4 selector;
}

struct AllowedSlippage {
    uint256 slippage;
}

struct AsyncActionFuseSubstrate {
    AsyncActionFuseSubstrateType substrateType;
    bytes31 data;
}

/// @title AsyncActionFuseLib
/// @notice Library for managing async action fuse operations
/// @dev Provides utility functions for encoding/decoding substrate data and managing AsyncExecutor instances.
///      Supports encoding/decoding of AllowedAmountToOutside, AllowedTargets, and AllowedSlippage structures.
///      Manages AsyncExecutor storage using ERC-7201 namespaced storage pattern.
/// @author IPOR Labs
library AsyncActionFuseLib {
    uint248 private constant _UINT88_MASK = (uint248(1) << 88) - 1;
    uint248 private constant _UINT32_MASK = (uint248(1) << 32) - 1;

    /// @notice Thrown when amount exceeds uint88 maximum value
    /// @param amount The amount that exceeded the maximum
    /// @custom:error AllowedAmountToOutsideAmountTooLarge
    error AllowedAmountToOutsideAmountTooLarge(uint256 amount);

    /// @notice Thrown when slippage exceeds uint248 maximum value
    /// @param slippage The slippage value that exceeded the maximum
    /// @custom:error AllowedSlippageTooLarge
    error AllowedSlippageTooLarge(uint256 slippage);

    /// @notice Encodes AllowedAmountToOutside struct into bytes31
    /// @param data_ The AllowedAmountToOutside struct to encode
    /// @return encoded The encoded bytes31 data
    /// @dev Encodes address (20 bytes, left-aligned) and uint88 amount (11 bytes, right-aligned) into 31 bytes.
    ///      Layout: [address (20 bytes) | amount (11 bytes)]
    ///      Reverts if amount exceeds uint88 maximum (2^88 - 1).
    function encodeAllowedAmountToOutside(AllowedAmountToOutside memory data_)
        internal
        pure
        returns (bytes31 encoded)
    {
        if (data_.amount > type(uint88).max) {
            revert AllowedAmountToOutsideAmountTooLarge(data_.amount);
        }

        uint88 amount = uint88(data_.amount);
        // Pack: address shifted left by 88 bits, amount in lower 88 bits
        uint248 packed = (uint248(uint160(data_.asset)) << 88) | uint248(amount);
        encoded = bytes31(packed);
    }

    /// @notice Decodes bytes31 into AllowedAmountToOutside struct
    /// @param encoded_ The encoded bytes31 data
    /// @return data_ The decoded AllowedAmountToOutside struct
    /// @dev Decodes address (20 bytes, left-aligned) and uint88 amount (11 bytes, right-aligned) from 31 bytes.
    ///      Layout: [address (20 bytes) | amount (11 bytes)]
    function decodeAllowedAmountToOutside(bytes31 encoded_)
        internal
        pure
        returns (AllowedAmountToOutside memory data_)
    {
        uint248 packed = uint248(encoded_);
        // Extract address from upper 160 bits (shifted right by 88 bits)
        data_.asset = address(uint160(packed >> 88));
        // Extract amount from lower 88 bits
        data_.amount = uint256(uint88(packed & _UINT88_MASK));
    }

    /// @notice Encodes AllowedTargets struct into bytes31
    /// @param data_ The AllowedTargets struct to encode
    /// @return encoded The encoded bytes31 data
    /// @dev Encodes address (20 bytes, left-aligned) and bytes4 selector (4 bytes, right-aligned) into 31 bytes.
    ///      Layout: [address (20 bytes) | selector (4 bytes) | unused (7 bytes)]
    ///      The remaining 7 bytes are unused but preserved for consistency with bytes31 format.
    function encodeAllowedTargets(AllowedTargets memory data_)
        internal
        pure
        returns (bytes31 encoded)
    {
        // Pack: address shifted left by 32 bits, selector in lower 32 bits
        uint248 packed = (uint248(uint160(data_.target)) << 32) | uint248(uint32(data_.selector));
        encoded = bytes31(packed);
    }

    /// @notice Decodes bytes31 into AllowedTargets struct
    /// @param encoded_ The encoded bytes31 data
    /// @return data_ The decoded AllowedTargets struct
    /// @dev Decodes address (20 bytes, left-aligned) and bytes4 selector (4 bytes, right-aligned) from 31 bytes.
    ///      Layout: [address (20 bytes) | selector (4 bytes) | unused (7 bytes)]
    function decodeAllowedTargets(bytes31 encoded_)
        internal
        pure
        returns (AllowedTargets memory data_)
    {
        uint248 packed = uint248(encoded_);
        // Extract address from upper 160 bits (shifted right by 32 bits)
        data_.target = address(uint160(packed >> 32));
        // Extract selector from lower 32 bits
        data_.selector = bytes4(uint32(packed & _UINT32_MASK));
    }

    /// @notice Encodes AsyncActionFuseSubstrate struct into bytes32
    /// @param substrate_ The AsyncActionFuseSubstrate struct to encode
    /// @return encoded The encoded bytes32 data
    /// @dev Encodes enum substrateType (1 byte, leftmost) and bytes31 data (31 bytes, right-aligned) into 32 bytes.
    ///      Layout: [substrateType (1 byte) | data (31 bytes)]
    function encodeAsyncActionFuseSubstrate(AsyncActionFuseSubstrate memory substrate_)
        internal
        pure
        returns (bytes32 encoded)
    {
        // Pack: substrateType in leftmost byte (shifted left by 248 bits), data in remaining 31 bytes
        uint256 packed =
            (uint256(uint8(substrate_.substrateType)) << 248) | uint256(uint248(substrate_.data));
        encoded = bytes32(packed);
    }

    /// @notice Decodes bytes32 into AsyncActionFuseSubstrate struct
    /// @param encoded_ The encoded bytes32 data
    /// @return substrate_ The decoded AsyncActionFuseSubstrate struct
    /// @dev Decodes enum substrateType (1 byte, leftmost) and bytes31 data (31 bytes, right-aligned) from 32 bytes.
    ///      Layout: [substrateType (1 byte) | data (31 bytes)]
    function decodeAsyncActionFuseSubstrate(bytes32 encoded_)
        internal
        pure
        returns (AsyncActionFuseSubstrate memory substrate_)
    {
        uint256 packed = uint256(encoded_);
        // Extract substrateType from leftmost byte
        substrate_.substrateType = AsyncActionFuseSubstrateType(uint8(packed >> 248));
        // Extract data from remaining 31 bytes (lower 248 bits)
        substrate_.data = bytes31(uint248(packed));
    }

    /// @notice Encodes AllowedSlippage struct into bytes31
    /// @param data_ The AllowedSlippage struct to encode
    /// @return encoded The encoded bytes31 data
    /// @dev Encodes uint248 slippage value (31 bytes) directly into bytes31.
    ///      Reverts if slippage exceeds uint248 maximum (2^248 - 1).
    ///      Note: slippage is typically expressed as a percentage in 18-decimal WAD format (1e18 = 100%).
    function encodeAllowedSlippage(AllowedSlippage memory data_)
        internal
        pure
        returns (bytes31 encoded)
    {
        if (data_.slippage > type(uint248).max) {
            revert AllowedSlippageTooLarge(data_.slippage);
        }

        uint248 slippage = uint248(data_.slippage);
        encoded = bytes31(slippage);
    }

    /// @notice Decodes bytes31 into AllowedSlippage struct
    /// @param encoded_ The encoded bytes31 data
    /// @return data_ The decoded AllowedSlippage struct
    /// @dev Decodes uint248 slippage value (31 bytes) directly from bytes31.
    ///      Note: slippage is typically expressed as a percentage in 18-decimal WAD format (1e18 = 100%).
    function decodeAllowedSlippage(bytes31 encoded_)
        internal
        pure
        returns (AllowedSlippage memory data_)
    {
        data_.slippage = uint256(uint248(encoded_));
    }

    /// @notice Decodes array of bytes32 into three separate arrays based on substrate type
    /// @param encodedSubstrates_ Array of encoded AsyncActionFuseSubstrate data
    /// @return allowedAmounts Array of AllowedAmountToOutside structs
    /// @return allowedTargets Array of AllowedTargets structs
    /// @return allowedSlippage Single AllowedSlippage struct (last one found if multiple exist)
    /// @dev Processes each bytes32, decodes AsyncActionFuseSubstrate, and routes to appropriate array.
    ///      Uses two-pass algorithm: first pass counts each type for array allocation,
    ///      second pass decodes and populates arrays. This approach is gas-efficient for memory allocation.
    ///      Unknown substrate types are silently ignored.
    ///      If multiple ALLOWED_SLIPPAGE substrates exist, only the last one is returned.
    function decodeAsyncActionFuseSubstrates(bytes32[] memory encodedSubstrates_)
        internal
        pure
        returns (
            AllowedAmountToOutside[] memory allowedAmounts,
            AllowedTargets[] memory allowedTargets,
            AllowedSlippage memory allowedSlippage
        )
    {
        uint256 length = encodedSubstrates_.length;
        // First pass: count each substrate type to determine array sizes
        uint256 amountCount;
        uint256 targetCount;
        for (uint256 i; i < length; ++i) {
            uint8 substrateType = uint8(uint256(encodedSubstrates_[i]) >> 248);
            if (substrateType == uint8(AsyncActionFuseSubstrateType.ALLOWED_AMOUNT_TO_OUTSIDE)) {
                ++amountCount;
            } else if (substrateType == uint8(AsyncActionFuseSubstrateType.ALLOWED_TARGETS)) {
                ++targetCount;
            }
        }

        // Allocate arrays with correct sizes
        allowedAmounts = new AllowedAmountToOutside[](amountCount);
        allowedTargets = new AllowedTargets[](targetCount);

        // Second pass: decode and populate arrays
        uint256 amountIndex;
        uint256 targetIndex;

        for (uint256 i; i < length; ++i) {
            uint256 encoded = uint256(encodedSubstrates_[i]);
            uint8 substrateType = uint8(encoded >> 248);
            bytes31 dataBytes = bytes31(uint248(encoded));

            if (substrateType == uint8(AsyncActionFuseSubstrateType.ALLOWED_AMOUNT_TO_OUTSIDE)) {
                allowedAmounts[amountIndex] = decodeAllowedAmountToOutside(dataBytes);
                ++amountIndex;
            } else if (substrateType == uint8(AsyncActionFuseSubstrateType.ALLOWED_TARGETS)) {
                allowedTargets[targetIndex] = decodeAllowedTargets(dataBytes);
                ++targetIndex;
            } else if (substrateType == uint8(AsyncActionFuseSubstrateType.ALLOWED_SLIPPAGE)) {
                allowedSlippage = decodeAllowedSlippage(dataBytes);
            }
        }
    }

    /// @dev Storage slot for AsyncExecutor address
    /// @dev Uses ERC-7201 namespaced storage pattern to avoid storage collisions.
    ///      Calculation: keccak256(abi.encode(uint256(keccak256("io.ipor.asyncAction.Executor")) - 1)) & ~bytes32(uint256(0xff))
    ///      The slot is calculated by: namespace hash - 1, then clearing the last byte to align to 256-bit boundary.
    bytes32 private constant ASYNC_EXECUTOR_SLOT = 0xd11817d505e758dbdddfdf82e8802c5d790ff9a5210336904df8aac67e86d200;

    /// @dev Structure holding the AsyncExecutor address
    /// @custom:storage-location erc7201:io.ipor.asyncAction.Executor
    struct AsyncExecutorStorage {
        /// @dev The address of the AsyncExecutor
        address executor;
    }

    /// @notice Gets the AsyncExecutor storage pointer
    /// @return storagePtr The AsyncExecutorStorage struct from storage
    /// @dev Uses inline assembly to access the namespaced storage slot.
    function getAsyncExecutorStorage() internal pure returns (AsyncExecutorStorage storage storagePtr) {
        assembly {
            storagePtr.slot := ASYNC_EXECUTOR_SLOT
        }
    }

    /// @notice Sets the AsyncExecutor address
    /// @param executor_ The address of the AsyncExecutor to store
    /// @dev Overwrites any previously stored executor address.
    function setAsyncExecutor(address executor_) internal {
        AsyncExecutorStorage storage storagePtr = getAsyncExecutorStorage();
        storagePtr.executor = executor_;
    }

    /// @notice Gets the AsyncExecutor address from storage
    /// @return executorAddress The address of the AsyncExecutor, or address(0) if not set
    /// @dev Returns the executor address stored in the ERC-7201 namespaced storage slot.
    function getAsyncExecutor() internal view returns (address executorAddress) {
        AsyncExecutorStorage storage storagePtr = getAsyncExecutorStorage();
        executorAddress = storagePtr.executor;
    }

    /// @notice Gets the AsyncExecutor address, deploying a new one if it doesn't exist
    /// @param wEth_ Address of the WETH token contract (must not be address(0))
    /// @param plasmaVault_ Address of the controlling Plasma Vault (must not be address(0))
    /// @return executorAddress The address of the AsyncExecutor
    /// @dev If executor doesn't exist in storage, deploys a new AsyncExecutor and stores its address.
    ///      The executor is deployed with the provided WETH and Plasma Vault addresses.
    ///      Note: Input validation is performed by AsyncExecutor constructor
    function getAsyncExecutorAddress(address wEth_, address plasmaVault_) internal returns (address executorAddress) {
        executorAddress = getAsyncExecutor();

        if (executorAddress == address(0)) {
            executorAddress = address(new AsyncExecutor(wEth_, plasmaVault_));
            setAsyncExecutor(executorAddress);
        }
    }
}