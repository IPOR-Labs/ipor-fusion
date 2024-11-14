// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IFuseCommon} from "../IFuse.sol";
import {IFuseInstantWithdraw} from "../IFuseInstantWithdraw.sol";
import {MErc20} from "./ext/MErc20.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {MoonwellHelperLib} from "./MoonwellHelperLib.sol";

/// @notice Data for supplying assets to Moonwell
/// @param asset Asset address to supply
/// @param amount Amount of asset to supply
struct MoonwellSupplyFuseEnterData {
    address asset;
    uint256 amount;
}

/// @notice Data for withdrawing assets from Moonwell
/// @param asset Asset address to withdraw
/// @param amount Amount of asset to withdraw
struct MoonwellSupplyFuseExitData {
    address asset;
    uint256 amount;
}

/// @title MoonwellSupplyFuse
/// @notice Fuse for supplying and withdrawing assets in the Moonwell protocol
/// @dev Handles supplying assets to Moonwell markets and withdrawing supplied positions
/// @dev Substrates in this fuse are the mTokens used in Moonwell for given assets
contract MoonwellSupplyFuse is IFuseCommon, IFuseInstantWithdraw {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;
    using MoonwellHelperLib for uint256;

    /// @notice Version of this contract for tracking
    address public immutable VERSION;

    /// @notice Market ID this fuse is associated with
    uint256 public immutable MARKET_ID;

    event MoonwellSupplyEnterFuse(address version, address asset, address market, uint256 amount);
    event MoonwellSupplyExitFuse(address version, address asset, address market, uint256 amount);
    event MoonwellSupplyExitFailed(address version, address asset, address market, uint256 amount);

    error MoonwellSupplyFuseMintFailed();

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Supply assets to Moonwell
    /// @param data_ Struct containing asset and amount to supply
    function enter(MoonwellSupplyFuseEnterData memory data_) external {
        if (data_.amount == 0) {
            return;
        }

        bytes32[] memory assetsRaw = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);
        MErc20 mToken = MErc20(MoonwellHelperLib.getMToken(assetsRaw, data_.asset));

        uint256 balance = ERC20(data_.asset).balanceOf(address(this));
        uint256 finalAmount = data_.amount > balance ? balance : data_.amount;

        if (finalAmount == 0) {
            return;
        }

        ERC20(data_.asset).forceApprove(address(mToken), finalAmount);

        uint256 mintResult = mToken.mint(finalAmount);
        if (mintResult != 0) {
            revert MoonwellSupplyFuseMintFailed();
        }

        emit MoonwellSupplyEnterFuse(VERSION, data_.asset, address(mToken), finalAmount);
    }

    /// @notice Withdraw assets from Moonwell
    /// @param data_ Struct containing asset and amount to withdraw
    function exit(MoonwellSupplyFuseExitData calldata data_) external {
        _exit(data_);
    }

    /// @notice Handle instant withdrawals
    /// @dev params[0] - amount in underlying asset, params[1] - asset address
    /// @param params_ Array of parameters for withdrawal
    function instantWithdraw(bytes32[] calldata params_) external override {
        uint256 amount = uint256(params_[0]);
        address asset = PlasmaVaultConfigLib.bytes32ToAddress(params_[1]);

        _exit(MoonwellSupplyFuseExitData(asset, amount));
    }

    /// @dev Internal function to handle withdrawals
    /// @param data_ Struct containing withdrawal parameters
    function _exit(MoonwellSupplyFuseExitData memory data_) internal {
        if (data_.amount == 0) {
            return;
        }

        bytes32[] memory assetsRaw = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);
        MErc20 mToken = MErc20(MoonwellHelperLib.getMToken(assetsRaw, data_.asset));

        uint256 balance = mToken.balanceOfUnderlying(address(this));
        uint256 amountToWithdraw = data_.amount > balance ? balance : data_.amount;

        if (amountToWithdraw == 0) {
            return;
        }

        try mToken.redeemUnderlying(amountToWithdraw) returns (uint256 redeemResult) {
            if (redeemResult != 0) {
                emit MoonwellSupplyExitFuse(VERSION, data_.asset, address(mToken), redeemResult);
            } else {
                emit MoonwellSupplyExitFailed(VERSION, data_.asset, address(mToken), amountToWithdraw);
            }
        } catch {
            /// @dev if withdraw failed, continue with the next step
            emit MoonwellSupplyExitFailed(VERSION, data_.asset, address(mToken), amountToWithdraw);
        }
    }
}
