// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {IConnector} from "../IConnector.sol";
import {IApproveERC20} from "../IApproveERC20.sol";
import {IComet} from "./IComet.sol";
import {MarketConfigurationLib} from "../../libraries/MarketConfigurationLib.sol";

contract CompoundV3SupplyConnector is IConnector {
    struct CompoundV3SupplyConnectorData {
        // token to supply
        address token;
        // max amount to supply
        uint256 amount;
    }

    event CompoundV3SupplyConnector(string action, uint256 version, address tokenIn, address market, uint256 amount);

    error CompoundV3SupplyConnectorUnsupportedAsset(string action, address token, string errorCode);

    using SafeCast for uint256;

    IComet public immutable COMET;
    uint256 public immutable MARKET_ID;
    uint256 public constant VERSION = 1;

    constructor(address cometAddressInput, uint256 marketIdInput) {
        COMET = IComet(cometAddressInput);
        MARKET_ID = marketIdInput;
    }

    function enter(bytes calldata data) external returns (ExecutionStatus memory executionStatus) {
        CompoundV3SupplyConnectorData memory data = abi.decode(data, (CompoundV3SupplyConnectorData));
        return _enter(data);
    }

    function enter(
        CompoundV3SupplyConnectorData memory data
    ) external returns (ExecutionStatus memory executionStatus) {
        return _enter(data);
    }

    function _enter(
        CompoundV3SupplyConnectorData memory data
    ) internal returns (ExecutionStatus memory executionStatus) {
        if (!MarketConfigurationLib.isSubstrateAsAssetGranted(MARKET_ID, data.token)) {
            revert CompoundV3SupplyConnectorUnsupportedAsset("enter", data.token, Errors.NOT_SUPPORTED_TOKEN);
        }

        IApproveERC20(data.token).approve(address(COMET), data.amount);

        COMET.supply(data.token, data.amount);

        emit CompoundV3SupplyConnector("enter", VERSION, data.token, address(COMET), data.amount);

        address[] memory assets = new address[](1);
        assets[0] = data.token;
        return ExecutionStatus(1, assets);
    }

    function exit(bytes calldata data) external returns (ExecutionStatus memory executionStatus) {
        CompoundV3SupplyConnectorData memory data = abi.decode(data, (CompoundV3SupplyConnectorData));
        return _exit(data);
    }

    function exit(
        CompoundV3SupplyConnectorData calldata data
    ) external returns (ExecutionStatus memory executionStatus) {
        return _exit(data);
    }

    function _exit(
        CompoundV3SupplyConnectorData memory data
    ) internal returns (ExecutionStatus memory executionStatus) {
        if (!MarketConfigurationLib.isSubstrateAsAssetGranted(MARKET_ID, data.token)) {
            revert CompoundV3SupplyConnectorUnsupportedAsset("exit", data.token, Errors.NOT_SUPPORTED_TOKEN);
        }
        COMET.withdraw(data.token, data.amount);
        emit CompoundV3SupplyConnector("exit", VERSION, data.token, address(COMET), data.amount);

        address[] memory assets = new address[](1);
        assets[0] = data.token;
        return ExecutionStatus(1, assets);
    }
}
