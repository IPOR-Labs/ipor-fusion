// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IEVC} from "ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";
import {Errors as EvcErrors} from "ethereum-vault-connector/src/Errors.sol";

import {RescueShapeFenceEvkForkBase} from "./RescueShapeFenceEvkForkBase.sol";
import {CrosschainErrors} from "../../../contracts/crosschain/lib/CrosschainErrors.sol";
import {CrosschainMessages, UpdateVaults, SweepFloor} from "../../../contracts/crosschain/lib/CrosschainMessages.sol";
import {DEFAULT_COMMAND_BUDGET} from "../CommandBudget.sol";
import {IBorrowing} from "../../../contracts/fuses/euler/ext/IBorrowing.sol";

/// @title RescueShapeFenceEvkForkTest
/// @notice IL-9654 on a fork with the real Ethereum Vault Connector and real Euler EVK vaults. The dispatcher holds
///         tracked shares of a real vault. The three routes that granted a right through a generic rescue on the base
///         commit (operator grant, relayed approve, controller borrow) are refused at `scheduleRescue` with
///         `RescueCallShapeNotAllowed(target, selector)`; the same calls made directly as the dispatcher still work
///         on the real EVC/EVK, which shows the mechanism is real and only the schedule-time fence stops it. Calls in
///         the allowed shapes still pass on the same setup.
/// @dev One contract per fork block, and blocks that no other suite uses: tests that fork the same URL at the same
///      block share a backend, and a parallel `vm.warp` would leak between them. The calldata comes from the
///      builders of `RescueShapeFenceEvkForkBase`. Needs ETHEREUM_PROVIDER_URL (archive node).
abstract contract RescueShapeFenceEvkForkTestBase is RescueShapeFenceEvkForkBase {
    /// @dev `E_InsufficientAllowance()` of the Euler vault kit (`BalanceUtils`); the vaults are not importable here.
    bytes4 internal constant EVK_E_INSUFFICIENT_ALLOWANCE = 0x9f428ac4;

    function _schedule(address target_, bytes memory callData_) internal returns (uint256 id) {
        vm.prank(ADMIN);
        id = dispatcher.scheduleRescue(target_, 0, callData_);
    }

    function _execute(uint256 id_, bytes memory callData_) internal {
        vm.prank(ADMIN);
        dispatcher.executeRescue(id_, callData_);
    }

    /// @dev Schedule must revert `RescueCallShapeNotAllowed(target_, selector of callData_)`; nothing is queued.
    function _assertRefusedAtSchedule(address target_, bytes memory callData_) internal {
        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(CrosschainErrors.RescueCallShapeNotAllowed.selector, target_, bytes4(callData_))
        );
        dispatcher.scheduleRescue(target_, 0, callData_);
        assertEq(dispatcher.rescueCount(), 0, "nothing recorded");
        assertEq(dispatcher.pendingRescueCount(), 0, "queue empty");
    }

    function _assertSharesUntouched() internal view {
        assertEq(IERC20(TRACKED_VAULT).balanceOf(address(dispatcher)), depositedShares, "shares untouched");
        assertEq(IERC20(TRACKED_VAULT).balanceOf(ADMIN), 0, "no shares at the admin");
    }
}

