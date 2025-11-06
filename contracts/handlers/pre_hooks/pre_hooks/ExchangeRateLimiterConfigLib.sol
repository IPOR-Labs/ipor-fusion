// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;
/// @notice Enum representing the type of hook or validator
enum HookType {
    PREHOOKS,
    POSTHOOKS,
    VALIDATOR
}

/// @notice Structure for storing hook configuration data
/// @param typ The type of hook or validator
/// @param data The data bytes (remaining bytes32 after enum type)
/// @dev The entire struct is packed into a single bytes32 value:
///      - First 8 bits (1 byte): HookType enum value
///      - Remaining 31 bytes: data
struct ExchangeRateLimiterConfig {
    HookType typ;
    bytes31 data;
}

/// @notice Structure for storing hook address and execution order
/// @param hookAddress The address of the hook contract
/// @param index The execution order index (max value: 10)
struct Hook {
    address hookAddress;
    uint8 index;
}

/// @notice Structure for storing validator data
/// @param exchangeRate The exchange rate value (128 bits)
/// @param threshold The threshold value (120 bits)
/// @dev The entire struct is packed into a single bytes31 value (248 bits total):
///      - First 120 bits: threshold
///      - Remaining 128 bits: exchangeRate
struct ValidatorData {
    uint128 exchangeRate;
    uint120 threshold;
}

