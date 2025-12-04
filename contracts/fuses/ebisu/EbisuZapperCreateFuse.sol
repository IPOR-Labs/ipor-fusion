// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

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
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";

/**
 * @notice Data structure to open a new Trove through Ebisu Zapper
 * @dev Contains all parameters required to open a leveraged Trove in the Ebisu protocol
 */
struct EbisuZapperCreateFuseEnterData {
    /// @notice The address of the Ebisu Zapper contract to use for opening the Trove
    address zapper;
    /// @notice The address of the Ebisu AddressesRegistry (must be the one with the same branch as the zapper, as per Ebisu's docs)
    address registry;
    /// @notice The amount of collateral tokens deposited directly by the PlasmaVault (in collateral token decimals)
    uint256 collAmount;
    /// @notice The amount of ebUSD to mint as debt before fees (in ebUSD decimals, typically 18)
    uint256 ebusdAmount;
    /// @notice Upper bound hint given to SortedTroves to facilitate array insertion on Liquity (better values result in gas savings)
    uint256 upperHint;
    /// @notice Lower bound hint given to SortedTroves to facilitate array insertion on Liquity (better values result in gas savings)
    uint256 lowerHint;
    /// @notice The amount of flash loan requested for leverage (0 means no leverage, only direct deposit)
    uint256 flashLoanAmount;
    /// @notice The annual interest rate the Trove owner is willing to pay (scaled by DECIMAL_PRECISION, must be between 0.5% and 250%)
    uint256 annualInterestRate;
    /// @notice The maximum upfront fee the Trove owner is willing to pay (in ebUSD decimals)
    uint256 maxUpfrontFee;
}

/**
 * @notice Data structure to close an open Trove through Ebisu Zapper
 * @dev Contains all parameters required to close a Trove in the Ebisu protocol
 */
struct EbisuZapperCreateFuseExitData {
    /// @notice The address of the Ebisu Zapper contract used to close the Trove
    address zapper;
    /// @notice The amount of flash loan requested to close the Trove (only relevant if exitFromCollateral = true)
    /// @dev When exitFromCollateral is true, this flash loan is used to swap collateral for ebUSD to repay debt
    uint256 flashLoanAmount;
    /// @notice The minimum amount of collateral expected after closure (only relevant if exitFromCollateral = true)
    /// @dev Used as a slippage protection when swapping collateral for ebUSD
    uint256 minExpectedCollateral;
    /// @notice If true, repayment of ebUSD debt is done through a flash loan of collateral tokens swapped for ebUSD
    /// @dev If false, ebUSD debt is repaid directly by PlasmaVault transfer. In both cases, PlasmaVault receives excess collateral.
    ///      When true, PlasmaVault may also receive excess ebUSD after debt repayment.
    bool exitFromCollateral;
}

