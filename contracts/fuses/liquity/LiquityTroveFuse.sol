// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {IAddressesRegistry} from "./ext/IAddressesRegistry.sol";
import {IBorrowerOperations} from "./ext/IBorrowerOperations.sol";
import {IPriceFeed} from "./ext/IPriceFeed.sol";
import {FuseStorageLib} from "../../libraries/FuseStorageLib.sol";
import {IActivePool} from "./ext/IActivePool.sol";
import {ITroveManager} from "./ext/ITroveManager.sol";
import {LiquityMath} from "./ext/LiquityMath.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

/// @title Fuse for Liquity protocol responsible for calculating the balance of the Plasma Vault in Liquity protocol based on preconfigured market substrates
/// @dev Substrates in this fuse are the address registries of Liquity protocol that are used in the Liquity protocol for a given MARKET_ID
struct LiquityTroveEnterData {
    address registry;
    uint256 newIndex;
    uint256 collAmount;
    uint256 boldAmount;
    uint256 upperHint;
    uint256 lowerHint;
    uint256 annualInterestRate;
    uint256 maxUpfrontFee;
}

struct LiquityTroveExitData {
    address registry;
    uint256[] ownerIndexes;
}

contract LiquityTroveFuse is IFuseCommon {
    using SafeERC20 for ERC20;

    uint256 public immutable MARKET_ID;

    uint256 private constant MIN_ANNUAL_INTEREST_RATE = 1e16 / 2; // 0.5%
    uint256 private constant MAX_ANNUAL_INTEREST_RATE = 250 * 1e16; // 250%
    uint256 private constant UPFRONT_INTEREST_PERIOD = 7 days;
    uint256 private constant ONE_YEAR = 365 days;
    uint256 private constant DECIMAL_PRECISION = 1e18;
    uint256 private constant MIN_DEBT = 2000e18;

    event LiquityTroveFuseEnter(address asset, uint256 ownerIndex, uint256 troveId);
    event LiquityTroveFuseExit(address asset, uint256 troveId);

    error InvalidAnnualInterestRate();
    error InvalidRegistry();
    error UpfrontFeeTooHigh(uint256 fee);
    error DebtBelowMin(uint256 debt);
    error NewOracleFailureDetected();
    error ICRBelowMCR(uint256 icr, uint256 mcr);
    error DebtAboveBalance(uint256 debt, uint256 balance);
    error IndexAlreadyUsed();

    constructor(uint256 marketId_) {
        MARKET_ID = marketId_;
    }

    function enter(LiquityTroveEnterData calldata data) external {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data.registry)) revert InvalidRegistry();

        if (data.annualInterestRate < MIN_ANNUAL_INTEREST_RATE || data.annualInterestRate > MAX_ANNUAL_INTEREST_RATE) {
            revert InvalidAnnualInterestRate();
        }

        IBorrowerOperations borrowerOperations = IBorrowerOperations(
            IAddressesRegistry(data.registry).borrowerOperations()
        );

        _checkUpfrontFeeAndDebt(data);
        address collToken = address(IAddressesRegistry(data.registry).collToken());

        ERC20(collToken).forceApprove(address(borrowerOperations), type(uint256).max);

        FuseStorageLib.LiquityV2OwnerIds storage ownerIdsData = FuseStorageLib.getLiquityV2OwnerIds();
        if(ownerIdsData.idsByIndex[data.registry][data.newIndex] != 0) revert IndexAlreadyUsed();

        // it's better to compute upperHint and lowerHint off-chain, since calculating on-chain is expensive
        uint256 troveId = borrowerOperations.openTrove(
            address(this),
            data.newIndex,
            data.collAmount,
            data.boldAmount,
            data.upperHint,
            data.lowerHint,
            data.annualInterestRate,
            data.maxUpfrontFee,
            address(0), // anybody can add collateral and pay debt
            address(this), // only this contract can withdraw collateral and borrow
            address(this) // this contract is the recipient of the trove funds
        );

        ERC20(collToken).forceApprove(address(borrowerOperations), 0);

        ownerIdsData.idsByIndex[data.registry][data.newIndex] = troveId;
        ownerIdsData.troveIds[data.registry].push(troveId);

        emit LiquityTroveFuseEnter(data.registry, data.newIndex, troveId);
    }

    function exit(LiquityTroveExitData calldata data) external {
        uint256 len = data.ownerIndexes.length;
        if (len == 0) return;

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data.registry)) revert InvalidRegistry();
        IBorrowerOperations borrowerOperations = IBorrowerOperations(
            IAddressesRegistry(data.registry).borrowerOperations()
        );

        ITroveManager troveManager = ITroveManager(IAddressesRegistry(data.registry).troveManager());
        ERC20 boldToken = ERC20(IAddressesRegistry(data.registry).boldToken());

        FuseStorageLib.LiquityV2OwnerIds storage troveData = FuseStorageLib.getLiquityV2OwnerIds();

        boldToken.forceApprove(address(borrowerOperations), type(uint256).max);

        uint256 troveId;
        for (uint256 i; i < len; i++) {
            troveId = troveData.idsByIndex[data.registry][data.ownerIndexes[i]];
            if (troveId == 0) continue;

            if (troveManager.getLatestTroveData(troveId).entireDebt > boldToken.balanceOf(address(this))) {
                revert DebtAboveBalance(
                    troveManager.getLatestTroveData(troveId).entireDebt,
                    boldToken.balanceOf(address(this))
                );
            }

            borrowerOperations.closeTrove(troveId);

            emit LiquityTroveFuseExit(data.registry, troveId);
        }

        boldToken.forceApprove(address(borrowerOperations), 0);
    }

    function _calcUpfrontFee(uint256 debt, uint256 avgInterestRate) internal pure returns (uint256) {
        return _calcInterest(debt * avgInterestRate, UPFRONT_INTEREST_PERIOD);
    }

    function _calcInterest(uint256 weightedDebt, uint256 period) internal pure returns (uint256) {
        return (weightedDebt * period) / ONE_YEAR / DECIMAL_PRECISION;
    }

    function _requireUserAcceptsUpfrontFee(uint256 fee, uint256 maxFee) internal pure {
        if (fee > maxFee) {
            revert UpfrontFeeTooHigh(fee);
        }
    }

    function _checkUpfrontFeeAndDebt(LiquityTroveEnterData memory data) internal {
        IActivePool activePool = IAddressesRegistry(data.registry).activePool();

        IActivePool.TroveChange memory change;
        change.collIncrease = data.collAmount;
        change.debtIncrease = data.boldAmount;
        change.newWeightedRecordedDebt = change.debtIncrease * data.annualInterestRate;

        uint256 avgInterestRate = activePool.getNewApproxAvgInterestRateFromTroveChange(change);
        change.upfrontFee = _calcUpfrontFee(change.debtIncrease, avgInterestRate);
        _requireUserAcceptsUpfrontFee(change.upfrontFee, data.maxUpfrontFee);

        if (change.debtIncrease + change.upfrontFee < MIN_DEBT) {
            revert DebtBelowMin(change.debtIncrease + change.upfrontFee);
        }
        uint256 mcr = IAddressesRegistry(data.registry).MCR();
        (uint256 price, bool newOracleFailureDetected) = IPriceFeed(IAddressesRegistry(data.registry).priceFeed()).fetchPrice();
        if (newOracleFailureDetected) {
            revert NewOracleFailureDetected();
        }
        uint256 icr = LiquityMath._computeCR(data.collAmount, change.debtIncrease + change.upfrontFee, price);
        if (icr < mcr) {
            revert ICRBelowMCR(icr, mcr);
        }
    }
}