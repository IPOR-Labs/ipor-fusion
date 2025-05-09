// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./IPriceFeed.sol";
import {IBorrowerOperations} from "./IBorrowerOperations.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IActivePool} from "./IActivePool.sol";
import {ITroveManager} from "./ITroveManager.sol";

interface IAddressesRegistry {
    struct AddressVars {
        IPriceFeed priceFeed;
    }

    function CCR() external returns (uint256);

    function SCR() external returns (uint256);

    function MCR() external view returns (uint256);

    function BCR() external returns (uint256);

    function LIQUIDATION_PENALTY_SP() external returns (uint256);

    function LIQUIDATION_PENALTY_REDISTRIBUTION() external returns (uint256);

    function boldToken() external view returns (address);

    function collToken() external view returns (IERC20Metadata);

    function priceFeed() external view returns (IPriceFeed);

    function borrowerOperations() external view returns (IBorrowerOperations);

    function activePool() external view returns (IActivePool);

    function troveManager() external view returns (ITroveManager);

    function setAddresses(AddressVars memory _vars) external;
}
