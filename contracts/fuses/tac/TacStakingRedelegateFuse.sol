// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TacStakingStorageLib} from "./lib/TacStakingStorageLib.sol";
import {TacValidatorAddressConverter} from "./lib/TacValidatorAddressConverter.sol";
import {TacStakingDelegator} from "./TacStakingDelegator.sol";

/// @title TacStakingRedelegateFuse
/// @notice Fuse for redelegating TAC staking between validators
/// @dev This fuse is used to redelegate TAC from one validator to another

/// @notice Struct to represent the data for redelegate action
/// @dev validatorSrcAddresses - the source validator addresses
/// @dev validatorDstAddresses - the destination validator addresses
/// @dev wTacAmounts - the amounts of TAC to redelegate
struct TacStakingRedelegateFuseEnterData {
    string[] validatorSrcAddresses;
    string[] validatorDstAddresses;
    uint256[] wTacAmounts;
}

contract TacStakingRedelegateFuse is IFuseCommon {
    error TacStakingRedelegateFuseInvalidDelegatorAddress();
    error TacStakingRedelegateFuseSubstrateNotGranted(string validator);
    error TacStakingRedelegateFuseArrayLengthMismatch();

    event TacStakingRedelegateFuseRedelegate(
        address version,
        string[] validatorSrcAddresses,
        string[] validatorDstAddresses,
        uint256[] wTacAmounts
    );

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Redelegate TAC from source validators to destination validators
    /// @param data_ The redelegate data containing source, destination validators and amounts
    function enter(TacStakingRedelegateFuseEnterData memory data_) external {
        uint256 validatorSrcAddressesLength = data_.validatorSrcAddresses.length;

        if (validatorSrcAddressesLength == 0) {
            return;
        }

        if (
            validatorSrcAddressesLength != data_.validatorDstAddresses.length ||
            validatorSrcAddressesLength != data_.wTacAmounts.length
        ) {
            revert TacStakingRedelegateFuseArrayLengthMismatch();
        }

        address payable delegator = payable(TacStakingStorageLib.getTacStakingDelegator());

        if (delegator == address(0)) {
            revert TacStakingRedelegateFuseInvalidDelegatorAddress();
        }

        for (uint256 i; i < validatorSrcAddressesLength; i++) {
            if (!_validateGrantedSubstrate(data_.validatorSrcAddresses[i])) {
                revert TacStakingRedelegateFuseSubstrateNotGranted(data_.validatorSrcAddresses[i]);
            }

            if (!_validateGrantedSubstrate(data_.validatorDstAddresses[i])) {
                revert TacStakingRedelegateFuseSubstrateNotGranted(data_.validatorDstAddresses[i]);
            }
        }

        TacStakingDelegator(delegator).redelegate(
            data_.validatorSrcAddresses,
            data_.validatorDstAddresses,
            data_.wTacAmounts
        );

        emit TacStakingRedelegateFuseRedelegate(
            VERSION,
            data_.validatorSrcAddresses,
            data_.validatorDstAddresses,
            data_.wTacAmounts
        );
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
