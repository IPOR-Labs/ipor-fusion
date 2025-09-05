// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {ILeverageZapper} from "./ext/ILeverageZapper.sol";
import {IActivePool} from "./ext/IActivePool.sol";
import {IAddressesRegistry} from "./ext/IAddressesRegistry.sol";
import {IPriceFeed} from "./ext/IPriceFeed.sol";
import {LiquityMath} from "./ext/LiquityMath.sol";
import {FuseStorageLib} from "../../libraries/FuseStorageLib.sol";
import {EbisuMathLibrary} from "./EbisuMathLibrary.sol";

enum EnterType {
    ENTER,
    LEVERUP,
    LEVERDOWN
}

enum ExitType {
    ETH,
    COLLATERAL
}

struct EbisuZapperFuseEnterData {
    address zapper;
    address registry;
    uint256 ownerIndex;
    uint256 collAmount;
    uint256 ebusdAmount;
    uint256 upperHint;
    uint256 lowerHint;
    uint256 flashLoanAmount;
    uint256 annualInterestRate;
    uint256 maxUpfrontFee;  
    EnterType enterType; 
}

struct EbisuZapperFuseExitData {
    address zapper;
    uint256 ownerIndex;    
    uint256 flashLoanAmount;
    uint256 minExpectedCollateral;
    ExitType exitType;
}

contract EbisuZapperFuse is IFuseCommon {
    using SafeERC20 for ERC20;
    uint256 public immutable MARKET_ID;
    
    uint256 public constant ETH_GAS_COMPENSATION = 0.0375 ether; // from zapper

    uint256 private constant MIN_ANNUAL_INTEREST_RATE = 1e16 / 2; // 0.5%
    uint256 private constant MAX_ANNUAL_INTEREST_RATE = 250 * 1e16; // 250%
    uint256 private constant UPFRONT_INTEREST_PERIOD = 7 days;
    uint256 private constant ONE_YEAR = 365 days;
    uint256 private constant DECIMAL_PRECISION = 1e18;
    uint256 private constant MIN_DEBT = 2000e18;

    error DebtBelowMin(uint256 debt);
    error ICRBelowMCR(uint256 icr, uint256 mcr);
    error NewOracleFailureDetected();
    error UnknownEnterType();
    error UnknownExitType();
    error UpfrontFeeTooHigh(uint256 fee);
    
    event EbisuZapperFuseEnter(address zapper, uint256 collAmount, uint256 flashLoanAmount, uint256 ebusdAmount);
    event EbisuZapperFuseLeverDown(address zapper, uint256 ownerIndex, uint256 flashLoanAmount, uint256 ebusdAmount);
    event EbisuZapperFuseLeverUp(address zapper, uint256 ownerIndex, uint256 flashLoanAmount, uint256 ebusdAmount);
    event EbisuZapperFuseExit(address zapper, uint256 ownerIndex);

    constructor(uint256 marketId_) {
        MARKET_ID = marketId_;
    }
    
    // TODO, does iPOR accepts this to be PAYABLE? 
    function enter(EbisuZapperFuseEnterData memory data) external payable {
        ILeverageZapper zapper = ILeverageZapper(data.zapper);
        
        ERC20 collToken = ERC20(zapper.collToken());

        if (data.enterType == EnterType.ENTER) {
            _checkUpfrontFeeAndDebt(data);
            collToken.forceApprove(data.zapper, type(uint256).max);

            ILeverageZapper.OpenLeveragedTroveParams memory params = 
                ILeverageZapper.OpenLeveragedTroveParams({
                        owner: address(this), // the plasma vault
                        ownerIndex: data.ownerIndex,
                        collAmount: data.collAmount,
                        flashLoanAmount: data.flashLoanAmount,
                        boldAmount: data.ebusdAmount, // bold | ebusd (here)
                        upperHint: data.upperHint, // TODO: investigate more, BUT these are likely to optimize the trove insertion into sorted data strcutre
                        lowerHint: data.lowerHint, // same as above
                        annualInterestRate: data.annualInterestRate,
                        batchManager: address(0),
                        maxUpfrontFee: data.maxUpfrontFee,
                        addManager: address(0),
                        removeManager: address(this),
                        receiver: msg.sender
                    }
                );

            zapper.openLeveragedTroveWithRawETH{value: ETH_GAS_COMPENSATION}(params);

            collToken.forceApprove(data.zapper, 0);

            FuseStorageLib.EbisuOwnerIds storage ownerData = FuseStorageLib.getEbisuOwnerIds();
            ownerData.ownerIds[data.zapper].push(data.ownerIndex);

            emit EbisuZapperFuseEnter(data.zapper, data.collAmount, data.flashLoanAmount, data.ebusdAmount);

        } else if (data.enterType == EnterType.LEVERDOWN) {
            uint256 troveId = EbisuMathLibrary.calculateTroveId(address(this), data.zapper, data.ownerIndex);
            ILeverageZapper.LeverDownTroveParams memory leverParams = 
                ILeverageZapper.LeverDownTroveParams({
                    troveId: troveId,
                    flashLoanAmount: data.flashLoanAmount,
                    minBoldAmount: data.ebusdAmount
                });

            zapper.leverDownTrove(leverParams);

            emit EbisuZapperFuseLeverDown(data.zapper, data.ownerIndex, data.flashLoanAmount, data.ebusdAmount);

        } else if (data.enterType == EnterType.LEVERUP) {
            uint256 troveId = EbisuMathLibrary.calculateTroveId(address(this), data.zapper, data.ownerIndex);
            ILeverageZapper.LeverUpTroveParams memory leverParams = 
                ILeverageZapper.LeverUpTroveParams({
                    troveId: troveId,
                    flashLoanAmount: data.flashLoanAmount,
                    boldAmount: data.ebusdAmount,
                    maxUpfrontFee: data.maxUpfrontFee
                });

            zapper.leverUpTrove(leverParams);

            emit EbisuZapperFuseLeverUp(data.zapper, data.ownerIndex, data.flashLoanAmount, data.ebusdAmount);
        } else revert UnknownEnterType();
    }

    function exit(EbisuZapperFuseExitData memory data) external {
        ILeverageZapper zapper = ILeverageZapper(data.zapper);

        ERC20 ebusdToken = ERC20(zapper.boldToken());

        uint256 troveId = EbisuMathLibrary.calculateTroveId(address(this), data.zapper, data.ownerIndex);
        
        if (data.exitType == ExitType.ETH){
            ebusdToken.forceApprove(data.zapper, type(uint256).max);
            zapper.closeTroveToRawETH(troveId);
            ebusdToken.forceApprove(data.zapper, 0);
        } else if (data.exitType == ExitType.COLLATERAL) {
            zapper.closeTroveFromCollateral(troveId, data.flashLoanAmount, data.minExpectedCollateral); 
        } else revert UnknownExitType();


        emit EbisuZapperFuseExit(data.zapper, data.ownerIndex);
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

    function _checkUpfrontFeeAndDebt(EbisuZapperFuseEnterData memory data) internal {
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
        uint256 icr = LiquityMath._computeCR(data.collAmount, change.debtIncrease + change.upfrontFee, price);
        if (icr < mcr) {
            revert ICRBelowMCR(icr, mcr);
        }
    }
}