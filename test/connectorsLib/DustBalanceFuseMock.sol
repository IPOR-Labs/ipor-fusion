// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IMarketBalanceFuse} from "../../contracts/fuses/IMarketBalanceFuse.sol";
import {FusesLib} from "../../contracts/libraries/FusesLib.sol";

contract DustBalanceFuseMock is IMarketBalanceFuse {
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        MARKET_ID = marketId_;
    }

    function balanceOf() external view override returns (uint256) {
        /// @dev Dust in balance
        return FusesLib.ALLOWED_DUST_IN_BALANCE_FUSE + 1;
    }
}
