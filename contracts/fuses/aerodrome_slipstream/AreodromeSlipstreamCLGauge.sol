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

    function enter(AreodromeSlipstreamCLGaugeEnterData calldata data_) external {
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
            revert AreodromeSlipstreamCLGaugeUnsupportedGauge(data_.gaugeAddress);
        }

        if (data_.tokenId == 0) {
            return;
        }

        INonfungiblePositionManager(ICLGauge(data_.gaugeAddress).nft()).approve(data_.gaugeAddress, data_.tokenId);

        ICLGauge(data_.gaugeAddress).deposit(data_.tokenId);

        emit AreodromeSlipstreamCLGaugeEnter(data_.gaugeAddress, data_.tokenId);
    }

    function exit(AreodromeSlipstreamCLGaugeExitData calldata data_) external {
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
            revert AreodromeSlipstreamCLGaugeUnsupportedGauge(data_.gaugeAddress);
        }

        ICLGauge(data_.gaugeAddress).withdraw(data_.tokenId);

        emit AreodromeSlipstreamCLGaugeExit(data_.gaugeAddress, data_.tokenId);
    }
}
