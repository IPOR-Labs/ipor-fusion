// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";

import {CcipCrosschainFactory} from "../../contracts/crosschain/ccip/CcipCrosschainFactory.sol";
import {CcipCreate3Deployer} from "../../contracts/crosschain/ccip/CcipCreate3Deployer.sol";
import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipAppBase} from "../../contracts/crosschain/ccip/base/CcipAppBase.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {CcipClient} from "../../contracts/crosschain/ccip/interfaces/CcipClient.sol";
import {CcipMessages, CcipMsgType} from "../../contracts/crosschain/ccip/lib/CcipMessages.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";

contract CcipFactoryTest is Test {
    /// @dev Expiry stamped into a hand-built CREATE_DISPATCHER payload (the factory uses `DEPLOYMENT_TTL`).
    function _expiry() private view returns (uint256) {
        return block.timestamp + 7 days;
    }

    MockCcipRouter internal router;
    MockERC20 internal token;
    CcipCrosschainFactory internal factory;
    bytes32 internal constant ASSET_ID = keccak256("USDC");

    function setUp() public {
        router = new MockCcipRouter();
        token = new MockERC20("USD Coin", "USDC", 6);
        factory = new CcipCrosschainFactory(address(router), address(this));
        factory.scheduleAsset(ASSET_ID, address(token), 6);
        vm.warp(block.timestamp + factory.CONFIG_DELAY());
        factory.executeAsset(ASSET_ID, address(token), 6);
        factory.configureCreationCodes(
            type(CcipCrosschainExecutor).creationCode, type(CcipCrosschainDispatcher).creationCode
        );
    }

    function testShouldEmitInitialCreatorAllowanceAndRestrictionFromConstructor() public {
        vm.recordLogs();
        CcipCrosschainFactory fresh = new CcipCrosschainFactory(address(router), address(this));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool sawAllowance;
        bool sawRestriction;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(fresh)) continue;
            if (logs[i].topics[0] == CcipCrosschainFactory.CreatorAllowanceUpdated.selector) {
                (address creator, bool allowed) = abi.decode(logs[i].data, (address, bool));
                if (creator == address(this) && allowed) sawAllowance = true;
            } else if (logs[i].topics[0] == CcipCrosschainFactory.CreationRestrictionUpdated.selector) {
                if (abi.decode(logs[i].data, (bool))) sawRestriction = true;
            }
        }
        assertTrue(sawAllowance, "CreatorAllowanceUpdated(owner, true) missing");
        assertTrue(sawRestriction, "CreationRestrictionUpdated(true) missing");
        assertTrue(fresh.isAllowedCreator(address(this)));
        assertTrue(fresh.creationRestricted());
    }

    function testShouldCreateDeterministicExecutorAndIndexByManager() public {
        bytes32 salt = keccak256("ccip");
        address predicted = factory.computeExecutorAddress(address(this), salt);
        address deployed = factory.createExecutor(salt, ASSET_ID, address(0xBEEF), _safety());
        assertEq(deployed, predicted);
        assertTrue(factory.isExecutor(deployed));
        assertEq(CcipCrosschainExecutor(payable(deployed)).MANAGER(), address(0xBEEF));
        assertEq(CcipCrosschainExecutor(payable(deployed)).ASSET(), address(token));
        address[] memory executors = factory.executorsOf(address(0xBEEF));
        assertEq(executors.length, 1);
        assertEq(executors[0], deployed);
    }

    function testShouldRejectDisabledAsset() public {
        vm.expectRevert(abi.encodeWithSelector(CcipCrosschainFactory.AssetNotEnabled.selector, bytes32("DAI")));
        factory.createExecutor(bytes32("x"), bytes32("DAI"), address(this), _safety());
    }

    function testShouldRestrictCreationByDefaultAndAllowExplicitCreator() public {
        address creator = address(0xCAFE);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(CcipCrosschainFactory.CreatorNotAllowed.selector, creator));
        factory.createExecutor(bytes32("blocked"), ASSET_ID, address(this), _safety());

        factory.setCreatorAllowed(creator, true);
        vm.prank(creator);
        address deployed = factory.createExecutor(bytes32("allowed"), ASSET_ID, address(this), _safety());
        assertTrue(factory.isExecutor(deployed));
    }

    function testShouldRegisterExecutorRouteOnlyThroughMatchingFactoryRoute() public {
        uint256 remoteChain = 8453;
        CcipRouteConfig memory factoryRoute = CcipRouteConfig({
            chainSelector: 15971525489660198786,
            peer: address(factory),
            feeToken: address(0),
            messageGasLimit: 500_000,
            tokenGasLimit: 700_000,
            maxFee: 0.01 ether,
            enabled: true
        });
        factory.scheduleFactoryRoute(remoteChain, factoryRoute);
        vm.warp(block.timestamp + factory.CONFIG_DELAY());
        factory.executeFactoryRoute(remoteChain, factoryRoute);

        address executorAddress = factory.createExecutor(bytes32("route"), ASSET_ID, address(this), _safety());
        CcipRouteConfig memory executorRoute = factoryRoute;
        executorRoute.peer = executorAddress;
        factory.registerExecutorRoute(executorAddress, remoteChain, executorRoute);

        CcipRouteConfig memory stored = CcipCrosschainExecutor(payable(executorAddress)).ccipRoute(remoteChain);
        assertEq(stored.chainSelector, factoryRoute.chainSelector);
        assertEq(stored.peer, executorAddress);

        executorRoute.maxFee += 1;
        vm.expectRevert(
            abi.encodeWithSelector(CcipCrosschainFactory.ExecutorRouteMismatch.selector, executorAddress, remoteChain)
        );
        factory.registerExecutorRoute(executorAddress, remoteChain, executorRoute);
    }

    function testShouldTimelockAndPermissionlesslySyncUpdatedExecutorPolicy() public {
        uint256 remoteChain = 8453;
        CcipRouteConfig memory factoryRoute = _factoryRoute();
        _setFactoryRoute(remoteChain, factoryRoute);

        address executorAddress = factory.createExecutor(bytes32("policy"), ASSET_ID, address(this), _safety());
        CcipRouteConfig memory executorRoute = _appRoute(factoryRoute, executorAddress);
        factory.registerExecutorRoute(executorAddress, remoteChain, executorRoute);

        factoryRoute.feeToken = address(0xFEE);
        factoryRoute.messageGasLimit = 600_000;
        factoryRoute.tokenGasLimit = 800_000;
        factoryRoute.maxFee = 0.05 ether;
        factoryRoute.enabled = false;
        _setFactoryRoute(remoteChain, factoryRoute);

        vm.prank(address(0xBEEF));
        factory.syncCcipRoutePolicy(executorAddress, remoteChain);

        CcipRouteConfig memory stored = CcipCrosschainExecutor(payable(executorAddress)).ccipRoute(remoteChain);
        assertEq(stored.chainSelector, factoryRoute.chainSelector, "selector remains pinned");
        assertEq(stored.peer, executorAddress, "application peer remains pinned");
        assertEq(stored.feeToken, factoryRoute.feeToken);
        assertEq(stored.messageGasLimit, factoryRoute.messageGasLimit);
        assertEq(stored.tokenGasLimit, factoryRoute.tokenGasLimit);
        assertEq(stored.maxFee, factoryRoute.maxFee);
        assertFalse(stored.enabled);
    }

    /// @notice IL-8480 (B-23): first registration emits `CcipRouteRegistered` and the full route config.
    function testShouldEmitFullRouteConfigOnRouteRegistration() public {
        uint256 remoteChain = 8453;
        CcipRouteConfig memory route = _factoryRoute();
        factory.scheduleFactoryRoute(remoteChain, route);
        vm.warp(block.timestamp + factory.CONFIG_DELAY());

        vm.recordLogs();
        factory.executeFactoryRoute(remoteChain, route);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        Vm.Log memory registered = _findLog(logs, address(factory), CcipAppBase.CcipRouteRegistered.selector);
        (uint256 regChain, uint64 regSelector, address regPeer) = abi.decode(registered.data, (uint256, uint64, address));
        assertEq(regChain, remoteChain);
        assertEq(regSelector, route.chainSelector);
        assertEq(regPeer, route.peer);
        Vm.Log memory updated = _findLog(logs, address(factory), CcipAppBase.CcipRoutePolicyUpdated.selector);
        (uint256 chainId, CcipRouteConfig memory emitted) = abi.decode(updated.data, (uint256, CcipRouteConfig));
        assertEq(chainId, remoteChain);
        _assertRouteEq(emitted, route);
    }

    /// @notice IL-8480 (B-23): a policy update that disables the lane and moves fee and gas caps is visible in
    ///         plain values, not only as a hash change.
    function testShouldEmitFullRouteConfigWhenPolicyDisablesLane() public {
        uint256 remoteChain = 8453;
        CcipRouteConfig memory factoryRoute = _factoryRoute();
        _setFactoryRoute(remoteChain, factoryRoute);
        address executorAddress = factory.createExecutor(bytes32("b23"), ASSET_ID, address(this), _safety());
        factory.registerExecutorRoute(executorAddress, remoteChain, _appRoute(factoryRoute, executorAddress));

        factoryRoute.feeToken = address(0xFEE);
        factoryRoute.messageGasLimit = 600_000;
        factoryRoute.tokenGasLimit = 800_000;
        factoryRoute.maxFee = 0.05 ether;
        factoryRoute.enabled = false;
        _setFactoryRoute(remoteChain, factoryRoute);

        vm.recordLogs();
        factory.syncCcipRoutePolicy(executorAddress, remoteChain);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        Vm.Log memory updated = _findLog(logs, executorAddress, CcipAppBase.CcipRoutePolicyUpdated.selector);
        (uint256 chainId, CcipRouteConfig memory emitted) = abi.decode(updated.data, (uint256, CcipRouteConfig));
        assertEq(chainId, remoteChain);
        assertFalse(emitted.enabled, "disabled lane visible in the event");
        assertEq(emitted.feeToken, address(0xFEE));
        assertEq(emitted.messageGasLimit, 600_000);
        assertEq(emitted.tokenGasLimit, 800_000);
        assertEq(emitted.maxFee, 0.05 ether);
        assertEq(emitted.peer, executorAddress);
        assertEq(emitted.chainSelector, factoryRoute.chainSelector);
    }

    /// @notice IL-8480 (B-23): `scheduleFactoryRoute` emits the route values and the executable timestamp.
    function testShouldEmitFactoryRouteScheduledWithRouteValues() public {
        uint256 remoteChain = 8453;
        CcipRouteConfig memory route = _factoryRoute();
        uint256 executableAt = block.timestamp + factory.CONFIG_DELAY();

        vm.recordLogs();
        factory.scheduleFactoryRoute(remoteChain, route);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        Vm.Log memory scheduled = _findLog(logs, address(factory), CcipCrosschainFactory.FactoryRouteScheduled.selector);
        (uint256 chainId, CcipRouteConfig memory emitted, uint256 at) =
            abi.decode(scheduled.data, (uint256, CcipRouteConfig, uint256));
        assertEq(chainId, remoteChain);
        assertEq(at, executableAt);
        _assertRouteEq(emitted, route);
        _findLog(logs, address(factory), CcipCrosschainFactory.ConfigScheduled.selector);
    }

    // ---------------------------------------------------------------------
    // IL-8516: separate gas limit for the CREATE_DISPATCHER deployment ticket
    // ---------------------------------------------------------------------

    uint256 private constant DEPLOY_CHAIN = 8453;
    uint96 private constant COMMAND_GAS = 2_000_000;
    uint96 private constant DEPLOY_GAS = 6_000_000;

    function _routeWithCommandGas() private view returns (CcipRouteConfig memory route) {
        route = _factoryRoute();
        route.messageGasLimit = COMMAND_GAS;
        route.maxFee = 0.01 ether;
    }

    function _gasArgs(uint96 gasLimit_) private pure returns (bytes memory) {
        return
            CcipClient.argsToBytes(CcipClient.GenericExtraArgsV2({gasLimit: gasLimit_, allowOutOfOrderExecution: true}));
    }

    function _setDeploymentGasLimit(uint256 chainId_, uint96 gasLimit_) private {
        factory.scheduleDispatcherDeploymentGasLimit(chainId_, gasLimit_);
        vm.warp(block.timestamp + factory.CONFIG_DELAY());
        factory.executeDispatcherDeploymentGasLimit(chainId_, gasLimit_);
    }

    function _requestTicketAndReadGas(bytes32 salt_) private returns (address executorAddress, uint96 gasLimit) {
        router.setAutoDeliver(false);
        executorAddress = factory.createExecutor(salt_, ASSET_ID, address(this), _safety());
        address[] memory vaults = new address[](0);
        factory.requestDispatcher(executorAddress, DEPLOY_CHAIN, vaults, 0.01 ether);
        bytes memory args = router.lastExtraArgs();
        // layout: 4-byte tag, uint256 gasLimit, bool allowOutOfOrderExecution
        uint256 raw;
        assembly {
            raw := mload(add(args, 36))
        }
        gasLimit = uint96(raw);
        assertEq(args, _gasArgs(gasLimit), "extraArgs shape");
    }

    function testShouldSendDeploymentTicketWithDeploymentGasLimitWhenSet() public {
        _setFactoryRoute(DEPLOY_CHAIN, _routeWithCommandGas());
        _setDeploymentGasLimit(DEPLOY_CHAIN, DEPLOY_GAS);
        assertEq(factory.dispatcherDeploymentGasLimit(DEPLOY_CHAIN), DEPLOY_GAS);

        (, uint96 used) = _requestTicketAndReadGas(bytes32("deploy-set"));
        assertEq(used, DEPLOY_GAS, "ticket uses the deployment limit");
    }

    function testShouldFallBackToMessageGasLimitWhenDeploymentLimitUnsetOrReset() public {
        _setFactoryRoute(DEPLOY_CHAIN, _routeWithCommandGas());
        assertEq(factory.dispatcherDeploymentGasLimit(DEPLOY_CHAIN), 0);

        (, uint96 unsetUsed) = _requestTicketAndReadGas(bytes32("deploy-unset"));
        assertEq(unsetUsed, COMMAND_GAS, "unset falls back to messageGasLimit");

        _setDeploymentGasLimit(DEPLOY_CHAIN, DEPLOY_GAS);
        _setDeploymentGasLimit(DEPLOY_CHAIN, 0);
        assertEq(factory.dispatcherDeploymentGasLimit(DEPLOY_CHAIN), 0);

        (, uint96 resetUsed) = _requestTicketAndReadGas(bytes32("deploy-reset"));
        assertEq(resetUsed, COMMAND_GAS, "reset to 0 falls back to messageGasLimit");
    }

    function testShouldKeepRoutePolicySyncOnMessageGasLimitWhenDeploymentLimitSet() public {
        CcipRouteConfig memory route = _routeWithCommandGas();
        _setFactoryRoute(DEPLOY_CHAIN, route);
        address executorAddress = factory.createExecutor(bytes32("sync"), ASSET_ID, address(this), _safety());
        factory.registerExecutorRoute(executorAddress, DEPLOY_CHAIN, _appRoute(route, executorAddress));

        _setDeploymentGasLimit(DEPLOY_CHAIN, DEPLOY_GAS);
        factory.syncCcipRoutePolicy(executorAddress, DEPLOY_CHAIN);

        CcipRouteConfig memory stored = CcipCrosschainExecutor(payable(executorAddress)).ccipRoute(DEPLOY_CHAIN);
        assertEq(stored.messageGasLimit, COMMAND_GAS, "executor policy is not the deployment limit");
        // Registering an executor route that carries the deployment limit is still refused.
        CcipRouteConfig memory wrong = _appRoute(route, executorAddress);
        wrong.messageGasLimit = DEPLOY_GAS;
        vm.expectRevert(
            abi.encodeWithSelector(CcipCrosschainFactory.ExecutorRouteMismatch.selector, executorAddress, DEPLOY_CHAIN)
        );
        factory.registerExecutorRoute(executorAddress, DEPLOY_CHAIN, wrong);
    }

    function _deliverCreate(CcipRouteConfig memory route_, CcipCrosschainFactory.DeploymentTicket memory ticket_)
        private
    {
        vm.prank(address(router));
        factory.ccipReceive(
            CcipClient.Any2EVMMessage({
                messageId: keccak256(abi.encode("create", ticket_.vaults)),
                sourceChainSelector: route_.chainSelector,
                sender: abi.encode(address(factory)),
                data: CcipMessages.encode(CcipMsgType.CREATE_DISPATCHER, abi.encode(ticket_, _expiry())),
                destTokenAmounts: new CcipClient.EVMTokenAmount[](0)
            })
        );
    }

    function _remoteTicket(address[] memory vaults_)
        private
        view
        returns (CcipCrosschainFactory.DeploymentTicket memory)
    {
        bytes32 userSalt = keccak256("remote-executor");
        return CcipCrosschainFactory.DeploymentTicket({
            salt: keccak256(abi.encode(address(this), userSalt, uint8(7))),
            executor: factory.computeExecutorAddress(address(this), userSalt),
            srcChainId: DEPLOY_CHAIN,
            dstChainId: block.chainid,
            assetId: ASSET_ID,
            sharedDecimals: 6,
            vaults: vaults_,
            rescueAdmin: address(0xA11),
            rescueGuardian: address(0xB22),
            rescueDelay: 3 days
        });
    }

    function testShouldSendDeploymentAckAndNackWithMessageGasLimit() public {
        CcipRouteConfig memory route = _routeWithCommandGas();
        _setFactoryRoute(DEPLOY_CHAIN, route);
        _setDeploymentGasLimit(DEPLOY_CHAIN, DEPLOY_GAS);
        router.setAutoDeliver(false);

        _deliverCreate(route, _remoteTicket(new address[](0)));
        assertEq(router.heldCount(), 1);
        assertEq(router.lastExtraArgs(), _gasArgs(COMMAND_GAS), "ACK uses messageGasLimit");

        address[] memory other = new address[](1);
        other[0] = address(0xB002);
        _deliverCreate(route, _remoteTicket(other));
        assertEq(router.heldCount(), 2);
        assertEq(router.lastExtraArgs(), _gasArgs(COMMAND_GAS), "NACK uses messageGasLimit");
    }

    function testShouldMeasureDeploymentAckHandlerGas() public {
        CcipRouteConfig memory route = _routeWithCommandGas();
        _setFactoryRoute(DEPLOY_CHAIN, route);
        router.setAutoDeliver(false);
        (address executorAddress,) = _requestTicketAndReadGas(bytes32("ack-gas"));
        bytes32 ticketHash = factory.pendingDeploymentTicket(executorAddress, DEPLOY_CHAIN);

        CcipClient.Any2EVMMessage memory message = CcipClient.Any2EVMMessage({
            messageId: keccak256("ack"),
            sourceChainSelector: route.chainSelector,
            sender: abi.encode(address(factory)),
            data: CcipMessages.encode(
                CcipMsgType.DEPLOYMENT_ACK, abi.encode(executorAddress, DEPLOY_CHAIN, ticketHash)
            ),
            destTokenAmounts: new CcipClient.EVMTokenAmount[](0)
        });
        vm.prank(address(router));
        uint256 gasBefore = gasleft();
        factory.ccipReceive(message);
        uint256 used = gasBefore - gasleft();
        // solhint-disable-next-line no-console
        console2.log("DEPLOYMENT_ACK handler gas (cold-ish, in-test)", used);
        assertLt(used, COMMAND_GAS, "ACK fits the command gas limit");
        assertEq(factory.pendingDeploymentTicket(executorAddress, DEPLOY_CHAIN), bytes32(0));
    }

    function testShouldEmitDeploymentGasLimitEventsWithValues() public {
        uint256 executableAt = block.timestamp + factory.CONFIG_DELAY();
        vm.recordLogs();
        factory.scheduleDispatcherDeploymentGasLimit(DEPLOY_CHAIN, DEPLOY_GAS);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory scheduled =
            _findLog(logs, address(factory), CcipCrosschainFactory.DispatcherDeploymentGasLimitScheduled.selector);
        (uint256 chainId, uint96 gasLimit, uint256 at) = abi.decode(scheduled.data, (uint256, uint96, uint256));
        assertEq(chainId, DEPLOY_CHAIN);
        assertEq(gasLimit, DEPLOY_GAS);
        assertEq(at, executableAt);
        _findLog(logs, address(factory), CcipCrosschainFactory.ConfigScheduled.selector);

        vm.warp(executableAt);
        vm.recordLogs();
        factory.executeDispatcherDeploymentGasLimit(DEPLOY_CHAIN, DEPLOY_GAS);
        logs = vm.getRecordedLogs();
        Vm.Log memory executed =
            _findLog(logs, address(factory), CcipCrosschainFactory.DispatcherDeploymentGasLimitExecuted.selector);
        (chainId, gasLimit) = abi.decode(executed.data, (uint256, uint96));
        assertEq(chainId, DEPLOY_CHAIN);
        assertEq(gasLimit, DEPLOY_GAS);
    }

    function testShouldRejectDeploymentGasLimitExecuteBeforeDelayOrWithoutSchedule() public {
        bytes32 commitment = keccak256(abi.encode("DEPLOY_GAS", DEPLOY_CHAIN, DEPLOY_GAS));
        vm.expectRevert(abi.encodeWithSelector(CcipCrosschainFactory.ConfigNotScheduled.selector, commitment));
        factory.executeDispatcherDeploymentGasLimit(DEPLOY_CHAIN, DEPLOY_GAS);

        uint256 executableAt = block.timestamp + factory.CONFIG_DELAY();
        factory.scheduleDispatcherDeploymentGasLimit(DEPLOY_CHAIN, DEPLOY_GAS);
        vm.expectRevert(abi.encodeWithSelector(CcipCrosschainFactory.ConfigNotReady.selector, commitment, executableAt));
        factory.executeDispatcherDeploymentGasLimit(DEPLOY_CHAIN, DEPLOY_GAS);
        assertEq(factory.dispatcherDeploymentGasLimit(DEPLOY_CHAIN), 0);
    }

    function testShouldRejectCancelledOrDifferentDeploymentGasLimit() public {
        bytes32 commitment = keccak256(abi.encode("DEPLOY_GAS", DEPLOY_CHAIN, DEPLOY_GAS));
        factory.scheduleDispatcherDeploymentGasLimit(DEPLOY_CHAIN, DEPLOY_GAS);
        vm.warp(block.timestamp + factory.CONFIG_DELAY());

        bytes32 other = keccak256(abi.encode("DEPLOY_GAS", DEPLOY_CHAIN, DEPLOY_GAS + 1));
        vm.expectRevert(abi.encodeWithSelector(CcipCrosschainFactory.ConfigNotScheduled.selector, other));
        factory.executeDispatcherDeploymentGasLimit(DEPLOY_CHAIN, DEPLOY_GAS + 1);
        bytes32 otherChain = keccak256(abi.encode("DEPLOY_GAS", DEPLOY_CHAIN + 1, DEPLOY_GAS));
        vm.expectRevert(abi.encodeWithSelector(CcipCrosschainFactory.ConfigNotScheduled.selector, otherChain));
        factory.executeDispatcherDeploymentGasLimit(DEPLOY_CHAIN + 1, DEPLOY_GAS);

        factory.cancelScheduledConfig(commitment);
        vm.expectRevert(abi.encodeWithSelector(CcipCrosschainFactory.ConfigNotScheduled.selector, commitment));
        factory.executeDispatcherDeploymentGasLimit(DEPLOY_CHAIN, DEPLOY_GAS);
    }

    function testShouldRestrictDeploymentGasLimitToOwner() public {
        address stranger = address(0xBAD);
        vm.startPrank(stranger);
        vm.expectRevert(CcipCrosschainFactory.OnlyOwner.selector);
        factory.scheduleDispatcherDeploymentGasLimit(DEPLOY_CHAIN, DEPLOY_GAS);
        vm.expectRevert(CcipCrosschainFactory.OnlyOwner.selector);
        factory.executeDispatcherDeploymentGasLimit(DEPLOY_CHAIN, DEPLOY_GAS);
        vm.stopPrank();
    }

    function _findLog(Vm.Log[] memory logs_, address emitter_, bytes32 topic0_) private pure returns (Vm.Log memory) {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == emitter_ && logs_[i].topics[0] == topic0_) return logs_[i];
        }
        revert("log not found");
    }

    function _assertRouteEq(CcipRouteConfig memory a_, CcipRouteConfig memory b_) private pure {
        assertEq(a_.chainSelector, b_.chainSelector);
        assertEq(a_.peer, b_.peer);
        assertEq(a_.feeToken, b_.feeToken);
        assertEq(a_.messageGasLimit, b_.messageGasLimit);
        assertEq(a_.tokenGasLimit, b_.tokenGasLimit);
        assertEq(a_.maxFee, b_.maxFee);
        assertEq(a_.enabled, b_.enabled);
    }

    function testShouldRejectEnabledFactoryRouteWithZeroMessageGasLimit() public {
        CcipRouteConfig memory route = _factoryRoute();
        route.messageGasLimit = 0;
        factory.scheduleFactoryRoute(8453, route);
        vm.warp(block.timestamp + factory.CONFIG_DELAY());
        vm.expectRevert(abi.encodeWithSelector(CcipAppBase.CcipRouteGasPolicyUnset.selector, 8453));
        factory.executeFactoryRoute(8453, route);
    }

    function testShouldRejectEnabledFactoryRouteWithZeroTokenGasLimit() public {
        CcipRouteConfig memory route = _factoryRoute();
        route.tokenGasLimit = 0;
        factory.scheduleFactoryRoute(8453, route);
        vm.warp(block.timestamp + factory.CONFIG_DELAY());
        vm.expectRevert(abi.encodeWithSelector(CcipAppBase.CcipRouteGasPolicyUnset.selector, 8453));
        factory.executeFactoryRoute(8453, route);
    }

    function testShouldAcceptDisabledFactoryRouteWithZeroGasLimits() public {
        CcipRouteConfig memory route = _factoryRoute();
        route.messageGasLimit = 0;
        route.tokenGasLimit = 0;
        route.enabled = false;
        _setFactoryRoute(8453, route);
        bool enabled = factory.ccipRoute(8453).enabled;
        assertFalse(enabled);
    }

    function testShouldRejectFactoryRouteIdentityMutation() public {
        uint256 remoteChain = 8453;
        CcipRouteConfig memory route = _factoryRoute();
        address originalPeer = route.peer;
        uint64 originalSelector = route.chainSelector;
        _setFactoryRoute(remoteChain, route);

        CcipRouteConfig memory changed = route;
        changed.chainSelector = originalSelector + 1;
        factory.scheduleFactoryRoute(remoteChain, changed);
        vm.warp(block.timestamp + factory.CONFIG_DELAY());
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipAppBase.CcipRouteIdentityMismatch.selector,
                remoteChain,
                originalSelector,
                changed.chainSelector,
                originalPeer,
                changed.peer
            )
        );
        factory.executeFactoryRoute(remoteChain, changed);
    }

    function testShouldRejectForeignPeerOnScheduleFactoryRoute() public {
        uint256 remoteChain = 8453;
        CcipRouteConfig memory route = _factoryRoute();
        route.peer = address(0xBAD);

        vm.expectRevert(abi.encodeWithSelector(CcipCrosschainFactory.PeerMustBeSelf.selector, address(0xBAD)));
        factory.scheduleFactoryRoute(remoteChain, route);

        assertEq(factory.scheduledConfig(keccak256(abi.encode("ROUTE", remoteChain, route))), 0);
    }

    function testShouldRejectForeignPeerOnExecuteFactoryRoute() public {
        uint256 remoteChain = 8453;
        CcipRouteConfig memory route = _factoryRoute();
        route.peer = address(0xBAD);

        vm.expectRevert(abi.encodeWithSelector(CcipCrosschainFactory.PeerMustBeSelf.selector, address(0xBAD)));
        factory.executeFactoryRoute(remoteChain, route);
    }

    function testShouldRejectZeroPeerOnFactoryRouteAsNotSelf() public {
        uint256 remoteChain = 8453;
        CcipRouteConfig memory route = _factoryRoute();
        route.peer = address(0);

        vm.expectRevert(abi.encodeWithSelector(CcipCrosschainFactory.PeerMustBeSelf.selector, address(0)));
        factory.scheduleFactoryRoute(remoteChain, route);
    }

    /// @notice IL-8451: a factory route to this chain's own id is refused at schedule time, before the timelock.
    function testShouldRejectLocalChainOnScheduleFactoryRoute() public {
        CcipRouteConfig memory route = _factoryRoute();

        vm.expectRevert(abi.encodeWithSelector(CcipCrosschainFactory.RouteToLocalChain.selector, block.chainid));
        factory.scheduleFactoryRoute(block.chainid, route);

        assertEq(factory.scheduledConfig(keccak256(abi.encode("ROUTE", block.chainid, route))), 0);
    }

    function testShouldRejectLocalChainOnExecuteFactoryRoute() public {
        CcipRouteConfig memory route = _factoryRoute();

        vm.expectRevert(abi.encodeWithSelector(CcipCrosschainFactory.RouteToLocalChain.selector, block.chainid));
        factory.executeFactoryRoute(block.chainid, route);
    }

    function testShouldAcceptSelfPeerOnFactoryRoute() public {
        uint256 remoteChain = 8453;
        CcipRouteConfig memory route = _factoryRoute();
        _setFactoryRoute(remoteChain, route);

        CcipRouteConfig memory stored = factory.ccipRoute(remoteChain);
        assertEq(stored.peer, address(factory));
        assertEq(stored.chainSelector, route.chainSelector);
    }

    function testShouldSyncUpdatedPolicyToRegisteredDispatcher() public {
        uint256 remoteChain = 8453;
        CcipRouteConfig memory factoryRoute = _factoryRoute();
        _setFactoryRoute(remoteChain, factoryRoute);
        router.setAutoDeliver(false);

        bytes32 userSalt = keccak256("remote-executor");
        bytes32 deploymentSalt = keccak256(abi.encode(address(this), userSalt, uint8(7)));
        address dispatcherAddress = factory.computeExecutorAddress(address(this), userSalt);
        address[] memory vaults = new address[](0);
        CcipCrosschainFactory.DeploymentTicket memory ticket = CcipCrosschainFactory.DeploymentTicket({
            salt: deploymentSalt,
            executor: dispatcherAddress,
            srcChainId: remoteChain,
            dstChainId: block.chainid,
            assetId: ASSET_ID,
            sharedDecimals: 6,
            vaults: vaults,
            rescueAdmin: address(0xA11),
            rescueGuardian: address(0xB22),
            rescueDelay: 3 days
        });
        vm.prank(address(router));
        factory.ccipReceive(
            CcipClient.Any2EVMMessage({
                messageId: keccak256("deploy-dispatcher"),
                sourceChainSelector: factoryRoute.chainSelector,
                sender: abi.encode(address(factory)),
                data: CcipMessages.encode(CcipMsgType.CREATE_DISPATCHER, abi.encode(ticket, _expiry())),
                destTokenAmounts: new CcipClient.EVMTokenAmount[](0)
            })
        );
        assertTrue(factory.isDispatcher(dispatcherAddress));

        uint256 wrongChain = 42161;
        CcipRouteConfig memory wrongRoute = _factoryRoute();
        wrongRoute.chainSelector = factoryRoute.chainSelector + 1;
        _setFactoryRoute(wrongChain, wrongRoute);
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipCrosschainFactory.DispatcherRouteMismatch.selector, dispatcherAddress, remoteChain, wrongChain
            )
        );
        factory.syncCcipRoutePolicy(dispatcherAddress, wrongChain);

        factoryRoute.maxFee = 0.02 ether;
        factoryRoute.messageGasLimit = 650_000;
        factoryRoute.tokenGasLimit = 850_000;
        _setFactoryRoute(remoteChain, factoryRoute);

        vm.prank(address(0xCAFE));
        factory.syncCcipRoutePolicy(dispatcherAddress, remoteChain);
        CcipRouteConfig memory stored = CcipCrosschainDispatcher(payable(dispatcherAddress)).ccipRoute(remoteChain);
        assertEq(stored.peer, dispatcherAddress);
        assertEq(stored.maxFee, factoryRoute.maxFee);
        assertEq(stored.messageGasLimit, factoryRoute.messageGasLimit);
        assertEq(stored.tokenGasLimit, factoryRoute.tokenGasLimit);
    }

    function testShouldRejectPolicySyncForUnknownApplication() public {
        vm.expectRevert(abi.encodeWithSelector(CcipCrosschainFactory.InvalidCcipApp.selector, address(0xBAD)));
        factory.syncCcipRoutePolicy(address(0xBAD), 8453);
    }

    function testShouldRejectPolicySyncWhenTrackedAssetIsFeeToken() public {
        uint256 remoteChain = 8453;
        CcipRouteConfig memory factoryRoute = _factoryRoute();
        factoryRoute.feeToken = address(token);
        _setFactoryRoute(remoteChain, factoryRoute);
        address executorAddress = factory.createExecutor(bytes32("asset-fee"), ASSET_ID, address(this), _safety());

        vm.expectRevert(CcipCrosschainExecutor.AssetCannotPayCcipFees.selector);
        factory.syncCcipRoutePolicy(executorAddress, remoteChain);
    }

    /// @notice IL-9045: the dispatcher constructor refuses a fee token equal to its bridged asset.
    /// @dev Negative: constructor guard removed -> the dispatcher deploys -> no revert -> fails.
    function testShouldRejectDispatcherConstructorWhenAssetIsFeeToken() public {
        CcipRouteConfig memory route = _appRoute(_factoryRoute(), address(factory));
        route.feeToken = address(token);

        vm.expectRevert(CcipCrosschainDispatcher.AssetCannotPayCcipFees.selector);
        new CcipCrosschainDispatcher(
            address(router),
            address(factory),
            address(token),
            ASSET_ID,
            6,
            8453,
            route,
            address(0xA11),
            address(0xB22),
            3 days
        );
    }

    /// @notice IL-9045: a factory policy sync must not move a registered dispatcher's fee token to its asset.
    /// @dev Negative: `syncRoutePolicy` guard removed -> the dispatcher accepts the asset as fee token -> fails.
    function testShouldRejectDispatcherPolicySyncWhenTrackedAssetIsFeeToken() public {
        uint256 remoteChain = 8453;
        CcipRouteConfig memory factoryRoute = _factoryRoute();
        _setFactoryRoute(remoteChain, factoryRoute);
        router.setAutoDeliver(false);

        bytes32 deploymentSalt = keccak256(abi.encode(address(this), bytes32("disp-fee"), uint8(7)));
        address dispatcherAddress = factory.computeExecutorAddress(address(this), bytes32("disp-fee"));
        CcipCrosschainFactory.DeploymentTicket memory ticket = CcipCrosschainFactory.DeploymentTicket({
            salt: deploymentSalt,
            executor: dispatcherAddress,
            srcChainId: remoteChain,
            dstChainId: block.chainid,
            assetId: ASSET_ID,
            sharedDecimals: 6,
            vaults: new address[](0),
            rescueAdmin: address(0xA11),
            rescueGuardian: address(0xB22),
            rescueDelay: 3 days
        });
        vm.prank(address(router));
        factory.ccipReceive(
            CcipClient.Any2EVMMessage({
                messageId: keccak256("deploy-dispatcher-fee"),
                sourceChainSelector: factoryRoute.chainSelector,
                sender: abi.encode(address(factory)),
                data: CcipMessages.encode(CcipMsgType.CREATE_DISPATCHER, abi.encode(ticket, _expiry())),
                destTokenAmounts: new CcipClient.EVMTokenAmount[](0)
            })
        );
        assertTrue(factory.isDispatcher(dispatcherAddress));

        factoryRoute.feeToken = address(token);
        _setFactoryRoute(remoteChain, factoryRoute);

        vm.expectRevert(CcipCrosschainDispatcher.AssetCannotPayCcipFees.selector);
        factory.syncCcipRoutePolicy(dispatcherAddress, remoteChain);

        assertEq(CcipCrosschainDispatcher(payable(dispatcherAddress)).ccipRoute(remoteChain).feeToken, address(0));
    }

    function testShouldRejectDirectExecutorPolicyUpdateOutsideFactory() public {
        uint256 remoteChain = 8453;
        CcipRouteConfig memory factoryRoute = _factoryRoute();
        _setFactoryRoute(remoteChain, factoryRoute);
        address executorAddress = factory.createExecutor(bytes32("unauthorized"), ASSET_ID, address(this), _safety());

        vm.expectRevert(CcipCrosschainExecutor.OnlyFactory.selector);
        CcipCrosschainExecutor(payable(executorAddress))
            .registerRoute(remoteChain, _appRoute(factoryRoute, executorAddress));
    }

    function _factoryRoute() private view returns (CcipRouteConfig memory) {
        return CcipRouteConfig({
            chainSelector: 15971525489660198786,
            peer: address(factory),
            feeToken: address(0),
            messageGasLimit: 500_000,
            tokenGasLimit: 700_000,
            maxFee: 0.01 ether,
            enabled: true
        });
    }

    function _setFactoryRoute(uint256 chainId_, CcipRouteConfig memory route_) private {
        factory.scheduleFactoryRoute(chainId_, route_);
        vm.warp(block.timestamp + factory.CONFIG_DELAY());
        factory.executeFactoryRoute(chainId_, route_);
    }

    function _appRoute(CcipRouteConfig memory route_, address app_) private pure returns (CcipRouteConfig memory) {
        return CcipRouteConfig({
            chainSelector: route_.chainSelector,
            peer: app_,
            feeToken: route_.feeToken,
            messageGasLimit: route_.messageGasLimit,
            tokenGasLimit: route_.tokenGasLimit,
            maxFee: route_.maxFee,
            enabled: route_.enabled
        });
    }

    function _safety() private pure returns (CcipCrosschainExecutor.SafetyConfig memory) {
        return CcipCrosschainExecutor.SafetyConfig({
            rescueAdmin: address(0xA11),
            rescueGuardian: address(0xB22),
            balanceProposer: address(0xA33),
            balanceApprover: address(0xB44),
            rescueDelay: 3 days,
            balanceStalenessMax: 7 days,
            bigChangeBps: 2_000, // == ATTESTATION_ANCHOR_BAND_BPS, the constructor ceiling (IL-8058)
            minUpdateInterval: 1 hours,
            transferStalenessMax: 1 days
        });
    }

    function testShouldKeepFactoryAddressAcrossChainSpecificRouterInitCode() public {
        CcipCreate3Deployer anchor = new CcipCreate3Deployer(address(this));
        bytes32 salt = keccak256("common-ccip-factory");
        address predicted = anchor.getDeployed(salt);
        uint256 snapshot = vm.snapshotState();

        address first = anchor.deploy(
            salt, abi.encodePacked(type(CcipCrosschainFactory).creationCode, abi.encode(address(0x1111), address(this)))
        );
        assertEq(first, predicted);
        assertEq(CcipCrosschainFactory(payable(first)).CCIP_ROUTER(), address(0x1111));

        assertTrue(vm.revertToState(snapshot));
        address second = anchor.deploy(
            salt, abi.encodePacked(type(CcipCrosschainFactory).creationCode, abi.encode(address(0x2222), address(this)))
        );
        assertEq(second, predicted);
        assertEq(CcipCrosschainFactory(payable(second)).CCIP_ROUTER(), address(0x2222));
    }
}
