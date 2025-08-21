// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {IAddressesRegistry} from "./ext/IAddressesRegistry.sol";
import {IBorrowerOperations} from "./ext/IBorrowerOperations.sol";
import {IPriceFeed} from "./ext/IPriceFeed.sol";
import {EbisuFuseStorageLib} from "../../libraries/EbisuFuseStorageLib.sol";
import {IActivePool} from "./ext/IActivePool.sol";
import {ITroveManager} from "./ext/ITroveManager.sol";
import {EbisuMath} from "./ext/EbisuMath.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

/// @title Fuse for Ebisu protocol responsible for calculating the balance of the Plasma Vault in Ebisu protocol based on preconfigured market substrates
/// @dev Substrates in this fuse are the address registries of Ebisu protocol that are used in the Ebisu protocol for a given MARKET_ID
struct EbisuTroveEnterData {
    address registry;
    uint256 newIndex;
    uint256 collAmount;
    uint256 ebusdAmount;
    uint256 upperHint;
    uint256 lowerHint;
    uint256 annualInterestRate;
    uint256 maxUpfrontFee;
}

struct EbisuTroveExitData {
    address registry;
    uint256[] ownerIndexes;
}

struct EbisuTroveManageData {
    address registry;
    uint256 troveId;
    uint256 amount;
}

struct EbisuTroveInterestManagerData {
    address registry;
    uint256 troveId;
    address interestManager;
}

