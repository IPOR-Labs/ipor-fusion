// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MockERC20} from "../test_helpers/MockERC20.sol";
import {PlasmaVaultCloneLib} from "../test_helpers/PlasmaVaultCloneLib.sol";
import {TestAddresses} from "../test_helpers/TestAddresses.sol";
import {IporFusionAccessManagerHelper} from "../test_helpers/IporFusionAccessManagerHelper.sol";
import {MutableValuePriceFeed} from "../managers/MutableValuePriceFeed.sol";

import {StargateTwoSidedBase} from "./StargateTwoSidedBase.sol";
import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {RetryBatchVaultHarness} from "./RetryCommandFollowUpTest.t.sol";
import {CrosschainRecoveryContextTestLib} from "./mocks/CrosschainRecoveryContextTestLib.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";
import {MockPriceOracleMiddleware} from "./mocks/MockPriceOracleMiddleware.sol";
import {MockPausableRemoteVault} from "./mocks/MockRetryFollowUpVaults.sol";
import {RecoveryBatcher} from "./mocks/RecoveryBatcher.sol";

import {PlasmaVault, PlasmaVaultInitData, FeeConfig} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IPlasmaVault, FuseAction} from "../../contracts/interfaces/IPlasmaVault.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {RewardsClaimManager} from "../../contracts/managers/rewards/RewardsClaimManager.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {
    CcipCrosschainCommandFuse,
    CcipCommandType,
    CcipCommandFuseEnterData
} from "../../contracts/fuses/crosschain/ccip/CcipCrosschainCommandFuse.sol";
import {
    CcipCrosschainSupplyFuse,
    CcipSupplyFuseEnterData
} from "../../contracts/fuses/crosschain/ccip/CcipCrosschainSupplyFuse.sol";
import {
    StargateCrosschainCommandFuse,
    StargateCrosschainCommandFuseEnterData,
    StargateCrosschainCommandType
} from "../../contracts/fuses/crosschain/stargate/StargateCrosschainCommandFuse.sol";
import {
    StargateCrosschainSupplyFuse,
    StargateCrosschainSupplyFuseEnterData
} from "../../contracts/fuses/crosschain/stargate/StargateCrosschainSupplyFuse.sol";
import {
    CrosschainClaimFuse,
    CrosschainClaimFuseEnterData
} from "../../contracts/fuses/crosschain/CrosschainClaimFuse.sol";
import {CrosschainBalanceFuse} from "../../contracts/fuses/crosschain/CrosschainBalanceFuse.sol";
import {CrosschainRecoveryLib} from "../../contracts/fuses/crosschain/lib/CrosschainRecoveryLib.sol";
import {CrosschainSubstrateLib} from "../../contracts/fuses/crosschain/lib/CrosschainSubstrateLib.sol";
import {BalanceObservation} from "../../contracts/crosschain/interfaces/ICrosschainExecutor.sol";
import {Command, CrosschainMessages} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {BusinessAction, CommandStatus} from "../../contracts/crosschain/lib/CrosschainConstants.sol";

/// @notice Adds the "command, then supply" batch shape to the retry harness: two fuse calls in ONE transaction with
///         the transient markers kept between them, exactly like one `PlasmaVault.execute` batch.
contract RecoveryFirstVaultHarness is RetryBatchVaultHarness {
    using Address for address;

    constructor(address underlying_) RetryBatchVaultHarness(underlying_) {}

    function stargateCommandThenSupply(
        StargateCrosschainCommandFuseEnterData memory first_,
        StargateCrosschainSupplyFuseEnterData memory second_
    ) external {
        commandFuse.functionDelegateCall(abi.encodeCall(StargateCrosschainCommandFuse.enter, (first_)));
        supplyFuse.functionDelegateCall(abi.encodeCall(StargateCrosschainSupplyFuse.enter, (second_)));
        CrosschainRecoveryContextTestLib.clearContext(IporFusionMarkets.CROSSCHAIN);
    }

    function ccipCommandThenSupply(
        CcipCommandFuseEnterData memory first_,
        CcipSupplyFuseEnterData memory second_
    ) external {
        ccipCommandFuse.functionDelegateCall(abi.encodeCall(CcipCrosschainCommandFuse.enter, (first_)));
        ccipSupplyFuse.functionDelegateCall(abi.encodeCall(CcipCrosschainSupplyFuse.enter, (second_)));
        CrosschainRecoveryContextTestLib.clearContext(IporFusionMarkets.CROSSCHAIN);
    }

    /// @dev Claim (recovery armed only when it moved positive priced value) and then a command, one batch.
    function stargateClaimThenCommand(
        CrosschainClaimFuseEnterData memory first_,
        StargateCrosschainCommandFuseEnterData memory second_
    ) external {
        claimFuse.functionDelegateCall(abi.encodeCall(CrosschainClaimFuse.enter, (first_)));
        commandFuse.functionDelegateCall(abi.encodeCall(StargateCrosschainCommandFuse.enter, (second_)));
        CrosschainRecoveryContextTestLib.clearContext(IporFusionMarkets.CROSSCHAIN);
    }

    function stargateClaimThenSupply(
        CrosschainClaimFuseEnterData memory first_,
        StargateCrosschainSupplyFuseEnterData memory second_
    ) external {
        claimFuse.functionDelegateCall(abi.encodeCall(CrosschainClaimFuse.enter, (first_)));
        supplyFuse.functionDelegateCall(abi.encodeCall(StargateCrosschainSupplyFuse.enter, (second_)));
        CrosschainRecoveryContextTestLib.clearContext(IporFusionMarkets.CROSSCHAIN);
    }

    function ccipClaimThenCommand(
        CrosschainClaimFuseEnterData memory first_,
        CcipCommandFuseEnterData memory second_
    ) external {
        claimFuse.functionDelegateCall(abi.encodeCall(CrosschainClaimFuse.enter, (first_)));
        ccipCommandFuse.functionDelegateCall(abi.encodeCall(CcipCrosschainCommandFuse.enter, (second_)));
        CrosschainRecoveryContextTestLib.clearContext(IporFusionMarkets.CROSSCHAIN);
    }

    function ccipClaimThenSupply(
        CrosschainClaimFuseEnterData memory first_,
        CcipSupplyFuseEnterData memory second_
    ) external {
        claimFuse.functionDelegateCall(abi.encodeCall(CrosschainClaimFuse.enter, (first_)));
        ccipSupplyFuse.functionDelegateCall(abi.encodeCall(CcipCrosschainSupplyFuse.enter, (second_)));
        CrosschainRecoveryContextTestLib.clearContext(IporFusionMarkets.CROSSCHAIN);
    }
}

