// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFuseCommon} from "../IFuseCommon.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IBorrowerOperations} from "./ext/IBorrowerOperations.sol";
import {IAddressesRegistry} from "./ext/IAddressesRegistry.sol";
import {FuseStorageLib} from "../../libraries/FuseStorageLib.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {EbisuZapperSubstrateLib, EbisuZapperSubstrate, EbisuZapperSubstrateType} from "./lib/EbisuZapperSubstrateLib.sol";

/// @notice Fuse to modify the collateral and debt of an open trove
/// since the owner of the trove is the PlasmaVault, a Fuse is necessary to act on it
contract EbisuAdjustTroveFuse is IFuseCommon {
    using SafeERC20 for IERC20;
    uint256 public immutable MARKET_ID;

    error UnsupportedSubstrate();
    error TroveNotOpen();

    event EbisuAdjustTroveFuseEnter(uint256 troveId, uint256 collChange, uint256 debtChange, bool isCollIncrease, bool isDebtIncrease);

    /// @notice Data to close an open Trove through Zapper
    /// @param zapper the zapper address
    /// @param registry the registry where the borrower operations for the trove is listed
    /// @param collChange the new collateral rate
    /// @param debtChange the new debt
    /// @param isCollIncrease wether the collateral is being increased
    /// @param isDebtIncrease wether the debt is being increased
    struct EbisuAdjustTroveFuseEnterData {
        address zapper;
        address registry;
        uint256 collChange;
        uint256 debtChange;
        bool isCollIncrease;
        bool isDebtIncrease;
        uint256 maxUpfrontFee;
    }

    constructor(uint256 marketId_) {
        MARKET_ID = marketId_;
    }

    /// @notice adjusts the collateral and debt of the Trove open by this Plasma Vault
    function enter(EbisuAdjustTroveFuseEnterData calldata data_) external {
        _requireSupportedSubstrates(data_.zapper, data_.registry);

        uint256 troveId = _getTroveIdOrRevert(data_.zapper);

        IAddressesRegistry registry = IAddressesRegistry(data_.registry);
        IERC20 ebusdToken = IERC20(registry.boldToken());
        IERC20 collToken = IERC20(registry.collToken());
        IBorrowerOperations registryBorrowerOperations = IBorrowerOperations(address(registry.borrowerOperations()));

        // bold is burnt when debt is reduced, so approve only in that case
        if(!data_.isDebtIncrease)
            ebusdToken.forceApprove(address(registryBorrowerOperations), data_.debtChange);

        // collateral is taken from vault when increased, so approve only in that case
        if(data_.isCollIncrease)
            collToken.forceApprove(address(registryBorrowerOperations), data_.collChange);
        registryBorrowerOperations.adjustTrove(
            troveId,
            data_.collChange,
            data_.isCollIncrease,
            data_.debtChange,
            data_.isDebtIncrease,
            data_.maxUpfrontFee
        );
        
        if(!data_.isDebtIncrease)
            ebusdToken.forceApprove(address(registryBorrowerOperations), 0);
        if(data_.isCollIncrease)
            collToken.forceApprove(address(registryBorrowerOperations), 0);

        emit EbisuAdjustTroveFuseEnter(troveId, data_.collChange, data_.debtChange, data_.isCollIncrease, data_.isDebtIncrease);
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
