// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IporMath} from "../../../../libraries/math/IporMath.sol";
import {TypeConversionLib} from "../../../../libraries/TypeConversionLib.sol";
import {TransientStorageLib} from "../../../../transient_storage/TransientStorageLib.sol";
import {IFuseCommon} from "../../../IFuseCommon.sol";
import {IFuseInstantWithdraw} from "../../../IFuseInstantWithdraw.sol";
import {ISavingsDai} from "./ext/ISavingsDai.sol";

/// @notice Structure for entering (supply) to the Spark protocol
struct SparkSupplyFuseEnterData {
    /// @dev amount of DAI to supply / deposit
    uint256 amount;
}

/// @notice Structure for exiting (withdraw) from the Spark protocol
struct SparkSupplyFuseExitData {
    /// @dev  amount of DAI to withdraw
    uint256 amount;
}

/// @title Fuse Spark Supply protocol responsible for supplying and withdrawing assets from the Spark protocol
/// @notice Fuse for Spark protocol responsible for supplying and withdrawing assets
/// @author IPOR Labs
contract SparkSupplyFuse is IFuseCommon, IFuseInstantWithdraw {
    using SafeERC20 for ERC20;

    /// @notice Address of DAI token
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    /// @notice Address of sDAI (Savings DAI) token
    address public constant SDAI = 0x83F20F44975D03b1b09e64809B757c47f942BEeA;

    /// @notice Address of this fuse contract
    address public immutable VERSION;

    /// @notice Market ID for the fuse
    uint256 public immutable MARKET_ID;

    /// @notice Emitted when entering the strategy
    /// @param version Address of the fuse
    /// @param amount Amount of DAI supplied
    /// @param shares Amount of sDAI shares received
    event SparkSupplyFuseEnter(address version, uint256 amount, uint256 shares);

    /// @notice Emitted when exiting the strategy
    /// @param version Address of the fuse
    /// @param amount Amount of assets withdrawn
    /// @param shares Amount of sDAI shares burned
    event SparkSupplyFuseExit(address version, uint256 amount, uint256 shares);

    /// @notice Emitted when exit fails
    /// @param version Address of the fuse
    /// @param amount Amount attempted to withdraw
    event SparkSupplyFuseExitFailed(address version, uint256 amount);

    /// @notice Constructor
    /// @param marketIdInput Market ID
    constructor(uint256 marketIdInput) {
        VERSION = address(this);
        MARKET_ID = marketIdInput;
    }

    /// @notice Enters the protocol by supplying assets
    /// @param data The input data for entering the protocol
    /// @return shares The amount of shares received
    function enter(SparkSupplyFuseEnterData memory data) public returns (uint256 shares) {
        if (data.amount == 0) {
            return 0;
        }
        ERC20(DAI).forceApprove(SDAI, data.amount);
        shares = ISavingsDai(SDAI).deposit(data.amount, address(this));

        emit SparkSupplyFuseEnter(VERSION, data.amount, shares);
        return shares;
    }

    /// @notice Enters the protocol using transient storage for input/output
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        uint256 amount = TypeConversionLib.toUint256(inputs[0]);

        uint256 shares = enter(SparkSupplyFuseEnterData({amount: amount}));

        bytes32[] memory outputs = new bytes32[](1);
        outputs[0] = TypeConversionLib.toBytes32(shares);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Exits the protocol by withdrawing assets
    /// @param data The input data for exiting the protocol
    /// @return shares The amount of shares burned/withdrawn
    function exit(SparkSupplyFuseExitData calldata data) external returns (uint256 shares) {
        return _exit(data, false);
    }

    /// @notice Exits the protocol using transient storage for input/output
    function exitTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        uint256 amount = TypeConversionLib.toUint256(inputs[0]);

        uint256 shares = _exit(SparkSupplyFuseExitData({amount: amount}), false);

        bytes32[] memory outputs = new bytes32[](1);
        outputs[0] = TypeConversionLib.toBytes32(shares);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Instant withdraw
    /// @dev params[0] - amount in underlying asset
    /// @param params_ The parameters for instant withdraw
    function instantWithdraw(bytes32[] calldata params_) external override {
        _exit(SparkSupplyFuseExitData({amount: uint256(params_[0])}), true);
    }

    /// @notice Internal exit logic
    /// @param data_ The input data for exiting the protocol
    /// @param catchExceptions_ Whether to catch exceptions during withdrawal
    /// @return shares The amount of shares burned/withdrawn
    function _exit(SparkSupplyFuseExitData memory data_, bool catchExceptions_) private returns (uint256 shares) {
        if (data_.amount == 0) {
            return 0;
        }

        uint256 finalAmount = IporMath.min(data_.amount, ISavingsDai(SDAI).maxWithdraw(address(this)));

        if (finalAmount == 0) {
            return 0;
        }

        return _performWithdraw(finalAmount, catchExceptions_);
    }

    /// @notice Internal withdraw logic
    /// @param finalAmount_ The amount to withdraw
    /// @param catchExceptions_ Whether to catch exceptions during withdrawal
    /// @return shares The amount of shares burned/withdrawn
    function _performWithdraw(uint256 finalAmount_, bool catchExceptions_) private returns (uint256 shares) {
        if (catchExceptions_) {
            try ISavingsDai(SDAI).withdraw(finalAmount_, address(this), address(this)) returns (uint256 shares_) {
                shares = shares_;
                emit SparkSupplyFuseExit(VERSION, finalAmount_, shares);
            } catch {
                /// @dev if withdraw failed, continue with the next step
                emit SparkSupplyFuseExitFailed(VERSION, finalAmount_);
            }
        } else {
            shares = ISavingsDai(SDAI).withdraw(finalAmount_, address(this), address(this));
            emit SparkSupplyFuseExit(VERSION, finalAmount_, shares);
        }
        return shares;
    }
}
