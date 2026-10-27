// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipDecimalsLib} from "../../contracts/crosschain/ccip/lib/CcipDecimalsLib.sol";
import {CcipMessages, CcipMsgType} from "../../contracts/crosschain/ccip/lib/CcipMessages.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {BusinessAction, CommandStatus} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {Command, CrosschainMessages} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";
import {MockRemoteVault, MockRemotePlasmaVault, MockWithdrawManager} from "./mocks/MockRemoteVault.sol";

contract FloorToken is ERC20 {
    uint8 private immutable _DEC;

    constructor(uint8 dec_) ERC20("USD", "USD") {
        _DEC = dec_;
    }

    function decimals() public view override returns (uint8) {
        return _DEC;
    }

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}

/// @title CcipRedeemFloorDecimalsTest
/// @notice IL-9017: on a route with more local than shared decimals (18 / 6) the REDEEM and REDEEM_FROM_REQUEST
///         `minAssets` floor travels in SHARED decimals and must be converted back to local decimals before it is
///         compared with the measured receipt. A missing scale would weaken the floor by 10^12. Also pins that
///         `shares` stay unscaled on the wire and that a delivery with sub-unit dust is floored with the dust
///         left untracked.
contract CcipRedeemFloorDecimalsTest is Test {
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;
    bytes32 internal constant INBOUND_SETTLED = keccak256("InboundSettled(bytes32,uint256,uint64)");

    MockCcipRouter internal router;
    FloorToken internal token;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;
    address internal factory;

    function setUp() public {
        vm.warp(365 days);
        router = new MockCcipRouter();
        token = new FloorToken(18);
        MockCcipRouteValidator routeValidator = new MockCcipRouteValidator();
        factory = address(routeValidator);
        executor = new CcipCrosschainExecutor(
            address(router),
            factory,
            address(this),
            address(token),
            keccak256("USDC"),
            6,
            _safety()
        );
        CcipRouteConfig memory back = _route(EXECUTOR_SELECTOR, address(executor));
        dispatcher = new CcipCrosschainDispatcher(
            address(router),
            factory,
            address(token),
            keccak256("USDC"),
            6,
            block.chainid,
            back,
            address(0xA11),
            address(0xB22),
            3 days
        );
        vm.prank(factory);
        dispatcher.configureVaults(new address[](0), true);
        CcipRouteConfig memory executorRoute = _route(DISPATCHER_SELECTOR, address(dispatcher));
        routeValidator.setRoute(REMOTE_CHAIN, executorRoute);
        routeValidator.registerExecutorRoute(address(executor), REMOTE_CHAIN, executorRoute);
        router.setSelector(address(executor), EXECUTOR_SELECTOR);
        router.setSelector(address(dispatcher), DISPATCHER_SELECTOR);
        vm.prank(factory);
        executor.markDispatcherReady(REMOTE_CHAIN);

        assertEq(executor.DECIMAL_CONVERSION_RATE(), 1e12, "18/6 route");
    }

    // ------------------------------------------------------------------ REDEEM

    function testShouldPutRedeemFloorOnTheWireInSharedDecimalsAndSharesUnscaled() public {
        MockRemoteVault vault = new MockRemoteVault(IERC20(address(token)), "V", "V");
        _fundAndDeposit(address(vault));
        router.setAutoDeliver(false);

        _sendRedeem(address(vault), 50e18, 50e18);

        Command memory wire = _heldCommand(0);
        assertEq(wire.action, uint8(BusinessAction.REDEEM), "action");
        (address wVault, uint256 wShares, uint256 wMinAssetsSD) = CrosschainMessages.decodeRedeemAction(
            wire.actionData
        );
        assertEq(wVault, address(vault), "vault");
        assertEq(wShares, 50e18, "shares are share units: never scaled");
        assertEq(wMinAssetsSD, 50e18 / 1e12, "minAssets travels in shared decimals");
    }

    function testShouldRedeemExactlyAtTheLocalDecimalsFloor() public {
        MockRemoteVault vault = new MockRemoteVault(IERC20(address(token)), "V", "V");
        _fundAndDeposit(address(vault));
        router.setAutoDeliver(false);

        _sendRedeem(address(vault), 50e18, 50e18);
        Command memory wire = _heldCommand(0);
        router.deliverHeld(0);

        assertEq(uint8(dispatcher.commandStatus(wire.commandId)), uint8(CommandStatus.SUCCEEDED), "at floor");
        assertEq(vault.balanceOf(address(dispatcher)), 0, "shares redeemed");
        assertEq(dispatcher.trackedIdle(), 100e6, "idle back to 100 SD");
    }

    function testShouldNackRedeemOneWeiBelowTheFloorWithoutBurningShares() public {
        MockRemoteVault vault = new MockRemoteVault(IERC20(address(token)), "V", "V");
        _fundAndDeposit(address(vault));
        // The vault loses 1 wei: redeeming everything now pays 50e18 - 1, one wei below the floor (50e6 SD = 50e18 LD).
        vm.prank(address(vault));
        token.transfer(address(0xdead), 1);
        router.setAutoDeliver(false);

        _sendRedeem(address(vault), 50e18, 50e18);
        Command memory wire = _heldCommand(0);
        router.deliverHeld(0);

        assertEq(uint8(dispatcher.commandStatus(wire.commandId)), uint8(CommandStatus.FAILED), "below floor NACKed");
        assertEq(vault.balanceOf(address(dispatcher)), 50e18, "shares untouched");
        assertEq(dispatcher.trackedIdle(), 50e6, "idle untouched");
    }

    function testShouldRevertRedeemBelowFloorWithFullMinimumNotMet() public {
        MockRemoteVault vault = new MockRemoteVault(IERC20(address(token)), "V", "V");
        _fundAndDeposit(address(vault));
        vm.prank(address(vault));
        token.transfer(address(0xdead), 1);
        router.setAutoDeliver(false);

        _sendRedeem(address(vault), 50e18, 50e18);
        Command memory wire = _heldCommand(0);

        // `_runCommand` swallows the reason, so run the stored command directly: the floor is compared in LD.
        vm.expectRevert(abi.encodeWithSelector(CcipCrosschainDispatcher.MinimumNotMet.selector, 50e18 - 1, 50e18));
        vm.prank(address(dispatcher));
        dispatcher.runStoredCommand(CcipMsgType.COMMAND, wire, "");
    }

    function testShouldRedeemWithSharesBeyondTheFloorWhenAssetsExceedIt() public {
        MockRemoteVault vault = new MockRemoteVault(IERC20(address(token)), "V", "V");
        _fundAndDeposit(address(vault));
        // Yield: the vault now pays 60e18 for the 50e18 shares; a 55e18 floor (55e6 SD) is met.
        token.mint(address(vault), 10e18);
        router.setAutoDeliver(false);

        _sendRedeem(address(vault), 50e18, 55e18);
        Command memory wire = _heldCommand(0);
        router.deliverHeld(0);
        assertEq(uint8(dispatcher.commandStatus(wire.commandId)), uint8(CommandStatus.SUCCEEDED), "yield above floor");
        // The vault's ERC-4626 virtual-share rounding pays 60e18 - 1, which floors to 60e6 - 1 SD.
        assertEq(dispatcher.trackedIdle(), uint256(50e6) + uint256(60e18 - 1) / 1e12, "50 + floored 60 SD");
    }

    function testShouldRejectRedeemFloorWithDustOnSend() public {
        MockRemoteVault vault = new MockRemoteVault(IERC20(address(token)), "V", "V");
        _fundAndDeposit(address(vault));

        vm.expectRevert(abi.encodeWithSelector(CcipDecimalsLib.AmountHasDust.selector, 50e18 + 1));
        _sendRedeem(address(vault), 50e18, 50e18 + 1);
    }

    // ------------------------------------------------------------------ REDEEM_FROM_REQUEST

    function testShouldPutRedeemFromRequestFloorOnTheWireInSharedDecimals() public {
        (MockWithdrawManager wm, MockRemotePlasmaVault rv) = _mockWm();
        _fundAndDeposit(address(rv));
        _requestShares(wm, rv, 50e18);
        router.setAutoDeliver(false);

        _sendRedeemFromRequest(wm, rv, 50e18, 50e18);

        Command memory wire = _heldCommand(0);
        assertEq(wire.action, uint8(BusinessAction.REDEEM_FROM_REQUEST), "action");
        (address wWm, address wVault, uint256 wShares, uint256 wMinAssetsSD, address wReceiver) = CrosschainMessages
            .decodeRedeemFromRequestAction(wire.actionData);
        assertEq(wWm, address(wm), "manager");
        assertEq(wVault, address(rv), "vault");
        assertEq(wShares, 50e18, "shares are share units: never scaled");
        assertEq(wMinAssetsSD, 50e6, "minAssets travels in shared decimals");
        assertEq(wReceiver, address(dispatcher), "receiver");
    }

    function testShouldRedeemFromRequestExactlyAtTheLocalDecimalsFloor() public {
        (MockWithdrawManager wm, MockRemotePlasmaVault rv) = _mockWm();
        _fundAndDeposit(address(rv));
        _requestShares(wm, rv, 50e18);
        router.setAutoDeliver(false);

        _sendRedeemFromRequest(wm, rv, 50e18, 50e18);
        Command memory wire = _heldCommand(0);
        router.deliverHeld(0);

        assertEq(uint8(dispatcher.commandStatus(wire.commandId)), uint8(CommandStatus.SUCCEEDED), "at floor");
        assertEq(dispatcher.trackedIdle(), 100e6, "idle back to 100 SD");
    }

    function testShouldNackRedeemFromRequestOneWeiBelowTheFloorKeepingTheRequest() public {
        (MockWithdrawManager wm, MockRemotePlasmaVault rv) = _mockWm();
        _fundAndDeposit(address(rv));
        _requestShares(wm, rv, 50e18);
        vm.prank(address(rv));
        token.transfer(address(0xdead), 1);
        router.setAutoDeliver(false);

        _sendRedeemFromRequest(wm, rv, 50e18, 50e18);
        Command memory wire = _heldCommand(0);
        router.deliverHeld(0);

        assertEq(uint8(dispatcher.commandStatus(wire.commandId)), uint8(CommandStatus.FAILED), "below floor NACKed");
        assertEq(wm.requestInfo(address(dispatcher)).shares, 50e18, "request untouched");
        assertEq(rv.balanceOf(address(dispatcher)), 50e18, "shares untouched");
    }

    function testShouldRevertRedeemFromRequestBelowFloorWithFullMinimumNotMet() public {
        (MockWithdrawManager wm, MockRemotePlasmaVault rv) = _mockWm();
        _fundAndDeposit(address(rv));
        _requestShares(wm, rv, 50e18);
        vm.prank(address(rv));
        token.transfer(address(0xdead), 1);
        router.setAutoDeliver(false);

        _sendRedeemFromRequest(wm, rv, 50e18, 50e18);
        Command memory wire = _heldCommand(0);

        vm.expectRevert(abi.encodeWithSelector(CcipCrosschainDispatcher.MinimumNotMet.selector, 50e18 - 1, 50e18));
        vm.prank(address(dispatcher));
        dispatcher.runStoredCommand(CcipMsgType.COMMAND, wire, "");
    }

    function testShouldRejectRedeemFromRequestFloorWithDustOnSend() public {
        (MockWithdrawManager wm, MockRemotePlasmaVault rv) = _mockWm();
        _fundAndDeposit(address(rv));
        _requestShares(wm, rv, 50e18);

        vm.expectRevert(abi.encodeWithSelector(CcipDecimalsLib.AmountHasDust.selector, 50e18 + 1));
        _sendRedeemFromRequest(wm, rv, 50e18, 50e18 + 1);
    }

    // ------------------------------------------------------------------ REQUEST_SHARES

    function testShouldPassRequestSharesWithUnscaledShares() public {
        (MockWithdrawManager wm, MockRemotePlasmaVault rv) = _mockWm();
        _fundAndDeposit(address(rv));
        router.setAutoDeliver(false);

        bytes memory data = CrosschainMessages.encodeRequestSharesAction(
            address(wm),
            address(rv),
            50e18,
            type(uint256).max
        );
        _send(BusinessAction.REQUEST_SHARES, data);

        Command memory wire = _heldCommand(0);
        assertEq(wire.actionData, data, "REQUEST_SHARES data is not normalized");
        router.deliverHeld(0);

        assertEq(uint8(dispatcher.commandStatus(wire.commandId)), uint8(CommandStatus.SUCCEEDED), "request ok");
        assertEq(wm.requestInfo(address(dispatcher)).shares, 50e18, "50e18 share units requested, not 50e6");
    }

    // ------------------------------------------------------------------ inbound dust

    function testShouldFloorNonDivisibleDeliveryAndKeepDustUntracked() public {
        // 10_001e12 LD with a 1 bps pool haircut: delivered = 9_999_999_900_000_000, i.e. 9_999 SD + 999_900_000_000 dust.
        uint256 sent = 10_001e12;
        uint256 delivered = sent - ((sent * 1) / 10_000);
        assertEq(delivered % 1e12, 999_900_000_000, "delivery carries sub-unit dust");
        router.setPoolHaircutBps(1);
        token.mint(address(executor), sent);
        uint64 versionBefore = dispatcher.stateVersion();

        vm.recordLogs();
        executor.sendAssetToDispatcher(REMOTE_CHAIN, sent, 0, address(0), 2_000_000);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(dispatcher.trackedIdle(), delivered / 1e12, "tracked idle is the floor");
        assertEq(dispatcher.trackedIdle(), 9_999, "floor in shared decimals");
        assertEq(token.balanceOf(address(dispatcher)), delivered, "the whole delivery is held");
        assertEq(
            token.balanceOf(address(dispatcher)) - dispatcher.trackedIdle() * 1e12,
            999_900_000_000,
            "the dust stays as untracked surplus"
        );
        assertEq(dispatcher.stateVersion(), versionBefore + 1, "state version +1");

        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(dispatcher) && logs[i].topics[0] == INBOUND_SETTLED) {
                (, uint256 amount, uint64 version) = abi.decode(logs[i].data, (bytes32, uint256, uint64));
                assertEq(amount, 9_999, "TRANSFER_SETTLED carries the floored amount");
                assertEq(version, versionBefore + 1, "event version");
                found = true;
            }
        }
        assertTrue(found, "InboundSettled emitted");
    }

    // ------------------------------------------------------------------ helpers

    function _route(uint64 selector_, address peer_) private pure returns (CcipRouteConfig memory) {
        return
            CcipRouteConfig({
                chainSelector: selector_,
                peer: peer_,
                feeToken: address(0),
                messageGasLimit: 2_000_000,
                tokenGasLimit: 2_000_000,
                maxFee: 0,
                enabled: true
            });
    }

    function _safety() private view returns (CcipCrosschainExecutor.SafetyConfig memory) {
        return
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
            });
    }

    function _attest(uint256 balanceSD_) private {
        vm.warp(block.timestamp + 1);
        uint256 proposalId = executor.proposeBalance(
            REMOTE_CHAIN,
            balanceSD_ * 1e12,
            executor.lastRemoteStateVersion(REMOTE_CHAIN),
            1,
            uint64(block.timestamp),
            uint64(block.timestamp + 1 days),
            dispatcher.trackedPositionSetHash()
        );
        vm.prank(address(0xA33));
        executor.approveBalance(proposalId);
    }

    function _mockWm() private returns (MockWithdrawManager wm, MockRemotePlasmaVault rv) {
        rv = new MockRemotePlasmaVault(IERC20(address(token)), "Mock WM Vault", "MWVLT");
        wm = new MockWithdrawManager(address(rv));
        rv.setWithdrawManager(address(wm));
    }

    /// @dev Bridges 100 SD (100e18 LD) of idle, allowlists `vault_` and deposits half of it: 50e18 shares at 1:1.
    function _fundAndDeposit(address vault_) private {
        token.mint(address(executor), 100e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e18, 0, address(0), 2_000_000);
        assertEq(dispatcher.trackedIdle(), 100e6, "idle in shared decimals");
        _attest(100e6);

        address[] memory vaults = new address[](1);
        vaults[0] = vault_;
        executor.updateVaults(REMOTE_CHAIN, vaults, true, false, 0, address(0), 2_000_000);
        _send(BusinessAction.DEPOSIT, CrosschainMessages.encodeDepositAction(vault_, 50e18, 0));
        assertEq(IERC20(vault_).balanceOf(address(dispatcher)), 50e18, "50e18 shares");
        assertEq(dispatcher.trackedIdle(), 50e6, "50 SD left idle");
    }

    function _requestShares(MockWithdrawManager wm, MockRemotePlasmaVault rv, uint256 shares_) private {
        _send(
            BusinessAction.REQUEST_SHARES,
            CrosschainMessages.encodeRequestSharesAction(address(wm), address(rv), shares_, type(uint256).max)
        );
        assertEq(wm.requestInfo(address(dispatcher)).shares, shares_, "request recorded");
    }

    function _sendRedeem(address vault_, uint256 shares_, uint256 minAssetsLD_) private {
        _send(BusinessAction.REDEEM, CrosschainMessages.encodeRedeemAction(vault_, shares_, minAssetsLD_));
    }

    function _sendRedeemFromRequest(
        MockWithdrawManager wm,
        MockRemotePlasmaVault rv,
        uint256 shares_,
        uint256 minAssetsLD_
    ) private {
        _send(
            BusinessAction.REDEEM_FROM_REQUEST,
            CrosschainMessages.encodeRedeemFromRequestAction(
                address(wm),
                address(rv),
                shares_,
                minAssetsLD_,
                address(dispatcher)
            )
        );
    }

    function _send(BusinessAction action_, bytes memory actionData_) private {
        executor.sendCommandToDispatcher(
            REMOTE_CHAIN,
            Command({
                commandId: bytes32(0),
                sequence: 0,
                commandConfigEpoch: 0,
                action: uint8(action_),
                minExecutionGas: 0,
                actionData: actionData_
            }),
            0,
            address(0),
            2_000_000
        );
    }

    /// @dev The command the executor put on the wire (held while `autoDeliver` is off).
    function _heldCommand(uint256 index_) private view returns (Command memory command) {
        (CcipMsgType messageType, bytes memory data) = CcipMessages.decode(router.heldData(index_));
        assertEq(uint8(messageType), uint8(CcipMsgType.COMMAND), "COMMAND on the wire");
        (, command, ) = abi.decode(data, (CcipMsgType, Command, bytes));
    }
}
