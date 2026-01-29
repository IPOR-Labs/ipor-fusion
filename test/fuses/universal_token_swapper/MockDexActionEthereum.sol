// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Mock DEX action for testing. Must be pre-funded with tokens before use.
contract MockDexActionEthereum {
    using SafeERC20 for ERC20;

    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    /// @notice Returns 1000 USDC to the executor. Contract must be pre-funded with USDC.
    function returnExtra1000Usdc(address executor) external {
        ERC20(USDC).transfer(executor, 1_000e6);
    }

    /// @notice Returns 1000 USDT to the executor. Contract must be pre-funded with USDT.
    function returnExtra1000Usdt(address executor) external {
        ERC20(USDT).safeTransfer(executor, 1_000e6);
    }

    /// @notice Returns 500 USDT to the executor. Contract must be pre-funded with USDT.
    function returnExtra500Usdt(address executor) external {
        ERC20(USDT).safeTransfer(executor, 500e6);
    }
}
