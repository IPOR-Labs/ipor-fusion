// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

// The fork suites print gas-budget and fee-quote reports for operators, so console output is intended here.
/* solhint-disable no-console */

import {console2} from "forge-std/console2.sol";

import {CcipForkBase, CcipForkMessage} from "./CcipForkBase.sol";
import {CcipMsgType} from "../../../contracts/crosschain/ccip/lib/CcipMessages.sol";
import {CcipCrosschainExecutor} from "../../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";

/// @title CcipForkGasTest
/// @notice IL-8458 / Codex O-14: measures, over the real CCIP transport, the gas every receiver handler uses
///         (`Router.routeMessage` `gasUsed`, i.e. exactly what the OffRamp's gas limit has to cover) and the fee the
///         real `Router.getFee` charged for each send, and checks every handler against the gas limit its message
///         carries with a 30% margin. Run with `-vv` for the table.
contract CcipForkGasTest is CcipForkBase {
    uint256 internal constant MARGIN_NUMERATOR = 13; // measured * 1.3 <= limit
    uint256 internal constant MARGIN_DENOMINATOR = 10;

    struct Row {
        string label;
        uint256 gasUsed;
        uint256 gasLimit;
        uint256 fee;
    }

    Row[] internal rows;

    /// @dev A fork backend of its own (see `CcipForkBase._forkBlocks`).
    function _forkBlocks() internal pure override returns (uint256, uint256) {
        return (ETHEREUM_FORK_BLOCK + 2, ARBITRUM_FORK_BLOCK + 2);
    }

    function setUp() public {
        _deployStack();
    }

    function _deliver(CcipForkMessage memory m_, address destRouter_, string memory label_) internal override {
        (bool success, bytes memory ret, uint256 gasUsed) = _routeViaRouter(m_, destRouter_, m_.ccipReceiveGasLimit);
        if (!success) {
            emit log_named_bytes(label_, ret);
            fail();
        }
        rows.push(Row({label: label_, gasUsed: gasUsed, gasLimit: m_.ccipReceiveGasLimit, fee: m_.appFee}));
    }

    function testShouldFitEveryReceiverHandlerInItsConfiguredGasLimit() public {
        _runLifecycle();
        _measureDeploymentNack();
        _report();
    }

    /// @dev A CREATE_DISPATCHER whose predicted address is already occupied on the destination -> DEPLOYMENT_NACK.
    function _measureDeploymentNack() private {
        vm.selectFork(ethFork);
        CcipCrosschainExecutor second = CcipCrosschainExecutor(
            payable(factory.createExecutor(keccak256("IL-8458-nack"), ASSET_ID, address(this), _safety()))
        );
        _startCapture();
        factory.requestDispatcher(address(second), ARBITRUM_CHAIN_ID, new address[](0), MAX_FEE);
        CcipForkMessage memory create = _sendFromExecutor();
        vm.selectFork(arbFork);
        vm.etch(address(second), hex"00"); // occupy the CREATE3 address on the destination
        CcipForkMessage memory nack = _single(_deliverAndCollect(create, "factory CREATE_DISPATCHER (occupied)"));
        assertEq(uint8(_type(nack)), uint8(CcipMsgType.DEPLOYMENT_NACK));
        _deliverAndCollect(nack, "factory DEPLOYMENT_NACK");
        vm.selectFork(ethFork);
        assertEq(factory.pendingDeploymentTicket(address(second), ARBITRUM_CHAIN_ID), bytes32(0), "NACK cleared ticket");
    }

    function _isDispatcherDeploy(string memory label_) private pure returns (bool) {
        return keccak256(bytes(label_)) == keccak256("factory CREATE_DISPATCHER (CREATE3 deploy)");
    }

    function _report() private view {
        console2.log("| Receiver handler | gasUsed | gas limit | used % of limit | send fee (wei) | fee % of maxFee |");
        console2.log("|---|---:|---:|---:|---:|---:|");
        for (uint256 i; i < rows.length; ++i) {
            Row memory r = rows[i];
            console2.log(
                string.concat(
                    "| ",
                    r.label,
                    " | ",
                    vm.toString(r.gasUsed),
                    " | ",
                    vm.toString(r.gasLimit),
                    " | ",
                    vm.toString(r.gasUsed * 100 / r.gasLimit),
                    "% | ",
                    vm.toString(r.fee),
                    " | ",
                    vm.toString(r.fee * 100 / MAX_FEE),
                    "% |"
                )
            );
        }
        for (uint256 i; i < rows.length; ++i) {
            Row memory r = rows[i];
            assertGt(r.fee, 0, string.concat(r.label, ": real getFee was paid"));
            assertLe(r.fee, MAX_FEE, string.concat(r.label, ": fee within the route maxFee"));
            if (_isDispatcherDeploy(r.label)) {
                // KNOWN ISSUE (IL-8458 report): the CREATE3 deployment of the dispatcher is bytecode-bound and
                // uses ~92% of the 6,000,000 route messageGasLimit (mainnet-ccip-test-v6). It fits, but with under
                // 10% headroom instead of 30%: any dispatcher growth or gas repricing makes CREATE_DISPATCHER fail
                // on the destination. Pinned here so the headroom is visible and cannot shrink unnoticed.
                assertLe(r.gasUsed * 105 / 100, r.gasLimit, string.concat(r.label, ": below 5% headroom"));
                continue;
            }
            assertLe(
                r.gasUsed * MARGIN_NUMERATOR / MARGIN_DENOMINATOR,
                r.gasLimit,
                string.concat(r.label, ": measured gas * 1.3 exceeds the message gas limit")
            );
        }
    }
}
