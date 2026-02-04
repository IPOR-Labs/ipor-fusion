// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

/**
 * @title OlympixUnitTest
 * @notice Base contract for Olympix-generated unit tests
 * @dev All Olympix-generated tests should inherit from this contract
 */
abstract contract OlympixUnitTest is Test {
    string internal _contractName;

    constructor(string memory contractName_) {
        _contractName = contractName_;
    }

    function setUp() public virtual {}
}
