// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IFuseCommon} from "../IFuse.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {MComptroller} from "./ext/MComptroller.sol";

/// @notice Data for enabling markets as collateral in Moonwell
/// @param mTokens Array of mToken addresses to enable as collateral
struct MoonwellEnableMarketFuseEnterData {
    address[] mTokens;
}

/// @notice Data for disabling markets as collateral in Moonwell
/// @param mTokens Array of mToken addresses to disable as collateral
struct MoonwellEnableMarketFuseExitData {
    address[] mTokens;
}

/// @title MoonwellEnableMarketFuse
/// @notice Fuse for enabling and disabling markets(mTokens) as collateral in the Moonwell protocol
/// @dev Manages which markets can be used as collateral for borrowing
contract MoonwellEnableMarketFuse is IFuseCommon {
    /// @notice Version of this contract for tracking
    address public immutable VERSION;

    /// @notice Market ID this fuse is associated with
    uint256 public immutable MARKET_ID;

    /// @notice Moonwell Comptroller contract reference
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

    /// @notice Enable markets as collateral in Moonwell
    /// @param data_ Struct containing array of mToken addresses to enable
    function enter(MoonwellEnableMarketFuseEnterData memory data_) external {
        uint256 len = data_.mTokens.length;
        if (len == 0) {
            revert MoonwellEnableMarketFuseEmptyArray();
        }

        bytes32[] memory assetsRaw = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        // Validate all mTokens
        for (uint256 i; i < len; ++i) {
            if (!_isSupportedMToken(assetsRaw, data_.mTokens[i])) {
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

    /// @notice Disable markets as collateral in Moonwell
    /// @param data_ Struct containing array of mToken addresses to disable
    function exit(MoonwellEnableMarketFuseExitData calldata data_) external {
        uint256 len = data_.mTokens.length;

        if (len == 0) {
            revert MoonwellEnableMarketFuseEmptyArray();
        }

        bytes32[] memory assetsRaw = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);
        // Exit each market individually
        for (uint256 i; i < len; ++i) {
            address mToken = data_.mTokens[i];

            if (!_isSupportedMToken(assetsRaw, mToken)) {
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

    /// @dev Checks if an mToken is supported for the given market ID
    /// @param assetsRaw_ array of substrate addresses
    /// @param mToken_ mToken address to validate
    /// @return bool True if mToken is supported, false otherwise
    function _isSupportedMToken(bytes32[] memory assetsRaw_, address mToken_) internal view returns (bool) {
        uint256 len = assetsRaw_.length;
        if (len == 0) {
            return false;
        }
        for (uint256 i; i < len; ++i) {
            if (PlasmaVaultConfigLib.bytes32ToAddress(assetsRaw_[i]) == mToken_) {
                return true;
            }
        }
        return false;
    }
}
