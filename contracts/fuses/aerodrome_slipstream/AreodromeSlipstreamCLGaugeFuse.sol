// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {AreodromeSlipstreamSubstrateLib, AreodromeSlipstreamSubstrateType, AreodromeSlipstreamSubstrate} from "./AreodromeSlipstreamLib.sol";
import {ICLGauge} from "./ext/ICLGauge.sol";
import {INonfungiblePositionManager} from "./ext/INonfungiblePositionManager.sol";

struct AreodromeSlipstreamCLGaugeFuseEnterData {
    address gaugeAddress;
    uint256 tokenId;
}

struct AreodromeSlipstreamCLGaugeFuseExitData {
    address gaugeAddress;
    uint256 tokenId;
}

contract AreodromeSlipstreamCLGaugeFuse is IFuseCommon {
    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    event AreodromeSlipstreamCLGaugeFuseEnter(address gaugeAddress, uint256 tokenId);
    event AreodromeSlipstreamCLGaugeFuseExit(address gaugeAddress, uint256 tokenId);

    error AreodromeSlipstreamCLGaugeFuseUnsupportedGauge(address gaugeAddress);

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Enters (deposits) NFT position to gauge
    /// @param data_ Enter data containing gauge address and token ID
    /// @return gaugeAddress The address of the gauge
    /// @return tokenId The ID of the token deposited
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

        address gaugeAddress = PlasmaVaultConfigLib.bytes32ToAddress(gaugeAddressBytes32);
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
    /// @param data_ Exit data containing gauge address and token ID
    /// @return gaugeAddress The address of the gauge
    /// @return tokenId The ID of the token withdrawn
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

        address gaugeAddress = PlasmaVaultConfigLib.bytes32ToAddress(gaugeAddressBytes32);
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
