// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IMidasRedemptionVault} from "contracts/fuses/midas/ext/IMidasRedemptionVault.sol";

/// @notice Configurable mock for IMidasRedemptionVault used in MidasBalanceFuse unit tests.
///         Supports setting mToken and individual redeemRequests.
contract MockMidasRedemptionVaultForBalance {
    address public mToken;
    mapping(uint256 => IMidasRedemptionVault.Request) private _redeemRequests;

    function setMToken(address mToken_) external {
        mToken = mToken_;
    }

    function setRedeemRequest(uint256 id_, IMidasRedemptionVault.Request memory req_) external {
        _redeemRequests[id_] = req_;
    }

    function redeemRequests(uint256 id_) external view returns (IMidasRedemptionVault.Request memory) {
        return _redeemRequests[id_];
    }
}
