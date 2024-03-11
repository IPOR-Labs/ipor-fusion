// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;
import "forge-std/console2.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IPool.sol";
import "./IConnector.sol";

contract AaveV3SupplyConnector is IConnector {

    struct SupplyData {
        address token;
        uint256 amount;
    }

    IPool public constant aavePool = IPool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);

    function enter(bytes calldata data) external returns (uint256 executionStatus) {
        console2.log("AaveV3SupplyConnector: ENTER...");
        (SupplyData memory supplyData) = abi.decode(data, (SupplyData));

        IERC20(supplyData.token).approve(address(aavePool), supplyData.amount);

        aavePool.supply(supplyData.token, supplyData.amount, address(this), 0);
        console2.log("AaveV3SupplyConnector: END.");

    }

    function exit(bytes calldata data) external returns (uint256 executionStatus) {
        //TODO: implement
        revert("AaveV3SupplyConnector: exit not supported");
    }
}