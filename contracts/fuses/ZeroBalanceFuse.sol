// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IMarketBalanceFuse} from "./IMarketBalanceFuse.sol";

/**
 * @title ZeroBalanceFuse
 * @dev A smart contract that implements the IMarketBalanceFuse interface.
 *      The returned zero balance indicates that it is ignored in balance calculations for the associated market.
 */
contract ZeroBalanceFuse is IMarketBalanceFuse {
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        MARKET_ID = marketId_;
    }

    /**
     * @notice Returns the balance of the associated plasma vault in USD.
     * @dev This implementation always returns 0, as the balance is ignored for this specific market fuse.
     * @return uint256 Always returns 0, represented in 18 decimals.
     */
    function balanceOf() external pure override returns (uint256) {
        return 0;
    }
}
