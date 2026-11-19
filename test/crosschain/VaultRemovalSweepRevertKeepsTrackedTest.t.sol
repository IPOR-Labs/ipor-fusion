// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {EnforcedOptionParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppOptionsType3.sol";

import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
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
import {WireSweepFloor, WireUpdateVaults} from "./VaultRemovalSweepFloorTest.t.sol";

/// @dev A vault whose `redeem` reverts with its own custom error while locked, like a PlasmaVault whose account is
///      locked (`AccountIsLocked`). `maxRedeem` stays readable.
contract MockLockableVault is MockRemoteVault {
    error AccountIsLocked(address account);

    bool public locked;
    bool public silent;

    constructor(IERC20 asset_, string memory name_, string memory symbol_) MockRemoteVault(asset_, name_, symbol_) {}

    function setLocked(bool locked_) external {
        locked = locked_;
    }

    /// @dev While set, a locked redeem reverts with EMPTY data (like a plain out-of-gas).
    function setSilent(bool silent_) external {
        silent = silent_;
    }

    function redeem(uint256 shares_, address receiver_, address owner_) public override returns (uint256) {
        if (locked && silent) {
            assembly ("memory-safe") {
                revert(0, 0)
            }
        }
        if (locked) revert AccountIsLocked(owner_);
        return super.redeem(shares_, receiver_, owner_);
    }
}

