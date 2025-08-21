// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IActivePool} from "./IActivePool.sol";
import {IBorrowerOperations} from "./IBorrowerOperations.sol";
import {ITroveManager} from "./ITroveManager.sol";

interface IAddressesRegistry {
    function MCR() external view returns (uint256);

    function stabilityPool() external view returns (address);

    function collToken() external view returns (address);

    function priceFeed() external view returns (address);

    function boldToken() external view returns (address);

    function activePool() external view returns (IActivePool);

    function borrowerOperations() external view returns (IBorrowerOperations);

    function troveManager() external view returns (ITroveManager);
}
