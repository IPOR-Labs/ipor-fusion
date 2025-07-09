// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStaking} from "./ext/IStaking.sol";

interface IwTAC {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

struct StakingExecutorTacDelegateData {
    string validatorAddress;
    uint256 wTacAmount;
}

struct StakingExecutorTacRedelegateData {
    string validatorSrcAddress;
    string validatorDstAddress;
    uint256 wTacAmount;
}

struct StakingExecutorTacUndelegateData {
    string validatorAddress;
    uint256 wTacAmount;
}

contract TacStakingExecutor {
    using Address for address;
    using SafeERC20 for IERC20;

    error StakingExecutorTacInvalidTacAddress();
    error StakingExecutorTacInvalidStakingAddress();
    error StakingExecutorTacInvalidArrayLength();
    error StakingExecutorTacInvalidTargetAddress();

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

    function delegate(StakingExecutorTacDelegateData memory data_) external onlyPlasmaVault {
        if (data_.wTacAmount == 0) {
            return;
        }

        uint256 executorBalance = IERC20(W_TAC).balanceOf(address(this));

        uint256 finalAmount = data_.wTacAmount <= executorBalance ? data_.wTacAmount : executorBalance;

        if (finalAmount == 0) {
            return;
        }

        /// @dev get native TAC from wTAC
        IwTAC(W_TAC).withdraw(finalAmount);

        address delegator = address(this);

        IStaking(STAKING).delegate(delegator, data_.validatorAddress, finalAmount);

        emit TacStakingExecutorDelegate(PLASMA_VAULT, data_.validatorAddress, data_.wTacAmount);

        _transferRemainingBalance();
    }

    function redelegate(StakingExecutorTacRedelegateData memory data_) external onlyPlasmaVault {
        if (data_.wTacAmount == 0) {
            return;
        }

        int64 completionTime = IStaking(STAKING).redelegate(
            address(this),
            data_.validatorSrcAddress,
            data_.validatorDstAddress,
            data_.wTacAmount
        );

        emit TacStakingExecutorRedelegate(
            PLASMA_VAULT,
            data_.validatorSrcAddress,
            data_.validatorDstAddress,
            data_.wTacAmount,
            completionTime
        );

        _transferRemainingBalance();
    }

    function undelegate(StakingExecutorTacUndelegateData memory data_) external onlyPlasmaVault {
        if (data_.wTacAmount == 0) {
            return;
        }

        int64 completionTime = IStaking(STAKING).undelegate(address(this), data_.validatorAddress, data_.wTacAmount);

        _transferRemainingBalance();

        emit TacStakingExecutorUndelegate(PLASMA_VAULT, data_.validatorAddress, data_.wTacAmount, completionTime);
    }

    function instantWithdraw(uint256 amount_) external onlyPlasmaVault returns (uint256 withdrawnAmount_) {
        if (amount_ == 0) {
            return 0;
        }

        uint256 wTacBalance = IERC20(W_TAC).balanceOf(address(this));

        uint256 fromWTac = amount_ <= wTacBalance ? amount_ : wTacBalance;

        uint256 remainingNeeded = amount_ - fromWTac;

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
