// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;
import "forge-std/console2.sol";
import "./interfaces/IPool.sol";
import "./IConnector.sol";

contract AaveV3BorrowConnector is IConnector {
    uint256 public immutable override marketId;
    bytes32 internal immutable _marketName;

    struct BorrowData {
        address token;
        uint256 amount;
    }

    IPool public constant aavePool =
        IPool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);

    constructor(uint256 inputMarketId, bytes32 inputMarketName) {
        marketId = inputMarketId;
        _marketName = inputMarketName; //string(abi.encodePacked(inputMarketName));
    }

    function enter(
        bytes calldata data
    ) external returns (uint256 executionStatus) {
        console2.log("AaveV3BorrowConnector: ENTER...");
        BorrowData memory borrowData = abi.decode(data, (BorrowData));

        aavePool.borrow(
            borrowData.token,
            borrowData.amount,
            2,
            0,
            address(this)
        );

        console2.log("AaveV3BorrowConnector: END.");
    }

    function exit(
        bytes calldata data
    ) external returns (uint256 executionStatus) {
        //TODO: implement
        revert("AaveV3SupplyConnector: exit not supported");
    }

    function getSupportedAssets()
        external
        view
        returns (address[] memory assets)
    {
        return new address[](0);
    }

    function isSupportedAsset(address asset) external view returns (bool) {
        return true;
    }

    function marketName() external view returns (string memory) {
        return string(abi.encodePacked(_marketName));
    }
}
