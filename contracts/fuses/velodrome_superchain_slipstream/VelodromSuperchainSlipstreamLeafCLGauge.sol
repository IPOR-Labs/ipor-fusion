// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {FuseStorageLib} from "../../libraries/FuseStorageLib.sol";
import {VelodromSuperchainSlipstreamSubstrateLib, VelodromSuperchainSlipstreamSubstrateType, VelodromSuperchainSlipstreamSubstrate} from "./VelodromSuperchainSlipstreamLib.sol";
import {ILeafCLGauge} from "./ext/ILeafCLGauge.sol";
import {INonfungiblePositionManager} from "./ext/INonfungiblePositionManager.sol";

struct VelodromSuperchainSlipstreamLeafCLGaugeEnterData {
    address gaugeAddress;
    uint256 tokenId;
}

struct VelodromSuperchainSlipstreamLeafCLGaugeExitData {
    address gaugeAddress;
    uint256 tokenId;
}

contract VelodromSuperchainSlipstreamLeafCLGauge is IFuseCommon {
    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    event VelodromSuperchainSlipstreamLeafCLGaugeEnter(address gaugeAddress, uint256 tokenId);
    event VelodromSuperchainSlipstreamLeafCLGaugeExit(address gaugeAddress, uint256 tokenId);

    error VelodromSuperchainSlipstreamLeafCLGaugeUnsupportedGauge(address gaugeAddress);

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    function enter(VelodromSuperchainSlipstreamLeafCLGaugeEnterData calldata data) external {
        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                VelodromSuperchainSlipstreamSubstrateLib.substrateToBytes32(
                    VelodromSuperchainSlipstreamSubstrate({
                        substrateType: VelodromSuperchainSlipstreamSubstrateType.Gauge,
                        substrateAddress: data.gaugeAddress
                    })
                )
            )
        ) {
            revert VelodromSuperchainSlipstreamLeafCLGaugeUnsupportedGauge(data.gaugeAddress);
        }

        if (data.tokenId == 0) {
            return;
        }

        INonfungiblePositionManager(ILeafCLGauge(data.gaugeAddress).nft()).approve(data.gaugeAddress, data.tokenId);

        ILeafCLGauge(data.gaugeAddress).deposit(data.tokenId);

        emit VelodromSuperchainSlipstreamLeafCLGaugeEnter(data.gaugeAddress, data.tokenId);
    }

    function exit(VelodromSuperchainSlipstreamLeafCLGaugeExitData calldata data) external {
        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                VelodromSuperchainSlipstreamSubstrateLib.substrateToBytes32(
                    VelodromSuperchainSlipstreamSubstrate({
                        substrateType: VelodromSuperchainSlipstreamSubstrateType.Gauge,
                        substrateAddress: data.gaugeAddress
                    })
                )
            )
        ) {
            revert VelodromSuperchainSlipstreamLeafCLGaugeUnsupportedGauge(data.gaugeAddress);
        }

        ILeafCLGauge(data.gaugeAddress).withdraw(data.tokenId);

        emit VelodromSuperchainSlipstreamLeafCLGaugeExit(data.gaugeAddress, data.tokenId);
    }
}
