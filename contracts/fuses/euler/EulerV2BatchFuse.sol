// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

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

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    IEVC public immutable EVC;

    constructor(uint256 marketId_, address eulerV2EVC_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        EVC = IEVC(eulerV2EVC_);
    }

    /// @notice Enters the Euler V2 Supply Fuse with the specified parameters
    /// @param data_ The data structure containing the parameters for entering the Euler V2 Supply Fuse
    function enter(EulerV2BatchFuseData calldata data_) external {
        IEVC.BatchItem[] memory batchItems = new IEVC.BatchItem[](data_.batchItems.length);

        validate(data_);

        for (uint256 i = 0; i < data_.assetsForApprovals.length; i++) {
            ERC20(data_.assetsForApprovals[i]).forceApprove(data_.eulerVaultsForApprovals[i], type(uint256).max);
        }

        for (uint256 i = 0; i < data_.batchItems.length; i++) {
            batchItems[i] = IEVC.BatchItem(
                data_.batchItems[i].targetContract,
                data_.batchItems[i].targetContract != address(EVC)
                    ? EulerFuseLib.generateSubAccountAddress(address(this), data_.batchItems[i].onBehalfOfAccount)
                    : address(0),
                0,
                data_.batchItems[i].data
            );
        }

        EVC.batch(batchItems);

        for (uint256 i = 0; i < data_.assetsForApprovals.length; i++) {
            ERC20(data_.assetsForApprovals[i]).forceApprove(data_.eulerVaultsForApprovals[i], 0);
        }
    }

    function exit() external {
        // TODO: Implement exit functionality
        revert("Exit not implemented");
    }

    function validate(EulerV2BatchFuseData calldata data_) private view {
        if (data_.batchItems.length == 0) {
            revert EmptyBatchItems();
        }

        uint256 length = data_.batchItems.length;

        for (uint256 i = 0; i < length; i++) {
            if (data_.batchItems[i].targetContract == address(0)) {
                revert ZeroAddress();
            }

            if (data_.batchItems[i].targetContract == address(EVC)) {
                _vlidateEvc(data_.batchItems[i]);
            } else if (data_.batchItems[i].targetContract == address(this)) {
                _validPlasmaVaultCallBack(data_.batchItems[i]);
            } else {
                _validateEulerVault(data_.batchItems[i]);
            }
        }
    }

    function _vlidateEvc(EulerV2BatchItem calldata item_) internal view {
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
        revert EVCInvalidSelector();
    }

    function _validPlasmaVaultCallBack(EulerV2BatchItem calldata item_) internal view {
        bytes4 selector = bytes4(item_.data[:4]);
        if (selector == CallbackHandlerEuler.onEulerFlashLoan.selector) {
            return;
        }
        revert EVCInvalidSelector();
    }

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
            revert EVCInvalidSelector();
        }
    }
}
