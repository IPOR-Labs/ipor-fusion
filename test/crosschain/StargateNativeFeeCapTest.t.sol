// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {EnforcedOptionParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppOptionsType3.sol";

import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {BusinessAction} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CrosschainMessages, Command, UpdateVaults} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {StargateCrosschainDispatcher} from "../../contracts/crosschain/stargate/StargateCrosschainDispatcher.sol";
import {DEFAULT_COMMAND_BUDGET} from "./CommandBudget.sol";

/// @title StargateNativeFeeCapTest
/// @notice Regression coverage for IL-8050: the factory-held per-destination native fee ceiling
///         (`StargateNativeFeeCapLib`), enforced inside `StargateLzSendLib`/`StargateAssetSendLib` between
///         the quote and the solvency check, applies only to apps the factory lists in `isExecutor` — every
///         executor send is covered (including the enforced-options-only sends) while dispatcher sends and
///         the factory's own sends are structurally excluded.
contract StargateNativeFeeCapTest is CrosschainTestBase {
    using OptionsBuilder for bytes;

    /// @dev Matches the mocks' default fixed fee (`MockLzEndpoint`/`MockStargatePool`).
    uint256 internal constant CAP = 1e14;

    function setUp() public {
        _baseSetUp();
    }

    function _trivialCommand() internal pure returns (Command memory) {
        return
            Command({
                commandId: bytes32(0),
                sequence: 0,
                commandConfigEpoch: 0,
                action: uint8(BusinessAction.DEPOSIT),
                minExecutionGas: DEFAULT_COMMAND_BUDGET,
                actionData: CrosschainMessages.encodeDepositAction(address(0xBEEF), 1e6, 0)
            });
    }

    // ---------------------------------------------------------------------
    // 1. Asset send above the ceiling reverts, and leaves no side effect behind
    // ---------------------------------------------------------------------

    function testShouldRejectAssetSendAboveMaxNativeFee() public {
        _readyDispatcher();
        factory.setExecutor(address(executor), true);
        factory.setMaxNativeFee(REMOTE_CHAIN, CAP);
        pool.setAssetFee(CAP + 1);

        usdc.mint(address(executor), 100e6);
        uint256 nativeBefore = address(executor).balance;
        uint256 usdcBefore = usdc.balanceOf(address(executor));
        uint256 allowanceBefore = usdc.allowance(address(executor), address(pool));

        vm.recordLogs();
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.NativeFeeTooHigh.selector, CAP + 1, CAP));
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e6, 0, "");

        assertEq(address(executor).balance, nativeBefore, "native balance unchanged");
        assertEq(usdc.balanceOf(address(executor)), usdcBefore, "usdc balance unchanged");
        assertEq(usdc.allowance(address(executor), address(pool)), allowanceBefore, "no allowance left behind");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != ASSET_SENT_TOPIC, "no AssetSentToDispatcher on a reverted send");
        }
    }

    // ---------------------------------------------------------------------
    // 2. Recall request above the ceiling reverts even with hostile native-drop options
    // ---------------------------------------------------------------------

    function testShouldRejectRecallRequestAboveMaxNativeFee() public {
        _readyDispatcher();
        _settle100();
        factory.setExecutor(address(executor), true);
        factory.setMaxNativeFee(REMOTE_CHAIN, CAP);
        endpoint.setMessagingFee(CAP + 1);

        address attacker = address(0xBAD);
        bytes memory hostileOptions = OptionsBuilder.newOptions().addExecutorNativeDropOption(
            1 ether,
            bytes32(uint256(uint160(attacker)))
        );

        uint256 nativeBefore = address(executor).balance;
        // No public `activeReturnRequest` getter exists on the executor (deviation from plan §5 test 2's
        // exact assertion); `returnInFlight` is the accounting counter a successful request would have
        // moved, so its being unchanged proves the request never took effect.
        uint256 returnInFlightBefore = executor.returnInFlight(REMOTE_CHAIN);

        vm.recordLogs();
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.NativeFeeTooHigh.selector, CAP + 1, CAP));
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 10e6, 0, hostileOptions);

        assertEq(address(executor).balance, nativeBefore, "native balance unchanged");
        assertEq(executor.returnInFlight(REMOTE_CHAIN), returnInFlightBefore, "no return request recorded");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != RETURN_REQUESTED_TOPIC, "no ReturnRequested on a reverted send");
        }
    }

    // ---------------------------------------------------------------------
    // 3. The ceiling also covers the "" (enforced-options-only) executor sends
    // ---------------------------------------------------------------------

    function testShouldRejectCommandAboveMaxNativeFee() public {
        _readyDispatcher();
        factory.setExecutor(address(executor), true);
        factory.setMaxNativeFee(REMOTE_CHAIN, CAP);
        endpoint.setMessagingFee(CAP + 1);

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.NativeFeeTooHigh.selector, CAP + 1, CAP));
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _trivialCommand());
    }

    // ---------------------------------------------------------------------
    // 4. A quote exactly at the ceiling is admitted (`>`, not `>=`)
    // ---------------------------------------------------------------------

    function testShouldSendAtExactMaxNativeFee() public {
        _readyDispatcher();
        factory.setExecutor(address(executor), true);
        factory.setMaxNativeFee(REMOTE_CHAIN, CAP);
        pool.setAssetFee(CAP);

        usdc.mint(address(executor), 100e6);
        uint256 nativeBefore = address(executor).balance;

        vm.recordLogs();
        vm.prank(manager);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e6, 0, "");

        assertEq(nativeBefore - address(executor).balance, CAP, "exactly the cap paid, send not blocked");
        _captureAssetSent(); // reverts with "AssetSentToDispatcher not emitted" if the send did not go through
    }

    // ---------------------------------------------------------------------
    // 5. Zero (unset ceiling) means blocked, fail-closed, for a registered executor
    // ---------------------------------------------------------------------

    function testShouldBlockExecutorSendsWhileMaxNativeFeeUnset() public {
        _readyDispatcher();
        factory.setExecutor(address(executor), true);
        // maxNativeFee[REMOTE_CHAIN] left at its zero default.

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.NativeFeeTooHigh.selector, CAP, uint256(0)));
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _trivialCommand());
    }

    // ---------------------------------------------------------------------
    // 6. An executor the factory does not list in `isExecutor` stays uncapped
    // ---------------------------------------------------------------------

    function testShouldLeaveExecutorUncappedWhenFactoryDoesNotListIt() public {
        _readyDispatcher();
        factory.setMaxNativeFee(REMOTE_CHAIN, 1); // a 1 wei ceiling that would block every real send
        // isExecutor(address(executor)) is left false (the mock's default).

        uint256 sentBefore = endpoint.sentCount();
        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _trivialCommand());

        assertEq(endpoint.sentCount(), sentBefore + 1, "send proceeded: the probe never reached the ceiling");
    }

    // ---------------------------------------------------------------------
    // 7. A dispatcher is never capped, even when its own factory has code, lists a ceiling for the
    //    dispatcher's send target, and answers `isExecutor(dispatcher) == false`
    // ---------------------------------------------------------------------

    function testShouldNotCapDispatcherSendsByFactoryCeiling() public {
        // A ceiling for the chain the dispatcher sends its ACK to (the executor's chain) — the dispatcher
        // must ignore it, because `factory.isExecutor(address(dispatcher))` is false.
        factory.setMaxNativeFee(LOCAL_CHAIN, 1);

        EnforcedOptionParam[] memory enforcedOptions = new EnforcedOptionParam[](2);
        enforcedOptions[0] = EnforcedOptionParam({
            eid: LOCAL_EID,
            msgType: 1,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(2_000_000, 0)
        });
        enforcedOptions[1] = EnforcedOptionParam({
            eid: LOCAL_EID,
            msgType: 2,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(250_000, 0).addExecutorLzComposeOption(
                0,
                1_500_000,
                0
            )
        });
        bytes memory args = abi.encode(
            address(endpoint),
            address(usdc),
            address(pool),
            ASSET_ID,
            address(factory), // a REAL factory (has code), unlike StargateTwoSidedBase's address(0xF)
            admin,
            guardian,
            RESCUE_DELAY,
            LOCAL_CHAIN,
            LOCAL_EID,
            abi.encode(enforcedOptions)
        );
        vm.chainId(REMOTE_CHAIN); // `_registerPath` in the constructor rejects the dispatcher's own chain
        StargateCrosschainDispatcher dispatcher = StargateCrosschainDispatcher(
            payable(vm.deployCode("StargateCrosschainDispatcher.sol:StargateCrosschainDispatcher", args))
        );
        vm.chainId(LOCAL_CHAIN);
        vm.deal(address(dispatcher), 100 ether);

        assertFalse(factory.isExecutor(address(dispatcher)), "dispatcher never written to isExecutor");

        uint256 sentBefore = endpoint.sentCount();
        bytes32 dispatcherPeer = bytes32(uint256(uint160(address(dispatcher))));
        endpoint.deliverLz(
            address(dispatcher),
            LOCAL_EID,
            dispatcherPeer,
            keccak256("uv-guid"),
            CrosschainMessages.encodeUpdateVaults(
                UpdateVaults({
                    commandId: keccak256("uv"),
                    sequence: 0,
                    newConfigEpoch: 1,
                    minExecutionGas: DEFAULT_COMMAND_BUDGET,
                    vaults: new address[](0)
                })
            )
        );

        assertEq(endpoint.sentCount(), sentBefore + 1, "dispatcher's ACK send is not capped by the factory ceiling");
        assertEq(
            dispatcher.commandConfigEpoch(),
            1,
            "UPDATE_VAULTS applied normally; no new revert path in _lzReceive"
        );
    }
}
