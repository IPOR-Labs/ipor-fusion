// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

contract MockTermController {
    mapping(address => bool) public deployedFlag;

    function setIsTermDeployed(address contractAddress_, bool isDeployed_) external {
        deployedFlag[contractAddress_] = isDeployed_;
    }

    function isTermDeployed(address contractAddress) external view returns (bool) {
        return deployedFlag[contractAddress];
    }
}
