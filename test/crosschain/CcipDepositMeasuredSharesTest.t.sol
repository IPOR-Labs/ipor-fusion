// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {BusinessAction, CommandStatus} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {Command, CrosschainMessages} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";
import {MockRemoteVault} from "./mocks/MockRemoteVault.sol";
import {MockOverReportingVault} from "./mocks/MockOverReportingVault.sol";

contract DepositToken is ERC20 {
    constructor() ERC20("USD", "USD") {}

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}

/// @title CcipDepositMeasuredSharesTest
/// @notice IL-8601 (Ackee TP-M-23): the CCIP DEPOSIT `minShares` check runs against the share balance delta the
///         dispatcher actually received, never the value the vault's `deposit` returns.
contract CcipDepositMeasuredSharesTest is Test {
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;

    MockCcipRouter internal router;
    DepositToken internal token;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;

    function setUp() public {
        router = new MockCcipRouter();
        token = new DepositToken();
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
                rescueAdmin: address(0xA11),
                rescueGuardian: address(0xB22),
                balanceProposer: address(this),
                balanceApprover: address(0xA33),
                rescueDelay: 3 days,
                balanceStalenessMax: 7 days,
                bigChangeBps: 2_000,
                minUpdateInterval: 1 hours,
                transferStalenessMax: 1 days
            })
        );
        CcipRouteConfig memory back = CcipRouteConfig({
            chainSelector: EXECUTOR_SELECTOR,
            peer: address(executor),
            feeToken: address(0),
            messageGasLimit: 2_000_000,
            tokenGasLimit: 2_000_000,
            maxFee: 0,
            enabled: true
        });
        dispatcher = new CcipCrosschainDispatcher(
            address(router),
            factory,
            address(token),
            keccak256("USDC"),
            18,
            block.chainid,
            back,
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
        router.setSelector(address(executor), EXECUTOR_SELECTOR);
        router.setSelector(address(dispatcher), DISPATCHER_SELECTOR);
        vm.prank(factory);
        executor.markDispatcherReady(REMOTE_CHAIN);

        token.mint(address(executor), 100e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e18, 0, address(0), 2_000_000);
        vm.warp(block.timestamp + 1);
        uint256 proposalId = executor.proposeBalance(
            REMOTE_CHAIN,
            100e18,
            executor.lastRemoteStateVersion(REMOTE_CHAIN),
            1,
            uint64(block.timestamp),
            uint64(block.timestamp + 1 days),
            dispatcher.trackedPositionSetHash()
        );
        vm.prank(address(0xA33));
        executor.approveBalance(proposalId);
    }

    function _allow(address vault_) private {
        address[] memory vaults = new address[](1);
        vaults[0] = vault_;
        executor.updateVaults(REMOTE_CHAIN, vaults, true, false, 0, address(0), 2_000_000);
    }

    /// @dev Sends a DEPOSIT with the message held, reads its id while the command is still active, then delivers it
    ///      (command and ACK run synchronously, so the active command is cleared on success).
    function _deposit(address vault_, uint256 amount_, uint256 minShares_) private returns (bytes32 commandId) {
        router.setAutoDeliver(false);
        executor.sendCommandToDispatcher(
            REMOTE_CHAIN,
            Command({
                commandId: bytes32(0),
                sequence: 0,
                commandConfigEpoch: 0,
                action: uint8(BusinessAction.DEPOSIT),
                minExecutionGas: 0,
                actionData: CrosschainMessages.encodeDepositAction(vault_, amount_, minShares_)
            }),
            0,
            address(0),
            2_000_000
        );
        router.setAutoDeliver(true);
        commandId = executor.activeCommand(REMOTE_CHAIN);
        assertTrue(commandId != bytes32(0), "command id read while active");
        router.deliverHeld(router.heldCount() - 1);
    }

    function _assertSucceeded(bytes32 id_) private view {
        assertEq(uint8(dispatcher.commandStatus(id_)), uint8(CommandStatus.SUCCEEDED), "dispatcher SUCCEEDED");
        assertEq(uint8(executor.commandStatus(id_)), uint8(CommandStatus.SUCCEEDED), "executor SUCCEEDED");
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "active command cleared by the ACK");
    }

    function testShouldRevertDepositWhenVaultOverReportsShares() public {
        MockOverReportingVault liar = new MockOverReportingVault(IERC20(address(token)), 50, 2);
        _allow(address(liar));

        // Mints 25e18 shares but returns 100e18; minShares 30e18 sits between the two.
        bytes32 id = _deposit(address(liar), 50e18, 30e18);

        assertEq(uint8(executor.commandStatus(id)), uint8(CommandStatus.FAILED), "NACKed");
        assertEq(dispatcher.trackedIdle(), 100e18, "failed command debits nothing");
        assertEq(token.balanceOf(address(dispatcher)), 100e18, "assets stay in the dispatcher (reverted)");
        assertEq(IERC20(address(liar)).balanceOf(address(dispatcher)), 0, "no shares kept");
    }

    function testShouldRevertDepositWhenVaultMintsNoShares() public {
        MockOverReportingVault liar = new MockOverReportingVault(IERC20(address(token)), 0, 3);
        _allow(address(liar));

        bytes32 id = _deposit(address(liar), 50e18, 0); // even minShares == 0 must not accept a zero mint

        assertEq(uint8(executor.commandStatus(id)), uint8(CommandStatus.FAILED), "NACKed");
        assertEq(dispatcher.trackedIdle(), 100e18, "ledger untouched");
        assertEq(token.balanceOf(address(dispatcher)), 100e18);
    }

    function testShouldAcceptDepositWhenMeasuredSharesMeetMinimum() public {
        MockOverReportingVault liar = new MockOverReportingVault(IERC20(address(token)), 50, 2);
        _allow(address(liar));

        bytes32 id = _deposit(address(liar), 50e18, 25e18); // exactly the measured delta

        _assertSucceeded(id);
        assertEq(IERC20(address(liar)).balanceOf(address(dispatcher)), 25e18);
        assertEq(dispatcher.trackedIdle(), 50e18);
    }

    function testShouldAcceptConformingVaultDeposit() public {
        MockRemoteVault vault = new MockRemoteVault(IERC20(address(token)), "v", "V");
        _allow(address(vault));

        bytes32 id = _deposit(address(vault), 50e18, 50e18);

        _assertSucceeded(id);
        assertEq(IERC20(address(vault)).balanceOf(address(dispatcher)), 50e18);
    }
}
