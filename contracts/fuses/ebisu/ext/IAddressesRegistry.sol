// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./IActivePool.sol";
import "./IBorrowerOperations.sol";
import "./IPriceFeed.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "./ITroveManager.sol";

interface IAddressesRegistry {
    function CCR() external view returns (uint256);
    function SCR() external view returns (uint256);
    function MCR() external view returns (uint256);
    function BCR() external view returns (uint256);
    function LIQUIDATION_PENALTY_SP() external view returns (uint256);
    function LIQUIDATION_PENALTY_REDISTRIBUTION() external view returns (uint256);
    function branchCollGasCompensationCap() external view returns (uint256);

    function collToken() external view returns (IERC20Metadata);
    function boldToken() external view returns (IERC20Metadata);
    function borrowerOperations() external view returns (IBorrowerOperations);
    function troveManager() external view returns (ITroveManager);
    function priceFeed() external view returns (IPriceFeed);
    function activePool() external view returns (IActivePool);
    function gasPoolAddress() external view returns (address);
    function borrowerOperationsHelper() external view returns (address);
}
