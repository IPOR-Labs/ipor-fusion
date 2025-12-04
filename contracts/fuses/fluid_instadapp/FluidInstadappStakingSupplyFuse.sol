// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {IFuseCommon} from "../IFuse.sol";
import {IFuseInstantWithdraw} from "../IFuseInstantWithdraw.sol";
import {IFluidLendingStakingRewards} from "./ext/IFluidLendingStakingRewards.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";

/// @notice Data structure for entering - supplying - the Fluid Instadapp Staking protocol
struct FluidInstadappStakingSupplyFuseEnterData {
    /// @dev max fluidTokenAmount to deposit, in fluidTokenAmount decimals
    uint256 fluidTokenAmount;
    /// @dev stakingPool address where fluidToken is staked and farmed token ARB
    address stakingPool;
}

/// @notice Data structure for exiting - withdrawing - the Fluid Instadapp Staking protocol
struct FluidInstadappStakingSupplyFuseExitData {
    /// @dev fluidTokenAmount to deposit, in fluidTokenAmount decimals
    uint256 fluidTokenAmount;
    /// @dev stakingPool address where fluidToken is staked and farmed token ARB
    address stakingPool;
}

/// @title Fuse for Fluid Instadapp Staking protocol responsible for supplying and withdrawing assets from the Fluid Instadapp Staking protocol based on preconfigured market substrates
/// @dev Substrates in this fuse are the staking pools addresses that are used in the Fluid Instadapp Staking protocol for a given MARKET_ID
contract FluidInstadappStakingSupplyFuse is IFuseCommon, IFuseInstantWithdraw {
    using SafeERC20 for IERC20;

    /// @notice Emitted when assets are successfully staked in Fluid Instadapp Staking protocol
    /// @param version The address of this fuse contract version
    /// @param stakingPool The address of the staking pool receiving the stake
    /// @param stakingToken The address of the staking token being staked
    /// @param amount The amount of staking tokens staked
    event FluidInstadappStakingFuseEnter(address version, address stakingPool, address stakingToken, uint256 amount);

    /// @notice Emitted when assets are successfully unstaked from Fluid Instadapp Staking protocol
    /// @param version The address of this fuse contract version
    /// @param stakingPool The address of the staking pool from which assets are unstaked
    /// @param stakingToken The address of the staking token being unstaked
    /// @param amount The amount of staking tokens unstaked
    event FluidInstadappStakingFuseExit(address version, address stakingPool, address stakingToken, uint256 amount);

    /// @notice Emitted when unstaking from Fluid Instadapp Staking protocol fails (used in instant withdraw scenarios)
    /// @param version The address of this fuse contract version
    /// @param stakingPool The address of the staking pool from which unstaking was attempted
    /// @param stakingToken The address of the staking token that failed to unstake
    /// @param amount The amount of staking tokens that failed to unstake
    event FluidInstadappStakingFuseExitFailed(
        address version,
        address stakingPool,
        address stakingToken,
        uint256 amount
    );

    error FluidInstadappStakingSupplyFuseUnsupportedStakingPool(string action, address stakingPool);

    uint256 public immutable MARKET_ID;
    address public immutable VERSION;

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Enters the Fluid Instadapp Staking protocol
    /// @param data_ The data structure containing the parameters for entering
    /// @return stakingPool The address of the staking pool
    /// @return stakingToken The address of the staking token
    /// @return deposit The amount deposited
    function enter(
        FluidInstadappStakingSupplyFuseEnterData memory data_
    ) public returns (address stakingPool, address stakingToken, uint256 deposit) {
        stakingPool = data_.stakingPool;
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, stakingPool)) {
            revert FluidInstadappStakingSupplyFuseUnsupportedStakingPool("enter", stakingPool);
        }

        stakingToken = IFluidLendingStakingRewards(stakingPool).stakingToken();
        deposit = IporMath.min(data_.fluidTokenAmount, IERC20(stakingToken).balanceOf(address(this)));

        if (deposit == 0) {
            return (stakingPool, stakingToken, deposit);
        }

        IERC20(stakingToken).forceApprove(stakingPool, deposit);
        IFluidLendingStakingRewards(stakingPool).stake(deposit);

        emit FluidInstadappStakingFuseEnter(VERSION, stakingPool, stakingToken, deposit);
    }

    /// @notice Exits from the Market
    /// @param data_ The data structure containing the parameters for exiting
    /// @return stakingPool The address of the staking pool
    /// @return withdrawAmount The amount withdrawn
    function exit(
        FluidInstadappStakingSupplyFuseExitData memory data_
    ) public returns (address stakingPool, uint256 withdrawAmount) {
        return _exit(data_, false);
    }

    /// @dev params[0] - amount in underlying asset, params[1] - stakingPool address
    function instantWithdraw(bytes32[] calldata params_) external override {
        uint256 amount = uint256(params_[0]);

        if (amount == 0) {
            return;
        }

        address stakingPool = TypeConversionLib.toAddress(params_[1]);

        _exit(
            FluidInstadappStakingSupplyFuseExitData({
                stakingPool: stakingPool,
                fluidTokenAmount: IERC4626(IFluidLendingStakingRewards(stakingPool).stakingToken()).convertToShares(
                    amount
                )
            }),
            true
        );
    }

    function _exit(
        FluidInstadappStakingSupplyFuseExitData memory data_,
        bool catchExceptions_
    ) internal returns (address stakingPool, uint256 withdrawAmount) {
        stakingPool = data_.stakingPool;
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, stakingPool)) {
            revert FluidInstadappStakingSupplyFuseUnsupportedStakingPool("exit", stakingPool);
        }

        uint256 balanceOf = IFluidLendingStakingRewards(stakingPool).balanceOf(address(this));
        withdrawAmount = IporMath.min(data_.fluidTokenAmount, balanceOf);

        if (withdrawAmount == 0) {
            return (stakingPool, withdrawAmount);
        }

        _performWithdraw(stakingPool, withdrawAmount, catchExceptions_);
    }

    function _performWithdraw(address stakingPool_, uint256 withdrawAmount_, bool catchExceptions_) private {
        address stakingToken = IFluidLendingStakingRewards(stakingPool_).stakingToken();
        if (catchExceptions_) {
            try IFluidLendingStakingRewards(stakingPool_).withdraw(withdrawAmount_) {
                emit FluidInstadappStakingFuseExit(VERSION, stakingPool_, stakingToken, withdrawAmount_);
            } catch {
                /// @dev if withdraw failed, continue with the next step
                emit FluidInstadappStakingFuseExitFailed(VERSION, stakingPool_, stakingToken, withdrawAmount_);
            }
        } else {
            IFluidLendingStakingRewards(stakingPool_).withdraw(withdrawAmount_);
            emit FluidInstadappStakingFuseExit(VERSION, stakingPool_, stakingToken, withdrawAmount_);
        }
    }

    /// @notice Enters the Fluid Instadapp Staking protocol using transient storage for parameters
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        uint256 fluidTokenAmount = TypeConversionLib.toUint256(inputs[0]);
        address stakingPool = TypeConversionLib.toAddress(inputs[1]);

        (address returnedStakingPool, address returnedStakingToken, uint256 returnedDeposit) = enter(
            FluidInstadappStakingSupplyFuseEnterData({fluidTokenAmount: fluidTokenAmount, stakingPool: stakingPool})
        );

        bytes32[] memory outputs = new bytes32[](3);
        outputs[0] = TypeConversionLib.toBytes32(returnedStakingPool);
        outputs[1] = TypeConversionLib.toBytes32(returnedStakingToken);
        outputs[2] = TypeConversionLib.toBytes32(returnedDeposit);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Exits from the Fluid Instadapp Staking protocol using transient storage for parameters
    function exitTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        uint256 fluidTokenAmount = TypeConversionLib.toUint256(inputs[0]);
        address stakingPool = TypeConversionLib.toAddress(inputs[1]);

        (address returnedStakingPool, uint256 returnedWithdrawAmount) = exit(
            FluidInstadappStakingSupplyFuseExitData({fluidTokenAmount: fluidTokenAmount, stakingPool: stakingPool})
        );

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(returnedStakingPool);
        outputs[1] = TypeConversionLib.toBytes32(returnedWithdrawAmount);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}
