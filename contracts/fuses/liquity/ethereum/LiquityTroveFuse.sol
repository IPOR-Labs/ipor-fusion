// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IFuseCommon} from "../../IFuseCommon.sol";
import {Errors} from "../../../libraries/errors/Errors.sol";
import {IAddressesRegistry} from "./ext/IAddressesRegistry.sol";
import {IBorrowerOperations} from "./ext/IBorrowerOperations.sol";
import {FuseStorageLib} from "../../../libraries/FuseStorageLib.sol";
import {IActivePool} from "./ext/IActivePool.sol";
import {ITroveManager} from "./ext/ITroveManager.sol";
import {LiquityMath} from "./ext/LiquityMath.sol";
import {PlasmaVaultConfigLib} from "../../../libraries/PlasmaVaultConfigLib.sol";
import "./LiquityConstants.sol";

struct LiquityTroveEnterData {
    address registry;
    uint256 _collAmount;
    uint256 _boldAmount;
    uint256 _upperHint;
    uint256 _lowerHint;
    uint256 _annualInterestRate;
    uint256 _maxUpfrontFee;
}

struct LiquityTroveExitData {
    address registry;
    uint256[] ownerIndexes;
}

contract LiquityTroveFuse is IFuseCommon {
    using SafeERC20 for ERC20;

    uint256 public immutable MARKET_ID;
    address public immutable VERSION;

    uint256 private constant MIN_ANNUAL_INTEREST_RATE = 1e16 / 2; // 0.5%
    uint256 private constant MAX_ANNUAL_INTEREST_RATE = 250 * 1e16; // 250%
    uint256 private constant UPFRONT_INTEREST_PERIOD = 7 days;
    uint256 private constant ONE_YEAR = 365 days;
    uint256 private constant DECIMAL_PRECISION = 1e18;
    uint256 private constant MIN_DEBT = 2000e18;

    event LiquityTroveFuseEnter(address version, address asset, uint256 ownerIndex, uint256 troveId);
    event LiquityTroveFuseExit(address version, address asset, uint256 troveId);

    error InvalidAnnualInterestRate();
    error InvalidRegistry();
    error UpfrontFeeTooHigh(uint256 fee);
    error DebtBelowMin(uint256 debt);
    error NewOracleFailureDetected();
    error ICRBelowMCR(uint256 icr, uint256 mcr);
    error DebtAboveBalance(uint256 debt, uint256 balance);

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    function enter(LiquityTroveEnterData calldata data_) external {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.registry)) revert InvalidRegistry();

        if (
            data_._annualInterestRate < MIN_ANNUAL_INTEREST_RATE || data_._annualInterestRate > MAX_ANNUAL_INTEREST_RATE
        ) {
            revert InvalidAnnualInterestRate();
        }

        FuseStorageLib.LiquityV2OwnerIndexes storage troveData = FuseStorageLib.getLiquityV2OwnerIndexes();
        uint256 newIndex = troveData.lastIndex++;
        IBorrowerOperations borrowerOperations = IBorrowerOperations(
            IAddressesRegistry(data_.registry).borrowerOperations()
        );

        _checkUpfrontFeeAndDebt(data_);
        address collToken = address(IAddressesRegistry(data_.registry).collToken());

        ERC20(collToken).forceApprove(address(borrowerOperations), type(uint256).max);

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

        ERC20(collToken).forceApprove(address(borrowerOperations), 0);

        troveData.idByOwnerIndex[data_.registry][newIndex] = troveId;

        emit LiquityTroveFuseEnter(VERSION, data_.registry, newIndex, troveId);
    }

    function exit(LiquityTroveExitData calldata data_) external {
        IBorrowerOperations borrowerOperations = IBorrowerOperations(
            IAddressesRegistry(data_.registry).borrowerOperations()
        );

        ITroveManager troveManager = ITroveManager(IAddressesRegistry(data_.registry).troveManager());
        ERC20 boldToken = ERC20(IAddressesRegistry(data_.registry).boldToken());

        FuseStorageLib.LiquityV2OwnerIndexes storage troveData = FuseStorageLib.getLiquityV2OwnerIndexes();
        uint256 len = data_.ownerIndexes.length;

        ERC20(LiquityConstants.LIQUITY_BOLD).forceApprove(address(borrowerOperations), type(uint256).max);

        for (uint256 i; i < len; i++) {
            uint256 troveId = troveData.idByOwnerIndex[data_.registry][data_.ownerIndexes[i]];
            if (troveId == 0) continue;

            if (troveManager.getLatestTroveData(troveId).entireDebt > boldToken.balanceOf(address(this))) {
                revert DebtAboveBalance(
                    troveManager.getLatestTroveData(troveId).entireDebt,
                    boldToken.balanceOf(address(this))
                );
            }

            borrowerOperations.closeTrove(troveId);
            delete troveData.idByOwnerIndex[data_.registry][data_.ownerIndexes[i]];

            emit LiquityTroveFuseExit(VERSION, data_.registry, troveId);
        }

        ERC20(LiquityConstants.LIQUITY_BOLD).forceApprove(address(borrowerOperations), 0);
    }

    function _calcUpfrontFee(uint256 _debt, uint256 _avgInterestRate) internal pure returns (uint256) {
        return _calcInterest(_debt * _avgInterestRate, UPFRONT_INTEREST_PERIOD);
    }

    function _calcInterest(uint256 _weightedDebt, uint256 _period) internal pure returns (uint256) {
        return (_weightedDebt * _period) / ONE_YEAR / DECIMAL_PRECISION;
    }

    function _requireUserAcceptsUpfrontFee(uint256 _fee, uint256 _maxFee) internal pure {
        if (_fee > _maxFee) {
            revert UpfrontFeeTooHigh(_fee);
        }
    }

    function _checkUpfrontFeeAndDebt(LiquityTroveEnterData memory data_) internal {
        IActivePool activePool = IAddressesRegistry(data_.registry).activePool();

        IActivePool.TroveChange memory _change;
        _change.collIncrease = data_._collAmount;
        _change.debtIncrease = data_._boldAmount;
        _change.newWeightedRecordedDebt = _change.debtIncrease * data_._annualInterestRate;

        uint256 avgInterestRate = activePool.getNewApproxAvgInterestRateFromTroveChange(_change);
        _change.upfrontFee = _calcUpfrontFee(_change.debtIncrease, avgInterestRate);
        _requireUserAcceptsUpfrontFee(_change.upfrontFee, data_._maxUpfrontFee);

        if (_change.debtIncrease + _change.upfrontFee < MIN_DEBT) {
            revert DebtBelowMin(_change.debtIncrease + _change.upfrontFee);
        }
        uint256 mcr = IAddressesRegistry(data_.registry).MCR();
        (uint256 price, bool newOracleFailureDetected) = IAddressesRegistry(data_.registry).priceFeed().fetchPrice();
        if (newOracleFailureDetected) {
            revert NewOracleFailureDetected();
        }
        uint256 icr = LiquityMath._computeCR(data_._collAmount, _change.debtIncrease + _change.upfrontFee, price);
        if (icr < mcr) {
            revert ICRBelowMCR(icr, mcr);
        }
    }
}
