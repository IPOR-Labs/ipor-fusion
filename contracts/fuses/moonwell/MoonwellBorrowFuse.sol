// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IFuseCommon} from "../IFuse.sol";
import {MErc20} from "./ext/MErc20.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

struct MoonwellBorrowFuseEnterData {
    address asset; // asset to borrow
    uint256 amount; // amount to borrow
}

struct MoonwellBorrowFuseExitData {
    address asset; // asset to repay
    uint256 amount; // amount to repay
}

contract MoonwellBorrowFuse is IFuseCommon {
    address public immutable VERSION;
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

    function enter(MoonwellBorrowFuseEnterData memory data_) external {
        if (data_.amount == 0) return;

        MErc20 mToken = MErc20(_getMToken(MARKET_ID, data_.asset));
        uint256 borrowResult = mToken.borrow(data_.amount);
        if (borrowResult != 0) {
            revert MoonwellBorrowFuseBorrowFailed();
        }

        emit MoonwellBorrowEntered(VERSION, data_.asset, address(mToken), data_.amount);
    }

    function exit(MoonwellBorrowFuseExitData memory data_) external {
        if (data_.amount == 0) return;

        MErc20 mToken = MErc20(_getMToken(MARKET_ID, data_.asset));
        IERC20(data_.asset).approve(address(mToken), data_.amount);

        uint256 repayResult = mToken.repayBorrow(data_.amount);
        if (repayResult != 0) {
            revert MoonwellBorrowFuseRepayFailed();
        }

        emit MoonwellBorrowExited(VERSION, data_.asset, address(mToken), data_.amount);
    }

    function _getMToken(uint256 marketId_, address asset_) internal view returns (address) {
        bytes32[] memory assetsRaw = PlasmaVaultConfigLib.getMarketSubstrates(marketId_);
        uint256 len = assetsRaw.length;
        if (len == 0) {
            revert MoonwellBorrowFuseNoAssetsFound();
        }

        for (uint256 i; i < len; ++i) {
            address mToken = PlasmaVaultConfigLib.bytes32ToAddress(assetsRaw[i]);
            if (MErc20(mToken).underlying() == asset_) {
                return mToken;
            }
        }

        revert MoonwellBorrowFuseUnsupportedAsset(asset_);
    }
}
