// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;
import {IConnector} from "../../contracts/connectors/IConnector.sol";

contract DoNothingConnector is IConnector {
    uint256 public immutable MARKET_ID;

    struct DoNothingConnectorData {
        // token to supply
        address token;
    }

    event DoNothingConnector(string action, address token);

    constructor(uint256 marketIdInput) {
        MARKET_ID = marketIdInput;
    }

    function enter(bytes calldata data) external returns (bytes memory executionStatus) {
        DoNothingConnectorData memory structData = abi.decode(data, (DoNothingConnectorData));
        return _enter(structData);
    }

    function enter(DoNothingConnectorData memory data) external returns (bytes memory executionStatus) {
        return _enter(data);
    }

    function _enter(DoNothingConnectorData memory data) internal returns (bytes memory executionStatus) {
        emit DoNothingConnector("enter", data.token);
    }

    function exit(bytes calldata data) external returns (bytes memory executionStatus) {
        DoNothingConnectorData memory data = abi.decode(data, (DoNothingConnectorData));
        return _exit(data);
    }

    function exit(DoNothingConnectorData calldata data) external returns (bytes memory executionStatus) {
        return _exit(data);
    }

    function _exit(DoNothingConnectorData memory data) internal returns (bytes memory executionStatus) {
        emit DoNothingConnector("exit", data.token);
    }
}
