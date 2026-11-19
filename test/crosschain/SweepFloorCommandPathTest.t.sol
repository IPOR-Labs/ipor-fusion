// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {CcipMessages, CcipMsgType} from "../../contracts/crosschain/ccip/lib/CcipMessages.sol";
import {CcipDecimalsLib} from "../../contracts/crosschain/ccip/lib/CcipDecimalsLib.sol";
import {CcipExecutorCommandLib} from "../../contracts/crosschain/ccip/lib/CcipExecutorCommandLib.sol";
import {
    CcipCrosschainCommandFuse,
    CcipCommandFuseEnterData,
    CcipCommandType
} from "../../contracts/fuses/crosschain/ccip/CcipCrosschainCommandFuse.sol";
import {
    StargateCrosschainCommandFuse,
    StargateCrosschainCommandFuseEnterData,
    StargateCrosschainCommandType
} from "../../contracts/fuses/crosschain/stargate/StargateCrosschainCommandFuse.sol";
import {StargateExecutorCommandLib} from "../../contracts/crosschain/stargate/lib/StargateExecutorCommandLib.sol";
import {StargateExecutorState} from "../../contracts/crosschain/stargate/lib/StargateExecutorState.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {CrosschainConstants, MsgType} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {
    Command,
    CrosschainMessages,
    SweepFloor,
    UpdateVaults
} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {CrosschainSubstrateLib} from "../../contracts/fuses/crosschain/lib/CrosschainSubstrateLib.sol";
import {CcipCrosschainSupplyFuse} from "../../contracts/fuses/crosschain/ccip/CcipCrosschainSupplyFuse.sol";
import {CrosschainVaultHarness} from "./mocks/CrosschainVaultHarness.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";
import {MockExecutor} from "./mocks/MockExecutor.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";

/// @notice Plays the Stargate executor's storage so `StargateExecutorCommandLib.buildUpdateVaults` runs as in the
///         executor (delegatecall), with a registered command-lane gas.
contract SweepFloorStargateBuildHarness {
    StargateExecutorState internal _s;

    function setLane(uint256 chainId_, uint128 gas_) external {
        _s.commandLaneReceiveGas[chainId_] = gas_;
    }

    function buildUpdate(
        uint256 chainId_,
        address[] memory vaults_,
        SweepFloor[] memory floors_
    ) external returns (bytes memory payload) {
        (payload, , ) = StargateExecutorCommandLib.buildUpdateVaults(_s, chainId_, vaults_, floors_, 1);
    }
}

