// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice General interface for token exchange rates.
interface IRateProvider {
    /**
     * @notice An 18 decimal fixed point number representing the exchange rate of one token to another related token.
     * @dev The meaning of this rate depends on the context. Note that there may be an error associated with a token
     * rate, and the caller might require a certain rounding direction to ensure correctness. This (legacy) interface
     * does not take a rounding direction or return an error, so great care must be taken when interpreting and using
     * rates in downstream computations.
     *
     * @return rate The current token rate
     */
    function getRate() external view returns (uint256 rate);
}

interface IPool {
    function getTokens() external view returns (IERC20[] memory tokens);

    /**
     * @notice Token types supported by the Vault.
     * @dev In general, pools may contain any combination of these tokens.
     *
     * STANDARD tokens (e.g., BAL, WETH) have no rate provider.
     * WITH_RATE tokens (e.g., wstETH) require a rate provider. These may be tokens like wstETH, which need to be wrapped
     * because the underlying stETH token is rebasing, and such tokens are unsupported by the Vault. They may also be
     * tokens like sEUR, which track an underlying asset, but are not yield-bearing. Finally, this encompasses
     * yield-bearing ERC4626 tokens, which can be used to facilitate swaps without requiring wrapping or unwrapping
     * in most cases. The `paysYieldFees` flag can be used to indicate whether a token is yield-bearing (e.g., waDAI),
     * not yield-bearing (e.g., sEUR), or yield-bearing but exempt from fees (e.g., in certain nested pools, where
     * yield fees are charged elsewhere).
     *
     * NB: STANDARD must always be the first enum element, so that newly initialized data structures default to Standard.
     */
    enum TokenType {
        STANDARD,
        WITH_RATE
    }

    /**
     * @notice This data structure is stored in `_poolTokenInfo`, a nested mapping from pool -> (token -> TokenInfo).
     * @dev Since the token is already the key of the nested mapping, it would be redundant (and an extra SLOAD) to store
     * it again in the struct. When we construct PoolData, the tokens are separated into their own array.
     *
     * @param tokenType The token type (see the enum for supported types)
     * @param rateProvider The rate provider for a token (see further documentation above)
     * @param paysYieldFees Flag indicating whether yield fees should be charged on this token
     */
    struct TokenInfo {
        TokenType tokenType;
        IRateProvider rateProvider;
        bool paysYieldFees;
    }

    /**
     * @notice Gets the raw data for the pool: tokens, token info, raw balances, and last live balances.
     * @return tokens Pool tokens, sorted in token registration order
     * @return tokenInfo Token info structs (type, rate provider, yield flag), sorted in token registration order
     * @return balancesRaw Current native decimal balances of the pool tokens, sorted in token registration order
     * @return lastBalancesLiveScaled18 Last saved live balances, sorted in token registration order
     */
    function getTokenInfo()
        external
        view
        returns (
            IERC20[] memory tokens,
            TokenInfo[] memory tokenInfo,
            uint256[] memory balancesRaw,
            uint256[] memory lastBalancesLiveScaled18
        );
}
