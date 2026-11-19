// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CcipExecutorFixture} from "./CcipExecutorFixture.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";
import {MockRemoteVault} from "./mocks/MockRemoteVault.sol";
import {BusinessAction, CommandStatus} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {Command, CrosschainMessages} from "../../contracts/crosschain/lib/CrosschainMessages.sol";

/// @notice ERC-4626 stand-in whose `deposit` sends `feeBps` of the assets to a fee sink (a vault with an entry
///         fee): the depositor's shares are worth `assets * (1 - fee)` right after the deposit.
contract DepositFeeRemoteVault is MockRemoteVault {
    address public constant FEE_SINK = address(0xFEE);
    uint256 public feeBps;

    constructor(IERC20 asset_) MockRemoteVault(asset_, "FeeVault", "FEE") {}

    function setFeeBps(uint256 feeBps_) external {
        feeBps = feeBps_;
    }

    function deposit(uint256 assets_, address receiver_) public override returns (uint256) {
        uint256 fee = (assets_ * feeBps) / 10_000;
        uint256 shares = previewDeposit(assets_ - fee);
        _deposit(_msgSender(), receiver_, assets_ - fee, shares);
        if (fee != 0) IERC20(asset()).transferFrom(_msgSender(), FEE_SINK, fee);
        return shares;
    }
}

/// @title CcipStaleProposalAfterDepositAckBoundTest
/// @notice IL-9656 (L25) pinning test on the accepted risk IL-8582 / IL-9208: the ACK of a DEPOSIT command does not
///         void a pending attestation proposal, so approving an observation taken before the (fee-paying) command
///         overstates `settled`. The test pins the BOUND of that overstatement: it equals the sum of the fees of the
///         commands sent after the observation (not more, whatever the number of commands) and it disappears at the
///         next attestation round.
/// @dev Pinning test: passes on base 8692fbe5 and on the current series state; no code change in IL-9656. Making the
///      ACK void the proposal would add bytes to the CCIP executor (EIP-170) and bring back the IL-8589 liveness
///      problem (D-039); it is deliberately not done.
contract CcipStaleProposalAfterDepositAckBoundTest is CcipExecutorFixture {
    uint256 internal constant BRIDGED = 100e18;

    DepositFeeRemoteVault internal remoteVault;

    function setUp() public {
        _fixtureSetUp();
        remoteVault = new DepositFeeRemoteVault(IERC20(address(token)));

        // Command lane gas floor (> 1.8M) needs a route with a larger message gas limit than the fixture default.
        CcipRouteConfig memory route = CcipRouteConfig({
            chainSelector: DISPATCHER_SELECTOR,
            peer: address(dispatcher),
            feeToken: address(0),
            messageGasLimit: 2_000_000,
            tokenGasLimit: 500_000,
            maxFee: 0,
            enabled: true
        });
        MockCcipRouteValidator(factory).setRoute(REMOTE_CHAIN, route);
        MockCcipRouteValidator(factory).registerExecutorRoute(address(executor), REMOTE_CHAIN, route);

        address[] memory vaults = new address[](1);
        vaults[0] = address(remoteVault);
        executor.updateVaults(REMOTE_CHAIN, vaults, true, false, 0, address(0), 2_000_000);

        _bridge(BRIDGED);
        // A fee-free first deposit makes the vault a tracked position and seeds its share price.
        _deposit(10e18);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(BRIDGED);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), BRIDGED, "settled = value before the paid commands");
        assertEq(dispatcher.accountedBalance(), BRIDGED, "no fee paid yet");
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
    }

    function _deposit(uint256 amount_) internal {
        router.setAutoDeliver(false);
        executor.sendCommandToDispatcher(
            REMOTE_CHAIN,
            Command({
                commandId: bytes32(0),
                sequence: 0,
                commandConfigEpoch: 0,
                action: uint8(BusinessAction.DEPOSIT),
                minExecutionGas: 0,
                actionData: CrosschainMessages.encodeDepositAction(address(remoteVault), amount_, 0)
            }),
            0,
            address(0),
            2_000_000
        );
        router.setAutoDeliver(true);
        bytes32 id = executor.activeCommand(REMOTE_CHAIN);
        assertTrue(id != bytes32(0), "command active before delivery");
        router.deliverHeld(router.heldCount() - 1);
        assertEq(uint8(executor.commandStatus(id)), uint8(CommandStatus.SUCCEEDED), "ACK processed");
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "ACK cleared the active command");
    }

    /// @dev Proposes `balance_` for the CURRENT state, then runs `commands_` paid deposits, each with `feeBps_`.
    function _proposeThenPayFees(
        uint256 balance_,
        uint256 commands_,
        uint256 amount_,
        uint256 feeBps_
    ) internal returns (uint256 proposalId) {
        proposalId = _propose(balance_);
        remoteVault.setFeeBps(feeBps_);
        for (uint256 i; i < commands_; ++i) {
            _deposit(amount_);
        }
    }

    function testShouldBoundTheOverstatementByTheFeeOfOneCommand() public {
        uint256 proposalId = _proposeThenPayFees(BRIDGED, 1, 20e18, 500); // fee 5% of 20 = 1
        uint256 trueValue = dispatcher.accountedBalance();
        assertEq(trueValue, BRIDGED - 1e18, "the command cost one fee");

        vm.prank(APPROVER);
        executor.approveBalance(proposalId); // the proposal survived the DEPOSIT and its ACK

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), BRIDGED, "stale observation approved");
        assertEq(
            executor.settledRemoteBalance(REMOTE_CHAIN) - trueValue,
            1e18,
            "overstatement = the fee of one command"
        );
    }

    function testShouldNotGrowBeyondTheSumOfTheFeesWithMoreCommands() public {
        uint256 proposalId = _proposeThenPayFees(BRIDGED, 3, 20e18, 500); // 3 x fee 1
        uint256 trueValue = dispatcher.accountedBalance();
        assertEq(trueValue, BRIDGED - 3e18, "three commands cost three fees");

        vm.prank(APPROVER);
        executor.approveBalance(proposalId);

        assertEq(
            executor.settledRemoteBalance(REMOTE_CHAIN) - trueValue,
            3e18,
            "overstatement = sum of the fees, no more"
        );
    }

    function testShouldDisappearAtTheNextAttestationRound() public {
        uint256 proposalId = _proposeThenPayFees(BRIDGED, 2, 20e18, 500);
        uint256 trueValue = dispatcher.accountedBalance();
        vm.prank(APPROVER);
        executor.approveBalance(proposalId);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN) - trueValue, 2e18, "overstated before the next round");

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(trueValue);

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), trueValue, "the next round restores the true value");
    }
}
