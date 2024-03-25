// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {AssetsToMarketLib} from "../../../contracts/libraries/AssetsToMarketLib.sol";
import {AaveV3SupplyConnector} from "../../../contracts/connectors/aave_v3/AaveV3SupplyConnector.sol";

contract VaultMock {
    using Address for address;

    AaveV3SupplyConnector public connector;

    constructor(address connectorInput) {
        connector = AaveV3SupplyConnector(connectorInput);
    }
    //solhint-disable-next-line
    function enter(bytes calldata data) external returns (bytes memory executionStatus) {
        return address(connector).functionDelegateCall(msg.data);
    }

    function enter(
        //solhint-disable-next-line
        AaveV3SupplyConnector.AaveV3SupplyConnectorData memory data
    ) external returns (bytes memory executionStatus) {
        return address(connector).functionDelegateCall(msg.data);
    }

    //solhint-disable-next-line
    function exit(bytes calldata data) external returns (bytes memory executionStatus) {
        return address(connector).functionDelegateCall(msg.data);
    }

    function exit(
        //solhint-disable-next-line
        AaveV3SupplyConnector.AaveV3SupplyConnectorData memory data
    ) external returns (bytes memory executionStatus) {
        return address(connector).functionDelegateCall(msg.data);
    }

    function grantAssetsToMarket(uint256 marketId, address[] calldata assets) external {
        AssetsToMarketLib.grantAssetsToMarket(marketId, assets);
    }

    function revokeAssetsFromMarket(uint256 marketId, address[] calldata assets) external {
        AssetsToMarketLib.revokeAssetsFromMarket(marketId, assets);
    }
}
