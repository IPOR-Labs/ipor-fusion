// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {EulerFuseLib} from "./EulerFuseLib.sol";
import {IBorrowing} from "./ext/IBorrowing.sol";
import {IEVC} from "ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Data structure for entering the Euler V2 Borrow Fuse
/// @param eulerVault The address of the Euler vault
/// @param maxAmount The maximum amount to borrow
/// @param subAccount The sub-account identifier
struct EulerV2BorrowFuseEnterData {
    address eulerVault;
    uint256 maxAmount;
    bytes1 subAccount;
}

/// @notice Data structure for exiting the Euler V2 Borrow Fuse
/// @param eulerVault The address of the Euler vault
/// @param maxAmount The maximum amount to repay
/// @param subAccount The sub-account identifier
struct EulerV2BorrowFuseExitData {
    address eulerVault;
    uint256 maxAmount;
    bytes1 subAccount;
}

/// @title EulerV2BorrowFuse
/// @dev Fuse for Euler V2 vaults responsible for borrowing assets from Euler V2 vaults
contract EulerV2BorrowFuse is IFuseCommon {
    using SafeERC20 for ERC20;

    event EulerV2BorrowEnterFuse(address version, address eulerVault, uint256 borrowAmount, address subAccount);
    event EulerV2BorrowExitFuse(address version, address eulerVault, uint256 repayAmount, address subAccount);

    error EulerV2BorrowFuseUnsupportedEnterAction(address vault, bytes1 subAccount);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    IEVC public immutable EVC;

    constructor(uint256 marketId_, address eulerV2EVC_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        EVC = IEVC(eulerV2EVC_);
    }

    /// @notice Enters the Euler V2 Borrow Fuse with the specified parameters
    /// @param data_ The data structure containing the parameters for entering the Euler V2 Borrow Fuse
    function enter(EulerV2BorrowFuseEnterData memory data_) external {
        if (data_.maxAmount == 0) {
            return;
        }
        if (!EulerFuseLib.canBorrow(data_.eulerVault, data_.subAccount, MARKET_ID)) {
            revert EulerV2BorrowFuseUnsupportedEnterAction(data_.eulerVault, data_.subAccount);
        }

        address plasmaVault = address(this);

        address subAccount = EulerFuseLib.generateSubAccountAddress(plasmaVault, data_.subAccount);

        bytes memory borrowCalldata = abi.encodeWithSelector(IBorrowing.borrow.selector, data_.maxAmount, plasmaVault);

        /* solhint-disable avoid-low-level-calls */
        uint256 borrowedAmount = abi.decode(EVC.call(data_.eulerVault, subAccount, 0, borrowCalldata), (uint256));
        /* solhint-enable avoid-low-level-calls */

        emit EulerV2BorrowEnterFuse(VERSION, data_.eulerVault, borrowedAmount, subAccount);
    }

    /// @notice Exits the Euler V2 Borrow Fuse with the specified parameters
    /// @param data_ The data structure containing the parameters for exiting the Euler V2 Borrow Fuse
    function exit(EulerV2BorrowFuseExitData memory data_) external {
        if (data_.maxAmount == 0) {
            return;
        }
        if (!EulerFuseLib.canBorrow(data_.eulerVault, data_.subAccount, MARKET_ID)) {
            revert EulerV2BorrowFuseUnsupportedEnterAction(data_.eulerVault, data_.subAccount);
        }

        address plasmaVault = address(this);

        address subAccount = EulerFuseLib.generateSubAccountAddress(plasmaVault, data_.subAccount);

        address asset = ERC4626Upgradeable(data_.eulerVault).asset();

        ERC20(asset).forceApprove(data_.eulerVault, type(uint256).max);

        /* solhint-disable avoid-low-level-calls */
        uint256 repaidAmount = abi.decode(
            EVC.call(
                data_.eulerVault,
                plasmaVault,
                0,
                abi.encodeWithSelector(IBorrowing.repay.selector, data_.maxAmount, subAccount)
            ),
            (uint256)
        );
        /* solhint-enable avoid-low-level-calls */

        ERC20(asset).forceApprove(data_.eulerVault, 0);

        emit EulerV2BorrowExitFuse(VERSION, data_.eulerVault, repaidAmount, subAccount);
    }
}
