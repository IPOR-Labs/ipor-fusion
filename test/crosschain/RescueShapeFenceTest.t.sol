// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {EnforcedOptionParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppOptionsType3.sol";
import {EthereumVaultConnector} from "ethereum-vault-connector/src/EthereumVaultConnector.sol";
import {IEVC} from "ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";

import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {AuditToken} from "./CcipAuditRemediationTest.t.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";
import {MockLzEndpoint} from "./mocks/MockLzEndpoint.sol";
import {MockStargatePool, LzComposeBuilder} from "./mocks/MockStargatePool.sol";
import {MockRemoteVault, MockRemotePlasmaVault, MockWithdrawManager} from "./mocks/MockRemoteVault.sol";
import {MockRescueRequestManager} from "./mocks/MockRescueRequestManager.sol";
import {IRescueQueueHost} from "./interfaces/IRescueQueueHost.sol";
import {FactoryTestBase} from "./FactoryTestBase.sol";
import {MockEvcVault} from "./mocks/MockEvcVault.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";
import {DEFAULT_COMMAND_BUDGET} from "./CommandBudget.sol";
import {BusinessAction, CrosschainConstants} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {
    CrosschainMessages,
    Command,
    UpdateVaults,
    OutboundTransfer,
    SweepFloor
} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {IPlasmaVault} from "../../contracts/interfaces/IPlasmaVault.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {ContextManager} from "../../contracts/managers/context/ContextManager.sol";
import {StargateCrosschainDispatcher} from "../../contracts/crosschain/stargate/StargateCrosschainDispatcher.sol";
import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";

