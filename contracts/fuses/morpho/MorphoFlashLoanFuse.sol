// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IMorpho} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {CallbackData} from "../../libraries/CallbackHandlerLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";

/// @dev Struct to hold data for entering a Morpho Flash Loan Fuse
struct MorphoFlashLoanFuseEnterData {
    /// @dev The address of the token to be used in the flash loan
    address token;
    /// @dev The amount of the token to be used in the flash loan
    uint256 tokenAmount;
    /// @dev Callback data to be passed to the flash loan callback. This data should be an encoded FuseAction[] array.
    bytes callbackFuseActionsData;
}

/// @title Morpho Flash Loan Fuse
contract MorphoFlashLoanFuse is IFuseCommon {
    using SafeERC20 for ERC20;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    IMorpho public immutable MORPHO;

    error MorphoFlashLoanFuseUnsupportedToken(address token);

    event MorphoFlashLoanFuseEvent(address version, address asset, uint256 amount);

    constructor(uint256 marketId_, address morpho_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        MORPHO = IMorpho(morpho_);
    }

    function enter(MorphoFlashLoanFuseEnterData memory data_) public returns (address asset, uint256 amount) {
        if (data_.tokenAmount == 0) {
            asset = data_.token;
            amount = 0;
            emit MorphoFlashLoanFuseEvent(VERSION, asset, amount);
            return (asset, amount);
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.token)) {
            revert MorphoFlashLoanFuseUnsupportedToken(data_.token);
        }

        ERC20(data_.token).forceApprove(address(MORPHO), data_.tokenAmount);

        MORPHO.flashLoan(
            data_.token,
            data_.tokenAmount,
            abi.encode(
                CallbackData({
                    asset: data_.token,
                    addressToApprove: address(MORPHO),
                    amountToApprove: data_.tokenAmount,
                    actionData: data_.callbackFuseActionsData
                })
            )
        );

        ERC20(data_.token).forceApprove(address(MORPHO), 0);

        asset = data_.token;
        amount = data_.tokenAmount;

        emit MorphoFlashLoanFuseEvent(VERSION, asset, amount);
    }

    /// @notice Enters the Fuse using transient storage for parameters
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        address token = TypeConversionLib.toAddress(inputs[0]);
        uint256 tokenAmount = TypeConversionLib.toUint256(inputs[1]);
        uint256 callbackDataLength = TypeConversionLib.toUint256(inputs[2]);

        bytes memory callbackFuseActionsData;
        if (callbackDataLength > 0) {
            callbackFuseActionsData = new bytes(callbackDataLength);
            uint256 chunksCount = (callbackDataLength + 31) / 32; // ceil(callbackDataLength / 32)
            for (uint256 i; i < chunksCount; ++i) {
                bytes32 chunk = inputs[3 + i];
                uint256 chunkStart = i * 32;
                assembly {
                    let dataPtr := add(add(callbackFuseActionsData, 0x20), chunkStart)
                    mstore(dataPtr, chunk)
                }
            }
        }

        (address returnedAsset, uint256 returnedAmount) = enter(
            MorphoFlashLoanFuseEnterData({
                token: token,
                tokenAmount: tokenAmount,
                callbackFuseActionsData: callbackFuseActionsData
            })
        );

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(returnedAsset);
        outputs[1] = TypeConversionLib.toBytes32(returnedAmount);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}
