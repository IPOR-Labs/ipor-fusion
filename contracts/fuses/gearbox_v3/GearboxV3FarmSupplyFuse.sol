// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
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

    /// @notice Enters the Gearbox V3 Farmd protocol by depositing dToken to farmdToken
    /// @param data_ The data structure containing the parameters for entering the Gearbox V3 Farmd protocol
    /// @return farmdToken The address of the farmd token
    /// @return dToken The address of the dToken
    /// @return amount The amount deposited
    function enter(
        GearboxV3FarmdSupplyFuseEnterData memory data_
    ) public returns (address farmdToken, address dToken, uint256 amount) {
        if (data_.dTokenAmount == 0) {
            return (address(0), address(0), 0);
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.farmdToken)) {
            revert GearboxV3FarmdSupplyFuseUnsupportedFarmdToken("enter", data_.farmdToken);
        }

        dToken = IFarmingPool(data_.farmdToken).stakingToken();
        uint256 dTokenDepositAmount = IporMath.min(data_.dTokenAmount, IERC20(dToken).balanceOf(address(this)));

        if (dTokenDepositAmount == 0) {
            return (address(0), address(0), 0);
        }

        IERC20(dToken).forceApprove(data_.farmdToken, dTokenDepositAmount);
        IFarmingPool(data_.farmdToken).deposit(dTokenDepositAmount);

        farmdToken = data_.farmdToken;
        amount = dTokenDepositAmount;

        emit GearboxV3FarmdFuseEnter(VERSION, farmdToken, dToken, amount);
    }

    /// @notice Exits from the Market
    /// @param data_ The data structure containing the parameters for exiting the Gearbox V3 Farmd protocol
    /// @return farmdToken The address of the farmd token
    /// @return amount The amount withdrawn
    function exit(GearboxV3FarmdSupplyFuseExitData memory data_) public returns (address farmdToken, uint256 amount) {
        (farmdToken, amount) = _exit(data_, false);
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
            }),
            true
        );
    }

    function _exit(
        GearboxV3FarmdSupplyFuseExitData memory data_,
        bool catchExceptions_
    ) internal returns (address farmdToken, uint256 amount) {
        if (data_.dTokenAmount == 0) {
            return (address(0), 0);
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.farmdToken)) {
            revert GearboxV3FarmdSupplyFuseUnsupportedFarmdToken("exit", data_.farmdToken);
        }

        uint256 withdrawAmount = IporMath.min(
            data_.dTokenAmount,
            IFarmingPool(data_.farmdToken).balanceOf(address(this))
        );

        if (withdrawAmount == 0) {
            return (address(0), 0);
        }

        farmdToken = data_.farmdToken;
        amount = withdrawAmount;

        _performWithdraw(farmdToken, withdrawAmount, catchExceptions_);
    }

    function _performWithdraw(address farmdToken_, uint256 withdrawAmount_, bool catchExceptions_) private {
        if (catchExceptions_) {
            try IFarmingPool(farmdToken_).withdraw(withdrawAmount_) {
                emit GearboxV3FarmdFuseExit(VERSION, farmdToken_, withdrawAmount_);
            } catch {
                /// @dev if withdraw failed, continue with the next step
                emit GearboxV3FarmdFuseExitFailed(VERSION, farmdToken_, withdrawAmount_);
            }
        } else {
            IFarmingPool(farmdToken_).withdraw(withdrawAmount_);
            emit GearboxV3FarmdFuseExit(VERSION, farmdToken_, withdrawAmount_);
        }
    }

    /// @notice Enters the Gearbox V3 Farmd protocol using transient storage for parameters
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        uint256 dTokenAmount = TypeConversionLib.toUint256(inputs[0]);
        address farmdToken = TypeConversionLib.toAddress(inputs[1]);

        (address returnedFarmdToken, address returnedDToken, uint256 returnedAmount) = enter(
            GearboxV3FarmdSupplyFuseEnterData({dTokenAmount: dTokenAmount, farmdToken: farmdToken})
        );

        bytes32[] memory outputs = new bytes32[](3);
        outputs[0] = TypeConversionLib.toBytes32(returnedFarmdToken);
        outputs[1] = TypeConversionLib.toBytes32(returnedDToken);
        outputs[2] = TypeConversionLib.toBytes32(returnedAmount);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Exits from the Gearbox V3 Farmd protocol using transient storage for parameters
    function exitTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        uint256 dTokenAmount = TypeConversionLib.toUint256(inputs[0]);
        address farmdToken = TypeConversionLib.toAddress(inputs[1]);

        (address returnedFarmdToken, uint256 returnedAmount) = exit(
            GearboxV3FarmdSupplyFuseExitData({dTokenAmount: dTokenAmount, farmdToken: farmdToken})
        );

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(returnedFarmdToken);
        outputs[1] = TypeConversionLib.toBytes32(returnedAmount);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}
