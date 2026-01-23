// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {UpdateMarketsBalancesFuse} from "../../../contracts/fuses/update_balances/UpdateMarketsBalancesFuse.sol";
import {IUpdateMarketsBalancesFuse} from "../../../contracts/fuses/update_balances/IUpdateMarketsBalancesFuse.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";

/// @title UpdateMarketsBalancesFuseTest
/// @notice Unit tests for UpdateMarketsBalancesFuse contract
/// @dev These tests verify basic contract properties that don't require delegatecall context.
///      For full integration testing, see UpdateMarketsBalancesFuseIntegrationTest.t.sol
contract UpdateMarketsBalancesFuseTest is Test {
    UpdateMarketsBalancesFuse public fuse;

    function setUp() public {
        fuse = new UpdateMarketsBalancesFuse();
    }

    // ============ Constructor Tests ============

    function testShouldSetVersionToContractAddress() public view {
        // then
        assertEq(fuse.VERSION(), address(fuse), "VERSION should equal deployment address");
    }

    function testShouldReturnCorrectMarketId() public view {
        // then
        assertEq(fuse.MARKET_ID(), IporFusionMarkets.ZERO_BALANCE_MARKET, "MARKET_ID should be ZERO_BALANCE_MARKET");
    }

    function testMarketIdShouldBeMaxUint256() public view {
        // then - ZERO_BALANCE_MARKET is type(uint256).max
        assertEq(fuse.MARKET_ID(), type(uint256).max, "MARKET_ID should be max uint256");
    }

    // ============ Exit Tests ============

    function testShouldRevertWhenExitCalledDirectly() public {
        // given
        bytes memory emptyData = "";

        // when/then - direct call should revert
        vm.expectRevert(IUpdateMarketsBalancesFuse.UpdateMarketsBalancesFuseExitNotSupported.selector);
        fuse.exit(emptyData);
    }

    function testShouldRevertWhenExitCalledWithData() public {
        // given
        bytes memory someData = abi.encode(uint256(123));

        // when/then
        vm.expectRevert(IUpdateMarketsBalancesFuse.UpdateMarketsBalancesFuseExitNotSupported.selector);
        fuse.exit(someData);
    }
}
