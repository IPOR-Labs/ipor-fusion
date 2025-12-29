// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {VelodromeSuperchainSlipstreamSubstrateLib, VelodromeSuperchainSlipstreamSubstrateType, VelodromeSuperchainSlipstreamSubstrate} from "./VelodromeSuperchainSlipstreamSubstrateLib.sol";
import {ILeafCLGauge} from "./ext/ILeafCLGauge.sol";
import {INonfungiblePositionManager} from "./ext/INonfungiblePositionManager.sol";

/// @notice Data structure used for entering (depositing) NFT position to Velodrome Superchain Slipstream Leaf CL gauge
/// @dev This structure contains the gauge address and NFT token ID to deposit
/// @param gaugeAddress The address of the Velodrome Superchain Slipstream Leaf CL gauge contract
/// @param tokenId The NFT token ID representing the liquidity position to deposit
struct VelodromeSuperchainSlipstreamLeafCLGaugeFuseEnterData {
    address gaugeAddress;
    uint256 tokenId;
}

/// @notice Data structure used for exiting (withdrawing) NFT position from Velodrome Superchain Slipstream Leaf CL gauge
/// @dev This structure contains the gauge address and NFT token ID to withdraw
/// @param gaugeAddress The address of the Velodrome Superchain Slipstream Leaf CL gauge contract
/// @param tokenId The NFT token ID representing the liquidity position to withdraw
struct VelodromeSuperchainSlipstreamLeafCLGaugeFuseExitData {
    address gaugeAddress;
    uint256 tokenId;
}

/// @notice Result structure returned after entering (depositing) NFT position to gauge
/// @dev Contains the gauge address and token ID that were deposited
/// @param gaugeAddress The address of the gauge where the NFT was deposited
/// @param tokenId The ID of the token deposited (returns 0 if tokenId was 0 in input)
struct VelodromeSuperchainSlipstreamLeafCLGaugeFuseEnterResult {
    address gaugeAddress;
    uint256 tokenId;
}

/// @notice Result structure returned after exiting (withdrawing) NFT position from gauge
/// @dev Contains the gauge address and token ID that were withdrawn
/// @param gaugeAddress The address of the gauge from which the NFT was withdrawn
/// @param tokenId The ID of the token withdrawn
struct VelodromeSuperchainSlipstreamLeafCLGaugeFuseExitResult {
    address gaugeAddress;
    uint256 tokenId;
}

