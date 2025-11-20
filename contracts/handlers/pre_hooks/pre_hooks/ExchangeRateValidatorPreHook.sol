// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IPreHook} from "../IPreHook.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {PlasmaVaultConfigLib} from "../../../libraries/PlasmaVaultConfigLib.sol";
import {ExchangeRateValidatorConfigLib, Hook, ValidatorData, HookType, ExchangeRateValidatorConfig} from "./ExchangeRateValidatorConfigLib.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/// @title ExchangeRateValidatorPreHook
/// @author IPOR Labs
/// @notice Pre-execution hook for validating and limiting exchange rate changes in Plasma Vault
/// @dev Implements IPreHook to validate exchange rate changes and execute pre/post hooks.
///      This hook validates the current exchange rate against an expected value with a configurable threshold.
///      If the deviation exceeds the threshold, the operation reverts. If within threshold but outside half-threshold,
///      the expected exchange rate is updated in substrates.
///
/// Key features:
/// - Exchange rate validation with configurable threshold
/// - Automatic exchange rate updates when within threshold
/// - Support for pre-hooks and post-hooks execution
/// - Configurable via substrates in market configuration
///
/// Security considerations:
/// - Protected by PlasmaVault's access control
/// - Uses delegatecall for hook execution
/// - Validates threshold values (must be <= 100%)
/// - Prevents exchange rate manipulation attacks
contract ExchangeRateValidatorPreHook is IPreHook {
    /// @notice Market identifier associated with this pre-hook implementation
    /// @dev Mirrors fuse pattern: immutable MARKET_ID set at construction
    uint256 public immutable MARKET_ID;
    uint256 private constant _ONE = 1e18;

    error ExchangeRateOutOfRange(uint256 current, uint256 expected, uint256 threshold);
    error ThresholdTooHigh(uint256 threshold);

    /// @notice Emitted when exchange rate is updated in substrates
    /// @param oldExchangeRate Previous exchange rate value
    /// @param newExchangeRate New exchange rate value
    /// @param threshold Threshold used for validation
    event ExchangeRateUpdated(uint256 oldExchangeRate, uint256 newExchangeRate, uint256 threshold);

    /// @param marketId_ Market identifier to bind this pre-hook to
    constructor(uint256 marketId_) {
        MARKET_ID = marketId_;
    }

    /// @notice Executes the pre-hook logic before the main vault operation
    /// @dev Execution flow:
    ///      1. Loads substrates for MARKET_ID from config
    ///      2. Parses configs to extract pre-hooks, post-hooks, and validator data
    ///      3. Executes pre-hooks in order
    ///      4. Validates exchange rate and updates if needed
    ///      5. Executes post-hooks in order
    ///
    /// If no substrates are configured, the hook returns early without validation.
    /// @param selector_ The function selector of the main operation that will be executed
    function run(bytes4 selector_) external {
        bytes32[] storage substrates = PlasmaVaultConfigLib.getMarketSubstratesStorage(MARKET_ID).substrates;
        if (substrates.length == 0) {
            return;
        }

        (
            Hook[] memory preHooks,
            Hook[] memory postHooks,
            ValidatorData memory validationData,
            uint256 validatorIndex
        ) = ExchangeRateValidatorConfigLib.parseConfigs(substrates);

        _runHooks(selector_, preHooks);
        _runValidator(substrates, validatorIndex, validationData);
        _runHooks(selector_, postHooks);
    }

    /// @notice Calculates the current exchange rate in the PlasmaVault context
    /// @dev Must be called via delegatecall from the PlasmaVault to operate on its context.
    ///      Uses ERC-4626 convertToAssets for a full share unit, ensuring consistency with
    ///      vault fee logic and decimals offset handling.
    /// @return exchangeRate Assets per 1 share (assets in underlying token decimals for 1 share)
    function calculateExchangeRate() internal view returns (uint256 exchangeRate) {
        uint256 shareDecimals = IERC4626(address(this)).decimals();
        exchangeRate = IERC4626(address(this)).convertToAssets(10 ** shareDecimals);
    }

    /// @notice Executes a sequence of hooks via delegatecall to `run(bytes4)` on each hook address
    /// @dev Skips empty entries (address(0)). Uses OZ Address.functionDelegateCall to bubble reverts.
    /// @param selector_ Function selector to pass into each hook's run method
    /// @param hooks_ Array of Hook entries containing target addresses
    function _runHooks(bytes4 selector_, Hook[] memory hooks_) private {
        uint256 length = hooks_.length;
        for (uint256 i; i < length; ++i) {
            address implementation = hooks_[i].hookAddress;
            if (implementation == address(0)) {
                break;
            }
            Address.functionDelegateCall(implementation, abi.encodeWithSelector(IPreHook.run.selector, selector_));
        }
    }

    /// @notice Validates current exchange rate against expected with +/- threshold tolerance
    /// @dev Threshold is in 1e18 precision where 1e18 = 100%.
    ///      If |deviation| <= threshold/2, do not update substrates.
    ///      If threshold/2 < |deviation| <= threshold, update validator config in substrates at validatorIndex_.
    ///      If |deviation| > threshold, revert.
    /// @param substrates_ Raw substrates storage array
    /// @param validatorIndex_ Index of validator entry in substrates
    /// @param validationData_ Decoded validator data containing expected exchangeRate and threshold
    function _runValidator(
        bytes32[] storage substrates_,
        uint256 validatorIndex_,
        ValidatorData memory validationData_
    ) private {
        if (validatorIndex_ == type(uint256).max) {
            return;
        }

        uint256 current = calculateExchangeRate();
        uint256 expected = uint256(validationData_.exchangeRate);
        uint256 threshold = uint256(validationData_.threshold);

        if (threshold > _ONE) {
            revert ThresholdTooHigh(threshold);
        }

        uint256 upper = (expected * (_ONE + threshold)) / _ONE;
        uint256 lower = (expected * (_ONE - threshold)) / _ONE;

        if (current < lower || current > upper) {
            revert ExchangeRateOutOfRange(current, expected, threshold);
        }

        // Half-threshold band
        uint256 half = threshold / 2;
        uint256 upperHalf = (expected * (_ONE + half)) / _ONE;
        uint256 lowerHalf = (expected * (_ONE - half)) / _ONE;

        // If outside half band but within full band, update validator exchangeRate in substrates
        if (current < lowerHalf || current > upperHalf) {
            // Keep same threshold, update exchangeRate to current
            ValidatorData memory updated = ValidatorData({
                exchangeRate: uint128(current),
                threshold: validationData_.threshold
            });
            bytes31 encodedValidator = ExchangeRateValidatorConfigLib.validatorDataToBytes31(updated);
            bytes32 updatedConfig = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(
                ExchangeRateValidatorConfig({typ: HookType.VALIDATOR, data: encodedValidator})
            );
            substrates_[validatorIndex_] = updatedConfig;
            emit ExchangeRateUpdated(expected, current, threshold);
        }
    }
}
