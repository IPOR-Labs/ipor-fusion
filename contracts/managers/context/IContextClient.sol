// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

interface IContextClient {
    function setupContext(address sender) external;

    function clearContext() external;
}