/// @title StargateRecoveryThenExposureBatchTest
/// @notice IL-9127 (core C-019): `markNewExposure` refuses a batch that already armed a recovery action. Existing
///         tests pin only the opposite order (exposure first, then recovery, `markRecovery`). Here the recovery
///         action comes FIRST on a real Stargate executor + dispatcher, driven through the real fuses, and the later
///         exposure (a DEPOSIT command, a retried DEPOSIT, a supply `enter`) must be refused with the exact selector.
///         Live NAV is healthy, so the guard is the only possible revert (not `getBalance()` after the marker).
contract StargateRecoveryThenExposureBatchTest is StargateTwoSidedBase {
    uint256 internal constant MARKET = IporFusionMarkets.CROSSCHAIN;

    RecoveryFirstVaultHarness internal vault;
    MockERC20 internal underlying;
    MockPausableRemoteVault internal pausableVault;

    function setUp() public {
        // The executor's MANAGER is immutable: make it the vault harness before the base deploys the executor.
        underlying = new MockERC20("Underlying", "UND", 6);
        vault = new RecoveryFirstVaultHarness(address(underlying));
        manager = address(vault);
        _twoSidedSetUp();
        _bringUpBothSides();

        StargateCrosschainCommandFuse commandFuse = new StargateCrosschainCommandFuse(MARKET);
        StargateCrosschainSupplyFuse supplyFuse = new StargateCrosschainSupplyFuse(MARKET);
        CrosschainBalanceFuse balanceFuse = new CrosschainBalanceFuse(MARKET);
        vault.setFuses(
            address(supplyFuse),
            address(new CrosschainClaimFuse(MARKET)),
            address(commandFuse),
            address(balanceFuse)
        );
        MockPriceOracleMiddleware oracle = new MockPriceOracleMiddleware();
        oracle.setPrice(address(usdc), 1e8, 8);
        oracle.setPrice(address(underlying), 1e8, 8);
        vault.setPriceOracleMiddleware(address(oracle));

        // A granted, allowlisted vault; 2e6 idle on the dispatcher with a fresh attestation; the vault refuses
        // deposits, so the DEPOSIT is NACKed and stays FAILED in the command slot.
        pausableVault = new MockPausableRemoteVault(IERC20(address(usdc)));
        _grant(address(pausableVault));
        vault.enterCommand(_updateVaults(address(pausableVault)));
        _relayAll();
        _bridgeToDispatcher(2e6);
        _attest(2e6);
        pausableVault.setPaused(true);
        vault.enterCommand(_deposit(address(pausableVault), 1e6));
        _relayAll();
        (bool active, CommandStatus status) = _status();
        assertTrue(active, "lane held");
        assertEq(uint8(status), uint8(CommandStatus.FAILED), "precondition: FAILED DEPOSIT");
        pausableVault.setPaused(false);

        // Idle assets for the supply `enter` (it bridges the executor's asset).
        usdc.mint(address(vault), 10e6);

        // A real recall leaves 1e6 in the executor's idle ledger, so a claim moves positive, priced value.
        (bytes32 requestId, , ) = _requestAssets(1e6, 0);
        _relayAll();
        usdc.mint(address(executor), 1e6);
        _deliverReturnCompose(requestId, pool.lastGuid(), 1e6);
        assertEq(executor.idleLedger(), 1e6, "precondition: idle ledger funded by a real recall");
    }

    function _claim() internal view returns (CrosschainClaimFuseEnterData memory) {
        return CrosschainClaimFuseEnterData({executor: address(executor), amount: 1e6});
    }

    function _grant(address remoteVault_) internal {
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = CrosschainSubstrateLib.executorSubstrate(address(executor));
        substrates[1] = CrosschainSubstrateLib.remoteVaultSubstrate(REMOTE_CHAIN, remoteVault_);
        vault.grantSubstrates(MARKET, substrates);
    }

    function _data(
        StargateCrosschainCommandType type_
    ) internal view returns (StargateCrosschainCommandFuseEnterData memory data) {
        data.commandType = type_;
        data.executor = address(executor);
        data.chainId = REMOTE_CHAIN;
    }

    function _updateVaults(
        address remoteVault_
    ) internal view returns (StargateCrosschainCommandFuseEnterData memory data) {
        data = _data(StargateCrosschainCommandType.UPDATE_PLASMA_VAULTS);
        data.plasmaVaults = new address[](1);
        data.plasmaVaults[0] = remoteVault_;
    }

    function _deposit(
        address remoteVault_,
        uint256 amountSD_
    ) internal view returns (StargateCrosschainCommandFuseEnterData memory data) {
        data = _data(StargateCrosschainCommandType.SEND_COMMAND);
        data.command = Command({
            commandId: bytes32(0),
            sequence: 0,
            commandConfigEpoch: 0,
            action: uint8(BusinessAction.DEPOSIT),
            minExecutionGas: 0,
            actionData: CrosschainMessages.encodeDepositAction(remoteVault_, amountSD_, 0)
        });
    }

    function _redeem(
        address remoteVault_,
        uint256 shares_
    ) internal view returns (StargateCrosschainCommandFuseEnterData memory data) {
        data = _data(StargateCrosschainCommandType.SEND_COMMAND);
        data.command = Command({
            commandId: bytes32(0),
            sequence: 0,
            commandConfigEpoch: 0,
            action: uint8(BusinessAction.REDEEM),
            minExecutionGas: 0,
            actionData: CrosschainMessages.encodeRedeemAction(remoteVault_, shares_, 0)
        });
    }

    function _supply() internal view returns (StargateCrosschainSupplyFuseEnterData memory data) {
        data = StargateCrosschainSupplyFuseEnterData({
            executor: address(executor),
            asset: address(usdc),
            dstChainId: REMOTE_CHAIN,
            amount: 1e6,
            minAmountLD: 0,
            options: ""
        });
    }

    function _status() internal view returns (bool active, CommandStatus status) {
        (active, , , status, , , ) = executor.activeCommand(REMOTE_CHAIN);
    }

    function _attest(uint256 settledLD_) internal {
        BalanceObservation memory observation = BalanceObservation({
            chainId: REMOTE_CHAIN,
            settledBalance: settledLD_,
            stateVersion: executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN),
            remoteBlock: 1,
            remoteTimestamp: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 30 minutes),
            trackedPositionSetHash: bytes32(0)
        });
        vm.prank(proposer);
        executor.proposeBalance(observation);
        uint256 proposalId = executor.proposalCount();
        vm.prank(approver);
        executor.approveBalance(proposalId);
    }

    /// @notice CANCEL_COMMAND (recovery) and then a fresh DEPOSIT command in the same batch.
    function testShouldRefuseDepositCommandAfterCancelCommandInOneBatch() public {
        vm.expectRevert(CrosschainRecoveryLib.RecoveryExposureBatchForbidden.selector);
        vault.stargateTwo(_data(StargateCrosschainCommandType.CANCEL_COMMAND), _deposit(address(pausableVault), 1e6));
    }

    /// @notice CANCEL_COMMAND (recovery) and then a RETRY_COMMAND of the stored DEPOSIT in the same batch.
    function testShouldRefuseRetryOfStoredDepositAfterCancelCommandInOneBatch() public {
        assertEq(executor.activeCommandAction(REMOTE_CHAIN), uint8(BusinessAction.DEPOSIT), "stored DEPOSIT");

        vm.expectRevert(CrosschainRecoveryLib.RecoveryExposureBatchForbidden.selector);
        vault.stargateTwo(
            _data(StargateCrosschainCommandType.CANCEL_COMMAND),
            _data(StargateCrosschainCommandType.RETRY_COMMAND)
        );
    }

    /// @notice CANCEL_COMMAND (recovery) and then a supply `enter` (new exposure) in the same batch.
    function testShouldRefuseSupplyEnterAfterCancelCommandInOneBatch() public {
        vm.expectRevert(CrosschainRecoveryLib.RecoveryExposureBatchForbidden.selector);
        vault.stargateCommandThenSupply(_data(StargateCrosschainCommandType.CANCEL_COMMAND), _supply());
    }

    /// @notice A SEND_COMMAND REDEEM (recovery by business action) and then a DEPOSIT in the same batch.
    function testShouldRefuseDepositCommandAfterRedeemCommandInOneBatch() public {
        // Free the lane first, so the REDEEM is a legal send in its own right.
        vault.enterCommand(_data(StargateCrosschainCommandType.CANCEL_COMMAND));
        _relayAll();
        (bool active, ) = _status();
        assertFalse(active, "lane free");

        vm.expectRevert(CrosschainRecoveryLib.RecoveryExposureBatchForbidden.selector);
        vault.stargateTwo(_redeem(address(pausableVault), 1e6), _deposit(address(pausableVault), 1e6));
    }

    /// @notice claim (recovery) and then a supply `enter` in the same batch.
    /// @dev Reaches `CrosschainRecoveryLib.markNewExposure` (:114) through `StargateCrosschainSupplyFuse.enter`; the
    ///      claim arms recovery at `CrosschainClaimFuse.sol:93`.
    function testShouldRefuseSupplyEnterAfterClaimInOneBatch() public {
        vm.expectRevert(CrosschainRecoveryLib.RecoveryExposureBatchForbidden.selector);
        vault.stargateClaimThenSupply(_claim(), _supply());
        assertEq(executor.idleLedger(), 1e6, "claim rolled back with the batch");
    }

    /// @notice claim (recovery) and then a fresh DEPOSIT command in the same batch.
    /// @dev Reaches `markNewExposure` (:114) through the command fuse's `_gateOrMarkBusinessAction` (DEPOSIT).
    function testShouldRefuseDepositCommandAfterClaimInOneBatch() public {
        vm.expectRevert(CrosschainRecoveryLib.RecoveryExposureBatchForbidden.selector);
        vault.stargateClaimThenCommand(_claim(), _deposit(address(pausableVault), 1e6));
    }

    /// @notice claim (recovery) and then a RETRY_COMMAND of the stored DEPOSIT in the same batch.
    /// @dev Reaches `markNewExposure` (:114) through the retry path of `_gateOrMarkBusinessAction` (stored DEPOSIT).
    function testShouldRefuseRetryOfStoredDepositAfterClaimInOneBatch() public {
        assertEq(executor.activeCommandAction(REMOTE_CHAIN), uint8(BusinessAction.DEPOSIT), "stored DEPOSIT");

        vm.expectRevert(CrosschainRecoveryLib.RecoveryExposureBatchForbidden.selector);
        vault.stargateClaimThenCommand(_claim(), _data(StargateCrosschainCommandType.RETRY_COMMAND));
    }

    /// @notice A SEND_COMMAND REDEEM (recovery by business action) and then a supply `enter` in the same batch.
    /// @dev Reaches `markNewExposure` (:114) through `StargateCrosschainSupplyFuse.enter`; the REDEEM arms recovery
    ///      at `StargateCrosschainCommandFuse.sol:222`.
    ///
    ///      REDEEM -> RETRY DEPOSIT is deliberately not built: a REDEEM needs a free command lane, while a RETRY
    ///      needs the stored DEPOSIT occupying that lane, and the lane holds one command at a time. No valid
    ///      state has both, so the pair is unreachable (the retry would revert on the lane before the guard).
    function testShouldRefuseSupplyEnterAfterRedeemCommandInOneBatch() public {
        vault.enterCommand(_data(StargateCrosschainCommandType.CANCEL_COMMAND));
        _relayAll();
        (bool active, ) = _status();
        assertFalse(active, "lane free");

        vm.expectRevert(CrosschainRecoveryLib.RecoveryExposureBatchForbidden.selector);
        vault.stargateCommandThenSupply(_redeem(address(pausableVault), 1e6), _supply());
    }

    /// @notice The same actions in separate transactions pass: the guard is batch-scoped, not a lasting lock.
    function testShouldAllowDepositInTheTransactionAfterACancel() public {
        vault.enterCommand(_data(StargateCrosschainCommandType.CANCEL_COMMAND));
        _relayAll();
        (bool active, ) = _status();
        assertFalse(active, "lane freed by CANCEL");

        vault.enterCommand(_deposit(address(pausableVault), 1e6));
        _relayAll();
        assertEq(pausableVault.balanceOf(address(dispatcher)), 1e6, "DEPOSIT landed in the next transaction");

        vault.enterSupply(_supply());
    }
}

