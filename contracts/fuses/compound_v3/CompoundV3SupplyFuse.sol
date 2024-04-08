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

    struct CompoundV3SupplyFuseData {
        // token to supply
        address asset;
        // max amount to supply
        uint256 amount;
    }

    IComet public immutable COMET;
    uint256 public immutable MARKET_ID;
    address public immutable VERSION;

    event CompoundV3SupplyFuse(address version, string action, address asset, address market, uint256 amount);

    error CompoundV3SupplyFuseUnsupportedAsset(string action, address asset, string errorCode);

    constructor(address cometAddressInput, uint256 marketIdInput) {
        COMET = IComet(cometAddressInput);
        MARKET_ID = marketIdInput;
        VERSION = address(this);
    }

    function enter(bytes calldata data) external {
        CompoundV3SupplyFuseData memory data = abi.decode(data, (CompoundV3SupplyFuseData));
        _enter(data);
    }

    function enter(CompoundV3SupplyFuseData memory data) external {
        _enter(data);
    }

    function _enter(CompoundV3SupplyFuseData memory data) internal {
        if (!MarketConfigurationLib.isSubstrateAsAssetGranted(MARKET_ID, data.asset)) {
            revert CompoundV3SupplyFuseUnsupportedAsset("enter", data.asset, Errors.UNSUPPORTED_ASSET);
        }

        IApproveERC20(data.asset).approve(address(COMET), data.amount);

        COMET.supply(data.asset, data.amount);

        emit CompoundV3SupplyFuse(VERSION, "enter", data.asset, address(COMET), data.amount);
    }

    function exit(bytes calldata data) external {
        CompoundV3SupplyFuseData memory data = abi.decode(data, (CompoundV3SupplyFuseData));
        _exit(data);
    }

    function exit(CompoundV3SupplyFuseData calldata data) external {
        _exit(data);
    }

    function _exit(CompoundV3SupplyFuseData memory data) internal {
        if (!MarketConfigurationLib.isSubstrateAsAssetGranted(MARKET_ID, data.asset)) {
            revert CompoundV3SupplyFuseUnsupportedAsset("exit", data.asset, Errors.UNSUPPORTED_ASSET);
        }

        COMET.withdraw(data.asset, data.amount);

        emit CompoundV3SupplyFuse(VERSION, "exit", data.asset, address(COMET), data.amount);
    }
}
