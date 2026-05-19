// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {TestAddresses} from "test/test_helpers/TestAddresses.sol";

/// @dev Target contract: contracts/universal_reader/UniversalReader.sol

import {UniversalReader, ReadResult} from "contracts/universal_reader/UniversalReader.sol";

/// @dev Minimal concrete subclass used only to exercise the abstract base in unit tests.
contract UniversalReaderHarness is UniversalReader {}

contract UniversalReaderTest is OlympixUnitTest("UniversalReader") {
    UniversalReaderHarness public universalReader;

    function setUp() public override {
        universalReader = new UniversalReaderHarness();
    }

    function test_example_deployment_doesNotRevert() public view {
        assertTrue(address(universalReader) != address(0), "Contract should be deployed");
    }

    function test_example_readRevertsOnZeroAddress() public {
        vm.expectRevert(UniversalReader.ZeroAddress.selector);
        universalReader.read(address(0), "");
    }

    function test_example_readInternalRevertsForExternalCaller() public {
        vm.expectRevert(UniversalReader.UnauthorizedCaller.selector);
        universalReader.readInternal(address(0x1), "");
    }

    function test_readInternal_DelegatecallExecutesAndHitsOnlyThisElseBranch() public {
        // readInternal does target.functionDelegateCall(data), so balanceOf runs with the
        // reader's storage context. Pre-write the OZ ERC20 _balances slot (slot 0 mapping)
        // for address(universalReader) on the reader itself so the delegatecall returns 100.
        MockERC20 token = new MockERC20("Mock", "MCK", 18);
        bytes32 balancesSlot = keccak256(abi.encode(address(universalReader), uint256(0)));
        vm.store(address(universalReader), balancesSlot, bytes32(uint256(100)));

        bytes memory data = abi.encodeWithSelector(token.balanceOf.selector, address(universalReader));

        // Triggers the `else` branch in readInternal (msg.sender == address(this) via staticcall).
        ReadResult memory result = universalReader.read(address(token), data);

        uint256 decodedBalance = abi.decode(result.data, (uint256));
        assertEq(decodedBalance, 100, "Delegatecall via readInternal should return correct balance");
    }
}