// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
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

    function enter(VelodromeSuperchainSlipstreamLeafCLGaugeFuseEnterData calldata data_) external {
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

        if (data_.tokenId == 0) {
            return;
        }

        INonfungiblePositionManager(ILeafCLGauge(data_.gaugeAddress).nft()).approve(data_.gaugeAddress, data_.tokenId);

        ILeafCLGauge(data_.gaugeAddress).deposit(data_.tokenId);

        emit VelodromeSuperchainSlipstreamLeafCLGaugeEnter(data_.gaugeAddress, data_.tokenId);
    }

    function exit(VelodromeSuperchainSlipstreamLeafCLGaugeFuseExitData calldata data_) external {
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

        ILeafCLGauge(data_.gaugeAddress).withdraw(data_.tokenId);

        emit VelodromeSuperchainSlipstreamLeafCLGaugeExit(data_.gaugeAddress, data_.tokenId);
    }
}