/// @notice Route 1: operator grant on the dispatcher's EVC account.
contract RescueShapeFenceEvkRoute1ForkTest is RescueShapeFenceEvkForkTestBase {
    function _forkBlock() internal pure override returns (uint256) {
        return 23_600_201;
    }

    function testShouldRefuseTheOperatorGrantAtSchedule() public {
        (address target, bytes memory cd) = _route1OperatorGrant();
        _assertRefusedAtSchedule(target, cd);
        assertEq(bytes4(cd), IEVC.setAccountOperator.selector, "selector");

        // Even after the timelock would have elapsed, no right exists and the later use fails.
        vm.warp(block.timestamp + RESCUE_DELAY + 1);
        assertFalse(IEVC(EVC).isAccountOperatorAuthorized(address(dispatcher), ADMIN), "no operator");
        // The EVC refuses the admin as caller on behalf of the dispatcher's account.
        vm.expectRevert(EvcErrors.EVC_NotAuthorized.selector);
        this.route1LaterUseExternal();
        _assertSharesUntouched();
    }

    /// @dev External wrapper so `expectRevert` sees the revert of the EVC call.
    function route1LaterUseExternal() external {
        _route1LaterUse();
    }

    function testControlTheSameOperatorGrantMadeAsTheDispatcherGrantsTheRight() public {
        (address target, bytes memory cd) = _route1OperatorGrant();
        vm.prank(address(dispatcher));
        (bool ok, ) = target.call(cd);
        assertTrue(ok, "grant call");
        assertTrue(IEVC(EVC).isAccountOperatorAuthorized(address(dispatcher), ADMIN), "operator set");

        _route1LaterUse();
        assertEq(IERC20(TRACKED_VAULT).balanceOf(address(dispatcher)), 0, "dispatcher drained");
        assertEq(IERC20(TRACKED_VAULT).balanceOf(ADMIN), depositedShares, "shares at the admin");
    }
}

/// @notice Route 2: share approve relayed by the EVC on behalf of the dispatcher.
contract RescueShapeFenceEvkRoute2ForkTest is RescueShapeFenceEvkForkTestBase {
    function _forkBlock() internal pure override returns (uint256) {
        return 23_600_202;
    }

    function testShouldRefuseTheRelayedApproveAtSchedule() public {
        (address target, bytes memory cd) = _route2RelayedApprove();
        _assertRefusedAtSchedule(target, cd);
        assertEq(bytes4(cd), IEVC.call.selector, "selector");

        vm.warp(block.timestamp + RESCUE_DELAY + 1);
        assertEq(IERC20(TRACKED_VAULT).allowance(address(dispatcher), ADMIN), 0, "no allowance");
        // The EVK vault refuses the pull: the admin has no share allowance (historical EVK `E_InsufficientAllowance`).
        vm.expectRevert(EVK_E_INSUFFICIENT_ALLOWANCE);
        this.route2LaterUseExternal();
        _assertSharesUntouched();
    }

    function route2LaterUseExternal() external {
        _route2LaterUse();
    }

    function testControlTheSameRelayedApproveMadeAsTheDispatcherGrantsTheAllowance() public {
        (address target, bytes memory cd) = _route2RelayedApprove();
        vm.prank(address(dispatcher));
        (bool ok, ) = target.call(cd);
        assertTrue(ok, "relayed approve call");
        assertEq(IERC20(TRACKED_VAULT).allowance(address(dispatcher), ADMIN), type(uint256).max, "allowance set");

        _route2LaterUse();
        assertEq(IERC20(TRACKED_VAULT).balanceOf(address(dispatcher)), 0, "dispatcher drained");
        assertEq(IERC20(TRACKED_VAULT).balanceOf(ADMIN), depositedShares, "shares at the admin");
    }
}

