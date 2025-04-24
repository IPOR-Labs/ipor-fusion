// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {IAddressesRegistry} from "./ext/IAddressesRegistry.sol";
import {IBorrowerOperations} from "./ext/IBorrowerOperations.sol";
import {FuseStorageLib} from "../../libraries/FuseStorageLib.sol";
import "./LiquityConstants.sol";

struct LiquityTroveEnterData {
    address asset;
    uint256 _collAmount;
    uint256 _boldAmount;
    uint256 _upperHint;
    uint256 _lowerHint;
    uint256 _annualInterestRate;
    uint256 _maxUpfrontFee;
}

struct LiquityTroveExitData {
    address asset;
    uint256[] ownerIndexes;
}

contract LiquityTroveFuse is IFuseCommon {
    using SafeERC20 for ERC20;

    uint256 public immutable MARKET_ID;
    address public immutable VERSION;

    event LiquityTroveFuseEnter(address version, address asset, uint256 ownerIndex, uint256 troveId);
    event LiquityTroveFuseExit(address version, address asset, uint256 troveId);

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        FuseStorageLib.LiquityV2AssetToRegistry storage mappingStore = FuseStorageLib.getLiquityV2AssetToRegistry();

        mappingStore.registryByAsset[
            address(IAddressesRegistry(LiquityConstants.LIQUITY_ETH_ADDRESSES_REGISTRY).collToken())
        ] = LiquityConstants.LIQUITY_ETH_ADDRESSES_REGISTRY;
        mappingStore.registryByAsset[
            address(IAddressesRegistry(LiquityConstants.LIQUITY_WSTETH_ADDRESSES_REGISTRY).collToken())
        ] = LiquityConstants.LIQUITY_WSTETH_ADDRESSES_REGISTRY;
        mappingStore.registryByAsset[
            address(IAddressesRegistry(LiquityConstants.LIQUITY_RETH_ADDRESSES_REGISTRY).collToken())
        ] = LiquityConstants.LIQUITY_RETH_ADDRESSES_REGISTRY;
    }

    function enter(LiquityTroveEnterData calldata data_) external {
        address registry = FuseStorageLib.getLiquityV2AssetToRegistry().registryByAsset[data_.asset];
        if (registry == address(0)) {
            revert Errors.WrongAddress();
        }
        FuseStorageLib.LiquityV2OwnerIndexes storage troveData = FuseStorageLib.getLiquityV2OwnerIndexes();
        uint256 newIndex = troveData.lastIndex++;
        IBorrowerOperations borrowerOperations = IBorrowerOperations(IAddressesRegistry(registry).borrowerOperations());

        ERC20(data_.asset).forceApprove(address(borrowerOperations), data_._collAmount);

        // it's better to compute upperHint and lowerHint off-chain, since calculating on-chain is expensive
        uint256 troveId = borrowerOperations.openTrove(
            address(this),
            newIndex,
            data_._collAmount,
            data_._boldAmount,
            data_._upperHint,
            data_._lowerHint,
            data_._annualInterestRate,
            data_._maxUpfrontFee,
            address(0), // anybody can add collateral and pay debt
            address(this), // only this contract can withdraw collateral and borrow
            address(this) // this contract is the recipient of the trove funds
        );

        ERC20(data_.asset).forceApprove(address(borrowerOperations), 0);

        troveData.idByOwnerIndex[data_.asset][newIndex] = troveId;

        emit LiquityTroveFuseEnter(VERSION, data_.asset, newIndex, troveId);
    }

    function exit(LiquityTroveExitData calldata data_) external {
        address registry = FuseStorageLib.getLiquityV2AssetToRegistry().registryByAsset[data_.asset];
        if (registry == address(0)) {
            revert Errors.WrongAddress();
        }

        IBorrowerOperations borrowerOperations = IBorrowerOperations(IAddressesRegistry(registry).borrowerOperations());
        FuseStorageLib.LiquityV2OwnerIndexes storage troveData = FuseStorageLib.getLiquityV2OwnerIndexes();
        uint256 len = data_.ownerIndexes.length;

        for (uint256 i; i < len; i++) {
            uint256 troveId = troveData.idByOwnerIndex[data_.asset][data_.ownerIndexes[i]];
            if (troveId == 0) continue;

            ERC20(LiquityConstants.LIQUITY_BOLD).forceApprove(address(borrowerOperations), type(uint256).max);
            borrowerOperations.closeTrove(troveId);
            ERC20(LiquityConstants.LIQUITY_BOLD).forceApprove(address(borrowerOperations), 0);
            delete troveData.idByOwnerIndex[data_.asset][data_.ownerIndexes[i]];

            emit LiquityTroveFuseExit(VERSION, data_.asset, troveId);
        }
    }
}
