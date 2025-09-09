// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IAccountant} from "./IAccountant.sol";

interface IRewardVault {
    /// @notice Accountant tracks user balances and main protocol rewards
    // solhint-disable-next-line func-name-mixedcase
    function ACCOUNTANT() external view returns (IAccountant accountant);

    /// @notice Claims rewards for multiple tokens in a single transaction
    /// @dev Updates reward state and transfers claimed rewards to the receiver
    /// @param tokens Array of reward token addresses to claim
    /// @param receiver Address to receive the claimed rewards (defaults to msg.sender if zero)
    /// @return amounts Array of amounts claimed for each token, in the same order as input tokens
    function claim(address[] calldata tokens, address receiver) external returns (uint256[] memory amounts);

    /// @notice Retrieves the gauge address from clone arguments
    /// @dev Uses assembly to read from clone initialization data
    /// @return gauge The gauge contract address
    /// @custom:reverts CloneArgsNotFound if clone is incorrectly initialized
    function gauge() external view returns (address gauge);
}
