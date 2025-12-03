// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {VelodromeSuperchainSlipstreamSubstrateLib, VelodromeSuperchainSlipstreamSubstrateType, VelodromeSuperchainSlipstreamSubstrate} from "./VelodromeSuperchainSlipstreamSubstrateLib.sol";
import {ILeafCLGauge} from "./ext/ILeafCLGauge.sol";
import {INonfungiblePositionManager} from "./ext/INonfungiblePositionManager.sol";

struct VelodromeSuperchainSlipstreamLeafCLGaugeFuseEnterData {
    address gaugeAddress;
    uint256 tokenId;
}

struct VelodromeSuperchainSlipstreamLeafCLGaugeFuseExitData {
    address gaugeAddress;
    uint256 tokenId;
}

struct VelodromeSuperchainSlipstreamLeafCLGaugeFuseEnterResult {
    address gaugeAddress;
    uint256 tokenId;
}

struct VelodromeSuperchainSlipstreamLeafCLGaugeFuseExitResult {
    address gaugeAddress;
    uint256 tokenId;
}

contract VelodromeSuperchainSlipstreamLeafCLGaugeFuse is IFuseCommon {
    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    event VelodromeSuperchainSlipstreamLeafCLGaugeEnter(address gaugeAddress, uint256 tokenId);
    event VelodromeSuperchainSlipstreamLeafCLGaugeExit(address gaugeAddress, uint256 tokenId);

    error VelodromeSuperchainSlipstreamLeafCLGaugeUnsupportedGauge(address gaugeAddress);

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

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

    /// @notice Enters the Fuse using transient storage for parameters
    /// @dev Reads all parameters from transient storage and writes returned values to outputs
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

    /// @notice Exits the Fuse using transient storage for parameters
    /// @dev Reads all parameters from transient storage and writes returned values to outputs
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
