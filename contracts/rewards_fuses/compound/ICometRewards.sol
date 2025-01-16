// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

interface ICometRewards {
    function claimTo(address comet, address src, address to, bool shouldAccrue) external;
}
