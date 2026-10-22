// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {HyperCorePendingLib} from "./lib/HyperCorePendingLib.sol";
import {HyperCoreValuationLib} from "./lib/HyperCoreValuationLib.sol";

/// @notice Prices HyperCore assets owned by the vault, returning USD WAD.
/// @dev While a Core transfer is pending, returns the last-confirmed cached Core value; otherwise the live value.
contract HyperCoreBalanceFuse is IMarketBalanceFuse {
    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    error HyperCoreBalanceFuseInvalidMarketId();

    constructor(uint256 marketId) {
        if (marketId == 0) revert HyperCoreBalanceFuseInvalidMarketId();
        VERSION = address(this);
        MARKET_ID = marketId;
    }

    function balanceOf() external view override returns (uint256) {
        if (HyperCorePendingLib.isActionPending()) {
            return HyperCorePendingLib.cachedValueWad();
        }
        return HyperCoreValuationLib.liveValueWad(MARKET_ID);
    }
}
