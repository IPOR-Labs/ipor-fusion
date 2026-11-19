// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {EnforcedOptionParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppOptionsType3.sol";

import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {CcipClient} from "../../contracts/crosschain/ccip/interfaces/CcipClient.sol";
import {CcipMessages, CcipMsgType} from "../../contracts/crosschain/ccip/lib/CcipMessages.sol";
import {StargateCrosschainDispatcher} from "../../contracts/crosschain/stargate/StargateCrosschainDispatcher.sol";
import {MsgType, BusinessAction, CommandStatus} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CrosschainMessages, Command, OutboundTransfer} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {ValueNeutralToken} from "./CcipValueNeutralVersionTest.t.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";
import {MockRemoteVault} from "./mocks/MockRemoteVault.sol";
import {MockLzEndpoint} from "./mocks/MockLzEndpoint.sol";
import {MockStargatePool, LzComposeBuilder} from "./mocks/MockStargatePool.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";
import {DEFAULT_COMMAND_BUDGET} from "./CommandBudget.sol";

/// @dev Wire mirror of the IL-9629 `SweepFloor`, declared here so this file also compiles against the commit before
///      IL-9629 (the base-regression proof runs it there).
struct WireSweepFloor {
    address vault;
    uint256 minAssets;
}

/// @dev Wire mirror of the IL-9629 `UpdateVaults` (Stargate inner payload, six members).
struct WireUpdateVaults {
    bytes32 commandId;
    uint64 sequence;
    uint64 newConfigEpoch;
    uint64 minExecutionGas;
    address[] vaults;
    WireSweepFloor[] floors;
}

/// @dev Shared helpers of the two transport suites.
abstract contract SweepFloorTestBase is Test {
    /// @dev `CrosschainVaultActionLib.SWEEP_BELOW_MIN` (IL-9629), literal so the file compiles before IL-9629.
    uint8 internal constant SWEEP_BELOW_MIN = 6;
    /// @dev `CrosschainVaultActionLib.SweepBelowMinimum` selector.
    bytes4 internal constant SWEEP_BELOW_MINIMUM = bytes4(keccak256("SweepBelowMinimum(address,uint256,uint256)"));
    address internal constant ATTACKER = address(0xBAD);

    event TrackedVaultSwept(address vault, uint256 sharesRedeemed, uint256 assetsLD);
    event TrackedVaultSweepResidual(
        address vault,
        uint256 sharesLeft,
        uint8 reason,
        bytes4 redeemError,
        bool untracked
    );

    bytes32 internal constant SWEPT_TOPIC = keccak256("TrackedVaultSwept(address,uint256,uint256)");
    bytes32 internal constant RESIDUAL_TOPIC =
        keccak256("TrackedVaultSweepResidual(address,uint256,uint8,bytes4,bool)");

    /// @dev Pushes the spot share price of `vault_` down: `amount_` of its assets leave it (a manipulated price).
    function _manipulate(address vault_, address asset_, uint256 amount_) internal {
        vm.prank(vault_);
        IERC20(asset_).transfer(ATTACKER, amount_);
    }

    /// @dev Undoes `_manipulate`.
    function _restore(address vault_, address asset_, uint256 amount_) internal {
        vm.prank(ATTACKER);
        IERC20(asset_).transfer(vault_, amount_);
    }

    function _one(address v_) internal pure returns (address[] memory vaults) {
        vaults = new address[](1);
        vaults[0] = v_;
    }

    function _floor(address v_, uint256 minAssets_) internal pure returns (WireSweepFloor[] memory floors) {
        floors = new WireSweepFloor[](1);
        floors[0] = WireSweepFloor({vault: v_, minAssets: minAssets_});
    }

    /// @dev Sweep events (`TrackedVaultSwept` or `TrackedVaultSweepResidual`) of `emitter_` about `vault_`.
    function _sweepEvents(Vm.Log[] memory logs_, address emitter_, address vault_) internal pure returns (uint256 n) {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter != emitter_) continue;
            bytes32 topic = logs_[i].topics[0];
            if (topic != SWEPT_TOPIC && topic != RESIDUAL_TOPIC) continue;
            if (abi.decode(logs_[i].data, (address)) == vault_) ++n;
        }
    }
}

