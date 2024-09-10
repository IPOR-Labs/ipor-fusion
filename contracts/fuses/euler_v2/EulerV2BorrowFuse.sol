// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IFuse} from "../IFuse.sol";
import {IEVault} from "./ext/IEVault.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IEVC} from "../../../node_modules/ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";

/// @notice Structure for entering (borrow)Euler V2 vaults
struct EulerV2BorrowFuseEnterData {
    /// @notice EVault address to borrow from
    address vault;
    /// @notice asset amount to borrow
    uint256 amount;
}

/// @notice Structure for exiting (repay) from the Euler V2 protocol
struct EulerV2BorrowFuseExitData {
    /// @notice EVault address to repay to
    address vault;
    /// @notice borrowed asset amount to repay
    uint256 amount;
}

/// @title Fuse Euler V2 Borrow responsible for borrowing and repaying assets from Euler V2 vaults
/// @dev Substrates in this fuse are the EVaults that are used in Euler V2 for a given MARKET_ID
contract EulerV2BorrowFuse is IFuse {
    using SafeERC20 for ERC20;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    IEVC public immutable EVC = IEVC(0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383);

    event EulerV2BorrowEnterFuse(address version, address vault, uint256 amount);
    event EulerV2BorrowExitFuse(address version, address vault, uint256 repaidAmount);

    error EulerV2BorrowFuseUnsupportedVault(string action, address vault);

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    function enter(bytes calldata data_) external override {
        _enter(abi.decode(data_, (EulerV2BorrowFuseEnterData)));
    }

    function enter(EulerV2BorrowFuseEnterData memory data_) external {
        _enter(data_);
    }

    function exit(bytes calldata data_) external override {
        _exit(abi.decode(data_, (EulerV2BorrowFuseExitData)));
    }

    function exit(EulerV2BorrowFuseExitData calldata data_) external {
        _exit(data_);
    }

    function _enter(EulerV2BorrowFuseEnterData memory data_) internal {
        if (data_.amount == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.vault)) {
            revert EulerV2BorrowFuseUnsupportedVault("enter", data_.vault);
        }

        // Prepare the calldata for the borrow function
        bytes memory borrowCalldata = abi.encodeWithSelector(IEVault.borrow.selector, data_.amount, address(this));

        /* solhint-disable avoid-low-level-calls */
        uint256 borrowedAmount = abi.decode(EVC.call(data_.vault, address(this), 0, borrowCalldata), (uint256));
        emit EulerV2BorrowEnterFuse(VERSION, data_.vault, borrowedAmount);
        /* solhint-enable avoid-low-level-calls */
    }

    function _exit(EulerV2BorrowFuseExitData memory data_) internal {
        if (data_.amount == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.vault)) {
            revert EulerV2BorrowFuseUnsupportedVault("exit", data_.vault);
        }

        IEVault vault = IEVault(data_.vault);
        address asset = vault.asset();
        ERC20(asset).forceApprove(data_.vault, data_.amount);

        // Prepare the calldata for the repay function
        bytes memory repayCalldata = abi.encodeWithSelector(IEVault.repay.selector, data_.amount, address(this));

        // Call the vault through EVC
        /* solhint-disable avoid-low-level-calls */
        uint256 repaidAmount = abi.decode(EVC.call(data_.vault, address(this), 0, repayCalldata), (uint256));
        emit EulerV2BorrowExitFuse(VERSION, data_.vault, repaidAmount);
        /* solhint-enable avoid-low-level-calls */
    }
}
