// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {DIAPriceFeedFactory} from "../../../contracts/factory/price_feed/DIAPriceFeedFactory.sol";
import {DIAPriceFeed} from "../../../contracts/price_oracle/price_feed/DIAPriceFeed.sol";

contract DIAPriceFeedFactoryTest is Test {
    DIAPriceFeedFactory public factory;

    address public constant DIA_ORACLE = 0xafA00E7Eff2EA6D216E432d99807c159d08C2b79;
    string public constant KEY = "OUSD/USD";
    uint32 public constant MAX_STALE = 1 days + 1 hours;
    uint8 public constant DIA_DEC_8 = 8;
    uint8 public constant DEC_18 = 18;
    address public constant ADMIN = address(0x1);

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 22773442);
        address implementation = address(new DIAPriceFeedFactory());
        factory = DIAPriceFeedFactory(
            address(new ERC1967Proxy(implementation, abi.encodeWithSignature("initialize(address)", ADMIN)))
        );
    }

    function test_Initialize() public view {
        assertEq(factory.owner(), ADMIN, "Owner should be set correctly");
    }

    function test_Initialize_RevertsOnZeroAdmin() public {
        address implementation = address(new DIAPriceFeedFactory());
        vm.expectRevert(DIAPriceFeedFactory.InvalidAddress.selector);
        new ERC1967Proxy(implementation, abi.encodeWithSignature("initialize(address)", address(0)));
    }

    function test_Initialize_CannotCallTwice() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        factory.initialize(ADMIN);
    }

    function test_CreatePriceFeed() public {
        address priceFeed = factory.create(DIA_ORACLE, KEY, MAX_STALE, DIA_DEC_8, DEC_18);

        assertTrue(priceFeed != address(0), "Price feed should be created");

        DIAPriceFeed feed = DIAPriceFeed(priceFeed);
        assertEq(feed.DIA_ORACLE(), DIA_ORACLE, "DIA_ORACLE should be set correctly");
        assertEq(feed.KEY(), KEY, "KEY should be set correctly");
        assertEq(feed.MAX_STALE_PERIOD(), MAX_STALE, "MAX_STALE_PERIOD should be set correctly");
        assertEq(feed.DIA_DECIMALS(), DIA_DEC_8, "DIA_DECIMALS should be set correctly");
        assertEq(feed.PRICE_FEED_DECIMALS(), DEC_18, "PRICE_FEED_DECIMALS should be set correctly");
        assertEq(feed.SCALE(), 1e10, "SCALE should match configured decimals");
    }

    function test_CreatePriceFeed_WithDiaDecimals5() public {
        address priceFeed = factory.create(DIA_ORACLE, KEY, MAX_STALE, 5, DEC_18);
        DIAPriceFeed feed = DIAPriceFeed(priceFeed);
        assertEq(feed.DIA_DECIMALS(), 5, "DIA_DECIMALS should be 5");
        assertEq(feed.PRICE_FEED_DECIMALS(), DEC_18, "PRICE_FEED_DECIMALS should be 18");
        assertEq(feed.SCALE(), 10 ** 13, "SCALE should be 10**13");
    }

    function test_CreatePriceFeed_EmitsEvent() public {
        vm.recordLogs();
        address priceFeed = factory.create(DIA_ORACLE, KEY, MAX_STALE, DIA_DEC_8, DEC_18);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool found;
        bytes32 expectedSig = keccak256("DIAPriceFeedCreated(address,address,string,uint32,uint8,uint8)");
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == expectedSig && logs[i].emitter == address(factory)) {
                (
                    address emittedFeed,
                    address emittedOracle,
                    string memory emittedKey,
                    uint32 emittedStale,
                    uint8 emittedDiaDec,
                    uint8 emittedFeedDec
                ) = abi.decode(logs[i].data, (address, address, string, uint32, uint8, uint8));
                assertEq(emittedFeed, priceFeed, "event priceFeed mismatch");
                assertEq(emittedOracle, DIA_ORACLE, "event oracle mismatch");
                assertEq(emittedKey, KEY, "event key mismatch");
                assertEq(emittedStale, MAX_STALE, "event stale period mismatch");
                assertEq(emittedDiaDec, DIA_DEC_8, "event DIA decimals mismatch");
                assertEq(emittedFeedDec, DEC_18, "event feed decimals mismatch");
                found = true;
                break;
            }
        }
        assertTrue(found, "DIAPriceFeedCreated event not found");
    }

    function test_CreatePriceFeed_RevertsOnZeroOracle() public {
        vm.expectRevert(DIAPriceFeed.ZeroAddress.selector);
        factory.create(address(0), KEY, MAX_STALE, DIA_DEC_8, DEC_18);
    }

    function test_CreatePriceFeed_RevertsOnEmptyKey() public {
        vm.expectRevert(DIAPriceFeed.EmptyKey.selector);
        factory.create(DIA_ORACLE, "", MAX_STALE, DIA_DEC_8, DEC_18);
    }

    function test_CreatePriceFeed_RevertsOnZeroStalePeriod() public {
        vm.expectRevert(DIAPriceFeed.ZeroStalePeriod.selector);
        factory.create(DIA_ORACLE, KEY, 0, DIA_DEC_8, DEC_18);
    }

    function test_CreatePriceFeed_RevertsOnZeroDiaDecimals() public {
        vm.expectRevert(DIAPriceFeed.ZeroDiaDecimals.selector);
        factory.create(DIA_ORACLE, KEY, MAX_STALE, 0, DEC_18);
    }

    function test_CreatePriceFeed_RevertsWhenFeedDecimalsBelowDiaDecimals() public {
        vm.expectRevert(DIAPriceFeed.PriceFeedDecimalsTooLow.selector);
        factory.create(DIA_ORACLE, KEY, MAX_STALE, DIA_DEC_8, 7);
    }

    function test_Upgrade_NotOwner() public {
        address caller = address(0x2);
        address newImplementation = address(new DIAPriceFeedFactory());

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", caller));
        vm.prank(caller);
        factory.upgradeToAndCall(newImplementation, "");
    }

    function test_Upgrade_Owner() public {
        address newImplementation = address(new DIAPriceFeedFactory());
        vm.prank(ADMIN);
        factory.upgradeToAndCall(newImplementation, "");

        assertEq(factory.owner(), ADMIN, "Owner should remain after upgrade");
        bytes32 storedImpl = vm.load(address(factory), ERC1967Utils.IMPLEMENTATION_SLOT);
        assertEq(address(uint160(uint256(storedImpl))), newImplementation, "ERC1967 impl slot mismatch");
    }
}