/// @title CcipVaultRemovalSweepFloorTest
/// @notice IL-9629 (M39) on the CCIP dispatcher. Removing a vault whose position is mispriced at spot (here: its assets
///         drained, so a redeem pays a sixth of the position's value) sold the position at that price and booked the
///         loss (IL-8784 sweep, no floor). With a `SweepFloor` the redeem is rolled back unless it pays the floor; the
///         vault then leaves the allowlist but STAYS TRACKED (in NAV) and ALPHA exits it with a REDEEM (Q23, D-051).
///         Codex 2.9: such a retained vault is touched by a later UPDATE_VAULTS only through an explicit floor entry.
///         Dispatcher-level tests inject the four-element `extra`; executor-level tests call the IL-9629 entry
///         `updateVaultsWithSweepFloors` by signature (this file compiles against the commit before IL-9629).
contract CcipVaultRemovalSweepFloorTest is SweepFloorTestBase {
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;
    address internal constant RESCUE_ADMIN = address(0xA11);
    address internal constant GUARDIAN = address(0xB22);
    address internal constant APPROVER = address(0xA33);
    string internal constant FLOORED_UPDATE =
        "updateVaultsWithSweepFloors(uint256,address[],bool,bool,(address,uint256)[],uint256,address,uint256)";

    MockCcipRouter internal router;
    ValueNeutralToken internal token;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;
    MockRemoteVault internal vaultA;
    MockRemoteVault internal vaultB;
    uint256 internal nonce;

    function setUp() public {
        router = new MockCcipRouter();
        token = new ValueNeutralToken();
        MockCcipRouteValidator routeValidator = new MockCcipRouteValidator();
        address factory = address(routeValidator);
        executor = new CcipCrosschainExecutor(
            address(router),
            factory,
            address(this),
            address(token),
            keccak256("USDC"),
            18,
            CcipCrosschainExecutor.SafetyConfig({
                rescueAdmin: RESCUE_ADMIN,
                rescueGuardian: GUARDIAN,
                balanceProposer: address(this),
                balanceApprover: APPROVER,
                rescueDelay: 3 days,
                balanceStalenessMax: 7 days,
                bigChangeBps: 2_000,
                anchorBandBps: 2_000,
                minUpdateInterval: 1 hours,
                transferStalenessMax: 1 days
            })
        );
        dispatcher = new CcipCrosschainDispatcher(
            address(router),
            factory,
            address(token),
            keccak256("USDC"),
            18,
            block.chainid,
            _route(EXECUTOR_SELECTOR, address(executor)),
            RESCUE_ADMIN,
            GUARDIAN,
            3 days
        );
        vaultA = new MockRemoteVault(IERC20(address(token)), "A", "A");
        vaultB = new MockRemoteVault(IERC20(address(token)), "B", "B");
        address[] memory vaults = new address[](2);
        vaults[0] = address(vaultA);
        vaults[1] = address(vaultB);
        vm.prank(factory);
        dispatcher.configureVaults(vaults, true);
        CcipRouteConfig memory executorRoute = _route(DISPATCHER_SELECTOR, address(dispatcher));
        routeValidator.setRoute(REMOTE_CHAIN, executorRoute);
        routeValidator.registerExecutorRoute(address(executor), REMOTE_CHAIN, executorRoute);
        router.setSelector(address(executor), EXECUTOR_SELECTOR);
        router.setSelector(address(dispatcher), DISPATCHER_SELECTOR);
        vm.prank(factory);
        executor.markDispatcherReady(REMOTE_CHAIN);
        vm.warp(1_700_000_000);
        vm.roll(1_000);

        // 100 idle + a 50 position in vault A whose spot price is pushed down to a fifth (the position is worth 10).
        token.mint(address(executor), 100e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e18, 0, address(0), 2_000_000);
        token.mint(address(this), 50e18);
        token.approve(address(vaultA), 50e18);
        vaultA.deposit(50e18, address(dispatcher));
        _manipulate(address(vaultA), address(token), 40e18);
    }

    function _route(uint64 selector_, address peer_) private pure returns (CcipRouteConfig memory) {
        return
            CcipRouteConfig({
                chainSelector: selector_,
                peer: peer_,
                feeToken: address(0),
                messageGasLimit: 3_000_000,
                tokenGasLimit: 2_000_000,
                maxFee: 0,
                enabled: true
            });
    }

    // ------------------------------------------------------------------ helpers

    /// @dev The IL-9629 executor entry, by signature.
    function _updateWithFloors(
        address[] memory vaults_,
        bool allowed_,
        bool replace_,
        WireSweepFloor[] memory floors_
    ) private {
        (bool ok, ) = address(executor).call(
            abi.encodeWithSignature(
                FLOORED_UPDATE,
                REMOTE_CHAIN,
                vaults_,
                allowed_,
                replace_,
                floors_,
                uint256(0),
                address(0),
                uint256(3_000_000)
            )
        );
        assertTrue(ok, "updateVaultsWithSweepFloors sent");
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "UPDATE_VAULTS acked");
    }

    function _update(address[] memory vaults_, bool allowed_, bool replace_) private {
        executor.updateVaults(REMOTE_CHAIN, vaults_, allowed_, replace_, 0, address(0), 3_000_000);
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "UPDATE_VAULTS acked");
    }

    function _redeem(address vault_, uint256 shares_, uint256 minAssets_) private {
        executor.sendCommandToDispatcher(
            REMOTE_CHAIN,
            Command({
                commandId: bytes32(0),
                sequence: 0,
                commandConfigEpoch: 0,
                action: uint8(BusinessAction.REDEEM),
                minExecutionGas: 0,
                actionData: CrosschainMessages.encodeRedeemAction(vault_, shares_, minAssets_)
            }),
            0,
            address(0),
            3_000_000
        );
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "REDEEM acked");
    }

    /// @dev Delivers an UPDATE_VAULTS straight to the dispatcher with the IL-9629 four-element `extra`. Callers stop the
    ///      router's auto-delivery first: the executor never sent this command, so its ACK stays with the router.
    function _inject(address[] memory vaults_, bool allowed_, WireSweepFloor[] memory floors_) private {
        bytes32 id = bytes32(((block.timestamp + 1 days) << 192) | ++nonce);
        bytes memory data = CcipMessages.encode(
            CcipMsgType.UPDATE_VAULTS,
            abi.encode(
                CcipMsgType.UPDATE_VAULTS,
                Command({
                    commandId: id,
                    sequence: dispatcher.nextCommandSequence(),
                    commandConfigEpoch: dispatcher.commandConfigEpoch(),
                    action: 0,
                    minExecutionGas: 0,
                    actionData: ""
                }),
                abi.encode(vaults_, allowed_, false, floors_)
            )
        );
        vm.prank(address(router));
        dispatcher.ccipReceive(
            CcipClient.Any2EVMMessage({
                messageId: keccak256(abi.encode("sweep-floor", nonce)),
                sourceChainSelector: EXECUTOR_SELECTOR,
                sender: abi.encode(address(executor)),
                data: data,
                destTokenAmounts: new CcipClient.EVMTokenAmount[](0)
            })
        );
        assertEq(uint8(dispatcher.commandStatus(id)), uint8(CommandStatus.SUCCEEDED), "injected UPDATE_VAULTS ran");
    }

    function _assertRetained(uint256 idle_) private view {
        assertFalse(dispatcher.isAllowedVault(address(vaultA)), "off the allowlist");
        assertTrue(dispatcher.isTrackedVault(address(vaultA)), "still tracked");
        assertEq(vaultA.balanceOf(address(dispatcher)), 50e18, "no share sold");
        assertEq(dispatcher.trackedIdle(), idle_, "nothing booked from a sale below the floor");
    }

    // ------------------------------------------------------------------ dispatcher level (injected)

    function testShouldKeepAVaultTrackedWhenTheInjectedFloorIsNotReached() public {
        router.setAutoDeliver(false);
        uint256 navBefore = dispatcher.accountedBalance();
        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultSweepResidual(address(vaultA), 50e18, SWEEP_BELOW_MIN, SWEEP_BELOW_MINIMUM, false);
        _inject(_one(address(vaultA)), false, _floor(address(vaultA), 45e18));
        _assertRetained(100e18);
        assertEq(dispatcher.accountedBalance(), navBefore, "the position still counts in NAV");
    }

    /// @dev Codex 2.9, both transports: a retained vault is left alone by an unrelated later command and swept by
    ///      the next command that names it in a floor entry.
    function testShouldSkipARetainedVaultUntilAnInjectedFloorEntryNamesIt() public {
        router.setAutoDeliver(false);
        _inject(_one(address(vaultA)), false, _floor(address(vaultA), 45e18));
        _assertRetained(100e18);

        vm.recordLogs();
        _inject(_one(address(vaultB)), false, new WireSweepFloor[](0));
        assertEq(_sweepEvents(vm.getRecordedLogs(), address(dispatcher), address(vaultA)), 0, "A untouched");
        assertFalse(dispatcher.isAllowedVault(address(vaultB)), "the unrelated removal ran");
        _assertRetained(100e18);

        _restore(address(vaultA), address(token), 40e18);
        _inject(new address[](0), false, _floor(address(vaultA), 49e18));
        assertFalse(dispatcher.isTrackedVault(address(vaultA)), "untracked by the named entry");
        assertEq(vaultA.balanceOf(address(dispatcher)), 0, "swept");
        assertEq(dispatcher.trackedIdle(), 150e18, "at the restored price");
    }

    // ------------------------------------------------------------------ executor entry (end to end)

    function testShouldKeepARemovedVaultTrackedWhenItsSweepFloorIsNotReached() public {
        uint256 navBefore = dispatcher.accountedBalance();
        assertEq(navBefore, 110e18, "precondition: 100 idle + the position at the manipulated price");
        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultSweepResidual(address(vaultA), 50e18, SWEEP_BELOW_MIN, SWEEP_BELOW_MINIMUM, false);
        _updateWithFloors(_one(address(vaultA)), false, false, _floor(address(vaultA), 45e18));
        _assertRetained(100e18);
        assertEq(dispatcher.accountedBalance(), navBefore, "the position still counts in NAV");
    }

    /// @dev After the retention ALPHA exits with a REDEEM at a fair price; on CCIP the emptied vault stays tracked (it is
    ///      worth 0) until a floor entry removes it.
    function testShouldExitARetainedPositionWithARedeemAtTheRestoredPrice() public {
        _updateWithFloors(_one(address(vaultA)), false, false, _floor(address(vaultA), 45e18));
        _restore(address(vaultA), address(token), 40e18);
        _redeem(address(vaultA), 50e18, 49e18);
        assertEq(vaultA.balanceOf(address(dispatcher)), 0, "redeemed");
        assertEq(dispatcher.trackedIdle(), 150e18, "at the restored price");

        _updateWithFloors(new address[](0), false, false, _floor(address(vaultA), 0));
        assertFalse(dispatcher.isTrackedVault(address(vaultA)), "the floor-0 entry frees the slot");
        assertEq(dispatcher.trackedIdle(), 150e18, "nothing more to sweep");
    }

    function testShouldSweepARemovedVaultWhoseFloorIsReached() public {
        _restore(address(vaultA), address(token), 40e18);
        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultSwept(address(vaultA), 50e18, 50e18);
        _updateWithFloors(_one(address(vaultA)), false, false, _floor(address(vaultA), 50e18));
        assertFalse(dispatcher.isTrackedVault(address(vaultA)), "untracked");
        assertEq(dispatcher.trackedIdle(), 150e18, "swept into idle");
    }

    /// @dev Pinning (passes before and after IL-9629): the floorless entry keeps the IL-8784 behaviour and sells at the
    ///      manipulated price. This is the reported loss; the floor above is the protection.
    function testShouldStillSellAtTheManipulatedPriceWithoutAFloor() public {
        _update(_one(address(vaultA)), false, false);
        assertFalse(dispatcher.isTrackedVault(address(vaultA)), "untracked");
        assertEq(vaultA.balanceOf(address(dispatcher)), 0, "sold");
        assertEq(dispatcher.trackedIdle(), 110e18, "for a fifth of the position");
    }

    /// @dev Codex 2.9 regression: command 1 retains A; commands 2 (a plain removal) and 3 (a replace) do not name A and
    ///      leave it alone, even though A is tracked and off the allowlist; command 4 names A in a floor entry and
    ///      sweeps it.
    function testShouldNotTouchARetainedVaultUntilAnExplicitFloorEntryNamesIt() public {
        _updateWithFloors(_one(address(vaultA)), false, false, _floor(address(vaultA), 45e18));
        _assertRetained(100e18);

        vm.recordLogs();
        _update(_one(address(vaultB)), false, false);
        assertEq(_sweepEvents(vm.getRecordedLogs(), address(dispatcher), address(vaultA)), 0, "removal: A untouched");
        _assertRetained(100e18);

        vm.recordLogs();
        _update(_one(address(vaultB)), true, true);
        assertEq(_sweepEvents(vm.getRecordedLogs(), address(dispatcher), address(vaultA)), 0, "replace: A untouched");
        assertTrue(dispatcher.isAllowedVault(address(vaultB)), "the replace ran");
        _assertRetained(100e18);

        _restore(address(vaultA), address(token), 40e18);
        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultSwept(address(vaultA), 50e18, 50e18);
        _updateWithFloors(new address[](0), false, false, _floor(address(vaultA), 49e18));
        assertFalse(dispatcher.isTrackedVault(address(vaultA)), "untracked by the named entry");
        assertEq(dispatcher.trackedIdle(), 150e18, "at the restored price");
    }

    /// @dev A floor of 0 in an explicit entry is the forced removal (D-028): it sweeps at whatever price.
    function testShouldForceRemoveARetainedVaultWithAZeroFloorEntry() public {
        _updateWithFloors(_one(address(vaultA)), false, false, _floor(address(vaultA), 45e18));
        _updateWithFloors(new address[](0), false, false, _floor(address(vaultA), 0));
        assertFalse(dispatcher.isTrackedVault(address(vaultA)), "untracked");
        assertEq(dispatcher.trackedIdle(), 110e18, "sold at the manipulated price, by choice");
    }

    /// @dev An explicit entry whose floor is still not reached retains the vault again.
    function testShouldRetainAgainWhenTheNamedFloorIsStillNotReached() public {
        _updateWithFloors(_one(address(vaultA)), false, false, _floor(address(vaultA), 45e18));
        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultSweepResidual(address(vaultA), 50e18, SWEEP_BELOW_MIN, SWEEP_BELOW_MINIMUM, false);
        _updateWithFloors(new address[](0), false, false, _floor(address(vaultA), 45e18));
        _assertRetained(100e18);
    }

    /// @dev A floor for a vault that stays allowlisted is carried and ignored.
    function testShouldIgnoreAFloorForAVaultThatStaysAllowlisted() public {
        _updateWithFloors(_one(address(vaultB)), false, false, _floor(address(vaultA), 45e18));
        assertTrue(dispatcher.isAllowedVault(address(vaultA)), "A stays allowlisted");
        assertTrue(dispatcher.isTrackedVault(address(vaultA)), "A stays tracked");
        assertEq(vaultA.balanceOf(address(dispatcher)), 50e18, "A not swept");
        assertFalse(dispatcher.isAllowedVault(address(vaultB)), "B removed");
    }
}

