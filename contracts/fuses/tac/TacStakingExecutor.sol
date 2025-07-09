// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStaking} from "./ext/IStaking.sol";
import {IwTAC} from "./ext/IwTAC.sol";

/// @notice Data structure for delegate operation
/// @param validatorAddress The address of the validator to delegate to
/// @param wTacAmount The amount of wTAC to delegate
struct StakingExecutorTacDelegateData {
    string[] validatorAddresses;
    uint256[] wTacAmounts;
}

/// @notice Data structure for redelegate operation
/// @param validatorSrcAddress The address of the validator to redelegate from
/// @param validatorDstAddress The address of the validator to redelegate to
/// @param wTacAmount The amount of wTAC to redelegate
struct StakingExecutorTacRedelegateData {
    string validatorSrcAddress;
    string validatorDstAddress;
    uint256 wTacAmount;
}

/// @notice Data structure for undelegate operation
/// @param validatorAddress The address of the validator to undelegate from
/// @param wTacAmount The amount of wTAC to undelegate
// struct StakingExecutorTacUndelegateData {
//     string[] validatorAddresses;
//     uint256[] wTacAmounts;
// }

/// @title TacStakingExecutor
/// @notice Executor for TAC staking operations in Plasma Vault
/// @dev Handles delegation, redelegation, undelegation, instant withdrawals, and emergency exit
/// @dev Allows the contract to receive native TAC tokens
/// @dev Only callable by the PlasmaVault contract
contract TacStakingExecutor {
    using Address for address;
    using SafeERC20 for IERC20;

    error StakingExecutorTacInvalidTacAddress();
    error StakingExecutorTacInvalidStakingAddress();
    error StakingExecutorTacInvalidArrayLength();
    error StakingExecutorTacInvalidTargetAddress();
    error StakingExecutorTacInsufficientBalance();

    event TacStakingExecutorDelegate(address plasmaVault, string validatorAddress, uint256 amount);
    event TacStakingExecutorRedelegate(
        address plasmaVault,
        string validatorSrcAddress,
        string validatorDstAddress,
        uint256 amount,
        int64 completionTime
    );
    event TacStakingExecutorUndelegate(
        address plasmaVault,
        string validatorAddress,
        uint256 amount,
        int64 completionTime
    );
    event TacStakingExecutorInstantWithdraw(address plasmaVault, uint256 amount);
    event TacStakingExecutorExit(address plasmaVault, uint256 amount);
    event TacStakingExecutorBatchExecute(address plasmaVault, address[] targets, bytes[] calldatas);

    address public immutable W_TAC;
    address public immutable STAKING;
    address public immutable PLASMA_VAULT;

    error StakingExecutorTacInvalidPlasmaVaultAddress();

    modifier onlyPlasmaVault() {
        if (msg.sender != PLASMA_VAULT) {
            revert StakingExecutorTacInvalidPlasmaVaultAddress();
        }
        _;
    }

    constructor(address plasmaVault_, address wTAC_, address staking_) {
        if (plasmaVault_ == address(0)) {
            revert StakingExecutorTacInvalidPlasmaVaultAddress();
        }

        if (wTAC_ == address(0)) {
            revert StakingExecutorTacInvalidTacAddress();
        }

        if (staking_ == address(0)) {
            revert StakingExecutorTacInvalidStakingAddress();
        }

        PLASMA_VAULT = plasmaVault_;
        W_TAC = wTAC_;
        STAKING = staking_;
    }

    function delegate(string[] calldata validatorAddresses_, uint256[] calldata wTacAmounts_) external onlyPlasmaVault {
        if (validatorAddresses_.length == 0) {
            return;
        }

        if (validatorAddresses_.length != wTacAmounts_.length) {
            revert StakingExecutorTacInvalidArrayLength();
        }

        uint256 totalWTacAmount = 0;

        for (uint256 i; i < wTacAmounts_.length; i++) {
            totalWTacAmount += wTacAmounts_[i];
        }

        address delegator = address(this);

        uint256 executorBalance = IERC20(W_TAC).balanceOf(delegator);

        if (totalWTacAmount > executorBalance) {
            revert StakingExecutorTacInsufficientBalance();
        }

        /// @dev get native TAC from wTAC
        IwTAC(W_TAC).withdraw(totalWTacAmount);

        for (uint256 i; i < validatorAddresses_.length; i++) {
            if (wTacAmounts_[i] == 0) {
                continue;
            }

            IStaking(STAKING).delegate(delegator, validatorAddresses_[i], wTacAmounts_[i]);

            emit TacStakingExecutorDelegate(PLASMA_VAULT, validatorAddresses_[i], wTacAmounts_[i]);
        }

        _transferRemainingBalance();
    }

    function undelegate(
        string[] calldata validatorAddresses_,
        uint256[] calldata wTacAmounts_
    ) external onlyPlasmaVault {
        if (validatorAddresses_.length == 0) {
            return;
        }

        if (validatorAddresses_.length != wTacAmounts_.length) {
            revert StakingExecutorTacInvalidArrayLength();
        }

        for (uint256 i; i < validatorAddresses_.length; i++) {
            if (wTacAmounts_[i] == 0) {
                continue;
            }

            int64 completionTime = IStaking(STAKING).undelegate(address(this), validatorAddresses_[i], wTacAmounts_[i]);

            emit TacStakingExecutorUndelegate(PLASMA_VAULT, validatorAddresses_[i], wTacAmounts_[i], completionTime);
        }

        _transferRemainingBalance();
    }

    function redelegate(
        string[] calldata validatorSrcAddresses_,
        string[] calldata validatorDstAddresses_,
        uint256[] calldata wTacAmounts_
    ) external onlyPlasmaVault {
        if (validatorSrcAddresses_.length == 0) {
            return;
        }

        if (
            validatorSrcAddresses_.length != validatorDstAddresses_.length ||
            validatorSrcAddresses_.length != wTacAmounts_.length
        ) {
            revert StakingExecutorTacInvalidArrayLength();
        }

        for (uint256 i; i < validatorSrcAddresses_.length; i++) {
            if (wTacAmounts_[i] == 0) {
                continue;
            }

            int64 completionTime = IStaking(STAKING).redelegate(
                address(this),
                validatorSrcAddresses_[i],
                validatorDstAddresses_[i],
                wTacAmounts_[i]
            );

            emit TacStakingExecutorRedelegate(
                PLASMA_VAULT,
                validatorSrcAddresses_[i],
                validatorDstAddresses_[i],
                wTacAmounts_[i],
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

        if (fromWTac > 0) {
            IwTAC(W_TAC).withdraw(fromWTac);
        }

        if (fromNative > 0) {
            IwTAC(W_TAC).deposit{value: fromNative}();
        }

        IERC20(W_TAC).safeTransfer(PLASMA_VAULT, totalWithdrawable);

        withdrawnAmount_ = totalWithdrawable;

        emit TacStakingExecutorInstantWithdraw(PLASMA_VAULT, withdrawnAmount_);
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

        emit TacStakingExecutorExit(PLASMA_VAULT, totalWTacBalance);
    }

    /// @notice Execute batch of calls as the executor
    /// @param targets Array of target addresses to call
    /// @param calldatas Array of calldata to execute
    /// @return results Array of return data from each call
    /// @dev Restriction: only for emergency actions can be executed only by PlasmaVault
    function executeBatch(
        address[] calldata targets,
        bytes[] calldata calldatas
    ) external onlyPlasmaVault returns (bytes[] memory results) {
        if (targets.length != calldatas.length) {
            revert StakingExecutorTacInvalidArrayLength();
        }

        results = new bytes[](targets.length);

        for (uint256 i = 0; i < targets.length; i++) {
            if (targets[i] == address(0)) {
                revert StakingExecutorTacInvalidTargetAddress();
            }

            results[i] = targets[i].functionCall(calldatas[i]);
        }

        emit TacStakingExecutorBatchExecute(PLASMA_VAULT, targets, calldatas);
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
