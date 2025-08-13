// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {CallbackHandlerReader} from "../../contracts/readers/CallbackHandlerReader.sol";
import {CallbackHandlerMorpho} from "../../contracts/handlers/callbacks/CallbackHandlerMorpho.sol";

contract CallbackHandlerReaderTest is Test {
    CallbackHandlerReader public reader;
    address public constant PLASMA_VAULT = 0xe9385eFf3F937FcB0f0085Da9A3F53D6C2B4fB5F;
    address public constant CallbackHandlerMorphoAddress = 0x4f9Cc0d7432B66EACa58064a2F0EA663A2F0b465;
    address public constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 22987150);

        // Deploy BalanceFusesReader
        reader = new CallbackHandlerReader();
    }

    function test_getCallbackHandler() public {
        // given

        // when
        address result = reader.getCallbackHandler(
            PLASMA_VAULT,
            MORPHO,
            CallbackHandlerMorpho.onMorphoFlashLoan.selector
        );

        // then
        assertEq(result, CallbackHandlerMorphoAddress);
    }

    function test_getCallbackHandler_not_found() public {
        // given
        address result = reader.getCallbackHandler(
            PLASMA_VAULT,
            address(this),
            CallbackHandlerMorpho.onMorphoFlashLoan.selector
        );

        // then
        assertEq(result, address(0));
    }

    function test_getCallbackHandlers() public {
        // given
        address[] memory senders = new address[](1);
        senders[0] = MORPHO;
        bytes4[] memory sigs = new bytes4[](1);
        sigs[0] = CallbackHandlerMorpho.onMorphoFlashLoan.selector;

        // when
        address[] memory result = reader.getCallbackHandlers(PLASMA_VAULT, senders, sigs);

        // then
        assertEq(result[0], CallbackHandlerMorphoAddress);
        assertEq(result.length, 1);
    }

    function test_getCallbackHandlers_not_found() public {
        // given
        address[] memory senders = new address[](2);
        senders[0] = MORPHO;
        senders[1] = address(this);
        bytes4[] memory sigs = new bytes4[](2);
        sigs[0] = CallbackHandlerMorpho.onMorphoFlashLoan.selector;
        sigs[1] = CallbackHandlerMorpho.onMorphoFlashLoan.selector;

        // when
        address[] memory result = reader.getCallbackHandlers(PLASMA_VAULT, senders, sigs);

        // then
        assertEq(result[0], CallbackHandlerMorphoAddress);
        assertEq(result.length, 2);
        assertEq(result[1], address(0));
    }
}