/// @notice Route 3: controller borrow through a lending sibling vault (enableCollateral, enableController, borrow).
contract RescueShapeFenceEvkRoute3ForkTest is RescueShapeFenceEvkForkTestBase {
    function _forkBlock() internal pure override returns (uint256) {
        return 23_600_203;
    }

    function testShouldRefuseAllThreeCallsOfTheControllerBorrowAtSchedule() public {
        (address t1, bytes memory c1) = _route3EnableCollateral();
        (address t2, bytes memory c2) = _route3EnableController();
        (address t3, bytes memory c3) = _route3Borrow(BORROW_AMOUNT);
        assertEq(bytes4(c1), IEVC.enableCollateral.selector, "selector 1");
        assertEq(bytes4(c2), IEVC.enableController.selector, "selector 2");
        assertEq(bytes4(c3), IBorrowing.borrow.selector, "selector 3");
        assertEq(t3, BORROW_VAULT, "borrow targets the sibling vault");

        _assertRefusedAtSchedule(t1, c1);
        _assertRefusedAtSchedule(t2, c2);
        _assertRefusedAtSchedule(t3, c3);

        vm.warp(block.timestamp + RESCUE_DELAY + 1);
        assertEq(IBorrowing(BORROW_VAULT).debtOf(address(dispatcher)), 0, "no debt");
        assertEq(IEVC(EVC).getControllers(address(dispatcher)).length, 0, "no controller");
        assertEq(IEVC(EVC).getCollaterals(address(dispatcher)).length, 0, "no collateral enabled");
        _assertSharesUntouched();
    }

    function testControlTheSameThreeCallsMadeAsTheDispatcherBorrowAgainstItsShares() public {
        (address t1, bytes memory c1) = _route3EnableCollateral();
        (address t2, bytes memory c2) = _route3EnableController();
        (address t3, bytes memory c3) = _route3Borrow(BORROW_AMOUNT);
        uint256 adminUsdcBefore = IERC20(USDC).balanceOf(ADMIN);

        vm.startPrank(address(dispatcher));
        (bool ok1, ) = t1.call(c1);
        (bool ok2, ) = t2.call(c2);
        (bool ok3, ) = t3.call(c3);
        vm.stopPrank();

        assertTrue(ok1 && ok2 && ok3, "the three calls succeed as the dispatcher");
        assertEq(IERC20(USDC).balanceOf(ADMIN) - adminUsdcBefore, BORROW_AMOUNT, "borrowed tokens at the admin");
        assertGt(IBorrowing(BORROW_VAULT).debtOf(address(dispatcher)), 0, "debt on the dispatcher account");
        assertEq(IERC20(TRACKED_VAULT).balanceOf(address(dispatcher)), depositedShares, "shares still held");
    }
}

/// @notice Control: a `transfer` of a foreign token still passes the fence on the same setup.
contract RescueShapeFenceEvkAllowedTransferForkTest is RescueShapeFenceEvkForkTestBase {
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    function _forkBlock() internal pure override returns (uint256) {
        return 23_600_204;
    }

    function testControlShouldScheduleAndExecuteATransferOfAForeignToken() public {
        uint256 amount = 1_000e18;
        deal(DAI, address(dispatcher), amount);
        bytes memory cd = abi.encodeCall(IERC20.transfer, (ADMIN, amount));

        uint256 id = _schedule(DAI, cd);
        assertEq(dispatcher.pendingRescueCount(), 1, "queued");
        vm.warp(block.timestamp + RESCUE_DELAY + 1);
        _execute(id, cd);

        assertEq(IERC20(DAI).balanceOf(ADMIN), amount, "token at the admin");
        assertEq(IERC20(DAI).balanceOf(address(dispatcher)), 0, "token left the dispatcher");
        assertEq(IERC20(TRACKED_VAULT).balanceOf(address(dispatcher)), depositedShares, "tracked shares untouched");
    }
}

/// @notice Control: a `redeem` of residual shares with the dispatcher as owner on a removed vault still passes.
contract RescueShapeFenceEvkAllowedRedeemForkTest is RescueShapeFenceEvkForkTestBase {
    function _forkBlock() internal pure override returns (uint256) {
        return 23_600_205;
    }

    function testControlShouldRedeemResidualSharesOfARemovedVaultAsOwner() public {
        // Remove the vault from the allowlist: the sweep redeems the position and the vault is untracked.
        _deliver(
            CrosschainMessages.encodeUpdateVaults(
                UpdateVaults({
                    commandId: keccak256("rm"),
                    sequence: 2,
                    newConfigEpoch: 2,
                    minExecutionGas: DEFAULT_COMMAND_BUDGET,
                    vaults: new address[](0),
                    floors: new SweepFloor[](0)
                })
            )
        );
        assertFalse(dispatcher.isTrackedVault(TRACKED_VAULT), "vault untracked");
        assertFalse(dispatcher.isAllowedVault(TRACKED_VAULT), "vault off the allowlist");

        // A donation leaves residual shares of the removed vault on the dispatcher.
        deal(USDC, address(this), 20e6);
        IERC20(USDC).approve(TRACKED_VAULT, 20e6);
        IERC4626(TRACKED_VAULT).deposit(20e6, address(dispatcher));
        uint256 residual = IERC20(TRACKED_VAULT).balanceOf(address(dispatcher));
        assertGt(residual, 0, "residual shares");

        bytes memory cd = abi.encodeCall(IERC4626.redeem, (residual, ADMIN, address(dispatcher)));
        uint256 id = _schedule(TRACKED_VAULT, cd);
        vm.warp(block.timestamp + RESCUE_DELAY + 1);
        uint256 adminUsdcBefore = IERC20(USDC).balanceOf(ADMIN);
        _execute(id, cd);

        assertEq(IERC20(TRACKED_VAULT).balanceOf(address(dispatcher)), 0, "residual redeemed");
        assertGt(IERC20(USDC).balanceOf(ADMIN) - adminUsdcBefore, 19e6, "assets at the receiver");
    }
}

