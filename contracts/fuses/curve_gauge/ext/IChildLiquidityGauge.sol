// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

/**
 * @dev address on Arbitrum Mainnet 0xbdbb71914ddb650f96449b54d2ca15132be56aca
 * @dev https://vscode.blockscan.com/arbitrum-one/0xbdbb71914ddb650f96449b54d2ca15132be56aca
 */

interface IChildLiquidityGauge {
    /**
     * @notice Deposit `_value` LP tokens
     * @param _value Number of tokens to deposit
     * @param _user The account to send gauge tokens to (defaults msg.sender)
     * @param _claim_rewards (defaults to False)
     */
    function deposit(uint256 _value, address _user, bool _claim_rewards) external;

    /**
     * @notice Withdraw `_value` LP tokens
     * @param _value Number of tokens to withdraw
     * @param _user The account to send gauge tokens to (defaults to msg.sender)
     * @param _claim_rewards (defaults to False)
     */
    function withdraw(uint256 _value, address _user, bool _claim_rewards) external;

    /**
     * @notice Claim available reward tokens for `_addr`
     * @param _addr Address to claim for
     * @param _receiver Address to transfer rewards to - if set to ZERO_ADDRESS, uses the default reward receiver for the caller
     */
    function claim_rewards(address _addr, address _receiver) external;

    /**
     * @notice LP token being staked (deposited into the gauge)
     */
    function lp_token() external returns (address);
}
