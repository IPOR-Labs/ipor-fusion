// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
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

    function enter(AreodromeSlipstreamCLGaugeFuseEnterData calldata data_) external {
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
            return;
        }

        INonfungiblePositionManager(ICLGauge(data_.gaugeAddress).nft()).approve(data_.gaugeAddress, data_.tokenId);

        ICLGauge(data_.gaugeAddress).deposit(data_.tokenId);

        emit AreodromeSlipstreamCLGaugeFuseEnter(data_.gaugeAddress, data_.tokenId);
    }

    function exit(AreodromeSlipstreamCLGaugeFuseExitData calldata data_) external {
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
    }
}
