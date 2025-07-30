// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {FuseStorageLib} from "../../libraries/FuseStorageLib.sol";
import {VelodromSuperchainSlipstreamSubstrateLib, VelodromSuperchainSlipstreamSubstrateType, VelodromSuperchainSlipstreamSubstrate} from "./VelodromSuperchainSlipstreamLib.sol";
import {ILeafCLGauge} from "./ext/ILeafCLGauge.sol";
import {INonfungiblePositionManager} from "./ext/INonfungiblePositionManager.sol";

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

    function enter(address gaugeAddress, uint256 tokenId) external {
        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                VelodromSuperchainSlipstreamSubstrateLib.substrateToBytes32(
                    VelodromSuperchainSlipstreamSubstrate({
                        substrateType: VelodromSuperchainSlipstreamSubstrateType.Gauge,
                        substrateAddress: gaugeAddress
                    })
                )
            )
        ) {
            revert VelodromSuperchainSlipstreamLeafCLGaugeUnsupportedGauge(gaugeAddress);
        }

        if (tokenId == 0) {
            return;
        }

        INonfungiblePositionManager(ILeafCLGauge(gaugeAddress).nft()).approve(gaugeAddress, tokenId);

        ILeafCLGauge(gaugeAddress).deposit(tokenId);

        FuseStorageLib.VelodromSuperchainSlipstreamTokenIds storage tokensIds = FuseStorageLib
            .getVelodromSuperchainSlipstreamTokenIds();

        uint256 tokenIndex = tokensIds.indexes[tokenId];
        uint256 len = tokensIds.tokenIds.length;

        if (tokenIndex != len - 1) {
            tokensIds.tokenIds[tokenIndex] = tokensIds.tokenIds[len - 1];
        }
        tokensIds.tokenIds.pop();

        emit VelodromSuperchainSlipstreamLeafCLGaugeEnter(gaugeAddress, tokenId);
    }

    function exit(address gaugeAddress, uint256 tokenId) external {
        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                VelodromSuperchainSlipstreamSubstrateLib.substrateToBytes32(
                    VelodromSuperchainSlipstreamSubstrate({
                        substrateType: VelodromSuperchainSlipstreamSubstrateType.Gauge,
                        substrateAddress: gaugeAddress
                    })
                )
            )
        ) {
            revert VelodromSuperchainSlipstreamLeafCLGaugeUnsupportedGauge(gaugeAddress);
        }

        ILeafCLGauge(gaugeAddress).withdraw(tokenId);

        FuseStorageLib.VelodromSuperchainSlipstreamTokenIds storage tokensIds = FuseStorageLib
            .getVelodromSuperchainSlipstreamTokenIds();
        tokensIds.indexes[tokenId] = tokensIds.tokenIds.length;
        tokensIds.tokenIds.push(tokenId);

        emit VelodromSuperchainSlipstreamLeafCLGaugeExit(gaugeAddress, tokenId);
    }
}
