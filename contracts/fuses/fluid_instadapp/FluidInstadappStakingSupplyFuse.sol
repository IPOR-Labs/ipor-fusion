// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IFuse} from "../IFuse.sol";
import {IFuseInstantWithdraw} from "../IFuseInstantWithdraw.sol";
import {IFluidLendingStakingRewards} from "./ext/IFluidLendingStakingRewards.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";

struct FluidInstadappStakingSupplyFuseEnterData {
    /// @dev max fluidTokenAmount to deposit, in fluidTokenAmount decimals
    uint256 fluidTokenAmount;
    /// @dev stakingPool address where fluidToken is staked and farmed token ARB
    address stakingPool;
}

struct FluidInstadappStakingSupplyFuseExitData {
    /// @dev fluidTokenAmount to deposit, in fluidTokenAmount decimals
    uint256 fluidTokenAmount;
    /// @dev stakingPool address where fluidToken is staked and farmed token ARB
    address stakingPool;
}

contract FluidInstadappStakingSupplyFuse is IFuse, IFuseInstantWithdraw {
    using SafeERC20 for IERC20;

    event FluidInstadappStakingEnterFuse(address version, address stakingPool, address stakingToken, uint256 amount);
    event FluidInstadappStakingExitFuse(address version, address stakingPool, uint256 amount);

    error FluidInstadappStakingSupplyFuseUnsupportedStakingPool(string action, address stakingPool);

    uint256 public immutable MARKET_ID;
    address public immutable VERSION;

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Enters to the Market
    function enter(bytes calldata data_) external {
        FluidInstadappStakingSupplyFuseEnterData memory data = abi.decode(
            data_,
            (FluidInstadappStakingSupplyFuseEnterData)
        );
        enter(data);
    }

    function enter(FluidInstadappStakingSupplyFuseEnterData memory data_) public {
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

        emit FluidInstadappStakingEnterFuse(VERSION, data_.stakingPool, stakingToken, deposit);
    }

    /// @notice Exits from the Market
    function exit(bytes calldata data_) external {
        FluidInstadappStakingSupplyFuseExitData memory data = abi.decode(
            data_,
            (FluidInstadappStakingSupplyFuseExitData)
        );
        exit(data);
    }
    /// @notice Exits from the Market
    function exit(FluidInstadappStakingSupplyFuseExitData memory data_) public {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.stakingPool)) {
            revert FluidInstadappStakingSupplyFuseUnsupportedStakingPool("enter", data_.stakingPool);
        }

        uint256 balanceOf = IFluidLendingStakingRewards(data_.stakingPool).balanceOf(address(this));
        uint256 withdrawAmount = IporMath.min(data_.fluidTokenAmount, balanceOf);

        if (withdrawAmount == 0) {
            return;
        }

        IFluidLendingStakingRewards(data_.stakingPool).withdraw(withdrawAmount);
        emit FluidInstadappStakingExitFuse(VERSION, data_.stakingPool, withdrawAmount);
    }

    /// @dev params[0] - amount in underlying asset, params[1] - vault address
    function instantWithdraw(bytes32[] calldata params_) external override {
        uint256 amount = uint256(params_[0]);

        if (amount == 0) {
            return;
        }

        address stakingPool = PlasmaVaultConfigLib.bytes32ToAddress(params_[1]);

        exit(
            FluidInstadappStakingSupplyFuseExitData({
                stakingPool: stakingPool,
                fluidTokenAmount: IERC4626(IFluidLendingStakingRewards(stakingPool).stakingToken()).convertToShares(
                    amount
                )
            })
        );
    }
}
