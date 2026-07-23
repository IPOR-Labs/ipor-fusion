// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {Errors} from "contracts/libraries/errors/Errors.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {
    TermFinanceRepurchaseFuse,
    TermFinanceRepurchaseFuseEnterData
} from "contracts/fuses/term_finance/TermFinanceRepurchaseFuse.sol";

import {TermFinanceRepurchaseFuseHarness} from "./mocks/TermFinanceRepurchaseFuseHarness.sol";
import {MockERC20Decimals} from "./mocks/MockERC20Decimals.sol";
import {MockTermController} from "./mocks/MockTermController.sol";
import {MockTermRepoLocker} from "./mocks/MockTermRepoLocker.sol";
import {MockTermRepoServicer} from "./mocks/MockTermRepoServicer.sol";

/// @notice Unit tests for the borrower-side `TermFinanceRepurchaseFuse`.
/// @dev Mirrors the structure of `TermFinanceCollateralFuseTest`. Coverage matrix:
///      - happy path: full repayment, partial repayment, event payload
///      - approval target verification: `forceApprove(purchaseToken, termRepoLocker, X)` followed
///        by `forceApprove(..., 0)` post-call (approval target is the per-Term `TermRepoLocker`,
///        NOT the servicer / purchase token contract itself)
///      - WithdrawManager runtime check (`enter` reverts, constructor does NOT revert)
///      - TermController.isTermDeployed guard
///      - Substrate allowlist (SERVICER substrate)
///      - Repurchase window guard (strict `<` boundary)
///      - Zero amount input validation
///      - Underfunded vault propagation
///      - Overpayment handling (capped at obligation by the Servicer impl — see
///        `MockTermRepoServicer.revertOnOverpayment` for both branches)
///      - Negative coverage: the contract exposes no `exit()` symbol.
contract TermFinanceRepurchaseFuseTest is Test {
    /// @dev Canonical WithdrawManager storage slot (PlasmaVaultStorageLib.WITHDRAW_MANAGER).
    ///      Used to poke the harness's storage directly so the runtime check
    ///      `getWithdrawManager().manager == address(0)` resolves to a non-zero address.
    bytes32 internal constant WITHDRAW_MANAGER_SLOT =
        0x465d2ff0062318fe6f4c7e9ac78cfcd70bc86a1d992722875ef83a9770513100;

    /// @dev Local copy of the fuse event for `vm.expectEmit` assertions.
    event TermFinanceRepurchased(
        address version,
        address servicer,
        uint256 amountPaid,
        uint256 remainingObligation
    );

    uint256 internal constant MARKET_ID = 52;
    address internal constant WITHDRAW_MANAGER = address(0xBEEF);

    TermFinanceRepurchaseFuseHarness internal harness;
    MockTermController internal controller;
    MockTermRepoServicer internal servicer;
    MockTermRepoLocker internal termRepoLocker;
    MockERC20Decimals internal usdc;

    /// @dev Default obligation seeded for the vault (the harness) in every test setup.
    ///      Tests can override per-case via `servicer.setBorrowerRepurchaseObligation`.
    uint256 internal constant DEFAULT_OBLIGATION = 1_000_000; // 1 USDC, 6 decimals
    /// @dev Default repurchase window end seeded by setUp. `block.timestamp` starts well below.
    uint256 internal constant DEFAULT_WINDOW_END = 1_000_000_000;

    function setUp() public {
        controller = new MockTermController();
        harness = new TermFinanceRepurchaseFuseHarness(MARKET_ID, address(controller));

        usdc = new MockERC20Decimals("USDC", "USDC", 6);
        servicer = new MockTermRepoServicer();
        termRepoLocker = new MockTermRepoLocker();

        // Wire the Term-side pairing: servicer owns the locker and the purchase token.
        servicer.setTermRepoLocker(address(termRepoLocker));
        servicer.setPurchaseToken(address(usdc));
        servicer.setEndOfRepurchaseWindow(DEFAULT_WINDOW_END);
        servicer.setBorrowerRepurchaseObligation(address(harness), DEFAULT_OBLIGATION);

        // Mark the servicer as deployed in the Term Finance controller.
        controller.setIsTermDeployed(address(servicer), true);

        // Grant the SERVICER substrate on the vault side (TYPE 0x00 — legacy addressToBytes32
        // encoding, naturally compatible with `TermFinanceSubstrateType.SERVICER`).
        bytes32[] memory subs = new bytes32[](1);
        subs[0] = PlasmaVaultConfigLib.addressToBytes32(address(servicer));
        harness.setMarketSubstrates(MARKET_ID, subs);

        // Provision the harness's WithdrawManager slot so `_assertWithdrawManagerSet()` passes
        // by default. Tests that need to assert the missing-WithdrawManager revert wipe it back
        // to address(0) via `_setWithdrawManager(address(0))`.
        _setWithdrawManager(WITHDRAW_MANAGER);

        // Fund the vault (harness) with enough purchase token to cover the default obligation
        // multiple times over. Tests that need an underfunded path overwrite this.
        usdc.mint(address(harness), DEFAULT_OBLIGATION * 10);

        // Pin block.timestamp clearly below the repurchase window end so the window guard
        // passes for happy-path tests.
        vm.warp(1);
    }

    // ---------- helpers ----------

    /// @notice Direct-poke the WithdrawManager slot of the harness so the runtime check
    ///         resolves correctly. Mirrors the `vm.store` pattern in
    ///         `TermFinanceCollateralFuseTest._setWithdrawManager`.
    function _setWithdrawManager(address manager_) internal {
        vm.store(address(harness), WITHDRAW_MANAGER_SLOT, bytes32(uint256(uint160(manager_))));
    }

    function _enterData(uint256 amount_) internal view returns (TermFinanceRepurchaseFuseEnterData memory) {
        return TermFinanceRepurchaseFuseEnterData({servicer: address(servicer), amount: amount_});
    }

    // ============ constructor ============

    function test_constructor_setsImmutables() public view {
        assertEq(harness.MARKET_ID(), MARKET_ID);
        assertEq(harness.TERM_CONTROLLER(), address(controller));
        assertEq(harness.VERSION(), address(harness));
    }

    function test_constructor_revertsOnZeroMarketId() public {
        vm.expectRevert(Errors.WrongValue.selector);
        new TermFinanceRepurchaseFuseHarness(0, address(controller));
    }

    function test_constructor_revertsOnZeroController() public {
        vm.expectRevert(Errors.WrongAddress.selector);
        new TermFinanceRepurchaseFuseHarness(MARKET_ID, address(0));
    }

    /// @notice Regression test — the WithdrawManager check MUST live in `enter`,
    ///         NOT the constructor. An earlier plan draft put the check in the constructor;
    ///         that would have read empty deployer-EOA storage at deployment time and
    ///         unconditionally reverted. Asserting that fresh construction succeeds even when
    ///         the deployer has no WithdrawManager-shaped slot codifies the step 0
    ///         invariant.
    function testRepurchaseConstructorDoesNotRevertOutsideDelegatecall() public {
        // Build fresh — no `vm.store` for WithdrawManager. Constructor must NOT call
        // `_assertWithdrawManagerSet()`.
        TermFinanceRepurchaseFuseHarness freshHarness = new TermFinanceRepurchaseFuseHarness(
            MARKET_ID,
            address(controller)
        );
        assertEq(freshHarness.MARKET_ID(), MARKET_ID);
        assertEq(freshHarness.TERM_CONTROLLER(), address(controller));
    }

    function testConstructorShouldNotRevertWhenWithdrawManagerIsZero() public {
        // Standalone deployment — WithdrawManager check must NOT run in constructor.
        // Mirror of `testRepurchaseConstructorDoesNotRevertOutsideDelegatecall` named per the
        // task spec naming convention.
        new TermFinanceRepurchaseFuseHarness(MARKET_ID, address(controller));
    }

    // ============ enter — happy path ============

    function testEnterShouldSubmitRepurchasePayment() public {
        uint256 amount = DEFAULT_OBLIGATION;
        uint256 vaultBalanceBefore = usdc.balanceOf(address(harness));
        uint256 lockerBalanceBefore = usdc.balanceOf(address(termRepoLocker));

        harness.enter(_enterData(amount));

        assertEq(
            usdc.balanceOf(address(harness)),
            vaultBalanceBefore - amount,
            "vault purchase-token balance decreases by repaid amount"
        );
        assertEq(
            usdc.balanceOf(address(termRepoLocker)),
            lockerBalanceBefore + amount,
            "purchase token lands in the per-Term locker (pulled via transferTokenFromWallet)"
        );
        assertEq(
            servicer.getBorrowerRepurchaseObligation(address(harness)),
            0,
            "obligation fully discharged"
        );
    }

    function testEnterShouldEmitRepurchasedEvent() public {
        uint256 amount = DEFAULT_OBLIGATION;

        vm.expectEmit(true, true, true, true);
        // amountPaid == amount because the mock fully pulls; remainingObligation == 0 after full repay.
        emit TermFinanceRepurchased(address(harness), address(servicer), amount, 0);
        harness.enter(_enterData(amount));
    }

    /// @notice Verifies the approval-target invariant: the fuse approves the
    ///         per-Term `TermRepoLocker` (NOT the servicer, NOT the purchase token contract
    ///         itself) and resets the allowance to zero post-call via `forceApprove(..., 0)`.
    function testEnterShouldClearApprovalAfterRepay() public {
        uint256 amount = DEFAULT_OBLIGATION;
        harness.enter(_enterData(amount));

        assertEq(
            usdc.allowance(address(harness), address(termRepoLocker)),
            0,
            "termRepoLocker allowance reset to zero after repay"
        );
        // Also assert we never approved the servicer — approval target is the locker, NOT the servicer.
        assertEq(
            usdc.allowance(address(harness), address(servicer)),
            0,
            "must not approve servicer (approval target is termRepoLocker)"
        );
    }

    /// @notice Partial repayment: `amount < obligation`. The fuse measures the pre/post delta
    ///         (= amount) and the event records the leftover obligation.
    function testEnterShouldHandlePartialRepayment() public {
        uint256 amount = DEFAULT_OBLIGATION / 3; // smaller than outstanding obligation
        uint256 expectedRemaining = DEFAULT_OBLIGATION - amount;

        uint256 vaultBalanceBefore = usdc.balanceOf(address(harness));

        vm.expectEmit(true, true, true, true);
        emit TermFinanceRepurchased(address(harness), address(servicer), amount, expectedRemaining);
        harness.enter(_enterData(amount));

        assertEq(
            usdc.balanceOf(address(harness)),
            vaultBalanceBefore - amount,
            "vault balance decreases by the partial amount"
        );
        assertEq(
            servicer.getBorrowerRepurchaseObligation(address(harness)),
            expectedRemaining,
            "remaining obligation tracked by servicer"
        );
    }

    // ============ WithdrawManager runtime check ============

    function testEnterShouldRevertWhenWithdrawManagerIsZero() public {
        // Wipe the WithdrawManager so the runtime check fails.
        _setWithdrawManager(address(0));

        vm.expectRevert(TermFinanceRepurchaseFuse.TermFinanceRepurchaseFuseWithdrawManagerRequired.selector);
        harness.enter(_enterData(DEFAULT_OBLIGATION));
    }

    /// @notice Ordering verification: even when OTHER validations would also fail
    ///         (substrate wipe), the WithdrawManager check MUST be reported first — confirms
    ///         `_assertWithdrawManagerSet()` runs as the FIRST statement of `enter`.
    function testRepurchaseEnterChecksWithdrawManagerBeforeOtherValidation() public {
        _setWithdrawManager(address(0));
        // Wipe substrates so the servicer-allowlist check would ALSO fail. Expect the
        // WithdrawManager selector, not `UnsupportedMarket`.
        bytes32[] memory empty = new bytes32[](0);
        harness.setMarketSubstrates(MARKET_ID, empty);

        vm.expectRevert(TermFinanceRepurchaseFuse.TermFinanceRepurchaseFuseWithdrawManagerRequired.selector);
        harness.enter(_enterData(DEFAULT_OBLIGATION));
    }

    // ============ TermController.isTermDeployed guard ============

    function testEnterShouldRevertWhenTermNotDeployed() public {
        controller.setIsTermDeployed(address(servicer), false);

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceRepurchaseFuse.TermFinanceRepurchaseFuseTermNotDeployed.selector,
                address(servicer)
            )
        );
        harness.enter(_enterData(DEFAULT_OBLIGATION));
    }

    // ============ Substrate validation ============

    function testEnterShouldRevertWhenServicerSubstrateNotGranted() public {
        bytes32[] memory empty = new bytes32[](0);
        harness.setMarketSubstrates(MARKET_ID, empty);

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceRepurchaseFuse.TermFinanceRepurchaseFuseUnsupportedMarket.selector,
                address(servicer)
            )
        );
        harness.enter(_enterData(DEFAULT_OBLIGATION));
    }

    // ============ Repurchase window guard ============

    /// @notice Strict `<` boundary per the fuse's NatSpec step 8: when
    ///         `block.timestamp == endOfRepurchaseWindow`, the borrower is already inside the
    ///         default window where collateral may be seized by liquidators — so the call must
    ///         revert. This is also the at-boundary test (instantly-at-endTimestamp reverts).
    function testEnterShouldRevertWhenWindowClosed() public {
        uint256 windowEnd = 2_000_000;
        servicer.setEndOfRepurchaseWindow(windowEnd);
        vm.warp(windowEnd); // block.timestamp == end → revert (strict `<`)

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceRepurchaseFuse.TermFinanceRepurchaseFuseWindowClosed.selector,
                windowEnd,
                windowEnd
            )
        );
        harness.enter(_enterData(DEFAULT_OBLIGATION));
    }

    /// @notice Additional coverage past the boundary — `block.timestamp > end` also reverts.
    function testEnterShouldRevertWhenWindowClosedPastBoundary() public {
        uint256 windowEnd = 2_000_000;
        servicer.setEndOfRepurchaseWindow(windowEnd);
        vm.warp(windowEnd + 1 days);

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceRepurchaseFuse.TermFinanceRepurchaseFuseWindowClosed.selector,
                windowEnd + 1 days,
                windowEnd
            )
        );
        harness.enter(_enterData(DEFAULT_OBLIGATION));
    }

    /// @notice Boundary on the accepting side: `block.timestamp == end - 1` (the last legal
    ///         instant for a borrower repurchase) must succeed.
    function testEnterShouldAcceptRepurchaseAtWindowMinusOne() public {
        uint256 windowEnd = 2_000_000;
        servicer.setEndOfRepurchaseWindow(windowEnd);
        vm.warp(windowEnd - 1);

        // No revert expected — should fully process the repayment.
        harness.enter(_enterData(DEFAULT_OBLIGATION));
        assertEq(
            servicer.getBorrowerRepurchaseObligation(address(harness)),
            0,
            "boundary-1 repayment processed normally"
        );
    }

    // ============ Input validation ============

    function testEnterShouldRevertWhenAmountIsZero() public {
        vm.expectRevert(TermFinanceRepurchaseFuse.TermFinanceRepurchaseFuseZeroAmount.selector);
        harness.enter(_enterData(0));
    }

    // ============ Edge cases ============

    /// @notice When the vault is underfunded relative to the repayment amount, the ERC20 pull
    ///         inside `TermRepoLocker.transferTokenFromWallet` must propagate (OZ ERC20
    ///         `transferFrom` reverts with `ERC20InsufficientBalance`). The fuse itself does
    ///         NOT pre-check the balance — the underlying transfer is the source of truth,
    ///         which keeps the fuse minimal.
    function testEnterShouldRevertWhenInsufficientPurchaseTokenBalance() public {
        // Drain the vault so it cannot cover the repayment.
        uint256 vaultBalance = usdc.balanceOf(address(harness));
        vm.prank(address(harness));
        usdc.transfer(address(0xDEAD), vaultBalance);

        // Seed an obligation strictly greater than the (now zero) vault balance so the pull fails.
        servicer.setBorrowerRepurchaseObligation(address(harness), DEFAULT_OBLIGATION);

        // OZ 5.x ERC20 uses a custom error here — accept any revert from the transferFrom call.
        vm.expectRevert();
        harness.enter(_enterData(DEFAULT_OBLIGATION));
    }

    /// @notice The fuse now CLAMPS the payment to the outstanding obligation
    ///         BEFORE approving/submitting, so it can never over-pay — even a servicer that
    ///         rejects `amount > obligation` (`revertOnOverpayment = true`) is handed exactly
    ///         the obligation and succeeds. This proves the fuse-side cap does not depend on
    ///         the servicer's own over-payment guard.
    function testEnterClampsToObligation_noOverpaymentRevertEvenWhenServicerRejects() public {
        servicer.setRevertOnOverpayment(true);
        servicer.setBorrowerRepurchaseObligation(address(harness), DEFAULT_OBLIGATION);

        uint256 overAmount = DEFAULT_OBLIGATION * 2;
        uint256 vaultBalanceBefore = usdc.balanceOf(address(harness));

        // Clamped to DEFAULT_OBLIGATION → servicer is not over-paid → no revert.
        vm.expectEmit(true, true, true, true);
        emit TermFinanceRepurchased(address(harness), address(servicer), DEFAULT_OBLIGATION, 0);
        harness.enter(_enterData(overAmount));

        assertEq(
            usdc.balanceOf(address(harness)),
            vaultBalanceBefore - DEFAULT_OBLIGATION,
            "fuse-side clamp pulled exactly the obligation despite over-sized request"
        );
        assertEq(usdc.allowance(address(harness), address(termRepoLocker)), 0, "allowance reset to zero");
    }

    /// @notice Repurchase with no outstanding obligation reverts for observability
    ///         instead of approving/submitting a clamped-to-zero no-op.
    function testEnterRevertsWhenNoObligation() public {
        servicer.setBorrowerRepurchaseObligation(address(harness), 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceRepurchaseFuse.TermFinanceRepurchaseFuseNoObligation.selector,
                address(servicer)
            )
        );
        harness.enter(_enterData(DEFAULT_OBLIGATION));
    }

    function testEnterShouldRecordCappedAmountWhenServicerAcceptsOverpayment() public {
        servicer.setRevertOnOverpayment(false);
        servicer.setBorrowerRepurchaseObligation(address(harness), DEFAULT_OBLIGATION);

        uint256 overAmount = DEFAULT_OBLIGATION * 2;
        uint256 vaultBalanceBefore = usdc.balanceOf(address(harness));

        // The mock caps the pull at the outstanding obligation; the fuse's pre/post delta
        // therefore equals `DEFAULT_OBLIGATION` (not the requested `overAmount`). This proves
        // the contract NatSpec promise that `amountPaid` reflects the actual transfer, not the
        // input parameter.
        vm.expectEmit(true, true, true, true);
        emit TermFinanceRepurchased(address(harness), address(servicer), DEFAULT_OBLIGATION, 0);
        harness.enter(_enterData(overAmount));

        assertEq(
            usdc.balanceOf(address(harness)),
            vaultBalanceBefore - DEFAULT_OBLIGATION,
            "only the outstanding obligation was pulled; excess request ignored"
        );
        assertEq(
            usdc.allowance(address(harness), address(termRepoLocker)),
            0,
            "allowance still reset to zero even though servicer pulled less than approved"
        );
    }

    /// @notice Propagation coverage: a revert inside the Servicer's `submitRepurchasePayment`
    ///         (e.g. paused, blacklisted, deployment guard mid-call) bubbles up unchanged.
    function testEnterShouldPropagateRevertFromServicer() public {
        servicer.setSubmitRepurchasePaymentReverts(true);
        vm.expectRevert(bytes("MockTermRepoServicer: submitRepurchasePayment reverts"));
        harness.enter(_enterData(DEFAULT_OBLIGATION));
    }

    // ============ Asymmetric design — no exit() ============

    /// @notice Repurchase payments are irreversible at the Term layer (funds flow into the
    ///         lender redemption pot). The contract MUST NOT expose a symmetric `exit()` —
    ///         this test pins that asymmetric design (regression against a future PR adding
    ///         an `exit` selector to the ABI).
    function testRepurchaseFuseHasNoExitFunction() public {
        bytes4 exitWithEnterStructSelector = bytes4(keccak256("exit((address,uint256))"));
        bytes4 exitNoArgsSelector = bytes4(keccak256("exit()"));

        // Attempt to call common `exit` shapes via low-level call. Both must fail with no
        // matching function (no selector wired) — i.e. the call returns success=false and
        // empty returndata in Solidity 0.8.x (no fallback on the harness).
        (bool ok1, ) = address(harness).call(abi.encodePacked(exitWithEnterStructSelector));
        (bool ok2, ) = address(harness).call(abi.encodePacked(exitNoArgsSelector));

        assertFalse(ok1, "fuse must not expose exit((address,uint256))");
        assertFalse(ok2, "fuse must not expose exit()");
    }
}
