// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IFuseCommon} from "../IFuse.sol";
import {IFuseInstantWithdraw} from "../IFuseInstantWithdraw.sol";
import {IFluidLendingStakingRewards} from "./ext/IFluidLendingStakingRewards.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";

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

    event FluidInstadappStakingFuseEnter(address version, address stakingPool, address stakingToken, uint256 amount);
    event FluidInstadappStakingFuseExit(address version, address stakingPool, uint256 amount);
    event FluidInstadappStakingFuseExitFailed(address version, address stakingPool, uint256 amount);

    error FluidInstadappStakingSupplyFuseUnsupportedStakingPool(string action, address stakingPool);

    uint256 public immutable MARKET_ID;
    address public immutable VERSION;

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    function enter(FluidInstadappStakingSupplyFuseEnterData memory data_) external {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.stakingPool)) {
            revert FluidInstadappStakingSupplyFuseUnsupportedStakingPool("enter", data_.stakingPool);
        }

        address stakingToken = IFluidLendingStakingRewards(data_.stakingPool).stakingToken();
        uint256 deposit = IporMath.min(data_.fluidTokenAmount, IERC20(stakingToken).balanceOf(address(this)));

        if (deposit == 0) {
            return;
        }

        IERC20(stakingToken).forceApprove(data_.stakingPool, deposit);
        IFluidLendingStakingRewards(data_.stakingPool).stake(deposit);

        emit FluidInstadappStakingFuseEnter(VERSION, data_.stakingPool, stakingToken, deposit);
    }

    /// @notice Exits from the Market
    function exit(FluidInstadappStakingSupplyFuseExitData memory data_) external {
        _exit(data_);
    }

    /// @dev params[0] - amount in underlying asset, params[1] - vault address
    function instantWithdraw(bytes32[] calldata params_) external override {
        uint256 amount = uint256(params_[0]);

        if (amount == 0) {
            return;
        }

        address stakingPool = PlasmaVaultConfigLib.bytes32ToAddress(params_[1]);

        _exit(
            FluidInstadappStakingSupplyFuseExitData({
                stakingPool: stakingPool,
                fluidTokenAmount: IERC4626(IFluidLendingStakingRewards(stakingPool).stakingToken()).convertToShares(
                    amount
                )
            })
        );
    }

    function _exit(FluidInstadappStakingSupplyFuseExitData memory data_) internal {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.stakingPool)) {
            revert FluidInstadappStakingSupplyFuseUnsupportedStakingPool("enter", data_.stakingPool);
        }

        uint256 balanceOf = IFluidLendingStakingRewards(data_.stakingPool).balanceOf(address(this));
        uint256 withdrawAmount = IporMath.min(data_.fluidTokenAmount, balanceOf);

        if (withdrawAmount == 0) {
            return;
        }

        try IFluidLendingStakingRewards(data_.stakingPool).withdraw(withdrawAmount) {
            emit FluidInstadappStakingFuseExit(VERSION, data_.stakingPool, withdrawAmount);
        } catch {
            /// @dev if withdraw failed, continue with the next step
            emit FluidInstadappStakingFuseExitFailed(VERSION, data_.stakingPool, withdrawAmount);
        }
    }
}
