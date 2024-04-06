// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Erc4626SupplyConnector} from "../../../contracts/connectors/erc4626/Erc4626SupplyConnector.sol";
import {MarketConfigurationLib} from "../../../contracts/libraries/MarketConfigurationLib.sol";

contract VaultERC4626Mock {
    using Address for address;

    Erc4626SupplyConnector public connector;

    constructor(address connectorInput) {
        connector = Erc4626SupplyConnector(connectorInput);
    }
    //solhint-disable-next-line
    function enter(bytes calldata data) external returns (bytes memory executionStatus) {
        return address(connector).functionDelegateCall(msg.data);
    }

    function enter(
        //solhint-disable-next-line
        Erc4626SupplyConnector.Erc4626SupplyConnectorData memory data
    ) external returns (bytes memory executionStatus) {
        return address(connector).functionDelegateCall(msg.data);
    }

    //solhint-disable-next-line
    function exit(bytes calldata data) external returns (bytes memory executionStatus) {
        return address(connector).functionDelegateCall(msg.data);
    }

    function exit(
        //solhint-disable-next-line
        Erc4626SupplyConnector.Erc4626SupplyConnectorData memory data
    ) external returns (bytes memory executionStatus) {
        return address(connector).functionDelegateCall(msg.data);
    }

    function grantAssetsToMarket(uint256 marketId, address[] calldata assets) external {
        MarketConfigurationLib.grandSubstratesAsAssetsToMarket(marketId, assets);
    }
}
