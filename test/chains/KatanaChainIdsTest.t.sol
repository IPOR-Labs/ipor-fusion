// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "../../contracts/chains/KatanaChainIds.sol";

contract KatanaChainIdsTest is Test {
    function testKatanaNativeMarketId() public pure {
        assertEq(KatanaChainIds.KATANA_NATIVE, 747474001);
    }

    function testKatanaUsdcMarketId() public pure {
        assertEq(KatanaChainIds.KATANA_USDC, 747474002);
    }

    function testKatanaWethMarketId() public pure {
        assertEq(KatanaChainIds.KATANA_WETH, 747474003);
    }
}
