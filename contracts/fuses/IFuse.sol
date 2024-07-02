// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {IFuseCommon} from "./IFuseCommon.sol";

interface IFuse is IFuseCommon {
    function enter(bytes calldata data) external;

    function exit(bytes calldata data) external;
}
