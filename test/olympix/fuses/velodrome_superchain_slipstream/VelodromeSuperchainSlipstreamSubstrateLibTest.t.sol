// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {VelodromeSuperchainSlipstreamSubstrateLibCaller} from "test/test_helpers/lib_callers/VelodromeSuperchainSlipstreamSubstrateLibCaller.sol";
import {ICLFactory} from "contracts/fuses/velodrome_superchain_slipstream/ext/ICLFactory.sol";

/// @dev Target: VelodromeSuperchainSlipstreamSubstrateLibCaller (library VelodromeSuperchainSlipstreamSubstrateLib wrapped for Olympix targeting).

contract VelodromeSuperchainSlipstreamSubstrateLibTest is OlympixUnitTest("VelodromeSuperchainSlipstreamSubstrateLibCaller") {
    VelodromeSuperchainSlipstreamSubstrateLibCaller internal caller;

    function setUp() public override {
        caller = new VelodromeSuperchainSlipstreamSubstrateLibCaller();
    }

    function test_example_deploys() public view {
        assertTrue(address(caller) != address(0));
    }

    function test_getPoolAddress_DoesNotRevert() public {
            // Call getPoolAddress with arbitrary parameters to hit the branch
            // We only care that it does not revert and the branch is executed.
            address factory = makeAddr("factory");
            address token0 = address(0x2);
            address token1 = address(0x3);
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

            address pool = caller.getPoolAddress(factory, token0, token1, tickSpacing);
            assertEq(pool, expectedPool);
        }
    
}