// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";

/// @title Generic fuse for Swaps on Uniswap V3/V2 returns 0 because it is ignored in balance
contract UniswapBalanceFuse is IMarketBalanceFuse {
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        MARKET_ID = marketId_;
    }

    /// @param plasmaVault_ The address of the Plasma Vault
    /// @return The balance of the given input plasmaVault_ in associated with Fuse Balance marketId in USD, represented in 18 decimals
    //solhint-disable-next-line
    function balanceOf(address plasmaVault_) external view override returns (uint256) {
        return 0;
    }
}
