// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {PreHooksLibCaller} from "test/test_helpers/lib_callers/PreHooksLibCaller.sol";

/// @dev Target: PreHooksLibCaller (library PreHooksLib wrapped for Olympix targeting).

import {PreHooksLib} from "contracts/handlers/pre_hooks/PreHooksLib.sol";
contract PreHooksLibTest is OlympixUnitTest("PreHooksLibCaller") {
    PreHooksLibCaller internal caller;

    function setUp() public override {
        caller = new PreHooksLibCaller();
    }

    function test_example_deploys() public view {
        assertTrue(address(caller) != address(0));
    }

    function test_getPreHookImplementation_returnsSetImplementation_branchHit() public {
            // prepare selectors and implementation
            bytes4[] memory selectors = new bytes4[](1);
            selectors[0] = bytes4(keccak256("dummyPreHook()"));
    
            address[] memory implementations = new address[](1);
            implementations[0] = address(this);
    
            bytes32[][] memory substrates = new bytes32[][](1);
            substrates[0] = new bytes32[](0);
    
            // configure PreHooksLib storage via caller wrapper (writes into caller's storage)
            caller.setPreHookImplementations(selectors, implementations, substrates);
    
            // when: querying implementation for our selector via wrapper (hits opix-target-branch-7-True)
            address implFromCaller = caller.getPreHookImplementation(selectors[0]);
    
            // then: it should match the implementation we set
            assertEq(implFromCaller, implementations[0], "implementation from caller should match configured implementation");
        }

    function test_getPreHookSubstrates_ReturnsConfiguredSubstrates() public {
            // prepare a fake selector and implementation
            bytes4[] memory selectors = new bytes4[](1);
            selectors[0] = bytes4(keccak256("foo()"));
    
            address[] memory implementations = new address[](1);
            implementations[0] = address(0xBEEF);
    
            bytes32[][] memory substrates = new bytes32[][](1);
            substrates[0] = new bytes32[](2);
            substrates[0][0] = bytes32(uint256(1));
            substrates[0][1] = bytes32(uint256(2));
    
            // configure pre-hook in library storage via caller wrapper
            caller.setPreHookImplementations(selectors, implementations, substrates);
    
            // exercise the target branch getPreHookSubstrates
            bytes32[] memory result = caller.getPreHookSubstrates(selectors[0], implementations[0]);
    
            // validate
            assertEq(result.length, 2, "substrates length");
            assertEq(result[0], substrates[0][0], "substrate[0]");
            assertEq(result[1], substrates[0][1], "substrate[1]");
        }

    function test_getPreHookSelectors_ReturnsConfiguredSelectors() public {
        // given: configure a single pre-hook implementation
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = bytes4(keccak256("dummyPreHook(bytes32)"));
    
        address[] memory implementations = new address[](1);
        implementations[0] = address(this);
    
        bytes32[][] memory substrates = new bytes32[][](1);
        substrates[0] = new bytes32[](1);
        substrates[0][0] = bytes32(uint256(123));
    
        caller.setPreHookImplementations(selectors, implementations, substrates);
    
        // when: retrieving selectors via wrapper (calls PreHooksLib.getPreHookSelectors())
        bytes4[] memory storedSelectors = caller.getPreHookSelectors();
    
        // then: the configured selector should be present
        bool found;
        for (uint256 i = 0; i < storedSelectors.length; ++i) {
            if (storedSelectors[i] == selectors[0]) {
                found = true;
                break;
            }
        }
        assertTrue(found, "Configured pre-hook selector should be returned by getPreHookSelectors");
    }

    function test_setPreHookImplementations_storesSelectorsAndData() public {
            // prepare one selector, implementation, and its substrates
            bytes4[] memory selectors = new bytes4[](1);
            selectors[0] = bytes4(keccak256("dummyHook()"));
    
            address[] memory implementations = new address[](1);
            implementations[0] = address(0xBEEF);
    
            bytes32[][] memory substrates = new bytes32[][](1);
            substrates[0] = new bytes32[](2);
            substrates[0][0] = bytes32(uint256(1));
            substrates[0][1] = bytes32(uint256(2));
    
            // when: store config via wrapper (hits opix-target-branch-23-True)
            caller.setPreHookImplementations(selectors, implementations, substrates);
    
            // then: selector list contains our selector
            bytes4[] memory storedSelectors = caller.getPreHookSelectors();
            assertEq(storedSelectors.length, 1, "selectors length");
            assertEq(storedSelectors[0], selectors[0], "selector value");
    
            // and: implementation & substrates retrievable
            address impl = caller.getPreHookImplementation(selectors[0]);
            assertEq(impl, implementations[0], "implementation address");
    
            bytes32[] memory storedSubstrates = caller.getPreHookSubstrates(selectors[0], implementations[0]);
            assertEq(storedSubstrates.length, 2, "substrates length");
            assertEq(storedSubstrates[0], substrates[0][0], "substrate[0]");
            assertEq(storedSubstrates[1], substrates[0][1], "substrate[1]");
        }
}