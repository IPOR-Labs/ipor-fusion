// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IFuseCommon} from "../IFuse.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {MComptroller} from "./ext/MComptroller.sol";

struct MoonwellEnableMarketFuseEnterData {
    /// @notice array of mToken addresses to enable as collateral
    address[] mTokens;
}

struct MoonwellEnableMarketFuseExitData {
    /// @notice array of mToken addresses to disable as collateral
    address[] mTokens;
}

/// @dev Fuse for Moonwell protocol responsible for enabling and disabling mTokens as collateral
contract MoonwellEnableMarketFuse is IFuseCommon {
    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    MComptroller public immutable COMPTROLLER;

    event MoonwellMarketEnabled(address version, address[] mTokens);
    event MoonwellMarketDisabled(address version, address mToken);
    event MoonwellMarketEnableFailed(address version, address[] mTokens);
    event MoonwellMarketDisableFailed(address version, address mToken);

    error MoonwellEnableMarketFuseUnsupportedMToken(address mToken);
    error MoonwellEnableMarketFuseEmptyArray();

    constructor(uint256 marketId_, address comptroller_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        COMPTROLLER = MComptroller(comptroller_);
    }

    function enter(MoonwellEnableMarketFuseEnterData memory data_) external {
        uint256 len = data_.mTokens.length;
        if (len == 0) {
            revert MoonwellEnableMarketFuseEmptyArray();
        }

        // Validate all mTokens
        for (uint256 i; i < len; ++i) {
            if (!_isSupportedMToken(MARKET_ID, data_.mTokens[i])) {
                revert MoonwellEnableMarketFuseUnsupportedMToken(data_.mTokens[i]);
            }
        }

        // Enter the markets
        uint256[] memory errors = COMPTROLLER.enterMarkets(data_.mTokens);

        // Check if any errors occurred
        bool hasError;
        for (uint256 i; i < len; ++i) {
            if (errors[i] != 0) {
                hasError = true;
                break;
            }
        }

        if (!hasError) {
            emit MoonwellMarketEnabled(VERSION, data_.mTokens);
        } else {
            emit MoonwellMarketEnableFailed(VERSION, data_.mTokens);
        }
    }

    function exit(MoonwellEnableMarketFuseExitData calldata data_) external {
        uint256 len = data_.mTokens.length;

        if (len == 0) {
            revert MoonwellEnableMarketFuseEmptyArray();
        }

        // Exit each market individually
        for (uint256 i; i < len; ++i) {
            address mToken = data_.mTokens[i];

            if (!_isSupportedMToken(MARKET_ID, mToken)) {
                revert MoonwellEnableMarketFuseUnsupportedMToken(mToken);
            }

            uint256 error = COMPTROLLER.exitMarket(mToken);

            if (error == 0) {
                emit MoonwellMarketDisabled(VERSION, mToken);
            } else {
                emit MoonwellMarketDisableFailed(VERSION, mToken);
            }
        }
    }

    function _isSupportedMToken(uint256 marketId_, address mToken_) internal view returns (bool) {
        bytes32[] memory assetsRaw = PlasmaVaultConfigLib.getMarketSubstrates(marketId_);
        uint256 len = assetsRaw.length;
        if (len == 0) {
            return false;
        }
        for (uint256 i; i < len; ++i) {
            if (PlasmaVaultConfigLib.bytes32ToAddress(assetsRaw[i]) == mToken_) {
                return true;
            }
        }
        return false;
    }
}