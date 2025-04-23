// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./IPriceFeed.sol";
import {IBorrowerOperations} from "./IBorrowerOperations.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";

interface IAddressesRegistry {
    struct AddressVars {
        IPriceFeed priceFeed;
    }

    function CCR() external returns (uint256);

    function SCR() external returns (uint256);

    function MCR() external returns (uint256);

    function BCR() external returns (uint256);

    function LIQUIDATION_PENALTY_SP() external returns (uint256);

    function LIQUIDATION_PENALTY_REDISTRIBUTION() external returns (uint256);

    function collToken() external view returns (IERC20Metadata);

    function priceFeed() external view returns (IPriceFeed);

    function borrowerOperations() external view returns (IBorrowerOperations);

    function setAddresses(AddressVars memory _vars) external;
}
