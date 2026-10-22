// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {EnforcedOptionParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppOptionsType3.sol";

import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {CrosschainConstants} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {MockLzEndpoint} from "./mocks/MockLzEndpoint.sol";
import {StargateExecutorDeploymentLib} from "../../contracts/crosschain/stargate/lib/StargateExecutorDeploymentLib.sol";

/// @title ExecutorRegisterChainOptionsTest
/// @notice Regression cover for `unrepairable_one_shot_config_bricks_command_lane` (IL-8296): before this
///         fix, `registerChain` accepted enforced options that gave the command lane no usable executor
///         `lzReceive` gas, so the LayerZero endpoint would refuse the resulting sends and the auto
///         `UPDATE_VAULTS` ACK would revert permanently. `registerChain` now validates the command-lane
///         options through `StargateExecutorDeploymentLib.validateRegistration` before writing the path,
///         and accepts only the exact `addExecutorLzReceiveOption(gas, 0)` shape with gas in the
///         command-lane bounds (review of d745492: unbounded gas, lzReceive value and native drop bricked
///         the path the same way).
contract ExecutorRegisterChainOptionsTest is CrosschainTestBase {
    using OptionsBuilder for bytes;

    uint16 internal constant COMPOSE_MSG_TYPE = 2;
    uint128 internal constant MIN_GAS = StargateExecutorDeploymentLib.COMMAND_LANE_MIN_RECEIVE_GAS;
    uint128 internal constant MAX_GAS = StargateExecutorDeploymentLib.COMMAND_LANE_MAX_RECEIVE_GAS;

    function setUp() public {
        _baseSetUp();
    }

    // ---------------------------------------------------------------------
    // 1. Empty enforced options
    // ---------------------------------------------------------------------

    function testShouldRevertRegisterChainWithEmptyEnforcedOptions() public {
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.CommandLaneOptionsInvalid.selector, REMOTE_EID));
        executor.registerChain(REMOTE_CHAIN, REMOTE_EID, "");
    }

    // ---------------------------------------------------------------------
    // 2. Only a compose (msgType 2) entry, no msgType 1 entry at all
    // ---------------------------------------------------------------------

    function testShouldRevertRegisterChainWithOnlyComposeOptionEntry() public {
        EnforcedOptionParam[] memory options = new EnforcedOptionParam[](1);
        options[0] = EnforcedOptionParam({
            eid: REMOTE_EID,
            msgType: COMPOSE_MSG_TYPE,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(250_000, 0).addExecutorLzComposeOption(
                0,
                1_500_000,
                0
            )
        });

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.CommandLaneOptionsInvalid.selector, REMOTE_EID));
        executor.registerChain(REMOTE_CHAIN, REMOTE_EID, abi.encode(options));
    }

    // ---------------------------------------------------------------------
    // 3. Type-3 header only, no TLV entries at all (the endpoint quote reverts `Executor_NoOptions()`)
    // ---------------------------------------------------------------------

    function testShouldRevertRegisterChainWithHeaderOnlyCommandLaneOptions() public {
        EnforcedOptionParam[] memory options = new EnforcedOptionParam[](1);
        options[0] = EnforcedOptionParam({eid: REMOTE_EID, msgType: 1, options: OptionsBuilder.newOptions()});

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.CommandLaneOptionsInvalid.selector, REMOTE_EID));
        executor.registerChain(REMOTE_CHAIN, REMOTE_EID, abi.encode(options));
    }

    // ---------------------------------------------------------------------
    // 4. lzReceive option present but gas == 0 (the endpoint quote reverts `Executor_ZeroLzReceiveGasProvided()`)
    // ---------------------------------------------------------------------

    function testShouldRevertRegisterChainWithZeroLzReceiveGas() public {
        EnforcedOptionParam[] memory options = new EnforcedOptionParam[](1);
        options[0] = EnforcedOptionParam({
            eid: REMOTE_EID,
            msgType: 1,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(0, 0)
        });

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.CommandLaneOptionsInvalid.selector, REMOTE_EID));
        executor.registerChain(REMOTE_CHAIN, REMOTE_EID, abi.encode(options));
    }

    // ---------------------------------------------------------------------
    // 5. Only a native-drop executor option, no lzReceive option
    // ---------------------------------------------------------------------

    function testShouldRevertRegisterChainWithNativeDropOnlyOptions() public {
        EnforcedOptionParam[] memory options = new EnforcedOptionParam[](1);
        options[0] = EnforcedOptionParam({
            eid: REMOTE_EID,
            msgType: 1,
            options: OptionsBuilder.newOptions().addExecutorNativeDropOption(
                1,
                bytes32(uint256(uint160(address(0xBEEF))))
            )
        });

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.CommandLaneOptionsInvalid.selector, REMOTE_EID));
        executor.registerChain(REMOTE_CHAIN, REMOTE_EID, abi.encode(options));
    }

    // ---------------------------------------------------------------------
    // 6. Two msgType-1 entries, last one invalid: last entry wins, so the whole registration reverts
    // ---------------------------------------------------------------------

    function testShouldRevertRegisterChainWhenLastDuplicateEntryIsInvalid() public {
        EnforcedOptionParam[] memory options = new EnforcedOptionParam[](2);
        options[0] = EnforcedOptionParam({
            eid: REMOTE_EID,
            msgType: 1,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(3_000_000, 0)
        });
        options[1] = EnforcedOptionParam({
            eid: REMOTE_EID,
            msgType: 1,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(0, 0)
        });

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.CommandLaneOptionsInvalid.selector, REMOTE_EID));
        executor.registerChain(REMOTE_CHAIN, REMOTE_EID, abi.encode(options));
    }

    // ---------------------------------------------------------------------
    // 7. Two msgType-1 entries, last one valid: succeeds; documents last-wins (passes at HEAD too)
    // ---------------------------------------------------------------------

    function testShouldRegisterChainWhenLastDuplicateEntryIsValid() public {
        bytes memory validOptions = OptionsBuilder.newOptions().addExecutorLzReceiveOption(3_000_000, 0);

        EnforcedOptionParam[] memory options = new EnforcedOptionParam[](2);
        options[0] = EnforcedOptionParam({
            eid: REMOTE_EID,
            msgType: 1,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(0, 0)
        });
        options[1] = EnforcedOptionParam({eid: REMOTE_EID, msgType: 1, options: validOptions});

        vm.prank(manager);
        executor.registerChain(REMOTE_CHAIN, REMOTE_EID, abi.encode(options));

        assertEq(executor.enforcedOptions(REMOTE_EID, 1), validOptions, "the later duplicate is the stored blob");
    }

    // ---------------------------------------------------------------------
    // 8. Positive control mirroring StargateTwoSidedBase's shape: lzReceive + compose entries; succeeds
    //    at HEAD and after
    // ---------------------------------------------------------------------

    function testShouldRegisterChainWithLzReceiveAndComposeEntries() public {
        EnforcedOptionParam[] memory options = new EnforcedOptionParam[](2);
        options[0] = EnforcedOptionParam({
            eid: REMOTE_EID,
            msgType: 1,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(3_000_000, 0)
        });
        options[1] = EnforcedOptionParam({
            eid: REMOTE_EID,
            msgType: COMPOSE_MSG_TYPE,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(250_000, 0).addExecutorLzComposeOption(
                0,
                1_500_000,
                0
            )
        });

        vm.prank(manager);
        executor.registerChain(REMOTE_CHAIN, REMOTE_EID, abi.encode(options));

        assertEq(executor.registeredChainCount(), 1, "chain counted as registered");
        assertEq(executor.eidOf(REMOTE_CHAIN), REMOTE_EID, "path bijection written");
    }

    // ---------------------------------------------------------------------
    // 9. Gas bounds: gas just outside [MIN_GAS, MAX_GAS] reverts (2^100 is the review's unpayable-fee
    //    PoC), gas exactly on either bound registers
    // ---------------------------------------------------------------------

    function testShouldRevertRegisterChainWithLzReceiveGasBelowMinimum() public {
        _expectRegisterRevert(OptionsBuilder.newOptions().addExecutorLzReceiveOption(MIN_GAS - 1, 0));
    }

    function testShouldRevertRegisterChainWithLzReceiveGasOfOne() public {
        _expectRegisterRevert(OptionsBuilder.newOptions().addExecutorLzReceiveOption(1, 0));
    }

    function testShouldRevertRegisterChainWithLzReceiveGasAboveMaximum() public {
        _expectRegisterRevert(OptionsBuilder.newOptions().addExecutorLzReceiveOption(MAX_GAS + 1, 0));
    }

    function testShouldRevertRegisterChainWithUnpayableLzReceiveGas() public {
        _expectRegisterRevert(OptionsBuilder.newOptions().addExecutorLzReceiveOption(uint128(1) << 100, 0));
    }

    function testShouldRegisterChainWithLzReceiveGasAtMinimum() public {
        _expectRegisterSuccess(OptionsBuilder.newOptions().addExecutorLzReceiveOption(MIN_GAS, 0));
    }

    function testShouldRegisterChainWithLzReceiveGasAtMaximum() public {
        _expectRegisterSuccess(OptionsBuilder.newOptions().addExecutorLzReceiveOption(MAX_GAS, 0));
    }

    // ---------------------------------------------------------------------
    // 10. Truncated TLV body inside the msgType-1 options blob: refused with the custom error, never a
    //     BytesLib panic
    // ---------------------------------------------------------------------

    function testShouldRevertRegisterChainWithTruncatedOptionTlv() public {
        // [type3 header 0x0003][workerId 0x01][size 0x0011 = 17][optionType 0x01] + 8 bytes of a
        // declared-17-byte body that is actually only 9 bytes long.
        bytes memory truncated = hex"0003"
        hex"01"
        hex"0011"
        hex"01"
        hex"0000000000000000";

        EnforcedOptionParam[] memory options = new EnforcedOptionParam[](1);
        options[0] = EnforcedOptionParam({eid: REMOTE_EID, msgType: 1, options: truncated});

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.CommandLaneOptionsInvalid.selector, REMOTE_EID));
        executor.registerChain(REMOTE_CHAIN, REMOTE_EID, abi.encode(options));
    }

    // ---------------------------------------------------------------------
    // 10a. lzReceive option present but with a 19-byte payload (TLV size 20): in bounds, so a check
    //      requiring only `size >= 17` would let it through, reading a "gas" out of a payload
    //      `ExecutorOptions.decodeLzReceiveOption` (16- or 32-byte payload only) never accepts. Reverts.
    // ---------------------------------------------------------------------

    function testShouldRevertRegisterChainWithOversizedLzReceivePayload() public {
        // [type3 header 0x0003][workerId 0x01][size 0x0014 = 20][optionType 0x01]
        //   [gas, 16 B, value 2_000_000][3 B of trailing padding] -> 19-byte payload, size 20.
        bytes memory oversized = hex"0003"
        hex"01"
        hex"0014"
        hex"01"
        hex"000000000000000000000000001e8480"
        hex"000000";

        EnforcedOptionParam[] memory options = new EnforcedOptionParam[](1);
        options[0] = EnforcedOptionParam({eid: REMOTE_EID, msgType: 1, options: oversized});

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.CommandLaneOptionsInvalid.selector, REMOTE_EID));
        executor.registerChain(REMOTE_CHAIN, REMOTE_EID, abi.encode(options));
    }

    // ---------------------------------------------------------------------
    // 10b. A well-formed lzReceive option (size 17) followed, in the same blob, by the oversized (size 20)
    //      one from 10a: on a mainnet fork, the live endpoint rejects a malformed lzReceive option
    //      anywhere in the blob, even after a valid one was already seen; this parser now mirrors that
    //      per-option size rule (`ExecutorOptions.decodeLzReceiveOption`: 16- or 32-byte payload only).
    //      Reverts.
    // ---------------------------------------------------------------------

    function testShouldRevertRegisterChainWithValidLzReceiveFollowedByOversizedOne() public {
        bytes memory validTlv = OptionsBuilder.newOptions().addExecutorLzReceiveOption(3_000_000, 0);
        // Same oversized (size 20) TLV as 10a, without its own type-3 header (appended into one blob).
        bytes memory oversizedTlv = hex"01" hex"0014" hex"01" hex"000000000000000000000000001e8480" hex"000000";
        bytes memory blob = abi.encodePacked(validTlv, oversizedTlv);

        EnforcedOptionParam[] memory options = new EnforcedOptionParam[](1);
        options[0] = EnforcedOptionParam({eid: REMOTE_EID, msgType: 1, options: blob});

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.CommandLaneOptionsInvalid.selector, REMOTE_EID));
        executor.registerChain(REMOTE_CHAIN, REMOTE_EID, abi.encode(options));
    }

    // ---------------------------------------------------------------------
    // 10c. lzReceive with a native value (TLV size 33) reverts: a value above the destination executor's
    //      native cap makes the endpoint quote revert `Executor_NativeAmountExceedsCap` (review PoC,
    //      1e24), and the command lane never needs one, so any value is refused.
    // ---------------------------------------------------------------------

    function testShouldRevertRegisterChainWithLzReceiveValue() public {
        _expectRegisterRevert(OptionsBuilder.newOptions().addExecutorLzReceiveOption(3_000_000, 1e24));
    }

    function testShouldRevertRegisterChainWithLzReceiveValueOfOne() public {
        _expectRegisterRevert(OptionsBuilder.newOptions().addExecutorLzReceiveOption(3_000_000, 1));
    }

    // ---------------------------------------------------------------------
    // 10d. A valid lzReceive option followed by any other option in the same blob reverts: native drop
    //      (review PoC, 1e24), compose, a second lzReceive, or a skipped DVN option of maximum size.
    // ---------------------------------------------------------------------

    function testShouldRevertRegisterChainWithValidLzReceiveAndNativeDrop() public {
        _expectRegisterRevert(
            OptionsBuilder.newOptions().addExecutorLzReceiveOption(3_000_000, 0).addExecutorNativeDropOption(
                1e24,
                bytes32(uint256(uint160(address(0xBEEF))))
            )
        );
    }

    function testShouldRevertRegisterChainWithValidLzReceiveAndCompose() public {
        _expectRegisterRevert(
            OptionsBuilder.newOptions().addExecutorLzReceiveOption(3_000_000, 0).addExecutorLzComposeOption(
                0,
                1_500_000,
                0
            )
        );
    }

    function testShouldRevertRegisterChainWithZeroThenNonZeroLzReceiveInSameBlob() public {
        _expectRegisterRevert(
            OptionsBuilder.newOptions().addExecutorLzReceiveOption(0, 0).addExecutorLzReceiveOption(3_000_000, 0)
        );
    }

    function testShouldRevertRegisterChainWithValidLzReceiveFollowedByMaxSizeSkippedOption() public {
        bytes memory validTlv = OptionsBuilder.newOptions().addExecutorLzReceiveOption(3_000_000, 0);
        // [workerId 0x02 (DVN, not the executor)][size 0xFFFF = 65535][65535 B of body].
        bytes memory skippedTlv = abi.encodePacked(hex"02", uint16(65535), new bytes(65535));
        _expectRegisterRevert(abi.encodePacked(validTlv, skippedTlv));
    }

    // ---------------------------------------------------------------------
    // 10e. 22-byte blobs with the right length and gas but a wrong header byte revert: options type,
    //      worker id and option type are all pinned.
    // ---------------------------------------------------------------------

    function testShouldRevertRegisterChainWithWrongOptionsType() public {
        _expectRegisterRevert(abi.encodePacked(hex"0002" hex"01" hex"0011" hex"01", uint128(3_000_000)));
    }

    function testShouldRevertRegisterChainWithNonExecutorWorker() public {
        _expectRegisterRevert(abi.encodePacked(hex"0003" hex"02" hex"0011" hex"01", uint128(3_000_000)));
    }

    function testShouldRevertRegisterChainWithNonLzReceiveOptionType() public {
        _expectRegisterRevert(abi.encodePacked(hex"0003" hex"01" hex"0011" hex"02", uint128(3_000_000)));
    }

    // ---------------------------------------------------------------------
    // 10f. The oversized (size 20) lzReceive TLV from 10a, placed BEFORE a valid one in the same blob,
    //      reverts `CommandLaneOptionsInvalid`.
    // ---------------------------------------------------------------------

    function testShouldRevertRegisterChainWithOversizedLzReceiveBeforeValidOne() public {
        // Single type-3 header, then the same oversized (size 20) TLV as 10a, then a well-formed
        // (size 17) lzReceive TLV that the walk never reaches.
        bytes memory oversizedTlv = hex"01" hex"0014" hex"01" hex"000000000000000000000000001e8480" hex"000000";
        bytes memory validTlv = hex"01" hex"0011" hex"01" hex"000000000000000000000000001e8480";
        bytes memory blob = abi.encodePacked(hex"0003", oversizedTlv, validTlv);

        EnforcedOptionParam[] memory options = new EnforcedOptionParam[](1);
        options[0] = EnforcedOptionParam({eid: REMOTE_EID, msgType: 1, options: blob});

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.CommandLaneOptionsInvalid.selector, REMOTE_EID));
        executor.registerChain(REMOTE_CHAIN, REMOTE_EID, abi.encode(options));
    }

    // ---------------------------------------------------------------------
    // 11. Fold preservation: the factory path-mismatch check still runs, same selector, at HEAD and after
    // ---------------------------------------------------------------------

    function testShouldRevertRegisterChainWhenFactoryPathMismatch() public {
        bytes memory validOptions = abi.encode(_singleValidOption(REMOTE_EID + 1));

        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(CrosschainErrors.FactoryPathMismatch.selector, REMOTE_CHAIN, REMOTE_EID + 1)
        );
        executor.registerChain(REMOTE_CHAIN, REMOTE_EID + 1, validOptions);
    }

    // ---------------------------------------------------------------------
    // 12. Fold preservation: the chain cap check still runs, same selector, at HEAD and after
    // ---------------------------------------------------------------------

    function testShouldRevertRegisterChainWhenChainCapReached() public {
        uint256 maxChains = CrosschainConstants.MAX_DISPATCHER_CHAINS;
        // REMOTE_CHAIN/REMOTE_EID is already wired by `_baseSetUp`; use a disjoint block of ids so none
        // collides with LOCAL_CHAIN (1) or REMOTE_CHAIN (42161) / REMOTE_EID (30110).
        for (uint256 i; i < maxChains - 1; ++i) {
            uint256 chainId = 90_000 + i;
            uint32 eid = uint32(90_000 + i);
            factory.setPath(chainId, eid);
            vm.prank(manager);
            executor.registerChain(chainId, eid, abi.encode(_singleValidOption(eid)));
        }
        assertEq(executor.registeredChainCount(), maxChains - 1, "cap - 1 chains registered so far");

        // One more registration (the REMOTE_CHAIN path from setUp) pushes the count to the cap.
        vm.prank(manager);
        executor.registerChain(REMOTE_CHAIN, REMOTE_EID, abi.encode(_singleValidOption(REMOTE_EID)));
        assertEq(executor.registeredChainCount(), maxChains, "cap reached");

        uint256 oneMoreChainId = 91_000;
        uint32 oneMoreEid = 91_000;
        factory.setPath(oneMoreChainId, oneMoreEid);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.DispatcherChainsCapReached.selector, maxChains));
        executor.registerChain(oneMoreChainId, oneMoreEid, abi.encode(_singleValidOption(oneMoreEid)));
    }

    // ---------------------------------------------------------------------
    // 13. End-to-end demonstration: the missing-options bug would otherwise only surface downstream, at
    //     the auto UPDATE_VAULTS ACK send, on an append-only path that can never be repaired; with the
    //     fix, `registerChain` itself refuses the registration up front, before that state is ever
    //     reached. Needs the mock endpoint's `setRequireExecutorOptions` switch to approximate the real
    //     endpoint's reverts.
    // ---------------------------------------------------------------------

    function testShouldNotBrickDispatcherAckWhenRegisteredWithoutCommandLaneOptions() public {
        endpoint.setRequireExecutorOptions(true);

        // The defective registration is rejected at the source: `registerChain` itself now reverts, so
        // the chain never reaches a state where the later ACK could revert and brick it (IL-8296). This
        // first assertion is exactly the one that is RED at HEAD (there, this call succeeds and the
        // brick appears two steps later, at the ACK).
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.CommandLaneOptionsInvalid.selector, REMOTE_EID));
        executor.registerChain(REMOTE_CHAIN, REMOTE_EID, "");

        // Registering correctly and carrying the chain through request/ack must work end to end and must
        // not hit the mock's options guard, showing the options the registration guard requires are
        // sufficient for the mock's approximation of the endpoint's minimum-options check.
        vm.prank(manager);
        executor.registerChain(REMOTE_CHAIN, REMOTE_EID, abi.encode(_singleValidOption(REMOTE_EID)));

        address[] memory emptyVaults = new address[](0);
        vm.prank(manager);
        executor.createDispatcher(REMOTE_CHAIN, emptyVaults);
        factory.ackDispatcher(address(executor), 1, REMOTE_CHAIN);

        assertTrue(executor.hasDispatcher(REMOTE_CHAIN), "dispatcher readiness flipped, ACK did not revert");
        MockLzEndpoint.SentMessage memory updateVaults = endpoint.lastSent();
        assertGt(updateVaults.options.length, 2, "auto UPDATE_VAULTS carries usable executor options");
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _expectRegisterRevert(bytes memory commandLaneOptions_) internal {
        EnforcedOptionParam[] memory options = new EnforcedOptionParam[](1);
        options[0] = EnforcedOptionParam({eid: REMOTE_EID, msgType: 1, options: commandLaneOptions_});

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.CommandLaneOptionsInvalid.selector, REMOTE_EID));
        executor.registerChain(REMOTE_CHAIN, REMOTE_EID, abi.encode(options));
    }

    function _expectRegisterSuccess(bytes memory commandLaneOptions_) internal {
        EnforcedOptionParam[] memory options = new EnforcedOptionParam[](1);
        options[0] = EnforcedOptionParam({eid: REMOTE_EID, msgType: 1, options: commandLaneOptions_});

        vm.prank(manager);
        executor.registerChain(REMOTE_CHAIN, REMOTE_EID, abi.encode(options));

        assertEq(executor.registeredChainCount(), 1, "chain counted as registered");
        assertEq(executor.enforcedOptions(REMOTE_EID, 1), commandLaneOptions_, "command-lane blob stored");
    }

    function _singleValidOption(uint32 eid_) internal pure returns (EnforcedOptionParam[] memory options) {
        options = new EnforcedOptionParam[](1);
        options[0] = EnforcedOptionParam({
            eid: eid_,
            msgType: 1,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(3_000_000, 0)
        });
    }
}
