// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {CompoundV3SupplyConnector} from "../../../contracts/connectors/compound_v3/CompoundV3SupplyConnector.sol";
import {MarketConfigurationLib} from "../../../contracts/libraries/MarketConfigurationLib.sol";

contract CompoundV3SupplyConnectorMock {
    using Address for address;

    CompoundV3SupplyConnector public connector;

    constructor(address connectorInput) {
        connector = CompoundV3SupplyConnector(connectorInput);
    }
    //solhint-disable-next-line
    function enter(bytes calldata data) external returns (bytes memory executionStatus) {
        return address(connector).functionDelegateCall(msg.data);
    }

    function enter(
        //solhint-disable-next-line
        CompoundV3SupplyConnector.CompoundV3SupplyConnectorData memory data
    ) external returns (bytes memory executionStatus) {
        return address(connector).functionDelegateCall(msg.data);
    }

    //solhint-disable-next-line
    function exit(bytes calldata data) external returns (bytes memory executionStatus) {
        return address(connector).functionDelegateCall(msg.data);
    }

    function exit(
        //solhint-disable-next-line
        CompoundV3SupplyConnector.CompoundV3SupplyConnectorData memory data
    ) external returns (bytes memory executionStatus) {
        return address(connector).functionDelegateCall(msg.data);
    }

    function grantAssetsToMarket(uint256 marketId, address[] calldata assets) external {
        MarketConfigurationLib.grandSubstratesAsAssetsToMarket(marketId, assets);
    }
}
