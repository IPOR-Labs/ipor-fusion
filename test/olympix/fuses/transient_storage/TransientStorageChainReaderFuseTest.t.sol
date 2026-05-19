// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/transient_storage/TransientStorageChainReaderFuse.sol

import {TransientStorageChainReaderFuse} from "contracts/fuses/transient_storage/TransientStorageChainReaderFuse.sol";

import {TransientStorageChainReaderFuse, ExternalCalls, ExternalCall, ReadDataFromResponse} from "contracts/fuses/transient_storage/TransientStorageChainReaderFuse.sol";
import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
import {DataType} from "contracts/libraries/TypeConversionLib.sol";
import {MockTarget, TransientStorageChainReaderFuseMock} from "test/fuses/transient_storage/TransientStorageChainReaderFuseMock.sol";
contract TransientStorageChainReaderFuseTest is OlympixUnitTest("TransientStorageChainReaderFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_extractBytes32LengthLessThan32() public {
            // Use the delegatecall proxy so enter() writes outputs into the proxy's transient
            // storage and the subsequent getOutputs() reads from the same context.
            TransientStorageChainReaderFuse fuse = new TransientStorageChainReaderFuse();
            TransientStorageChainReaderFuseMock proxy = new TransientStorageChainReaderFuseMock(address(fuse));
            MockTarget target = new MockTarget();

            uint256 value = 0x1234;
            bytes memory callData = abi.encodeWithSelector(MockTarget.returnUint256.selector, value);

            ReadDataFromResponse[] memory readers = new ReadDataFromResponse[](1);
            readers[0] = ReadDataFromResponse({
                dataType: DataType.UINT256,
                bytesStart: 30,
                bytesEnd: 32
            });

            ExternalCall[] memory calls = new ExternalCall[](1);
            calls[0] = ExternalCall({
                target: address(target),
                targetCalldata: callData,
                readers: readers
            });

            ExternalCalls memory extCalls = ExternalCalls({calls: calls, responseLength: 1});

            bytes memory encoded = abi.encode(extCalls);
            proxy.enter(encoded);

            bytes32[] memory outputs = proxy.getOutputs(address(fuse));
            assertEq(outputs.length, 1, "unexpected outputs length");
            assertEq(uint256(outputs[0]), value, "decoded value mismatch");
        }
}