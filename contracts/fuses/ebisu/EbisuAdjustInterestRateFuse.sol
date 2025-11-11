// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IFuseCommon} from "../IFuseCommon.sol";
import {IBorrowerOperations} from "./ext/IBorrowerOperations.sol";
import {IAddressesRegistry} from "./ext/IAddressesRegistry.sol";
import {FuseStorageLib} from "../../libraries/FuseStorageLib.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {EbisuZapperSubstrateLib, EbisuZapperSubstrate, EbisuZapperSubstrateType} from "./lib/EbisuZapperSubstrateLib.sol";

contract EbisuAdjustInterestRateFuse is IFuseCommon {
    uint256 public immutable MARKET_ID;

    error UnsupportedSubstrate();
    error TroveNotOpen();

    event EbisuAdjustInterestRateFuseEnter(uint256 troveId, uint256 newAnnualInterestRate);

    struct EbisuAdjustInterestRateFuseEnterData {
        address zapper;
        address registry;
        uint256 newAnnualInterestRate;
        uint256 maxUpfrontFee;
        uint256 upperHint;
        uint256 lowerHint;
    }

    constructor(uint256 marketId_) {
        MARKET_ID = marketId_;
    }

    function enter(EbisuAdjustInterestRateFuseEnterData calldata data_) external {
        _requireSupportedSubstrates(data_.zapper, data_.registry);

        uint256 troveId = _getTroveIdOrRevert(data_.zapper);

        IAddressesRegistry registry = IAddressesRegistry(data_.registry);
        IBorrowerOperations registryBorrowerOperations = IBorrowerOperations(address(registry.borrowerOperations()));

        registryBorrowerOperations.adjustTroveInterestRate(
            troveId,
            data_.newAnnualInterestRate,
            data_.upperHint,
            data_.lowerHint,
            data_.maxUpfrontFee
        );

        emit EbisuAdjustInterestRateFuseEnter(troveId, data_.newAnnualInterestRate);
    }

    function _requireSupportedSubstrates(address zapper, address registry) internal view {
        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                EbisuZapperSubstrateLib.substrateToBytes32(
                    EbisuZapperSubstrate({substrateType: EbisuZapperSubstrateType.ZAPPER, substrateAddress: zapper})
                )
            )
        ) revert UnsupportedSubstrate();

        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                EbisuZapperSubstrateLib.substrateToBytes32(
                    EbisuZapperSubstrate({substrateType: EbisuZapperSubstrateType.REGISTRY, substrateAddress: registry})
                )
            )
        ) revert UnsupportedSubstrate();
    }

    function _getTroveIdOrRevert(address zapper) internal view returns (uint256 troveId) {
        troveId = FuseStorageLib.getEbisuTroveIds().troveIds[zapper];
        if (troveId == 0) revert TroveNotOpen();
    }
}
