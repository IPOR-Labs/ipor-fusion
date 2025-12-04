// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {AreodromeSlipstreamSubstrateLib, AreodromeSlipstreamSubstrateType, AreodromeSlipstreamSubstrate} from "./AreodromeSlipstreamLib.sol";
import {ICLGauge} from "./ext/ICLGauge.sol";
import {INonfungiblePositionManager} from "./ext/INonfungiblePositionManager.sol";

/// @notice Data structure used for entering (depositing) NFT position to Aerodrome Slipstream CL gauge
/// @dev This structure contains the gauge address and NFT token ID to deposit
/// @param gaugeAddress The address of the Aerodrome Slipstream CL gauge contract
/// @param tokenId The NFT token ID representing the liquidity position to deposit
struct AreodromeSlipstreamCLGaugeFuseEnterData {
    address gaugeAddress;
    uint256 tokenId;
}

/// @notice Data structure used for exiting (withdrawing) NFT position from Aerodrome Slipstream CL gauge
/// @dev This structure contains the gauge address and NFT token ID to withdraw
/// @param gaugeAddress The address of the Aerodrome Slipstream CL gauge contract
/// @param tokenId The NFT token ID representing the liquidity position to withdraw
struct AreodromeSlipstreamCLGaugeFuseExitData {
    address gaugeAddress;
    uint256 tokenId;
}