/// @title RescueShapeFenceBase
/// @notice IL-9654 (Olympix 2026-11-06 #5.2.23): a host that holds vault shares (a dispatcher) accepts a generic
///         rescue only in one of seven calldata shapes: empty calldata (value only), `transfer(address,uint256)`,
///         `approve(address,uint256)` with amount 0, `redeem(uint256,address,address)` and
///         `redeemFromRequest(uint256,address,address)` with the host as owner, `requestShares(uint256)` on a
///         manager whose vault is neither tracked nor allowlisted, and LayerZero packet hygiene on its own endpoint.
///         Everything else is refused at schedule with `RescueCallShapeNotAllowed`, whatever the target, so a vault
///         connector (Euler EVC), a lending sibling (IL-9672), a forwarder or the share token of a vault that is not
///         allowlisted yet (IL-8844) are refused. The fence checks the bytes of the call, not what the target does
///         with them.
/// @dev Each concrete suite deploys a dispatcher with NO vault allowlisted or tracked in the shape tests: the rule
///      depends on the host's code, not on the content of its tracked set. The `requestShares` rule is checked at
///      schedule and again at execute. Re-injection: removing `_requireAllowedRescueShape` from
///      `RescueLogicLib.schedule` fails every `testShouldReject...` test and the `RescueCallShapeNotAllowed` cases
///      here.
abstract contract RescueShapeFenceBase is Test {
    uint256 internal constant DELAY = 3 days;
    address internal constant RECEIVER = address(0xCAFE);
    address internal constant SPENDER = address(0xBAD);
    /// @dev Stand-ins for a vault connector (Euler EVC) and for a lending sibling of a vault (the paired silo of a
    ///      Silo v2 silo). They need no code: the fence reads the target and the calldata only, at schedule time.
    address internal constant CONNECTOR = address(0xE0C);
    address internal constant SIBLING = address(0x5110);
    address internal constant SOME_VAULT = address(0x4626);

    function _host() internal view virtual returns (address);

    function _rescueAdmin() internal view virtual returns (address);

    function _asset() internal view virtual returns (IERC20);

    function _mintAsset(address to_, uint256 amount_) internal virtual;

    /// @dev The host's LayerZero endpoint; `address(0)` on a host without one (CCIP).
    function _endpoint() internal view virtual returns (address);

    /// @dev Allowlisted plus tracked vaults of the host.
    function _vaultCount() internal view virtual returns (uint256);

    /// @dev Puts `vault_` into the host's ban set (the set the vault fence and the `requestShares` rule use): it is
    ///      allowlisted on the Stargate dispatcher, and allowlisted and tracked at once on the CCIP dispatcher.
    function _banVault(address vault_) internal virtual;

    function _schedule(address target_, uint256 value_, bytes memory callData_) internal returns (uint256 id) {
        vm.prank(_rescueAdmin());
        id = IRescueQueueHost(_host()).scheduleRescue(target_, value_, callData_);
    }

    function _execute(address target_, uint256 value_, bytes memory callData_) internal {
        uint256 id = _schedule(target_, value_, callData_);
        vm.warp(block.timestamp + DELAY);
        vm.prank(_rescueAdmin());
        IRescueQueueHost(_host()).executeRescue(id, callData_);
    }

    function _expectRejected(address target_, bytes memory callData_) internal {
        bytes4 selector = callData_.length < 4 ? bytes4(0) : bytes4(callData_);
        _expectRejectedWith(
            target_,
            callData_,
            abi.encodeWithSelector(CrosschainErrors.RescueCallShapeNotAllowed.selector, target_, selector)
        );
    }

    /// @dev Schedule must revert with exactly `revertData_` and queue nothing.
    function _expectRejectedWith(address target_, bytes memory callData_, bytes memory revertData_) internal {
        uint256 countBefore = IRescueQueueHost(_host()).rescueCount();
        vm.prank(_rescueAdmin());
        vm.expectRevert(revertData_);
        IRescueQueueHost(_host()).scheduleRescue(target_, 0, callData_);
        assertEq(IRescueQueueHost(_host()).rescueCount(), countBefore, "nothing queued");
    }

    /// @dev Execute (after the timelock) must revert with exactly `revertData_`; the record stays scheduled.
    function _expectExecuteReverts(uint256 id_, bytes memory callData_, bytes memory revertData_) internal {
        uint256 pendingBefore = IRescueQueueHost(_host()).pendingRescueCount();
        vm.warp(block.timestamp + DELAY);
        vm.prank(_rescueAdmin());
        vm.expectRevert(revertData_);
        IRescueQueueHost(_host()).executeRescue(id_, callData_);
        assertEq(IRescueQueueHost(_host()).pendingRescueCount(), pendingBefore, "the record stays scheduled");
    }

    function _requestSharesCall(uint256 shares_) internal pure returns (bytes memory) {
        return abi.encodeCall(WithdrawManager.requestShares, (shares_));
    }

    function _shapeError(address target_, bytes4 selector_) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(CrosschainErrors.RescueCallShapeNotAllowed.selector, target_, selector_);
    }

    function _trackedVaultError(address vault_) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(CrosschainErrors.RescueTrackedVaultCall.selector, vault_);
    }

    /// @dev A PlasmaVault-like vault outside both sets, wired to a manager, with `shares_` shares held by the host.
    function _residualPosition(uint256 shares_) internal returns (MockRemotePlasmaVault vault, MockWithdrawManager wm) {
        vault = new MockRemotePlasmaVault(_asset(), "Vault", "VLT");
        wm = new MockWithdrawManager(address(vault));
        vault.setWithdrawManager(address(wm));
        _mintAsset(address(this), shares_);
        _asset().approve(address(vault), shares_);
        vault.deposit(shares_, _host());
    }

    // ------------------------------------------------------------------ allowed shapes

    /// @notice Empty calldata is value only; on a contract target it would run that contract's `receive` or
    ///         `fallback` with the host as `msg.sender`, which the fence does not judge.
    function testShouldAcceptEmptyCalldataWithValue() public {
        vm.deal(_host(), 1 ether);
        _execute(RECEIVER, 1 ether, "");
        assertEq(RECEIVER.balance, 1 ether, "value forwarded");
    }

    function testShouldAcceptTokenTransfer() public {
        MockERC20 other = new MockERC20("Other", "OTH", 6);
        other.mint(_host(), 5e6);
        _execute(address(other), 0, abi.encodeCall(IERC20.transfer, (RECEIVER, 5e6)));
        assertEq(other.balanceOf(RECEIVER), 5e6, "foreign token recovered");
    }

    function testShouldAcceptAllowanceRevoke() public {
        MockERC20 other = new MockERC20("Other", "OTH", 6);
        vm.prank(_host());
        other.approve(SPENDER, type(uint256).max);
        _execute(address(other), 0, abi.encodeCall(IERC20.approve, (SPENDER, 0)));
        assertEq(other.allowance(_host(), SPENDER), 0, "allowance removed");
    }

    /// @notice The shares of a vault that is neither allowlisted nor tracked (a residual after a removal) are
    ///         recovered by `redeem` with the host as owner. A PlasmaVault restricts share transfers by default,
    ///         so `transfer` alone would not cover this.
    function testShouldAcceptRedeemOfOwnSharesOnAVaultOutsideTheAllowlist() public {
        MockRemoteVault vault = new MockRemoteVault(_asset(), "Vault", "VLT");
        _mintAsset(address(this), 10);
        _asset().approve(address(vault), 10);
        vault.deposit(10, _host());
        uint256 hostAssetBefore = _asset().balanceOf(_host());

        _execute(address(vault), 0, abi.encodeCall(IERC4626.redeem, (10, RECEIVER, _host())));
        assertEq(vault.balanceOf(_host()), 0, "shares redeemed");
        assertEq(_asset().balanceOf(RECEIVER), 10, "the receiver is paid");
        assertEq(_asset().balanceOf(_host()), hostAssetBefore, "the host's own ASSET balance is untouched");
    }

    /// @notice LayerZero packet hygiene (`skip`, `clear`, `nilify`, `burn`) stays available on the host's own
    ///         endpoint, end to end, and nowhere else.
    function testShouldAcceptPacketHygieneOnTheEndpointOnly() public {
        address host = _host();
        bytes[] memory hygiene = new bytes[](4);
        hygiene[0] = abi.encodeWithSignature("skip(address,uint32,bytes32,uint64)", host, 30101, bytes32(0), 1);
        hygiene[1] = abi.encodeWithSignature(
            "clear(address,(uint32,bytes32,uint64),bytes32,bytes)",
            host,
            uint32(30101),
            bytes32(0),
            uint64(1),
            bytes32(0),
            ""
        );
        hygiene[2] = abi.encodeWithSignature(
            "nilify(address,uint32,bytes32,uint64,bytes32)",
            host,
            30101,
            bytes32(0),
            1,
            bytes32(0)
        );
        hygiene[3] = abi.encodeWithSignature(
            "burn(address,uint32,bytes32,uint64,bytes32)",
            host,
            30101,
            bytes32(0),
            1,
            bytes32(0)
        );
        assertEq(bytes4(hygiene[0]), bytes4(0xd70b8902), "skip selector pinned");
        assertEq(bytes4(hygiene[1]), bytes4(0x2a56c1b0), "clear selector pinned");
        assertEq(bytes4(hygiene[2]), bytes4(0x2e80fbf3), "nilify selector pinned");
        assertEq(bytes4(hygiene[3]), bytes4(0x40f80683), "burn selector pinned");

        for (uint256 i; i < hygiene.length; ++i) {
            if (_endpoint() != address(0)) _execute(_endpoint(), 0, hygiene[i]);
            _expectRejected(CONNECTOR, hygiene[i]);
            _expectRejected(address(0), hygiene[i]);
        }
    }

    // ------------------------------------------------------------------ rejected shapes

    /// @notice The calls of the finding and of its siblings: each is outside the seven shapes, whatever the target
    ///         does with it (a vault connector, a lending sibling, a share token that is not allowlisted).
    function testShouldRejectCallsThatGrantARight() public {
        assertEq(_vaultCount(), 0, "no vault allowlisted or tracked: the rule does not depend on the set");
        address host = _host();
        address admin = _rescueAdmin();
        bytes memory approveMax = abi.encodeCall(IERC20.approve, (admin, type(uint256).max));

        // Euler EVC (IL-9654): operator, relayed approve, collateral and controller.
        _expectRejected(CONNECTOR, abi.encodeCall(IEVC.setAccountOperator, (host, admin, true)));
        _expectRejected(CONNECTOR, abi.encodeCall(IEVC.setOperator, (bytes19(uint152(uint160(host) >> 8)), admin, 1)));
        _expectRejected(CONNECTOR, abi.encodeCall(IEVC.call, (SOME_VAULT, host, 0, approveMax)));
        _expectRejected(CONNECTOR, abi.encodeCall(IEVC.batch, (new IEVC.BatchItem[](0))));
        _expectRejected(CONNECTOR, abi.encodeCall(IEVC.enableCollateral, (host, SOME_VAULT)));
        _expectRejected(CONNECTOR, abi.encodeCall(IEVC.enableController, (host, SIBLING)));
        // Lending sibling (IL-9672): borrow against the host's shares with the host as `msg.sender`.
        _expectRejected(SIBLING, abi.encodeWithSignature("borrow(uint256,address,address)", 1e6, admin, host));
        // Share token of a vault that is not allowlisted yet (IL-8844), and the other grant families.
        _expectRejected(SOME_VAULT, approveMax);
        _expectRejected(SOME_VAULT, abi.encodeWithSignature("increaseAllowance(address,uint256)", admin, 1));
        _expectRejected(SOME_VAULT, abi.encodeWithSignature("setApprovalForAll(address,bool)", admin, true));
        _expectRejected(SOME_VAULT, abi.encodeWithSignature("setAuthorization(address,bool)", admin, true));
        _expectRejected(SOME_VAULT, abi.encodeWithSignature("approveDelegation(address,uint256)", admin, 1e6));
        _expectRejected(SOME_VAULT, abi.encodeWithSignature("allow(address,bool)", admin, true));
        _expectRejected(
            SOME_VAULT,
            abi.encodeWithSignature(
                "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)",
                host,
                admin,
                type(uint256).max,
                type(uint256).max,
                uint8(27),
                bytes32(0),
                bytes32(0)
            )
        );
        // Calls that move value through someone else's right, or that are not a recovery.
        _expectRejected(SOME_VAULT, abi.encodeCall(IERC20.transferFrom, (host, admin, 1)));
        _expectRejected(SOME_VAULT, abi.encodeCall(IERC4626.withdraw, (1, admin, host)));
        _expectRejected(SOME_VAULT, abi.encodeCall(IERC4626.deposit, (1, host)));
    }

    /// @notice An allowed selector with another length or argument is not an allowed shape.
    function testShouldRejectAllowedSelectorsWithAnotherLengthOrArgument() public {
        address host = _host();
        bytes memory transfer = abi.encodeCall(IERC20.transfer, (RECEIVER, 1));
        bytes memory revoke = abi.encodeCall(IERC20.approve, (SPENDER, 0));
        bytes memory redeem = abi.encodeCall(IERC4626.redeem, (1, RECEIVER, host));

        _expectRejected(SOME_VAULT, bytes.concat(transfer, bytes32(0)));
        _expectRejected(SOME_VAULT, bytes.concat(revoke, bytes32(0)));
        _expectRejected(SOME_VAULT, bytes.concat(redeem, bytes32(0)));
        _expectRejected(SOME_VAULT, bytes.concat(transfer, bytes1(0)));
        _expectRejected(SOME_VAULT, abi.encodePacked(IERC20.transfer.selector, bytes32(uint256(uint160(RECEIVER)))));
        _expectRejected(SOME_VAULT, abi.encodeCall(IERC20.approve, (SPENDER, 1)));
        // `redeem` of somebody else's shares (it would spend an allowance given to the host).
        _expectRejected(SOME_VAULT, abi.encodeCall(IERC4626.redeem, (1, RECEIVER, SPENDER)));
        // A dirty upper part of the owner word is not the host's address.
        _expectRejected(
            SOME_VAULT,
            abi.encodePacked(
                IERC4626.redeem.selector,
                uint256(1),
                uint256(uint160(RECEIVER)),
                (uint256(1) << 160) | uint256(uint160(host))
            )
        );
    }

    function testShouldRejectCalldataShorterThanASelector() public {
        _expectRejected(CONNECTOR, hex"a9");
        _expectRejected(CONNECTOR, hex"a905");
        _expectRejected(CONNECTOR, hex"a9059c");
    }

    function testFuzzShouldRejectEverySelectorOutsideTheList(bytes4 selector_, bytes memory args_) public {
        vm.assume(selector_ != IERC20.transfer.selector);
        vm.assume(selector_ != IERC20.approve.selector);
        vm.assume(selector_ != IERC4626.redeem.selector);
        vm.assume(selector_ != IPlasmaVault.redeemFromRequest.selector);
        vm.assume(selector_ != WithdrawManager.requestShares.selector);
        // LayerZero hygiene selectors: refused on every target but the host's own endpoint, checked by the next fuzz.
        vm.assume(selector_ != bytes4(0xd70b8902) && selector_ != bytes4(0x2a56c1b0));
        vm.assume(selector_ != bytes4(0x2e80fbf3) && selector_ != bytes4(0x40f80683));
        // The ContextManager selector has its own, earlier fence (IL-8770).
        vm.assume(selector_ != ContextManager.runWithContext.selector);
        _expectRejected(CONNECTOR, abi.encodePacked(selector_, args_));
    }

    function testFuzzShouldRejectApproveAboveZero(address spender_, uint256 amount_) public {
        vm.assume(amount_ != 0);
        _expectRejected(SOME_VAULT, abi.encodeCall(IERC20.approve, (spender_, amount_)));
    }

    /// @notice Every selector of the list, with a length other than the one its shape allows, is refused. The
    ///         LayerZero selectors are refused with any length on a target that is not the host's endpoint.
    function testFuzzShouldRejectListedSelectorsWithOtherLengths(uint256 which_, uint256 extra_) public {
        which_ = bound(which_, 0, 8);
        extra_ = bound(extra_, 0, 200);
        bytes4[9] memory selectors = [
            IERC20.transfer.selector,
            IERC20.approve.selector,
            IERC4626.redeem.selector,
            IPlasmaVault.redeemFromRequest.selector,
            WithdrawManager.requestShares.selector,
            bytes4(0xd70b8902),
            bytes4(0x2a56c1b0),
            bytes4(0x2e80fbf3),
            bytes4(0x40f80683)
        ];
        uint256 allowedLength = which_ < 2 ? 68 : (which_ < 4 ? 100 : (which_ == 4 ? 36 : type(uint256).max));
        vm.assume(extra_ + 4 != allowedLength);
        _expectRejected(SOME_VAULT, abi.encodePacked(selectors[which_], new bytes(extra_)));
    }

    // ------------------------------------------------------------------ empty sets, approve amount

    /// @notice The rule does not depend on the content of the host's vault sets: with both sets empty a call outside
    ///         the list is refused and the listed shapes pass.
    function testShouldApplyTheFenceWithEmptyVaultSets() public {
        assertEq(_vaultCount(), 0, "no vault allowlisted or tracked");
        _expectRejected(CONNECTOR, abi.encodeCall(IEVC.setAccountOperator, (_host(), SPENDER, true)));
        _execute(RECEIVER, 0, "");
        assertEq(IRescueQueueHost(_host()).pendingRescueCount(), 0, "the listed shape ran");
    }

    function testShouldRejectApproveWithNonZeroAmount() public {
        _expectRejected(SOME_VAULT, abi.encodeCall(IERC20.approve, (SPENDER, 1)));
        _expectRejected(SOME_VAULT, abi.encodeCall(IERC20.approve, (SPENDER, type(uint256).max)));
        _expectRejected(SOME_VAULT, abi.encodeCall(IERC20.approve, (address(0), 1)));
    }

    // ------------------------------------------------------------------ redeemFromRequest and redeem shapes

    /// @notice Residual shares of a vault outside both sets: `redeemFromRequest` with the host as owner.
    function testShouldAcceptRedeemFromRequestOfOwnSharesOnAVaultOutsideTheSets() public {
        (MockRemotePlasmaVault vault, MockWithdrawManager wm) = _residualPosition(10);
        vm.prank(_host());
        wm.requestShares(10);
        uint256 hostAssetBefore = _asset().balanceOf(_host());

        _execute(address(vault), 0, abi.encodeCall(IPlasmaVault.redeemFromRequest, (10, RECEIVER, _host())));
        assertEq(vault.balanceOf(_host()), 0, "shares redeemed from the request");
        assertEq(_asset().balanceOf(RECEIVER), 10, "the receiver is paid");
        assertEq(_asset().balanceOf(_host()), hostAssetBefore, "the host's own ASSET balance is untouched");
        assertEq(wm.requestedShares(_host()), 0, "the request was consumed");
    }

    function testShouldRejectRedeemFromRequestWithAnotherOwnerOrADirtyOwnerWord() public {
        address host = _host();
        _expectRejected(SOME_VAULT, abi.encodeCall(IPlasmaVault.redeemFromRequest, (1, RECEIVER, SPENDER)));
        _expectRejected(SOME_VAULT, abi.encodeCall(IPlasmaVault.redeemFromRequest, (1, RECEIVER, address(0))));
        _expectRejected(
            SOME_VAULT,
            abi.encodePacked(
                IPlasmaVault.redeemFromRequest.selector,
                uint256(1),
                uint256(uint160(RECEIVER)),
                (uint256(1) << 160) | uint256(uint160(host))
            )
        );
        // The host in the receiver word does not make it the owner.
        _expectRejected(SOME_VAULT, abi.encodeCall(IPlasmaVault.redeemFromRequest, (1, host, SPENDER)));
    }

    function testShouldRejectRedeemAndRedeemFromRequestWithAnotherLength() public {
        bytes[2] memory valid = [
            abi.encodeCall(IPlasmaVault.redeemFromRequest, (1, RECEIVER, _host())),
            abi.encodeCall(IERC4626.redeem, (1, RECEIVER, _host()))
        ];
        for (uint256 i; i < valid.length; ++i) {
            bytes memory cd = valid[i];
            assertEq(cd.length, 100, "the valid shape is 100 bytes");
            _expectRejected(SOME_VAULT, _prefix(cd, 99));
            _expectRejected(SOME_VAULT, bytes.concat(cd, bytes1(0)));
            _expectRejected(SOME_VAULT, bytes.concat(cd, bytes32(0)));
        }
    }

    function _prefix(bytes memory data_, uint256 length_) internal pure returns (bytes memory out) {
        out = new bytes(length_);
        for (uint256 i; i < length_; ++i) {
            out[i] = data_[i];
        }
    }

    // ------------------------------------------------------------------ requestShares shape

    /// @notice A request on a manager of a vault outside both sets passes.
    function testShouldAcceptRequestSharesOnAManagerOfAVaultOutsideTheSets() public {
        (MockRemotePlasmaVault vault, MockWithdrawManager wm) = _residualPosition(10);

        _execute(address(wm), 0, _requestSharesCall(10));
        assertEq(wm.requestedShares(_host()), 10, "request recorded for the host");
        assertEq(vault.balanceOf(_host()), 10, "no fee: the host keeps its shares");
    }

    /// @notice The manager's fee is not bounded on this path: it is taken from the host's shares.
    function testShouldAcceptRequestSharesWhenTheManagerChargesAFee() public {
        (MockRemotePlasmaVault vault, MockWithdrawManager wm) = _residualPosition(10);
        wm.setFeeShares(2);

        _execute(address(wm), 0, _requestSharesCall(10));
        assertEq(wm.requestedShares(_host()), 10, "request recorded");
        assertEq(vault.balanceOf(address(wm)), 2, "the manager took its fee from the host's shares");
        assertEq(vault.balanceOf(_host()), 8, "the host paid the fee");
    }

    /// @notice A fee raised during the timelock is paid at execute, without a revert.
    function testShouldPayAFeeRaisedDuringTheTimelockWithoutARevert() public {
        (MockRemotePlasmaVault vault, MockWithdrawManager wm) = _residualPosition(10);
        wm.setFeeShares(1);
        bytes memory cd = _requestSharesCall(10);
        uint256 id = _schedule(address(wm), 0, cd);

        wm.setFeeShares(10);
        vm.warp(block.timestamp + DELAY);
        vm.prank(_rescueAdmin());
        IRescueQueueHost(_host()).executeRescue(id, cd);
        assertEq(vault.balanceOf(address(wm)), 10, "the raised fee took the whole position");
        assertEq(vault.balanceOf(_host()), 0, "nothing left on the host");
    }

    /// @notice The last-resort recovery: both steps scheduled together, executed in order.
    function testShouldRecoverResidualSharesThroughRequestSharesThenRedeemFromRequest() public {
        (MockRemotePlasmaVault vault, MockWithdrawManager wm) = _residualPosition(10);
        bytes memory requestCall = _requestSharesCall(10);
        bytes memory redeemCall = abi.encodeCall(IPlasmaVault.redeemFromRequest, (10, RECEIVER, _host()));
        uint256 requestId = _schedule(address(wm), 0, requestCall);
        uint256 redeemId = _schedule(address(vault), 0, redeemCall);

        vm.warp(block.timestamp + DELAY);
        vm.startPrank(_rescueAdmin());
        IRescueQueueHost(_host()).executeRescue(requestId, requestCall);
        IRescueQueueHost(_host()).executeRescue(redeemId, redeemCall);
        vm.stopPrank();
        assertEq(vault.balanceOf(_host()), 0, "the residual is gone");
        assertEq(_asset().balanceOf(RECEIVER), 10, "the receiver is paid");
    }

    function testShouldRejectRequestSharesWithAnotherLength() public {
        MockRescueRequestManager manager = new MockRescueRequestManager(SOME_VAULT);
        bytes memory valid = _requestSharesCall(1);
        assertEq(valid.length, 36, "the valid shape is 36 bytes");
        _expectRejected(address(manager), _prefix(valid, 35));
        _expectRejected(address(manager), bytes.concat(valid, bytes1(0)));
        _expectRejected(address(manager), bytes.concat(valid, bytes32(0)));
    }

    /// @notice The target must answer `getPlasmaVaultAddress()` with exactly one word holding a non-zero address.
    function testShouldRejectRequestSharesOnATargetThatDoesNotAnswerWithOneVaultWord() public {
        bytes memory cd = _requestSharesCall(1);
        bytes4 selector = WithdrawManager.requestShares.selector;

        // No code: the staticcall succeeds with empty returndata.
        _expectRejectedWith(CONNECTOR, cd, _shapeError(CONNECTOR, selector));

        MockRescueRequestManager manager = new MockRescueRequestManager(SOME_VAULT);
        address m = address(manager);
        manager.setMode(MockRescueRequestManager.Mode.Revert);
        _expectRejectedWith(m, cd, _shapeError(m, selector));
        manager.setMode(MockRescueRequestManager.Mode.Empty);
        _expectRejectedWith(m, cd, _shapeError(m, selector));
        manager.setMode(MockRescueRequestManager.Mode.TwoWords);
        _expectRejectedWith(m, cd, _shapeError(m, selector));
        manager.setMode(MockRescueRequestManager.Mode.DirtyUpperBits);
        _expectRejectedWith(m, cd, _shapeError(m, selector));
        manager.setMode(MockRescueRequestManager.Mode.Normal);
        manager.setVault(address(0));
        _expectRejectedWith(m, cd, _shapeError(m, selector));

        // Control: the same manager with a vault outside both sets passes.
        manager.setVault(SOME_VAULT);
        _schedule(m, 0, cd);
    }

    /// @notice A manager whose vault is in the ban set is refused with the vault's address, whichever set holds it.
    function testShouldRejectRequestSharesOnAManagerOfABannedVault() public {
        MockRemoteVault vault = new MockRemoteVault(_asset(), "Vault", "VLT");
        MockRescueRequestManager manager = new MockRescueRequestManager(address(vault));
        _banVault(address(vault));
        _expectRejectedWith(address(manager), _requestSharesCall(1), _trackedVaultError(address(vault)));
    }

    /// @notice The manager's vault is read at execute too: a vault added to the sets during the timelock refuses it.
    function testShouldRefuseRequestSharesAtExecuteWhenTheVaultIsAddedDuringTheTimelock() public {
        MockRemoteVault vault = new MockRemoteVault(_asset(), "Vault", "VLT");
        MockRescueRequestManager manager = new MockRescueRequestManager(address(vault));
        bytes memory cd = _requestSharesCall(1);
        uint256 id = _schedule(address(manager), 0, cd);

        _banVault(address(vault));
        _expectExecuteReverts(id, cd, _trackedVaultError(address(vault)));
        assertEq(manager.requestCount(), 0, "the manager was not called");
    }

    /// @notice A manager that stops answering with a vault during the timelock is refused at execute.
    function testShouldRefuseRequestSharesAtExecuteWhenTheManagerStopsAnswering() public {
        MockRescueRequestManager manager = new MockRescueRequestManager(SOME_VAULT);
        bytes memory cd = _requestSharesCall(1);
        bytes4 selector = WithdrawManager.requestShares.selector;
        address m = address(manager);

        uint256 zeroId = _schedule(m, 0, cd);
        manager.setVault(address(0));
        _expectExecuteReverts(zeroId, cd, _shapeError(m, selector));

        manager.setVault(SOME_VAULT);
        uint256 revertId = _schedule(m, 0, cd);
        manager.setMode(MockRescueRequestManager.Mode.Revert);
        _expectExecuteReverts(revertId, cd, _shapeError(m, selector));
        assertEq(manager.requestCount(), 0, "the manager was never called");
    }

    /// @notice A vault added to the sets during the timelock refuses `redeem` and `redeemFromRequest` at execute.
    function testShouldRefuseRedeemShapesAtExecuteWhenTheVaultIsAddedDuringTheTimelock() public {
        MockRemoteVault vault = new MockRemoteVault(_asset(), "Vault", "VLT");
        bytes memory redeemCall = abi.encodeCall(IERC4626.redeem, (1, RECEIVER, _host()));
        bytes memory fromRequestCall = abi.encodeCall(IPlasmaVault.redeemFromRequest, (1, RECEIVER, _host()));
        uint256 redeemId = _schedule(address(vault), 0, redeemCall);
        uint256 fromRequestId = _schedule(address(vault), 0, fromRequestCall);

        _banVault(address(vault));
        _expectExecuteReverts(redeemId, redeemCall, _trackedVaultError(address(vault)));
        _expectExecuteReverts(fromRequestId, fromRequestCall, _trackedVaultError(address(vault)));
    }

    // ------------------------------------------------------------------ order of the fences

    /// @notice The earlier fences keep their order and their errors: the vault ban comes before the shape rule, the
    ///         protected-token fence before the shape fence, and the context fence before both.
    function testShouldKeepTheOrderOfTheEarlierFences() public {
        MockRemoteVault vault = new MockRemoteVault(_asset(), "Vault", "VLT");
        _banVault(address(vault));
        // A `requestShares`-shaped call on a banned vault: the vault ban, not the shape rule.
        _expectRejectedWith(address(vault), _requestSharesCall(1), _trackedVaultError(address(vault)));

        // `approve(spender, 0)` is a listed shape, yet on the ASSET only `transfer` is allowed.
        address asset = address(_asset());
        _expectRejectedWith(
            asset,
            abi.encodeCall(IERC20.approve, (SPENDER, 0)),
            abi.encodeWithSelector(CrosschainErrors.RescueProtectedTokenCall.selector, asset, IERC20.approve.selector)
        );

        _expectRejectedWith(
            CONNECTOR,
            abi.encodeWithSelector(ContextManager.runWithContext.selector),
            abi.encodeWithSelector(CrosschainErrors.RescueContextCall.selector, CONNECTOR)
        );
    }

    // ------------------------------------------------------------------ selector pins

    /// @notice The selectors of the new shapes are the real ones. The library constants are private; the accepted-shape
    ///         tests above build their calldata from these interface selectors, so a wrong constant in the library
    ///         fails them.
    function testShouldPinTheSelectorsOfTheShapes() public pure {
        assertEq(IPlasmaVault.redeemFromRequest.selector, bytes4(0xa64099d2), "redeemFromRequest");
        assertEq(WithdrawManager.requestShares.selector, bytes4(0xfc415e9c), "requestShares");
        assertEq(WithdrawManager.getPlasmaVaultAddress.selector, bytes4(0x0bdcc726), "getPlasmaVaultAddress");
        assertEq(IERC4626.redeem.selector, bytes4(0xba087652), "redeem");
        assertEq(IERC20.approve.selector, bytes4(0x095ea7b3), "approve");
        assertEq(IERC20.transfer.selector, bytes4(0xa9059cbb), "transfer");
    }
}

