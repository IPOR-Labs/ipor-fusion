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
import {IWethEthAdapter} from "./IWethEthAdapter.sol";
import {WethEthAdapterStorageLib} from "./lib/WethEthAdapterStorageLib.sol";
import {WethEthAdapter} from "./WethEthAdapter.sol";
import {EbisuZapperSubstrateLib, EbisuZapperSubstrate, EbisuZapperSubstrateType} from "./lib/EbisuZapperSubstrateLib.sol";

enum ExitType {
    ETH,
    COLLATERAL
}

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
    uint256 wethForGas;
}

struct EbisuZapperCreateFuseExitData {
    address zapper;
    uint256 flashLoanAmount;
    uint256 minExpectedCollateral;
    ExitType exitType;
}

contract EbisuZapperCreateFuse is IFuseCommon {
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
        require(weth_ != address(0), "WETH address invalid");
        MARKET_ID = marketId_;
        WETH = weth_;
    }

    function enter(EbisuZapperCreateFuseEnterData calldata data) external {
        // Storage cache
        FuseStorageLib.EbisuTroveIds storage troveData = FuseStorageLib.getEbisuTroveIds();

        // No trove yet for zapper
        if (troveData.troveIds[data.zapper] != 0) revert TroveAlreadyOpen();

        // Validate targets
        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, 
            EbisuZapperSubstrateLib.substrateToBytes32(
                EbisuZapperSubstrate({
                    substrateType: EbisuZapperSubstrateType.Zapper,
                    substrateAddress: data.zapper
                })))) revert UnsupportedSubstrate();
        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, 
            EbisuZapperSubstrateLib.substrateToBytes32(
                EbisuZapperSubstrate({
                    substrateType: EbisuZapperSubstrateType.Registry,
                    substrateAddress: data.registry
                })))) revert UnsupportedSubstrate();

        // Interest bounds
        if (data.annualInterestRate < MIN_ANNUAL_INTEREST_RATE || data.annualInterestRate > MAX_ANNUAL_INTEREST_RATE) {
            revert UpfrontFeeTooHigh(data.annualInterestRate);
        }

        _checkUpfrontFeeAndDebt(data);

        address adapter = WethEthAdapterStorageLib.getWethEthAdapter();
        if (adapter == address(0)) {
            adapter = _createAdapterWhenNotExists();
        }

        // Build params
        // Bump the latestOwnerId before assigning (pre-increment), so that the first id ever used 1
        uint256 ownerId = ++troveData.latestOwnerId;
        ILeverageZapper.OpenLeveragedTroveParams memory params = ILeverageZapper.OpenLeveragedTroveParams({
            owner: address(this),
            ownerIndex: ownerId,
            collAmount: data.collAmount,
            flashLoanAmount: data.flashLoanAmount,
            boldAmount: data.ebusdAmount,
            upperHint: data.upperHint,
            lowerHint: data.lowerHint,
            annualInterestRate: data.annualInterestRate,
            batchManager: address(0),
            maxUpfrontFee: data.maxUpfrontFee,
            addManager: address(0),
            removeManager: adapter,
            receiver: adapter
        });

        ILeverageZapper zapper = ILeverageZapper(data.zapper);

        // Send the gas amount
        IERC20(WETH).transfer(adapter, data.wethForGas);

        // Transfer collateral to adapter
        IERC20(zapper.collToken()).transfer(adapter, data.collAmount);

        // Prepare zapper call
        bytes memory callData =
            abi.encodeWithSelector(ILeverageZapper.openLeveragedTroveWithRawETH.selector, params);

        // minEthToSpend = ETH_GAS_COMPENSATION by default
        IWethEthAdapter(adapter).callZapperWithEth(
            data.zapper,
            callData,
            data.collAmount,
            data.wethForGas,
            ETH_GAS_COMPENSATION
        );

        // Track troveId for this zapper
        uint256 troveId = EbisuMathLib.calculateTroveId(
            adapter,
            address(this),
            data.zapper,
            ownerId
        );
        troveData.troveIds[data.zapper] = troveId;

        emit EbisuZapperCreateFuseEnter(data.zapper, data.collAmount, data.flashLoanAmount, data.ebusdAmount, troveId);
    }

    function exit(EbisuZapperCreateFuseExitData calldata data) external {
        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, 
            EbisuZapperSubstrateLib.substrateToBytes32(
                EbisuZapperSubstrate({
                    substrateType: EbisuZapperSubstrateType.Zapper,
                    substrateAddress: data.zapper
            })))) revert UnsupportedSubstrate();

        FuseStorageLib.EbisuTroveIds storage troveData = FuseStorageLib.getEbisuTroveIds();

        uint256 troveId = troveData.troveIds[data.zapper];
        if (troveId == 0) revert TroveNotOpen();

        address adapter = WethEthAdapterStorageLib.getWethEthAdapter();
        if (adapter == address(0)) 
            revert WethEthAdapterNotFound();

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
        ebusdToken.transfer(adapter, ebusdToken.balanceOf(address(this)));

        IWethEthAdapter(adapter).callZapperExpectEthBack(data.zapper, callData);

        delete troveData.troveIds[data.zapper];

        emit EbisuZapperCreateFuseExit(data.zapper, troveData.latestOwnerId);
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

    function _checkUpfrontFeeAndDebt(EbisuZapperCreateFuseEnterData calldata data) internal {
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
