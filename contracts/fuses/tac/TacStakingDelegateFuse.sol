// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IFuseCommon} from "../IFuseCommon.sol";
import {IFuseInstantWithdraw} from "../IFuseInstantWithdraw.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {TacStakingDelegator} from "./TacStakingDelegator.sol";
import {TacStakingStorageLib} from "./lib/TacStakingStorageLib.sol";
import {TacValidatorAddressConverter} from "./lib/TacValidatorAddressConverter.sol";

/// @notice Struct to represent the data for entering the fuse - delegate action
/// @dev validatorAddresses - the validator addresses
/// @dev wTacAmounts - the amounts of TAC to delegate
struct TacStakingDelegateFuseEnterData {
    string[] validatorAddresses;
    uint256[] wTacAmounts;
}

/// @notice Struct to represent the data for exiting the fuse - undelegate action
/// @dev validatorAddresses - the array of validator addresses
/// @dev wTacAmounts - the array of amounts of wTAC to unstake
struct TacStakingDelegateFuseExitData {
    string[] validatorAddresses;
    uint256[] tacAmounts;
}

contract TacStakingDelegateFuse is IFuseCommon, IFuseInstantWithdraw {
    using SafeERC20 for IERC20;

    error TacStakingFuseInvalidDelegatorAddress();
    error TacStakingFuseSubstrateNotGranted(string validator);
    error TacStakingFuseArrayLengthMismatch();
    error TacStakingFuseEmptyArray();
    error TacStakingFuseInsufficientBalance();

    event TacStakingDelegateFuseEnter(address version, string[] validatorAddresses, uint256[] wTacAmounts);
    event TacStakingDelegateFuseExit(address version, string[] validatorAddresses, uint256[] tacAmounts);

    event TacStakingFuseInstantWithdraw(address version, uint256 amount);
    event TacStakingDelegatorCreated(address delegator, address plasmaVault, address wTAC, address staking);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address public immutable W_TAC;
    address public immutable STAKING;

    constructor(uint256 marketId_, address wTAC_, address staking_) {
        if (wTAC_ == address(0)) {
            revert TacStakingFuseInvalidDelegatorAddress();
        }
        if (staking_ == address(0)) {
            revert TacStakingFuseInvalidDelegatorAddress();
        }

        VERSION = address(this);
        MARKET_ID = marketId_;
        W_TAC = wTAC_;
        STAKING = staking_;
    }

    /// @notice Delegate the balance of the delegator to the validators
    /// @dev Only callable by the PlasmaVault contract
    function enter(TacStakingDelegateFuseEnterData calldata data_) external {
        uint256 validatorAddressesLength = data_.validatorAddresses.length;

        if (validatorAddressesLength == 0) {
            revert TacStakingFuseEmptyArray();
        }

        if (validatorAddressesLength != data_.wTacAmounts.length) {
            revert TacStakingFuseArrayLengthMismatch();
        }

        address delegator = TacStakingStorageLib.getTacStakingDelegator();

        if (delegator == address(0)) {
            delegator = _createDelegatorWhenNotExists();
        }

        uint256 totalWTacAmount = 0;

        for (uint256 i; i < validatorAddressesLength; i++) {
            if (!_validateGrantedSubstrate(data_.validatorAddresses[i])) {
                revert TacStakingFuseSubstrateNotGranted(data_.validatorAddresses[i]);
            }

            totalWTacAmount += data_.wTacAmounts[i];
        }

        if (totalWTacAmount == 0) {
            return;
        }

        if (totalWTacAmount > IERC20(W_TAC).balanceOf(address(this))) {
            revert TacStakingFuseInsufficientBalance();
        } else {
            IERC20(W_TAC).safeTransfer(delegator, totalWTacAmount);
        }

        TacStakingDelegator(payable(delegator)).delegate(data_.validatorAddresses, data_.wTacAmounts);

        emit TacStakingDelegateFuseEnter(VERSION, data_.validatorAddresses, data_.wTacAmounts);
    }

    function exit(TacStakingDelegateFuseExitData memory data_) external {
        uint256 validatorAddressesLength = data_.validatorAddresses.length;

        if (validatorAddressesLength == 0) {
            revert TacStakingFuseEmptyArray();
        }

        if (validatorAddressesLength != data_.tacAmounts.length) {
            revert TacStakingFuseArrayLengthMismatch();
        }

        address delegator = TacStakingStorageLib.getTacStakingDelegator();

        if (delegator == address(0)) {
            revert TacStakingFuseInvalidDelegatorAddress();
        }

        for (uint256 i; i < validatorAddressesLength; i++) {
            if (!_validateGrantedSubstrate(data_.validatorAddresses[i])) {
                revert TacStakingFuseSubstrateNotGranted(data_.validatorAddresses[i]);
            }
        }

        TacStakingDelegator(payable(delegator)).undelegate(data_.validatorAddresses, data_.tacAmounts);

        emit TacStakingDelegateFuseExit(VERSION, data_.validatorAddresses, data_.tacAmounts);
    }

    /// @notice Handle instant withdrawals
    /// @dev params[0] - amount in wTAC, params[1] - validator hash (bytes32)
    /// @param params_ Array of parameters for withdrawal
    /// @dev Intant withdraw can be done only from TacStakingDelegator
    function instantWithdraw(bytes32[] calldata params_) external override {
        uint256 wTacAmount = uint256(params_[0]);

        if (wTacAmount == 0) {
            return;
        }

        address delegator = TacStakingStorageLib.getTacStakingDelegator();

        if (delegator == address(0)) {
            revert TacStakingFuseInvalidDelegatorAddress();
        }

        uint256 withdrawnAmount = TacStakingDelegator(payable(delegator)).instantWithdraw(wTacAmount);

        emit TacStakingFuseInstantWithdraw(VERSION, withdrawnAmount);
    }

    /// @notice Creates a new TacStakingDelegator and stores its address in storage if it doesn't exist
    function _createDelegatorWhenNotExists() internal returns (address delegatorAddress) {
        delegatorAddress = TacStakingStorageLib.getTacStakingDelegator();

        if (delegatorAddress == address(0)) {
            delegatorAddress = address(new TacStakingDelegator(address(this), W_TAC, STAKING));
            TacStakingStorageLib.setTacStakingDelegator(delegatorAddress);
            emit TacStakingDelegatorCreated(delegatorAddress, address(this), W_TAC, STAKING);
        }
    }

    /// @notice Validates that a validator address is granted as a substrate for the market
    /// @dev Converts validator address string to two bytes32 values and checks if both are granted
    /// @param validatorAddress_ The validator address string to validate
    /// @return True if validator is granted as substrate, false otherwise
    function _validateGrantedSubstrate(string memory validatorAddress_) private view returns (bool) {
        (bytes32 firstSlot, bytes32 secondSlot) = TacValidatorAddressConverter.validatorAddressToBytes32(
            validatorAddress_
        );

        return
            PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, firstSlot) &&
            PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, secondSlot);
    }
}
