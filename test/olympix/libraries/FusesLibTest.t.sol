// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {FusesLibCaller} from "test/test_helpers/lib_callers/FusesLibCaller.sol";
import {FusesLib} from "contracts/libraries/FusesLib.sol";

/// @dev Target: FusesLibCaller (library FusesLib wrapped for Olympix targeting).

import {DustBalanceFuseMock} from "test/connectorsLib/DustBalanceFuseMock.sol";
contract FusesLibTest is OlympixUnitTest("FusesLibCaller") {
    FusesLibCaller internal caller;

    function setUp() public override {
        caller = new FusesLibCaller();
    }

    function test_example_isFuseSupportedDefaultsFalse() public view {
        assertFalse(caller.isFuseSupported(address(0xBEEF)));
    }

    function test_example_addFuseMakesItSupported() public {
        address fuse = address(0xCAFE);
        caller.addFuse(fuse);
        assertTrue(caller.isFuseSupported(fuse));
    }

    function test_example_addFuseTwiceReverts() public {
        address fuse = address(0xCAFE);
        caller.addFuse(fuse);
        vm.expectRevert(FusesLib.FuseAlreadyExists.selector);
        caller.addFuse(fuse);
    }

    function test_isBalanceFuseSupportedTrueAfterAdd_UsesRealBalanceFuseMock() public {
            uint256 marketId = 1;
            // use a real balance fuse mock so the internal call to MARKET_ID() succeeds
            DustBalanceFuseMock balanceFuse = new DustBalanceFuseMock(marketId, 18);
    
            // add balance fuse for the given market
            caller.addBalanceFuse(marketId, address(balanceFuse));
    
            // opix-target-branch-13-True: ensure the wrapped call executes and returns true
            bool supported = caller.isBalanceFuseSupported(marketId, address(balanceFuse));
            assertTrue(supported, "Balance fuse should be supported after addBalanceFuse");
        }

    function test_getBalanceFuse_ReturnsAddedBalanceFuse_ForMarket() public {
            uint256 marketId = 1;
            // use a real balance fuse mock so MARKET_ID() staticcall succeeds
            DustBalanceFuseMock balanceFuse = new DustBalanceFuseMock(marketId, 18);
    
            // arrange: add a balance fuse for marketId via the wrapper
            caller.addBalanceFuse(marketId, address(balanceFuse));
    
            // act & assert: getBalanceFuse should now return that address
            assertEq(caller.getBalanceFuse(marketId), address(balanceFuse));
        }

    function test_getFusesArrayAfterAddFuse() public {
        address fuse1 = address(0x1111);
        address fuse2 = address(0x2222);
    
        caller.addFuse(fuse1);
        caller.addFuse(fuse2);
    
        address[] memory fuses = caller.getFusesArray();
    
        assertEq(fuses.length, 2, "Fuses array should contain two entries");
        assertEq(fuses[0], fuse1, "First fuse should match fuse1");
        assertEq(fuses[1], fuse2, "Second fuse should match fuse2");
    }

    function test_getFuseArrayIndex_MatchesUnderlyingFusesLibIndexing() public {
            address fuse1 = address(0xA1);
            address fuse2 = address(0xA2);
    
            caller.addFuse(fuse1);
            caller.addFuse(fuse2);
    
            uint256 index1 = caller.getFuseArrayIndex(fuse1);
            uint256 index2 = caller.getFuseArrayIndex(fuse2);
    
            // FusesLib reserves index 0 and starts actual fuses from index 1
            assertEq(index1, 1, "First added fuse should have index 1 (0 is reserved)");
            assertEq(index2, 2, "Second added fuse should have index 2 (0 is reserved)");
        }

    function test_removeFuse_RemovesAndAllowsReadd() public {
        address fuse = address(0xBEEF);
    
        // add once
        caller.addFuse(fuse);
        assertTrue(caller.isFuseSupported(fuse));
    
        // remove (targets removeFuse -> FusesLib.removeFuse)
        caller.removeFuse(fuse);
        assertFalse(caller.isFuseSupported(fuse));
    
        // can be added again without reverting
        caller.addFuse(fuse);
        assertTrue(caller.isFuseSupported(fuse));
    }

    function test_addBalanceFuse_registersMarketAsActive() public {
            uint256 marketId = 1;
            // use a real balance fuse mock so the internal call to MARKET_ID() succeeds
            DustBalanceFuseMock balanceFuse = new DustBalanceFuseMock(marketId, 18);
    
            // when: add a balance fuse for a given market
            caller.addBalanceFuse(marketId, address(balanceFuse));
    
            // then: marketId should appear in active markets list
            uint256[] memory activeMarkets = caller.getActiveMarketsInBalanceFuses();
            bool found;
            for (uint256 i = 0; i < activeMarkets.length; i++) {
                if (activeMarkets[i] == marketId) {
                    found = true;
                    break;
                }
            }
            assertTrue(found, "marketId should be active after adding balance fuse");
        }

    function test_getActiveMarketsInBalanceFuses_MultipleMarkets() public {
            // given: deploy two mock balance fuses so fuse addresses are real contracts
            uint256 marketId1 = 1;
            uint256 marketId2 = 2;
    
            DustBalanceFuseMock fuse1 = new DustBalanceFuseMock(marketId1, 18);
            DustBalanceFuseMock fuse2 = new DustBalanceFuseMock(marketId2, 18);
    
            caller.addBalanceFuse(marketId1, address(fuse1));
            caller.addBalanceFuse(marketId2, address(fuse2));
    
            // when
            uint256[] memory activeMarkets = caller.getActiveMarketsInBalanceFuses();
    
            // then: both market ids should be present (order not assumed)
            bool found1;
            bool found2;
            for (uint256 i = 0; i < activeMarkets.length; ++i) {
                if (activeMarkets[i] == marketId1) {
                    found1 = true;
                } else if (activeMarkets[i] == marketId2) {
                    found2 = true;
                }
            }
    
            assertTrue(found1, "marketId1 should be active");
            assertTrue(found2, "marketId2 should be active");
        }
}