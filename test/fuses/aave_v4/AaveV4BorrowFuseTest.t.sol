// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {AaveV4SubstrateLib} from "../../../contracts/fuses/aave_v4/AaveV4SubstrateLib.sol";
import {
    AaveV4BorrowFuse,
    AaveV4BorrowFuseEnterData,
    AaveV4BorrowFuseExitData
} from "../../../contracts/fuses/aave_v4/AaveV4BorrowFuse.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";
import {MockAaveV4Spoke} from "./MockAaveV4Spoke.sol";
import {ERC20Mock} from "./ERC20Mock.sol";

/// @title AaveV4BorrowFuseTest
/// @notice Tests for AaveV4BorrowFuse contract
contract AaveV4BorrowFuseTest is Test {
    uint256 public constant MARKET_ID = 49;
    uint256 public constant RESERVE_ID = 1;

    AaveV4BorrowFuse public borrowFuse;
    PlasmaVaultMock public vaultMock;
    MockAaveV4Spoke public spoke;
    ERC20Mock public token;

    function setUp() public {
        // Deploy contracts
        borrowFuse = new AaveV4BorrowFuse(MARKET_ID);
        spoke = new MockAaveV4Spoke();
        token = new ERC20Mock("Test Token", "TST", 18);

        // Configure mock spoke
        spoke.addReserve(RESERVE_ID, address(token));

        // Fund spoke with tokens for borrows
        token.mint(address(spoke), 10_000_000e18);

        // Use borrowFuse as the main fuse in mock; reserve granted as borrowable
        vaultMock = new PlasmaVaultMock(address(borrowFuse), address(0));
        _grant(AaveV4SubstrateLib.encodeReserve(address(spoke), RESERVE_ID, false, true));

        // Label
        vm.label(address(borrowFuse), "AaveV4BorrowFuse");
        vm.label(address(vaultMock), "PlasmaVaultMock");
        vm.label(address(spoke), "MockAaveV4Spoke");
        vm.label(address(token), "TestToken");
    }

    // ============ Constructor Tests ============

    function testShouldDeployWithValidMarketId() public view {
        assertEq(borrowFuse.VERSION(), address(borrowFuse));
        assertEq(borrowFuse.MARKET_ID(), MARKET_ID);
    }

    function testShouldRevertWhenMarketIdIsZero() public {
        vm.expectRevert(AaveV4BorrowFuse.AaveV4BorrowFuseInvalidMarketId.selector);
        new AaveV4BorrowFuse(0);
    }

    // ============ Enter (Borrow) Tests ============

    function testShouldBeAbleToBorrow() public {
        // given
        uint256 borrowAmount = 1_000e18;
        uint256 balanceBefore = token.balanceOf(address(vaultMock));

        // when
        vaultMock.enterAaveV4Borrow(_enterData(address(spoke), address(token), RESERVE_ID, borrowAmount, 0));

        // then
        uint256 balanceAfter = token.balanceOf(address(vaultMock));
        assertEq(balanceAfter - balanceBefore, borrowAmount, "Vault should receive borrowed tokens");

        uint256 debt = spoke.getUserTotalDebt(RESERVE_ID, address(vaultMock));
        assertEq(debt, borrowAmount, "Debt should equal amount");

        (, bool borrowing) = spoke.getUserReserveStatus(RESERVE_ID, address(vaultMock));
        assertTrue(borrowing);
    }

    function testShouldReturnEarlyWhenBorrowAmountIsZero() public {
        // when - no revert
        vaultMock.enterAaveV4Borrow(_enterData(address(spoke), address(token), RESERVE_ID, 0, 0));

        // then
        uint256 debt = spoke.getUserTotalDebt(RESERVE_ID, address(vaultMock));
        assertEq(debt, 0);
    }

    function testShouldRevertWhenReserveNotGrantedOnBorrow() public {
        // given - reserve 2 listed but not granted
        uint256 ungrantedReserveId = 2;
        spoke.addReserve(ungrantedReserveId, address(token));

        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4BorrowFuse.AaveV4BorrowFuseUnsupportedSubstrate.selector,
                "enter",
                address(spoke),
                ungrantedReserveId
            )
        );
        vaultMock.enterAaveV4Borrow(_enterData(address(spoke), address(token), ungrantedReserveId, 100e18, 0));
    }

    function testShouldRevertWhenSpokeNotGrantedOnBorrow() public {
        // given
        MockAaveV4Spoke ungrantedSpoke = new MockAaveV4Spoke();
        ungrantedSpoke.addReserve(RESERVE_ID, address(token));

        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4BorrowFuse.AaveV4BorrowFuseUnsupportedSubstrate.selector,
                "enter",
                address(ungrantedSpoke),
                RESERVE_ID
            )
        );
        vaultMock.enterAaveV4Borrow(_enterData(address(ungrantedSpoke), address(token), RESERVE_ID, 100e18, 0));
    }

    function testShouldRevertWhenGrantLacksCanBorrow() public {
        // given - reserve granted as collateral only
        _grant(AaveV4SubstrateLib.encodeReserve(address(spoke), RESERVE_ID, true, false));

        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4BorrowFuse.AaveV4BorrowFuseUnsupportedSubstrate.selector,
                "enter",
                address(spoke),
                RESERVE_ID
            )
        );
        vaultMock.enterAaveV4Borrow(_enterData(address(spoke), address(token), RESERVE_ID, 100e18, 0));
    }

    function testShouldBorrowWhenGrantHasBothFlags() public {
        _grant(AaveV4SubstrateLib.encodeReserve(address(spoke), RESERVE_ID, true, true));

        vaultMock.enterAaveV4Borrow(_enterData(address(spoke), address(token), RESERVE_ID, 100e18, 0));

        assertEq(spoke.getUserTotalDebt(RESERVE_ID, address(vaultMock)), 100e18);
    }

    function testShouldDistinguishTwoBorrowableReservesOfSameAsset() public {
        // given - same underlying twice on one spoke (USDC via Prime / Core hub); only reserve 2 borrowable
        uint256 duplicateReserveId = 2;
        spoke.addReserve(duplicateReserveId, address(token));
        _grant(AaveV4SubstrateLib.encodeReserve(address(spoke), duplicateReserveId, false, true));

        // when/then - reserve 1 rejected
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4BorrowFuse.AaveV4BorrowFuseUnsupportedSubstrate.selector,
                "enter",
                address(spoke),
                RESERVE_ID
            )
        );
        vaultMock.enterAaveV4Borrow(_enterData(address(spoke), address(token), RESERVE_ID, 100e18, 0));

        // reserve 2 works
        vaultMock.enterAaveV4Borrow(_enterData(address(spoke), address(token), duplicateReserveId, 100e18, 0));
        assertEq(spoke.getUserTotalDebt(duplicateReserveId, address(vaultMock)), 100e18);
        assertEq(spoke.getUserTotalDebt(RESERVE_ID, address(vaultMock)), 0);
    }

    function testShouldEmitEnterEvent() public {
        // given
        uint256 amount = 500e18;

        // when/then
        vm.expectEmit(false, false, false, true);
        emit AaveV4BorrowFuse.AaveV4BorrowFuseEnter(
            address(borrowFuse),
            address(spoke),
            address(token),
            RESERVE_ID,
            amount,
            amount // shares == amount in 1:1 mock
        );
        vaultMock.enterAaveV4Borrow(_enterData(address(spoke), address(token), RESERVE_ID, amount, 0));
    }

    // ============ Exit (Repay) Tests ============

    function testShouldBeAbleToRepay() public {
        // given - borrow first
        uint256 borrowAmount = 1_000e18;
        vaultMock.enterAaveV4Borrow(_enterData(address(spoke), address(token), RESERVE_ID, borrowAmount, 0));

        // when - repay
        vaultMock.exitAaveV4Borrow(_exitData(address(spoke), address(token), RESERVE_ID, borrowAmount, 0));

        // then
        uint256 debt = spoke.getUserTotalDebt(RESERVE_ID, address(vaultMock));
        assertEq(debt, 0, "Debt should be zero after full repay");

        (, bool borrowing) = spoke.getUserReserveStatus(RESERVE_ID, address(vaultMock));
        assertFalse(borrowing);
    }

    function testShouldRepayWithMaxAmountCappedAtDebtAndBalance() public {
        // given - borrow 1000, hold 1500 in the vault
        uint256 borrowAmount = 1_000e18;
        vaultMock.enterAaveV4Borrow(_enterData(address(spoke), address(token), RESERVE_ID, borrowAmount, 0));
        token.mint(address(vaultMock), 500e18);

        // when - repay "everything"
        vaultMock.exitAaveV4Borrow(_exitData(address(spoke), address(token), RESERVE_ID, type(uint256).max, 0));

        // then - debt cleared, surplus stays in the vault
        assertEq(spoke.getUserTotalDebt(RESERVE_ID, address(vaultMock)), 0);
        assertEq(token.balanceOf(address(vaultMock)), 500e18);
    }

    function testShouldReturnEarlyWhenRepayAmountIsZero() public {
        // given - borrow first
        uint256 borrowAmount = 1_000e18;
        vaultMock.enterAaveV4Borrow(_enterData(address(spoke), address(token), RESERVE_ID, borrowAmount, 0));

        // when - repay 0
        vaultMock.exitAaveV4Borrow(_exitData(address(spoke), address(token), RESERVE_ID, 0, 0));

        // then
        uint256 debt = spoke.getUserTotalDebt(RESERVE_ID, address(vaultMock));
        assertEq(debt, borrowAmount, "Debt should not change");
    }

    function testShouldRepayMinOfBalanceAndAmount() public {
        // given - borrow 1000 but only keep 500
        uint256 borrowAmount = 1_000e18;
        vaultMock.enterAaveV4Borrow(_enterData(address(spoke), address(token), RESERVE_ID, borrowAmount, 0));

        // Burn half the tokens from vault (simulating partial balance)
        uint256 vaultBalance = token.balanceOf(address(vaultMock));
        vm.prank(address(vaultMock));
        token.transfer(address(1), vaultBalance / 2);

        uint256 currentBalance = token.balanceOf(address(vaultMock));

        // when - try to repay full amount
        vaultMock.exitAaveV4Borrow(_exitData(address(spoke), address(token), RESERVE_ID, borrowAmount, 0));

        // then - only partial repay
        uint256 debt = spoke.getUserTotalDebt(RESERVE_ID, address(vaultMock));
        assertEq(debt, borrowAmount - currentBalance, "Should repay only available balance");
    }

    function testShouldRepayWhenGrantLacksCanBorrow() public {
        // given - borrow, then the atomist revokes canBorrow (keeps plain grant)
        uint256 borrowAmount = 1_000e18;
        vaultMock.enterAaveV4Borrow(_enterData(address(spoke), address(token), RESERVE_ID, borrowAmount, 0));
        _grant(AaveV4SubstrateLib.encodeReserve(address(spoke), RESERVE_ID, false, false));

        // when - repaying (de-risking) must still work
        vaultMock.exitAaveV4Borrow(_exitData(address(spoke), address(token), RESERVE_ID, borrowAmount, 0));

        // then
        assertEq(spoke.getUserTotalDebt(RESERVE_ID, address(vaultMock)), 0);

        // and borrowing again is rejected
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4BorrowFuse.AaveV4BorrowFuseUnsupportedSubstrate.selector,
                "enter",
                address(spoke),
                RESERVE_ID
            )
        );
        vaultMock.enterAaveV4Borrow(_enterData(address(spoke), address(token), RESERVE_ID, 1e18, 0));
    }

    function testShouldEmitExitEvent() public {
        // given - borrow first
        uint256 amount = 500e18;
        vaultMock.enterAaveV4Borrow(_enterData(address(spoke), address(token), RESERVE_ID, amount, 0));

        // when/then
        vm.expectEmit(false, false, false, true);
        emit AaveV4BorrowFuse.AaveV4BorrowFuseExit(
            address(borrowFuse),
            address(spoke),
            address(token),
            RESERVE_ID,
            amount,
            amount // sharesRepaid == amount in 1:1 mock
        );
        vaultMock.exitAaveV4Borrow(_exitData(address(spoke), address(token), RESERVE_ID, amount, 0));
    }

    function testShouldApproveBeforeRepay() public {
        // given - borrow first
        uint256 amount = 500e18;
        vaultMock.enterAaveV4Borrow(_enterData(address(spoke), address(token), RESERVE_ID, amount, 0));

        // when - repay (forceApprove is called internally)
        vaultMock.exitAaveV4Borrow(_exitData(address(spoke), address(token), RESERVE_ID, amount, 0));

        // then - repay succeeded (would have failed without approval)
        uint256 debt = spoke.getUserTotalDebt(RESERVE_ID, address(vaultMock));
        assertEq(debt, 0);
    }

    // ============ Transient Storage Tests ============

    function testShouldEnterTransient() public {
        // given
        uint256 amount = 500e18;

        bytes32[] memory inputs = new bytes32[](5);
        inputs[0] = bytes32(uint256(uint160(address(spoke))));
        inputs[1] = bytes32(uint256(uint160(address(token))));
        inputs[2] = bytes32(RESERVE_ID);
        inputs[3] = bytes32(amount);
        inputs[4] = bytes32(uint256(0)); // minShares

        vaultMock.setInputs(address(borrowFuse), inputs);

        // when
        vaultMock.enterAaveV4BorrowTransient();

        // then
        uint256 debt = spoke.getUserTotalDebt(RESERVE_ID, address(vaultMock));
        assertEq(debt, amount, "Borrow should succeed via transient storage");

        bytes32[] memory outputs = vaultMock.getOutputs(address(borrowFuse));
        assertEq(outputs.length, 2);
        assertEq(address(uint160(uint256(outputs[0]))), address(token));
        assertEq(uint256(outputs[1]), amount);
    }

    function testShouldExitTransient() public {
        // given - borrow first
        uint256 amount = 500e18;
        vaultMock.enterAaveV4Borrow(_enterData(address(spoke), address(token), RESERVE_ID, amount, 0));

        bytes32[] memory inputs = new bytes32[](5);
        inputs[0] = bytes32(uint256(uint160(address(spoke))));
        inputs[1] = bytes32(uint256(uint160(address(token))));
        inputs[2] = bytes32(RESERVE_ID);
        inputs[3] = bytes32(amount);
        inputs[4] = bytes32(uint256(0)); // minSharesRepaid

        vaultMock.setInputs(address(borrowFuse), inputs);

        // when
        vaultMock.exitAaveV4BorrowTransient();

        // then
        uint256 debt = spoke.getUserTotalDebt(RESERVE_ID, address(vaultMock));
        assertEq(debt, 0, "All debt should be repaid via transient exit");

        bytes32[] memory outputs = vaultMock.getOutputs(address(borrowFuse));
        assertEq(outputs.length, 2);
        assertEq(uint256(outputs[1]), amount);
    }

    // ============ Additional Coverage Tests ============

    function testShouldReturnEarlyWhenRepayBalanceIsZero() public {
        // given - borrow first
        uint256 borrowAmount = 1_000e18;
        vaultMock.enterAaveV4Borrow(_enterData(address(spoke), address(token), RESERVE_ID, borrowAmount, 0));

        // Transfer all tokens away from vault so balance is 0
        uint256 vaultBalance = token.balanceOf(address(vaultMock));
        vm.prank(address(vaultMock));
        token.transfer(address(1), vaultBalance);

        assertEq(token.balanceOf(address(vaultMock)), 0, "Vault should have 0 balance");

        // when - try to repay with 0 balance
        vaultMock.exitAaveV4Borrow(_exitData(address(spoke), address(token), RESERVE_ID, borrowAmount, 0));

        // then - debt should not change (repayAmount == 0 early return)
        uint256 debt = spoke.getUserTotalDebt(RESERVE_ID, address(vaultMock));
        assertEq(debt, borrowAmount, "Debt should not change when vault has 0 balance");
    }

    function testShouldRevertWhenReserveNotGrantedOnExit() public {
        // given
        uint256 ungrantedReserveId = 2;
        spoke.addReserve(ungrantedReserveId, address(token));

        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4BorrowFuse.AaveV4BorrowFuseUnsupportedSubstrate.selector,
                "exit",
                address(spoke),
                ungrantedReserveId
            )
        );
        vaultMock.exitAaveV4Borrow(_exitData(address(spoke), address(token), ungrantedReserveId, 100e18, 0));
    }

    function testShouldRevertWhenSpokeNotGrantedOnExit() public {
        // given
        MockAaveV4Spoke ungrantedSpoke = new MockAaveV4Spoke();

        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4BorrowFuse.AaveV4BorrowFuseUnsupportedSubstrate.selector,
                "exit",
                address(ungrantedSpoke),
                RESERVE_ID
            )
        );
        vaultMock.exitAaveV4Borrow(_exitData(address(ungrantedSpoke), address(token), RESERVE_ID, 100e18, 0));
    }

    // ============ Slippage Protection Tests ============

    function testShouldRevertWhenBorrowSharesBelowMinSharesOnEnter() public {
        // given - spoke returns 90% shares (slippage)
        spoke.setShareRate(90, 100);
        uint256 amount = 1_000e18;

        uint256 expectedShares = (amount * 90) / 100; // 900e18
        uint256 minShares = 950e18; // require at least 950 shares

        // when/then
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4BorrowFuse.AaveV4BorrowFuseInsufficientShares.selector,
                expectedShares,
                minShares
            )
        );
        vaultMock.enterAaveV4Borrow(_enterData(address(spoke), address(token), RESERVE_ID, amount, minShares));
    }

    function testShouldSucceedWhenBorrowSharesEqualMinSharesOnEnter() public {
        // given - spoke returns 90% shares
        spoke.setShareRate(90, 100);
        uint256 amount = 1_000e18;
        uint256 expectedShares = (amount * 90) / 100; // 900e18

        // when - minShares exactly matches received
        vaultMock.enterAaveV4Borrow(_enterData(address(spoke), address(token), RESERVE_ID, amount, expectedShares));

        // then - borrow succeeded
        // getUserTotalDebt returns assets (shares * denominator / numerator), so 900e18 * 100/90 = 1000e18
        uint256 debt = spoke.getUserTotalDebt(RESERVE_ID, address(vaultMock));
        assertEq(debt, amount, "Borrow should succeed when shares == minShares");
    }

    function testShouldRevertWhenRepaidSharesBelowMinSharesRepaidOnExit() public {
        // given - borrow first with 1:1
        uint256 borrowAmount = 1_000e18;
        vaultMock.enterAaveV4Borrow(_enterData(address(spoke), address(token), RESERVE_ID, borrowAmount, 0));

        // Change share rate so repay reduces fewer shares than expected
        // With 1:1 borrow, we have 1000e18 borrow shares
        // Now set rate to 90/100: repay(500e18) -> repaidShares = 500 * 90/100 = 450e18
        spoke.setShareRate(90, 100);

        uint256 repayAmount = 500e18;
        uint256 expectedSharesRepaid = (repayAmount * 90) / 100; // 450e18
        uint256 minSharesRepaid = 600e18; // require more than actual

        // when/then
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4BorrowFuse.AaveV4BorrowFuseInsufficientSharesRepaid.selector,
                expectedSharesRepaid,
                minSharesRepaid
            )
        );
        vaultMock.exitAaveV4Borrow(_exitData(address(spoke), address(token), RESERVE_ID, repayAmount, minSharesRepaid));
    }

    function testShouldSucceedWhenRepaidSharesEqualMinSharesRepaidOnExit() public {
        // given - borrow first with 1:1
        uint256 borrowAmount = 1_000e18;
        vaultMock.enterAaveV4Borrow(_enterData(address(spoke), address(token), RESERVE_ID, borrowAmount, 0));

        uint256 repayAmount = 500e18;
        // In 1:1 mock, sharesRepaid = repayAmount = 500e18
        uint256 minSharesRepaid = repayAmount;

        // when - minSharesRepaid exactly matches actual
        vaultMock.exitAaveV4Borrow(_exitData(address(spoke), address(token), RESERVE_ID, repayAmount, minSharesRepaid));

        // then - repay succeeded, remaining debt = 500e18
        uint256 debt = spoke.getUserTotalDebt(RESERVE_ID, address(vaultMock));
        assertEq(debt, borrowAmount - repayAmount, "Remaining debt should be 500e18");
    }

    // ============ Reserve/Asset Mismatch Tests ============

    function testShouldRevertWhenReserveAssetMismatchOnBorrow() public {
        // given - token2 at reserve 2 (granted), but we pass token2 with reserveId=1 (which has token)
        ERC20Mock token2 = new ERC20Mock("Token2", "TK2", 18);
        spoke.addReserve(2, address(token2));

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = AaveV4SubstrateLib.encodeReserve(address(spoke), RESERVE_ID, false, true);
        substrates[1] = AaveV4SubstrateLib.encodeReserve(address(spoke), 2, false, true);
        vaultMock.grantMarketSubstrates(MARKET_ID, substrates);

        // when/then - reserveId=1 points to token, but data says token2
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4BorrowFuse.AaveV4BorrowFuseReserveAssetMismatch.selector,
                RESERVE_ID,
                address(token2),
                address(token)
            )
        );
        vaultMock.enterAaveV4Borrow(_enterData(address(spoke), address(token2), RESERVE_ID, 100e18, 0));
    }

    function testShouldRevertWhenReserveAssetMismatchOnRepay() public {
        // given - borrow token from reserve 1
        vaultMock.enterAaveV4Borrow(_enterData(address(spoke), address(token), RESERVE_ID, 500e18, 0));

        // Add token2 at reserve 2 and grant it
        ERC20Mock token2 = new ERC20Mock("Token2", "TK2", 18);
        spoke.addReserve(2, address(token2));

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = AaveV4SubstrateLib.encodeReserve(address(spoke), RESERVE_ID, false, true);
        substrates[1] = AaveV4SubstrateLib.encodeReserve(address(spoke), 2, false, true);
        vaultMock.grantMarketSubstrates(MARKET_ID, substrates);

        // when/then - try to repay with wrong reserveId
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4BorrowFuse.AaveV4BorrowFuseReserveAssetMismatch.selector,
                2, // reserveId 2
                address(token), // expected
                address(token2) // actual at reserveId 2
            )
        );
        vaultMock.exitAaveV4Borrow(_exitData(address(spoke), address(token), 2, 100e18, 0));
    }

    // ============ Helpers ============

    function _grant(bytes32 substrate_) private {
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = substrate_;
        vaultMock.grantMarketSubstrates(MARKET_ID, substrates);
    }

    function _enterData(
        address spoke_,
        address asset_,
        uint256 reserveId_,
        uint256 amount_,
        uint256 minShares_
    ) private pure returns (AaveV4BorrowFuseEnterData memory) {
        return
            AaveV4BorrowFuseEnterData({
                spoke: spoke_,
                asset: asset_,
                reserveId: reserveId_,
                amount: amount_,
                minShares: minShares_
            });
    }

    function _exitData(
        address spoke_,
        address asset_,
        uint256 reserveId_,
        uint256 amount_,
        uint256 minSharesRepaid_
    ) private pure returns (AaveV4BorrowFuseExitData memory) {
        return
            AaveV4BorrowFuseExitData({
                spoke: spoke_,
                asset: asset_,
                reserveId: reserveId_,
                amount: amount_,
                minSharesRepaid: minSharesRepaid_
            });
    }
}