/// @title CcipRecoveryThenExposureBatchTest
/// @notice Same IL-9127 direction on a real CCIP executor + dispatcher behind the mock router (synchronous delivery).
///         CANCEL_COMMAND frees the lane at once, so the later DEPOSIT would otherwise go through.
contract CcipRecoveryThenExposureBatchTest is Test {
    uint256 internal constant MARKET = IporFusionMarkets.CROSSCHAIN;
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 1;
    uint64 internal constant DISPATCHER_SELECTOR = 2;
    address internal constant PROPOSER = address(0xA33);
    address internal constant APPROVER = address(0xB44);

    MockERC20 internal token;
    MockCcipRouter internal router;
    RecoveryFirstVaultHarness internal vault;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;
    MockPausableRemoteVault internal pausableVault;
    bytes32 internal failedId;

    function setUp() public {
        vm.warp(1_760_000_000);
        token = new MockERC20("USD Coin", "USDC", 6);
        router = new MockCcipRouter();
        MockCcipRouteValidator routeValidator = new MockCcipRouteValidator();
        address factory = address(routeValidator);
        vault = new RecoveryFirstVaultHarness(address(token));
        executor = new CcipCrosschainExecutor(
            address(router),
            factory,
            address(vault),
            address(token),
            keccak256("USDC"),
            6,
            CcipCrosschainExecutor.SafetyConfig({
                rescueAdmin: address(0xA11),
                rescueGuardian: address(0xB22),
                balanceProposer: PROPOSER,
                balanceApprover: APPROVER,
                rescueDelay: 3 days,
                balanceStalenessMax: 1 hours,
                bigChangeBps: 2_000,
                minUpdateInterval: 1 minutes,
                transferStalenessMax: 1 days
            })
        );
        dispatcher = new CcipCrosschainDispatcher(
            address(router),
            factory,
            address(token),
            keccak256("USDC"),
            6,
            block.chainid,
            CcipRouteConfig({
                chainSelector: EXECUTOR_SELECTOR,
                peer: address(executor),
                feeToken: address(0),
                messageGasLimit: 2_000_000,
                tokenGasLimit: 2_000_000,
                maxFee: 0,
                enabled: true
            }),
            address(0xA11),
            address(0xB22),
            3 days
        );
        vm.prank(factory);
        dispatcher.configureVaults(new address[](0), true);
        CcipRouteConfig memory executorRoute = CcipRouteConfig({
            chainSelector: DISPATCHER_SELECTOR,
            peer: address(dispatcher),
            feeToken: address(0),
            messageGasLimit: 2_000_000,
            tokenGasLimit: 2_000_000,
            maxFee: 0,
            enabled: true
        });
        routeValidator.setRoute(REMOTE_CHAIN, executorRoute);
        routeValidator.registerExecutorRoute(address(executor), REMOTE_CHAIN, executorRoute);
        vm.prank(factory);
        executor.markDispatcherReady(REMOTE_CHAIN);
        router.setSelector(address(executor), EXECUTOR_SELECTOR);
        router.setSelector(address(dispatcher), DISPATCHER_SELECTOR);

        CcipCrosschainCommandFuse commandFuse = new CcipCrosschainCommandFuse(MARKET);
        CcipCrosschainSupplyFuse supplyFuse = new CcipCrosschainSupplyFuse(MARKET);
        CrosschainBalanceFuse balanceFuse = new CrosschainBalanceFuse(MARKET);
        vault.setFuses(address(0), address(new CrosschainClaimFuse(MARKET)), address(0), address(balanceFuse));
        vault.setCcipFuses(address(supplyFuse), address(commandFuse));
        MockPriceOracleMiddleware oracle = new MockPriceOracleMiddleware();
        oracle.setPrice(address(token), 1e8, 8);
        vault.setPriceOracleMiddleware(address(oracle));

        // A granted, allowlisted vault; 100e6 idle on the dispatcher with a fresh attestation; the vault refuses
        // deposits, so the DEPOSIT is NACKed and stays FAILED in the command slot.
        pausableVault = new MockPausableRemoteVault(IERC20(address(token)));
        _grant(address(pausableVault));
        vault.enterCcipCommand(_updateVaults(address(pausableVault)));
        vm.warp(block.timestamp + 1);
        _bridge(100e6);
        vm.warp(block.timestamp + 1);
        _attest(100e6);
        pausableVault.setPaused(true);
        vault.enterCcipCommand(_deposit(address(pausableVault), 50e6));
        failedId = executor.activeCommand(REMOTE_CHAIN);
        assertEq(uint8(executor.commandStatus(failedId)), uint8(CommandStatus.FAILED), "precondition: FAILED DEPOSIT");
        pausableVault.setPaused(false);

        // Idle assets for the supply `enter`.
        token.mint(address(vault), 10e6);

        // A real recall (synchronous delivery) leaves 10e6 in the executor's idle ledger for the claim.
        vm.prank(address(vault));
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 10e6, 0, 0, address(0), 2_000_000);
        assertEq(executor.idleLedger(), 10e6, "precondition: idle ledger funded by a real recall");
    }

    function _claim() internal view returns (CrosschainClaimFuseEnterData memory) {
        return CrosschainClaimFuseEnterData({executor: address(executor), amount: 10e6});
    }

    function _grant(address remoteVault_) internal {
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = CrosschainSubstrateLib.executorSubstrate(address(executor));
        substrates[1] = CrosschainSubstrateLib.remoteVaultSubstrate(REMOTE_CHAIN, remoteVault_);
        vault.grantSubstrates(MARKET, substrates);
    }

    function _data(
        CcipCommandType type_,
        bytes32 commandId_
    ) internal view returns (CcipCommandFuseEnterData memory data) {
        data.commandType = type_;
        data.executor = address(executor);
        data.chainId = REMOTE_CHAIN;
        data.gasLimit = 2_000_000;
        data.command.commandId = commandId_;
    }

    function _updateVaults(address remoteVault_) internal view returns (CcipCommandFuseEnterData memory data) {
        data = _data(CcipCommandType.UPDATE_VAULTS, bytes32(0));
        data.plasmaVaults = new address[](1);
        data.plasmaVaults[0] = remoteVault_;
        data.vaultsAllowed = true;
    }

    function _send(
        BusinessAction action_,
        bytes memory actionData_
    ) internal view returns (CcipCommandFuseEnterData memory data) {
        data = _data(CcipCommandType.SEND_COMMAND, bytes32(0));
        data.command = Command({
            commandId: bytes32(0),
            sequence: 0,
            commandConfigEpoch: 0,
            action: uint8(action_),
            minExecutionGas: 0,
            actionData: actionData_
        });
    }

    function _deposit(address remoteVault_, uint256 amount_) internal view returns (CcipCommandFuseEnterData memory) {
        return _send(BusinessAction.DEPOSIT, CrosschainMessages.encodeDepositAction(remoteVault_, amount_, 0));
    }

    function _redeem(address remoteVault_, uint256 shares_) internal view returns (CcipCommandFuseEnterData memory) {
        return _send(BusinessAction.REDEEM, CrosschainMessages.encodeRedeemAction(remoteVault_, shares_, 0));
    }

    function _supply() internal view returns (CcipSupplyFuseEnterData memory) {
        return
            CcipSupplyFuseEnterData({
                executor: address(executor),
                asset: address(token),
                dstChainId: REMOTE_CHAIN,
                amount: 1e6,
                maxFee: 0,
                feeToken: address(0),
                gasLimit: 2_000_000,
                minDelivered: 0
            });
    }

    function _bridge(uint256 amount_) internal {
        token.mint(address(executor), amount_);
        vm.prank(address(vault));
        executor.sendAssetToDispatcher(REMOTE_CHAIN, amount_, 0, address(0), 2_000_000);
    }

    function _attest(uint256 balance_) internal {
        uint64 version = executor.lastRemoteStateVersion(REMOTE_CHAIN);
        bytes32 positionSetHash = dispatcher.trackedPositionSetHash();
        vm.prank(PROPOSER);
        uint256 proposalId = executor.proposeBalance(
            REMOTE_CHAIN,
            balance_,
            version,
            1,
            uint64(block.timestamp),
            uint64(block.timestamp + 1 days),
            positionSetHash
        );
        vm.prank(APPROVER);
        executor.approveBalance(proposalId);
    }

    /// @notice CANCEL_COMMAND (recovery) and then a fresh DEPOSIT command in the same batch.
    function testShouldRefuseDepositCommandAfterCancelCommandInOneBatch() public {
        vm.expectRevert(CrosschainRecoveryLib.RecoveryExposureBatchForbidden.selector);
        vault.ccipTwo(_data(CcipCommandType.CANCEL_COMMAND, failedId), _deposit(address(pausableVault), 50e6));
    }

    /// @notice CANCEL_COMMAND (recovery) and then a RETRY_COMMAND of the stored DEPOSIT in the same batch.
    function testShouldRefuseRetryOfStoredDepositAfterCancelCommandInOneBatch() public {
        assertEq(executor.commandDepositTarget(failedId), address(pausableVault), "stored DEPOSIT target");

        vm.expectRevert(CrosschainRecoveryLib.RecoveryExposureBatchForbidden.selector);
        vault.ccipTwo(_data(CcipCommandType.CANCEL_COMMAND, failedId), _data(CcipCommandType.RETRY_COMMAND, failedId));
    }

    /// @notice CANCEL_COMMAND (recovery) and then a supply `enter` (new exposure) in the same batch.
    function testShouldRefuseSupplyEnterAfterCancelCommandInOneBatch() public {
        vm.expectRevert(CrosschainRecoveryLib.RecoveryExposureBatchForbidden.selector);
        vault.ccipCommandThenSupply(_data(CcipCommandType.CANCEL_COMMAND, failedId), _supply());
    }

    /// @notice A SEND_COMMAND REDEEM (recovery by business action) and then a DEPOSIT in the same batch.
    function testShouldRefuseDepositCommandAfterRedeemCommandInOneBatch() public {
        vault.enterCcipCommand(_data(CcipCommandType.CANCEL_COMMAND, failedId)); // free the lane first

        vm.expectRevert(CrosschainRecoveryLib.RecoveryExposureBatchForbidden.selector);
        vault.ccipTwo(_redeem(address(pausableVault), 1e6), _deposit(address(pausableVault), 50e6));
    }

    /// @notice claim (recovery) and then a supply `enter` in the same batch.
    /// @dev Reaches `CrosschainRecoveryLib.markNewExposure` (:114) through `CcipCrosschainSupplyFuse.enter`; the
    ///      claim arms recovery at `CrosschainClaimFuse.sol:93`.
    function testShouldRefuseSupplyEnterAfterClaimInOneBatch() public {
        vm.expectRevert(CrosschainRecoveryLib.RecoveryExposureBatchForbidden.selector);
        vault.ccipClaimThenSupply(_claim(), _supply());
        assertEq(executor.idleLedger(), 10e6, "claim rolled back with the batch");
    }

    /// @notice claim (recovery) and then a fresh DEPOSIT command in the same batch.
    /// @dev Reaches `markNewExposure` (:114) through `CcipCrosschainCommandFuse._gateOrMarkBusinessAction` (DEPOSIT).
    function testShouldRefuseDepositCommandAfterClaimInOneBatch() public {
        vm.expectRevert(CrosschainRecoveryLib.RecoveryExposureBatchForbidden.selector);
        vault.ccipClaimThenCommand(_claim(), _deposit(address(pausableVault), 50e6));
    }

    /// @notice claim (recovery) and then a RETRY_COMMAND of the stored DEPOSIT in the same batch.
    /// @dev Reaches `markNewExposure` (:114) through the retry path of `_gateOrMarkBusinessAction` (stored DEPOSIT).
    function testShouldRefuseRetryOfStoredDepositAfterClaimInOneBatch() public {
        assertEq(executor.commandDepositTarget(failedId), address(pausableVault), "stored DEPOSIT target");

        vm.expectRevert(CrosschainRecoveryLib.RecoveryExposureBatchForbidden.selector);
        vault.ccipClaimThenCommand(_claim(), _data(CcipCommandType.RETRY_COMMAND, failedId));
    }

    /// @notice A SEND_COMMAND REDEEM (recovery by business action) and then a supply `enter` in the same batch.
    /// @dev Reaches `markNewExposure` (:114) through `CcipCrosschainSupplyFuse.enter`; the REDEEM arms recovery at
    ///      `CcipCrosschainCommandFuse.sol:295`.
    ///
    ///      REDEEM -> RETRY DEPOSIT is deliberately not built: a REDEEM needs a free command lane, while a RETRY
    ///      needs the stored DEPOSIT occupying that lane, and the lane holds one command at a time. No valid
    ///      state has both, so the pair is unreachable (the retry would revert on the lane before the guard).
    function testShouldRefuseSupplyEnterAfterRedeemCommandInOneBatch() public {
        vault.enterCcipCommand(_data(CcipCommandType.CANCEL_COMMAND, failedId)); // free the lane first

        vm.expectRevert(CrosschainRecoveryLib.RecoveryExposureBatchForbidden.selector);
        vault.ccipCommandThenSupply(_redeem(address(pausableVault), 1e6), _supply());
    }

    /// @notice The same actions in separate transactions pass: the guard is batch-scoped, not a lasting lock.
    function testShouldAllowDepositInTheTransactionAfterACancel() public {
        vault.enterCcipCommand(_data(CcipCommandType.CANCEL_COMMAND, failedId));
        assertEq(uint8(executor.commandStatus(failedId)), uint8(CommandStatus.CANCELLED), "lane freed by CANCEL");

        vault.enterCcipCommand(_deposit(address(pausableVault), 50e6));
        assertEq(pausableVault.balanceOf(address(dispatcher)), 50e6, "DEPOSIT landed in the next transaction");

        vault.enterCcipSupply(_supply());
    }
}

