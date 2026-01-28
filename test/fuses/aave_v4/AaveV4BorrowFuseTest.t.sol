// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {Errors} from "../../../contracts/libraries/errors/Errors.sol";
import {AaveV4SubstrateLib} from "../../../contracts/fuses/aave_v4/AaveV4SubstrateLib.sol";
import {AaveV4BorrowFuse, AaveV4BorrowFuseEnterData, AaveV4BorrowFuseExitData} from "../../../contracts/fuses/aave_v4/AaveV4BorrowFuse.sol";
import {AaveV4SupplyFuse, AaveV4SupplyFuseEnterData} from "../../../contracts/fuses/aave_v4/AaveV4SupplyFuse.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";
import {MockAaveV4Spoke} from "./MockAaveV4Spoke.sol";
import {ERC20Mock} from "./ERC20Mock.sol";

/// @title AaveV4BorrowFuseTest
/// @notice Tests for AaveV4BorrowFuse contract
contract AaveV4BorrowFuseTest is Test {
    uint256 public constant MARKET_ID = 43;
    uint256 public constant RESERVE_ID = 1;

    AaveV4BorrowFuse public borrowFuse;
    AaveV4SupplyFuse public supplyFuse;
    PlasmaVaultMock public vaultMock;
    MockAaveV4Spoke public spoke;
    ERC20Mock public token;

    function setUp() public {
        // Deploy contracts
        borrowFuse = new AaveV4BorrowFuse(MARKET_ID);
        supplyFuse = new AaveV4SupplyFuse(MARKET_ID);
        spoke = new MockAaveV4Spoke();
        token = new ERC20Mock("Test Token", "TST", 18);

        // Configure mock spoke
        spoke.addReserve(RESERVE_ID, address(token));

        // Fund spoke with tokens for borrows
        token.mint(address(spoke), 10_000_000e18);

        // Grant substrates
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = AaveV4SubstrateLib.encodeAsset(address(token));
        substrates[1] = AaveV4SubstrateLib.encodeSpoke(address(spoke));

        // Use borrowFuse as the main fuse in mock
        vaultMock = new PlasmaVaultMock(address(borrowFuse), address(0));
        vaultMock.grantMarketSubstrates(MARKET_ID, substrates);

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
        vaultMock.enterAaveV4Borrow(
            AaveV4BorrowFuseEnterData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: borrowAmount,
                minShares: 0
            })
        );

        // then
        uint256 balanceAfter = token.balanceOf(address(vaultMock));
        assertEq(balanceAfter - balanceBefore, borrowAmount, "Vault should receive borrowed tokens");

        uint256 borrowShares = spoke.getUserTotalDebt(RESERVE_ID, address(vaultMock));
        assertEq(borrowShares, borrowAmount, "Borrow shares should equal amount");
    }

    function testShouldReturnEarlyWhenBorrowAmountIsZero() public {
        // when - no revert
        vaultMock.enterAaveV4Borrow(
            AaveV4BorrowFuseEnterData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: 0,
                minShares: 0
            })
        );

        // then
        uint256 borrowShares = spoke.getUserTotalDebt(RESERVE_ID, address(vaultMock));
        assertEq(borrowShares, 0);
    }

    function testShouldRevertWhenAssetSubstrateNotGrantedOnBorrow() public {
        // given
        ERC20Mock ungrantedToken = new ERC20Mock("Other", "OTH", 18);

        bytes32 expectedSubstrate = AaveV4SubstrateLib.encodeAsset(address(ungrantedToken));
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4BorrowFuse.AaveV4BorrowFuseUnsupportedSubstrate.selector,
                "enter",
                expectedSubstrate
            )
        );
        vaultMock.enterAaveV4Borrow(
            AaveV4BorrowFuseEnterData({
                spoke: address(spoke),
                asset: address(ungrantedToken),
                reserveId: RESERVE_ID,
                amount: 100e18,
                minShares: 0
            })
        );
    }

    function testShouldRevertWhenSpokeSubstrateNotGrantedOnBorrow() public {
        // given
        MockAaveV4Spoke ungrantedSpoke = new MockAaveV4Spoke();

        bytes32 expectedSubstrate = AaveV4SubstrateLib.encodeSpoke(address(ungrantedSpoke));
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4BorrowFuse.AaveV4BorrowFuseUnsupportedSubstrate.selector,
                "enter",
                expectedSubstrate
            )
        );
        vaultMock.enterAaveV4Borrow(
            AaveV4BorrowFuseEnterData({
                spoke: address(ungrantedSpoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: 100e18,
                minShares: 0
            })
        );
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
        vaultMock.enterAaveV4Borrow(
            AaveV4BorrowFuseEnterData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: amount,
                minShares: 0
            })
        );
    }

    // ============ Exit (Repay) Tests ============

    function testShouldBeAbleToRepay() public {
        // given - borrow first
        uint256 borrowAmount = 1_000e18;
        vaultMock.enterAaveV4Borrow(
            AaveV4BorrowFuseEnterData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: borrowAmount,
                minShares: 0
            })
        );

        // when - repay
        vaultMock.exitAaveV4Borrow(
            AaveV4BorrowFuseExitData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: borrowAmount,
                minSharesRepaid: 0
            })
        );

        // then
        uint256 borrowShares = spoke.getUserTotalDebt(RESERVE_ID, address(vaultMock));
        assertEq(borrowShares, 0, "Borrow shares should be zero after full repay");
    }

    function testShouldReturnEarlyWhenRepayAmountIsZero() public {
        // given - borrow first
        uint256 borrowAmount = 1_000e18;
        vaultMock.enterAaveV4Borrow(
            AaveV4BorrowFuseEnterData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: borrowAmount,
                minShares: 0
            })
        );

        // when - repay 0
        vaultMock.exitAaveV4Borrow(
            AaveV4BorrowFuseExitData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: 0,
                minSharesRepaid: 0
            })
        );

        // then
        uint256 borrowShares = spoke.getUserTotalDebt(RESERVE_ID, address(vaultMock));
        assertEq(borrowShares, borrowAmount, "Borrow shares should not change");
    }

    function testShouldRepayMinOfBalanceAndAmount() public {
        // given - borrow 1000 but only keep 500
        uint256 borrowAmount = 1_000e18;
        vaultMock.enterAaveV4Borrow(
            AaveV4BorrowFuseEnterData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: borrowAmount,
                minShares: 0
            })
        );

        // Burn half the tokens from vault (simulating partial balance)
        uint256 vaultBalance = token.balanceOf(address(vaultMock));
        vm.prank(address(vaultMock));
        token.transfer(address(1), vaultBalance / 2);

        uint256 currentBalance = token.balanceOf(address(vaultMock));

        // when - try to repay full amount
        vaultMock.exitAaveV4Borrow(
            AaveV4BorrowFuseExitData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: borrowAmount,
                minSharesRepaid: 0
            })
        );

        // then - only partial repay
        uint256 borrowShares = spoke.getUserTotalDebt(RESERVE_ID, address(vaultMock));
        assertEq(borrowShares, borrowAmount - currentBalance, "Should repay only available balance");
    }

    function testShouldEmitExitEvent() public {
        // given - borrow first
        uint256 amount = 500e18;
        vaultMock.enterAaveV4Borrow(
            AaveV4BorrowFuseEnterData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: amount,
                minShares: 0
            })
        );

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
        vaultMock.exitAaveV4Borrow(
            AaveV4BorrowFuseExitData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: amount,
                minSharesRepaid: 0
            })
        );
    }

    function testShouldApproveBeforeRepay() public {
        // given - borrow first
        uint256 amount = 500e18;
        vaultMock.enterAaveV4Borrow(
            AaveV4BorrowFuseEnterData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: amount,
                minShares: 0
            })
        );

        // when - repay (forceApprove is called internally)
        vaultMock.exitAaveV4Borrow(
            AaveV4BorrowFuseExitData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: amount,
                minSharesRepaid: 0
            })
        );

        // then - repay succeeded (would have failed without approval)
        uint256 borrowShares = spoke.getUserTotalDebt(RESERVE_ID, address(vaultMock));
        assertEq(borrowShares, 0);
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
        uint256 borrowShares = spoke.getUserTotalDebt(RESERVE_ID, address(vaultMock));
        assertEq(borrowShares, amount, "Borrow should succeed via transient storage");

        bytes32[] memory outputs = vaultMock.getOutputs(address(borrowFuse));
        assertEq(outputs.length, 2);
        assertEq(address(uint160(uint256(outputs[0]))), address(token));
        assertEq(uint256(outputs[1]), amount);
    }

    function testShouldExitTransient() public {
        // given - borrow first
        uint256 amount = 500e18;
        vaultMock.enterAaveV4Borrow(
            AaveV4BorrowFuseEnterData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: amount,
                minShares: 0
            })
        );

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
        uint256 borrowShares = spoke.getUserTotalDebt(RESERVE_ID, address(vaultMock));
        assertEq(borrowShares, 0, "All debt should be repaid via transient exit");

        bytes32[] memory outputs = vaultMock.getOutputs(address(borrowFuse));
        assertEq(outputs.length, 2);
        assertEq(uint256(outputs[1]), amount);
    }

    // ============ Additional Coverage Tests ============

    function testShouldReturnEarlyWhenRepayBalanceIsZero() public {
        // given - borrow first
        uint256 borrowAmount = 1_000e18;
        vaultMock.enterAaveV4Borrow(
            AaveV4BorrowFuseEnterData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: borrowAmount,
                minShares: 0
            })
        );

        // Transfer all tokens away from vault so balance is 0
        uint256 vaultBalance = token.balanceOf(address(vaultMock));
        vm.prank(address(vaultMock));
        token.transfer(address(1), vaultBalance);

        assertEq(token.balanceOf(address(vaultMock)), 0, "Vault should have 0 balance");

        // when - try to repay with 0 balance
        vaultMock.exitAaveV4Borrow(
            AaveV4BorrowFuseExitData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: borrowAmount,
                minSharesRepaid: 0
            })
        );

        // then - borrow shares should not change (repayAmount == 0 early return)
        uint256 borrowShares = spoke.getUserTotalDebt(RESERVE_ID, address(vaultMock));
        assertEq(borrowShares, borrowAmount, "Borrow shares should not change when vault has 0 balance");
    }

    function testShouldRevertWhenAssetSubstrateNotGrantedOnExit() public {
        // given
        ERC20Mock ungrantedToken = new ERC20Mock("Other", "OTH", 18);

        bytes32 expectedSubstrate = AaveV4SubstrateLib.encodeAsset(address(ungrantedToken));
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4BorrowFuse.AaveV4BorrowFuseUnsupportedSubstrate.selector,
                "exit",
                expectedSubstrate
            )
        );
        vaultMock.exitAaveV4Borrow(
            AaveV4BorrowFuseExitData({
                spoke: address(spoke),
                asset: address(ungrantedToken),
                reserveId: RESERVE_ID,
                amount: 100e18,
                minSharesRepaid: 0
            })
        );
    }

    function testShouldRevertWhenSpokeSubstrateNotGrantedOnExit() public {
        // given
        MockAaveV4Spoke ungrantedSpoke = new MockAaveV4Spoke();

        bytes32 expectedSubstrate = AaveV4SubstrateLib.encodeSpoke(address(ungrantedSpoke));
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4BorrowFuse.AaveV4BorrowFuseUnsupportedSubstrate.selector,
                "exit",
                expectedSubstrate
            )
        );
        vaultMock.exitAaveV4Borrow(
            AaveV4BorrowFuseExitData({
                spoke: address(ungrantedSpoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: 100e18,
                minSharesRepaid: 0
            })
        );
    }

    // ============ Slippage Protection Tests ============

    function testShouldRevertWhenBorrowSharesBelowMinSharesOnEnter() public {
        // given - spoke returns 90% shares (slippage)
        spoke.setShareRate(90, 100);
        uint256 amount = 1_000e18;

        uint256 expectedShares = amount * 90 / 100; // 900e18
        uint256 minShares = 950e18; // require at least 950 shares

        // when/then
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4BorrowFuse.AaveV4BorrowFuseInsufficientShares.selector,
                expectedShares,
                minShares
            )
        );
        vaultMock.enterAaveV4Borrow(
            AaveV4BorrowFuseEnterData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: amount,
                minShares: minShares
            })
        );
    }

    function testShouldSucceedWhenBorrowSharesEqualMinSharesOnEnter() public {
        // given - spoke returns 90% shares
        spoke.setShareRate(90, 100);
        uint256 amount = 1_000e18;
        uint256 expectedShares = amount * 90 / 100; // 900e18

        // when - minShares exactly matches received
        vaultMock.enterAaveV4Borrow(
            AaveV4BorrowFuseEnterData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: amount,
                minShares: expectedShares
            })
        );

        // then - borrow succeeded
        // getUserTotalDebt returns assets (shares * denominator / numerator), so 900e18 * 100/90 = 1000e18
        uint256 borrowDebt = spoke.getUserTotalDebt(RESERVE_ID, address(vaultMock));
        assertEq(borrowDebt, amount, "Borrow should succeed when shares == minShares");
    }

    function testShouldRevertWhenRepaidSharesBelowMinSharesRepaidOnExit() public {
        // given - borrow first with 1:1
        uint256 borrowAmount = 1_000e18;
        vaultMock.enterAaveV4Borrow(
            AaveV4BorrowFuseEnterData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: borrowAmount,
                minShares: 0
            })
        );

        // Change share rate so repay reduces fewer shares than expected
        // With 1:1 borrow, we have 1000e18 borrow shares
        // Now set rate to 90/100: repay(500e18) → repaidShares = 500 * 90/100 = 450e18
        spoke.setShareRate(90, 100);

        uint256 repayAmount = 500e18;
        uint256 expectedSharesRepaid = repayAmount * 90 / 100; // 450e18
        uint256 minSharesRepaid = 600e18; // require more than actual

        // when/then
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4BorrowFuse.AaveV4BorrowFuseInsufficientSharesRepaid.selector,
                expectedSharesRepaid,
                minSharesRepaid
            )
        );
        vaultMock.exitAaveV4Borrow(
            AaveV4BorrowFuseExitData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: repayAmount,
                minSharesRepaid: minSharesRepaid
            })
        );
    }

    function testShouldSucceedWhenRepaidSharesEqualMinSharesRepaidOnExit() public {
        // given - borrow first with 1:1
        uint256 borrowAmount = 1_000e18;
        vaultMock.enterAaveV4Borrow(
            AaveV4BorrowFuseEnterData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: borrowAmount,
                minShares: 0
            })
        );

        uint256 repayAmount = 500e18;
        // In 1:1 mock, sharesRepaid = repayAmount = 500e18
        uint256 minSharesRepaid = repayAmount;

        // when - minSharesRepaid exactly matches actual
        vaultMock.exitAaveV4Borrow(
            AaveV4BorrowFuseExitData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: repayAmount,
                minSharesRepaid: minSharesRepaid
            })
        );

        // then - repay succeeded, remaining debt = 500e18
        uint256 borrowShares = spoke.getUserTotalDebt(RESERVE_ID, address(vaultMock));
        assertEq(borrowShares, borrowAmount - repayAmount, "Remaining debt should be 500e18");
    }
}
