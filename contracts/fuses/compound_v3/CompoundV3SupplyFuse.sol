// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IFuse} from "../IFuse.sol";
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

contract CompoundV3SupplyFuse is IFuse, IFuseInstantWithdraw {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    IComet public immutable COMET;
    address public immutable COMPOUND_BASE_TOKEN;

    event CompoundV3SupplyEnterFuse(address version, address asset, address market, uint256 amount);
    event CompoundV3SupplyExitFuse(address version, address asset, address market, uint256 amount);

    error CompoundV3SupplyFuseUnsupportedAsset(string action, address asset);

    constructor(uint256 marketId_, address cometAddress_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        COMET = IComet(cometAddress_);
        COMPOUND_BASE_TOKEN = COMET.baseToken();
    }

    function enter(bytes calldata data_) external override {
        _enter(abi.decode(data_, (CompoundV3SupplyFuseEnterData)));
    }

    /// @dev technical method to generate ABI
    function enter(CompoundV3SupplyFuseEnterData memory data_) external {
        _enter(data_);
    }

    function exit(bytes calldata data_) external override {
        _exit(abi.decode(data_, (CompoundV3SupplyFuseExitData)));
    }

    /// @dev technical method to generate ABI
    function exit(CompoundV3SupplyFuseExitData calldata data_) external {
        _exit(data_);
    }

    /// @dev params[0] - amount in underlying asset, params[1] - asset address
    function instantWithdraw(bytes32[] calldata params_) external override {
        uint256 amount = uint256(params_[0]);
        address asset = PlasmaVaultConfigLib.bytes32ToAddress(params_[1]);

        _exit(CompoundV3SupplyFuseExitData(asset, amount));
    }

    function _enter(CompoundV3SupplyFuseEnterData memory data_) internal {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.asset)) {
            revert CompoundV3SupplyFuseUnsupportedAsset("enter", data_.asset);
        }

        ERC20(data_.asset).forceApprove(address(COMET), data_.amount);

        COMET.supply(data_.asset, data_.amount);

        emit CompoundV3SupplyEnterFuse(VERSION, data_.asset, address(COMET), data_.amount);
    }

    function _exit(CompoundV3SupplyFuseExitData memory data_) internal {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.asset)) {
            revert CompoundV3SupplyFuseUnsupportedAsset("exit", data_.asset);
        }

        COMET.withdraw(data_.asset, IporMath.min(data_.amount, _getBalance(data_.asset)));

        emit CompoundV3SupplyExitFuse(VERSION, data_.asset, address(COMET), data_.amount);
    }

    function _getBalance(address asset_) private view returns (uint256) {
        if (asset_ == COMPOUND_BASE_TOKEN) {
            return COMET.balanceOf(address(this));
        } else {
            return COMET.collateralBalanceOf(address(this), asset_);
        }
    }
}
