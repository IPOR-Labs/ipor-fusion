// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {Errors} from "contracts/libraries/errors/Errors.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {
    TermFinanceRedeemFuse,
    TermFinanceRedeemFuseEnterData
} from "contracts/fuses/term_finance/TermFinanceRedeemFuse.sol";

import {TermFinanceRedeemFuseHarness} from "./mocks/TermFinanceRedeemFuseHarness.sol";
import {MockERC20Decimals} from "./mocks/MockERC20Decimals.sol";
import {MockTermController} from "./mocks/MockTermController.sol";
import {MockTermRepoServicer} from "./mocks/MockTermRepoServicer.sol";
import {MockTermRepoToken} from "./mocks/MockTermRepoToken.sol";

contract TermFinanceRedeemFuseTest is Test {
    /// @dev Local copy of fuse event for `vm.expectEmit` assertions.
    event TermFinanceRedeemed(
        address version,
        address servicer,
        uint256 amountToRedeem,
        uint256 purchaseTokenReceived
    );

    uint256 internal constant MARKET_ID = 52;

    /// @dev Canonical WithdrawManager ERC-7201 slot — mirrors `PlasmaVaultStorageLib`'s
    ///      `WITHDRAW_MANAGER` constant (private there).
    bytes32 internal constant WITHDRAW_MANAGER_SLOT =
        0x465d2ff0062318fe6f4c7e9ac78cfcd70bc86a1d992722875ef83a9770513100;

    /// @dev Sentinel WithdrawManager address — any non-zero value satisfies the guard.
    address internal constant WITHDRAW_MANAGER = address(0xCAFE);

    TermFinanceRedeemFuseHarness harness;
    MockTermController controller;
    MockTermRepoServicer servicer;
    MockTermRepoToken repoToken;
    MockERC20Decimals usdc;
    address termRepoLocker;

    function setUp() public {
        controller = new MockTermController();
        harness = new TermFinanceRedeemFuseHarness(MARKET_ID, address(controller));

        servicer = new MockTermRepoServicer();
        repoToken = new MockTermRepoToken("TR", "TR", 6);
        usdc = new MockERC20Decimals("USDC", "USDC", 6);
        termRepoLocker = makeAddr("termRepoLocker");

        servicer.setTermRepoToken(address(repoToken));
        servicer.setTermRepoLocker(termRepoLocker);
        servicer.setPurchaseToken(address(usdc));
        servicer.setShortfallHaircutMantissa(0);
        controller.setIsTermDeployed(address(servicer), true);

        bytes32[] memory subs = new bytes32[](1);
        subs[0] = PlasmaVaultConfigLib.addressToBytes32(address(servicer));
        harness.setMarketSubstrates(MARKET_ID, subs);

        // Default: WithdrawManager is configured (invariant satisfied).
        _setWithdrawManager(WITHDRAW_MANAGER);
    }

    function _setWithdrawManager(address manager_) internal {
        vm.store(address(harness), WITHDRAW_MANAGER_SLOT, bytes32(uint256(uint160(manager_))));
    }

    function _clearWithdrawManagerSlot() internal {
        _setWithdrawManager(address(0));
    }

    function _setupVaultWithRepoToken(uint256 amount_) internal {
        repoToken.mint(address(harness), amount_);
        // Fund termRepoLocker with USDC for payout; servicer pulls via transferFrom.
        usdc.mint(termRepoLocker, amount_);
        vm.prank(termRepoLocker);
        usdc.approve(address(servicer), type(uint256).max);
    }

    function _data(uint256 amt_) internal view returns (TermFinanceRedeemFuseEnterData memory) {
        return TermFinanceRedeemFuseEnterData({servicer: address(servicer), amountToRedeem: amt_});
    }

    // ============ constructor ============

    function test_constructor_setsImmutables() public view {
        assertEq(harness.MARKET_ID(), MARKET_ID);
        assertEq(harness.TERM_CONTROLLER(), address(controller));
    }

    function test_constructor_revertsOnZeroMarketId() public {
        vm.expectRevert(Errors.WrongValue.selector);
        new TermFinanceRedeemFuseHarness(0, address(controller));
    }

    function test_constructor_revertsOnZeroController() public {
        vm.expectRevert(Errors.WrongAddress.selector);
        new TermFinanceRedeemFuseHarness(MARKET_ID, address(0));
    }

    // ============ enter — happy path ============

    function test_enter_happyPath_redeemsFullAmount() public {
        uint256 amt = 1_000_000;
        _setupVaultWithRepoToken(amt);

        servicer.setRedemptionTimestamp(block.timestamp);
        vm.warp(block.timestamp + 1);

        // Assert full event payload (no haircut → receives full amount).
        vm.expectEmit(true, true, true, true);
        emit TermFinanceRedeemed(address(harness), address(servicer), amt, amt);
        harness.enter(_data(amt));

        assertEq(repoToken.balanceOf(address(harness)), 0, "repoToken burned");
        assertEq(usdc.balanceOf(address(harness)), amt, "received purchase token");
    }

    function test_enter_happyPath_withHaircut_receivesReduced() public {
        uint256 amt = 1_000_000;
        _setupVaultWithRepoToken(amt);

        servicer.setRedemptionTimestamp(block.timestamp);
        servicer.setShortfallHaircutMantissa(3e16); // 3%
        vm.warp(block.timestamp + 1);

        harness.enter(_data(amt));

        uint256 expected = (amt * (1e18 - 3e16)) / 1e18;
        assertEq(usdc.balanceOf(address(harness)), expected);
    }

    // ============ enter — guards ============

    function test_enter_revertsOnSubstrateNotGranted() public {
        bytes32[] memory empty = new bytes32[](0);
        harness.setMarketSubstrates(MARKET_ID, empty);

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceRedeemFuse.TermFinanceRedeemFuseUnsupportedMarket.selector,
                address(servicer)
            )
        );
        harness.enter(_data(1_000_000));
    }

    function test_enter_revertsOnControllerNotDeployed() public {
        controller.setIsTermDeployed(address(servicer), false);
        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceRedeemFuse.TermFinanceRedeemFuseTermNotDeployed.selector,
                address(servicer)
            )
        );
        harness.enter(_data(1_000_000));
    }

    function test_enter_revertsOnZeroAmount() public {
        vm.expectRevert(TermFinanceRedeemFuse.TermFinanceRedeemFuseZeroAmount.selector);
        harness.enter(_data(0));
    }

    function test_enter_revertsOnTooEarly() public {
        servicer.setRedemptionTimestamp(block.timestamp + 1 days);

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceRedeemFuse.TermFinanceRedeemFuseTooEarly.selector,
                address(servicer),
                block.timestamp + 1 days
            )
        );
        harness.enter(_data(1_000_000));
    }

    // ============ WithdrawManager runtime check ============

    function test_enter_revertsWhenWithdrawManagerNotSet() public {
        _clearWithdrawManagerSlot();

        vm.expectRevert(TermFinanceRedeemFuse.TermFinanceRedeemFuseWithdrawManagerRequired.selector);
        harness.enter(_data(1_000_000));
    }

    /// @notice Ordering: WithdrawManager check runs FIRST, before the substrate allowlist
    ///         check (which would otherwise revert with `UnsupportedMarket`). With both
    ///         invariants broken, the revert must be the WithdrawManager selector — proving
    ///         a single-position reorder would be caught.
    function testEnterShouldCheckWithdrawManagerBeforeOtherValidation() public {
        bytes32[] memory empty = new bytes32[](0);
        harness.setMarketSubstrates(MARKET_ID, empty);
        _clearWithdrawManagerSlot();

        vm.expectRevert(TermFinanceRedeemFuse.TermFinanceRedeemFuseWithdrawManagerRequired.selector);
        harness.enter(_data(1_000_000));
    }
}
