// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {Errors} from "contracts/libraries/errors/Errors.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {
    TermFinanceCollateralFuse,
    TermFinanceCollateralFuseEnterData,
    TermFinanceCollateralFuseExitData
} from "contracts/fuses/term_finance/TermFinanceCollateralFuse.sol";
import {TermFinanceSubstrateLib} from "contracts/fuses/term_finance/lib/TermFinanceSubstrateLib.sol";

import {TermFinanceCollateralFuseHarness} from "./mocks/TermFinanceCollateralFuseHarness.sol";
import {MockERC20Decimals} from "./mocks/MockERC20Decimals.sol";
import {MockTermController} from "./mocks/MockTermController.sol";
import {MockTermRepoCollateralManager} from "./mocks/MockTermRepoCollateralManager.sol";
import {MockTermRepoLocker} from "./mocks/MockTermRepoLocker.sol";
import {MockTermRepoServicer} from "./mocks/MockTermRepoServicer.sol";

/// @notice Unit tests for the borrower-side `TermFinanceCollateralFuse`.
/// @dev Mirrors the structure of `TermFinanceOfferFuseTest`. Coverage matrix:
///      - happy path (lock + unlock + approval cleanup)
///      - WithdrawManager runtime check (enter + exit + constructor regression)
///      - TermController.isTermDeployed guard
///      - Substrate allowlist (servicer + collateral pair)
///      - Servicer ⇄ CollateralManager impersonation guard
///      - CollateralManager accepted-token guard
///      - Zero-amount input
///      - ERC20 revert when vault is underfunded.
contract TermFinanceCollateralFuseTest is Test {
    /// @dev Canonical WithdrawManager storage slot (PlasmaVaultStorageLib.WITHDRAW_MANAGER).
    ///      Used to poke the harness's storage directly so the runtime check
    ///      `getWithdrawManager().manager == address(0)` resolves to a non-zero address.
    bytes32 internal constant WITHDRAW_MANAGER_SLOT =
        0x465d2ff0062318fe6f4c7e9ac78cfcd70bc86a1d992722875ef83a9770513100;

    /// @dev Local copies of fuse events for `vm.expectEmit` assertions.
    event TermFinanceCollateralLocked(
        address version,
        address servicer,
        address collateralManager,
        address collateralToken,
        uint256 amount
    );
    event TermFinanceCollateralUnlocked(
        address version,
        address servicer,
        address collateralManager,
        address collateralToken,
        uint256 amount
    );

    uint256 internal constant MARKET_ID = 52;
    address internal constant WITHDRAW_MANAGER = address(0xBEEF);

    TermFinanceCollateralFuseHarness internal harness;
    MockTermController internal controller;
    MockTermRepoServicer internal servicer;
    MockTermRepoCollateralManager internal collateralManager;
    MockTermRepoLocker internal termRepoLocker;
    MockERC20Decimals internal collateralToken;

    function setUp() public {
        controller = new MockTermController();
        harness = new TermFinanceCollateralFuseHarness(MARKET_ID, address(controller));

        collateralToken = new MockERC20Decimals("Collateral", "COL", 18);
        servicer = new MockTermRepoServicer();
        collateralManager = new MockTermRepoCollateralManager();
        termRepoLocker = new MockTermRepoLocker();

        // Wire the Term-side pairing: servicer points to collateralManager and termRepoLocker.
        servicer.setTermRepoLocker(address(termRepoLocker));
        servicer.setTermRepoCollateralManager(address(collateralManager));
        collateralManager.setTermRepoLocker(address(termRepoLocker));

        // Configure the manager's accepted-collateral list.
        address[] memory acceptedTokens = new address[](1);
        acceptedTokens[0] = address(collateralToken);
        collateralManager.setAcceptedTokens(acceptedTokens);

        // Mark the servicer as deployed in the Term Finance controller.
        controller.setIsTermDeployed(address(servicer), true);

        // Grant both SERVICER and COLLATERAL_TOKEN substrates on the vault side.
        bytes32[] memory subs = new bytes32[](2);
        subs[0] = PlasmaVaultConfigLib.addressToBytes32(address(servicer));
        subs[1] = TermFinanceSubstrateLib.collateralPairKey(address(servicer), address(collateralToken));
        harness.setMarketSubstrates(MARKET_ID, subs);

        // Provision the harness's WithdrawManager slot so `_assertWithdrawManagerSet()` passes by default.
        _setWithdrawManager(WITHDRAW_MANAGER);

        // Fund the vault (harness) with collateral so the lock pull succeeds.
        collateralToken.mint(address(harness), 100e18);
    }

    // ---------- helpers ----------

    /// @notice Direct-poke the WithdrawManager slot of the harness so the runtime check
    ///         resolves correctly. Mirrors the `vm.store` pattern in
    ///         `PlasmaVaultRequestSharesTest._setUp` (storage layout note).
    function _setWithdrawManager(address manager_) internal {
        vm.store(address(harness), WITHDRAW_MANAGER_SLOT, bytes32(uint256(uint160(manager_))));
    }

    function _enterData(
        uint256 amount_
    ) internal view returns (TermFinanceCollateralFuseEnterData memory) {
        return TermFinanceCollateralFuseEnterData({
            servicer: address(servicer),
            collateralManager: address(collateralManager),
            collateralToken: address(collateralToken),
            amount: amount_
        });
    }

    function _exitData(uint256 amount_) internal view returns (TermFinanceCollateralFuseExitData memory) {
        return TermFinanceCollateralFuseExitData({
            servicer: address(servicer),
            collateralManager: address(collateralManager),
            collateralToken: address(collateralToken),
            amount: amount_
        });
    }

    function _setupLockedPosition(uint256 amount_) internal {
        // Lock first so an unlock has something to remove. The mock locker holds the pulled
        // collateral; the manager pushes it back via `MockTermRepoLocker.transferTokenToWallet`
        // on exit, so no extra approval choreography is needed.
        harness.enter(_enterData(amount_));
    }

    // ============ constructor ============

    function test_constructor_setsImmutables() public view {
        assertEq(harness.MARKET_ID(), MARKET_ID);
        assertEq(harness.TERM_CONTROLLER(), address(controller));
        assertEq(harness.VERSION(), address(harness));
    }

    function test_constructor_revertsOnZeroMarketId() public {
        vm.expectRevert(Errors.WrongValue.selector);
        new TermFinanceCollateralFuseHarness(0, address(controller));
    }

    function test_constructor_revertsOnZeroController() public {
        vm.expectRevert(Errors.WrongAddress.selector);
        new TermFinanceCollateralFuseHarness(MARKET_ID, address(0));
    }

    /// @notice Regression test — the WithdrawManager check MUST live in `enter` / `exit`,
    ///         NOT the constructor. An earlier plan draft put the check in the constructor; that
    ///         would have read empty deployer-EOA storage at deployment time and unconditionally
    ///         reverted. Asserting that fresh construction succeeds even when the deployer has no
    ///         WithdrawManager-shaped slot codifies the step 0 invariant.
    function testCollateralConstructorDoesNotRevertOutsideDelegatecall() public {
        // Build fresh — no `vm.store` for WithdrawManager. Constructor must NOT call
        // `_assertWithdrawManagerSet()`.
        TermFinanceCollateralFuseHarness freshHarness = new TermFinanceCollateralFuseHarness(
            MARKET_ID,
            address(controller)
        );
        assertEq(freshHarness.MARKET_ID(), MARKET_ID);
        assertEq(freshHarness.TERM_CONTROLLER(), address(controller));
    }

    // ============ enter — happy path ============

    function testEnterShouldLockCollateral() public {
        uint256 amount = 10e18;
        uint256 lockerBalanceBefore = collateralToken.balanceOf(address(termRepoLocker));
        uint256 vaultBalanceBefore = collateralToken.balanceOf(address(harness));

        vm.expectEmit(true, true, true, true);
        emit TermFinanceCollateralLocked(
            address(harness),
            address(servicer),
            address(collateralManager),
            address(collateralToken),
            amount
        );
        harness.enter(_enterData(amount));

        assertEq(
            collateralManager.getCollateralBalance(address(harness), address(collateralToken)),
            amount,
            "manager records borrower collateral balance"
        );
        assertEq(
            collateralToken.balanceOf(address(termRepoLocker)),
            lockerBalanceBefore + amount,
            "tokens land in locker"
        );
        assertEq(
            collateralToken.balanceOf(address(harness)),
            vaultBalanceBefore - amount,
            "vault balance decreases by the locked amount"
        );
    }

    function testEnterShouldClearApprovalAfterLock() public {
        uint256 amount = 7e18;
        harness.enter(_enterData(amount));

        assertEq(
            collateralToken.allowance(address(harness), address(termRepoLocker)),
            0,
            "termRepoLocker allowance reset to zero after lock"
        );
        // Also assert we never approved the collateralManager — approval target is the locker, NOT the manager.
        assertEq(
            collateralToken.allowance(address(harness), address(collateralManager)),
            0,
            "must not approve collateralManager (approval target is termRepoLocker)"
        );
    }

    /// @notice Edge case: when the manager doesn't actually pull collateral on lock (defensive
    ///         design hardening — e.g. a future Term Finance impl that partial-pulls), the fuse's
    ///         explicit `forceApprove(termRepoLocker, 0)` post-call MUST still leave allowance == 0
    ///         to prevent leaked approvals.
    function testEnterShouldZeroApprovalEvenWhenManagerDoesNotPullFunds() public {
        collateralManager.setSkipPull(true);
        uint256 amount = 3e18;
        harness.enter(_enterData(amount));

        assertEq(
            collateralToken.allowance(address(harness), address(termRepoLocker)),
            0,
            "approval reset to zero even when manager skips the pull"
        );
    }

    // ============ exit — happy path ============

    function testExitShouldUnlockCollateral() public {
        uint256 lockAmount = 10e18;
        _setupLockedPosition(lockAmount);

        uint256 vaultBalanceBeforeExit = collateralToken.balanceOf(address(harness));
        uint256 lockerBalanceBeforeExit = collateralToken.balanceOf(address(termRepoLocker));

        vm.expectEmit(true, true, true, true);
        emit TermFinanceCollateralUnlocked(
            address(harness),
            address(servicer),
            address(collateralManager),
            address(collateralToken),
            lockAmount
        );
        harness.exit(_exitData(lockAmount));

        assertEq(
            collateralManager.getCollateralBalance(address(harness), address(collateralToken)),
            0,
            "manager records zero collateral after full unlock"
        );
        assertEq(
            collateralToken.balanceOf(address(harness)),
            vaultBalanceBeforeExit + lockAmount,
            "tokens flowed back to the vault"
        );
        assertEq(
            collateralToken.balanceOf(address(termRepoLocker)),
            lockerBalanceBeforeExit - lockAmount,
            "locker drained by the unlock amount"
        );
    }

    // ============ WithdrawManager runtime check ============

    function testEnterShouldRevertWhenWithdrawManagerIsZero() public {
        // Wipe the WithdrawManager so the runtime check fails.
        _setWithdrawManager(address(0));

        vm.expectRevert(TermFinanceCollateralFuse.TermFinanceCollateralFuseWithdrawManagerRequired.selector);
        harness.enter(_enterData(1e18));
    }

    function testExitShouldRevertWhenWithdrawManagerIsZero() public {
        _setWithdrawManager(address(0));

        vm.expectRevert(TermFinanceCollateralFuse.TermFinanceCollateralFuseWithdrawManagerRequired.selector);
        harness.exit(_exitData(1e18));
    }

    /// @notice Ordering verification: even when
    ///         OTHER validations would also fail, the WithdrawManager check MUST be reported
    ///         first because it is the FIRST statement of `enter` / `exit`.
    function testEnterShouldCheckWithdrawManagerBeforeOtherValidation() public {
        _setWithdrawManager(address(0));
        // Wipe substrates so substrate validation would ALSO fail. Expect the
        // WithdrawManager selector, not `UnsupportedMarket`.
        bytes32[] memory empty = new bytes32[](0);
        harness.setMarketSubstrates(MARKET_ID, empty);

        vm.expectRevert(TermFinanceCollateralFuse.TermFinanceCollateralFuseWithdrawManagerRequired.selector);
        harness.enter(_enterData(1e18));
    }

    // ============ TermController.isTermDeployed guard ============

    function testEnterShouldRevertWhenTermNotDeployed() public {
        controller.setIsTermDeployed(address(servicer), false);

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceCollateralFuse.TermFinanceCollateralFuseTermNotDeployed.selector,
                address(servicer)
            )
        );
        harness.enter(_enterData(1e18));
    }

    function testExitShouldRevertWhenTermNotDeployed() public {
        controller.setIsTermDeployed(address(servicer), false);

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceCollateralFuse.TermFinanceCollateralFuseTermNotDeployed.selector,
                address(servicer)
            )
        );
        harness.exit(_exitData(1e18));
    }

    // ============ Substrate validation ============

    function testEnterShouldRevertWhenServicerSubstrateNotGranted() public {
        // Drop both substrates so even the servicer check fails.
        bytes32[] memory empty = new bytes32[](0);
        harness.setMarketSubstrates(MARKET_ID, empty);

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceCollateralFuse.TermFinanceCollateralFuseUnsupportedMarket.selector,
                address(servicer)
            )
        );
        harness.enter(_enterData(1e18));
    }

    function testEnterShouldRevertWhenCollateralTokenSubstrateNotGranted() public {
        // Re-grant ONLY the servicer substrate; drop the (servicer, token) pair substrate.
        bytes32[] memory subs = new bytes32[](1);
        subs[0] = PlasmaVaultConfigLib.addressToBytes32(address(servicer));
        harness.setMarketSubstrates(MARKET_ID, subs);

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceCollateralFuse.TermFinanceCollateralFuseUnsupportedCollateralToken.selector,
                address(collateralToken)
            )
        );
        harness.enter(_enterData(1e18));
    }

    function testExitShouldRevertWhenServicerSubstrateNotGranted() public {
        bytes32[] memory empty = new bytes32[](0);
        harness.setMarketSubstrates(MARKET_ID, empty);

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceCollateralFuse.TermFinanceCollateralFuseUnsupportedMarket.selector,
                address(servicer)
            )
        );
        harness.exit(_exitData(1e18));
    }

    function testExitShouldRevertWhenCollateralTokenSubstrateNotGranted() public {
        bytes32[] memory subs = new bytes32[](1);
        subs[0] = PlasmaVaultConfigLib.addressToBytes32(address(servicer));
        harness.setMarketSubstrates(MARKET_ID, subs);

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceCollateralFuse.TermFinanceCollateralFuseUnsupportedCollateralToken.selector,
                address(collateralToken)
            )
        );
        harness.exit(_exitData(1e18));
    }

    // ============ Servicer ⇄ CollateralManager pairing guard ============

    function testEnterShouldRevertWhenServicerCollateralManagerMismatch() public {
        // Re-wire the servicer to point at a DIFFERENT manager than what we pass in calldata.
        MockTermRepoCollateralManager rogueManager = new MockTermRepoCollateralManager();
        servicer.setTermRepoCollateralManager(address(rogueManager));

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceCollateralFuse.TermFinanceCollateralFuseServicerCollateralManagerMismatch.selector,
                address(servicer),
                address(rogueManager),
                address(collateralManager)
            )
        );
        harness.enter(_enterData(1e18));
    }

    function testExitShouldRevertWhenServicerCollateralManagerMismatch() public {
        MockTermRepoCollateralManager rogueManager = new MockTermRepoCollateralManager();
        servicer.setTermRepoCollateralManager(address(rogueManager));

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceCollateralFuse.TermFinanceCollateralFuseServicerCollateralManagerMismatch.selector,
                address(servicer),
                address(rogueManager),
                address(collateralManager)
            )
        );
        harness.exit(_exitData(1e18));
    }

    // ============ CollateralManager accepted-token guard ============

    function testEnterShouldRevertWhenCollateralTokenNotAcceptedByManager() public {
        // Reconfigure manager to drop the collateral from its accepted list. Keep substrates
        // unchanged so the per-token defense-in-depth check is reached.
        address[] memory emptyTokens = new address[](0);
        collateralManager.setAcceptedTokens(emptyTokens);

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceCollateralFuse.TermFinanceCollateralFuseCollateralTokenNotAccepted.selector,
                address(collateralManager),
                address(collateralToken)
            )
        );
        harness.enter(_enterData(1e18));
    }

    function testEnterShouldAcceptAnyTokenInAcceptedListNotJustFirst() public {
        // Add multiple accepted tokens with our target at position 2 (non-first index) — verifies
        // the loop in `_assertCollateralTokenAccepted` iterates through `numOfAcceptedCollateralTokens`.
        address tokenA = makeAddr("tokenA");
        address tokenB = makeAddr("tokenB");
        address[] memory acceptedTokens = new address[](3);
        acceptedTokens[0] = tokenA;
        acceptedTokens[1] = tokenB;
        acceptedTokens[2] = address(collateralToken);
        collateralManager.setAcceptedTokens(acceptedTokens);

        // Should not revert on the accepted-token check.
        harness.enter(_enterData(1e18));
        assertEq(
            collateralManager.getCollateralBalance(address(harness), address(collateralToken)),
            1e18
        );
    }

    function testExitShouldRevertWhenCollateralTokenNotAcceptedByManager() public {
        address[] memory emptyTokens = new address[](0);
        collateralManager.setAcceptedTokens(emptyTokens);

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceCollateralFuse.TermFinanceCollateralFuseCollateralTokenNotAccepted.selector,
                address(collateralManager),
                address(collateralToken)
            )
        );
        harness.exit(_exitData(1e18));
    }

    // ============ Zero amount ============

    function testEnterShouldRevertWhenAmountIsZero() public {
        vm.expectRevert(TermFinanceCollateralFuse.TermFinanceCollateralFuseZeroAmount.selector);
        harness.enter(_enterData(0));
    }

    function testExitShouldRevertWhenAmountIsZero() public {
        vm.expectRevert(TermFinanceCollateralFuse.TermFinanceCollateralFuseZeroAmount.selector);
        harness.exit(_exitData(0));
    }

    // ============ Edge cases ============

    /// @notice When the vault is underfunded relative to the lock amount, the ERC20 pull inside
    ///         `externalLockCollateral` must propagate (OZ ERC20 `transferFrom` reverts with
    ///         `ERC20InsufficientBalance`). The fuse itself does NOT pre-check the balance — the
    ///         underlying transfer is the source of truth, which keeps the fuse minimal.
    function testEnterShouldRevertWhenAmountExceedsBalance() public {
        uint256 balance = collateralToken.balanceOf(address(harness));
        // Any revert from the underlying ERC20 (OZ uses a custom error here in 5.x).
        vm.expectRevert();
        harness.enter(_enterData(balance + 1));
    }

    /// @notice The mock manager rejects unlocking more than the locked amount with a
    ///         human-readable string. In production this is the Term Repo collateral maintenance
    ///         guard reverting. The fuse passes the call through faithfully.
    function testExitShouldRevertWhenAmountExceedsLockedAmount() public {
        uint256 lockAmount = 5e18;
        _setupLockedPosition(lockAmount);

        vm.expectRevert(bytes("MockCollateralManager: amount exceeds locked"));
        harness.exit(_exitData(lockAmount + 1));
    }

    /// @notice Defensive coverage: a revert from the manager during `externalLockCollateral`
    ///         (e.g. Term Finance's own collateral-cap or pause guard) must bubble up unchanged
    ///         to the caller. The fuse does not wrap or absorb such failures.
    function testEnterShouldPropagateRevertFromManager() public {
        collateralManager.setLockReverts(true);
        vm.expectRevert(bytes("MockCollateralManager: externalLockCollateral reverts"));
        harness.enter(_enterData(1e18));
    }

    function testExitShouldPropagateRevertFromManager() public {
        _setupLockedPosition(1e18);
        collateralManager.setUnlockReverts(true);
        vm.expectRevert(bytes("MockCollateralManager: externalUnlockCollateral reverts"));
        harness.exit(_exitData(1e18));
    }
}
