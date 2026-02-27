// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFuseCommon} from "../IFuseCommon.sol";
import {IDolomiteAccountRegistry} from "./ext/IDolomiteAccountRegistry.sol";

/// @dev Struct for enabling E-mode on a Dolomite sub-account
struct DolomiteEModeFuseEnterData {
    /// @notice sub-account to enable E-mode for
    uint8 subAccountId;
    /// @notice E-mode category ID (0 = disable)
    uint8 categoryId;
}

/// @dev Struct for disabling E-mode on a Dolomite sub-account
struct DolomiteEModeFuseExitData {
    /// @notice sub-account to disable E-mode for
    uint8 subAccountId;
}

/// @title DolomiteEModeFuse
/// @notice Fuse for managing E-mode (Efficiency Mode) in Dolomite protocol
/// @author IPOR Labs
contract DolomiteEModeFuse is IFuseCommon {
    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address public immutable DOLOMITE_ACCOUNT_REGISTRY;

    event DolomiteEModeFuseEnter(address version, uint8 subAccountId, uint8 categoryId, string categoryLabel);

    event DolomiteEModeFuseExit(address version, uint8 subAccountId, uint8 previousCategoryId);

    error DolomiteEModeFuseInvalidMarketId();
    error DolomiteEModeFuseInvalidAccountRegistry();
    error DolomiteEModeFuseInvalidCategory(uint8 categoryId);
    error DolomiteEModeFuseAlreadyInMode(uint8 subAccountId, uint8 currentCategoryId);
    error DolomiteEModeFuseNotInEMode(uint8 subAccountId);

    constructor(uint256 marketId_, address dolomiteAccountRegistry_) {
        if (marketId_ == 0) {
            revert DolomiteEModeFuseInvalidMarketId();
        }
        if (dolomiteAccountRegistry_ == address(0)) {
            revert DolomiteEModeFuseInvalidAccountRegistry();
        }

        VERSION = address(this);
        MARKET_ID = marketId_;
        DOLOMITE_ACCOUNT_REGISTRY = dolomiteAccountRegistry_;
    }

    /// @notice Enables E-mode for a sub-account
    /// @param data_ The enter data
    /// @return subAccountId The configured sub-account
    /// @return categoryId The enabled category
    function enter(DolomiteEModeFuseEnterData memory data_) public returns (uint8 subAccountId, uint8 categoryId) {
        if (data_.categoryId == 0) {
            revert DolomiteEModeFuseInvalidCategory(data_.categoryId);
        }

        IDolomiteAccountRegistry.EModeCategory memory category = IDolomiteAccountRegistry(DOLOMITE_ACCOUNT_REGISTRY)
            .getEModeCategory(data_.categoryId);

        if (category.id == 0) {
            revert DolomiteEModeFuseInvalidCategory(data_.categoryId);
        }

        uint8 currentCategoryId = IDolomiteAccountRegistry(DOLOMITE_ACCOUNT_REGISTRY).getAccountEMode(
            address(this),
            uint256(data_.subAccountId)
        );

        if (currentCategoryId == data_.categoryId) {
            revert DolomiteEModeFuseAlreadyInMode(data_.subAccountId, currentCategoryId);
        }

        IDolomiteAccountRegistry(DOLOMITE_ACCOUNT_REGISTRY).setAccountEMode(
            uint256(data_.subAccountId),
            data_.categoryId
        );

        emit DolomiteEModeFuseEnter(VERSION, data_.subAccountId, data_.categoryId, category.label);

        return (data_.subAccountId, data_.categoryId);
    }

    /// @notice Disables E-mode for a sub-account
    /// @param data_ The exit data
    /// @return subAccountId The configured sub-account
    /// @return previousCategoryId The disabled category
    function exit(
        DolomiteEModeFuseExitData memory data_
    ) public returns (uint8 subAccountId, uint8 previousCategoryId) {
        uint8 currentCategoryId = IDolomiteAccountRegistry(DOLOMITE_ACCOUNT_REGISTRY).getAccountEMode(
            address(this),
            uint256(data_.subAccountId)
        );

        if (currentCategoryId == 0) {
            revert DolomiteEModeFuseNotInEMode(data_.subAccountId);
        }

        IDolomiteAccountRegistry(DOLOMITE_ACCOUNT_REGISTRY).setAccountEMode(uint256(data_.subAccountId), 0);

        emit DolomiteEModeFuseExit(VERSION, data_.subAccountId, currentCategoryId);

        return (data_.subAccountId, currentCategoryId);
    }
}