/// @dev Deploys a Stargate dispatcher from its compiled artifact (the test contract stays under the create limit).
abstract contract StargateDispatcherFixture is Test {
    using OptionsBuilder for bytes;

    function _deployStargateDispatcher(
        address endpoint_,
        address asset_,
        address pool_,
        address admin_,
        uint32 executorEid_
    ) internal returns (StargateCrosschainDispatcher) {
        EnforcedOptionParam[] memory enforced = new EnforcedOptionParam[](2);
        enforced[0] = EnforcedOptionParam({
            eid: executorEid_,
            msgType: 1,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(2_000_000, 0)
        });
        enforced[1] = EnforcedOptionParam({
            eid: executorEid_,
            msgType: 2,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(250_000, 0).addExecutorLzComposeOption(
                0,
                1_500_000,
                0
            )
        });
        bytes memory args = abi.encode(
            endpoint_,
            asset_,
            pool_,
            keccak256("USDC"),
            address(0xF),
            admin_,
            address(0x6A6A6A),
            uint256(3 days),
            uint256(1),
            executorEid_,
            abi.encode(enforced)
        );
        return
            StargateCrosschainDispatcher(
                payable(vm.deployCode("StargateCrosschainDispatcher.sol:StargateCrosschainDispatcher", args))
            );
    }
}

