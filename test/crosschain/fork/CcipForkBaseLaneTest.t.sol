// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {CcipForkBase, CcipForkMessage} from "./CcipForkBase.sol";
import {CcipCrosschainFactory} from "../../../contracts/crosschain/ccip/CcipCrosschainFactory.sol";
import {CcipMsgType} from "../../../contracts/crosschain/ccip/lib/CcipMessages.sol";

/// @title CcipForkBaseLaneTest
/// @notice IL-8458 / Codex O-14: the Ethereum -> Base lane on pinned forks (Base @ 51,945,000). Ethereum uses the
///         same OnRamp 2.0.0 for Base as for Arbitrum; Base executes through its own OffRamp 2.0.0. Covers dispatcher
///         deployment, the DEPLOYMENT_ACK back to Ethereum and a BALANCE_REQUEST / BALANCE_REPORT round trip.
contract CcipForkBaseLaneTest is CcipForkBase {
    uint256 internal baseFork;

    function setUp() public {
        ethFork = vm.createFork(vm.envString("ETHEREUM_PROVIDER_URL"), ETHEREUM_FORK_BLOCK);
        baseFork = vm.createFork(vm.envString("BASE_PROVIDER_URL"), BASE_FORK_BLOCK);
        factoryDeployer = makeAddr("IL-8458-ccip-factory-deployer");

        vm.selectFork(baseFork);
        CcipCrosschainFactory baseFactory = _deployFactory(BASE_ROUTER, ETHEREUM_CHAIN_ID, ETHEREUM_SELECTOR);
        vm.selectFork(ethFork);
        factory = _deployFactory(ETHEREUM_ROUTER, BASE_CHAIN_ID, BASE_SELECTOR);
        assertEq(address(factory), address(baseFactory), "factory at the same address on both forks");
        _createExecutor(BASE_CHAIN_ID, BASE_SELECTOR);
    }

    function _deliver(CcipForkMessage memory, address, string memory) internal pure override {
        revert("not used");
    }

    function _execute(uint256 fork_, address router_, CcipForkMessage memory m_, uint64 backSelector_)
        private
        returns (CcipForkMessage memory response)
    {
        vm.selectFork(fork_);
        _startCapture();
        assertEq(_executeOnOffRamp(m_, router_, 0), 2, "OffRamp 2.0 SUCCESS");
        CcipForkMessage[] memory sent = _sent(router_, backSelector_);
        if (sent.length != 0) response = _single(sent);
    }

    function testShouldDeployADispatcherAndRoundTripOverTheBaseLane() public {
        _warmExecutorStorage();
        _startCapture();
        factory.requestDispatcher(address(executor), BASE_CHAIN_ID, new address[](0), MAX_FEE);
        CcipForkMessage memory create = _single(_sent(ETHEREUM_ROUTER, BASE_SELECTOR));
        assertEq(create.destChainSelector, BASE_SELECTOR);

        CcipForkMessage memory ack = _execute(baseFork, BASE_ROUTER, create, ETHEREUM_SELECTOR);
        assertEq(uint8(_type(ack)), uint8(CcipMsgType.DEPLOYMENT_ACK));
        assertTrue(address(dispatcher).code.length != 0, "dispatcher deployed on Base");
        vm.deal(address(dispatcher), 1 ether);
        _execute(ethFork, ETHEREUM_ROUTER, ack, BASE_SELECTOR);
        assertTrue(executor.isDispatcherReady(BASE_CHAIN_ID));

        _startCapture();
        executor.requestRemoteBalance(BASE_CHAIN_ID, MAX_FEE, FEE_TOKEN, MESSAGE_GAS_LIMIT);
        CcipForkMessage memory request = _single(_sent(ETHEREUM_ROUTER, BASE_SELECTOR));
        CcipForkMessage memory report = _execute(baseFork, BASE_ROUTER, request, ETHEREUM_SELECTOR);
        assertEq(uint8(_type(report)), uint8(CcipMsgType.BALANCE_REPORT));
        // A balance report is value-neutral (IL-8257): it bumps no state version and never moves the frontier.
        uint64 version = dispatcher.stateVersion();
        assertEq(version, 0, "the balance request bumped no state version");
        _execute(ethFork, ETHEREUM_ROUTER, report, BASE_SELECTOR);
        assertEq(executor.lastRemoteStateVersion(BASE_CHAIN_ID), version, "frontier untouched by the report");
    }
}
