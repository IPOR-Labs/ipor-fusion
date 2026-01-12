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

/// @notice Structure for entering a Morpho Flash Loan Fuse
/// @param token The address of the token to be borrowed in the flash loan
/// @param tokenAmount The amount of tokens to borrow in the flash loan
/// @param callbackFuseActionsData Encoded FuseAction[] array to execute during the flash loan callback
struct MorphoFlashLoanFuseEnterData {
    /// @notice The address of the token to be borrowed in the flash loan
    address token;
    /// @notice The amount of tokens to borrow in the flash loan
    uint256 tokenAmount;
    /// @notice Callback data to be passed to the flash loan callback. This data should be an encoded FuseAction[] array.
    bytes callbackFuseActionsData;
}

/**
 * @title Fuse for executing Morpho protocol flash loans
 * @notice Enables borrowing tokens from Morpho protocol via flash loans with callback support
 * @dev This fuse allows the Plasma Vault to borrow tokens from Morpho protocol without collateral,
 *      execute operations via callback, and repay the loan within the same transaction.
 *      The callback mechanism enables executing additional FuseActions during the flash loan.
 */
contract MorphoFlashLoanFuse is IFuseCommon {
    using SafeERC20 for ERC20;

    /// @notice Address of this fuse contract version
    /// @dev Immutable value set in constructor, used for tracking and versioning
    address public immutable VERSION;

    /// @notice Market ID this fuse operates on
    /// @dev Immutable value set in constructor, used to retrieve market substrates (token addresses)
    uint256 public immutable MARKET_ID;

    /// @notice Morpho protocol contract address
    /// @dev Immutable value set in constructor, used for Morpho protocol interactions
    IMorpho public immutable MORPHO;

    /// @notice Thrown when an unsupported token is used for flash loan
    /// @param token The address of the token that is not supported
    /// @custom:error MorphoFlashLoanFuseUnsupportedToken
    error MorphoFlashLoanFuseUnsupportedToken(address token);

    /// @notice Emitted when a flash loan is executed
    /// @param version The address of this fuse contract version
    /// @param asset The address of the token borrowed
    /// @param amount The amount of tokens borrowed
    event MorphoFlashLoanFuseEvent(address version, address asset, uint256 amount);

    /**
     * @notice Initializes the MorphoFlashLoanFuse with a market ID and Morpho address
     * @param marketId_ The market ID used to identify the token substrates
     * @param morpho_ The address of the Morpho protocol contract
     * @dev Sets VERSION to the address of this contract instance for tracking purposes
     */
    constructor(uint256 marketId_, address morpho_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        MORPHO = IMorpho(morpho_);
    }

    /**
     * @notice Executes a flash loan from Morpho protocol
     * @param data_ Struct containing token address, amount, and callback data
     * @return asset The address of the token borrowed
     * @return amount The amount of tokens borrowed
     * @dev This function:
     *      1. Validates that tokenAmount is not zero (returns early if zero)
     *      2. Validates that the token is granted as a substrate for this market
     *      3. Approves tokens for Morpho protocol
     *      4. Calls Morpho.flashLoan() with callback data encoded as CallbackData struct
     *      5. Resets approval to zero after flash loan execution
     *      6. Emits MorphoFlashLoanFuseEvent with borrowed token and amount
     *      The flash loan must be repaid within the same transaction via the callback mechanism.
     */
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

    /**
     * @notice Enters the Fuse using transient storage for parameters
     * @dev Reads token address, tokenAmount, and callbackFuseActionsData from transient storage inputs.
     *      Input format: inputs[0] = token address, inputs[1] = tokenAmount, inputs[2] = callbackDataLength,
     *      inputs[3..n] = callback data chunks (if callbackDataLength > 0).
     *      The callback data is reconstructed from bytes32 chunks using assembly for gas efficiency.
     *      Writes returned asset and amount to transient storage outputs.
     */
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        address token = TypeConversionLib.toAddress(inputs[0]);
        uint256 tokenAmount = TypeConversionLib.toUint256(inputs[1]);
        uint256 callbackDataLength = TypeConversionLib.toUint256(inputs[2]);

        bytes memory callbackFuseActionsData;
        if (callbackDataLength > 0) {
            callbackFuseActionsData = new bytes(callbackDataLength);
            // Calculate number of 32-byte chunks needed to store the callback data
            uint256 chunksCount = (callbackDataLength + 31) / 32; // ceil(callbackDataLength / 32)
            for (uint256 i; i < chunksCount; ++i) {
                bytes32 chunk = inputs[3 + i];
                uint256 chunkStart = i * 32;
                // Assembly block: Copy each 32-byte chunk into the callback data bytes array
                // @dev This uses inline assembly for gas efficiency when reconstructing bytes from bytes32 chunks
                // @dev dataPtr points to the memory location where the chunk should be stored
                // @dev mstore writes the 32-byte chunk to the calculated memory offset
                assembly {
                    // Calculate pointer: callbackFuseActionsData.data + chunkStart offset
                    // add(callbackFuseActionsData, 0x20) skips the length prefix (first 32 bytes)
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
