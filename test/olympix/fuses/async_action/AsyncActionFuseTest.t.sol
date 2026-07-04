// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {AsyncActionFuse, AsyncActionFuseEnterData} from "contracts/fuses/async_action/AsyncActionFuse.sol";

/// @dev Target contract: contracts/fuses/async_action/AsyncActionFuse.sol
/// @dev Constructor and pure-validation paths are unit-testable without infrastructure.
/// @dev Full enter/exit flow requires PlasmaVault context + AsyncExecutor — covered in integration tests.

import {AsyncActionFuse} from "contracts/fuses/async_action/AsyncActionFuse.sol";
import {AsyncActionFuseExitData} from "contracts/fuses/async_action/AsyncActionFuse.sol";
contract AsyncActionFuseTest is OlympixUnitTest("AsyncActionFuse") {
    AsyncActionFuse internal fuse;
    address internal constant WETH = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    uint256 internal constant MARKET_ID = 42;

    function setUp() public override {
        fuse = new AsyncActionFuse(MARKET_ID, WETH);
    }

    function test_example_constructorSetsImmutables() public view {
        assertEq(fuse.MARKET_ID(), MARKET_ID);
        assertEq(fuse.W_ETH(), WETH);
        assertEq(fuse.VERSION(), address(fuse));
    }

    function test_example_constructorRevertsOnZeroMarketId() public {
        vm.expectRevert(AsyncActionFuse.AsyncActionFuseInvalidMarketId.selector);
        new AsyncActionFuse(0, WETH);
    }

    function test_example_constructorRevertsOnZeroWeth() public {
        vm.expectRevert(AsyncActionFuse.AsyncActionFuseInvalidWethAddress.selector);
        new AsyncActionFuse(MARKET_ID, address(0));
    }

    function test_example_enterRevertsOnZeroTokenOut() public {
        AsyncActionFuseEnterData memory data;
        vm.expectRevert(AsyncActionFuse.AsyncActionFuseInvalidTokenOut.selector);
        fuse.enter(data);
    }

    function test_example_enterRevertsOnLengthMismatch() public {
        AsyncActionFuseEnterData memory data;
        data.tokenOut = address(0xBEEF);
        data.targets = new address[](2);
        data.callDatas = new bytes[](1);
        data.ethAmounts = new uint256[](2);
        vm.expectRevert(AsyncActionFuse.AsyncActionFuseInvalidArrayLength.selector);
        fuse.enter(data);
    }

    function test_enter_ArrayLengthsMatch_HitsElseBranch149() public {
            AsyncActionFuseEnterData memory data;
            data.tokenOut = address(0xBEEF); // non-zero to pass first require
    
            // Set all arrays to the same (non-zero) length so the `if` condition is false
            data.targets = new address[](1);
            data.callDatas = new bytes[](1);
            data.ethAmounts = new uint256[](1);
    
            // We don't care about later logic here (it will revert on substrates/validation),
            // we only need to ensure the length-check `else` branch is entered.
            // Any revert reason after that is acceptable.
            vm.expectRevert();
            fuse.enter(data);
        }

    function test_exit_ReturnsEarlyOnEmptyAssetsArray_Branch292True() public {
            AsyncActionFuseExitData memory data;
            address[] memory returnedAssets = fuse.exit(data);
            assertEq(returnedAssets.length, 0);
        }

    function test_exit_NonEmptyAssetsHitsElseBranch() public {
            address[] memory assets = new address[](1);
            assets[0] = address(0xBEEF);
            bytes[] memory fetchCallDatas = new bytes[](1);
            fetchCallDatas[0] = hex"deadbeef"; // at least 4 bytes to pass _validateTargetsMemory length check
    
            AsyncActionFuseExitData memory data = AsyncActionFuseExitData({
                assets: assets,
                fetchCallDatas: fetchCallDatas
            });
    
            vm.expectRevert();
            fuse.exit(data);
        }
}