/// @notice Stargate dispatcher host (it exposes `getTrackedVaults()`).
contract StargateDispatcherRescueShapeFenceTest is StargateDispatcherFixture, RescueShapeFenceBase {
    uint32 internal constant EXECUTOR_EID = 30101;
    address internal constant ADMIN = address(0xADADAD);

    MockLzEndpoint internal endpoint;
    MockERC20 internal usdc;
    MockStargatePool internal usdcPool;
    StargateCrosschainDispatcher internal dispatcher;
    uint256 internal guidNonce;

    function setUp() public {
        vm.chainId(42161);
        vm.warp(365 days);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdcPool = new MockStargatePool(address(usdc), 6);
        endpoint = new MockLzEndpoint();
        dispatcher = _deployStargateDispatcher(
            address(endpoint),
            address(usdc),
            address(usdcPool),
            ADMIN,
            EXECUTOR_EID
        );
        // UPDATE_VAULTS and commands answer through the endpoint and need a native budget.
        vm.deal(address(dispatcher), 100 ether);
    }

    function _host() internal view override returns (address) {
        return address(dispatcher);
    }

    function _rescueAdmin() internal pure override returns (address) {
        return ADMIN;
    }

    function _asset() internal view override returns (IERC20) {
        return IERC20(address(usdc));
    }

    function _mintAsset(address to_, uint256 amount_) internal override {
        usdc.mint(to_, amount_);
    }

    function _endpoint() internal view override returns (address) {
        return address(endpoint);
    }

    function _vaultCount() internal view override returns (uint256) {
        return dispatcher.getTrackedVaults().length + dispatcher.getAllowedVaults().length;
    }

    /// @dev Allowlists `vault_` next to the vaults already allowlisted (an UPDATE_VAULTS replacement list).
    function _banVault(address vault_) internal override {
        address[] memory current = dispatcher.getAllowedVaults();
        address[] memory vaults = new address[](current.length + 1);
        for (uint256 i; i < current.length; ++i) {
            vaults[i] = current[i];
        }
        vaults[current.length] = vault_;
        _deliverLz(
            CrosschainMessages.encodeUpdateVaults(
                UpdateVaults({
                    commandId: keccak256(abi.encode("uv", ++guidNonce)),
                    sequence: dispatcher.nextCommandSequence(),
                    newConfigEpoch: dispatcher.commandConfigEpoch() + 1,
                    minExecutionGas: DEFAULT_COMMAND_BUDGET,
                    vaults: vaults,
                    floors: new SweepFloor[](0)
                })
            )
        );
        assertTrue(dispatcher.isAllowedVault(vault_), "vault allowlisted");
    }

    function _deliverLz(bytes memory envelope_) internal {
        endpoint.deliverLz(
            address(dispatcher),
            EXECUTOR_EID,
            bytes32(uint256(uint160(address(dispatcher)))),
            keccak256(abi.encode("guid", ++guidNonce)),
            envelope_
        );
    }

    /// @notice A vault the dispatcher really tracks (shares held after a DEPOSIT) refuses a `requestShares` on its
    ///         manager as well.
    function testShouldRejectRequestSharesOnAManagerOfATrackedVault() public {
        MockRemoteVault vault = new MockRemoteVault(usdc, "Vault", "VLT");
        _banVault(address(vault));
        usdc.mint(address(dispatcher), 100e6);
        endpoint.deliverCompose(
            address(dispatcher),
            address(usdcPool),
            keccak256(abi.encode("guid", ++guidNonce)),
            LzComposeBuilder.build(
                address(dispatcher),
                EXECUTOR_EID,
                100e6,
                CrosschainMessages.encodeOutboundTransfer(OutboundTransfer({transferId: keccak256("t1")}))
            )
        );
        _deliverLz(
            CrosschainMessages.encodeCommand(
                Command({
                    commandId: keccak256("dep"),
                    sequence: dispatcher.nextCommandSequence(),
                    commandConfigEpoch: dispatcher.commandConfigEpoch(),
                    action: uint8(BusinessAction.DEPOSIT),
                    minExecutionGas: DEFAULT_COMMAND_BUDGET,
                    actionData: CrosschainMessages.encodeDepositAction(address(vault), 50e6, 0)
                })
            )
        );
        assertTrue(dispatcher.isTrackedVault(address(vault)), "vault tracked");

        MockRescueRequestManager manager = new MockRescueRequestManager(address(vault));
        _expectRejectedWith(address(manager), _requestSharesCall(1), _trackedVaultError(address(vault)));
    }

    /// @notice An allowlisted vault that holds no shares yet is in the ban set already: its manager is refused. A rule
    ///         that looked at the tracked set alone would let this through.
    function testShouldRejectRequestSharesOnAManagerOfAnAllowlistedVaultThatIsNotTrackedYet() public {
        MockRemoteVault vault = new MockRemoteVault(usdc, "Vault", "VLT");
        _banVault(address(vault));
        assertFalse(dispatcher.isTrackedVault(address(vault)), "not tracked");
        MockRescueRequestManager manager = new MockRescueRequestManager(address(vault));
        _expectRejectedWith(address(manager), _requestSharesCall(1), _trackedVaultError(address(vault)));
    }
}

