// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {ILeverageZapper} from "./ext/ILeverageZapper.sol";
import {IActivePool} from "./ext/IActivePool.sol";
import {IAddressesRegistry} from "./ext/IAddressesRegistry.sol";
import {IPriceFeed} from "./ext/IPriceFeed.sol";
import {LiquityMath} from "./ext/LiquityMath.sol";
import {FuseStorageLib} from "../../libraries/FuseStorageLib.sol";
import {EbisuMathLib} from "./lib/EbisuMathLib.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IWethEthAdapter} from "./IWethEthAdapter.sol";
import {WethEthAdapterStorageLib} from "./lib/WethEthAdapterStorageLib.sol";
import {WethEthAdapter} from "./WethEthAdapter.sol";
import {EbisuZapperSubstrateLib, EbisuZapperSubstrate, EbisuZapperSubstrateType} from "./lib/EbisuZapperSubstrateLib.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Data to open a new Trove through Zapper
/// @param zapper the zapper address
/// @param registry the registry address (must be the one with the same branch as the zapper, as per Ebisu's docs)
/// @param collAmount the amount of collateral deposited directly by the PlasmaVault
/// @param ebusdAmount the amount of ebUSD to mint as debt (before fees)
/// @param upperHint upper bound given to SortedTroves to facilitate array insertion on Liquity (better values -> gas saving)
/// @param lowerHint lower bound given to SortedTroves to facilitate array insertion on Liquity (better values -> gas saving)
/// @param flashLoanAmount the amount of flash loan requested for the leverage (0 amount -> no leverage)
/// @param annualInterestRate the annual interest rate the Trove owner is willing to pay
/// @param maxUpfrontFee the maximum upfront fee the Trove owner is willing to pay
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

/// @notice Data to close an open Trove through Zapper
/// @param zapper the zapper address
/// @param flashLoanAmount the amount of flash loan requested to close the Trove (relevant only if exitFromCollateral = true)
/// @param minExpectedCollateral the minimum amount of collateral expected after closure (relevant only if exitFromCollateral = true)
/// @param exitFromCollateral if this is true, repayment of ebUSD debt is done through a flash loan, otherwise it is done directly by PlasmaVault
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
        if (weth_ == address(0)) revert WethAddressNotValid();
        MARKET_ID = marketId_;
        WETH = weth_;
    }

    /// @notice opening a Liquity (leveraged) Trove through Ebisu's Zapper
    /// The Vault deposits collAmount worth of collateral tokens in the Trove
    /// The remaining part (leverage) is obtained thanks to a flash loan performed by the Zapper
    /// The result is having a Trove open with collateral collAmount + flashLoanAmount, and debt ebusdAmount + fees
    /// An amount of 0.375 ETH must be deposited on the Zapper contract, thus we need the WethEthAdapter
    function enter(EbisuZapperCreateFuseEnterData calldata data_) external {
        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                EbisuZapperSubstrateLib.substrateToBytes32(
                    EbisuZapperSubstrate({
                        substrateType: EbisuZapperSubstrateType.ZAPPER,
                        substrateAddress: data_.zapper
                    })
                )
            )
        ) revert UnsupportedSubstrate();
        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                EbisuZapperSubstrateLib.substrateToBytes32(
                    EbisuZapperSubstrate({
                        substrateType: EbisuZapperSubstrateType.REGISTRY,
                        substrateAddress: data_.registry
                    })
                )
            )
        ) revert UnsupportedSubstrate();

        if (
            data_.annualInterestRate < MIN_ANNUAL_INTEREST_RATE || data_.annualInterestRate > MAX_ANNUAL_INTEREST_RATE
        ) {
            revert UpfrontFeeTooHigh(data_.annualInterestRate);
        }

        _checkUpfrontFeeAndDebt(data_);

        address adapter = _createAdapterWhenNotExists();

        FuseStorageLib.EbisuTroveIds storage troveDataStorage = FuseStorageLib.getEbisuTroveIds();

        if (troveDataStorage.troveIds[data_.zapper] != 0) revert TroveAlreadyOpen();

        uint256 ownerIndex = ++troveDataStorage.latestOwnerIndex;
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

        IERC20(WETH).safeTransfer(adapter, ETH_GAS_COMPENSATION);

        IERC20(zapper.collToken()).safeTransfer(adapter, data_.collAmount);

        /// @dev minEthToSpend = ETH_GAS_COMPENSATION by default
        IWethEthAdapter(adapter).openTroveByZapper(params, data_.zapper, ETH_GAS_COMPENSATION);

        uint256 troveId = EbisuMathLib.calculateTroveId(adapter, address(this), data_.zapper, ownerIndex);
        troveDataStorage.troveIds[data_.zapper] = troveId;

        emit EbisuZapperCreateFuseEnter(
            data_.zapper,
            data_.collAmount,
            data_.flashLoanAmount,
            data_.ebusdAmount,
            troveId
        );
    }

    /// @notice closing a Liquity (leveraged) Trove through Ebisu's Zapper
    /// If exitFromCollateral = true, ebUSD debt is repaid by requesting a flash loan of collateral tokens and swapping them for ebUSD
    /// If exitFromCollateral = false, ebUSD debt is repaid by a direct transfer by the PlasmaVault
    /// In both cases, the PlasmaVault receives the excess collateral tokens
    /// In the case exitFromCollateral = true, the PlasmaVault may receive excess ebUSD too.
    function exit(EbisuZapperCreateFuseExitData calldata data_) external {
        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                EbisuZapperSubstrateLib.substrateToBytes32(
                    EbisuZapperSubstrate({
                        substrateType: EbisuZapperSubstrateType.ZAPPER,
                        substrateAddress: data_.zapper
                    })
                )
            )
        ) revert UnsupportedSubstrate();

        FuseStorageLib.EbisuTroveIds storage troveDataStorage = FuseStorageLib.getEbisuTroveIds();

        uint256 troveId = troveDataStorage.troveIds[data_.zapper];
        if (troveId == 0) revert TroveNotOpen();

        address adapter = WethEthAdapterStorageLib.getWethEthAdapter();
        if (adapter == address(0)) revert WethEthAdapterNotFound();

        if (!data_.exitFromCollateral) {
            IERC20 ebusdToken = IERC20(ILeverageZapper(data_.zapper).boldToken());
            ebusdToken.safeTransfer(adapter, ebusdToken.balanceOf(address(this)));
        }

        IWethEthAdapter(adapter).closeTroveByZapper(
            data_.zapper,
            data_.exitFromCollateral,
            troveId,
            data_.flashLoanAmount,
            data_.minExpectedCollateral
        );

        delete troveDataStorage.troveIds[data_.zapper];

        emit EbisuZapperCreateFuseExit(data_.zapper, troveDataStorage.latestOwnerIndex);
    }

    // -------- internal helpers --------

    function _calcUpfrontFee(uint256 debt_, uint256 avgInterestRate_) internal pure returns (uint256) {
        return _calcInterest(debt_ * avgInterestRate_, UPFRONT_INTEREST_PERIOD);
    }

    function _calcInterest(uint256 weightedDebt_, uint256 period_) internal pure returns (uint256) {
        return (weightedDebt_ * period_) / ONE_YEAR / DECIMAL_PRECISION;
    }

    function _requireUserAcceptsUpfrontFee(uint256 fee_, uint256 maxFee_) internal pure {
        if (fee_ > maxFee_) {
            revert UpfrontFeeTooHigh(fee_);
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

        uint256 icr = LiquityMath.computeCR(data_.collAmount, newDebt, price);
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
