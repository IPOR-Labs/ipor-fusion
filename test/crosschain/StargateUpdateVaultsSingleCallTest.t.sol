// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {EnforcedOptionParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppOptionsType3.sol";

import {StargateCrosschainDispatcher} from "../../contracts/crosschain/stargate/StargateCrosschainDispatcher.sol";
import {BusinessAction, CommandStatus} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {
    CrosschainMessages,
    UpdateVaults,
    Command,
    OutboundTransfer
} from "../../contracts/crosschain/lib/CrosschainMessages.sol";

import {MockFaultyVault} from "./mocks/MockFaultyVault.sol";
import {MockLzEndpoint} from "./mocks/MockLzEndpoint.sol";
import {MockStargatePool, LzComposeBuilder} from "./mocks/MockStargatePool.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";
import {DEFAULT_COMMAND_BUDGET} from "./CommandBudget.sol";

/// @notice IL-8681 size round: the Stargate dispatcher applies `UPDATE_VAULTS` in ONE linked call
///         (`StargateDispatcherLib.applyUpdateVaults` replaces the allowlist and reconciles the tracked set), stores
///         the next config epoch before that call, and computes the tracked-position-set hash in the library. These
///         tests pin what must not change: the epoch only moves on success, a failed update rolls the early epoch
///         write back, events keep their order (`VaultsUpdated` before the sweep events), swept assets are credited
///         to `trackedIdle`, and the set hash is still `keccak256(abi.encode(dispatcher, chainid, trackedVaults))`.
contract StargateUpdateVaultsSingleCallTest is Test {
    using OptionsBuilder for bytes;

    uint256 internal constant DISPATCHER_CHAIN = 42161;
    uint256 internal constant EXECUTOR_CHAIN = 1;
    uint32 internal constant EXECUTOR_EID = 30101;
    bytes32 internal constant ASSET_ID = keccak256("USDC");
    bytes32 internal constant GUID = keccak256("guid");

    event VaultsUpdated(uint64 commandConfigEpoch, uint64 stateVersion, uint256 count);
    event TrackedVaultSwept(address vault, uint256 sharesRedeemed, uint256 assetsLD);

    address internal admin = address(0xADADAD);
    address internal guardian = address(0x6A6A6A);

    MockLzEndpoint internal endpoint;
    MockStargatePool internal pool;
    MockERC20 internal usdc;
    MockFaultyVault internal vaultA;
    MockFaultyVault internal vaultB;
    StargateCrosschainDispatcher internal dispatcher;
    uint256 internal nonce;

    function setUp() public {
        vm.chainId(DISPATCHER_CHAIN);
        vm.warp(365 days);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        pool = new MockStargatePool(address(usdc), 6);
        endpoint = new MockLzEndpoint();
        vaultA = new MockFaultyVault(IERC20(address(usdc)), "Vault A", "VA");
        vaultB = new MockFaultyVault(IERC20(address(usdc)), "Vault B", "VB");

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
            admin,
            guardian,
            uint256(3 days),
            EXECUTOR_CHAIN,
            EXECUTOR_EID,
            abi.encode(enforcedOptions)
        );
        dispatcher = StargateCrosschainDispatcher(
            payable(vm.deployCode("StargateCrosschainDispatcher.sol:StargateCrosschainDispatcher", args))
        );
        vm.deal(address(dispatcher), 100 ether);
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

    function _updateVaults(address[] memory vaults_, uint64 newConfigEpoch_) private returns (bytes32 id) {
        id = keccak256(abi.encode("uv", ++nonce));
        _deliver(
            CrosschainMessages.encodeUpdateVaults(
                UpdateVaults({
                    commandId: id,
                    sequence: dispatcher.nextCommandSequence(),
                    newConfigEpoch: newConfigEpoch_,
                    minExecutionGas: DEFAULT_COMMAND_BUDGET,
                    vaults: vaults_
                })
            )
        );
    }

    function _setVaults(address[] memory vaults_) private returns (bytes32 id) {
        return _updateVaults(vaults_, dispatcher.commandConfigEpoch() + 1);
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

    function _deposit(address v_, uint256 amountSD_) private {
        bytes32 id = keccak256(abi.encode("dep", ++nonce));
        _deliver(
            CrosschainMessages.encodeCommand(
                Command({
                    commandId: id,
                    sequence: dispatcher.nextCommandSequence(),
                    commandConfigEpoch: dispatcher.commandConfigEpoch(),
                    action: uint8(BusinessAction.DEPOSIT),
                    minExecutionGas: DEFAULT_COMMAND_BUDGET,
                    actionData: CrosschainMessages.encodeDepositAction(v_, amountSD_, 0)
                })
            )
        );
        assertEq(uint8(dispatcher.commandStatus(id)), uint8(CommandStatus.SUCCEEDED), "deposit succeeded");
    }

    function _two() private view returns (address[] memory vaults) {
        vaults = new address[](2);
        vaults[0] = address(vaultA);
        vaults[1] = address(vaultB);
    }

    function _one(address v_) private pure returns (address[] memory vaults) {
        vaults = new address[](1);
        vaults[0] = v_;
    }

    /// @dev Two allowlisted vaults with live positions: 30 + 20 in the vaults, 50 idle (6-decimal USDC).
    function _twoPositions() private {
        _setVaults(_two());
        _compose(100e6);
        _deposit(address(vaultA), 30e6);
        _deposit(address(vaultB), 20e6);
        assertEq(dispatcher.getTrackedVaults().length, 2, "both tracked");
        assertEq(dispatcher.trackedIdle(), 50e6, "idle after the deposits");
    }

    function _expectedSetHash() private view returns (bytes32) {
        return keccak256(abi.encode(address(dispatcher), block.chainid, dispatcher.getTrackedVaults()));
    }

    // ------------------------------------------------------------------ tests

    function testShouldAdvanceTheEpochOnceAndEmitVaultsUpdatedBeforeTheSweep() public {
        _twoPositions();
        uint64 epochBefore = dispatcher.commandConfigEpoch();

        vm.recordLogs();
        bytes32 id = _setVaults(_one(address(vaultB)));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(uint8(dispatcher.commandStatus(id)), uint8(CommandStatus.SUCCEEDED), "update succeeded");
        assertEq(dispatcher.commandConfigEpoch(), epochBefore + 1, "epoch advanced by exactly one");
        assertFalse(dispatcher.isAllowedVault(address(vaultA)), "A off the allowlist");
        assertTrue(dispatcher.isAllowedVault(address(vaultB)), "B still allowlisted");
        assertFalse(dispatcher.isTrackedVault(address(vaultA)), "A untracked");
        assertTrue(dispatcher.isTrackedVault(address(vaultB)), "B still tracked");
        assertEq(vaultA.balanceOf(address(dispatcher)), 0, "A redeemed");
        assertEq(dispatcher.trackedIdle(), 80e6, "swept assets credited to idle");

        uint256 updatedAt = type(uint256).max;
        uint256 sweptAt = type(uint256).max;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(dispatcher)) continue;
            if (logs[i].topics[0] == VaultsUpdated.selector) {
                updatedAt = i;
                (uint64 epoch, , uint256 count) = abi.decode(logs[i].data, (uint64, uint64, uint256));
                assertEq(epoch, epochBefore + 1, "VaultsUpdated carries the new epoch");
                assertEq(count, 1, "VaultsUpdated carries the new set size");
            } else if (logs[i].topics[0] == TrackedVaultSwept.selector) {
                sweptAt = i;
                (address v, uint256 shares, uint256 assets) = abi.decode(logs[i].data, (address, uint256, uint256));
                assertEq(v, address(vaultA), "swept vault");
                assertEq(shares, 30e6, "swept shares");
                assertEq(assets, 30e6, "swept assets");
            }
        }
        assertTrue(updatedAt != type(uint256).max, "VaultsUpdated emitted");
        assertTrue(sweptAt != type(uint256).max, "TrackedVaultSwept emitted");
        assertLt(updatedAt, sweptAt, "allowlist replaced before the sweep");
    }

    function testShouldRollTheEarlyEpochWriteBackWhenThePayloadEpochIsWrong() public {
        _twoPositions();
        uint64 epochBefore = dispatcher.commandConfigEpoch();

        // One epoch ahead of what the dispatcher expects: the library rejects it after the host stored epoch + 1.
        bytes32 id = _updateVaults(_one(address(vaultB)), epochBefore + 2);

        assertEq(uint8(dispatcher.commandStatus(id)), uint8(CommandStatus.FAILED), "update NACKed");
        assertEq(dispatcher.commandConfigEpoch(), epochBefore, "epoch write rolled back");
        assertTrue(dispatcher.isAllowedVault(address(vaultA)), "allowlist untouched");
        assertTrue(dispatcher.isTrackedVault(address(vaultA)), "A still tracked, nothing swept");
        assertEq(vaultA.balanceOf(address(dispatcher)), 30e6, "A position untouched");
        assertEq(dispatcher.trackedIdle(), 50e6, "idle untouched");
    }

    function testShouldRollTheEarlyEpochWriteBackWhenThePayloadEpochIsStale() public {
        _twoPositions();
        uint64 epochBefore = dispatcher.commandConfigEpoch();

        // The current epoch instead of the next one.
        bytes32 id = _updateVaults(_one(address(vaultB)), epochBefore);

        assertEq(uint8(dispatcher.commandStatus(id)), uint8(CommandStatus.FAILED), "stale update NACKed");
        assertEq(dispatcher.commandConfigEpoch(), epochBefore, "epoch write rolled back");
        assertTrue(dispatcher.isTrackedVault(address(vaultA)), "A still tracked, nothing swept");
        assertEq(dispatcher.trackedIdle(), 50e6, "idle untouched");
    }

    function testShouldKeepTheTrackedSetHashBoundToDispatcherChainAndSet() public {
        bytes32 emptyHash = dispatcher.observation().trackedPositionSetHash;
        assertEq(emptyHash, _expectedSetHash(), "empty set hash");

        _twoPositions();
        bytes32 twoHash = dispatcher.observation().trackedPositionSetHash;
        assertEq(twoHash, _expectedSetHash(), "two-vault set hash");
        assertTrue(twoHash != emptyHash, "hash follows the set");

        _setVaults(_one(address(vaultB)));
        bytes32 oneHash = dispatcher.observation().trackedPositionSetHash;
        assertEq(dispatcher.getTrackedVaults().length, 1, "one tracked after the removal");
        assertEq(oneHash, _expectedSetHash(), "hash after the sweep");
        assertTrue(oneHash != twoHash, "hash changed with the set");
    }
}
