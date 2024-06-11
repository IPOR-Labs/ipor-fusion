// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {Address} from "@fusion/@openzeppelin/contracts/utils/Address.sol";
import {SparkSupplyFuse, SparkSupplyFuseEnterData, SparkSupplyFuseExitData} from "../../../contracts/fuses/spark/SparkSupplyFuse.sol";

contract VaultSparkMock {
    using Address for address;

    SparkSupplyFuse public fuse;
    address public sparkBalanceFuse;

    constructor(address fuseInput, address sparkBalanceFuseInput) {
        fuse = SparkSupplyFuse(fuseInput);
        sparkBalanceFuse = sparkBalanceFuseInput;
    }
    //solhint-disable-next-line
    function enter(bytes calldata data) external returns (bytes memory executionStatus) {
        return address(fuse).functionDelegateCall(msg.data);
    }

    function enter(
        //solhint-disable-next-line
        SparkSupplyFuseEnterData memory data
    ) external returns (bytes memory executionStatus) {
        return address(fuse).functionDelegateCall(msg.data);
    }

    //solhint-disable-next-line
    function exit(bytes calldata data) external returns (bytes memory executionStatus) {
        return address(fuse).functionDelegateCall(msg.data);
    }

    function exit(
        //solhint-disable-next-line
        SparkSupplyFuseExitData memory data
    ) external returns (bytes memory executionStatus) {
        return address(fuse).functionDelegateCall(msg.data);
    }

    //solhint-disable-next-line
    function balanceOf(address plasmaVault) external returns (uint256) {
        return abi.decode(sparkBalanceFuse.functionDelegateCall(msg.data), (uint256));
    }
}
