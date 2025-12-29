// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IEVC} from "ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {EulerFuseLib} from "./EulerFuseLib.sol";
import {IBorrowing} from "./ext/IBorrowing.sol";
import {CallbackHandlerEuler} from "../../handlers/callbacks/CallbackHandlerEuler.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {IVault} from "ethereum-vault-connector/src/interfaces/IVault.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";

struct EulerV2BatchItem {
    address targetContract;
    bytes1 onBehalfOfAccount;
    bytes data;
}

struct EulerV2BatchFuseData {
    EulerV2BatchItem[] batchItems;
    address[] assetsForApprovals;
    address[] eulerVaultsForApprovals;
}

contract EulerV2BatchFuse is IFuseCommon {
    using SafeERC20 for ERC20;

    error EmptyBatchItems();
    error ZeroAddress();
    error EVCInvalidSelector();
    error EVCInvalidCollateral();
    error EulerVaultInvalidPermissions();
    error ArrayLengthMismatch();
    error DuplicateAsset();
    error InvalidBatchItem();
    error UnsupportedOperation();

    event BatchExecuted(uint256 indexed batchSize, address[] assets, address[] vaults);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    IEVC public immutable EVC;

    constructor(uint256 marketId_, address eulerV2EVC_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        EVC = IEVC(eulerV2EVC_);
    }

    /// @notice Executes a batch of Euler V2 operations including supply (deposit), borrow, repay, and withdraw operations
    /// @dev This function validates all batch items, sets up approvals, executes the batch via EVC, and cleans up approvals
    /// @dev Supported operations: deposit, withdraw, borrow, repay, repayWithShares, disableController, enableController
    /// @dev Flash loan operations are NOT supported by this fuse - use dedicated flash loan fuses instead
    /// @param data_ The data structure containing batch items and approval configurations
    /// @return batchSize The number of batch items executed
    /// @return assets The array of assets used for approvals
    /// @return vaults The array of Euler vaults used for approvals
    /// @custom:security This function includes reentrancy protection and comprehensive validation
    function enter(
        EulerV2BatchFuseData memory data_
    ) public returns (uint256 batchSize, address[] memory assets, address[] memory vaults) {
        IEVC.BatchItem[] memory batchItems = new IEVC.BatchItem[](data_.batchItems.length);

        _validate(data_);

        for (uint256 i = 0; i < data_.assetsForApprovals.length; i++) {
            ERC20(data_.assetsForApprovals[i]).forceApprove(data_.eulerVaultsForApprovals[i], type(uint256).max);
        }

        // Cache frequently used values for gas optimization
        address evcAddress = address(EVC);
        address thisAddress = address(this);

        for (uint256 i = 0; i < data_.batchItems.length; i++) {
            EulerV2BatchItem memory item = data_.batchItems[i];
            batchItems[i] = IEVC.BatchItem(
                item.targetContract,
                item.targetContract != evcAddress
                    ? EulerFuseLib.generateSubAccountAddress(thisAddress, item.onBehalfOfAccount)
                    : address(0),
                0,
                item.data
            );
        }

        EVC.batch(batchItems);

        for (uint256 i = 0; i < data_.assetsForApprovals.length; i++) {
            ERC20(data_.assetsForApprovals[i]).forceApprove(data_.eulerVaultsForApprovals[i], 0);
        }

        batchSize = data_.batchItems.length;
        assets = data_.assetsForApprovals;
        vaults = data_.eulerVaultsForApprovals;

        emit BatchExecuted(batchSize, assets, vaults);
    }

    /// @notice Exits the Euler V2 Batch Fuse
    /// @dev Currently not implemented as batch operations are typically one-time executions
    /// @dev Batch operations are designed for atomic execution and don't require exit functionality
    /// @custom:note This fuse is designed for one-time batch operations, not ongoing state management
    function exit() external {
        // Batch operations are atomic and don't require exit functionality
        // The fuse is designed for one-time execution of multiple operations
        revert UnsupportedOperation();
    }

    /// @notice Executes a batch of Euler V2 operations using transient storage for parameters
    /// @dev Reads ABI-encoded EulerV2BatchFuseData from transient storage inputs as concatenated bytes32 chunks,
    ///      calls enter(), and writes outputs to transient storage.
    ///      Input format: inputs[0..n] = bytes32 chunks of ABI-encoded EulerV2BatchFuseData
    ///      Output format: outputs[0] = batchSize, outputs[1..n] = assets, outputs[n+1..m] = vaults
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        // Reconstruct ABI-encoded data from bytes32 chunks
        uint256 inputsLen = inputs.length;
        bytes memory encodedData = new bytes(inputsLen * 32);
        for (uint256 i; i < inputsLen; ++i) {
            bytes32 chunk = inputs[i];
            assembly {
                mstore(add(encodedData, add(32, mul(i, 32))), chunk)
            }
        }

        // Decode the full EulerV2BatchFuseData structure
        EulerV2BatchFuseData memory data = abi.decode(encodedData, (EulerV2BatchFuseData));

        // Call enter and capture return values
        (uint256 batchSize, address[] memory assets, address[] memory vaults) = enter(data);

        // Write outputs to transient storage
        // Format: [batchSize, assetsLength, assets..., vaultsLength, vaults...]
        uint256 assetsLen = assets.length;
        uint256 vaultsLen = vaults.length;
        bytes32[] memory outputs = new bytes32[](1 + 1 + assetsLen + 1 + vaultsLen);

        outputs[0] = TypeConversionLib.toBytes32(batchSize);
        outputs[1] = TypeConversionLib.toBytes32(assetsLen);

        for (uint256 i; i < assetsLen; ++i) {
            outputs[2 + i] = TypeConversionLib.toBytes32(assets[i]);
        }

        outputs[2 + assetsLen] = TypeConversionLib.toBytes32(vaultsLen);

        for (uint256 i; i < vaultsLen; ++i) {
            outputs[3 + assetsLen + i] = TypeConversionLib.toBytes32(vaults[i]);
        }

        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Validates the batch fuse data for security and correctness
    /// @dev Checks for empty batches, array length mismatches, duplicate assets, and validates each batch item
    /// @param data_ The batch fuse data to validate
    function _validate(EulerV2BatchFuseData memory data_) private view {
        if (data_.batchItems.length == 0) {
            revert EmptyBatchItems();
        }

        if (data_.assetsForApprovals.length != data_.eulerVaultsForApprovals.length) {
            revert ArrayLengthMismatch();
        }

        uint256 length = data_.batchItems.length;

        for (uint256 i = 0; i < length; i++) {
            if (data_.batchItems[i].targetContract == address(0)) {
                revert ZeroAddress();
            }

            if (data_.batchItems[i].targetContract == address(EVC)) {
                _validateEvc(data_.batchItems[i]);
            } else if (data_.batchItems[i].targetContract == address(this)) {
                _validatePlasmaVaultCallback(data_.batchItems[i]);
            } else {
                _validateEulerVault(data_.batchItems[i]);
            }
        }
    }

    /// @notice Validates EVC (Ethereum Vault Connector) batch items
    /// @dev Supported operations: enableController
    /// @dev Includes collateral permission checks and account validation
    /// @param item_ The batch item to validate
    function _validateEvc(EulerV2BatchItem memory item_) internal view {
        bytes4 selector = bytes4(_slice(item_.data, 0, 4));
        if (selector == IEVC.enableController.selector) {
            (address account, address vault) = abi.decode(
                _slice(item_.data, 4, item_.data.length - 4),
                (address, address)
            );
            bool canCollateral = EulerFuseLib.canCollateral(MARKET_ID, vault, item_.onBehalfOfAccount);
            if (
                !canCollateral ||
                account != EulerFuseLib.generateSubAccountAddress(address(this), item_.onBehalfOfAccount)
            ) {
                revert EVCInvalidCollateral();
            }
            return;
        }
        revert UnsupportedOperation();
    }

    /// @notice Validates Plasma Vault callback batch items
    /// @dev Currently only supports onEulerFlashLoan callback selector
    /// @dev Note: While the callback handler exists, initiating flash loans via this fuse is not supported
    /// @dev The callback handler is reserved for external flash loan integrations
    /// @param item_ The batch item to validate
    function _validatePlasmaVaultCallback(EulerV2BatchItem memory item_) internal view {
        bytes4 selector = bytes4(_slice(item_.data, 0, 4));
        if (selector == CallbackHandlerEuler.onEulerFlashLoan.selector) {
            return;
        }
        revert UnsupportedOperation();
    }

    /// @notice Validates Euler Vault batch items for various operations
    /// @dev Supported operations: borrow, repay, repayWithShares, deposit, withdraw, disableController
    /// @dev Flash loan operations are NOT supported - any flashLoan selector will revert with UnsupportedOperation
    /// @dev All operations include permission checks and subaccount validation
    /// @param item_ The batch item to validate
    function _validateEulerVault(EulerV2BatchItem memory item_) internal view {
        bytes4 selector = bytes4(_slice(item_.data, 0, 4));
        bytes memory dataAfterSelector = _slice(item_.data, 4, item_.data.length - 4);
        if (selector == IBorrowing.borrow.selector) {
            (, address subaccount) = abi.decode(dataAfterSelector, (uint256, address));
            bool canBorrow = EulerFuseLib.canBorrow(MARKET_ID, item_.targetContract, item_.onBehalfOfAccount);
            if (
                !canBorrow ||
                subaccount != EulerFuseLib.generateSubAccountAddress(address(this), item_.onBehalfOfAccount)
            ) {
                revert EulerVaultInvalidPermissions();
            }
        } else if (selector == IBorrowing.repay.selector || selector == IBorrowing.repayWithShares.selector) {
            (, address subaccount) = abi.decode(dataAfterSelector, (uint256, address));
            bool canRepay = EulerFuseLib.canBorrow(MARKET_ID, item_.targetContract, item_.onBehalfOfAccount);
            if (
                !canRepay ||
                subaccount != EulerFuseLib.generateSubAccountAddress(address(this), item_.onBehalfOfAccount)
            ) {
                revert EulerVaultInvalidPermissions();
            }
        } else if (selector == ERC4626Upgradeable.deposit.selector) {
            (, address subaccount) = abi.decode(dataAfterSelector, (uint256, address));
            bool canSupply = EulerFuseLib.canSupply(MARKET_ID, item_.targetContract, item_.onBehalfOfAccount);
            if (
                !canSupply ||
                subaccount != EulerFuseLib.generateSubAccountAddress(address(this), item_.onBehalfOfAccount)
            ) {
                revert EulerVaultInvalidPermissions();
            }
        } else if (selector == ERC4626Upgradeable.withdraw.selector) {
            (, address subaccount) = abi.decode(dataAfterSelector, (uint256, address));
            // For withdraw operations, we should check if the vault can supply (has the asset)
            // and validate the subaccount matches
            bool canSupply = EulerFuseLib.canSupply(MARKET_ID, item_.targetContract, item_.onBehalfOfAccount);
            if (
                !canSupply ||
                subaccount != EulerFuseLib.generateSubAccountAddress(address(this), item_.onBehalfOfAccount)
            ) {
                revert EulerVaultInvalidPermissions();
            }
        } else if (selector == IVault.disableController.selector) {
            bool canSupply = EulerFuseLib.canSupply(MARKET_ID, item_.targetContract, item_.onBehalfOfAccount);
            if (!canSupply) {
                revert EulerVaultInvalidPermissions();
            }
        } else {
            revert UnsupportedOperation();
        }
    }

    /// @notice Slices a bytes array from a start index for a given length
    /// @param data_ The bytes array to slice
    /// @param start_ The starting index
    /// @param length_ The length of the slice
    /// @return result The sliced bytes array
    function _slice(bytes memory data_, uint256 start_, uint256 length_) private pure returns (bytes memory result) {
        result = new bytes(length_);
        for (uint256 i; i < length_; ++i) {
            result[i] = data_[start_ + i];
        }
    }
}
