// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {UniversalTokenSwapperWithSignatureFuse, UniversalTokenSwapperSubstrate} from "../../../contracts/fuses/universal_token_swapper/UniversalTokenSwapperWithSignatureFuse.sol";

contract UniversalTokenSwapperWithSignatureFuseTest is Test {
    UniversalTokenSwapperWithSignatureFuse public swapper;
    address public constant EXECUTOR = address(0x1234);
    uint256 public constant MARKET_ID = 1;
    uint256 public constant SLIPPAGE_REVERSE = 0.05e18; // 5% slippage

    function setUp() public {
        swapper = new UniversalTokenSwapperWithSignatureFuse(MARKET_ID, EXECUTOR, SLIPPAGE_REVERSE);
    }

    function testShouldConvertSubstrateToBytes32AndBack() public {
        // Prepare test data
        bytes4 functionSelector = bytes4(keccak256("testFunction()"));
        address target = address(0x5678);

        // Create substrate
        UniversalTokenSwapperSubstrate memory substrate = UniversalTokenSwapperSubstrate({
            functionSelector: functionSelector,
            target: target
        });

        // Test toBytes32
        bytes32 packed = swapper.toBytes32(substrate);

        // Verify packed data
        assertEq(bytes4(uint32(uint256(packed) >> 224)), functionSelector, "Function selector mismatch");
        assertEq(address(uint160(uint256(packed))), target, "Target address mismatch");

        // Test fromBytes32
        UniversalTokenSwapperSubstrate memory unpacked = swapper.fromBytes32(packed);

        // Verify unpacked data
        assertEq(unpacked.functionSelector, functionSelector, "Unpacked function selector mismatch");
        assertEq(unpacked.target, target, "Unpacked target address mismatch");
    }

    function testShouldHandleZeroValuesInConversion() public {
        // Create substrate with zero values
        UniversalTokenSwapperSubstrate memory substrate = UniversalTokenSwapperSubstrate({
            functionSelector: bytes4(0),
            target: address(0)
        });

        // Test toBytes32
        bytes32 packed = swapper.toBytes32(substrate);

        // Test fromBytes32
        UniversalTokenSwapperSubstrate memory unpacked = swapper.fromBytes32(packed);

        // Verify unpacked data
        assertEq(unpacked.functionSelector, bytes4(0), "Unpacked function selector should be zero");
        assertEq(unpacked.target, address(0), "Unpacked target address should be zero");
    }

    function testShouldHandleMaxValuesInConversion() public {
        // Create substrate with max values
        UniversalTokenSwapperSubstrate memory substrate = UniversalTokenSwapperSubstrate({
            functionSelector: bytes4(type(uint32).max),
            target: address(type(uint160).max)
        });

        // Test toBytes32
        bytes32 packed = swapper.toBytes32(substrate);

        // Test fromBytes32
        UniversalTokenSwapperSubstrate memory unpacked = swapper.fromBytes32(packed);

        // Verify unpacked data
        assertEq(unpacked.functionSelector, bytes4(type(uint32).max), "Unpacked function selector should be max");
        assertEq(unpacked.target, address(type(uint160).max), "Unpacked target address should be max");
    }
}