/// @title ExchangeRateLimiterConfigLib
/// @notice Library for converting ExchangeRateLimiterConfig to/from bytes32
library ExchangeRateLimiterConfigLib {
    /// @notice Error thrown when the maximum number of pre-hooks is exceeded
    error ExchangeRateLimiterConfigLibMaxPreHooksExceeded();
    /// @notice Error thrown when the maximum number of post-hooks is exceeded
    error ExchangeRateLimiterConfigLibMaxPostHooksExceeded();
    /// @notice Error thrown when hook index is out of range (must be 0-9)
    error ExchangeRateLimiterConfigLibInvalidHookIndex();
    /// @notice Error thrown when hook position is already occupied
    error ExchangeRateLimiterConfigLibHookPositionOccupied();
    /// @notice Error thrown when hook type value is invalid
    error ExchangeRateLimiterConfigLibInvalidHookType();

    /// @notice Maximum number of pre-hooks allowed
    uint256 private constant MAX_PRE_HOOKS = 10;
    /// @notice Maximum number of post-hooks allowed
    uint256 private constant MAX_POST_HOOKS = 10;
    /// @notice Converts ExchangeRateLimiterConfig to bytes32
    /// @param config_ The configuration struct to convert
    /// @return The packed bytes32 value
    /// @dev Packs enum type in the most significant byte (bits 248-255), data occupies lower 31 bytes (bits 0-247)
    function exchangeRateLimiterConfigToBytes32(ExchangeRateLimiterConfig memory config_) internal pure returns (bytes32) {
        return bytes32((uint256(config_.typ) << 248) | uint256(uint248(config_.data)));
    }

    /// @notice Converts bytes32 to ExchangeRateLimiterConfig
    /// @param bytes32Config_ The packed bytes32 value
    /// @return config The unpacked configuration struct
    /// @dev Extracts enum type from most significant byte, data from lower 31 bytes
    function bytes32ToExchangeRateLimiterConfig(bytes32 bytes32Config_) internal pure returns (ExchangeRateLimiterConfig memory config) {
        // Extract enum from most significant byte (bits 248-255)
        uint256 typValue = uint256(bytes32Config_) >> 248;
        if (typValue == 0) {
            config.typ = HookType.PREHOOKS;
        } else if (typValue == 1) {
            config.typ = HookType.POSTHOOKS;
        } else if (typValue == 2) {
            config.typ = HookType.VALIDATOR;
        } else {
            revert ExchangeRateLimiterConfigLibInvalidHookType();
        }
        // Extract data from lower 31 bytes (bits 0-247)
        config.data = bytes31(uint248(uint256(bytes32Config_)));
    }

    /// @notice Converts Hook struct to bytes31
    /// @param hook_ The Hook struct to convert
    /// @return The packed bytes31 value
    /// @dev Packs address (160 bits) and index (8 bits) into bytes31:
    ///      - First 160 bits: address (shifted by 88 bits)
    ///      - Next 8 bits: index (shifted by 80 bits)
    ///      - Remaining 80 bits: unused
    function hookToBytes31(Hook memory hook_) internal pure returns (bytes31) {
        // Address is 20 bytes (160 bits), index is 1 byte (8 bits), bytes31 is 31 bytes (248 bits)
        // Pack address in bits 88-247 (160 bits), index in bits 80-87 (8 bits)
        return bytes31(uint248((uint256(uint160(hook_.hookAddress)) << 88) | (uint256(hook_.index) << 80)));
    }

    /// @notice Converts bytes31 to Hook struct
    /// @param bytes31Hook_ The packed bytes31 value
    /// @return hook The unpacked Hook struct
    /// @dev Extracts address from bits 88-247 (160 bits) and index from bits 80-87 (8 bits)
    function bytes31ToHook(bytes31 bytes31Hook_) internal pure returns (Hook memory hook) {
        uint256 packed = uint256(uint248(bytes31Hook_));
        // Extract address from bits 88-247 (160 bits) by shifting right by 88 bits
        hook.hookAddress = address(uint160(packed >> 88));
        // Extract index from bits 80-87 (8 bits) by shifting right by 80 bits and masking
        hook.index = uint8((packed >> 80) & 0xFF);
    }

    /// @notice Converts ValidatorData struct to bytes31
    /// @param validatorData_ The ValidatorData struct to convert
    /// @return The packed bytes31 value
    /// @dev Packs threshold (120 bits) and exchangeRate (128 bits) into bytes31
    function validatorDataToBytes31(ValidatorData memory validatorData_) internal pure returns (bytes31) {
        // Pack threshold in first 120 bits, exchangeRate in remaining 128 bits (shifted by 120 bits)
        return bytes31(uint248(uint256(validatorData_.threshold) | (uint256(validatorData_.exchangeRate) << 120)));
    }

    /// @notice Converts bytes31 to ValidatorData struct
    /// @param bytes31ValidatorData_ The packed bytes31 value
    /// @return validatorData The unpacked ValidatorData struct
    /// @dev Extracts threshold from first 120 bits, exchangeRate from remaining 128 bits
    function bytes31ToValidatorData(bytes31 bytes31ValidatorData_) internal pure returns (ValidatorData memory validatorData) {
        uint256 packed = uint256(uint248(bytes31ValidatorData_));
        // Extract threshold from first 120 bits
        validatorData.threshold = uint120(packed & type(uint120).max);
        // Extract exchangeRate from remaining 128 bits (bits 120-247)
        validatorData.exchangeRate = uint128(packed >> 120);
    }

    /// @notice Parses an array of bytes32 containing ExchangeRateLimiterConfig data
    /// @param configs_ Array of bytes32 containing packed ExchangeRateLimiterConfig
    /// @return preHooks Array of pre-hooks extracted from the configs (always 10 elements, empty hooks have address(0))
    /// @return postHooks Array of post-hooks extracted from the configs (always 10 elements, empty hooks have address(0))
    /// @return validationData Validator data extracted from the configs
    /// @return index Position of validationData in the input array (type(uint256).max if not found)
    /// @dev Iterates through the array, unpacks each ExchangeRateLimiterConfig,
    ///      and categorizes them based on HookType (PREHOOKS, POSTHOOKS, VALIDATOR).
    ///      Reverts if the maximum number of pre-hooks or post-hooks (10 each) is exceeded.
    ///      Hooks are inserted at positions corresponding to their index field (0-9).
    ///      Returns arrays of fixed size 10, with empty hooks (address(0)) filling unused slots.
    function parseConfigs(
        bytes32[] memory configs_
    ) internal pure returns (Hook[] memory preHooks, Hook[] memory postHooks, ValidatorData memory validationData, uint256 index) {
        index = type(uint256).max;

        // Allocate arrays with fixed size of 10
        preHooks = new Hook[](MAX_PRE_HOOKS);
        postHooks = new Hook[](MAX_POST_HOOKS);

        uint256 configsLength = configs_.length;

        // Process configs: insert hooks at positions corresponding to their index
        for (uint256 i; i < configsLength; ++i) {
            ExchangeRateLimiterConfig memory config = bytes32ToExchangeRateLimiterConfig(configs_[i]);
            if (config.typ == HookType.PREHOOKS) {
                Hook memory hook = bytes31ToHook(config.data);
                if (hook.index >= MAX_PRE_HOOKS) {
                    revert ExchangeRateLimiterConfigLibInvalidHookIndex();
                }
                if (preHooks[hook.index].hookAddress != address(0)) {
                    revert ExchangeRateLimiterConfigLibHookPositionOccupied();
                }
                preHooks[hook.index] = hook;
            } else if (config.typ == HookType.POSTHOOKS) {
                Hook memory hook = bytes31ToHook(config.data);
                if (hook.index >= MAX_POST_HOOKS) {
                    revert ExchangeRateLimiterConfigLibInvalidHookIndex();
                }
                if (postHooks[hook.index].hookAddress != address(0)) {
                    revert ExchangeRateLimiterConfigLibHookPositionOccupied();
                }
                postHooks[hook.index] = hook;
            } else if (config.typ == HookType.VALIDATOR) {
                if (index == type(uint256).max) {
                    index = i;
                    validationData = bytes31ToValidatorData(config.data);
                }
            }
        }
    }
}