contract EbisuZapperCreateFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    /// @notice Address of this fuse contract version
    /// @dev Immutable value set in constructor, used for tracking and versioning
    address public immutable VERSION;

    /// @notice Market ID this fuse operates on
    /// @dev Immutable value set in constructor, used to retrieve market substrates
    uint256 public immutable MARKET_ID;

    /// @notice Address of the WETH token contract
    /// @dev Immutable value set in constructor, used for ETH gas compensation
    address public immutable WETH;

    /// @notice ETH gas compensation amount required by Ebisu Zapper
    /// @dev Fixed amount of 0.375 ETH that must be deposited on the Zapper contract
    uint256 public constant ETH_GAS_COMPENSATION = 0.0375 ether;

    /// @notice Minimum allowed annual interest rate (0.5%)
    /// @dev Scaled by DECIMAL_PRECISION (1e18), equals 0.5e16
    uint256 private constant MIN_ANNUAL_INTEREST_RATE = 1e16 / 2;

    /// @notice Maximum allowed annual interest rate (250%)
    /// @dev Scaled by DECIMAL_PRECISION (1e18), equals 250e16
    uint256 private constant MAX_ANNUAL_INTEREST_RATE = 250 * 1e16;

    /// @notice Time period for upfront interest calculation (7 days)
    /// @dev Used to calculate upfront fees based on annual interest rate
    uint256 private constant UPFRONT_INTEREST_PERIOD = 7 days;

    /// @notice Number of seconds in one year (365 days)
    /// @dev Used for interest rate calculations
    uint256 private constant ONE_YEAR = 365 days;

    /// @notice Decimal precision constant (1e18)
    /// @dev Used for scaling interest rates and calculations
    uint256 private constant DECIMAL_PRECISION = 1e18;

    /// @notice Minimum debt amount required to open a Trove (2000 ebUSD)
    /// @dev Prevents opening Troves with debt below this threshold
    uint256 private constant MIN_DEBT = 2000e18;

    /// @notice Thrown when calculated debt is below the minimum required debt
    /// @param debt The calculated debt amount that is below minimum
    /// @custom:error DebtBelowMin
    error DebtBelowMin(uint256 debt);

    /// @notice Thrown when Individual Collateral Ratio (ICR) is below Minimum Collateral Ratio (MCR)
    /// @param icr The calculated ICR value
    /// @param mcr The required MCR value
    /// @custom:error ICRBelowMCR
    error ICRBelowMCR(uint256 icr, uint256 mcr);

    /// @notice Thrown when a new oracle failure is detected during price fetch
    /// @custom:error NewOracleFailureDetected
    error NewOracleFailureDetected();

    /// @notice Thrown when upfront fee exceeds maximum allowed or annual interest rate is out of bounds
    /// @param fee The calculated upfront fee or annual interest rate that exceeds limits
    /// @custom:error UpfrontFeeTooHigh
    error UpfrontFeeTooHigh(uint256 fee);

    /// @notice Thrown when zapper or registry substrate is not granted for the market
    /// @custom:error UnsupportedSubstrate
    error UnsupportedSubstrate();

    /// @notice Thrown when attempting to open a Trove but one is already open for the zapper
    /// @custom:error TroveAlreadyOpen
    error TroveAlreadyOpen();

    /// @notice Thrown when attempting to close a Trove but none is open for the zapper
    /// @custom:error TroveNotOpen
    error TroveNotOpen();

    /// @notice Thrown when WethEthAdapter is not found in storage
    /// @custom:error WethEthAdapterNotFound
    error WethEthAdapterNotFound();

    /// @notice Thrown when WETH address is zero
    /// @custom:error WethAddressNotValid
    error WethAddressNotValid();

    /// @notice Emitted when a new Trove is successfully opened through Ebisu Zapper
    /// @param zapper The address of the zapper used to open the Trove
    /// @param collAmount The amount of collateral deposited directly by the PlasmaVault
    /// @param flashLoanAmount The amount of flash loan used for leverage
    /// @param ebusdAmount The amount of ebUSD minted as debt
    /// @param troveId The unique identifier of the opened Trove
    event EbisuZapperCreateFuseEnter(
        address zapper,
        uint256 collAmount,
        uint256 flashLoanAmount,
        uint256 ebusdAmount,
        uint256 troveId
    );

    /// @notice Emitted when a Trove is successfully closed through Ebisu Zapper
    /// @param zapper The address of the zapper used to close the Trove
    /// @param ownerIndex The owner index associated with the closed Trove
    event EbisuZapperCreateFuseExit(address zapper, uint256 ownerIndex);

    /// @notice Emitted when a new WethEthAdapter is created and stored
    /// @param adapterAddress The address of the newly created adapter
    /// @param plasmaVault The address of the Plasma Vault that owns the adapter
    /// @param weth The address of the WETH token used by the adapter
    event WethEthAdapterCreated(address adapterAddress, address plasmaVault, address weth);

    /**
     * @notice Initializes the EbisuZapperCreateFuse with a market ID and WETH address
     * @param marketId_ The market ID used to identify the Ebisu protocol market substrates
     * @param weth_ The address of the WETH token contract (must not be address(0))
     * @dev Reverts if weth_ is zero address
     */
    constructor(uint256 marketId_, address weth_) {
        if (weth_ == address(0)) revert WethAddressNotValid();
        VERSION = address(this);
        MARKET_ID = marketId_;
        WETH = weth_;
    }

    /**
     * @notice Opens a Liquity (leveraged) Trove through Ebisu's Zapper
     * @dev The Vault deposits collAmount worth of collateral tokens in the Trove.
     *      The remaining part (leverage) is obtained thanks to a flash loan performed by the Zapper.
     *      The result is having a Trove open with collateral collAmount + flashLoanAmount, and debt ebusdAmount + fees.
     *      An amount of 0.375 ETH must be deposited on the Zapper contract, thus we need the WethEthAdapter.
     *      Validates that both zapper and registry are granted as substrates for the market.
     *      Validates annual interest rate is within allowed bounds.
     *      Checks upfront fee, minimum debt, and ICR requirements.
     * @param data_ The data structure containing all parameters for opening the Trove
     * @return zapper The address of the zapper used to open the Trove
     * @return troveId The unique identifier of the opened Trove
     * @custom:revert UnsupportedSubstrate When zapper or registry is not granted as substrate
     * @custom:revert UpfrontFeeTooHigh When annual interest rate is out of bounds or upfront fee exceeds max
     * @custom:revert DebtBelowMin When calculated debt is below minimum required
     * @custom:revert ICRBelowMCR When ICR is below minimum collateral ratio
     * @custom:revert NewOracleFailureDetected When price oracle failure is detected
     * @custom:revert TroveAlreadyOpen When a Trove is already open for this zapper
     */
    function enter(EbisuZapperCreateFuseEnterData memory data_) public returns (address zapper, uint256 troveId) {
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

        ILeverageZapper zapperContract = ILeverageZapper(data_.zapper);

        IERC20(WETH).safeTransfer(adapter, ETH_GAS_COMPENSATION);

        IERC20(zapperContract.collToken()).safeTransfer(adapter, data_.collAmount);

        /// @dev minEthToSpend = ETH_GAS_COMPENSATION by default
        IWethEthAdapter(adapter).openTroveByZapper(params, data_.zapper, ETH_GAS_COMPENSATION);

        troveId = EbisuMathLib.calculateTroveId(adapter, address(this), data_.zapper, ownerIndex);
        troveDataStorage.troveIds[data_.zapper] = troveId;

        emit EbisuZapperCreateFuseEnter(
            data_.zapper,
            data_.collAmount,
            data_.flashLoanAmount,
            data_.ebusdAmount,
            troveId
        );

        return (data_.zapper, troveId);
    }

    /**
     * @notice Transient version of enter function that reads inputs from transient storage
     * @dev Reads all required parameters from transient storage, calls enter function,
     *      and writes outputs back to transient storage
     */
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        EbisuZapperCreateFuseEnterData memory data;
        data.zapper = TypeConversionLib.toAddress(inputs[0]);
        data.registry = TypeConversionLib.toAddress(inputs[1]);
        data.collAmount = TypeConversionLib.toUint256(inputs[2]);
        data.ebusdAmount = TypeConversionLib.toUint256(inputs[3]);
        data.upperHint = TypeConversionLib.toUint256(inputs[4]);
        data.lowerHint = TypeConversionLib.toUint256(inputs[5]);
        data.flashLoanAmount = TypeConversionLib.toUint256(inputs[6]);
        data.annualInterestRate = TypeConversionLib.toUint256(inputs[7]);
        data.maxUpfrontFee = TypeConversionLib.toUint256(inputs[8]);

        (address zapper, uint256 troveId) = enter(data);

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(zapper);
        outputs[1] = TypeConversionLib.toBytes32(troveId);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /**
     * @notice Closes a Liquity (leveraged) Trove through Ebisu's Zapper
     * @dev If exitFromCollateral = true, ebUSD debt is repaid by requesting a flash loan of collateral tokens
     *      and swapping them for ebUSD. If exitFromCollateral = false, ebUSD debt is repaid by a direct transfer
     *      by the PlasmaVault. In both cases, the PlasmaVault receives the excess collateral tokens.
     *      In the case exitFromCollateral = true, the PlasmaVault may receive excess ebUSD too.
     *      Validates that zapper is granted as substrate for the market.
     * @param data_ The data structure containing all parameters for closing the Trove
     * @return zapper The address of the zapper used to close the Trove
     * @return ownerIndex The owner index associated with the closed Trove
     * @custom:revert UnsupportedSubstrate When zapper is not granted as substrate
     * @custom:revert TroveNotOpen When no Trove is open for this zapper
     * @custom:revert WethEthAdapterNotFound When WethEthAdapter is not found in storage
     */
    function exit(EbisuZapperCreateFuseExitData memory data_) public returns (address zapper, uint256 ownerIndex) {
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

        return (data_.zapper, troveDataStorage.latestOwnerIndex);
    }

    /**
     * @notice Transient version of exit function that reads inputs from transient storage
     * @dev Reads all required parameters from transient storage, calls exit function,
     *      and writes outputs back to transient storage
     */
    function exitTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        EbisuZapperCreateFuseExitData memory data;
        data.zapper = TypeConversionLib.toAddress(inputs[0]);
        data.flashLoanAmount = TypeConversionLib.toUint256(inputs[1]);
        data.minExpectedCollateral = TypeConversionLib.toUint256(inputs[2]);
        data.exitFromCollateral = TypeConversionLib.toBool(inputs[3]);

        (address zapper, uint256 ownerIndex) = exit(data);

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(zapper);
        outputs[1] = TypeConversionLib.toBytes32(ownerIndex);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    // -------- internal helpers --------

    /**
     * @notice Calculates the upfront fee for a given debt and average interest rate
     * @dev The upfront fee is calculated based on the debt amount, average interest rate,
     *      and a fixed upfront interest period (7 days)
     * @param debt_ The debt amount for which to calculate the upfront fee
     * @param avgInterestRate_ The average interest rate (scaled by DECIMAL_PRECISION)
     * @return The calculated upfront fee amount
     */
    function _calcUpfrontFee(uint256 debt_, uint256 avgInterestRate_) internal pure returns (uint256) {
        return _calcInterest(debt_ * avgInterestRate_, UPFRONT_INTEREST_PERIOD);
    }

    /**
     * @notice Calculates interest for a weighted debt over a specific period
     * @dev Interest is calculated as: (weightedDebt * period) / ONE_YEAR / DECIMAL_PRECISION
     * @param weightedDebt_ The weighted debt amount (debt * interest rate)
     * @param period_ The time period for interest calculation (in seconds)
     * @return The calculated interest amount
     */
    function _calcInterest(uint256 weightedDebt_, uint256 period_) internal pure returns (uint256) {
        return (weightedDebt_ * period_) / ONE_YEAR / DECIMAL_PRECISION;
    }

    /**
     * @notice Validates that the calculated upfront fee does not exceed the maximum allowed fee
     * @param fee_ The calculated upfront fee
     * @param maxFee_ The maximum upfront fee the user is willing to pay
     * @custom:revert UpfrontFeeTooHigh When the calculated fee exceeds the maximum allowed fee
     */
    function _requireUserAcceptsUpfrontFee(uint256 fee_, uint256 maxFee_) internal pure {
        if (fee_ > maxFee_) {
            revert UpfrontFeeTooHigh(fee_);
        }
    }

    /**
     * @notice Validates upfront fee, minimum debt, and ICR requirements before opening a Trove
     * @dev This function performs comprehensive validation:
     *      1. Calculates the average interest rate from the Trove change
     *      2. Calculates and validates the upfront fee
     *      3. Validates that the total debt (debt + upfront fee) meets minimum debt requirement
     *      4. Validates that the ICR (Individual Collateral Ratio) meets the MCR (Minimum Collateral Ratio)
     *      5. Checks for oracle failure
     * @param data_ The data structure containing Trove opening parameters
     * @custom:revert UpfrontFeeTooHigh When upfront fee exceeds maximum allowed or interest rate is invalid
     * @custom:revert DebtBelowMin When calculated debt is below minimum required (2000e18)
     * @custom:revert ICRBelowMCR When ICR is below minimum collateral ratio
     * @custom:revert NewOracleFailureDetected When price oracle failure is detected
     */
    function _checkUpfrontFeeAndDebt(EbisuZapperCreateFuseEnterData memory data_) internal {
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

    /**
     * @notice Creates a new WethEthAdapter and stores its address in storage if it doesn't exist
     * @dev Checks if a WethEthAdapter already exists in storage. If not, creates a new instance
     *      and stores its address. Emits WethEthAdapterCreated event when a new adapter is created.
     * @return adapterAddress The address of the WethEthAdapter (existing or newly created)
     */
    function _createAdapterWhenNotExists() internal returns (address adapterAddress) {
        adapterAddress = WethEthAdapterStorageLib.getWethEthAdapter();

        if (adapterAddress == address(0)) {
            adapterAddress = address(new WethEthAdapter(address(this), WETH));
            WethEthAdapterStorageLib.setWethEthAdapter(adapterAddress);
            emit WethEthAdapterCreated(adapterAddress, address(this), WETH);
        }
    }
}
