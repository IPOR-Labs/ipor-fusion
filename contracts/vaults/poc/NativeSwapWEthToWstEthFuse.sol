// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFuse} from "../../fuses/IFuse.sol";
import {IwstEth} from "./interfaces/IwstEth.sol";
import {IStETH} from "./interfaces/IStETH.sol";
import {IWETH9} from "./interfaces/IWETH9.sol";

contract NativeSwapWethToWstEthFuse is IFuse {
    struct SwapData {
        uint256 wEthAmount;
    }

    address public constant W_ETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant WST_ETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address public constant ST_ETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    uint256 public constant MARKET_ID = 0;

    function enter(bytes calldata data) external {
        SwapData memory swapData = abi.decode(data, (SwapData));

        IWETH9(W_ETH).withdraw(swapData.wEthAmount);

        IStETH(ST_ETH).submit{value: swapData.wEthAmount}(address(0));

        uint256 stEthAmount = IStETH(ST_ETH).balanceOf(address(this));

        IERC20(ST_ETH).approve(WST_ETH, stEthAmount);

        IwstEth(WST_ETH).wrap(stEthAmount);
    }

    //todo remove solhint disable
    //solhint-disable-next-line
    function exit(bytes calldata data) external {
        //warning  Error message for revert is too long: 41 counted / 32 allowed  reason-string
        // todo remove solhint disable
        //solhint-disable-next-line
        revert("AaveV3SupplyFuse: exit not supported");
    }

    function withdraw(bytes32[] calldata) external override {
        revert("not supported");
    }

    function getSupportedAssets() external view returns (address[] memory assets) {
        assets = new address[](0);
    }

    // todo remove solhint disable
    //solhint-disable-next-line
    function isSupportedAsset(address asset) external view returns (bool) {
        return true;
    }
}