/// @dev CCIP executor and dispatcher pair, no vault allowlisted, wired through a router mock so the executor's
///      `updateVaults` reaches the dispatcher (it allowlists and tracks vaults there).
abstract contract CcipRescueShapeSetup is Test {
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;
    address internal constant CCIP_ADMIN = address(0xA11);

    MockCcipRouter internal router;
    AuditToken internal token;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;

    function _deployPair() internal {
        router = new MockCcipRouter();
        token = new AuditToken(18);
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
                rescueAdmin: CCIP_ADMIN,
                rescueGuardian: address(0xB22),
                balanceProposer: address(this),
                balanceApprover: address(0xA33),
                rescueDelay: 3 days,
                balanceStalenessMax: 7 days,
                bigChangeBps: 2_000,
                anchorBandBps: 2_000,
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
            CCIP_ADMIN,
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
    }
}

/// @notice CCIP dispatcher host (it exposes `trackedVaultsLength()`, not `getTrackedVaults()`).
contract CcipDispatcherRescueShapeFenceTest is CcipRescueShapeSetup, RescueShapeFenceBase {
    function setUp() public {
        _deployPair();
    }

    function _host() internal view override returns (address) {
        return address(dispatcher);
    }

    function _rescueAdmin() internal pure override returns (address) {
        return CCIP_ADMIN;
    }

    function _asset() internal view override returns (IERC20) {
        return IERC20(address(token));
    }

    function _mintAsset(address to_, uint256 amount_) internal override {
        token.mint(to_, amount_);
    }

    function _endpoint() internal pure override returns (address) {
        return address(0);
    }

    function _vaultCount() internal view override returns (uint256) {
        return dispatcher.trackedVaultsLength();
    }

    /// @dev On the CCIP dispatcher a vault added to the allowlist is tracked at once, so this bans it.
    function _banVault(address vault_) internal override {
        address[] memory vaults = new address[](1);
        vaults[0] = vault_;
        executor.updateVaults(REMOTE_CHAIN, vaults, true, false, 0, address(0), 2_000_000);
        assertTrue(dispatcher.isAllowedVault(vault_), "vault allowlisted");
        assertEq(dispatcher.trackedVaultsLength(), 1, "vault tracked");
    }
}

