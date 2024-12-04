// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFuseCommon} from "../IFuse.sol";
import {MErc20} from "./ext/MErc20.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MoonwellHelperLib} from "./MoonwellHelperLib.sol";

/// @notice Data for borrowing assets from Moonwell
/// @param asset Asset to borrow
/// @param amount Amount to borrow
struct MoonwellBorrowFuseEnterData {
    address asset;
    uint256 amount;
}

/// @notice Data for repaying borrowed assets to Moonwell
/// @param asset Asset to repay
/// @param amount Amount to repay
struct MoonwellBorrowFuseExitData {
    address asset;
    uint256 amount;
}

/// @title MoonwellBorrowFuse
/// @notice Fuse for borrowing and repaying assets in the Moonwell protocol
/// @dev Handles borrowing assets from Moonwell markets and repaying borrowed positions
contract MoonwellBorrowFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    /// @notice Version of this contract for tracking
    address public immutable VERSION;

    /// @notice Market ID this fuse is associated with
    uint256 public immutable MARKET_ID;

    event MoonwellBorrowEntered(address version, address asset, address market, uint256 amount);
    event MoonwellBorrowExited(address version, address asset, address market, uint256 amount);

    error MoonwellBorrowFuseUnsupportedAsset(address asset);
    error MoonwellBorrowFuseNoAssetsFound();
    error MoonwellBorrowFuseBorrowFailed();
    error MoonwellBorrowFuseRepayFailed();

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Borrow assets from Moonwell
    /// @param data_ Struct containing asset and amount to borrow
    function enter(MoonwellBorrowFuseEnterData memory data_) external {
        if (data_.amount == 0) return;

        MErc20 mToken = MErc20(
            MoonwellHelperLib.getMToken(PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID), data_.asset)
        );
        if (mToken.borrow(data_.amount) != 0) {
            revert MoonwellBorrowFuseBorrowFailed();
        }

        emit MoonwellBorrowEntered(VERSION, data_.asset, address(mToken), data_.amount);
    }

    /// @notice Repay borrowed assets to Moonwell
    /// @param data_ Struct containing asset and amount to repay
    function exit(MoonwellBorrowFuseExitData memory data_) external {
        if (data_.amount == 0) return;

        MErc20 mToken = MErc20(
            MoonwellHelperLib.getMToken(PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID), data_.asset)
        );
        IERC20(data_.asset).forceApprove(address(mToken), data_.amount);

        if (mToken.repayBorrow(data_.amount) != 0) {
            revert MoonwellBorrowFuseRepayFailed();
        }

        IERC20(data_.asset).forceApprove(address(mToken), 0);

        emit MoonwellBorrowExited(VERSION, data_.asset, address(mToken), data_.amount);
    }
}