/// @title CcipVaultRemovalSweepRevertKeepsTrackedTest
/// @notice IL-9694 D-002 (3sigma audit v2 #14), narrowing D-028 under a non-zero sweep floor: a redeem that reverts
///         WITH the vault's own error (here `AccountIsLocked`) and burned nothing reports reason 6 (`untracked`
///         false) and the vault stays tracked, off the allowlist, in NAV. Before the change it was reason 2 and the
///         vault was untracked, so a temporarily locked position dropped out of NAV. Without a floor D-028 stands.
contract CcipVaultRemovalSweepRevertKeepsTrackedTest is Test {
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;
    address internal constant RESCUE_ADMIN = address(0xA11);
    address internal constant GUARDIAN = address(0xB22);
    address internal constant APPROVER = address(0xA33);
    string internal constant FLOORED_UPDATE =
        "updateVaultsWithSweepFloors(uint256,address[],bool,bool,(address,uint256)[],uint256,address,uint256)";

    event TrackedVaultSwept(address vault, uint256 sharesRedeemed, uint256 assetsLD);
    event TrackedVaultSweepResidual(
        address vault,
        uint256 sharesLeft,
        uint8 reason,
        bytes4 redeemError,
        bool untracked
    );

    MockCcipRouter internal router;
    ValueNeutralToken internal token;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;
    MockLockableVault internal vaultA;

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
        vaultA = new MockLockableVault(IERC20(address(token)), "A", "A");
        address[] memory vaults = new address[](1);
        vaults[0] = address(vaultA);
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

        // 100 idle + a 50 position in vault A, then A locks the position.
        token.mint(address(executor), 100e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e18, 0, address(0), 2_000_000);
        token.mint(address(this), 50e18);
        token.approve(address(vaultA), 50e18);
        vaultA.deposit(50e18, address(dispatcher));
        vaultA.setLocked(true);
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

    function _one() private view returns (address[] memory vaults) {
        vaults = new address[](1);
        vaults[0] = address(vaultA);
    }

    function _floor(uint256 minAssets_) private view returns (WireSweepFloor[] memory floors) {
        floors = new WireSweepFloor[](1);
        floors[0] = WireSweepFloor({vault: address(vaultA), minAssets: minAssets_});
    }

    function _updateWithFloors(address[] memory vaults_, WireSweepFloor[] memory floors_) private {
        _sendFlooredUpdate(vaults_, floors_);
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "UPDATE_VAULTS acked");
    }

    function _sendFlooredUpdate(address[] memory vaults_, WireSweepFloor[] memory floors_) private {
        (bool ok, ) = address(executor).call(
            abi.encodeWithSignature(
                FLOORED_UPDATE,
                REMOTE_CHAIN,
                vaults_,
                false,
                false,
                floors_,
                uint256(0),
                address(0),
                uint256(3_000_000)
            )
        );
        assertTrue(ok, "updateVaultsWithSweepFloors sent");
    }

    /// @dev Finds the one TrackedVaultSweepResidual of the recorded logs and checks reason, error and `untracked`.
    function _assertResidual(uint8 reason_, bool untracked_, bytes4 err_) private {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = TrackedVaultSweepResidual.selector;
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(dispatcher) || logs[i].topics[0] != topic) continue;
            ++found;
            (address vault, uint256 left, uint8 reason, bytes4 err, bool untracked) = abi.decode(
                logs[i].data,
                (address, uint256, uint8, bytes4, bool)
            );
            assertEq(vault, address(vaultA), "residual vault");
            assertEq(left, 50e18, "residual shares");
            assertEq(reason, reason_, "residual reason");
            assertEq(err, err_, "residual error data");
            assertEq(untracked, untracked_, "residual untracked");
        }
        assertEq(found, 1, "one residual event");
    }

    function _redeem(uint256 shares_) private {
        executor.sendCommandToDispatcher(
            REMOTE_CHAIN,
            Command({
                commandId: bytes32(0),
                sequence: 0,
                commandConfigEpoch: 0,
                action: uint8(BusinessAction.REDEEM),
                minExecutionGas: 0,
                actionData: CrosschainMessages.encodeRedeemAction(address(vaultA), shares_, 0)
            }),
            0,
            address(0),
            3_000_000
        );
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "REDEEM acked");
    }

    function testShouldKeepALockedVaultTrackedWhenAFlooredRedeemRevertsWithTheVaultsOwnError() public {
        uint256 navBefore = dispatcher.accountedBalance();
        assertEq(navBefore, 150e18, "precondition: 100 idle + 50 position");
        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultSweepResidual(address(vaultA), 50e18, 6, MockLockableVault.AccountIsLocked.selector, false);
        _updateWithFloors(_one(), _floor(1e18));
        assertFalse(dispatcher.isAllowedVault(address(vaultA)), "off the allowlist");
        assertTrue(dispatcher.isTrackedVault(address(vaultA)), "still tracked");
        assertEq(vaultA.balanceOf(address(dispatcher)), 50e18, "no share burned");
        assertEq(dispatcher.accountedBalance(), navBefore, "NAV unchanged");
    }

    /// @dev IL-9699: the 3M CCIP lane leaves less than VAULT_SWEEP_GAS + reserve at the sweep, so EVERY floored
    ///      sweep there is gas-limited (forwarded gas below VAULT_SWEEP_GAS). Error data still wins: the vault's own
    ///      `AccountIsLocked` is reason 6 and the vault stays tracked (IL-9694 D-002 applies on the main lane).
    function testShouldKeepAGasLimitedFlooredRedeemTrackedWhenItRevertsWithTheVaultsOwnError() public {
        uint256 held = _holdFlooredUpdate();
        vm.recordLogs();
        router.deliverHeldExact(held, 2_500_000);
        _assertResidual(6, false, MockLockableVault.AccountIsLocked.selector);
        assertTrue(dispatcher.isTrackedVault(address(vaultA)), "still tracked");
        assertEq(vaultA.balanceOf(address(dispatcher)), 50e18, "no share burned");
    }

    /// @dev D-065: a gas-limited floored redeem that reverts with EMPTY data (a plain out-of-gas) is reason 5 and
    ///      untracks.
    function testShouldUntrackAGasLimitedFlooredRedeemThatRevertsWithEmptyData() public {
        vaultA.setSilent(true);
        uint256 held = _holdFlooredUpdate();
        vm.recordLogs();
        router.deliverHeldExact(held, 2_500_000);
        _assertResidual(5, true, bytes4(0));
        assertFalse(dispatcher.isTrackedVault(address(vaultA)), "untracked");
        assertEq(vaultA.balanceOf(address(dispatcher)), 50e18, "no share burned");
    }

    function _holdFlooredUpdate() private returns (uint256 held) {
        router.setAutoDeliver(false);
        _sendFlooredUpdate(_one(), _floor(1e18));
        router.setAutoDeliver(true);
        held = router.heldCount() - 1;
    }

    function testShouldRedeemTheRetainedLockedVaultOnceItUnlocks() public {
        _updateWithFloors(_one(), _floor(1e18));
        vaultA.setLocked(false);
        _redeem(50e18);
        assertEq(vaultA.balanceOf(address(dispatcher)), 0, "redeemed");
        assertEq(dispatcher.trackedIdle(), 150e18, "booked into idle");
    }

    /// @dev D-028 stands without a floor entry: the revert is reason 2 and the vault is untracked.
    function testShouldUntrackALockedVaultWithoutAFloor() public {
        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultSweepResidual(address(vaultA), 50e18, 2, MockLockableVault.AccountIsLocked.selector, true);
        _updateWithFloors(_one(), new WireSweepFloor[](0));
        assertFalse(dispatcher.isTrackedVault(address(vaultA)), "untracked");
    }

    /// @dev A floor entry of 0 is the forced removal: unchanged, the locked vault is untracked.
    function testShouldUntrackALockedVaultWithAZeroFloor() public {
        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultSweepResidual(address(vaultA), 50e18, 2, MockLockableVault.AccountIsLocked.selector, true);
        _updateWithFloors(_one(), _floor(0));
        assertFalse(dispatcher.isTrackedVault(address(vaultA)), "untracked");
    }

    /// @dev A retained locked vault is still removable later by a zero-floor entry.
    function testShouldForceRemoveARetainedLockedVaultWithAZeroFloorEntry() public {
        _updateWithFloors(_one(), _floor(1e18));
        _updateWithFloors(new address[](0), _floor(0));
        assertFalse(dispatcher.isTrackedVault(address(vaultA)), "untracked");
    }
}

