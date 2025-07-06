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
    
    address public immutable wTAC;
    address public immutable staking;
    address public immutable plasmaVault;

    error StakingExecutorTacInvalidPlasmaVaultAddress();

    modifier restricted() {
        if (msg.sender != plasmaVault) {
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

        plasmaVault = plasmaVault_;
        wTAC = wTAC_;
        staking = staking_;
    }

    function delegate(StakingExecutorTacEnterData memory data_) external restricted {
        if (data_.wTacAmount == 0) {
            return;
        }

        address plasmaVault = msg.sender;

        uint256 executorBalance = IERC20(wTAC).balanceOf(address(this));

        uint256 finalAmount = data_.wTacAmount <= executorBalance ? data_.wTacAmount : executorBalance;

        if (finalAmount == 0) {
            return;
        }

        /// @dev get native TAC from wTAC
        IWETH9(wTAC).withdraw(finalAmount);

        address delegator = address(this);

        /// @dev delegate TAC to the validator
        staking.functionCall(abi.encodeWithSelector(IStaking.delegate.selector, delegator, data_.operatorAddress, finalAmount));

        uint256 remainingBalance = address(this).balance;

        if (remainingBalance > 0) {
            IWETH9(wTAC).deposit{value: remainingBalance}();
            IERC20(wTAC).safeTransfer(plasmaVault, remainingBalance);
        }

        emit TacStakingExecutorDelegate(plasmaVault, data_.operatorAddress, data_.wTacAmount);
    }

    function undelegate(StakingExecutorTacExitData memory data_) external restricted {
        if (data_.wTacAmount == 0) {
            return;
        }

        address plasmaVault = msg.sender;

        staking.functionCall(
            abi.encodeWithSelector(IStaking.undelegate.selector, address(this), data_.operatorAddress, data_.wTacAmount)
        );

        uint256 remainingBalance = address(this).balance;

        if (remainingBalance > 0) {
            IWETH9(wTAC).deposit{value: remainingBalance}();
            IERC20(wTAC).safeTransfer(plasmaVault, remainingBalance);
        }

        emit TacStakingExecutorUndelegate(plasmaVault, data_.operatorAddress, data_.wTacAmount);
    }

    function instantWithdraw(uint256 amount_) external restricted {
        if (amount_ == 0) {
            return;
        }

        uint256 remainingBalance = address(this).balance;
        
        uint256 finalAmount = amount_ <= remainingBalance ? amount_ : remainingBalance;

        if (finalAmount == 0) {
            return;
        }

        IWETH9(wTAC).withdraw(finalAmount);

        IERC20(wTAC).safeTransfer(plasmaVault, finalAmount);

        emit TacStakingExecutorInstantWithdraw(plasmaVault, finalAmount);
    }

    function exit() external restricted {
        uint256 remainingBalance = address(this).balance;

        IWETH9(wTAC).withdraw(remainingBalance);

        uint256 remainingWTacBalance = IERC20(wTAC).balanceOf(address(this));

        IERC20(wTAC).safeTransfer(plasmaVault, remainingWTacBalance);

        emit TacStakingExecutorExit(plasmaVault, remainingWTacBalance);
    }

    /// @notice Allows the contract to receive native token
    receive() external payable {}
}
