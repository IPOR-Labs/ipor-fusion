// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IFuseCommon} from "../IFuse.sol";
import {IFuseInstantWithdraw} from "../IFuseInstantWithdraw.sol";
import {CErc20} from "./ext/CErc20.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

struct CompoundV2SupplyFuseEnterData {
    /// @notis asset address to supply
    address asset;
    /// @notice asset amount to supply
    uint256 amount;
}

struct CompoundV2SupplyFuseExitData {
    /// @notice asset address to withdraw
    address asset;
    /// @notice asset amount to withdraw
    uint256 amount;
}

/// @dev Fuse for Compound V2 protocol responsible for supplying and withdrawing assets from the Compound V2 protocol based on preconfigured market substrates
/// @dev Substrates in this fuse are the cTokens that are used in the Compound V2 protocol for a given MARKET_ID
contract CompoundV2SupplyFuse is IFuseCommon, IFuseInstantWithdraw {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    event CompoundV2SupplyEnterFuse(address version, address asset, address market, uint256 amount);
    event CompoundV2SupplyExitFuse(address version, address asset, address market, uint256 amount);
    event CompoundV2SupplyExitFailed(address version, address asset, address market, uint256 amount);

    error CompoundV2SupplyFuseUnsupportedAsset(address asset);

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    function enter(CompoundV2SupplyFuseEnterData memory data_) external {
        if (data_.amount == 0) {
            return;
        }

        CErc20 cToken = CErc20(_getCToken(MARKET_ID, data_.asset));

        ERC20(data_.asset).forceApprove(address(cToken), data_.amount);

        cToken.mint(data_.amount);

        emit CompoundV2SupplyEnterFuse(VERSION, data_.asset, address(cToken), data_.amount);
    }

    function exit(CompoundV2SupplyFuseExitData calldata data_) external {
        _exit(data_);
    }

    /// @dev params[0] - amount in underlying asset, params[1] - asset address
    function instantWithdraw(bytes32[] calldata params_) external override {
        uint256 amount = uint256(params_[0]);

        address asset = PlasmaVaultConfigLib.bytes32ToAddress(params_[1]);

        _exit(CompoundV2SupplyFuseExitData(asset, amount));
    }

    function _exit(CompoundV2SupplyFuseExitData memory data_) internal {
        if (data_.amount == 0) {
            return;
        }

        CErc20 cToken = CErc20(_getCToken(MARKET_ID, data_.asset));

        uint256 balance = cToken.balanceOfUnderlying(address(this));
        uint256 amountToWithdraw = data_.amount > balance ? balance : data_.amount;

        if (amountToWithdraw == 0) {
            return;
        }

        try cToken.redeemUnderlying(amountToWithdraw) returns (uint256 successFlag) {
            if (successFlag == 0) {
                emit CompoundV2SupplyExitFuse(VERSION, data_.asset, address(cToken), amountToWithdraw);
            } else {
                emit CompoundV2SupplyExitFailed(VERSION, data_.asset, address(cToken), amountToWithdraw);
            }
        } catch {
            /// @dev if withdraw failed, continue with the next step
            emit CompoundV2SupplyExitFailed(VERSION, data_.asset, address(cToken), amountToWithdraw);
        }
    }

    function _getCToken(uint256 marketId_, address asset_) internal view returns (address) {
        bytes32[] memory assetsRaw = PlasmaVaultConfigLib.getMarketSubstrates(marketId_);
        uint256 len = assetsRaw.length;
        if (len == 0) {
            revert CompoundV2SupplyFuseUnsupportedAsset(asset_);
        }
        for (uint256 i; i < len; ++i) {
            address cToken = PlasmaVaultConfigLib.bytes32ToAddress(assetsRaw[i]);
            if (CErc20(cToken).underlying() == asset_) {
                return cToken;
            }
        }
        revert CompoundV2SupplyFuseUnsupportedAsset(asset_);
    }
}
