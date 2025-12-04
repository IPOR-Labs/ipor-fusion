// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFuseCommon} from "../IFuse.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
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

    /// @notice Emitted when markets (mTokens) are successfully enabled as collateral in Moonwell
    /// @param version The address of this fuse contract version
    /// @param mTokens Array of mToken addresses that were successfully enabled as collateral
    event MoonwellMarketEnabled(address version, address[] mTokens);

    /// @notice Emitted when a market (mToken) is successfully disabled as collateral in Moonwell
    /// @param version The address of this fuse contract version
    /// @param mToken The mToken address that was successfully disabled as collateral
    event MoonwellMarketDisabled(address version, address mToken);

    /// @notice Emitted when enabling markets (mTokens) as collateral fails
    /// @param version The address of this fuse contract version
    /// @param mTokens Array of mToken addresses for which enabling as collateral failed
    /// @dev This event is emitted when one or more mTokens in the array failed to be enabled,
    ///      typically due to an error code returned by the Moonwell Comptroller
    event MoonwellMarketEnableFailed(address version, address[] mTokens);

    /// @notice Emitted when disabling a market (mToken) as collateral fails
    /// @param version The address of this fuse contract version
    /// @param mToken The mToken address for which disabling as collateral failed
    /// @dev This event is emitted when the mToken failed to be disabled, typically due to
    ///      an error code returned by the Moonwell Comptroller (e.g., if there's outstanding debt)
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
    /// @return mTokens Array of mToken addresses that were enabled
    function enter(MoonwellEnableMarketFuseEnterData memory data_) public returns (address[] memory mTokens) {
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

        mTokens = data_.mTokens;

        if (!hasError) {
            emit MoonwellMarketEnabled(VERSION, mTokens);
        } else {
            emit MoonwellMarketEnableFailed(VERSION, mTokens);
        }
    }

    /// @notice Disable markets as collateral in Moonwell
    /// @param data_ Struct containing array of mToken addresses to disable
    /// @return mTokens Array of mToken addresses that were processed
    function exit(MoonwellEnableMarketFuseExitData memory data_) public returns (address[] memory mTokens) {
        uint256 len = data_.mTokens.length;

        if (len == 0) {
            revert MoonwellEnableMarketFuseEmptyArray();
        }

        bytes32[] memory assetsRaw = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);
        mTokens = data_.mTokens;

        // Exit each market individually
        for (uint256 i; i < len; ++i) {
            address mToken = mTokens[i];

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

    /// @notice Enters the Fuse using transient storage for parameters
    /// @dev Reads mTokens array from transient storage.
    ///      Input 0: mTokensLength (uint256)
    ///      Inputs 1 to mTokensLength: mTokens (address[])
    ///      Writes returned mTokens array length and elements to transient storage outputs.
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        uint256 mTokensLength = TypeConversionLib.toUint256(inputs[0]);

        address[] memory mTokens = new address[](mTokensLength);
        for (uint256 i; i < mTokensLength; ++i) {
            mTokens[i] = TypeConversionLib.toAddress(inputs[1 + i]);
        }

        address[] memory returnedMTokens = enter(MoonwellEnableMarketFuseEnterData(mTokens));

        bytes32[] memory outputs = new bytes32[](1 + returnedMTokens.length);
        outputs[0] = TypeConversionLib.toBytes32(returnedMTokens.length);
        for (uint256 i; i < returnedMTokens.length; ++i) {
            outputs[1 + i] = TypeConversionLib.toBytes32(returnedMTokens[i]);
        }
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Exits the Fuse using transient storage for parameters
    /// @dev Reads mTokens array from transient storage.
    ///      Input 0: mTokensLength (uint256)
    ///      Inputs 1 to mTokensLength: mTokens (address[])
    ///      Writes returned mTokens array length and elements to transient storage outputs.
    function exitTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        uint256 mTokensLength = TypeConversionLib.toUint256(inputs[0]);

        address[] memory mTokens = new address[](mTokensLength);
        for (uint256 i; i < mTokensLength; ++i) {
            mTokens[i] = TypeConversionLib.toAddress(inputs[1 + i]);
        }

        address[] memory returnedMTokens = exit(MoonwellEnableMarketFuseExitData(mTokens));

        bytes32[] memory outputs = new bytes32[](1 + returnedMTokens.length);
        outputs[0] = TypeConversionLib.toBytes32(returnedMTokens.length);
        for (uint256 i; i < returnedMTokens.length; ++i) {
            outputs[1 + i] = TypeConversionLib.toBytes32(returnedMTokens[i]);
        }
        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}
