// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {AreodromeSlipstreamSubstrateLib, AreodromeSlipstreamSubstrateType, AreodromeSlipstreamSubstrate} from "./AreodromeSlipstreamLib.sol";
import {ICLGauge} from "./ext/ICLGauge.sol";
import {INonfungiblePositionManager} from "./ext/INonfungiblePositionManager.sol";

struct AreodromeSlipstreamCLGaugeEnterData {
    address gaugeAddress;
    uint256 tokenId;
}

struct AreodromeSlipstreamCLGaugeExitData {
    address gaugeAddress;
    uint256 tokenId;
}

contract AreodromeSlipstreamCLGauge is IFuseCommon {
    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    event AreodromeSlipstreamCLGaugeEnter(address gaugeAddress, uint256 tokenId);
    event AreodromeSlipstreamCLGaugeExit(address gaugeAddress, uint256 tokenId);

    error AreodromeSlipstreamCLGaugeUnsupportedGauge(address gaugeAddress);

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    function enter(AreodromeSlipstreamCLGaugeEnterData calldata data) external {
        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                AreodromeSlipstreamSubstrateLib.substrateToBytes32(
                    AreodromeSlipstreamSubstrate({
                        substrateType: AreodromeSlipstreamSubstrateType.Gauge,
                        substrateAddress: data.gaugeAddress
                    })
                )
            )
        ) {
            revert AreodromeSlipstreamCLGaugeUnsupportedGauge(data.gaugeAddress);
        }

        if (data.tokenId == 0) {
            return;
        }

        INonfungiblePositionManager(ICLGauge(data.gaugeAddress).nft()).approve(data.gaugeAddress, data.tokenId);

        ICLGauge(data.gaugeAddress).deposit(data.tokenId);

        emit AreodromeSlipstreamCLGaugeEnter(data.gaugeAddress, data.tokenId);
    }

    function exit(AreodromeSlipstreamCLGaugeExitData calldata data) external {
        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                AreodromeSlipstreamSubstrateLib.substrateToBytes32(
                    AreodromeSlipstreamSubstrate({
                        substrateType: AreodromeSlipstreamSubstrateType.Gauge,
                        substrateAddress: data.gaugeAddress
                    })
                )
            )
        ) {
            revert AreodromeSlipstreamCLGaugeUnsupportedGauge(data.gaugeAddress);
        }

        ICLGauge(data.gaugeAddress).withdraw(data.tokenId);

        emit AreodromeSlipstreamCLGaugeExit(data.gaugeAddress, data.tokenId);
    }
}
