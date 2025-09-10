// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IZapper} from "./ext/IZapper.sol";
import {ILeverageZapper} from "./ext/ILeverageZapper.sol";
import {IActivePool} from "./ext/IActivePool.sol";
import {IAddressesRegistry} from "./ext/IAddressesRegistry.sol";
import {IPriceFeed} from "./ext/IPriceFeed.sol";
import {LiquityMath} from "./ext/LiquityMath.sol";
import {FuseStorageLib} from "../../libraries/FuseStorageLib.sol";
import {EbisuMathLibrary} from "./EbisuMathLibrary.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

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
    uint256 collAmount;
    uint256 ebusdAmount;
    uint256 upperHint;
    uint256 lowerHint;
    uint256 flashLoanAmount;
    uint256 annualInterestRate;
    uint256 maxUpfrontFee;
    address weth;
    address wethEthAdapter;
    uint256 wethForGas;
}

struct EbisuZapperFuseExitData {
    address zapper;
    uint256 flashLoanAmount;
    uint256 minExpectedCollateral;
    ExitType exitType;
    address weth;
    address wethEthAdapter;
}

contract EbisuZapperFuse is IFuseCommon {
    uint256 public immutable MARKET_ID;

    // from zapper
    uint256 public constant ETH_GAS_COMPENSATION = 0.0375 ether;

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
    error UnsupportedSubstrate();
    error TargetIsNotAContract();
    error TroveAlreadyOpen();
    error TroveNotOpen();

    event EbisuZapperFuseEnter(
        address zapper,
        uint256 collAmount,
        uint256 flashLoanAmount,
        uint256 ebusdAmount,
        uint256 troveId
    );
    event EbisuZapperFuseLeverDown(address zapper, uint256 ownerIndex, uint256 flashLoanAmount, uint256 ebusdAmount);
    event EbisuZapperFuseLeverUp(address zapper, uint256 ownerIndex, uint256 flashLoanAmount, uint256 ebusdAmount);
    event EbisuZapperFuseExit(address zapper, uint256 ownerIndex);

    constructor(uint256 marketId_) {
        MARKET_ID = marketId_;
    }

    function enter(EbisuZapperFuseEnterData calldata data) external {
        // Storage cache
        FuseStorageLib.EbisuTroveIds storage troveData = FuseStorageLib.getEbisuTroveIds();

        // No trove yet for zapper
        if (troveData.troveIds[data.zapper] != 0) revert TroveAlreadyOpen();

        // Validate targets early
        _validateSubstrate(MARKET_ID, data.zapper);
        _validateSubstrate(MARKET_ID, data.registry);
        _validateSubstrate(MARKET_ID, data.wethEthAdapter);

        // Interest bounds
        if (data.annualInterestRate < MIN_ANNUAL_INTEREST_RATE || data.annualInterestRate > MAX_ANNUAL_INTEREST_RATE) {
            revert UpfrontFeeTooHigh(data.annualInterestRate);
        }

        _checkUpfrontFeeAndDebt(data);

        // Build params
        ILeverageZapper.OpenLeveragedTroveParams memory params = ILeverageZapper.OpenLeveragedTroveParams({
            owner: address(this),
            ownerIndex: ++troveData.latestOwnerId,
            collAmount: data.collAmount,
            flashLoanAmount: data.flashLoanAmount,
            boldAmount: data.ebusdAmount,
            upperHint: data.upperHint,
            lowerHint: data.lowerHint,
            annualInterestRate: data.annualInterestRate,
            batchManager: address(0),
            maxUpfrontFee: data.maxUpfrontFee,
            addManager: address(0),
            removeManager: data.wethEthAdapter,
            receiver: data.wethEthAdapter
        });

        // Route through ETH adapter to fund msg.value without the Vault holding ETH
        //  - VAULT approves adapter for data.wethForGas (done here via delegatecall)
        //  - adapter unwraps WETH->ETH and calls zapper.open...{value: ETH}
        require(data.wethEthAdapter != address(0) && data.weth != address(0), "enter: adapter/weth required");
        _validateSubstrate(MARKET_ID, data.wethEthAdapter); // keep duplicate validation to preserve behavior

        ILeverageZapper zapper = ILeverageZapper(data.zapper);

        // Send the gas amount
        IERC20(data.weth).transfer(data.wethEthAdapter, data.wethForGas);

        // Transfer collateral to adapter
        IERC20(zapper.collToken()).transfer(data.wethEthAdapter, data.collAmount);

        // Prepare zapper call
        bytes memory callData =
            abi.encodeWithSelector(ILeverageZapper.openLeveragedTroveWithRawETH.selector, params);

        // minEthToSpend = ETH_GAS_COMPENSATION by default (you can pass data.wethForGas if you want exact match)
        (bool ok, ) = data.wethEthAdapter.call(
            abi.encodeWithSignature(
                "callZapperWithEth(address,bytes,uint256,uint256,uint256)",
                data.zapper,
                callData,
                data.collAmount,
                data.wethForGas,
                ETH_GAS_COMPENSATION
            )
        );
        require(ok, "enter: adapter call failed");

        // Track troveId for this zapper
        uint256 troveId = EbisuMathLibrary.calculateTroveId(
            data.wethEthAdapter,
            address(this),
            data.zapper,
            troveData.latestOwnerId
        );
        troveData.troveIds[data.zapper] = troveId;

        emit EbisuZapperFuseEnter(data.zapper, data.collAmount, data.flashLoanAmount, data.ebusdAmount, troveId);
    }

    function exit(EbisuZapperFuseExitData calldata data) external {
        _validateSubstrate(MARKET_ID, data.zapper);

        FuseStorageLib.EbisuTroveIds storage troveData = FuseStorageLib.getEbisuTroveIds();

        uint256 troveId = troveData.troveIds[data.zapper];
        if (troveId == 0) revert TroveNotOpen();

        ILeverageZapper zapper = ILeverageZapper(data.zapper);
        IERC20 ebusdToken = IERC20(zapper.boldToken());

        // Decide which zapper function to call (only calldata differs)
        bytes4 selector;
        bool isCollateralExit;
        if (data.exitType == ExitType.ETH) {
            selector = IZapper.closeTroveToRawETH.selector;
            isCollateralExit = false;
        } else if (data.exitType == ExitType.COLLATERAL) {
            selector = IZapper.closeTroveFromCollateral.selector;
            isCollateralExit = true;
        } else {
            revert UnknownExitType();
        }

        // The Vault cannot receive ETH. Use adapter to wrap back to WETH and return it.
        require(data.wethEthAdapter != address(0) && data.weth != address(0), "exit: adapter/weth required");
        _validateSubstrate(MARKET_ID, data.wethEthAdapter); // keep validation behavior

        // Build calldata (minimal difference between the two modes)
        bytes memory callData = isCollateralExit
            ? abi.encodeWithSelector(
                selector,
                troveId,
                data.flashLoanAmount,
                data.minExpectedCollateral
            )
            : abi.encodeWithSelector(
                selector,
                troveId
            );

        // Repay from Vault balance via adapter (common path)
        ebusdToken.transfer(data.wethEthAdapter, ebusdToken.balanceOf(address(this)));

        (bool ok, ) = data.wethEthAdapter.call(
            abi.encodeWithSignature("callZapperExpectEthBack(address,bytes)", data.zapper, callData)
        );
        require(ok, "exit: adapter closeToRawETH failed");

        delete troveData.troveIds[data.zapper];

        emit EbisuZapperFuseExit(data.zapper, troveData.latestOwnerId);
    }

    // -------- internal helpers --------

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

    function _checkUpfrontFeeAndDebt(EbisuZapperFuseEnterData calldata data) internal {
        IAddressesRegistry reg = IAddressesRegistry(data.registry);
        IActivePool activePool = reg.activePool();

        IActivePool.TroveChange memory change;
        change.collIncrease = data.collAmount;
        change.debtIncrease = data.ebusdAmount;
        change.newWeightedRecordedDebt = change.debtIncrease * data.annualInterestRate;

        uint256 avgInterestRate = activePool.getNewApproxAvgInterestRateFromTroveChange(change);
        change.upfrontFee = _calcUpfrontFee(change.debtIncrease, avgInterestRate);
        _requireUserAcceptsUpfrontFee(change.upfrontFee, data.maxUpfrontFee);

        uint256 newDebt = change.debtIncrease + change.upfrontFee;
        if (newDebt < MIN_DEBT) {
            revert DebtBelowMin(newDebt);
        }

        uint256 mcr = reg.MCR();

        (uint256 price, bool newOracleFailureDetected) = IPriceFeed(reg.priceFeed()).fetchPrice();
        if (newOracleFailureDetected) {
            revert NewOracleFailureDetected();
        }

        uint256 icr = LiquityMath._computeCR(data.collAmount, newDebt, price);
        if (icr < mcr) {
            revert ICRBelowMCR(icr, mcr);
        }
    }

    function _validateSubstrate(uint256 marketId, address target) internal view {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(marketId, target)) revert UnsupportedSubstrate();
        if (target.code.length == 0) revert TargetIsNotAContract();
    }
}
