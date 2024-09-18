// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IFuseInstantWithdraw} from "../IFuseInstantWithdraw.sol";
import {IFarmingPool} from "./ext/IFarmingPool.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";

struct GearboxV3FarmdSupplyFuseEnterData {
    /// @dev max dTokenAmount to deposit, in dToken decimals
    uint256 dTokenAmount;
    address farmdToken;
}

struct GearboxV3FarmdSupplyFuseExitData {
    /// @dev amount to withdraw, in dToken decimals
    uint256 dTokenAmount;
    /// @dev farmd token address where dToken is staked and farmed token (ARB for dUSDC)
    address farmdToken;
}

/// @title Fuse for Gearbox V3 Farmd protocol responsible for supplying and withdrawing assets from the Gearbox V3 Farmd protocol based on preconfigured market substrates
/// @dev Substrates in this fuse are the farmd tokens addresses that are used in the Gearbox V3 Farmd protocol for a given MARKET_ID
contract GearboxV3FarmSupplyFuse is IFuseCommon, IFuseInstantWithdraw {
    using SafeERC20 for IERC20;

    event GearboxV3FarmdFuseEnter(address version, address farmdToken, address dToken, uint256 amount);
    event GearboxV3FarmdFuseExit(address version, address farmdToken, uint256 amount);
    event GearboxV3FarmdFuseExitFailed(address version, address farmdToken, uint256 amount);

    error GearboxV3FarmdSupplyFuseUnsupportedFarmdToken(string action, address farmdToken);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    function enter(GearboxV3FarmdSupplyFuseEnterData memory data_) external {
        if (data_.dTokenAmount == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.farmdToken)) {
            revert GearboxV3FarmdSupplyFuseUnsupportedFarmdToken("enter", data_.farmdToken);
        }

        address dToken = IFarmingPool(data_.farmdToken).stakingToken();
        uint256 dTokenDepositAmount = IporMath.min(data_.dTokenAmount, IERC20(dToken).balanceOf(address(this)));

        if (dTokenDepositAmount == 0) {
            return;
        }

        IERC20(dToken).forceApprove(data_.farmdToken, dTokenDepositAmount);
        IFarmingPool(data_.farmdToken).deposit(dTokenDepositAmount);

        emit GearboxV3FarmdFuseEnter(VERSION, data_.farmdToken, dToken, dTokenDepositAmount);
    }

    /// @notice Exits from the Market
    function exit(GearboxV3FarmdSupplyFuseExitData memory data_) external {
        _exit(data_);
    }

    /// @dev params[0] - amount in underlying asset of Plasma Vault, params[1] - Farm dToken address
    function instantWithdraw(bytes32[] calldata params_) external override {
        uint256 amount = uint256(params_[0]);

        address farmdToken = PlasmaVaultConfigLib.bytes32ToAddress(params_[1]);

        _exit(
            GearboxV3FarmdSupplyFuseExitData({
                farmdToken: farmdToken,
                /// @dev dToken 1:1 Farm dToken
                dTokenAmount: IERC4626(IFarmingPool(farmdToken).stakingToken()).convertToShares(amount)
            })
        );
    }

    function _exit(GearboxV3FarmdSupplyFuseExitData memory data_) internal {
        if (data_.dTokenAmount == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.farmdToken)) {
            revert GearboxV3FarmdSupplyFuseUnsupportedFarmdToken("enter", data_.farmdToken);
        }

        uint256 withdrawAmount = IporMath.min(
            data_.dTokenAmount,
            IFarmingPool(data_.farmdToken).balanceOf(address(this))
        );

        if (withdrawAmount == 0) {
            return;
        }

        try IFarmingPool(data_.farmdToken).withdraw(withdrawAmount) {
            emit GearboxV3FarmdFuseExit(VERSION, data_.farmdToken, withdrawAmount);
        } catch {
            /// @dev if withdraw failed, continue with the next step
            emit GearboxV3FarmdFuseExitFailed(VERSION, data_.farmdToken, withdrawAmount);
        }
    }
}
