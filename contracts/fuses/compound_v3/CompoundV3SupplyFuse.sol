// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {IFuse} from "../IFuse.sol";
import {IApproveERC20} from "../IApproveERC20.sol";
import {IComet} from "./IComet.sol";
import {MarketConfigurationLib} from "../../libraries/MarketConfigurationLib.sol";

contract CompoundV3SupplyFuse is IFuse {
    using SafeCast for uint256;

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

    IComet public immutable COMET;
    uint256 public immutable MARKET_ID;
    address public immutable VERSION;

    event CompoundV3SupplyEnterFuse(address version, address asset, address market, uint256 amount);
    event CompoundV3SupplyExitFuse(address version, address asset, address market, uint256 amount);

    error CompoundV3SupplyFuseUnsupportedAsset(string action, address asset, string errorCode);

    constructor(address cometAddressInput, uint256 marketIdInput) {
        COMET = IComet(cometAddressInput);
        MARKET_ID = marketIdInput;
        VERSION = address(this);
    }

    function enter(bytes calldata data) external {
        _enter(abi.decode(data, (CompoundV3SupplyFuseEnterData)));
    }

    function enter(CompoundV3SupplyFuseEnterData memory data) external {
        _enter(data);
    }

    function exit(bytes calldata data) external {
        _exit(abi.decode(data, (CompoundV3SupplyFuseExitData)));
    }

    function exit(CompoundV3SupplyFuseExitData calldata data) external {
        _exit(data);
    }

    /// @dev params[0] - amount in underlying asset, params[1] - asset address
    function withdraw(bytes32[] calldata params) external override {
        uint256 amount = uint256(params[0]);
        address asset = MarketConfigurationLib.bytes32ToAddress(params[1]);

        _exit(CompoundV3SupplyFuseExitData(asset, amount));
    }

    function _enter(CompoundV3SupplyFuseEnterData memory data) internal {
        if (!MarketConfigurationLib.isSubstrateAsAssetGranted(MARKET_ID, data.asset)) {
            revert CompoundV3SupplyFuseUnsupportedAsset("enter", data.asset, Errors.UNSUPPORTED_ASSET);
        }

        IApproveERC20(data.asset).approve(address(COMET), data.amount);

        COMET.supply(data.asset, data.amount);

        emit CompoundV3SupplyEnterFuse(VERSION, data.asset, address(COMET), data.amount);
    }

    function _exit(CompoundV3SupplyFuseExitData memory data) internal {
        if (!MarketConfigurationLib.isSubstrateAsAssetGranted(MARKET_ID, data.asset)) {
            revert CompoundV3SupplyFuseUnsupportedAsset("exit", data.asset, Errors.UNSUPPORTED_ASSET);
        }

        COMET.withdraw(data.asset, data.amount);

        emit CompoundV3SupplyExitFuse(VERSION, data.asset, address(COMET), data.amount);
    }
}
