// SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

import "./IPriceFeed.sol";

// Common interface for the Borrower Operations.
interface IBorrowerOperations {
    function CCR() external view returns (uint256);

    function MCR() external view returns (uint256);

    function SCR() external view returns (uint256);

    function openTrove(
        address _owner,
        uint256 _ownerIndex,
        uint256 _ETHAmount,
        uint256 _boldAmount,
        uint256 _upperHint,
        uint256 _lowerHint,
        uint256 _annualInterestRate,
        uint256 _maxUpfrontFee,
        address _addManager,
        address _removeManager,
        address _receiver
    ) external returns (uint256);

    function closeTrove(uint256 _troveId) external;
}