/// @title AreodromeSlipstreamCLGaugeFuse
/// @notice Fuse for depositing and withdrawing NFT positions to/from Aerodrome Slipstream CL gauges
/// @dev This fuse allows users to stake their NFT liquidity positions in Aerodrome Slipstream CL gauges
///      to earn rewards. It validates that gauges are granted as substrates for the market.
///      Supports both standard function calls and transient storage-based calls.
/// @author IPOR Labs
contract AreodromeSlipstreamCLGaugeFuse is IFuseCommon {
    /// @notice The version identifier of this fuse contract
    address public immutable VERSION;

    /// @notice The market ID associated with this fuse
    /// @dev Used to validate that gauges are granted as substrates for this market
    uint256 public immutable MARKET_ID;

    /// @notice Emitted when an NFT position is deposited to a gauge
    /// @param gaugeAddress The address of the gauge contract
    /// @param tokenId The NFT token ID representing the liquidity position
    event AreodromeSlipstreamCLGaugeFuseEnter(address gaugeAddress, uint256 tokenId);

    /// @notice Emitted when an NFT position is withdrawn from a gauge
    /// @param gaugeAddress The address of the gauge contract
    /// @param tokenId The NFT token ID representing the liquidity position
    event AreodromeSlipstreamCLGaugeFuseExit(address gaugeAddress, uint256 tokenId);

    /// @notice Thrown when attempting to interact with a gauge that is not granted as a substrate
    /// @param gaugeAddress The address of the gauge that is not supported
    error AreodromeSlipstreamCLGaugeFuseUnsupportedGauge(address gaugeAddress);

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
    /// @return gaugeAddress The address of the gauge where the NFT was deposited
    /// @return tokenId The ID of the token deposited (returns 0 if tokenId was 0 in input)
    /// @custom:revert AreodromeSlipstreamCLGaugeFuseUnsupportedGauge When gauge is not granted as a substrate
    function enter(
        AreodromeSlipstreamCLGaugeFuseEnterData memory data_
    ) public returns (address gaugeAddress, uint256 tokenId) {
        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                AreodromeSlipstreamSubstrateLib.substrateToBytes32(
                    AreodromeSlipstreamSubstrate({
                        substrateType: AreodromeSlipstreamSubstrateType.Gauge,
                        substrateAddress: data_.gaugeAddress
                    })
                )
            )
        ) {
            revert AreodromeSlipstreamCLGaugeFuseUnsupportedGauge(data_.gaugeAddress);
        }

        if (data_.tokenId == 0) {
            return (data_.gaugeAddress, 0);
        }

        INonfungiblePositionManager(ICLGauge(data_.gaugeAddress).nft()).approve(data_.gaugeAddress, data_.tokenId);

        ICLGauge(data_.gaugeAddress).deposit(data_.tokenId);

        emit AreodromeSlipstreamCLGaugeFuseEnter(data_.gaugeAddress, data_.tokenId);

        return (data_.gaugeAddress, data_.tokenId);
    }

    /// @notice Enters (deposits) NFT position to gauge using transient storage for inputs
    /// @dev Reads gaugeAddress and tokenId from transient storage
    /// @dev Writes returned gaugeAddress and tokenId to transient storage outputs
    function enterTransient() external {
        bytes32 gaugeAddressBytes32 = TransientStorageLib.getInput(VERSION, 0);
        bytes32 tokenIdBytes32 = TransientStorageLib.getInput(VERSION, 1);

        address gaugeAddress = TypeConversionLib.toAddress(gaugeAddressBytes32);
        uint256 tokenId = TypeConversionLib.toUint256(tokenIdBytes32);

        AreodromeSlipstreamCLGaugeFuseEnterData memory data = AreodromeSlipstreamCLGaugeFuseEnterData({
            gaugeAddress: gaugeAddress,
            tokenId: tokenId
        });

        (address returnedGaugeAddress, uint256 returnedTokenId) = enter(data);

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(returnedGaugeAddress);
        outputs[1] = TypeConversionLib.toBytes32(returnedTokenId);

        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Exits (withdraws) NFT position from gauge
    /// @dev Validates that the gauge is granted as a substrate. Withdraws the NFT from the gauge,
    ///      returning it to the caller and stopping reward accrual.
    /// @param data_ Exit data containing gauge address and token ID
    /// @return gaugeAddress The address of the gauge from which the NFT was withdrawn
    /// @return tokenId The ID of the token withdrawn
    /// @custom:revert AreodromeSlipstreamCLGaugeFuseUnsupportedGauge When gauge is not granted as a substrate
    function exit(
        AreodromeSlipstreamCLGaugeFuseExitData memory data_
    ) public returns (address gaugeAddress, uint256 tokenId) {
        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                AreodromeSlipstreamSubstrateLib.substrateToBytes32(
                    AreodromeSlipstreamSubstrate({
                        substrateType: AreodromeSlipstreamSubstrateType.Gauge,
                        substrateAddress: data_.gaugeAddress
                    })
                )
            )
        ) {
            revert AreodromeSlipstreamCLGaugeFuseUnsupportedGauge(data_.gaugeAddress);
        }

        ICLGauge(data_.gaugeAddress).withdraw(data_.tokenId);

        emit AreodromeSlipstreamCLGaugeFuseExit(data_.gaugeAddress, data_.tokenId);

        return (data_.gaugeAddress, data_.tokenId);
    }

    /// @notice Exits (withdraws) NFT position from gauge using transient storage for inputs
    /// @dev Reads gaugeAddress and tokenId from transient storage
    /// @dev Writes returned gaugeAddress and tokenId to transient storage outputs
    function exitTransient() external {
        bytes32 gaugeAddressBytes32 = TransientStorageLib.getInput(VERSION, 0);
        bytes32 tokenIdBytes32 = TransientStorageLib.getInput(VERSION, 1);

        address gaugeAddress = TypeConversionLib.toAddress(gaugeAddressBytes32);
        uint256 tokenId = TypeConversionLib.toUint256(tokenIdBytes32);

        AreodromeSlipstreamCLGaugeFuseExitData memory data = AreodromeSlipstreamCLGaugeFuseExitData({
            gaugeAddress: gaugeAddress,
            tokenId: tokenId
        });

        (address returnedGaugeAddress, uint256 returnedTokenId) = exit(data);

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(returnedGaugeAddress);
        outputs[1] = TypeConversionLib.toBytes32(returnedTokenId);

        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}
