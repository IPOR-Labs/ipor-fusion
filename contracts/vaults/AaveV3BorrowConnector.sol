// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {IPool} from "./interfaces/IPool.sol";
import {IConnector} from "./IConnector.sol";

contract AaveV3BorrowConnector is IConnector {
    uint256 public immutable override MARKET_ID;
    bytes32 internal immutable _MARKET_NAME;

    struct BorrowData {
        address token;
        uint256 amount;
    }

    IPool public constant AAVE_POOL = IPool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);

    constructor(uint256 inputMarketId, bytes32 inputMarketName) {
        MARKET_ID = inputMarketId;
        _MARKET_NAME = inputMarketName; //string(abi.encodePacked(inputMarketName));
    }

    function enter(bytes calldata data) external returns (uint256 executionStatus) {
        BorrowData memory borrowData = abi.decode(data, (BorrowData));

        AAVE_POOL.borrow(borrowData.token, borrowData.amount, 2, 0, address(this));
    }

    // todo remove solhint disable
    //solhint-disable-next-line
    function exit(bytes calldata data) external returns (uint256 executionStatus) {
        //TODO: implement
        // todo remove solhint disable
        //solhint-disable-next-line
        revert("AaveV3SupplyConnector: exit not supported");
    }

    function getSupportedAssets() external view returns (address[] memory assets) {
        return new address[](0);
    }

    // todo remove solhint disable
    //solhint-disable-next-line
    function isSupportedAsset(address asset) external view returns (bool) {
        return true;
    }

    function marketName() external view returns (string memory) {
        return string(abi.encodePacked(_MARKET_NAME));
    }
}
