// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {TacStakingExecutor, StakingExecutorTacEnterData, StakingExecutorTacExitData} from "./TakStakingExecutor.sol";
import {TacStakingStorageLib} from "./TacStakingStorageLib.sol";
import {console2} from "forge-std/console2.sol";

struct TacStakingFuseEnterData {
    string validator;
    uint256 tacAmount;
}

struct TacStakingFuseExitData {
    string validator;
    uint256 wTacAmount;
}

contract TacStakingFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    error TacStakingFuseInvalidExecutorAddress();
    error TacStakingFuseUnsupportedAsset(string action, string validator);
    error TacStakingFuseExecutorAlreadySet();
    error TacStakingFuseOnlyAlpha();

    event TacStakingFuseEnter(address version, string validator, uint256 amount);
    event TacStakingFuseExit(address version, string validator, uint256 amount);
    event TacStakingExecutorCreated(address executor, address plasmaVault, address wTAC, address staking);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address public immutable wTAC;
    address public immutable staking;

    constructor(uint256 marketId_, address wTAC_, address staking_) {
        if (wTAC_ == address(0)) {
            revert TacStakingFuseInvalidExecutorAddress();
        }
        if (staking_ == address(0)) {
            revert TacStakingFuseInvalidExecutorAddress();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
        wTAC = wTAC_;
        staking = staking_;
    }

    /// @notice Creates a new TacStakingExecutor and stores its address in storage
    /// @dev Only callable by alpha role
    function createExecutor() external {
        // Check if executor is already set
        address existingExecutor = TacStakingStorageLib.getTacStakingExecutor();
        if (existingExecutor != address(0)) {
            revert TacStakingFuseExecutorAlreadySet();
        }

        // Create new executor with address(this) as plasmaVault
        TacStakingExecutor executor = new TacStakingExecutor(address(this), wTAC, staking);

        // Store executor address in storage
        TacStakingStorageLib.setTacStakingExecutor(address(executor));

        emit TacStakingExecutorCreated(address(executor), address(this), wTAC, staking);
    }

    function enter(TacStakingFuseEnterData memory data_) external {
        if (data_.tacAmount == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, keccak256(bytes(data_.validator)))) {
            revert TacStakingFuseUnsupportedAsset("enter", data_.validator);
        }

        address payable executor = payable(TacStakingStorageLib.getTacStakingExecutor());

        console2.log("executor", executor);

        if (executor == address(0)) {
            revert TacStakingFuseInvalidExecutorAddress();
        }

        uint256 balance = IERC20(wTAC).balanceOf(address(this));
        uint256 finalAmount = data_.tacAmount <= balance ? data_.tacAmount : balance;

        if (finalAmount == 0) {
            return;
        }

        IERC20(wTAC).safeTransfer(executor, finalAmount);

        TacStakingExecutor(executor).enter(
            StakingExecutorTacEnterData({validator: data_.validator, wTacAmount: finalAmount})
        );

        emit TacStakingFuseEnter(VERSION, data_.validator, finalAmount);
    }

    function exit(TacStakingFuseExitData memory data_) external {
        if (data_.wTacAmount == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, keccak256(bytes(data_.validator)))) {
            revert TacStakingFuseUnsupportedAsset("exit", data_.validator);
        }

        address payable executor = payable(TacStakingStorageLib.getTacStakingExecutor());

        if (executor == address(0)) {
            revert TacStakingFuseInvalidExecutorAddress();
        }

        TacStakingExecutor(executor).exit(
            StakingExecutorTacExitData({validator: data_.validator, wTacAmount: data_.wTacAmount})
        );

        emit TacStakingFuseExit(VERSION, data_.validator, data_.wTacAmount);
    }
}