/// @notice Control: a value-only rescue (empty calldata) to the EVC passes the fence at schedule, but the EVC refuses
///         the native value at execution outside deferred checks, so it grants nothing.
contract RescueShapeFenceEvkEmptyCalldataEvcForkTest is RescueShapeFenceEvkForkTestBase {
    function _forkBlock() internal pure override returns (uint256) {
        return 23_600_206;
    }

    function testControlShouldScheduleAValueOnlyRescueToTheEvcAndFailItAtExecution() public {
        vm.prank(ADMIN);
        uint256 id = dispatcher.scheduleRescue(EVC, 1, "");
        assertEq(dispatcher.pendingRescueCount(), 1, "queued");
        vm.warp(block.timestamp + RESCUE_DELAY + 1);

        uint256 evcBalanceBefore = EVC.balance;
        uint256 dispatcherBalanceBefore = address(dispatcher).balance;
        vm.prank(ADMIN);
        vm.expectRevert(EvcErrors.EVC_NotAuthorized.selector);
        dispatcher.executeRescue(id, "");

        assertEq(EVC.balance, evcBalanceBefore, "the EVC received nothing");
        assertEq(address(dispatcher).balance, dispatcherBalanceBefore, "the dispatcher kept its native balance");
        assertFalse(IEVC(EVC).isAccountOperatorAuthorized(address(dispatcher), ADMIN), "no operator");
        assertEq(IEVC(EVC).getControllers(address(dispatcher)).length, 0, "no controller");
        _assertSharesUntouched();
    }
}

/// @notice Control: a value-only rescue to WETH passes the fence and executes; WETH only credits the dispatcher.
contract RescueShapeFenceEvkEmptyCalldataWethForkTest is RescueShapeFenceEvkForkTestBase {
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function _forkBlock() internal pure override returns (uint256) {
        return 23_600_207;
    }

    function testControlShouldExecuteAValueOnlyRescueToWethAndCreditOnlyTheDispatcher() public {
        uint256 amount = 1 ether;
        vm.prank(ADMIN);
        uint256 id = dispatcher.scheduleRescue(WETH, amount, "");
        assertEq(dispatcher.pendingRescueCount(), 1, "queued");
        vm.warp(block.timestamp + RESCUE_DELAY + 1);

        uint256 nativeBefore = address(dispatcher).balance;
        uint256 wethBefore = IERC20(WETH).balanceOf(address(dispatcher));
        uint256 adminWethBefore = IERC20(WETH).balanceOf(ADMIN);
        vm.prank(ADMIN);
        dispatcher.executeRescue(id, "");

        assertEq(nativeBefore - address(dispatcher).balance, amount, "the native value left the dispatcher");
        assertEq(IERC20(WETH).balanceOf(address(dispatcher)) - wethBefore, amount, "WETH credited to the dispatcher");
        assertEq(IERC20(WETH).balanceOf(ADMIN), adminWethBefore, "nothing credited to the admin");
        assertEq(IERC20(WETH).allowance(address(dispatcher), ADMIN), 0, "no allowance granted");
        _assertSharesUntouched();
    }
}
