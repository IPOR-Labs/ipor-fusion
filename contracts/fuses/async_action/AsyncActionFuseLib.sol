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
/// @dev Provides utility functions for async action fuse management
library AsyncActionFuseLib {
    uint248 private constant _UINT88_MASK = (uint248(1) << 88) - 1;
    uint248 private constant _UINT32_MASK = (uint248(1) << 32) - 1;

    /// @notice Thrown when amount exceeds uint88 maximum value
    error AllowedAmountToOutsideAmountTooLarge(uint256 amount);
    /// @notice Thrown when slippage exceeds uint248 maximum value
    error AllowedSlippageTooLarge(uint256 slippage);

    /// @notice Encodes AllowedAmountToOutside struct into bytes31
    /// @param data_ The AllowedAmountToOutside struct to encode
    /// @return encoded The encoded bytes31 data
    /// @dev Encodes address (20 bytes) and uint88 amount (11 bytes) into 31 bytes
    ///      Reverts if amount exceeds uint88 maximum (2^88 - 1)
    function encodeAllowedAmountToOutside(AllowedAmountToOutside memory data_)
        internal
        pure
        returns (bytes31 encoded)
    {
        if (data_.amount > type(uint88).max) {
            revert AllowedAmountToOutsideAmountTooLarge(data_.amount);
        }

        uint88 amount_ = uint88(data_.amount);
        uint248 packed_ = (uint248(uint160(data_.asset)) << 88) | uint248(amount_);
        encoded = bytes31(packed_);
    }

    /// @notice Decodes bytes31 into AllowedAmountToOutside struct
    /// @param encoded_ The encoded bytes31 data
    /// @return data_ The decoded AllowedAmountToOutside struct
    /// @dev Decodes address (20 bytes) and uint88 amount (11 bytes) from 31 bytes
    function decodeAllowedAmountToOutside(bytes31 encoded_)
        internal
        pure
        returns (AllowedAmountToOutside memory data_)
    {
        uint248 packed_ = uint248(encoded_);
        data_.asset = address(uint160(packed_ >> 88));
        data_.amount = uint256(uint88(packed_ & _UINT88_MASK));
    }

    /// @notice Encodes AllowedTargets struct into bytes31
    /// @param data_ The AllowedTargets struct to encode
    /// @return encoded The encoded bytes31 data
    /// @dev Encodes address (20 bytes) and bytes4 selector (4 bytes) into 24 bytes
    function encodeAllowedTargets(AllowedTargets memory data_)
        internal
        pure
        returns (bytes31 encoded)
    {
        uint248 packed_ = (uint248(uint160(data_.target)) << 32) | uint248(uint32(data_.selector));
        encoded = bytes31(packed_);
    }

    /// @notice Decodes bytes31 into AllowedTargets struct
    /// @param encoded_ The encoded bytes31 data
    /// @return data_ The decoded AllowedTargets struct
    /// @dev Decodes address (20 bytes) and bytes4 selector (4 bytes) from 31 bytes
    function decodeAllowedTargets(bytes31 encoded_)
        internal
        pure
        returns (AllowedTargets memory data_)
    {
        uint248 packed_ = uint248(encoded_);
        data_.target = address(uint160(packed_ >> 32));
        data_.selector = bytes4(uint32(packed_ & _UINT32_MASK));
    }

    /// @notice Encodes AsyncActionFuseSubstrate struct into bytes32
    /// @param substrate_ The AsyncActionFuseSubstrate struct to encode
    /// @return encoded The encoded bytes32 data
    /// @dev Encodes enum substrateType (1 byte) and bytes31 data (31 bytes) into 32 bytes
    function encodeAsyncActionFuseSubstrate(AsyncActionFuseSubstrate memory substrate_)
        internal
        pure
        returns (bytes32 encoded)
    {
        uint256 packed_ =
            (uint256(uint8(substrate_.substrateType)) << 248) | uint256(uint248(substrate_.data));
        encoded = bytes32(packed_);
    }

    /// @notice Decodes bytes32 into AsyncActionFuseSubstrate struct
    /// @param encoded_ The encoded bytes32 data
    /// @return substrate_ The decoded AsyncActionFuseSubstrate struct
    /// @dev Decodes enum substrateType (1 byte) and bytes31 data (31 bytes) from 32 bytes
    function decodeAsyncActionFuseSubstrate(bytes32 encoded_)
        internal
        pure
        returns (AsyncActionFuseSubstrate memory substrate_)
    {
        uint256 packed_ = uint256(encoded_);
        substrate_.substrateType = AsyncActionFuseSubstrateType(uint8(packed_ >> 248));
        substrate_.data = bytes31(uint248(packed_));
    }

    /// @notice Encodes AllowedSlippage struct into bytes31
    /// @param data_ The AllowedSlippage struct to encode
    /// @return encoded The encoded bytes31 data
    /// @dev Encodes uint248 slippage (31 bytes) into 31 bytes
    ///      Reverts if slippage exceeds uint248 maximum (2^248 - 1)
    function encodeAllowedSlippage(AllowedSlippage memory data_)
        internal
        pure
        returns (bytes31 encoded)
    {
        if (data_.slippage > type(uint248).max) {
            revert AllowedSlippageTooLarge(data_.slippage);
        }

        uint248 slippage_ = uint248(data_.slippage);
        encoded = bytes31(slippage_);
    }

    /// @notice Decodes bytes31 into AllowedSlippage struct
    /// @param encoded_ The encoded bytes31 data
    /// @return data_ The decoded AllowedSlippage struct
    /// @dev Decodes uint248 slippage (31 bytes) from 31 bytes
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
    /// @return allowedSlippages Array of AllowedSlippage structs
    /// @dev Processes each bytes32, decodes AsyncActionFuseSubstrate, and routes to appropriate array
    function decodeAsyncActionFuseSubstrates(bytes32[] memory encodedSubstrates_)
        internal
        pure
        returns (
            AllowedAmountToOutside[] memory allowedAmounts,
            AllowedTargets[] memory allowedTargets,
            AllowedSlippage[] memory allowedSlippages
        )
    {
        uint256 length_ = encodedSubstrates_.length;
        
        // Count each type to allocate arrays
        uint256 amountCount_;
        uint256 targetCount_;
        uint256 slippageCount_;
        
        for (uint256 i_; i_ < length_; ++i_) {
            uint256 encoded_ = uint256(encodedSubstrates_[i_]);
            uint8 substrateType_ = uint8(encoded_ >> 248);

            if (substrateType_ == uint8(AsyncActionFuseSubstrateType.ALLOWED_AMOUNT_TO_OUTSIDE)) {
                ++amountCount_;
            } else if (substrateType_ == uint8(AsyncActionFuseSubstrateType.ALLOWED_TARGETS)) {
                ++targetCount_;
            } else if (substrateType_ == uint8(AsyncActionFuseSubstrateType.ALLOWED_SLIPPAGE)) {
                ++slippageCount_;
            }
        }
        
        // Allocate arrays
        allowedAmounts = new AllowedAmountToOutside[](amountCount_);
        allowedTargets = new AllowedTargets[](targetCount_);
        allowedSlippages = new AllowedSlippage[](slippageCount_);
        
        // Fill arrays
        uint256 amountIndex_;
        uint256 targetIndex_;
        uint256 slippageIndex_;
        
        for (uint256 i_; i_ < length_; ++i_) {
            uint256 encoded_ = uint256(encodedSubstrates_[i_]);
            uint8 substrateType_ = uint8(encoded_ >> 248);
            bytes31 dataBytes_ = bytes31(uint248(encoded_));

            if (substrateType_ == uint8(AsyncActionFuseSubstrateType.ALLOWED_AMOUNT_TO_OUTSIDE)) {
                allowedAmounts[amountIndex_] = decodeAllowedAmountToOutside(dataBytes_);
                ++amountIndex_;
            } else if (substrateType_ == uint8(AsyncActionFuseSubstrateType.ALLOWED_TARGETS)) {
                allowedTargets[targetIndex_] = decodeAllowedTargets(dataBytes_);
                ++targetIndex_;
            } else if (substrateType_ == uint8(AsyncActionFuseSubstrateType.ALLOWED_SLIPPAGE)) {
                allowedSlippages[slippageIndex_] = decodeAllowedSlippage(dataBytes_);
                ++slippageIndex_;
            }
        }
    }

    /// @dev Storage slot for AsyncExecutor address
    /// @dev Calculation: keccak256(abi.encode(uint256(keccak256("io.ipor.asyncAction.Executor")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ASYNC_EXECUTOR_SLOT = 0xd11817d505e758dbdddfdf82e8802c5d790ff9a5210336904df8aac67e86d200;

    /// @dev Structure holding the AsyncExecutor address
    /// @custom:storage-location erc7201:io.ipor.asyncAction.Executor
    struct AsyncExecutorStorage {
        /// @dev The address of the AsyncExecutor
        address executor;
    }

    /// @notice Gets the AsyncExecutor storage pointer
    /// @return storagePtr The AsyncExecutorStorage struct from storage
    function getAsyncExecutorStorage() internal pure returns (AsyncExecutorStorage storage storagePtr) {
        assembly {
            storagePtr.slot := ASYNC_EXECUTOR_SLOT
        }
    }

    /// @notice Sets the AsyncExecutor address
    /// @param executor_ The address of the AsyncExecutor
    function setAsyncExecutor(address executor_) internal {
        AsyncExecutorStorage storage storagePtr = getAsyncExecutorStorage();
        storagePtr.executor = executor_;
    }

    /// @notice Gets the AsyncExecutor address from storage
    /// @return The address of the AsyncExecutor, or address(0) if not set
    function getAsyncExecutor() internal view returns (address) {
        AsyncExecutorStorage storage storagePtr = getAsyncExecutorStorage();
        return storagePtr.executor;
    }

    /// @notice Gets the AsyncExecutor address, deploying a new one if it doesn't exist
    /// @param wEth_ Address of the WETH token contract
    /// @param plasmaVault_ Address of the controlling Plasma Vault
    /// @return executorAddress The address of the AsyncExecutor
    /// @dev If executor doesn't exist in storage, deploys a new AsyncExecutor and stores its address
    function getAsyncExecutorAddress(address wEth_, address plasmaVault_) internal returns (address executorAddress) {
        executorAddress = getAsyncExecutor();

        if (executorAddress == address(0)) {
            executorAddress = address(new AsyncExecutor(wEth_, plasmaVault_));
            setAsyncExecutor(executorAddress);
        }
    }
}