/// @title StargateVaultRemovalSweepRevertKeepsTrackedTest
/// @notice IL-9694 D-002 on the Stargate dispatcher: the same rule with the replace-only allowlist.
contract StargateVaultRemovalSweepRevertKeepsTrackedTest is Test {
    using OptionsBuilder for bytes;

    uint256 internal constant DISPATCHER_CHAIN = 42161;
    uint256 internal constant EXECUTOR_CHAIN = 1;
    uint32 internal constant EXECUTOR_EID = 30101;
    bytes32 internal constant ASSET_ID = keccak256("USDC");
    bytes32 internal constant GUID = keccak256("guid");

    event TrackedVaultSweepResidual(
        address vault,
        uint256 sharesLeft,
        uint8 reason,
        bytes4 redeemError,
        bool untracked
    );

    MockLzEndpoint internal endpoint;
    MockStargatePool internal pool;
    MockERC20 internal usdc;
    MockLockableVault internal vaultA;
    StargateCrosschainDispatcher internal dispatcher;
    uint256 internal nonce;

    function setUp() public {
        vm.chainId(DISPATCHER_CHAIN);
        vm.warp(365 days);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        pool = new MockStargatePool(address(usdc), 6);
        endpoint = new MockLzEndpoint();
        vaultA = new MockLockableVault(IERC20(address(usdc)), "A", "A");

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

        _setVaults(_one(), new WireSweepFloor[](0));
        _compose(100e6);
        _command(BusinessAction.DEPOSIT, CrosschainMessages.encodeDepositAction(address(vaultA), 50e6, 0));
        assertTrue(dispatcher.isTrackedVault(address(vaultA)), "precondition: A tracked");
        vaultA.setLocked(true);
    }

    function _one() private view returns (address[] memory vaults) {
        vaults = new address[](1);
        vaults[0] = address(vaultA);
    }

    function _floor(uint256 minAssets_) private view returns (WireSweepFloor[] memory floors) {
        floors = new WireSweepFloor[](1);
        floors[0] = WireSweepFloor({vault: address(vaultA), minAssets: minAssets_});
    }

    function _deliver(bytes memory envelope_) private {
        endpoint.deliverLz(
            address(dispatcher),
            EXECUTOR_EID,
            bytes32(uint256(uint160(address(dispatcher)))),
            GUID,
            envelope_
        );
    }

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

    function testShouldKeepALockedVaultTrackedWhenAFlooredRedeemRevertsWithTheVaultsOwnError() public {
        uint256 idleBefore = dispatcher.trackedIdle();
        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultSweepResidual(address(vaultA), 50e6, 6, MockLockableVault.AccountIsLocked.selector, false);
        _setVaults(new address[](0), _floor(1e6));
        assertFalse(dispatcher.isAllowedVault(address(vaultA)), "off the allowlist");
        assertTrue(dispatcher.isTrackedVault(address(vaultA)), "still tracked");
        assertEq(vaultA.balanceOf(address(dispatcher)), 50e6, "no share burned");
        assertEq(dispatcher.trackedIdle(), idleBefore, "idle unchanged");
    }

    function testShouldRedeemTheRetainedLockedVaultOnceItUnlocks() public {
        _setVaults(new address[](0), _floor(1e6));
        vaultA.setLocked(false);
        _command(BusinessAction.REDEEM, CrosschainMessages.encodeRedeemAction(address(vaultA), 50e6, 0));
        assertEq(vaultA.balanceOf(address(dispatcher)), 0, "redeemed");
        assertEq(dispatcher.trackedIdle(), 100e6, "booked into idle");
    }

    function testShouldUntrackALockedVaultWithoutAFloor() public {
        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultSweepResidual(address(vaultA), 50e6, 2, MockLockableVault.AccountIsLocked.selector, true);
        _setVaults(new address[](0), new WireSweepFloor[](0));
        assertFalse(dispatcher.isTrackedVault(address(vaultA)), "untracked");
    }

    function testShouldUntrackALockedVaultWithAZeroFloor() public {
        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultSweepResidual(address(vaultA), 50e6, 2, MockLockableVault.AccountIsLocked.selector, true);
        _setVaults(new address[](0), _floor(0));
        assertFalse(dispatcher.isTrackedVault(address(vaultA)), "untracked");
    }

    function testShouldForceRemoveARetainedLockedVaultWithAZeroFloorEntry() public {
        _setVaults(new address[](0), _floor(1e6));
        _setVaults(new address[](0), _floor(0));
        assertFalse(dispatcher.isTrackedVault(address(vaultA)), "untracked");
    }
}
