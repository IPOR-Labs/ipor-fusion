// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IMarketBalanceFuse} from "../../contracts/fuses/IMarketBalanceFuse.sol";

contract DustBalanceFuseMock is IMarketBalanceFuse {
    uint256 public immutable MARKET_ID;
    uint256 private immutable UNDERLYING_DECIMALS;

    constructor(uint256 marketId_, uint256 underlyingDecimals_) {
        MARKET_ID = marketId_;
        UNDERLYING_DECIMALS = underlyingDecimals_;
    }

    function balanceOf() external view override returns (uint256) {
        /// @dev Dust in balance
        return 10 ** (UNDERLYING_DECIMALS / 2) + 1;
    }
}
