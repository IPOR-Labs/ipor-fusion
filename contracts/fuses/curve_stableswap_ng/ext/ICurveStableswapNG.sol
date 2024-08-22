// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/**
 * @dev address on Arbitrum Mainnet 0xf6841C27fe35ED7069189aFD5b81513578AFD7FF
 * @dev https://vscode.blockscan.com/arbitrum-one/0xf6841C27fe35ED7069189aFD5b81513578AFD7FF
 */

/* solhint-disable */
interface ICurveStableswapNG {
    /**
     * @dev Return the number of coins in the pool
     * @return Number of coins in the pool
     */
    function N_COINS() external view returns (uint256);

    /**
     * @dev Return the coin address at index i
     * @param i Index of the coin
     * @return Address of the coin
     */
    function coins(uint256 i) external view returns (address);

    /**
     * @dev Calculate addition or reduction in token supply from a deposit or withdrawal
     * @param _amounts Amount of each coin being deposited or withdrawn
     * @param _is_deposit Flag set to True for deposits and False for withhdrawals
     * @return Expected amount of LP tokens received
     */
    function calc_token_amount(uint256[] calldata _amounts, bool _is_deposit) external view returns (uint256);

    /**
     * @dev Add liquidity to the pool
     * @param _amounts List of amounts of coins to deposit
     * @param _min_mint_amount Minimum amount of LP tokens to mint from the deposit
     * @param _receiver Address to receive the minted LP tokens (defaults to msg.sender)
     * @return Amount of LP tokens received by depositing
     */
    function add_liquidity(
        uint256[] calldata _amounts,
        uint256 _min_mint_amount,
        address _receiver
    ) external returns (uint256);

    /**
     * @dev Calculate the amount of coin i to receive from burning _burn_amount of LP tokens
     * @param _burn_amount Amount of LP tokens to burn / withdraw
     * @param i Index value of the coin to receive
     * @return Amount of coin i to receive
     */
    function calc_withdraw_one_coin(uint256 _burn_amount, int128 i) external view returns (uint256);

    /**
     * @dev Remove a minimum of _min_received of coin i by burining _burn_amount of LP tokens
     * @param _burn_amount Amount of LP tokens to burn / withdraw
     * @param i Index value of the coin to receive
     * @param _min_received Minimum amount of coin i to receive
     * @param _receiver Address to receive the withdrawn coins (defaults to msg.sender)
     */
    function remove_liquidity_one_coin(
        uint256 _burn_amount,
        int128 i,
        uint256 _min_received,
        address _receiver
    ) external returns (uint256);
}