/// @title StargateVaultRemovalSweepFloorTest
/// @notice IL-9629 (M39) on the Stargate dispatcher: the same rules with the replace-only allowlist. The six-member
///         `UpdateVaults` is encoded here by hand (wire mirror) and delivered straight to the dispatcher.
contract StargateVaultRemovalSweepFloorTest is SweepFloorTestBase {
    using OptionsBuilder for bytes;

    uint256 internal constant DISPATCHER_CHAIN = 42161;
    uint256 internal constant EXECUTOR_CHAIN = 1;
    uint32 internal constant EXECUTOR_EID = 30101;
    bytes32 internal constant ASSET_ID = keccak256("USDC");
    bytes32 internal constant GUID = keccak256("guid");

    MockLzEndpoint internal endpoint;
    MockStargatePool internal pool;
    MockERC20 internal usdc;
    MockRemoteVault internal vaultA;
    MockRemoteVault internal vaultB;
    StargateCrosschainDispatcher internal dispatcher;
    uint256 internal nonce;

    function setUp() public {
        vm.chainId(DISPATCHER_CHAIN);
        vm.warp(365 days);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        pool = new MockStargatePool(address(usdc), 6);
        endpoint = new MockLzEndpoint();
        vaultA = new MockRemoteVault(IERC20(address(usdc)), "A", "A");
        vaultB = new MockRemoteVault(IERC20(address(usdc)), "B", "B");

        EnforcedOptionParam[] memory enforcedOptions = new EnforcedOptionParam[](2);
        enforcedOptions[0] = EnforcedOptionParam({
            eid: EXECUTOR_EID,
            msgType: 1,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(2_000_000, 0)
        });
        enforcedOptions[1] = EnforcedOptionParam({
            eid: EXECUTOR_EID,
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
            address(0xF),
            address(0xADADAD),
            address(0x6A6A6A),
            uint256(3 days),
            EXECUTOR_CHAIN,
            EXECUTOR_EID,
            abi.encode(enforcedOptions)
        );
        dispatcher = StargateCrosschainDispatcher(
            payable(vm.deployCode("StargateCrosschainDispatcher.sol:StargateCrosschainDispatcher", args))
        );
        vm.deal(address(dispatcher), 100 ether);

        // allowlist A, 100 idle, 50 deposited into A, then A's spot price pushed down to a fifth.
        _setVaults(_one(address(vaultA)), new WireSweepFloor[](0));
        _compose(100e6);
        _command(BusinessAction.DEPOSIT, CrosschainMessages.encodeDepositAction(address(vaultA), 50e6, 0));
        assertTrue(dispatcher.isTrackedVault(address(vaultA)), "precondition: A tracked");
        _manipulate(address(vaultA), address(usdc), 40e6);
    }

    // ------------------------------------------------------------------ helpers

    function _deliver(bytes memory envelope_) private {
        endpoint.deliverLz(
            address(dispatcher),
            EXECUTOR_EID,
            bytes32(uint256(uint160(address(dispatcher)))),
            GUID,
            envelope_
        );
    }

    /// @dev Replaces the allowlist with `vaults_` carrying `floors_` (hand-encoded IL-9629 `UpdateVaults`).
    function _setVaults(address[] memory vaults_, WireSweepFloor[] memory floors_) private returns (bytes32 id) {
        id = keccak256(abi.encode("uv", ++nonce));
        _deliver(
            CrosschainMessages.encodeEnvelope(
                MsgType.UPDATE_VAULTS,
                abi.encode(
                    WireUpdateVaults({
                        commandId: id,
                        sequence: dispatcher.nextCommandSequence(),
                        newConfigEpoch: dispatcher.commandConfigEpoch() + 1,
                        minExecutionGas: DEFAULT_COMMAND_BUDGET,
                        vaults: vaults_,
                        floors: floors_
                    })
                )
            )
        );
        assertEq(uint8(dispatcher.commandStatus(id)), uint8(CommandStatus.SUCCEEDED), "UPDATE_VAULTS acked");
    }

    function _compose(uint256 amountLD_) private {
        usdc.mint(address(dispatcher), amountLD_);
        bytes memory composeMsg = LzComposeBuilder.build(
            address(dispatcher),
            EXECUTOR_EID,
            amountLD_,
            CrosschainMessages.encodeOutboundTransfer(
                OutboundTransfer({transferId: keccak256(abi.encode("c", ++nonce))})
            )
        );
        endpoint.deliverCompose(address(dispatcher), address(pool), GUID, composeMsg);
    }

    function _command(BusinessAction action_, bytes memory actionData_) private {
        bytes32 id = keccak256(abi.encode("cmd", ++nonce));
        _deliver(
            CrosschainMessages.encodeCommand(
                Command({
                    commandId: id,
                    sequence: dispatcher.nextCommandSequence(),
                    commandConfigEpoch: dispatcher.commandConfigEpoch(),
                    action: uint8(action_),
                    minExecutionGas: DEFAULT_COMMAND_BUDGET,
                    actionData: actionData_
                })
            )
        );
        assertEq(uint8(dispatcher.commandStatus(id)), uint8(CommandStatus.SUCCEEDED), "command acked");
    }

    function _assertRetained(uint256 idle_) private view {
        assertFalse(dispatcher.isAllowedVault(address(vaultA)), "off the allowlist");
        assertTrue(dispatcher.isTrackedVault(address(vaultA)), "still tracked");
        assertEq(vaultA.balanceOf(address(dispatcher)), 50e6, "no share sold");
        assertEq(dispatcher.trackedIdle(), idle_, "nothing booked from a sale below the floor");
    }

    // ------------------------------------------------------------------ tests

    function testShouldKeepARemovedVaultTrackedWhenItsSweepFloorIsNotReached() public {
        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultSweepResidual(address(vaultA), 50e6, SWEEP_BELOW_MIN, SWEEP_BELOW_MINIMUM, false);
        _setVaults(new address[](0), _floor(address(vaultA), 45e6));
        _assertRetained(50e6);
        assertEq(dispatcher.getTrackedVaults().length, 1, "the retained vault keeps its slot");
    }

    /// @dev A REDEEM at the restored price exits the retained position; Stargate untracks the emptied vault.
    function testShouldExitARetainedPositionWithARedeemAtTheRestoredPrice() public {
        _setVaults(new address[](0), _floor(address(vaultA), 45e6));
        _restore(address(vaultA), address(usdc), 40e6);
        _command(BusinessAction.REDEEM, CrosschainMessages.encodeRedeemAction(address(vaultA), 50e6, 49e6));
        assertEq(vaultA.balanceOf(address(dispatcher)), 0, "redeemed");
        assertFalse(dispatcher.isTrackedVault(address(vaultA)), "emptied: untracked");
        assertEq(dispatcher.trackedIdle(), 100e6, "at the restored price");
    }

    function testShouldSweepARemovedVaultWhoseFloorIsReached() public {
        _restore(address(vaultA), address(usdc), 40e6);
        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultSwept(address(vaultA), 50e6, 50e6);
        _setVaults(new address[](0), _floor(address(vaultA), 50e6));
        assertFalse(dispatcher.isTrackedVault(address(vaultA)), "untracked");
        assertEq(dispatcher.trackedIdle(), 100e6, "swept into idle");
    }

    /// @dev Pinning (passes before and after IL-9629): without a floor the removal sells at the manipulated price.
    function testShouldStillSellAtTheManipulatedPriceWithoutAFloor() public {
        _setVaults(new address[](0), new WireSweepFloor[](0));
        assertFalse(dispatcher.isTrackedVault(address(vaultA)), "untracked");
        assertEq(vaultA.balanceOf(address(dispatcher)), 0, "sold");
        assertEq(dispatcher.trackedIdle(), 60e6, "for a fifth of the position");
    }

    /// @dev Codex 2.9 regression: command 1 retains A; command 2 (an unrelated allowlist replacement that does not name
    ///      A in a floor) leaves it alone; command 3 names A in a floor entry and sweeps it.
    function testShouldNotTouchARetainedVaultUntilAnExplicitFloorEntryNamesIt() public {
        _setVaults(new address[](0), _floor(address(vaultA), 45e6));
        _assertRetained(50e6);

        vm.recordLogs();
        _setVaults(_one(address(vaultB)), new WireSweepFloor[](0));
        assertEq(_sweepEvents(vm.getRecordedLogs(), address(dispatcher), address(vaultA)), 0, "A untouched");
        assertTrue(dispatcher.isAllowedVault(address(vaultB)), "the unrelated update ran");
        _assertRetained(50e6);

        _restore(address(vaultA), address(usdc), 40e6);
        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultSwept(address(vaultA), 50e6, 50e6);
        _setVaults(_one(address(vaultB)), _floor(address(vaultA), 49e6));
        assertFalse(dispatcher.isTrackedVault(address(vaultA)), "untracked by the named entry");
        assertEq(dispatcher.trackedIdle(), 100e6, "at the restored price");
    }

    /// @dev A floor of 0 in an explicit entry is the forced removal (D-028).
    function testShouldForceRemoveARetainedVaultWithAZeroFloorEntry() public {
        _setVaults(new address[](0), _floor(address(vaultA), 45e6));
        _setVaults(new address[](0), _floor(address(vaultA), 0));
        assertFalse(dispatcher.isTrackedVault(address(vaultA)), "untracked");
        assertEq(dispatcher.trackedIdle(), 60e6, "sold at the manipulated price, by choice");
    }

    /// @dev Re-allowlisting a retained vault makes it an ordinary allowlisted position again.
    function testShouldTreatARetainedVaultAllowlistedAgainAsAnOrdinaryPosition() public {
        _setVaults(new address[](0), _floor(address(vaultA), 45e6));
        _setVaults(_one(address(vaultA)), new WireSweepFloor[](0));
        assertTrue(dispatcher.isAllowedVault(address(vaultA)), "allowlisted again");
        assertTrue(dispatcher.isTrackedVault(address(vaultA)), "tracked");
        // a later floorless removal sweeps it like any allowlisted vault (it is no longer a retained position)
        _setVaults(new address[](0), new WireSweepFloor[](0));
        assertFalse(dispatcher.isTrackedVault(address(vaultA)), "swept and untracked");
    }
}

/// @title Stargate18To6SweepFloorTest
/// @notice IL-9590 #7: the Stargate sweep floor on an 18-decimal asset over a 6-shared-decimal route (rate 1e12), where
///         a shared-vs-local mix-up or an overflowing floor conversion would otherwise stay invisible (the suite above
///         runs 6/6). The vault's assets are one wei short, so a redeem of the whole position pays 50e18 - 1 LD.
contract Stargate18To6SweepFloorTest is SweepFloorTestBase {
    using OptionsBuilder for bytes;

    uint256 internal constant DISPATCHER_CHAIN = 42161;
    uint256 internal constant EXECUTOR_CHAIN = 1;
    uint32 internal constant EXECUTOR_EID = 30101;
    bytes32 internal constant ASSET_ID = keccak256("USDC");
    bytes32 internal constant GUID = keccak256("guid");

    MockLzEndpoint internal endpoint;
    MockStargatePool internal pool;
    MockERC20 internal usdc;
    MockRemoteVault internal vaultA;
    MockRemoteVault internal vaultB;
    StargateCrosschainDispatcher internal dispatcher;
    uint256 internal nonce;

    function setUp() public {
        vm.chainId(DISPATCHER_CHAIN);
        vm.warp(365 days);
        usdc = new MockERC20("USD Coin", "USDC", 18);
        pool = new MockStargatePool(address(usdc), 6);
        endpoint = new MockLzEndpoint();
        vaultA = new MockRemoteVault(IERC20(address(usdc)), "A", "A");
        vaultB = new MockRemoteVault(IERC20(address(usdc)), "B", "B");

        EnforcedOptionParam[] memory enforcedOptions = new EnforcedOptionParam[](2);
        enforcedOptions[0] = EnforcedOptionParam({
            eid: EXECUTOR_EID,
            msgType: 1,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(2_000_000, 0)
        });
        enforcedOptions[1] = EnforcedOptionParam({
            eid: EXECUTOR_EID,
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
            address(0xF),
            address(0xADADAD),
            address(0x6A6A6A),
            uint256(3 days),
            EXECUTOR_CHAIN,
            EXECUTOR_EID,
            abi.encode(enforcedOptions)
        );
        dispatcher = StargateCrosschainDispatcher(
            payable(vm.deployCode("StargateCrosschainDispatcher.sol:StargateCrosschainDispatcher", args))
        );
        vm.deal(address(dispatcher), 100 ether);

        // allowlist A, 100 idle, 50 deposited into A, then A's spot price pushed down to a fifth.
        _setVaults(_one(address(vaultA)), new WireSweepFloor[](0));
        _compose(100e18);
        _command(BusinessAction.DEPOSIT, CrosschainMessages.encodeDepositAction(address(vaultA), 50e6, 0));
        assertTrue(dispatcher.isTrackedVault(address(vaultA)), "precondition: A tracked");
        _manipulate(address(vaultA), address(usdc), 1);
    }

    // ------------------------------------------------------------------ helpers

    function _deliver(bytes memory envelope_) private {
        endpoint.deliverLz(
            address(dispatcher),
            EXECUTOR_EID,
            bytes32(uint256(uint160(address(dispatcher)))),
            GUID,
            envelope_
        );
    }

    /// @dev Replaces the allowlist with `vaults_` carrying `floors_` (hand-encoded IL-9629 `UpdateVaults`).
    function _setVaults(address[] memory vaults_, WireSweepFloor[] memory floors_) private returns (bytes32 id) {
        id = keccak256(abi.encode("uv", ++nonce));
        _deliver(
            CrosschainMessages.encodeEnvelope(
                MsgType.UPDATE_VAULTS,
                abi.encode(
                    WireUpdateVaults({
                        commandId: id,
                        sequence: dispatcher.nextCommandSequence(),
                        newConfigEpoch: dispatcher.commandConfigEpoch() + 1,
                        minExecutionGas: DEFAULT_COMMAND_BUDGET,
                        vaults: vaults_,
                        floors: floors_
                    })
                )
            )
        );
        assertEq(uint8(dispatcher.commandStatus(id)), uint8(CommandStatus.SUCCEEDED), "UPDATE_VAULTS acked");
    }

    function _compose(uint256 amountLD_) private {
        usdc.mint(address(dispatcher), amountLD_);
        bytes memory composeMsg = LzComposeBuilder.build(
            address(dispatcher),
            EXECUTOR_EID,
            amountLD_,
            CrosschainMessages.encodeOutboundTransfer(
                OutboundTransfer({transferId: keccak256(abi.encode("c", ++nonce))})
            )
        );
        endpoint.deliverCompose(address(dispatcher), address(pool), GUID, composeMsg);
    }

    function _command(BusinessAction action_, bytes memory actionData_) private {
        bytes32 id = keccak256(abi.encode("cmd", ++nonce));
        _deliver(
            CrosschainMessages.encodeCommand(
                Command({
                    commandId: id,
                    sequence: dispatcher.nextCommandSequence(),
                    commandConfigEpoch: dispatcher.commandConfigEpoch(),
                    action: uint8(action_),
                    minExecutionGas: DEFAULT_COMMAND_BUDGET,
                    actionData: actionData_
                })
            )
        );
        assertEq(uint8(dispatcher.commandStatus(id)), uint8(CommandStatus.SUCCEEDED), "command acked");
    }

    function _assertRetained(uint256 idle_) private view {
        assertFalse(dispatcher.isAllowedVault(address(vaultA)), "off the allowlist");
        assertTrue(dispatcher.isTrackedVault(address(vaultA)), "still tracked");
        assertEq(vaultA.balanceOf(address(dispatcher)), 50e18, "no share sold");
        assertEq(dispatcher.trackedIdle(), idle_, "nothing booked from a sale below the floor");
    }

    // ------------------------------------------------------------------ tests

    /// @dev SD-vs-LD pin on an 18/6 route (rate 1e12): a floor of 50e6 SD is 50e18 LD, one wei above the
    ///      redeem payout of 50e18 - 1 LD, so the removal keeps the vault (reason 6).
    function testShouldKeepTheVaultWhenTheRedeemPaysOneWeiBelowTheScaledFloor() public {
        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultSweepResidual(address(vaultA), 50e18, SWEEP_BELOW_MIN, SWEEP_BELOW_MINIMUM, false);
        _setVaults(new address[](0), _floor(address(vaultA), 50e6));
        _assertRetained(50e6);
    }

    function testShouldSweepWhenTheRedeemPaysExactlyTheScaledFloor() public {
        _restore(address(vaultA), address(usdc), 1);
        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultSwept(address(vaultA), 50e18, 50e18);
        _setVaults(new address[](0), _floor(address(vaultA), 50e6));
        assertFalse(dispatcher.isTrackedVault(address(vaultA)), "untracked");
        assertEq(dispatcher.trackedIdle(), 100e6, "swept into idle (shared decimals)");
    }

    /// @dev IL-9590 #7: a floor whose conversion to local decimals overflows means "never sell" (reason 6, vault
    ///      kept), not a Panic that NACKs the whole UPDATE_VAULTS.
    function testShouldSaturateAnOverflowingFloorInsteadOfPanicking() public {
        _restore(address(vaultA), address(usdc), 1);
        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultSweepResidual(address(vaultA), 50e18, SWEEP_BELOW_MIN, SWEEP_BELOW_MINIMUM, false);
        _setVaults(new address[](0), _floor(address(vaultA), type(uint256).max));
        _assertRetained(50e6);
    }
}

/// @title Ccip18To6SweepFloorTest
/// @notice IL-9590 round 2 #1: the CCIP sweep floor on an 18-decimal asset over a 6-shared-decimal route (rate 1e12).
///         A floor above `type(uint256).max / rate` can never be met and means "never sell" (reason 6, vault kept),
///         not a Panic in the floor conversion that NACKs the whole UPDATE_VAULTS (Stargate parity, T134). The vault's
///         assets are one wei short, so a redeem of the whole position pays 50e18 - 1 LD.
contract Ccip18To6SweepFloorTest is SweepFloorTestBase {
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;
    address internal constant RESCUE_ADMIN = address(0xA11);
    address internal constant GUARDIAN = address(0xB22);

    MockCcipRouter internal router;
    ValueNeutralToken internal token;
    CcipCrosschainDispatcher internal dispatcher;
    MockRemoteVault internal vaultA;
    address internal executor = address(0xE0E0);
    uint256 internal nonce;

    function setUp() public {
        router = new MockCcipRouter();
        token = new ValueNeutralToken();
        address factory = address(new MockCcipRouteValidator());
        dispatcher = new CcipCrosschainDispatcher(
            address(router),
            factory,
            address(token),
            keccak256("USDC"),
            6,
            block.chainid,
            _route(EXECUTOR_SELECTOR, executor),
            RESCUE_ADMIN,
            GUARDIAN,
            3 days
        );
        vaultA = new MockRemoteVault(IERC20(address(token)), "A", "A");
        vm.prank(factory);
        dispatcher.configureVaults(_one(address(vaultA)), true);
        router.setSelector(address(dispatcher), DISPATCHER_SELECTOR);
        vm.warp(1_700_000_000);
        vm.roll(1_000);

        // 50 position in vault A, then one wei of its assets removed (a redeem of everything pays 50e18 - 1 LD).
        token.mint(address(this), 50e18);
        token.approve(address(vaultA), 50e18);
        vaultA.deposit(50e18, address(dispatcher));
        assertTrue(dispatcher.isTrackedVault(address(vaultA)), "precondition: A tracked");
        _manipulate(address(vaultA), address(token), 1);
    }

    function _route(uint64 selector_, address peer_) private pure returns (CcipRouteConfig memory) {
        return
            CcipRouteConfig({
                chainSelector: selector_,
                peer: peer_,
                feeToken: address(0),
                messageGasLimit: 3_000_000,
                tokenGasLimit: 2_000_000,
                maxFee: 0,
                enabled: true
            });
    }

    /// @dev Delivers an UPDATE_VAULTS straight to the dispatcher with the IL-9629 four-element `extra`.
    function _inject(address[] memory vaults_, WireSweepFloor[] memory floors_) private returns (CommandStatus status) {
        bytes32 id = bytes32(((block.timestamp + 1 days) << 192) | ++nonce);
        bytes memory data = CcipMessages.encode(
            CcipMsgType.UPDATE_VAULTS,
            abi.encode(
                CcipMsgType.UPDATE_VAULTS,
                Command({
                    commandId: id,
                    sequence: dispatcher.nextCommandSequence(),
                    commandConfigEpoch: dispatcher.commandConfigEpoch(),
                    action: 0,
                    minExecutionGas: 0,
                    actionData: ""
                }),
                abi.encode(vaults_, false, false, floors_)
            )
        );
        vm.prank(address(router));
        dispatcher.ccipReceive(
            CcipClient.Any2EVMMessage({
                messageId: keccak256(abi.encode("sweep-floor-18-6", nonce)),
                sourceChainSelector: EXECUTOR_SELECTOR,
                sender: abi.encode(executor),
                data: data,
                destTokenAmounts: new CcipClient.EVMTokenAmount[](0)
            })
        );
        status = dispatcher.commandStatus(id);
    }

    function _assertRetained() private view {
        assertFalse(dispatcher.isAllowedVault(address(vaultA)), "off the allowlist");
        assertTrue(dispatcher.isTrackedVault(address(vaultA)), "still tracked");
        assertEq(vaultA.balanceOf(address(dispatcher)), 50e18, "no share sold");
    }

    /// @dev A floor of 50e6 SD is 50e18 LD, one wei above the redeem payout of 50e18 - 1 LD: the vault is kept.
    function testShouldKeepTheVaultWhenTheRedeemPaysOneWeiBelowTheScaledFloor() public {
        uint256 navBefore = dispatcher.accountedBalance();
        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultSweepResidual(address(vaultA), 50e18, SWEEP_BELOW_MIN, SWEEP_BELOW_MINIMUM, false);
        assertEq(
            uint8(_inject(_one(address(vaultA)), _floor(address(vaultA), 50e6))),
            uint8(CommandStatus.SUCCEEDED),
            "UPDATE_VAULTS acked"
        );
        _assertRetained();
        assertEq(dispatcher.accountedBalance(), navBefore, "NAV unchanged");
    }

    function testShouldSweepWhenTheRedeemPaysExactlyTheScaledFloor() public {
        _restore(address(vaultA), address(token), 1);
        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultSwept(address(vaultA), 50e18, 50e18);
        assertEq(
            uint8(_inject(_one(address(vaultA)), _floor(address(vaultA), 50e6))),
            uint8(CommandStatus.SUCCEEDED),
            "UPDATE_VAULTS acked"
        );
        assertFalse(dispatcher.isTrackedVault(address(vaultA)), "untracked");
        assertEq(dispatcher.trackedIdle(), 50e6, "swept into idle (shared decimals)");
    }

    /// @dev IL-9590 round 2 #1: a floor whose conversion to local decimals overflows means "never sell" (reason 6,
    ///      vault kept), not a Panic that NACKs the whole UPDATE_VAULTS.
    function testShouldSaturateAnOverflowingFloorInsteadOfPanicking() public {
        _restore(address(vaultA), address(token), 1);
        uint256 navBefore = dispatcher.accountedBalance();
        uint64 epochBefore = dispatcher.commandConfigEpoch();
        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultSweepResidual(address(vaultA), 50e18, SWEEP_BELOW_MIN, SWEEP_BELOW_MINIMUM, false);
        assertEq(
            uint8(_inject(_one(address(vaultA)), _floor(address(vaultA), type(uint256).max))),
            uint8(CommandStatus.SUCCEEDED),
            "UPDATE_VAULTS acked, not NACKed by a Panic"
        );
        _assertRetained();
        assertEq(dispatcher.accountedBalance(), navBefore, "NAV unchanged");
        assertEq(dispatcher.commandConfigEpoch(), epochBefore + 1, "config epoch advanced");
    }
}
