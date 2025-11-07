// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IFuseCommon} from "../IFuseCommon.sol";
import {IBorrowerOperations} from "./ext/IBorrowerOperations.sol";
import {IAddressesRegistry} from "./ext/IAddressesRegistry.sol";
import {FuseStorageLib} from "../../libraries/FuseStorageLib.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {EbisuZapperSubstrateLib, EbisuZapperSubstrate, EbisuZapperSubstrateType} from "./lib/EbisuZapperSubstrateLib.sol";

contract EbisuSetDelegateFuse is IFuseCommon {
    uint256 public immutable MARKET_ID;

    error UnsupportedSubstrate();
    error TroveNotOpen();
    error DelegateAddressZero();

    event EbisuSetDelegateFuseEnter(uint256 troveId, address delegate);

    struct EbisuSetDelegateFuseEnterData {
        address zapper;
        address registry;
        address delegate;
        uint128 minInterestRate;
        uint128 maxInterestRate;
        uint256 minInterestRateChangePeriod;
    }

    constructor(uint256 marketId_) {
        MARKET_ID = marketId_;
    }

    function enter(EbisuSetDelegateFuseEnterData calldata data_) external {
        _requireSupportedSubstrates(data_.zapper, data_.registry);

        if (data_.delegate == address(0)) revert DelegateAddressZero();

        uint256 troveId = _getTroveIdOrRevert(data_.zapper);

        IBorrowerOperations(IAddressesRegistry(data_.registry).borrowerOperations()).setInterestIndividualDelegate(
            troveId,
            data_.delegate,
            data_.minInterestRate,
            data_.maxInterestRate,
            0,
            0,
            0,
            0,
            data_.minInterestRateChangePeriod
        );

        emit EbisuSetDelegateFuseEnter(troveId, data_.delegate);
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
