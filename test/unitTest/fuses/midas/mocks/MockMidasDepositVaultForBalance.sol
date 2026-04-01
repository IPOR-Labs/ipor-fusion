// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IMidasDepositVault} from "contracts/fuses/midas/ext/IMidasDepositVault.sol";

/// @notice Configurable mock for IMidasDepositVault used in MidasBalanceFuse unit tests.
///         Supports setting mToken, mTokenDataFeed, and individual mintRequests.
contract MockMidasDepositVaultForBalance {
    address public mToken;
    address public mTokenDataFeed;
    mapping(uint256 => IMidasDepositVault.Request) private _mintRequests;

    function setMToken(address mToken_) external {
        mToken = mToken_;
    }

    function setMTokenDataFeed(address feed_) external {
        mTokenDataFeed = feed_;
    }

    function setMintRequest(uint256 id_, IMidasDepositVault.Request memory req_) external {
        _mintRequests[id_] = req_;
    }

    function mintRequests(uint256 id_) external view returns (IMidasDepositVault.Request memory) {
        return _mintRequests[id_];
    }
}
