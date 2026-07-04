// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {AreodromeSlipstreamSubstrateLibCaller} from "test/test_helpers/lib_callers/AreodromeSlipstreamSubstrateLibCaller.sol";
import {ICLFactory} from "contracts/fuses/aerodrome_slipstream/ext/ICLFactory.sol";

/// @dev Target: AreodromeSlipstreamSubstrateLibCaller (library AreodromeSlipstreamSubstrateLib wrapped for Olympix targeting).

contract AreodromeSlipstreamLibTest is OlympixUnitTest("AreodromeSlipstreamSubstrateLibCaller") {
    AreodromeSlipstreamSubstrateLibCaller internal caller;

    function setUp() public override {
        caller = new AreodromeSlipstreamSubstrateLibCaller();
    }

    function test_example_deploys() public view {
        assertTrue(address(caller) != address(0));
    }

    function test_getPoolAddress_usesLibraryAndReturnsAddress() public {
            // Using some deterministic but arbitrary inputs to exercise the branch
            address factory = makeAddr("factory");
            address token0 = address(0x1111);
            address token1 = address(0x2222);
            int24 tickSpacing = 60;

            // The library performs an external call to the factory (getPool) — the factory
            // must have code and answer, otherwise the call reverts with EvmError: Revert.
            address expectedPool = makeAddr("pool");
            vm.etch(factory, hex"fe");
            vm.mockCall(
                factory,
                abi.encodeWithSelector(ICLFactory.getPool.selector, token0, token1, tickSpacing),
                abi.encode(expectedPool)
            );
            // The pool must have code — the library's defense-in-depth check (PoolHasNoCode)
            vm.etch(expectedPool, hex"fe");

            // Act - this will execute the `if (true)` branch and call into the library
            address pool = caller.getPoolAddress(factory, token0, token1, tickSpacing);

    //        // Assert - library should return some address (it may be zero, but call must succeed)
            // Basic sanity check that call did not revert and returned a value
            assertEq(pool, expectedPool);
        }
    
}