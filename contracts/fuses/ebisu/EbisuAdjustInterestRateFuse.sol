// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFuseCommon} from "../IFuseCommon.sol";
import {IBorrowerOperations} from "./ext/IBorrowerOperations.sol";
import {IAddressesRegistry} from "./ext/IAddressesRegistry.sol";
import {FuseStorageLib} from "../../libraries/FuseStorageLib.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {EbisuZapperSubstrateLib, EbisuZapperSubstrate, EbisuZapperSubstrateType} from "./lib/EbisuZapperSubstrateLib.sol";

/// @notice Fuse to modify the interest rate of an open trove
/// since the owner of the trove is the PlasmaVault, a Fuse is necessary to act on it
contract EbisuAdjustInterestRateFuse is IFuseCommon {
    uint256 public immutable MARKET_ID;

    error UnsupportedSubstrate();
    error TroveNotOpen();

    event EbisuAdjustInterestRateFuseEnter(uint256 troveId, uint256 newAnnualInterestRate);

    /// @notice Data to close an open Trove through Zapper
    /// @param zapper the zapper address
    /// @param registry the registry where the borrower operations for the trove is listed
    /// @param newAnnualInterestRate the new annual interest rate
    /// @param maxUpfrontFee the maximum upfront fee to be paid for the operation
    /// @param upperHint upper bound given to SortedTroves to facilitate array insertion on Liquity (better values -> gas saving)
    /// @param lowerHint lower bound given to SortedTroves to facilitate array insertion on Liquity (better values -> gas saving)
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

    /// @notice adjusts the interest rate of the Trove open by this Plasma Vault
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

    function _requireSupportedSubstrates(address zapper_, address registry_) internal view {
        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                EbisuZapperSubstrateLib.substrateToBytes32(
                    EbisuZapperSubstrate({substrateType: EbisuZapperSubstrateType.ZAPPER, substrateAddress: zapper_})
                )
            )
        ) revert UnsupportedSubstrate();

        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                EbisuZapperSubstrateLib.substrateToBytes32(
                    EbisuZapperSubstrate({
                        substrateType: EbisuZapperSubstrateType.REGISTRY,
                        substrateAddress: registry_
                    })
                )
            )
        ) revert UnsupportedSubstrate();
    }

    function _getTroveIdOrRevert(address zapper_) internal view returns (uint256 troveId) {
        troveId = FuseStorageLib.getEbisuTroveIds().troveIds[zapper_];
        if (troveId == 0) revert TroveNotOpen();
    }
}
