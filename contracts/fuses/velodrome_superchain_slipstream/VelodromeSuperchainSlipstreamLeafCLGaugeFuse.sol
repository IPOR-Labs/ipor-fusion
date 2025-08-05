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

    function enter(VelodromeSuperchainSlipstreamLeafCLGaugeFuseEnterData calldata data) external {
        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                VelodromeSuperchainSlipstreamSubstrateLib.substrateToBytes32(
                    VelodromeSuperchainSlipstreamSubstrate({
                        substrateType: VelodromeSuperchainSlipstreamSubstrateType.Gauge,
                        substrateAddress: data.gaugeAddress
                    })
                )
            )
        ) {
            revert VelodromeSuperchainSlipstreamLeafCLGaugeUnsupportedGauge(data.gaugeAddress);
        }

        if (data.tokenId == 0) {
            return;
        }

        INonfungiblePositionManager(ILeafCLGauge(data.gaugeAddress).nft()).approve(data.gaugeAddress, data.tokenId);

        ILeafCLGauge(data.gaugeAddress).deposit(data.tokenId);

        emit VelodromeSuperchainSlipstreamLeafCLGaugeEnter(data.gaugeAddress, data.tokenId);
    }

    function exit(VelodromeSuperchainSlipstreamLeafCLGaugeFuseExitData calldata data) external {
        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                VelodromeSuperchainSlipstreamSubstrateLib.substrateToBytes32(
                    VelodromeSuperchainSlipstreamSubstrate({
                        substrateType: VelodromeSuperchainSlipstreamSubstrateType.Gauge,
                        substrateAddress: data.gaugeAddress
                    })
                )
            )
        ) {
            revert VelodromeSuperchainSlipstreamLeafCLGaugeUnsupportedGauge(data.gaugeAddress);
        }

        ILeafCLGauge(data.gaugeAddress).withdraw(data.tokenId);

        emit VelodromeSuperchainSlipstreamLeafCLGaugeExit(data.gaugeAddress, data.tokenId);
    }
}
