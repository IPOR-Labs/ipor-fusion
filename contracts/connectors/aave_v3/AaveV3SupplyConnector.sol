// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {IPool} from "../../vaults/interfaces/IPool.sol";
import {IConnector} from "../IConnector.sol";
import {IApproveERC20} from "../IApproveERC20.sol";
import {MarketConfigurationLib} from "../../libraries/MarketConfigurationLib.sol";

contract AaveV3SupplyConnector is IConnector {
    struct AaveV3SupplyConnectorData {
        // token to supply
        address token;
        // max amount to supply
        uint256 amount;
        // user eMode category if pass value bigger than 255 is ignored and not set
        uint256 userEModeCategoryId;
    }

    event AaveV3SupplyConnector(
        string action,
        uint256 version,
        address token,
        uint256 amount,
        uint256 userEModeCategoryId
    );

    error AaveV3SupplyConnectorUnsupportedAsset(string action, address token, string errorCode);

    using SafeCast for uint256;

    // Ethereum Mainnet 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2
    IPool public immutable AAVE_POOL;
    uint256 public immutable MARKET_ID;
    uint256 public constant VERSION = 1;

    constructor(address aavePoolInput, uint256 marketIdInput) {
        AAVE_POOL = IPool(aavePoolInput);
        MARKET_ID = marketIdInput;
    }

    function enter(bytes calldata data) external returns (bytes memory executionStatus) {
        AaveV3SupplyConnectorData memory structData = abi.decode(data, (AaveV3SupplyConnectorData));
        return _enter(structData);
    }

    function enter(AaveV3SupplyConnectorData memory data) external returns (bytes memory executionStatus) {
        return _enter(data);
    }

    function _enter(AaveV3SupplyConnectorData memory data) internal returns (bytes memory executionStatus) {
        if (!MarketConfigurationLib.isSubstrateAsAssetGranted(MARKET_ID, data.token)) {
            revert AaveV3SupplyConnectorUnsupportedAsset("enter", data.token, Errors.NOT_SUPPORTED_TOKEN);
        }

        IApproveERC20(data.token).approve(address(AAVE_POOL), data.amount);

        AAVE_POOL.supply(data.token, data.amount, address(this), 0);

        if (data.userEModeCategoryId <= type(uint8).max) {
            AAVE_POOL.setUserEMode(data.userEModeCategoryId.toUint8());
        }
        emit AaveV3SupplyConnector("enter", VERSION, data.token, data.amount, data.userEModeCategoryId);
    }

    function exit(bytes calldata data) external returns (bytes memory executionStatus) {
        AaveV3SupplyConnectorData memory data = abi.decode(data, (AaveV3SupplyConnectorData));
        return _exit(data);
    }

    function exit(AaveV3SupplyConnectorData calldata data) external returns (bytes memory executionStatus) {
        return _exit(data);
    }

    function _exit(AaveV3SupplyConnectorData memory data) internal returns (bytes memory executionStatus) {
        if (!MarketConfigurationLib.isSubstrateAsAssetGranted(MARKET_ID, data.token)) {
            revert AaveV3SupplyConnectorUnsupportedAsset("exit", data.token, Errors.NOT_SUPPORTED_TOKEN);
        }
        uint256 withDrawAmount = AAVE_POOL.withdraw(data.token, data.amount, address(this));
        emit AaveV3SupplyConnector("exit", VERSION, data.token, withDrawAmount, data.userEModeCategoryId);
    }
}