contract EbisuFuse is IFuseCommon {
    using SafeERC20 for ERC20;

    uint256 public immutable MARKET_ID;

    uint256 private constant MIN_ANNUAL_INTEREST_RATE = 1e16 / 2; // 0.5%
    uint256 private constant MAX_ANNUAL_INTEREST_RATE = 250 * 1e16; // 250%
    uint256 private constant UPFRONT_INTEREST_PERIOD = 7 days;
    uint256 private constant ONE_YEAR = 365 days;
    uint256 private constant DECIMAL_PRECISION = 1e18;
    uint256 private constant MIN_DEBT = 2000e18;
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    event EbisuTroveFuseEnter(address asset, uint256 ownerIndex, uint256 troveId);
    event EbisuTroveFuseExit(address asset, uint256 troveId);    
    event EbisuTroveFuseAddCollateral(address registry, uint256 troveId, uint256 amount);
    event EbisuTroveFuseWithdrawCollateral(address registry, uint256 troveId, uint256 amount);
    event EbisuTroveFuseBorrowMore(address registry, uint256 troveId, uint256 amount);
    event EbisuTroveFuseRepayDebt(address registry, uint256 troveId, uint256 amount);
    event EbisuTroveFuseSetInterestManager(address registry, uint256 troveId, address interestManager);

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

    function enter(EbisuTroveEnterData calldata data) external {
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
        
        // Approve WETH for upfront fees
        ERC20(WETH).forceApprove(address(borrowerOperations), type(uint256).max);

        EbisuFuseStorageLib.EbisuOwnerIds storage ownerIdsData = EbisuFuseStorageLib.getEbisuOwnerIds();
        if(ownerIdsData.idsByIndex[data.registry][data.newIndex] != 0) revert IndexAlreadyUsed();

        // it's better to compute upperHint and lowerHint off-chain, since calculating on-chain is expensive
        uint256 troveId = borrowerOperations.openTrove(
            address(this),
            data.newIndex,
            data.collAmount,
            data.ebusdAmount,
            data.upperHint,
            data.lowerHint,
            data.annualInterestRate,
            data.maxUpfrontFee,
            address(0), // anybody can add collateral and pay debt
            address(this), // only this contract can withdraw collateral and borrow
            address(this) // this contract is the recipient of the trove funds
        );

        ERC20(collToken).forceApprove(address(borrowerOperations), 0);
        // Reset WETH approval
        ERC20(WETH).forceApprove(address(borrowerOperations), 0);

        ownerIdsData.idsByIndex[data.registry][data.newIndex] = troveId;
        ownerIdsData.troveIds[data.registry].push(troveId);
        ownerIdsData.indexes[data.registry][troveId] = ownerIdsData.troveIds[data.registry].length - 1;

        emit EbisuTroveFuseEnter(data.registry, data.newIndex, troveId);
    }

    function exit(EbisuTroveExitData calldata data) external {
        uint256 len = data.ownerIndexes.length;
        if (len == 0) return;

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data.registry)) revert InvalidRegistry();
        IBorrowerOperations borrowerOperations = IBorrowerOperations(
            IAddressesRegistry(data.registry).borrowerOperations()
        );

        ITroveManager troveManager = ITroveManager(IAddressesRegistry(data.registry).troveManager());
        ERC20 ebusdToken = ERC20(IAddressesRegistry(data.registry).boldToken());

        EbisuFuseStorageLib.EbisuOwnerIds storage troveData = EbisuFuseStorageLib.getEbisuOwnerIds();

        ebusdToken.forceApprove(address(borrowerOperations), type(uint256).max);

        uint256 troveId;
        for (uint256 i; i < len; i++) {
            troveId = troveData.idsByIndex[data.registry][data.ownerIndexes[i]];
            if (troveId == 0) continue;

            if (troveManager.getLatestTroveData(troveId).entireDebt > ebusdToken.balanceOf(address(this))) {
                revert DebtAboveBalance(
                    troveManager.getLatestTroveData(troveId).entireDebt,
                    ebusdToken.balanceOf(address(this))
                );
            }

            borrowerOperations.closeTrove(troveId);

            // Remove troveId from the array using swap-and-pop pattern
            uint256[] storage troveIdsArray = troveData.troveIds[data.registry];
            uint256 troveIndex = troveData.indexes[data.registry][troveId];
            uint256 lastIndex = troveIdsArray.length - 1;
            
            if (troveIndex != lastIndex) {
                uint256 lastTroveId = troveIdsArray[lastIndex];
                troveIdsArray[troveIndex] = lastTroveId;
                troveData.indexes[data.registry][lastTroveId] = troveIndex;
            }
            
            troveIdsArray.pop();
            delete troveData.indexes[data.registry][troveId];
            delete troveData.idsByIndex[data.registry][data.ownerIndexes[i]];

            emit EbisuTroveFuseExit(data.registry, troveId);
        }

        ebusdToken.forceApprove(address(borrowerOperations), 0);
    }

    function addCollateral(EbisuTroveManageData calldata data) external {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data.registry)) revert InvalidRegistry();
        
        IBorrowerOperations borrowerOperations = IBorrowerOperations(
            IAddressesRegistry(data.registry).borrowerOperations()
        );
        
        address collToken = address(IAddressesRegistry(data.registry).collToken());
        ERC20(collToken).forceApprove(address(borrowerOperations), data.amount);
        
        borrowerOperations.addCollateral(data.troveId, data.amount);
        
        ERC20(collToken).forceApprove(address(borrowerOperations), 0);
        
        emit EbisuTroveFuseAddCollateral(data.registry, data.troveId, data.amount);
    }

    function withdrawCollateral(EbisuTroveManageData calldata data) external {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data.registry)) revert InvalidRegistry();
        
        IBorrowerOperations borrowerOperations = IBorrowerOperations(
            IAddressesRegistry(data.registry).borrowerOperations()
        );
        
        borrowerOperations.withdrawCollateral(data.troveId, data.amount);
        
        emit EbisuTroveFuseWithdrawCollateral(data.registry, data.troveId, data.amount);
    }

    function borrowMore(EbisuTroveManageData calldata data) external {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data.registry)) revert InvalidRegistry();
        
        IBorrowerOperations borrowerOperations = IBorrowerOperations(
            IAddressesRegistry(data.registry).borrowerOperations()
        );
        
        borrowerOperations.borrowMore(data.troveId, data.amount);
        
        emit EbisuTroveFuseBorrowMore(data.registry, data.troveId, data.amount);
    }

    function repayDebt(EbisuTroveManageData calldata data) external {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data.registry)) revert InvalidRegistry();
        
        IBorrowerOperations borrowerOperations = IBorrowerOperations(
            IAddressesRegistry(data.registry).borrowerOperations()
        );
        
        ERC20 ebusdToken = ERC20(IAddressesRegistry(data.registry).boldToken());
        ebusdToken.forceApprove(address(borrowerOperations), data.amount);
        
        borrowerOperations.repayDebt(data.troveId, data.amount);
        
        ebusdToken.forceApprove(address(borrowerOperations), 0);
        
        emit EbisuTroveFuseRepayDebt(data.registry, data.troveId, data.amount);
    }

    function setInterestManager(EbisuTroveInterestManagerData calldata data) external {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data.registry)) revert InvalidRegistry();
        
        IBorrowerOperations borrowerOperations = IBorrowerOperations(
            IAddressesRegistry(data.registry).borrowerOperations()
        );
        
        borrowerOperations.setInterestManager(data.troveId, data.interestManager);
        
        emit EbisuTroveFuseSetInterestManager(data.registry, data.troveId, data.interestManager);
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

    function _checkUpfrontFeeAndDebt(EbisuTroveEnterData memory data) internal {
        IActivePool activePool = IAddressesRegistry(data.registry).activePool();

        IActivePool.TroveChange memory change;
        change.collIncrease = data.collAmount;
        change.debtIncrease = data.ebusdAmount;
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
        uint256 icr = EbisuMath._computeCR(data.collAmount, change.debtIncrease + change.upfrontFee, price);
        if (icr < mcr) {
            revert ICRBelowMCR(icr, mcr);
        }
    }
}
