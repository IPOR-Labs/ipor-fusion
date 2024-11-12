// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IFuseCommon} from "../IFuse.sol";
import {IFuseInstantWithdraw} from "../IFuseInstantWithdraw.sol";
import {MErc20} from "./ext/MErc20.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

struct MoonwellSupplyFuseEnterData {
    /// @notice asset address to supply
    address asset;
    /// @notice asset amount to supply
    uint256 amount;
}

struct MoonwellSupplyFuseExitData {
    /// @notice asset address to withdraw
    address asset;
    /// @notice asset amount to withdraw
    uint256 amount;
}

/// @dev Fuse for Moonwell protocol responsible for supplying and withdrawing assets from the Moonwell protocol based on preconfigured market substrates
/// @dev Substrates in this fuse are the mTokens that are used in the Moonwell for given asset
contract MoonwellSupplyFuse is IFuseCommon, IFuseInstantWithdraw {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    event MoonwellSupplyEnterFuse(address version, address asset, address market, uint256 amount);
    event MoonwellSupplyExitFuse(address version, address asset, address market, uint256 amount);
    event MoonwellSupplyExitFailed(address version, address asset, address market, uint256 amount);

    error MoonwellSupplyFuseUnsupportedAsset(address asset);
    error MoonwellSupplyFuseMintFailed();

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    function enter(MoonwellSupplyFuseEnterData memory data_) external {
        if (data_.amount == 0) {
            return;
        }

        MErc20 mToken = MErc20(_getMToken(MARKET_ID, data_.asset));

        ERC20(data_.asset).forceApprove(address(mToken), data_.amount);

        uint256 mintResult = mToken.mint(data_.amount);
        if (mintResult != 0) {
            revert MoonwellSupplyFuseMintFailed();
        }

        emit MoonwellSupplyEnterFuse(VERSION, data_.asset, address(mToken), data_.amount);
    }

    function exit(MoonwellSupplyFuseExitData calldata data_) external {
        _exit(data_);
    }

    /// @dev params[0] - amount in underlying asset, params[1] - asset address
    function instantWithdraw(bytes32[] calldata params_) external override {
        uint256 amount = uint256(params_[0]);
        address asset = PlasmaVaultConfigLib.bytes32ToAddress(params_[1]);

        _exit(MoonwellSupplyFuseExitData(asset, amount));
    }

    function _exit(MoonwellSupplyFuseExitData memory data_) internal {
        if (data_.amount == 0) {
            return;
        }

        MErc20 mToken = MErc20(_getMToken(MARKET_ID, data_.asset));

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

    function _getMToken(uint256 marketId_, address asset_) internal view returns (address) {
        bytes32[] memory assetsRaw = PlasmaVaultConfigLib.getMarketSubstrates(marketId_);
        uint256 len = assetsRaw.length;
        if (len == 0) {
            revert MoonwellSupplyFuseUnsupportedAsset(asset_);
        }
        address mToken;
        for (uint256 i; i < len; ++i) {
            mToken = PlasmaVaultConfigLib.bytes32ToAddress(assetsRaw[i]);
            if (MErc20(mToken).underlying() == asset_) {
                return mToken;
            }
        }
        revert MoonwellSupplyFuseUnsupportedAsset(asset_);
    }
}
