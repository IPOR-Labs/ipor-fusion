// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IEVC} from "ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {EulerFuseLib} from "./EulerFuseLib.sol";
import {IBorrowing} from "./ext/IBorrowing.sol";
import {CallbackHandlerEuler} from "../../handlers/callbacks/CallbackHandlerEuler.sol";
import {CallbackData} from "../../libraries/CallbackHandlerLib.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {IVault} from "ethereum-vault-connector/src/interfaces/IVault.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";

struct EulerV2BatchItem {
    address targetContract;
    bytes1 onBehalfOfAccount;
    bytes data;
}

/// @notice Data structure for entering the Euler V2 Batch Fuse
/// @param batchItems The batch items executed through `EVC.batch`
/// @param assetsForApprovals The tokens approved for the batch; `assetsForApprovals[i]` must be the `asset()` of
///        `eulerVaultsForApprovals[i]`
/// @param eulerVaultsForApprovals The Euler vaults approved to pull `assetsForApprovals[i]` during the batch; each
///        must be granted in an EULER_V2 substrate of the market
struct EulerV2BatchFuseData {
    EulerV2BatchItem[] batchItems;
    address[] assetsForApprovals;
    address[] eulerVaultsForApprovals;
}

contract EulerV2BatchFuse is IFuseCommon {
    using SafeERC20 for ERC20;

    error EulerV2BatchFuseEmptyBatchItems();
    error EulerV2BatchFuseZeroAddress();
    error EulerV2BatchFuseInvalidController(address account, address eulerVault);
    error EulerV2BatchFuseInvalidVaultPermissions();
    error EulerV2BatchFuseArrayLengthMismatch();
    error EulerV2BatchFuseUnsupportedOperation();

    /// @notice Thrown when an approval pair is not (the `asset()` of a granted Euler vault, that Euler vault)
    /// @param asset The token of the rejected approval pair
    /// @param eulerVault The Euler vault (spender) of the rejected approval pair
    /// @custom:error EulerV2BatchFuseInvalidApprovalPair
    error EulerV2BatchFuseInvalidApprovalPair(address asset, address eulerVault);

    /// @notice Thrown when a Plasma Vault callback item approves a pair that is not one of the declared approval pairs
    /// @param asset The token of the callback approval (`CallbackData.asset`)
    /// @param spender The spender of the callback approval (`CallbackData.addressToApprove`)
    /// @custom:error EulerV2BatchFuseInvalidCallbackApproval
    error EulerV2BatchFuseInvalidCallbackApproval(address asset, address spender);

    /// @notice Emitted after a batch has been executed and the approvals have been reset
    /// @param version The address of this fuse (`VERSION`), identifies the fuse build that executed the batch
    /// @param batchSize The number of batch items executed
    /// @param assets The tokens of the approval pairs
    /// @param vaults The Euler vaults (spenders) of the approval pairs
    event EulerV2BatchFuseExecuted(address version, uint256 batchSize, address[] assets, address[] vaults);

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
    /// @dev Reentrancy protection inherited from PlasmaVault.execute() via delegatecall execution pattern
    /// @dev Supported operations: deposit, withdraw, borrow, repay, repayWithShares, disableController, enableController
    /// @dev Flash liquidity runs as borrow -> Plasma Vault callback (`onEulerFlashLoan`) -> repay inside one
    ///      `EVC.batch`, with the account checks deferred to the end of the batch; the EVK `flashLoan` selector is
    ///      not supported. A callback item may approve only one of the declared approval pairs (see
    ///      `_validatePlasmaVaultCallback`), so the reset after the batch also clears the callback approval, and the
    ///      vault's CallbackHandlerEuler accepts the callback only from an EVC account of the vault itself
    /// @dev The EVC `onBehalfOfAccount` of each item depends on its target and selector (see `_onBehalfOfAccount` and
    ///      `_validateEulerVault`): EVault deposit and repay are paid by the Plasma Vault, other EVault operations run on
    ///      behalf of the sub-account, and the tokens of borrow and withdraw are received by the Plasma Vault
    /// @dev Every approval pair is validated in `_validate` before any approval or EVC call (validation only makes
    ///      `asset()` view calls on granted Euler vaults): `eulerVaultsForApprovals[i]`
    ///      must be granted in an EULER_V2 substrate and `assetsForApprovals[i]` must be its `asset()`; each pair
    ///      is approved for `type(uint256).max` for the batch and reset to 0 after it
    /// @param data_ The data structure containing batch items and approval configurations
    /// @return batchSize The number of batch items executed
    /// @return assets The array of assets used for approvals
    /// @return vaults The array of Euler vaults used for approvals
    /// @custom:security Reentrancy protection via PlasmaVault.execute() and comprehensive validation of all batch items
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
                _onBehalfOfAccount(item, evcAddress, thisAddress),
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

        emit EulerV2BatchFuseExecuted(VERSION, batchSize, assets, vaults);
    }

    /// @notice Exits the Euler V2 Batch Fuse
    /// @dev Currently not implemented as batch operations are typically one-time executions
    /// @dev Batch operations are designed for atomic execution and don't require exit functionality
    /// @custom:note This fuse is designed for one-time batch operations, not ongoing state management
    function exit() external {
        // Batch operations are atomic and don't require exit functionality
        // The fuse is designed for one-time execution of multiple operations
        revert EulerV2BatchFuseUnsupportedOperation();
    }

    /// @notice Executes a batch of Euler V2 operations using transient storage for parameters
    /// @dev Reads ABI-encoded EulerV2BatchFuseData from transient storage inputs as concatenated bytes32 chunks,
    ///      calls enter(), and writes outputs to transient storage.
    ///      Input format: inputs[0..n] = bytes32 chunks of ABI-encoded EulerV2BatchFuseData
    ///      Output format: [batchSize, assetsLength, assets[0], assets[1], ..., vaultsLength, vaults[0], vaults[1], ...]
    ///      - outputs[0] = batchSize (uint256)
    ///      - outputs[1] = assetsLength (uint256)
    ///      - outputs[2..2+assetsLength-1] = assets (address[])
    ///      - outputs[2+assetsLength] = vaultsLength (uint256)
    ///      - outputs[3+assetsLength..3+assetsLength+vaultsLength-1] = vaults (address[])
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

    /// @notice Selects the EVC `onBehalfOfAccount` of a batch item from its target and selector
    /// @dev EVC items run with `address(0)`. Plasma Vault callback items and every EVault operation that acts on the
    ///      sub-account's position (borrow, withdraw, repayWithShares, disableController) run on behalf of the
    ///      sub-account. EVault `deposit` and `repay` pull tokens from the account they run on behalf of, so they run on
    ///      behalf of the Plasma Vault, which holds the tokens and the approvals; the position is credited or reduced
    ///      through the receiver argument, which is validated to be the sub-account.
    /// @dev For sub-account 0x00 the sub-account is the Plasma Vault itself, so every role collapses to the same address
    /// @param item_ The batch item
    /// @param evcAddress_ The EVC address
    /// @param plasmaVault_ The Plasma Vault address (this contract in the delegatecall context)
    /// @return The account passed to the EVC as `onBehalfOfAccount`
    function _onBehalfOfAccount(
        EulerV2BatchItem memory item_,
        address evcAddress_,
        address plasmaVault_
    ) private pure returns (address) {
        if (item_.targetContract == evcAddress_) {
            return address(0);
        }
        if (item_.targetContract != plasmaVault_) {
            bytes4 selector = bytes4(_slice(item_.data, 0, 4));
            if (selector == IBorrowing.repay.selector || selector == ERC4626Upgradeable.deposit.selector) {
                return plasmaVault_;
            }
        }
        return EulerFuseLib.generateSubAccountAddress(plasmaVault_, item_.onBehalfOfAccount);
    }

    /// @notice Validates the batch fuse data for security and correctness
    /// @dev Checks for empty batches and array length mismatches, then validates every approval pair (see
    ///      `_validateApprovalPair`), then each batch item; `enter` makes no approval or EVC call before this returns;
    ///      the only external calls here are `asset()` views on granted Euler vaults
    /// @param data_ The batch fuse data to validate
    function _validate(EulerV2BatchFuseData memory data_) private view {
        if (data_.batchItems.length == 0) {
            revert EulerV2BatchFuseEmptyBatchItems();
        }

        if (data_.assetsForApprovals.length != data_.eulerVaultsForApprovals.length) {
            revert EulerV2BatchFuseArrayLengthMismatch();
        }

        uint256 approvalsLength = data_.assetsForApprovals.length;
        for (uint256 i; i < approvalsLength; ++i) {
            _validateApprovalPair(data_.assetsForApprovals[i], data_.eulerVaultsForApprovals[i]);
        }

        uint256 length = data_.batchItems.length;

        for (uint256 i = 0; i < length; i++) {
            if (data_.batchItems[i].targetContract == address(0)) {
                revert EulerV2BatchFuseZeroAddress();
            }

            if (data_.batchItems[i].targetContract == address(EVC)) {
                _validateEvc(data_.batchItems[i]);
            } else if (data_.batchItems[i].targetContract == address(this)) {
                _validatePlasmaVaultCallback(data_.batchItems[i], data_);
            } else {
                _validateEulerVault(data_.batchItems[i]);
            }
        }
    }

    /// @notice Validates one approval pair of the batch
    /// @dev The Euler vault must be granted in any EULER_V2 substrate of the market (flags and sub-account are not
    ///      checked) and the token must be that vault's `asset()`, as in EulerV2SupplyFuse and EulerV2BorrowFuse.
    ///      `asset()` is called only after the grant check passed, so an ungranted address never receives a call.
    /// @param asset_ The token to approve
    /// @param eulerVault_ The Euler vault to approve as the spender
    function _validateApprovalPair(address asset_, address eulerVault_) private view {
        if (
            !EulerFuseLib.isEulerVaultGranted(MARKET_ID, eulerVault_) ||
            ERC4626Upgradeable(eulerVault_).asset() != asset_
        ) {
            revert EulerV2BatchFuseInvalidApprovalPair(asset_, eulerVault_);
        }
    }

    /// @notice Validates EVC (Ethereum Vault Connector) batch items
    /// @dev Supported operations: enableController
    /// @dev The vault must be granted to the sub-account with `canBorrow`, like in EulerV2ControllerFuse: enabling a
    ///      controller allows the vault to take control of the sub-account's position and to borrow against it
    /// @dev Reverts with `EulerV2BatchFuseInvalidController` when `canBorrow` is missing or the account is wrong
    /// @param item_ The batch item to validate
    function _validateEvc(EulerV2BatchItem memory item_) internal view {
        bytes4 selector = bytes4(_slice(item_.data, 0, 4));
        if (selector == IEVC.enableController.selector) {
            (address account, address vault) = abi.decode(
                _slice(item_.data, 4, item_.data.length - 4),
                (address, address)
            );
            bool canBorrow = EulerFuseLib.canBorrow(MARKET_ID, vault, item_.onBehalfOfAccount);
            if (
                !canBorrow || account != EulerFuseLib.generateSubAccountAddress(address(this), item_.onBehalfOfAccount)
            ) {
                revert EulerV2BatchFuseInvalidController(account, vault);
            }
            return;
        }
        revert EulerV2BatchFuseUnsupportedOperation();
    }

    /// @notice Validates Plasma Vault callback batch items
    /// @dev Only the `onEulerFlashLoan` selector is supported. The EVC calls the Plasma Vault, whose fallback runs the
    ///      registered CallbackHandlerEuler and then `CallbackHandlerLib.handleCallback`: the inner fuse actions
    ///      through `executeInternal`, then `forceApprove(asset, addressToApprove, amountToApprove)`.
    /// @dev The payload is decoded as `CallbackData` (a malformed payload reverts) and `(asset, addressToApprove)`
    ///      must equal one declared approval pair `(assetsForApprovals[j], eulerVaultsForApprovals[j])`, which
    ///      `_validateApprovalPair` validated and `enter` resets to 0 after the batch. `amountToApprove` is not
    ///      restricted because of that reset; `actionData` is not validated here because `executeInternal` runs
    ///      only the vault's supported fuses.
    /// @param item_ The batch item to validate
    /// @param data_ The batch fuse data with the declared approval pairs
    function _validatePlasmaVaultCallback(
        EulerV2BatchItem memory item_,
        EulerV2BatchFuseData memory data_
    ) internal pure {
        bytes4 selector = bytes4(_slice(item_.data, 0, 4));
        if (selector != CallbackHandlerEuler.onEulerFlashLoan.selector) {
            revert EulerV2BatchFuseUnsupportedOperation();
        }
        CallbackData memory callbackData = abi.decode(
            abi.decode(_slice(item_.data, 4, item_.data.length - 4), (bytes)),
            (CallbackData)
        );
        uint256 approvalsLength = data_.assetsForApprovals.length;
        for (uint256 i; i < approvalsLength; ++i) {
            if (
                data_.assetsForApprovals[i] == callbackData.asset &&
                data_.eulerVaultsForApprovals[i] == callbackData.addressToApprove
            ) {
                return;
            }
        }
        revert EulerV2BatchFuseInvalidCallbackApproval(callbackData.asset, callbackData.addressToApprove);
    }

    /// @notice Validates Euler Vault batch items for various operations
    /// @dev Supported operations: borrow, repay, repayWithShares, deposit, withdraw, disableController
    /// @dev Roles per selector (sub-account = Plasma Vault XOR `onBehalfOfAccount` id, equal to the Plasma Vault for 0x00):
    ///      - borrow(amount, receiver): receiver must be the Plasma Vault; runs on behalf of the sub-account
    ///      - withdraw(assets, receiver, owner): receiver must be the Plasma Vault, owner must be the sub-account;
    ///        runs on behalf of the sub-account
    ///      - deposit(assets, receiver): receiver must be the sub-account; runs on behalf of the Plasma Vault (payer)
    ///      - repay(amount, receiver): receiver (debt holder) must be the sub-account; runs on behalf of the Plasma
    ///        Vault (payer)
    ///      - repayWithShares(amount, receiver): receiver (debt holder) must be the sub-account; runs on behalf of the
    ///        sub-account, which owns the shares
    /// @dev Flash loan operations are NOT supported - any flashLoan selector will revert with EulerV2BatchFuseUnsupportedOperation
    /// @dev All operations include permission checks and subaccount validation
    /// @param item_ The batch item to validate
    function _validateEulerVault(EulerV2BatchItem memory item_) internal view {
        bytes4 selector = bytes4(_slice(item_.data, 0, 4));
        bytes memory dataAfterSelector = _slice(item_.data, 4, item_.data.length - 4);
        if (selector == IBorrowing.borrow.selector) {
            // borrow(uint256 amount, address receiver): the borrowed tokens go to the Plasma Vault
            (, address receiver) = abi.decode(dataAfterSelector, (uint256, address));
            bool canBorrow = EulerFuseLib.canBorrow(MARKET_ID, item_.targetContract, item_.onBehalfOfAccount);
            if (!canBorrow || receiver != address(this)) {
                revert EulerV2BatchFuseInvalidVaultPermissions();
            }
        } else if (selector == IBorrowing.repay.selector || selector == IBorrowing.repayWithShares.selector) {
            (, address subaccount) = abi.decode(dataAfterSelector, (uint256, address));
            // Repaying only requires the granted (vault, sub-account) entry, not `canBorrow`: a position must stay
            // repayable after the borrow right was revoked. The entry check stays: only granted vaults are paid.
            bool canRepay = EulerFuseLib.canSupply(MARKET_ID, item_.targetContract, item_.onBehalfOfAccount);
            if (
                !canRepay ||
                subaccount != EulerFuseLib.generateSubAccountAddress(address(this), item_.onBehalfOfAccount)
            ) {
                revert EulerV2BatchFuseInvalidVaultPermissions();
            }
        } else if (selector == ERC4626Upgradeable.deposit.selector) {
            (, address subaccount) = abi.decode(dataAfterSelector, (uint256, address));
            bool canSupply = EulerFuseLib.canSupply(MARKET_ID, item_.targetContract, item_.onBehalfOfAccount);
            if (
                !canSupply ||
                subaccount != EulerFuseLib.generateSubAccountAddress(address(this), item_.onBehalfOfAccount)
            ) {
                revert EulerV2BatchFuseInvalidVaultPermissions();
            }
        } else if (selector == ERC4626Upgradeable.withdraw.selector) {
            // withdraw(uint256 assets, address receiver, address owner): the assets go to the Plasma Vault and
            // the shares are burned from the sub-account
            (, address receiver, address owner) = abi.decode(dataAfterSelector, (uint256, address, address));
            bool canSupply = EulerFuseLib.canSupply(MARKET_ID, item_.targetContract, item_.onBehalfOfAccount);
            if (
                !canSupply ||
                receiver != address(this) ||
                owner != EulerFuseLib.generateSubAccountAddress(address(this), item_.onBehalfOfAccount)
            ) {
                revert EulerV2BatchFuseInvalidVaultPermissions();
            }
        } else if (selector == IVault.disableController.selector) {
            bool canSupply = EulerFuseLib.canSupply(MARKET_ID, item_.targetContract, item_.onBehalfOfAccount);
            if (!canSupply) {
                revert EulerV2BatchFuseInvalidVaultPermissions();
            }
        } else {
            revert EulerV2BatchFuseUnsupportedOperation();
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
