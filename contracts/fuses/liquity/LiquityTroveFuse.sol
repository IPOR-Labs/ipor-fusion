// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {IAddressesRegistry} from "./ext/IAddressesRegistry.sol";
import {IBorrowerOperations} from "./ext/IBorrowerOperations.sol";
import {FuseStorageLib} from "../../libraries/FuseStorageLib.sol";
import "./LiquityConstants.sol";

struct LiquityTroveEnterData {
    address asset;
    address _owner;
    uint256 _ownerIndex;
    uint256 _collAmount;
    uint256 _boldAmount;
    uint256 _upperHint;
    uint256 _lowerHint;
    uint256 _annualInterestRate;
    uint256 _maxUpfrontFee;
    address _addManager;
    address _removeManager;
    address _receiver;
}

struct LiquityTroveExitData {
    address asset;
    uint256[] _troveIds;
}

contract LiquityTroveFuse is IFuseCommon {
    uint256 public immutable MARKET_ID;
    address public immutable VERSION;

    mapping(address => address) public assetToRegistry;

    event LiquityTroveFuseEnter(address version, address asset, address owner, uint256 troveId);
    event LiquityTroveFuseExit(address version, address asset, uint256 troveId);

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        assetToRegistry[
            address(IAddressesRegistry(LiquityConstants.LIQUITY_ETH_ADDRESSES_REGISTRY).collToken())
        ] = LiquityConstants.LIQUITY_ETH_ADDRESSES_REGISTRY;
        assetToRegistry[
            address(IAddressesRegistry(LiquityConstants.LIQUITY_WSTETH_ADDRESSES_REGISTRY).collToken())
        ] = LiquityConstants.LIQUITY_WSTETH_ADDRESSES_REGISTRY;
        assetToRegistry[
            address(IAddressesRegistry(LiquityConstants.LIQUITY_RETH_ADDRESSES_REGISTRY).collToken())
        ] = LiquityConstants.LIQUITY_RETH_ADDRESSES_REGISTRY;
    }

    function enter(LiquityTroveEnterData memory data_) external {
        address registry = assetToRegistry[data_.asset];
        if (registry == address(0)) {
            revert Errors.WrongAddress();
        }

        IBorrowerOperations borrowerOperations = IBorrowerOperations(IAddressesRegistry(registry).borrowerOperations());

        IERC20(data_.asset).approve(address(borrowerOperations), data_._collAmount);

        uint256 troveId = borrowerOperations.openTrove(
            data_._owner,
            data_._ownerIndex,
            data_._collAmount,
            data_._boldAmount,
            data_._upperHint,
            data_._lowerHint,
            data_._annualInterestRate,
            data_._maxUpfrontFee,
            data_._addManager,
            data_._removeManager,
            data_._receiver
        );

        IERC20(data_.asset).approve(address(borrowerOperations), 0);

        FuseStorageLib.LiquityV2TroveIds storage troveIds = FuseStorageLib.getLiquityV2TroveIds();
        troveIds.indexesByAsset[data_.asset][troveId] = troveIds.troveIdsByAsset[data_.asset].length;
        troveIds.troveIdsByAsset[data_.asset].push(troveId);

        emit LiquityTroveFuseEnter(VERSION, data_.asset, data_._owner, troveId);
    }

    function exit(LiquityTroveExitData calldata data_) external {
        address registry = assetToRegistry[data_.asset];
        if (registry == address(0)) {
            revert Errors.WrongAddress();
        }

        FuseStorageLib.LiquityV2TroveIds storage troveIds = FuseStorageLib.getLiquityV2TroveIds();

        uint256 len = troveIds.troveIdsByAsset[data_.asset].length;
        uint256 troveIndex;

        IBorrowerOperations borrowerOperations = IBorrowerOperations(IAddressesRegistry(registry).borrowerOperations());

        for (uint256 i; i < len; i++) {
            troveIndex = troveIds.indexesByAsset[data_.asset][data_._troveIds[i]];
            borrowerOperations.closeTrove(data_._troveIds[i]);

            troveIndex = troveIds.indexesByAsset[data_.asset][data_._troveIds[i]];
            if (troveIndex != len - 1) {
                troveIds.troveIdsByAsset[data_.asset][troveIndex] = troveIds.troveIdsByAsset[data_.asset][len - 1];
            }
            troveIds.troveIdsByAsset[data_.asset].pop();

            emit LiquityTroveFuseExit(VERSION, data_.asset, data_._troveIds[i]);
        }
    }
}
