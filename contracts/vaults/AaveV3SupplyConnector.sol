// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPool} from "./interfaces/IPool.sol";
import {IConnector} from "./IConnector.sol";

contract AaveV3SupplyConnector is IConnector {
    struct SupplyData {
        address token;
        uint256 amount;
    }

    IPool public constant AAVE_POOL = IPool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);

    function enter(bytes calldata data) external returns (uint256 executionStatus) {
        SupplyData memory supplyData = abi.decode(data, (SupplyData));

        IERC20(supplyData.token).approve(address(AAVE_POOL), supplyData.amount);

        AAVE_POOL.supply(supplyData.token, supplyData.amount, address(this), 0);
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

    function marketId() external view returns (uint256) {
        return 0;
    }

    function marketName() external view returns (string memory) {
        return "";
    }
}
