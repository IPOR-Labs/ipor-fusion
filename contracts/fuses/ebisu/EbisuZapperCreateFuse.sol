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
import {EbisuMathLib} from "./lib/EbisuMathLib.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IWethEthAdapter} from "./ext/IWethEthAdapter.sol";
import {WethEthAdapterStorageLib} from "./lib/WethEthAdapterStorageLib.sol";
import {WethEthAdapter} from "./ext/WethEthAdapter.sol";
import {EbisuZapperSubstrateLib, EbisuZapperSubstrate, EbisuZapperSubstrateType} from "./lib/EbisuZapperSubstrateLib.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

struct EbisuZapperCreateFuseEnterData {
    address zapper;
    address registry;
    uint256 collAmount;
    uint256 ebusdAmount;
    uint256 upperHint;
    uint256 lowerHint;
    uint256 flashLoanAmount;
    uint256 annualInterestRate;
    uint256 maxUpfrontFee;
}

struct EbisuZapperCreateFuseExitData {
    address zapper;
    uint256 flashLoanAmount;
    uint256 minExpectedCollateral;
    bool exitFromCollateral;
}

contract EbisuZapperCreateFuse is IFuseCommon {
    using SafeERC20 for IERC20;
    uint256 public immutable MARKET_ID;
    address public immutable WETH;

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
    error UnknownExitType();
    error UpfrontFeeTooHigh(uint256 fee);
    error UnsupportedSubstrate();
    error TroveAlreadyOpen();
    error TroveNotOpen();
    error WethEthAdapterNotFound();
    error WethAddressNotValid();

    event EbisuZapperCreateFuseEnter(
        address zapper,
        uint256 collAmount,
        uint256 flashLoanAmount,
        uint256 ebusdAmount,
        uint256 troveId
    );
    event EbisuZapperCreateFuseExit(address zapper, uint256 ownerIndex);
    event WethEthAdapterCreated(address adapterAddress, address plasmaVault, address weth);

    constructor(uint256 marketId_, address weth_) {
        if(weth_ == address(0)) revert WethAddressNotValid();
        MARKET_ID = marketId_;
        WETH = weth_;
    }

    function enter(EbisuZapperCreateFuseEnterData calldata data_) external {
        // Storage cache
        FuseStorageLib.EbisuTroveIds storage troveData = FuseStorageLib.getEbisuTroveIds();

        // No trove yet for zapper
        if (troveData.troveIds[data_.zapper] != 0) revert TroveAlreadyOpen();

        // Validate targets
        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, 
            EbisuZapperSubstrateLib.substrateToBytes32(
                EbisuZapperSubstrate({
                    substrateType: EbisuZapperSubstrateType.Zapper,
                    substrateAddress: data_.zapper
                })))) revert UnsupportedSubstrate();
        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, 
            EbisuZapperSubstrateLib.substrateToBytes32(
                EbisuZapperSubstrate({
                    substrateType: EbisuZapperSubstrateType.Registry,
                    substrateAddress: data_.registry
                })))) revert UnsupportedSubstrate();

        // Interest bounds
        if (data_.annualInterestRate < MIN_ANNUAL_INTEREST_RATE || data_.annualInterestRate > MAX_ANNUAL_INTEREST_RATE) {
            revert UpfrontFeeTooHigh(data_.annualInterestRate);
        }

        _checkUpfrontFeeAndDebt(data_);

        address adapter = _createAdapterWhenNotExists();

        // Build params
        // Bump the latestOwnerIndex before assigning (pre-increment), so that the first id ever used 1
        uint256 ownerIndex = ++troveData.latestOwnerIndex;
        ILeverageZapper.OpenLeveragedTroveParams memory params = ILeverageZapper.OpenLeveragedTroveParams({
            owner: address(this),
            ownerIndex: ownerIndex,
            collAmount: data_.collAmount,
            flashLoanAmount: data_.flashLoanAmount,
            boldAmount: data_.ebusdAmount,
            upperHint: data_.upperHint,
            lowerHint: data_.lowerHint,
            annualInterestRate: data_.annualInterestRate,
            batchManager: address(0),
            maxUpfrontFee: data_.maxUpfrontFee,
            addManager: address(0),
            removeManager: adapter,
            receiver: adapter
        });

        ILeverageZapper zapper = ILeverageZapper(data_.zapper);

        // Send the gas amount
        IERC20(WETH).safeTransfer(adapter, ETH_GAS_COMPENSATION);

        // Transfer collateral to adapter
        IERC20(zapper.collToken()).safeTransfer(adapter, data_.collAmount);

        // minEthToSpend = ETH_GAS_COMPENSATION by default
        IWethEthAdapter(adapter).callZapperWithEth(
            params,
            data_.zapper,
            ETH_GAS_COMPENSATION
        );

        // Track troveId for this zapper
        uint256 troveId = EbisuMathLib.calculateTroveId(
            adapter,
            address(this),
            data_.zapper,
            ownerIndex
        );
        troveData.troveIds[data_.zapper] = troveId;

        emit EbisuZapperCreateFuseEnter(data_.zapper, data_.collAmount, data_.flashLoanAmount, data_.ebusdAmount, troveId);
    }

    function exit(EbisuZapperCreateFuseExitData calldata data_) external {
        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, 
            EbisuZapperSubstrateLib.substrateToBytes32(
                EbisuZapperSubstrate({
                    substrateType: EbisuZapperSubstrateType.Zapper,
                    substrateAddress: data_.zapper
            })))) revert UnsupportedSubstrate();

        FuseStorageLib.EbisuTroveIds storage troveData = FuseStorageLib.getEbisuTroveIds();

        uint256 troveId = troveData.troveIds[data_.zapper];
        if (troveId == 0) revert TroveNotOpen();

        address adapter = WethEthAdapterStorageLib.getWethEthAdapter();
        if (adapter == address(0)) 
            revert WethEthAdapterNotFound();

        if (!data_.exitFromCollateral){
            IERC20 ebusdToken = IERC20(ILeverageZapper(data_.zapper).boldToken());
            ebusdToken.safeTransfer(adapter, ebusdToken.balanceOf(address(this)));
        }

        IWethEthAdapter(adapter).callZapperExpectEthBack(
            data_.zapper, 
            data_.exitFromCollateral,
            troveId,
            data_.flashLoanAmount,
            data_.minExpectedCollateral);

        delete troveData.troveIds[data_.zapper];

        emit EbisuZapperCreateFuseExit(data_.zapper, troveData.latestOwnerIndex);
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

    function _checkUpfrontFeeAndDebt(EbisuZapperCreateFuseEnterData calldata data_) internal {
        IAddressesRegistry reg = IAddressesRegistry(data_.registry);
        IActivePool activePool = reg.activePool();

        IActivePool.TroveChange memory change;
        change.collIncrease = data_.collAmount;
        change.debtIncrease = data_.ebusdAmount;
        change.newWeightedRecordedDebt = change.debtIncrease * data_.annualInterestRate;

        uint256 avgInterestRate = activePool.getNewApproxAvgInterestRateFromTroveChange(change);
        change.upfrontFee = _calcUpfrontFee(change.debtIncrease, avgInterestRate);
        _requireUserAcceptsUpfrontFee(change.upfrontFee, data_.maxUpfrontFee);

        uint256 newDebt = change.debtIncrease + change.upfrontFee;
        if (newDebt < MIN_DEBT) {
            revert DebtBelowMin(newDebt);
        }

        uint256 mcr = reg.MCR();

        (uint256 price, bool newOracleFailureDetected) = IPriceFeed(reg.priceFeed()).fetchPrice();
        if (newOracleFailureDetected) {
            revert NewOracleFailureDetected();
        }

        uint256 icr = LiquityMath._computeCR(data_.collAmount, newDebt, price);
        if (icr < mcr) {
            revert ICRBelowMCR(icr, mcr);
        }
    }

    /// @notice Creates a new WethEthAdapter and stores its address in storage if it doesn't exist
    function _createAdapterWhenNotExists() internal returns (address adapterAddress) {
        adapterAddress = WethEthAdapterStorageLib.getWethEthAdapter();

        if (adapterAddress == address(0)) {
            adapterAddress = address(new WethEthAdapter(address(this), WETH));
            WethEthAdapterStorageLib.setWethEthAdapter(adapterAddress);
            emit WethEthAdapterCreated(adapterAddress, address(this), WETH);
        }
    }
}