/// @title SweepFloorCommandPathTest
/// @notice IL-9629 (M39): the executor and fuse side of the per-vault sweep floor. The CCIP executor validates the
///         floors and converts their `minAssets` from LOCAL to SHARED decimals exactly before it encodes the
///         `(vaults, allowed, replace, floors)` extra; the Stargate executor validates them and forwards shared decimals
///         verbatim in `UpdateVaults.floors`; both command fuses forward floors through `enterWithSweepFloors` (and keep
///         the old executor entry for an empty list). The dispatcher side is `VaultRemovalSweepFloorTest`.
contract SweepFloorCommandPathTest is Test {
    uint256 internal constant MARKET = IporFusionMarkets.CROSSCHAIN;
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 1;
    uint64 internal constant DISPATCHER_SELECTOR = 2;
    /// @dev 18 local decimals, 6 shared: the CCIP executor's `DECIMAL_CONVERSION_RATE` is 1e12.
    uint256 internal constant RATE = 1e12;
    address internal constant VAULT_A = address(0xA1);
    address internal constant VAULT_B = address(0xB2);

    MockERC20 internal token;
    MockCcipRouter internal router;
    CrosschainVaultHarness internal vault;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainCommandFuse internal commandFuse;

    function setUp() public {
        token = new MockERC20("Wrapped", "W18", 18);
        router = new MockCcipRouter();
        MockCcipRouteValidator routeValidator = new MockCcipRouteValidator();
        vault = new CrosschainVaultHarness(address(token));
        executor = new CcipCrosschainExecutor(
            address(router),
            address(routeValidator),
            address(vault),
            address(token),
            keccak256("W18"),
            6,
            CcipCrosschainExecutor.SafetyConfig({
                rescueAdmin: address(0xA11),
                rescueGuardian: address(0xB22),
                balanceProposer: address(0xA33),
                balanceApprover: address(0xB44),
                rescueDelay: 3 days,
                balanceStalenessMax: 7 days,
                bigChangeBps: 2_000,
                anchorBandBps: 2_000,
                minUpdateInterval: 1 hours,
                transferStalenessMax: 1 days
            })
        );
        CcipRouteConfig memory executorRoute = CcipRouteConfig({
            chainSelector: DISPATCHER_SELECTOR,
            peer: address(0xD15),
            feeToken: address(0),
            messageGasLimit: 3_000_000,
            tokenGasLimit: 2_000_000,
            maxFee: 0,
            enabled: true
        });
        routeValidator.setRoute(REMOTE_CHAIN, executorRoute);
        routeValidator.registerExecutorRoute(address(executor), REMOTE_CHAIN, executorRoute);
        vm.prank(address(routeValidator));
        executor.markDispatcherReady(REMOTE_CHAIN);
        router.setSelector(address(executor), EXECUTOR_SELECTOR);
        router.setAutoDeliver(false);

        commandFuse = new CcipCrosschainCommandFuse(MARKET);
        vault.setCcipFuses(address(new CcipCrosschainSupplyFuse(MARKET)), address(commandFuse));
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = CrosschainSubstrateLib.executorSubstrate(address(executor));
        vault.grantSubstrates(MARKET, substrates);
    }

    // ------------------------------------------------------------------ helpers

    function _one(address v_) private pure returns (address[] memory vaults) {
        vaults = new address[](1);
        vaults[0] = v_;
    }

    function _floor(address v_, uint256 minAssets_) private pure returns (SweepFloor[] memory floors) {
        floors = new SweepFloor[](1);
        floors[0] = SweepFloor({vault: v_, minAssets: minAssets_});
    }

    /// @dev External so `vm.expectRevert` can catch a revert of the linked library call.
    function encodeExt(
        address[] memory vaults_,
        bool allowed_,
        bool replace_,
        SweepFloor[] memory floors_,
        uint256 rate_
    ) external pure returns (bytes memory) {
        return CcipExecutorCommandLib.encodeVaultUpdate(vaults_, allowed_, replace_, floors_, rate_);
    }

    /// @dev The `extra` of the UPDATE_VAULTS the mock router holds last.
    function _heldExtra() private view returns (address[] memory, bool, bool, SweepFloor[] memory) {
        (CcipMsgType t, bytes memory data) = CcipMessages.decode(router.heldData(router.heldCount() - 1));
        assertEq(uint8(t), uint8(CcipMsgType.UPDATE_VAULTS), "an UPDATE_VAULTS was sent");
        (, , bytes memory extra) = abi.decode(data, (CcipMsgType, Command, bytes));
        return abi.decode(extra, (address[], bool, bool, SweepFloor[]));
    }

    function _ccipUpdate() private view returns (CcipCommandFuseEnterData memory d) {
        d.commandType = CcipCommandType.UPDATE_VAULTS;
        d.executor = address(executor);
        d.chainId = REMOTE_CHAIN;
        d.vaultsAllowed = false;
        d.vaultsReplace = false;
        d.gasLimit = 3_000_000;
    }

    // ------------------------------------------------------------------ CCIP codec

    /// @dev Golden vector (computed by hand, word by word): `abi.encode(address[] [A1], false, false,
    ///      (address,uint256)[] [(A1, 5)])`, the floor given as 5e12 LOCAL units and converted to 5 SHARED units.
    function testShouldEncodeTheCcipExtraWithFloorsInSharedDecimals() public pure {
        bytes memory extra = CcipExecutorCommandLib.encodeVaultUpdate(
            _one(VAULT_A),
            false,
            false,
            _floor(VAULT_A, 5e12),
            RATE
        );
        assertEq(
            keccak256(extra),
            keccak256(
                hex"00000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c0000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000a1000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000a10000000000000000000000000000000000000000000000000000000000000005"
            ),
            "CCIP UPDATE_VAULTS extra golden vector"
        );
    }

    function testShouldRefuseACcipFloorWithSubSharedDecimalDust() public {
        vm.expectRevert(abi.encodeWithSelector(CcipDecimalsLib.AmountHasDust.selector, 5e12 + 1));
        this.encodeExt(_one(VAULT_A), false, false, _floor(VAULT_A, 5e12 + 1), RATE);
    }

    function testShouldRefuseACcipFloorForTheZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(CcipExecutorCommandLib.InvalidVaultAddress.selector, address(0)));
        this.encodeExt(_one(VAULT_A), false, false, _floor(address(0), 0), RATE);
    }

    function testShouldRefuseADuplicateCcipFloor() public {
        SweepFloor[] memory floors = new SweepFloor[](2);
        floors[0] = SweepFloor({vault: VAULT_A, minAssets: 0});
        floors[1] = SweepFloor({vault: VAULT_A, minAssets: 1e12});
        vm.expectRevert(abi.encodeWithSelector(CcipExecutorCommandLib.DuplicateVault.selector, VAULT_A));
        this.encodeExt(_one(VAULT_B), false, false, floors, RATE);
    }

    function testShouldRefuseMoreCcipFloorsThanTheTrackedSetCap() public {
        uint256 cap = CrosschainConstants.MAX_TRACKED_POSITION_VAULTS;
        SweepFloor[] memory floors = new SweepFloor[](cap + 1);
        for (uint256 i; i < floors.length; ++i) {
            floors[i] = SweepFloor({vault: address(uint160(0x1000 + i)), minAssets: 0});
        }
        vm.expectRevert(abi.encodeWithSelector(CcipExecutorCommandLib.TooManyVaults.selector, cap + 1, cap));
        this.encodeExt(new address[](0), false, false, floors, RATE);
        // exactly the cap is accepted
        SweepFloor[] memory atCap = new SweepFloor[](cap);
        for (uint256 i; i < cap; ++i) {
            atCap[i] = floors[i];
        }
        this.encodeExt(new address[](0), false, false, atCap, RATE);
    }

    /// @dev The vault list keeps its own shape rule inside the new encoder.
    function testShouldStillRefuseADuplicateVaultInTheList() public {
        address[] memory vaults = new address[](2);
        vaults[0] = VAULT_A;
        vaults[1] = VAULT_A;
        vm.expectRevert(abi.encodeWithSelector(CcipExecutorCommandLib.DuplicateVault.selector, VAULT_A));
        this.encodeExt(vaults, true, false, new SweepFloor[](0), RATE);
    }

    // ------------------------------------------------------------------ CCIP executor and fuse

    /// @dev `updateVaultsWithSweepFloors` sends the floors converted to shared decimals; `updateVaults` sends an empty
    ///      list in the same four-element extra.
    function testShouldSendCcipFloorsInSharedDecimals() public {
        vm.prank(address(vault));
        executor.updateVaultsWithSweepFloors(
            REMOTE_CHAIN,
            _one(VAULT_A),
            false,
            false,
            _floor(VAULT_A, 7e12),
            0,
            address(0),
            0
        );
        (address[] memory vaults, bool allowed, bool replace, SweepFloor[] memory floors) = _heldExtra();
        assertEq(vaults.length, 1, "vault list");
        assertEq(vaults[0], VAULT_A);
        assertFalse(allowed, "removal");
        assertFalse(replace, "no replace");
        assertEq(floors.length, 1, "one floor");
        assertEq(floors[0].vault, VAULT_A, "floor vault");
        assertEq(floors[0].minAssets, 7, "7e12 local units = 7 shared units");
    }

    function testShouldSendAnEmptyFloorListFromTheOldEntry() public {
        vm.prank(address(vault));
        executor.updateVaults(REMOTE_CHAIN, _one(VAULT_A), false, false, 0, address(0), 0);
        (address[] memory vaults, , , SweepFloor[] memory floors) = _heldExtra();
        assertEq(vaults.length, 1, "vault list");
        assertEq(floors.length, 0, "no floor");
    }

    function testShouldRestrictTheFlooredCcipEntryToTheManager() public {
        vm.expectRevert(CcipCrosschainExecutor.OnlyManager.selector);
        executor.updateVaultsWithSweepFloors(
            REMOTE_CHAIN,
            _one(VAULT_A),
            false,
            false,
            _floor(VAULT_A, 0),
            0,
            address(0),
            0
        );
    }

    /// @dev The CCIP fuse forwards the floors (LOCAL decimals) to `updateVaultsWithSweepFloors`.
    function testShouldForwardCcipFloorsThroughTheFuse() public {
        CcipCommandFuseEnterData memory d = _ccipUpdate();
        d.plasmaVaults = _one(VAULT_A);
        uint256 heldBefore = router.heldCount();
        vault.enterCcipCommandWithSweepFloors(d, _floor(VAULT_A, 3e12));
        assertEq(router.heldCount(), heldBefore + 1, "one message sent");
        (, , , SweepFloor[] memory floors) = _heldExtra();
        assertEq(floors.length, 1, "floor forwarded");
        assertEq(floors[0].vault, VAULT_A);
        assertEq(floors[0].minAssets, 3, "converted by the executor");
    }

    /// @dev An empty floor list through the floor entry uses the old executor entry (no floors on the wire).
    function testShouldForwardAnEmptyCcipFloorListThroughTheOldEntry() public {
        CcipCommandFuseEnterData memory d = _ccipUpdate();
        d.plasmaVaults = _one(VAULT_A);
        vault.enterCcipCommandWithSweepFloors(d, new SweepFloor[](0));
        (address[] memory vaults, , , SweepFloor[] memory floors) = _heldExtra();
        assertEq(vaults[0], VAULT_A, "update sent");
        assertEq(floors.length, 0, "no floor");
    }

    function testShouldRefuseCcipFloorsOnAnotherCommandType() public {
        CcipCommandFuseEnterData memory d = _ccipUpdate();
        d.commandType = CcipCommandType.REFRESH_BALANCE;
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipCrosschainCommandFuse.CcipCommandFuseUnsupportedCommand.selector,
                uint8(CcipCommandType.REFRESH_BALANCE)
            )
        );
        vault.enterCcipCommandWithSweepFloors(d, _floor(VAULT_A, 0));
    }

    // ------------------------------------------------------------------ Stargate executor library

    function testShouldCarryStargateFloorsVerbatimInUpdateVaults() public {
        SweepFloorStargateBuildHarness h = new SweepFloorStargateBuildHarness();
        h.setLane(REMOTE_CHAIN, 4_000_000);
        bytes memory payload = h.buildUpdate(REMOTE_CHAIN, _one(VAULT_A), _floor(VAULT_B, 9));
        (MsgType t, bytes memory data) = this.decodeEnvelopeExt(payload);
        assertEq(uint8(t), uint8(MsgType.UPDATE_VAULTS));
        UpdateVaults memory u = CrosschainMessages.decodeUpdateVaults(data);
        assertEq(u.vaults.length, 1);
        assertEq(u.vaults[0], VAULT_A);
        assertEq(u.floors.length, 1, "one floor");
        assertEq(u.floors[0].vault, VAULT_B);
        assertEq(u.floors[0].minAssets, 9, "shared decimals, verbatim");
        // the budget is derived from the full payload, floors included
        assertEq(
            u.minExecutionGas,
            CrosschainMessages.commandGasBudget(4_000_000, CrosschainMessages.payloadWords(data.length), true),
            "budget over the floored payload"
        );
    }

    function decodeEnvelopeExt(bytes memory raw_) external pure returns (MsgType, bytes memory) {
        return CrosschainMessages.decodeEnvelope(raw_);
    }

    function testShouldRefuseInvalidStargateFloors() public {
        SweepFloorStargateBuildHarness h = new SweepFloorStargateBuildHarness();
        h.setLane(REMOTE_CHAIN, 10_000_000);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.InvalidVault.selector, address(0)));
        h.buildUpdate(REMOTE_CHAIN, new address[](0), _floor(address(0), 1));

        SweepFloor[] memory dup = new SweepFloor[](2);
        dup[0] = SweepFloor({vault: VAULT_A, minAssets: 1});
        dup[1] = SweepFloor({vault: VAULT_A, minAssets: 2});
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.InvalidVault.selector, VAULT_A));
        h.buildUpdate(REMOTE_CHAIN, new address[](0), dup);

        uint256 cap = CrosschainConstants.MAX_TRACKED_POSITION_VAULTS;
        SweepFloor[] memory tooMany = new SweepFloor[](cap + 1);
        for (uint256 i; i < tooMany.length; ++i) {
            tooMany[i] = SweepFloor({vault: address(uint160(0x1000 + i)), minAssets: 0});
        }
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.VaultsCapReached.selector, cap));
        h.buildUpdate(REMOTE_CHAIN, new address[](0), tooMany);
    }

    /// @dev Each floor adds two stored words: a lane that cannot carry them refuses the build, nothing is sent.
    function testShouldRefuseAStargateFloorSetTheLaneCannotCarry() public {
        SweepFloorStargateBuildHarness h = new SweepFloorStargateBuildHarness();
        UpdateVaults memory probe;
        probe.vaults = new address[](0);
        probe.floors = _floor(VAULT_A, 1);
        uint256 words = CrosschainMessages.payloadWords(abi.encode(probe).length);
        uint256 minLane = CrosschainMessages.laneGasFor(CrosschainConstants.COMMAND_EXECUTION_MIN_GAS, words, true);
        h.setLane(REMOTE_CHAIN, uint128(minLane - 1));
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.CommandLaneGasTooLow.selector, minLane - 1, minLane));
        h.buildUpdate(REMOTE_CHAIN, new address[](0), _floor(VAULT_A, 1));
        h.setLane(REMOTE_CHAIN, uint128(minLane));
        h.buildUpdate(REMOTE_CHAIN, new address[](0), _floor(VAULT_A, 1));
    }

    // ------------------------------------------------------------------ Stargate fuse

    function _stargateSetUp() private returns (MockExecutor sgExecutor, CrosschainVaultHarness sgVault) {
        sgVault = new CrosschainVaultHarness(address(token));
        StargateCrosschainCommandFuse sgFuse = new StargateCrosschainCommandFuse(MARKET);
        sgVault.setFuses(address(0), address(0), address(sgFuse), address(0));
        sgExecutor = new MockExecutor(address(sgVault), address(token));
        bytes32[] memory subs = new bytes32[](2);
        subs[0] = CrosschainSubstrateLib.executorSubstrate(address(sgExecutor));
        subs[1] = CrosschainSubstrateLib.remoteVaultSubstrate(REMOTE_CHAIN, VAULT_A);
        sgVault.grantSubstrates(MARKET, subs);
    }

    function _sgUpdate(address executor_) private pure returns (StargateCrosschainCommandFuseEnterData memory d) {
        d.commandType = StargateCrosschainCommandType.UPDATE_PLASMA_VAULTS;
        d.executor = executor_;
        d.chainId = REMOTE_CHAIN;
    }

    function testShouldForwardStargateFloorsThroughTheFuse() public {
        (MockExecutor sgExecutor, CrosschainVaultHarness sgVault) = _stargateSetUp();
        StargateCrosschainCommandFuseEnterData memory d = _sgUpdate(address(sgExecutor));
        d.plasmaVaults = _one(VAULT_A);
        sgVault.enterCommandWithSweepFloors(d, _floor(VAULT_B, 42));
        assertEq(sgExecutor.lastFlooredUpdateChainId(), REMOTE_CHAIN, "floored entry used");
        assertEq(sgExecutor.lastFloorCount(), 1, "one floor");
        (address floorVault, uint256 minAssets) = sgExecutor.lastFirstFloor();
        assertEq(floorVault, VAULT_B, "a floor needs no REMOTE_VAULT substrate (the vault may already be revoked)");
        assertEq(minAssets, 42, "verbatim");
        assertEq(sgExecutor.lastUpdateChainId(), 0, "old entry not used");
    }

    function testShouldUseTheOldStargateEntryForAnEmptyFloorList() public {
        (MockExecutor sgExecutor, CrosschainVaultHarness sgVault) = _stargateSetUp();
        StargateCrosschainCommandFuseEnterData memory d = _sgUpdate(address(sgExecutor));
        d.plasmaVaults = _one(VAULT_A);
        sgVault.enterCommandWithSweepFloors(d, new SweepFloor[](0));
        assertEq(sgExecutor.lastUpdateChainId(), REMOTE_CHAIN, "old entry used");
        assertEq(sgExecutor.lastFlooredUpdateChainId(), 0, "floored entry not used");
    }

    /// @dev The list still needs its REMOTE_VAULT substrates and the chain-blocked rule is unchanged: a non-empty list
    ///      is refused on a blocked chain, a pure removal carrying floors is not.
    function testShouldKeepTheStargateListGatesWithFloors() public {
        (MockExecutor sgExecutor, CrosschainVaultHarness sgVault) = _stargateSetUp();
        StargateCrosschainCommandFuseEnterData memory d = _sgUpdate(address(sgExecutor));
        d.plasmaVaults = _one(VAULT_B); // not granted
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainSubstrateLib.CrosschainFuseRemoteVaultNotGranted.selector,
                REMOTE_CHAIN,
                VAULT_B
            )
        );
        sgVault.enterCommandWithSweepFloors(d, _floor(VAULT_A, 1));

        sgExecutor.setChainBlocked(REMOTE_CHAIN, true);
        d.plasmaVaults = _one(VAULT_A);
        vm.expectRevert(
            abi.encodeWithSelector(
                StargateCrosschainCommandFuse.CrosschainCommandFuseChainBlocked.selector,
                address(sgExecutor),
                REMOTE_CHAIN
            )
        );
        sgVault.enterCommandWithSweepFloors(d, _floor(VAULT_A, 1));

        d.plasmaVaults = new address[](0);
        sgVault.enterCommandWithSweepFloors(d, _floor(VAULT_A, 1));
        assertEq(sgExecutor.lastFloorCount(), 1, "a pure removal with floors stays available on a blocked chain");
    }

    function testShouldRefuseStargateFloorsOnAnotherCommandType() public {
        (MockExecutor sgExecutor, CrosschainVaultHarness sgVault) = _stargateSetUp();
        StargateCrosschainCommandFuseEnterData memory d = _sgUpdate(address(sgExecutor));
        d.commandType = StargateCrosschainCommandType.CANCEL_COMMAND;
        vm.expectRevert(
            abi.encodeWithSelector(
                StargateCrosschainCommandFuse.CrosschainCommandFuseUnsupportedCommandType.selector,
                uint8(StargateCrosschainCommandType.CANCEL_COMMAND)
            )
        );
        sgVault.enterCommandWithSweepFloors(d, _floor(VAULT_A, 0));
    }
}
