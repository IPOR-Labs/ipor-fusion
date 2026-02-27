// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import {IPrincipalToken} from "../ext/IPrincipalToken.sol";

library LibExpiry {
    function isExpired(uint256 expiry) internal view returns (bool) {
        return block.timestamp >= expiry;
    }

    function isExpired(IPrincipalToken pt) internal view returns (bool) {
        return block.timestamp >= pt.maturity();
    }
}