/// @notice The shape fence is scoped to hosts that hold vault shares. An executor exposes no tracked-vault set, so its
///         generic rescue keeps every shape the earlier fences allow, and the `requestShares` checks at execute are
///         skipped too.
contract StargateExecutorRescueShapeScopeTest is CrosschainTestBase {
    function setUp() public {
        _baseSetUp();
    }

    function testShouldNotRestrictCallShapesOnTheStargateExecutor() public {
        bytes memory cd = abi.encodeCall(IEVC.setAccountOperator, (address(executor), admin, true));
        vm.prank(admin);
        uint256 id = executor.scheduleRescue(address(0xE0C), 0, cd);
        assertEq(id, executor.rescueCount(), "scheduled");
    }

    function testShouldScheduleAndExecuteRequestSharesOnATargetWithoutCodeOnTheStargateExecutor() public {
        bytes memory cd = abi.encodeCall(WithdrawManager.requestShares, (1));
        vm.startPrank(admin);
        uint256 id = executor.scheduleRescue(address(0xE0C), 0, cd);
        vm.warp(block.timestamp + RESCUE_DELAY);
        executor.executeRescue(id, cd);
        vm.stopPrank();
        assertEq(executor.pendingRescueCount(), 0, "executed");
    }
}

contract CcipExecutorRescueShapeScopeTest is CcipRescueShapeSetup {
    function setUp() public {
        _deployPair();
    }

    function testShouldNotRestrictCallShapesOnTheCcipExecutor() public {
        bytes memory cd = abi.encodeCall(IEVC.setAccountOperator, (address(executor), CCIP_ADMIN, true));
        vm.prank(CCIP_ADMIN);
        uint256 id = executor.scheduleRescue(address(0xE0C), 0, cd);
        assertEq(id, executor.rescueCount(), "scheduled");
    }

    function testShouldScheduleAndExecuteRequestSharesOnATargetWithoutCodeOnTheCcipExecutor() public {
        bytes memory cd = abi.encodeCall(WithdrawManager.requestShares, (1));
        vm.startPrank(CCIP_ADMIN);
        uint256 id = executor.scheduleRescue(address(0xE0C), 0, cd);
        vm.warp(block.timestamp + 3 days);
        executor.executeRescue(id, cd);
        vm.stopPrank();
        assertEq(executor.pendingRescueCount(), 0, "executed");
    }
}

