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

    /// @notice Executes a batch of Euler V2 operations including supply, borrow, repay, and flash loan operations
    /// @dev This function validates all batch items, sets up approvals, executes the batch via EVC, and cleans up approvals
    /// @param data_ The data structure containing batch items and approval configurations
    /// @custom:security This function includes reentrancy protection and comprehensive validation
    function enter(EulerV2BatchFuseData calldata data_) external {
        IEVC.BatchItem[] memory batchItems = new IEVC.BatchItem[](data_.batchItems.length);

        _validate(data_);

        for (uint256 i = 0; i < data_.assetsForApprovals.length; i++) {
            ERC20(data_.assetsForApprovals[i]).forceApprove(data_.eulerVaultsForApprovals[i], type(uint256).max);
        }

        // Cache frequently used values for gas optimization
        address evcAddress = address(EVC);
        address thisAddress = address(this);

        for (uint256 i = 0; i < data_.batchItems.length; i++) {
            EulerV2BatchItem calldata item = data_.batchItems[i];
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

        emit BatchExecuted(data_.batchItems.length, data_.assetsForApprovals, data_.eulerVaultsForApprovals);
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

    /// @notice Validates the batch fuse data for security and correctness
    /// @dev Checks for empty batches, array length mismatches, duplicate assets, and validates each batch item
    /// @param data_ The batch fuse data to validate
    function _validate(EulerV2BatchFuseData calldata data_) private view {
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
    /// @dev Currently only supports enableController selector with proper collateral validation
    /// @param item_ The batch item to validate
    function _validateEvc(EulerV2BatchItem calldata item_) internal view {
        bytes4 selector = bytes4(item_.data[:4]);
        if (selector == IEVC.enableController.selector) {
            (address account, address vault) = abi.decode(item_.data[4:], (address, address));
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
    /// @param item_ The batch item to validate
    function _validatePlasmaVaultCallback(EulerV2BatchItem calldata item_) internal view {
        bytes4 selector = bytes4(item_.data[:4]);
        if (selector == CallbackHandlerEuler.onEulerFlashLoan.selector) {
            return;
        }
        revert UnsupportedOperation();
    }

    /// @notice Validates Euler Vault batch items for various operations
    /// @dev Supports borrow, repay, deposit, withdraw, and disableController operations with proper permission checks
    /// @param item_ The batch item to validate
    function _validateEulerVault(EulerV2BatchItem calldata item_) internal view {
        bytes4 selector = bytes4(item_.data[:4]);
        if (selector == IBorrowing.borrow.selector) {
            (, address subaccount) = abi.decode(item_.data[4:], (uint256, address));
            bool canBorrow = EulerFuseLib.canBorrow(MARKET_ID, item_.targetContract, item_.onBehalfOfAccount);
            if (
                !canBorrow ||
                subaccount != EulerFuseLib.generateSubAccountAddress(address(this), item_.onBehalfOfAccount)
            ) {
                revert EulerVaultInvalidPermissions();
            }
        } else if (selector == IBorrowing.repay.selector || selector == IBorrowing.repayWithShares.selector) {
            (, address subaccount) = abi.decode(item_.data[4:], (uint256, address));
            bool canRepay = EulerFuseLib.canBorrow(MARKET_ID, item_.targetContract, item_.onBehalfOfAccount);
            if (
                !canRepay ||
                subaccount != EulerFuseLib.generateSubAccountAddress(address(this), item_.onBehalfOfAccount)
            ) {
                revert EulerVaultInvalidPermissions();
            }
        } else if (selector == ERC4626Upgradeable.deposit.selector) {
            (, address subaccount) = abi.decode(item_.data[4:], (uint256, address));
            bool canSupply = EulerFuseLib.canSupply(MARKET_ID, item_.targetContract, item_.onBehalfOfAccount);
            if (
                !canSupply ||
                subaccount != EulerFuseLib.generateSubAccountAddress(address(this), item_.onBehalfOfAccount)
            ) {
                revert EulerVaultInvalidPermissions();
            }
        } else if (selector == ERC4626Upgradeable.withdraw.selector) {
            (, address subaccount) = abi.decode(item_.data[4:], (uint256, address));
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
}
