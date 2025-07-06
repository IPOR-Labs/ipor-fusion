// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IFuseCommon} from "../IFuseCommon.sol";
import {IFuseInstantWithdraw} from "../IFuseInstantWithdraw.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {TacStakingExecutor, StakingExecutorTacEnterData, StakingExecutorTacExitData} from "./TacStakingExecutor.sol";
import {TacStakingStorageLib} from "./TacStakingStorageLib.sol";
import {IStaking, Validator, BondStatus} from "./ext/IStaking.sol";

struct TacStakingFuseEnterData {
    address validator;
    uint256 tacAmount;
}

struct TacStakingFuseExitData {
    address validator;
    uint256 wTacAmount;
}

contract TacStakingFuse is IFuseCommon, IFuseInstantWithdraw {
    using SafeERC20 for IERC20;

    error TacStakingFuseInvalidExecutorAddress();
    error TacStakingFuseSubstrateNotGranted(address validator);
    error TacStakingFuseExecutorAlreadyCreated();
    error TacStakingFuseUnsupportedValidator(address validator);
    error TacStakingFuseValidatorJailed(address validator, string operatorAddress);
    error TacStakingFuseValidatorNotBonded(address validator, string operatorAddress);

    event TacStakingFuseEnter(address version, address validator, string operatorAddress, uint256 amount);
    event TacStakingFuseExit(address version, address validator, string operatorAddress, uint256 amount);
    event TacStakingFuseInstantWithdraw(address version, uint256 amount);
    event TacStakingExecutorCreated(address executor, address plasmaVault, address wTAC, address staking);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address public immutable W_TAC;
    address public immutable STAKING;

    constructor(uint256 marketId_, address wTAC_, address staking_) {
        if (wTAC_ == address(0)) {
            revert TacStakingFuseInvalidExecutorAddress();
        }
        if (staking_ == address(0)) {
            revert TacStakingFuseInvalidExecutorAddress();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
        W_TAC = wTAC_;
        STAKING = staking_;
    }

    /// @notice Creates a new TacStakingExecutor and stores its address in storage
    /// @dev Only callable by alpha role
    function createExecutor() external {
        // Check if executor is already set
        address existingExecutor = TacStakingStorageLib.getTacStakingExecutor();
        if (existingExecutor != address(0)) {
            revert TacStakingFuseExecutorAlreadyCreated();
        }

        // Create new executor with address(this) as plasmaVault
        TacStakingExecutor executor = new TacStakingExecutor(address(this), W_TAC, STAKING);

        // Store executor address in storage
        TacStakingStorageLib.setTacStakingExecutor(address(executor));

        emit TacStakingExecutorCreated(address(executor), address(this), W_TAC, STAKING);
    }

    function enter(TacStakingFuseEnterData memory data_) external {
        if (data_.tacAmount == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.validator)) {
            revert TacStakingFuseSubstrateNotGranted(data_.validator);
        }

        address payable executor = payable(TacStakingStorageLib.getTacStakingExecutor());

        if (executor == address(0)) {
            revert TacStakingFuseInvalidExecutorAddress();
        }

        (string memory operatorAddress, bool isJailed, bool isBonded) = _getValidatorInfo(data_.validator);

        if (isJailed) {
            revert TacStakingFuseValidatorJailed(data_.validator, operatorAddress);
        }

        if (!isBonded) {
            revert TacStakingFuseValidatorNotBonded(data_.validator, operatorAddress);
        }

        uint256 balance = IERC20(W_TAC).balanceOf(address(this));
        uint256 finalAmount = data_.tacAmount <= balance ? data_.tacAmount : balance;

        if (finalAmount == 0) {
            return;
        }

        IERC20(W_TAC).safeTransfer(executor, finalAmount);

        TacStakingExecutor(executor).delegate(
            StakingExecutorTacEnterData({operatorAddress: operatorAddress, wTacAmount: finalAmount})
        );

        emit TacStakingFuseEnter(VERSION, data_.validator, operatorAddress, finalAmount);
    }

    function exit(TacStakingFuseExitData memory data_) external {
        if (data_.wTacAmount == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.validator)) {
            revert TacStakingFuseSubstrateNotGranted(data_.validator);
        }

        address payable executor = payable(TacStakingStorageLib.getTacStakingExecutor());

        if (executor == address(0)) {
            revert TacStakingFuseInvalidExecutorAddress();
        }

        (string memory operatorAddress, bool isJailed, bool isBonded) = _getValidatorInfo(data_.validator);

        /// TODO: confirm if when exit should be able to exit even if validator is jailed
        if (isJailed) {
            revert TacStakingFuseValidatorJailed(data_.validator, operatorAddress);
        }

        /// TODO: confirm if when exit should be able to exit even if validator is not bonded
        if (!isBonded) {
            revert TacStakingFuseValidatorNotBonded(data_.validator, operatorAddress);
        }

        TacStakingExecutor(executor).undelegate(
            StakingExecutorTacExitData({operatorAddress: operatorAddress, wTacAmount: data_.wTacAmount})
        );

        emit TacStakingFuseExit(VERSION, data_.validator, operatorAddress, data_.wTacAmount);
    }

    /// @notice Handle instant withdrawals
    /// @dev params[0] - amount in wTAC, params[1] - validator hash (bytes32)
    /// @param params_ Array of parameters for withdrawal
    /// @dev Intant withdraw can be done only from TacStakingExecutor
    function instantWithdraw(bytes32[] calldata params_) external override {
        uint256 amount = uint256(params_[0]);

        if (amount == 0) {
            return;
        }

        address payable executor = payable(TacStakingStorageLib.getTacStakingExecutor());

        if (executor == address(0)) {
            revert TacStakingFuseInvalidExecutorAddress();
        }

        uint256 withdrawnAmount = TacStakingExecutor(executor).instantWithdraw(amount);

        emit TacStakingFuseInstantWithdraw(VERSION, withdrawnAmount);
    }

    /// @notice Withdraw all wTAC from the executor
    /// @dev Intant withdraw can be done only from TacStakingExecutor
    function exit() external {
        address payable executor = payable(TacStakingStorageLib.getTacStakingExecutor());
        if (executor == address(0)) {
            revert TacStakingFuseInvalidExecutorAddress();
        }
        TacStakingExecutor(executor).exit();
    }

    function _getValidatorInfo(
        address validator_
    ) internal view returns (string memory operatorAddress_, bool isJailed_, bool isBonded_) {
        try IStaking(STAKING).validator(validator_) returns (Validator memory validator) {
            isJailed_ = validator.jailed;
            isBonded_ = validator.status == BondStatus.Bonded;
            operatorAddress_ = validator.operatorAddress;
        } catch {
            revert TacStakingFuseUnsupportedValidator(validator_);
        }
    }
}
