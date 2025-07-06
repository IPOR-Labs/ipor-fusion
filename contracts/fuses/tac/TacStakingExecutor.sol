// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStaking} from "./ext/IStaking.sol";

/// @title IWETH9 Interface
/// @notice Interface for Wrapped Ether (WETH) token with deposit and withdraw functionality
interface IWETH9 {
    /// @notice Deposit ETH to receive WETH
    function deposit() external payable;

    /// @notice Withdraw ETH from WETH
    /// @param amount Amount of WETH to withdraw
    function withdraw(uint256 amount) external;
}

struct StakingExecutorTacEnterData {
    string operatorAddress;
    uint256 wTacAmount;
}

struct StakingExecutorTacExitData {
    string operatorAddress;
    uint256 wTacAmount;
}

contract TacStakingExecutor {
    using Address for address;
    using SafeERC20 for IERC20;

    error StakingExecutorTacInvalidTacAddress();
    error StakingExecutorTacInvalidStakingAddress();
    error StakingExecutorTacDelegateFailed();
    error StakingExecutorTacUndelegateFailed();

    event TacStakingExecutorDelegate(address plasmaVault, string operatorAddress, uint256 amount);
    event TacStakingExecutorUndelegate(address plasmaVault, string operatorAddress, uint256 amount);
    event TacStakingExecutorInstantWithdraw(address plasmaVault, uint256 amount);
    event TacStakingExecutorExit(address plasmaVault, uint256 amount);

    address public immutable W_TAC;
    address public immutable STAKING;
    address public immutable PLASMA_VAULT;

    error StakingExecutorTacInvalidPlasmaVaultAddress();

    modifier restricted() {
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

    function delegate(StakingExecutorTacEnterData memory data_) external restricted {
        if (data_.wTacAmount == 0) {
            return;
        }

        address plasmaVault = msg.sender;

        uint256 executorBalance = IERC20(W_TAC).balanceOf(address(this));

        uint256 finalAmount = data_.wTacAmount <= executorBalance ? data_.wTacAmount : executorBalance;

        if (finalAmount == 0) {
            return;
        }

        /// @dev get native TAC from wTAC
        IWETH9(W_TAC).withdraw(finalAmount);

        address delegator = address(this);

        /// @dev delegate TAC to the validator
        STAKING.functionCall(
            abi.encodeWithSelector(IStaking.delegate.selector, delegator, data_.operatorAddress, finalAmount)
        );

        uint256 remainingBalance = address(this).balance;

        if (remainingBalance > 0) {
            IWETH9(W_TAC).deposit{value: remainingBalance}();
            IERC20(W_TAC).safeTransfer(plasmaVault, remainingBalance);
        }

        emit TacStakingExecutorDelegate(plasmaVault, data_.operatorAddress, data_.wTacAmount);
    }

    function undelegate(StakingExecutorTacExitData memory data_) external restricted {
        if (data_.wTacAmount == 0) {
            return;
        }

        STAKING.functionCall(
            abi.encodeWithSelector(IStaking.undelegate.selector, address(this), data_.operatorAddress, data_.wTacAmount)
        );

        uint256 remainingBalance = address(this).balance;

        if (remainingBalance > 0) {
            IWETH9(W_TAC).deposit{value: remainingBalance}();
            IERC20(W_TAC).safeTransfer(PLASMA_VAULT, remainingBalance);
        }

        emit TacStakingExecutorUndelegate(PLASMA_VAULT, data_.operatorAddress, data_.wTacAmount);
    }

    function instantWithdraw(uint256 amount_) external restricted returns (uint256 withdrawnAmount_) {
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
            IWETH9(W_TAC).withdraw(fromWTac);
        }

        if (fromNative > 0) {
            IWETH9(W_TAC).deposit{value: fromNative}();
        }

        IERC20(W_TAC).safeTransfer(PLASMA_VAULT, totalWithdrawable);

        withdrawnAmount_ = totalWithdrawable;

        emit TacStakingExecutorInstantWithdraw(PLASMA_VAULT, withdrawnAmount_);
    }

    function exit() external restricted {
        uint256 nativeBalance = address(this).balance;

        if (nativeBalance > 0) {
            IWETH9(W_TAC).deposit{value: nativeBalance}();
        }

        uint256 totalWTacBalance = IERC20(W_TAC).balanceOf(address(this));

        if (totalWTacBalance > 0) {
            IERC20(W_TAC).safeTransfer(PLASMA_VAULT, totalWTacBalance);
        }

        emit TacStakingExecutorExit(PLASMA_VAULT, totalWTacBalance);
    }

    /// @notice Allows the contract to receive native token
    receive() external payable {}
}
