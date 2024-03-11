// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import "forge-std/console2.sol";
import "./IConnector.sol";
import "./interfaces/IMorpho.sol";
import "./Vault.sol";
import "./interfaces/IwstEth.sol";
import "./interfaces/IStETH.sol";
import "./interfaces/IWETH9.sol";

contract NativeSwapWethToWstEthConnector is IConnector {

    struct SwapData {
        uint256 wEthAmount;
    }

    address public constant wEth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant wstEth = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address public constant stEth = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    function enter(bytes calldata data) external returns (uint256 executionStatus) {
        console2.log("NativeSwapWethToWstEthConnector: ENTER...");

        (SwapData memory swapData) = abi.decode(data, (SwapData));

        IWETH9(wEth).withdraw(swapData.wEthAmount);

        IStETH(stEth).submit{value: swapData.wEthAmount}(address(0));

        uint256 stEthAmount = IStETH(stEth).balanceOf(address(this));

        IERC20(stEth).approve(wstEth, stEthAmount);

        IwstEth(wstEth).wrap(stEthAmount);

        console2.log("NativeSwapWethToWstEthConnector: END.");
    }

    function exit(bytes calldata data) external returns (uint256 executionStatus) {
        //TODO: implement
        revert("AaveV3SupplyConnector: exit not supported");
    }
}
