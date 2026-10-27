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

contract AllowanceResetToken is ERC20 {
    constructor() ERC20("USD", "USD") {}

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}

/// @notice Non-conforming ERC-4626 that pulls `SHORTFALL` wei less than the `assets` it is asked to deposit.
contract ShortPullingCcipVault is MockRemoteVault {
    uint256 internal constant SHORTFALL = 1;

    constructor(IERC20 asset_) MockRemoteVault(asset_, "Short", "SHORT") {}

    function deposit(uint256 assets_, address receiver_) public override returns (uint256 shares) {
        uint256 pulled = assets_ - SHORTFALL;
        shares = previewDeposit(pulled);
        _deposit(_msgSender(), receiver_, pulled, shares);
    }
}

/// @title CcipDepositAllowanceResetTest
/// @notice IL-9128: after a DEPOSIT in which the vault pulls less than approved, the CCIP dispatcher resets the
///         unused vault allowance to zero. Every other mock vault pulls the full amount, so removing the reset
///         would go unnoticed without this suite.
contract CcipDepositAllowanceResetTest is Test {
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;

    MockCcipRouter internal router;
    AllowanceResetToken internal token;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;

    function setUp() public {
        router = new MockCcipRouter();
        token = new AllowanceResetToken();
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

    function testShouldResetUnusedVaultAllowanceAfterPartialDeposit() public {
        ShortPullingCcipVault vault = new ShortPullingCcipVault(IERC20(address(token)));
        _allow(address(vault));

        bytes32 id = _deposit(address(vault), 50e18, 0);

        _assertSucceeded(id);
        assertEq(token.balanceOf(address(dispatcher)), 50e18 + 1, "vault pulled 1 wei less than requested");
        assertEq(token.allowance(address(dispatcher), address(vault)), 0, "unused vault allowance reset");
        assertEq(IERC20(address(vault)).balanceOf(address(dispatcher)), 50e18 - 1, "shares match the pulled amount");
        assertEq(dispatcher.trackedIdle(), 50e18 + 1, "trackedIdle debited by the measured spend only");
        assertEq(dispatcher.trackedIdle(), token.balanceOf(address(dispatcher)), "ledger matches holdings");
    }
}