/// @notice The Stargate factory hosts the same rescue module and has no tracked-vault set: no shape is refused.
contract StargateFactoryRescueShapeScopeTest is FactoryTestBase {
    function setUp() public {
        _factorySetUp(CrosschainConstants.MIN_CONFIG_DELAY);
    }

    function testShouldNotRestrictCallShapesOnTheStargateFactory() public requiresFactory {
        IRescueQueueHost host = IRescueQueueHost(address(factory));
        bytes memory operatorCall = abi.encodeCall(IEVC.setAccountOperator, (address(factory), admin, true));
        bytes memory requestCall = abi.encodeCall(WithdrawManager.requestShares, (1));
        vm.startPrank(admin);
        uint256 first = host.scheduleRescue(address(0xE0C), 0, operatorCall);
        uint256 second = host.scheduleRescue(address(0xE0C), 0, requestCall);
        vm.warp(block.timestamp + 3 days);
        host.executeRescue(first, operatorCall);
        host.executeRescue(second, requestCall);
        vm.stopPrank();
        assertEq(host.pendingRescueCount(), 0, "both ran");
    }
}

/// @title RescueVaultConnectorFenceTest
/// @notice IL-9654 on the real Ethereum Vault Connector: a dispatcher holds tracked shares of a vault that
///         authenticates its callers through the EVC (as Euler EVK vaults do). A rescue
///         `EVC.setAccountOperator(dispatcher, ADMIN, true)` targets the EVC, not the vault, and leaves the share
///         balance unchanged, so neither the vault ban nor the share snapshot sees it; the operator could then move
///         the shares at any time, outside the timelock and the guardian veto. The attack must fail at schedule.
contract RescueVaultConnectorFenceTest is StargateDispatcherFixture {
    uint32 internal constant EXECUTOR_EID = 30101;
    bytes32 internal constant GUID = keccak256("guid");
    address internal constant ADMIN = address(0xADADAD);

    MockLzEndpoint internal endpoint;
    MockStargatePool internal pool;
    MockERC20 internal usdc;
    EthereumVaultConnector internal evc;
    MockEvcVault internal vault;
    StargateCrosschainDispatcher internal dispatcher;

    function setUp() public {
        vm.chainId(42161);
        vm.warp(365 days);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        pool = new MockStargatePool(address(usdc), 6);
        endpoint = new MockLzEndpoint();
        evc = new EthereumVaultConnector();
        vault = new MockEvcVault(IERC20(address(usdc)), address(evc));
        dispatcher = _deployStargateDispatcher(address(endpoint), address(usdc), address(pool), ADMIN, EXECUTOR_EID);
        vm.deal(address(dispatcher), 100 ether);

        // The dispatcher holds tracked shares: allowlist the vault (it passes the admission check), bridge assets
        // in, DEPOSIT them.
        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        _deliver(
            CrosschainMessages.encodeUpdateVaults(
                UpdateVaults({
                    commandId: keccak256("uv"),
                    sequence: 0,
                    newConfigEpoch: 1,
                    minExecutionGas: DEFAULT_COMMAND_BUDGET,
                    vaults: vaults,
                    floors: new SweepFloor[](0)
                })
            )
        );
        usdc.mint(address(dispatcher), 100e6);
        bytes memory composeMsg = LzComposeBuilder.build(
            address(dispatcher),
            EXECUTOR_EID,
            100e6,
            CrosschainMessages.encodeOutboundTransfer(OutboundTransfer({transferId: keccak256("t1")}))
        );
        endpoint.deliverCompose(address(dispatcher), address(pool), GUID, composeMsg);
        _deliver(
            CrosschainMessages.encodeCommand(
                Command({
                    commandId: keccak256("dep"),
                    sequence: 1,
                    commandConfigEpoch: dispatcher.commandConfigEpoch(),
                    action: uint8(BusinessAction.DEPOSIT),
                    minExecutionGas: DEFAULT_COMMAND_BUDGET,
                    actionData: CrosschainMessages.encodeDepositAction(address(vault), 50e6, 0)
                })
            )
        );
        assertTrue(dispatcher.isTrackedVault(address(vault)), "vault tracked");
        assertEq(vault.balanceOf(address(dispatcher)), 50e6, "dispatcher holds shares");
    }

    function _deliver(bytes memory envelope_) internal {
        endpoint.deliverLz(
            address(dispatcher),
            EXECUTOR_EID,
            bytes32(uint256(uint160(address(dispatcher)))),
            GUID,
            envelope_
        );
    }

    function _assertAdminCannotMoveTheShares() internal {
        vm.prank(ADMIN);
        (bool moved, ) = address(evc).call(
            abi.encodeCall(
                IEVC.call,
                (address(vault), address(dispatcher), 0, abi.encodeCall(IERC20.transfer, (ADMIN, 50e6)))
            )
        );
        assertFalse(moved, "the admin is not an operator of the dispatcher's account");
        assertEq(vault.balanceOf(address(dispatcher)), 50e6, "shares intact");
    }

    /// @notice The attack must fail: the schedule is rejected, no operator is set, the admin cannot move the shares.
    function testShouldBlockOperatorGrantThroughTheVaultConnector() public {
        bytes memory cd = abi.encodeCall(IEVC.setAccountOperator, (address(dispatcher), ADMIN, true));
        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.RescueCallShapeNotAllowed.selector,
                address(evc),
                IEVC.setAccountOperator.selector
            )
        );
        dispatcher.scheduleRescue(address(evc), 0, cd);
        assertEq(dispatcher.rescueCount(), 0, "nothing queued");
        assertFalse(evc.isAccountOperatorAuthorized(address(dispatcher), ADMIN), "no operator");
        _assertAdminCannotMoveTheShares();
    }

    /// @notice The second route of the finding: a share `approve` relayed by the EVC on behalf of the dispatcher.
    function testShouldBlockShareApprovalRelayedByTheVaultConnector() public {
        bytes memory cd = abi.encodeCall(
            IEVC.call,
            (address(vault), address(dispatcher), 0, abi.encodeCall(IERC20.approve, (ADMIN, type(uint256).max)))
        );
        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.RescueCallShapeNotAllowed.selector,
                address(evc),
                IEVC.call.selector
            )
        );
        dispatcher.scheduleRescue(address(evc), 0, cd);
        assertEq(vault.allowance(address(dispatcher), ADMIN), 0, "no share allowance");
        _assertAdminCannotMoveTheShares();
    }

    /// @notice Control: the mechanism the attack relies on is real. The dispatcher is the owner of its own EVC
    ///         account, so one call from it sets an operator; the share balance does not move and the vault is not
    ///         called. The operator then transfers the shares with no timelock.
    function testVaultConnectorOperatorMovesTheAccountSharesWithoutABalanceChange() public {
        vm.prank(address(dispatcher));
        evc.setAccountOperator(address(dispatcher), ADMIN, true);
        assertTrue(evc.isAccountOperatorAuthorized(address(dispatcher), ADMIN), "operator set by the account owner");
        assertEq(vault.balanceOf(address(dispatcher)), 50e6, "the grant leaves the share balance unchanged");

        // Without the fence the admin drains the dispatcher's shares outside the timelock.
        vm.prank(ADMIN);
        evc.call(address(vault), address(dispatcher), 0, abi.encodeCall(IERC20.transfer, (ADMIN, 50e6)));
        assertEq(vault.balanceOf(address(dispatcher)), 0, "dispatcher shares moved by the operator");
        assertEq(vault.balanceOf(ADMIN), 50e6, "the admin holds them");
    }
}