/// @title VelodromeSuperchainSlipstreamLeafCLGaugeFuse
/// @notice Fuse for depositing and withdrawing NFT positions to/from Velodrome Superchain Slipstream Leaf CL gauges
/// @dev This fuse allows users to stake their NFT liquidity positions in Velodrome Superchain Slipstream Leaf CL gauges
///      to earn rewards. It validates that gauges are granted as substrates for the market.
///      Supports both standard function calls and transient storage-based calls.
/// @author IPOR Labs
contract VelodromeSuperchainSlipstreamLeafCLGaugeFuse is IFuseCommon {
    /// @notice The version identifier of this fuse contract
    address public immutable VERSION;

    /// @notice The market ID associated with this fuse
    /// @dev Used to validate that gauges are granted as substrates for this market
    uint256 public immutable MARKET_ID;

    /// @notice Emitted when an NFT position is deposited to a gauge
    /// @param gaugeAddress The address of the gauge contract
    /// @param tokenId The NFT token ID representing the liquidity position
    event VelodromeSuperchainSlipstreamLeafCLGaugeEnter(address gaugeAddress, uint256 tokenId);

    /// @notice Emitted when an NFT position is withdrawn from a gauge
    /// @param gaugeAddress The address of the gauge contract
    /// @param tokenId The NFT token ID representing the liquidity position
    event VelodromeSuperchainSlipstreamLeafCLGaugeExit(address gaugeAddress, uint256 tokenId);

    /// @notice Thrown when attempting to interact with a gauge that is not granted as a substrate
    /// @param gaugeAddress The address of the gauge that is not supported
    error VelodromeSuperchainSlipstreamLeafCLGaugeUnsupportedGauge(address gaugeAddress);

    /// @notice Constructor to initialize the fuse with a market ID
    /// @param marketId_ The unique identifier for the market configuration
    /// @dev Sets VERSION to the address of this contract instance.
    ///      The market ID is used to validate that gauge addresses are granted as substrates.
    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Enters (deposits) NFT position to gauge
    /// @dev Validates that the gauge is granted as a substrate. If tokenId is zero, returns early without depositing.
    ///      Approves the gauge to transfer the NFT and then deposits it to earn rewards.
    /// @param data_ Enter data containing gauge address and token ID
    /// @return result Result structure containing gauge address and token ID
    /// @custom:revert VelodromeSuperchainSlipstreamLeafCLGaugeUnsupportedGauge When gauge is not granted as a substrate
    function enter(
        VelodromeSuperchainSlipstreamLeafCLGaugeFuseEnterData memory data_
    ) public returns (VelodromeSuperchainSlipstreamLeafCLGaugeFuseEnterResult memory result) {
        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                VelodromeSuperchainSlipstreamSubstrateLib.substrateToBytes32(
                    VelodromeSuperchainSlipstreamSubstrate({
                        substrateType: VelodromeSuperchainSlipstreamSubstrateType.Gauge,
                        substrateAddress: data_.gaugeAddress
                    })
                )
            )
        ) {
            revert VelodromeSuperchainSlipstreamLeafCLGaugeUnsupportedGauge(data_.gaugeAddress);
        }

        result.gaugeAddress = data_.gaugeAddress;
        result.tokenId = data_.tokenId;

        if (data_.tokenId == 0) {
            emit VelodromeSuperchainSlipstreamLeafCLGaugeEnter(result.gaugeAddress, result.tokenId);
            return result;
        }

        INonfungiblePositionManager(ILeafCLGauge(data_.gaugeAddress).nft()).approve(data_.gaugeAddress, data_.tokenId);

        ILeafCLGauge(data_.gaugeAddress).deposit(data_.tokenId);

        emit VelodromeSuperchainSlipstreamLeafCLGaugeEnter(result.gaugeAddress, result.tokenId);
    }

    /// @notice Exits (withdraws) NFT position from gauge
    /// @dev Validates that the gauge is granted as a substrate. Withdraws the NFT from the gauge,
    ///      returning it to the caller and stopping reward accrual.
    /// @param data_ Exit data containing gauge address and token ID
    /// @return result Result structure containing gauge address and token ID
    /// @custom:revert VelodromeSuperchainSlipstreamLeafCLGaugeUnsupportedGauge When gauge is not granted as a substrate
    function exit(
        VelodromeSuperchainSlipstreamLeafCLGaugeFuseExitData memory data_
    ) public returns (VelodromeSuperchainSlipstreamLeafCLGaugeFuseExitResult memory result) {
        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                VelodromeSuperchainSlipstreamSubstrateLib.substrateToBytes32(
                    VelodromeSuperchainSlipstreamSubstrate({
                        substrateType: VelodromeSuperchainSlipstreamSubstrateType.Gauge,
                        substrateAddress: data_.gaugeAddress
                    })
                )
            )
        ) {
            revert VelodromeSuperchainSlipstreamLeafCLGaugeUnsupportedGauge(data_.gaugeAddress);
        }

        result.gaugeAddress = data_.gaugeAddress;
        result.tokenId = data_.tokenId;

        ILeafCLGauge(data_.gaugeAddress).withdraw(data_.tokenId);

        emit VelodromeSuperchainSlipstreamLeafCLGaugeExit(result.gaugeAddress, result.tokenId);
    }

    /// @notice Enters (deposits) NFT position to gauge using transient storage for inputs
    /// @dev Reads gaugeAddress and tokenId from transient storage inputs (indices 0 and 1).
    ///      Writes returned gaugeAddress and tokenId to transient storage outputs (indices 0 and 1).
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        VelodromeSuperchainSlipstreamLeafCLGaugeFuseEnterData
            memory data_ = VelodromeSuperchainSlipstreamLeafCLGaugeFuseEnterData({
                gaugeAddress: TypeConversionLib.toAddress(inputs[0]),
                tokenId: TypeConversionLib.toUint256(inputs[1])
            });

        VelodromeSuperchainSlipstreamLeafCLGaugeFuseEnterResult memory result = enter(data_);

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(result.gaugeAddress);
        outputs[1] = TypeConversionLib.toBytes32(result.tokenId);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Exits (withdraws) NFT position from gauge using transient storage for inputs
    /// @dev Reads gaugeAddress and tokenId from transient storage inputs (indices 0 and 1).
    ///      Writes returned gaugeAddress and tokenId to transient storage outputs (indices 0 and 1).
    function exitTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        VelodromeSuperchainSlipstreamLeafCLGaugeFuseExitData
            memory data_ = VelodromeSuperchainSlipstreamLeafCLGaugeFuseExitData({
                gaugeAddress: TypeConversionLib.toAddress(inputs[0]),
                tokenId: TypeConversionLib.toUint256(inputs[1])
            });

        VelodromeSuperchainSlipstreamLeafCLGaugeFuseExitResult memory result = exit(data_);

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(result.gaugeAddress);
        outputs[1] = TypeConversionLib.toBytes32(result.tokenId);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}
