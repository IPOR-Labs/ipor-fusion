// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStaking} from "./ext/IStaking.sol";
import {IwTAC} from "./ext/IwTAC.sol";

/// @title TacStakingDelegator
/// @notice Delegator for TAC staking operations on behalf of the PlasmaVault
/// @dev Handles delegation, redelegation, undelegation, instant withdrawals, and emergency exit
/// @dev Only callable by the PlasmaVault contract
/// @dev Allows the contract to receive native TAC tokens
contract TacStakingDelegator {
    using Address for address;
    using SafeERC20 for IERC20;

    error TacStakingDelegatorInvalidWtacAddress();
    error TacStakingDelegatorInvalidStakingAddress();
    error TacStakingDelegatorInvalidArrayLength();
    error TacStakingDelegatorInvalidTargetAddress();
    error TacStakingDelegatorInsufficientBalance();
    error TacStakingDelegatorInvalidPlasmaVaultAddress();

    event TacStakingDelegatorDelegate(address plasmaVault, string validatorAddress, uint256 amount);
    event TacStakingDelegatorRedelegate(
        address plasmaVault,
        string validatorSrcAddress,
        string validatorDstAddress,
        uint256 amount,
        int64 completionTime
    );
    event TacStakingDelegatorUndelegate(
        address plasmaVault,
        string validatorAddress,
        uint256 amount,
        int64 completionTime
    );
    event TacStakingDelegatorInstantWithdraw(address plasmaVault, uint256 amount);
    event TacStakingDelegatorExit(address plasmaVault, uint256 amount);
    event TacStakingDelegatorBatchExecute(address plasmaVault, address[] targets, bytes[] calldatas);

    address public immutable W_TAC;
    address public immutable STAKING;
    address public immutable PLASMA_VAULT;

    modifier onlyPlasmaVault() {
        if (msg.sender != PLASMA_VAULT) {
            revert TacStakingDelegatorInvalidPlasmaVaultAddress();
        }
        _;
    }

    constructor(address plasmaVault_, address wTAC_, address staking_) {
        if (plasmaVault_ == address(0)) {
            revert TacStakingDelegatorInvalidPlasmaVaultAddress();
        }

        /// @dev Only PlasmaVault can create the Delegator
        if (plasmaVault_ != msg.sender) {
            revert TacStakingDelegatorInvalidPlasmaVaultAddress();
        }

        if (wTAC_ == address(0)) {
            revert TacStakingDelegatorInvalidWtacAddress();
        }

        if (staking_ == address(0)) {
            revert TacStakingDelegatorInvalidStakingAddress();
        }

        PLASMA_VAULT = plasmaVault_;
        W_TAC = wTAC_;
        STAKING = staking_;
    }

    function delegate(string[] calldata validatorAddresses_, uint256[] calldata wTacAmounts_) external onlyPlasmaVault {
        uint256 validatorAddressesLength = validatorAddresses_.length;

        if (validatorAddressesLength == 0) {
            return;
        }

        if (validatorAddressesLength != wTacAmounts_.length) {
            revert TacStakingDelegatorInvalidArrayLength();
        }

        uint256 totalWTacAmount = 0;

        for (uint256 i; i < validatorAddressesLength; i++) {
            totalWTacAmount += wTacAmounts_[i];
        }

        address delegator = address(this);

        uint256 delegatorBalance = IERC20(W_TAC).balanceOf(delegator);

        if (totalWTacAmount > delegatorBalance) {
            revert TacStakingDelegatorInsufficientBalance();
        }

        /// @dev get native TAC from wTAC
        IwTAC(W_TAC).withdraw(totalWTacAmount);

        for (uint256 i; i < validatorAddressesLength; i++) {
            if (wTacAmounts_[i] == 0) {
                continue;
            }

            IStaking(STAKING).delegate(delegator, validatorAddresses_[i], wTacAmounts_[i]);

            emit TacStakingDelegatorDelegate(PLASMA_VAULT, validatorAddresses_[i], wTacAmounts_[i]);
        }

        _transferRemainingBalance();
    }

    function undelegate(
        string[] calldata validatorAddresses_,
        uint256[] calldata tacAmounts_
    ) external onlyPlasmaVault {
        uint256 validatorAddressesLength = validatorAddresses_.length;

        if (validatorAddressesLength == 0) {
            return;
        }

        if (validatorAddressesLength != tacAmounts_.length) {
            revert TacStakingDelegatorInvalidArrayLength();
        }

        for (uint256 i; i < validatorAddressesLength; i++) {
            if (tacAmounts_[i] == 0) {
                continue;
            }

            int64 completionTime = IStaking(STAKING).undelegate(address(this), validatorAddresses_[i], tacAmounts_[i]);

            emit TacStakingDelegatorUndelegate(PLASMA_VAULT, validatorAddresses_[i], tacAmounts_[i], completionTime);
        }

        _transferRemainingBalance();
    }

    function redelegate(
        string[] calldata validatorSrcAddresses_,
        string[] calldata validatorDstAddresses_,
        uint256[] calldata tacAmounts_
    ) external onlyPlasmaVault {
        uint256 validatorSrcAddressesLength = validatorSrcAddresses_.length;

        if (validatorSrcAddressesLength == 0) {
            return;
        }

        if (
            validatorSrcAddressesLength != validatorDstAddresses_.length ||
            validatorSrcAddressesLength != tacAmounts_.length
        ) {
            revert TacStakingDelegatorInvalidArrayLength();
        }

        for (uint256 i; i < validatorSrcAddressesLength; i++) {
            if (tacAmounts_[i] == 0) {
                continue;
            }

            int64 completionTime = IStaking(STAKING).redelegate(
                address(this),
                validatorSrcAddresses_[i],
                validatorDstAddresses_[i],
                tacAmounts_[i]
            );

            emit TacStakingDelegatorRedelegate(
                PLASMA_VAULT,
                validatorSrcAddresses_[i],
                validatorDstAddresses_[i],
                tacAmounts_[i],
                completionTime
            );
        }

        _transferRemainingBalance();
    }

    function instantWithdraw(uint256 wTacAmount_) external onlyPlasmaVault returns (uint256 withdrawnAmount_) {
        if (wTacAmount_ == 0) {
            return 0;
        }

        uint256 wTacBalance = IERC20(W_TAC).balanceOf(address(this));

        uint256 fromWTac = wTacAmount_ <= wTacBalance ? wTacAmount_ : wTacBalance;

        uint256 remainingNeeded = wTacAmount_ - fromWTac;

        uint256 nativeBalance = address(this).balance;

        uint256 fromNative = remainingNeeded <= nativeBalance ? remainingNeeded : nativeBalance;

        uint256 totalWithdrawable = fromWTac + fromNative;

        if (totalWithdrawable == 0) {
            return 0;
        }

        if (fromNative > 0) {
            IwTAC(W_TAC).deposit{value: fromNative}();
        }

        IERC20(W_TAC).safeTransfer(PLASMA_VAULT, totalWithdrawable);

        withdrawnAmount_ = totalWithdrawable;

        emit TacStakingDelegatorInstantWithdraw(PLASMA_VAULT, withdrawnAmount_);
    }

    function emergencyExit() external onlyPlasmaVault {
        uint256 nativeBalance = address(this).balance;

        if (nativeBalance > 0) {
            IwTAC(W_TAC).deposit{value: nativeBalance}();
        }

        uint256 totalWTacBalance = IERC20(W_TAC).balanceOf(address(this));

        if (totalWTacBalance > 0) {
            IERC20(W_TAC).safeTransfer(PLASMA_VAULT, totalWTacBalance);
        }

        emit TacStakingDelegatorExit(PLASMA_VAULT, totalWTacBalance);
    }

    /// @notice Execute batch of calls as the delegator
    /// @param targets Array of target addresses to call
    /// @param calldatas Array of calldata to execute
    /// @return results Array of return data from each call
    /// @dev Restriction: only for emergency actions can be executed only by PlasmaVault
    function executeBatch(
        address[] calldata targets,
        bytes[] calldata calldatas
    ) external onlyPlasmaVault returns (bytes[] memory results) {
        uint256 targetsLength = targets.length;

        if (targetsLength != calldatas.length) {
            revert TacStakingDelegatorInvalidArrayLength();
        }

        results = new bytes[](targetsLength);

        for (uint256 i; i < targetsLength; i++) {
            if (targets[i] == address(0)) {
                revert TacStakingDelegatorInvalidTargetAddress();
            }

            results[i] = targets[i].functionDelegateCall(calldatas[i]);
        }

        emit TacStakingDelegatorBatchExecute(PLASMA_VAULT, targets, calldatas);
    }

    function _transferRemainingBalance() internal {
        uint256 remainingBalance = address(this).balance;

        if (remainingBalance > 0) {
            IwTAC(W_TAC).deposit{value: remainingBalance}();
            IERC20(W_TAC).safeTransfer(PLASMA_VAULT, remainingBalance);
        }
    }

    /// @notice Allows the contract to receive native token
    receive() external payable {}
}
