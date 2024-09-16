// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IFuseInstantWithdraw} from "../IFuseInstantWithdraw.sol";
import {IComet} from "./ext/IComet.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

struct CompoundV3SupplyFuseEnterData {
    /// @notice asset address to supply
    address asset;
    /// @notice asset amount to supply
    uint256 amount;
}

struct CompoundV3SupplyFuseExitData {
    /// @notice asset address to withdraw
    address asset;
    /// @notice asset amount to withdraw
    uint256 amount;
}

/// @title Fuse for Compound V3 protocol responsible for supplying and withdrawing assets from the Compound V3 protocol based on preconfigured market substrates
/// @dev Substrates in this fuse are the assets that are used in the Compound V3 protocol for a given MARKET_ID
contract CompoundV3SupplyFuse is IFuseCommon, IFuseInstantWithdraw {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    IComet public immutable COMET;
    address public immutable COMPOUND_BASE_TOKEN;

    event CompoundV3SupplyFuseEnter(address version, address asset, address market, uint256 amount);
    event CompoundV3SupplyFuseExit(address version, address asset, address market, uint256 amount);
    event CompoundV3SupplyFuseExitFailed(address version, address asset, address market, uint256 amount);

    error CompoundV3SupplyFuseUnsupportedAsset(string action, address asset);

    constructor(uint256 marketId_, address cometAddress_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        COMET = IComet(cometAddress_);
        COMPOUND_BASE_TOKEN = COMET.baseToken();
    }

    function enter(CompoundV3SupplyFuseEnterData memory data_) external {
        if (data_.amount == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.asset)) {
            revert CompoundV3SupplyFuseUnsupportedAsset("enter", data_.asset);
        }

        ERC20(data_.asset).forceApprove(address(COMET), data_.amount);

        COMET.supply(data_.asset, data_.amount);

        emit CompoundV3SupplyFuseEnter(VERSION, data_.asset, address(COMET), data_.amount);
    }

    function exit(CompoundV3SupplyFuseExitData calldata data_) external {
        _exit(data_);
    }

    /// @dev params[0] - amount in underlying asset, params[1] - asset address
    function instantWithdraw(bytes32[] calldata params_) external override {
        uint256 amount = uint256(params_[0]);

        address asset = PlasmaVaultConfigLib.bytes32ToAddress(params_[1]);

        _exit(CompoundV3SupplyFuseExitData(asset, amount));
    }

    function _exit(CompoundV3SupplyFuseExitData memory data_) internal {
        if (data_.amount == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.asset)) {
            revert CompoundV3SupplyFuseUnsupportedAsset("exit", data_.asset);
        }

        uint256 finalAmount = IporMath.min(data_.amount, _getBalance(data_.asset));

        if (finalAmount == 0) {
            return;
        }

        try COMET.withdraw(data_.asset, finalAmount) {
            emit CompoundV3SupplyFuseExit(VERSION, data_.asset, address(COMET), data_.amount);
        } catch {
            /// @dev if withdraw failed, continue with the next step
            emit CompoundV3SupplyFuseExitFailed(VERSION, data_.asset, address(COMET), data_.amount);
        }
    }

    function _getBalance(address asset_) private view returns (uint256) {
        if (asset_ == COMPOUND_BASE_TOKEN) {
            return COMET.balanceOf(address(this));
        } else {
            return COMET.collateralBalanceOf(address(this), asset_);
        }
    }
}