/// @title RecoveryThenExposureRealVaultBatchTest
/// @notice IL-9127 on a REAL `PlasmaVault`: two `execute` batches of ONE transaction (a Safe MultiSend stand-in).
///         Batch 1 claims the executor's idle assets (recovery), batch 2 supplies (new exposure). The transient
///         recovery marker outlives the first batch, so batch 2 must revert with `RecoveryExposureBatchForbidden`;
///         the same supply in the next transaction passes. Setup follows `CrosschainRealVaultRecoveryTest` after the
///         IL-8979 migration (vault cloned through `PlasmaVaultCloneLib`), without inheriting that test class.
///
///         Runs isolated: each top-level call is its own transaction, as on chain; without it the transient flags
///         of an earlier call in the test would leak into the next one.
/// forge-config: default.isolate = true
contract RecoveryThenExposureRealVaultBatchTest is CrosschainTestBase {
    using IporFusionAccessManagerHelper for IporFusionAccessManager;

    uint256 internal constant MARKET = IporFusionMarkets.CROSSCHAIN;
    uint256 internal constant USER_DEPOSIT = 1_000e6;
    uint256 internal constant BRIDGED = 100e6;

    address internal constant ATOMIST = TestAddresses.ATOMIST;
    address internal constant ALPHA = TestAddresses.ALPHA;
    address internal constant FUSE_MANAGER = TestAddresses.FUSE_MANAGER;
    address internal constant OWNER = TestAddresses.OWNER;
    address internal constant USER = TestAddresses.USER;
    address internal constant OPERATOR = address(0x0FE4);

    PlasmaVault internal vault;
    IporFusionAccessManager internal accessManager;
    StargateCrosschainSupplyFuse internal supplyFuse;
    CrosschainClaimFuse internal claimFuse;
    RecoveryBatcher internal batcher;

    function setUp() public {
        _baseSetUp();
        _deployVault();

        // Every crosschain fuse requires `executor.MANAGER() == vault`, so rebuild the executor with the vault
        // as manager.
        manager = address(vault);
        executor = _deployExecutor(address(factory), _params());
        vm.deal(address(executor), 100 ether);

        _configureMarkets();
        _deposit(USER, USER_DEPOSIT);
        _bridgeSettleAndRecall40();

        // Stands in for the recovery Safe: ALPHA only, it just relays the two `execute` calls.
        batcher = new RecoveryBatcher(OPERATOR);
        vm.prank(ATOMIST);
        accessManager.grantRole(Roles.ALPHA_ROLE, address(batcher), 0);
    }

    function testShouldRefuseSupplyInSecondExecuteBatchAfterClaimInTheFirst() public {
        RecoveryBatcher.Call[] memory calls = new RecoveryBatcher.Call[](2);
        calls[0] = RecoveryBatcher.Call({
            target: address(vault),
            data: abi.encodeCall(IPlasmaVault.execute, (_claimAction(40e6)))
        });
        calls[1] = RecoveryBatcher.Call({
            target: address(vault),
            data: abi.encodeCall(IPlasmaVault.execute, (_supplyAction(10e6)))
        });

        // The batcher bubbles the vault's revert data unchanged (`Address.functionCall`).
        vm.prank(OPERATOR);
        vm.expectRevert(CrosschainRecoveryLib.RecoveryExposureBatchForbidden.selector);
        batcher.run(calls);

        // Nothing of the reverted transaction persisted: the idle assets are still on the executor.
        assertEq(executor.idleLedger(), 40e6, "claim rolled back with the batch");
    }

    function testShouldAllowSupplyInTheTransactionAfterAClaim() public {
        vm.prank(ALPHA);
        vault.execute(_claimAction(40e6));
        assertEq(executor.idleLedger(), 0, "idle claimed");

        uint256 vaultBalanceBefore = usdc.balanceOf(address(vault));
        vm.prank(ALPHA);
        vault.execute(_supplyAction(10e6));
        assertEq(usdc.balanceOf(address(vault)), vaultBalanceBefore - 10e6, "supply sent in the next transaction");
    }

    // =====================================================================
    // Setup
    // =====================================================================

    function _deployVault() private {
        accessManager = new IporFusionAccessManager(ATOMIST, 0);
        WithdrawManager withdrawManager = new WithdrawManager(address(accessManager));

        PriceOracleMiddleware oracleImpl = new PriceOracleMiddleware(address(0));
        PriceOracleMiddleware oracle = PriceOracleMiddleware(
            address(new ERC1967Proxy(address(oracleImpl), abi.encodeWithSignature("initialize(address)", ATOMIST)))
        );
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        address[] memory sources = new address[](1);
        sources[0] = address(new MutableValuePriceFeed(1e18)); // $1.00, 18-decimal feed
        vm.prank(ATOMIST);
        oracle.setAssetsPricesSources(assets, sources);

        // Heavy contracts come from their artifacts to keep this test contract small.
        address plasmaVaultBase = vm.deployCode("PlasmaVaultBase.sol:PlasmaVaultBase");
        address feeFactory = vm.deployCode("FeeManagerFactory.sol:FeeManagerFactory");
        vault = PlasmaVaultCloneLib.clone(vm.deployCode("PlasmaVault.sol:PlasmaVault"));

        vm.startPrank(ATOMIST);
        vault.proxyInitialize(
            PlasmaVaultInitData({
                assetName: "Crosschain Recovery Vault",
                assetSymbol: "xcRV",
                underlyingToken: address(usdc),
                priceOracleMiddleware: address(oracle),
                feeConfig: FeeConfig({
                    iporDaoManagementFee: 0,
                    iporDaoPerformanceFee: 0,
                    feeFactory: feeFactory,
                    iporDaoFeeRecipientAddress: TestAddresses.IPOR_DAO_FEE_RECIPIENT_ADDRESS
                }),
                accessManager: address(accessManager),
                plasmaVaultBase: plasmaVaultBase,
                withdrawManager: address(withdrawManager),
                plasmaVaultVotesPlugin: address(0)
            })
        );
        RewardsClaimManager rewardsClaimManager = new RewardsClaimManager(address(accessManager), address(vault));
        accessManager.setupInitRoles(vault, address(withdrawManager), address(rewardsClaimManager));
        vm.stopPrank();
    }

    function _configureMarkets() private {
        supplyFuse = new StargateCrosschainSupplyFuse(MARKET);
        claimFuse = new CrosschainClaimFuse(MARKET);
        CrosschainBalanceFuse balanceFuse = new CrosschainBalanceFuse(MARKET);

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuse);
        fuses[1] = address(claimFuse);

        PlasmaVaultGovernance governance = PlasmaVaultGovernance(address(vault));
        vm.startPrank(FUSE_MANAGER);
        governance.addFuses(fuses);
        governance.addBalanceFuse(MARKET, address(balanceFuse));
        vm.stopPrank();

        bytes32[] memory subs = new bytes32[](1);
        subs[0] = CrosschainSubstrateLib.executorSubstrate(address(executor));
        vm.prank(FUSE_MANAGER);
        governance.grantMarketSubstrates(MARKET, subs);
    }

    /// @dev ALPHA bridges `BRIDGED` through the supply fuse, the dispatcher settles it and the executor gets a
    ///      fresh attestation; then 40e6 is recalled into the executor's idle ledger (idle = 40e6, settled = 60e6).
    function _bridgeSettleAndRecall40() private {
        _readyDispatcher();

        vm.recordLogs();
        vm.prank(ALPHA);
        vault.execute(_supplyAction(BRIDGED));
        (bytes32 transferId, bytes32 guid, ) = _captureAssetSent();

        _deliverTransferSettled(transferId, guid, BRIDGED, 1);
        _attest(BRIDGED, 1);
        _refresh();

        (bytes32 requestId, , ) = _requestAssets(40e6, 0);
        _deliverReturnStarted(requestId, RGUID, 40e6, 40e6, 2);
        usdc.mint(address(executor), 40e6);
        _deliverReturnCompose(requestId, RGUID, 40e6);

        assertEq(executor.idleLedger(), 40e6, "idle funded");
        _refresh();
    }

    function _attest(uint256 settledLD_, uint64 stateVersion_) private {
        BalanceObservation memory o = BalanceObservation({
            chainId: REMOTE_CHAIN,
            settledBalance: settledLD_,
            stateVersion: stateVersion_,
            remoteBlock: 1,
            remoteTimestamp: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 30 minutes),
            trackedPositionSetHash: bytes32(0)
        });
        vm.prank(proposer);
        executor.proposeBalance(o);
        uint256 proposalId = executor.proposalCount();
        vm.prank(approver);
        executor.approveBalance(proposalId);
    }

    function _deposit(address user_, uint256 amount_) private {
        usdc.mint(user_, amount_);
        vm.startPrank(user_);
        usdc.approve(address(vault), amount_);
        vault.deposit(amount_, user_);
        vm.stopPrank();
    }

    function _refresh() private {
        uint256[] memory markets = new uint256[](1);
        markets[0] = MARKET;
        vm.prank(ATOMIST); // UPDATE_MARKETS_BALANCES in the default role set
        vault.updateMarketsBalances(markets);
    }

    function _claimAction(uint256 amount_) private view returns (FuseAction[] memory actions) {
        actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(claimFuse),
            data: abi.encodeCall(
                CrosschainClaimFuse.enter,
                (CrosschainClaimFuseEnterData({executor: address(executor), amount: amount_}))
            )
        });
    }

    function _supplyAction(uint256 amount_) private view returns (FuseAction[] memory actions) {
        actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(supplyFuse),
            data: abi.encodeCall(
                StargateCrosschainSupplyFuse.enter,
                (
                    StargateCrosschainSupplyFuseEnterData({
                        executor: address(executor),
                        asset: address(usdc),
                        dstChainId: REMOTE_CHAIN,
                        amount: amount_,
                        minAmountLD: 0,
                        options: ""
                    })
                )
            )
        });
    }
}
