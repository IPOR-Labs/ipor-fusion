// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {Errors} from "../../../contracts/libraries/errors/Errors.sol";
import {AaveV4SubstrateLib} from "../../../contracts/fuses/aave_v4/AaveV4SubstrateLib.sol";
import {AaveV4SupplyFuse, AaveV4SupplyFuseEnterData, AaveV4SupplyFuseExitData} from "../../../contracts/fuses/aave_v4/AaveV4SupplyFuse.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";
import {MockAaveV4Spoke} from "./MockAaveV4Spoke.sol";
import {ERC20Mock} from "./ERC20Mock.sol";

/// @title AaveV4SupplyFuseTest
/// @notice Tests for AaveV4SupplyFuse contract
contract AaveV4SupplyFuseTest is Test {
    uint256 public constant MARKET_ID = 43;
    uint256 public constant RESERVE_ID = 1;

    AaveV4SupplyFuse public supplyFuse;
    PlasmaVaultMock public vaultMock;
    MockAaveV4Spoke public spoke;
    ERC20Mock public token;

    function setUp() public {
        // Deploy contracts
        supplyFuse = new AaveV4SupplyFuse(MARKET_ID);
        vaultMock = new PlasmaVaultMock(address(supplyFuse), address(0));
        spoke = new MockAaveV4Spoke();
        token = new ERC20Mock("Test Token", "TST", 18);

        // Configure mock spoke
        spoke.addReserve(RESERVE_ID, address(token));

        // Fund spoke with tokens for borrows
        token.mint(address(spoke), 1_000_000e18);

        // Grant substrates
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = AaveV4SubstrateLib.encodeAsset(address(token));
        substrates[1] = AaveV4SubstrateLib.encodeSpoke(address(spoke));
        vaultMock.grantMarketSubstrates(MARKET_ID, substrates);

        // Label addresses
        vm.label(address(supplyFuse), "AaveV4SupplyFuse");
        vm.label(address(vaultMock), "PlasmaVaultMock");
        vm.label(address(spoke), "MockAaveV4Spoke");
        vm.label(address(token), "TestToken");
    }

    // ============ Constructor Tests ============

    function testShouldDeployWithValidMarketId() public view {
        assertEq(supplyFuse.VERSION(), address(supplyFuse));
        assertEq(supplyFuse.MARKET_ID(), MARKET_ID);
    }

    function testShouldRevertWhenMarketIdIsZero() public {
        vm.expectRevert(AaveV4SupplyFuse.AaveV4SupplyFuseInvalidMarketId.selector);
        new AaveV4SupplyFuse(0);
    }

    // ============ Enter (Supply) Tests ============

    function testShouldBeAbleToSupply() public {
        // given
        uint256 amount = 1_000e18;
        token.mint(address(vaultMock), amount);

        uint256 balanceBefore = token.balanceOf(address(vaultMock));

        // when
        vaultMock.enterAaveV4Supply(
            AaveV4SupplyFuseEnterData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: amount,
                minShares: 0
            })
        );

        // then
        uint256 balanceAfter = token.balanceOf(address(vaultMock));
        assertEq(balanceBefore - balanceAfter, amount, "Vault balance should decrease by amount");

        uint256 supplyShares = spoke.getUserSuppliedShares(RESERVE_ID, address(vaultMock));
        assertEq(supplyShares, amount, "Supply shares should equal amount (1:1 in mock)");
    }

    function testShouldReturnEarlyWhenSupplyAmountIsZero() public {
        // when - no revert expected
        vaultMock.enterAaveV4Supply(
            AaveV4SupplyFuseEnterData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: 0,
                minShares: 0
            })
        );

        // then - no state change
        uint256 supplyShares = spoke.getUserSuppliedShares(RESERVE_ID, address(vaultMock));
        assertEq(supplyShares, 0);
    }

    function testShouldSupplyMinOfBalanceAndAmount() public {
        // given - vault has less than requested amount
        uint256 vaultBalance = 500e18;
        uint256 requestedAmount = 1_000e18;
        token.mint(address(vaultMock), vaultBalance);

        // when
        vaultMock.enterAaveV4Supply(
            AaveV4SupplyFuseEnterData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: requestedAmount,
                minShares: 0
            })
        );

        // then - should supply only available balance
        uint256 supplyShares = spoke.getUserSuppliedShares(RESERVE_ID, address(vaultMock));
        assertEq(supplyShares, vaultBalance, "Should supply only available balance");
    }

    function testShouldRevertWhenAssetSubstrateNotGranted() public {
        // given - new token not in substrates
        ERC20Mock ungrantedToken = new ERC20Mock("Other", "OTH", 18);
        ungrantedToken.mint(address(vaultMock), 1_000e18);

        // when/then
        bytes32 expectedSubstrate = AaveV4SubstrateLib.encodeAsset(address(ungrantedToken));
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4SupplyFuse.AaveV4SupplyFuseUnsupportedSubstrate.selector,
                "enter",
                expectedSubstrate
            )
        );
        vaultMock.enterAaveV4Supply(
            AaveV4SupplyFuseEnterData({
                spoke: address(spoke),
                asset: address(ungrantedToken),
                reserveId: RESERVE_ID,
                amount: 100e18,
                minShares: 0
            })
        );
    }

    function testShouldRevertWhenSpokeSubstrateNotGranted() public {
        // given - new spoke not in substrates
        MockAaveV4Spoke ungrantedSpoke = new MockAaveV4Spoke();
        ungrantedSpoke.addReserve(RESERVE_ID, address(token));
        token.mint(address(vaultMock), 1_000e18);

        // when/then
        bytes32 expectedSubstrate = AaveV4SubstrateLib.encodeSpoke(address(ungrantedSpoke));
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4SupplyFuse.AaveV4SupplyFuseUnsupportedSubstrate.selector,
                "enter",
                expectedSubstrate
            )
        );
        vaultMock.enterAaveV4Supply(
            AaveV4SupplyFuseEnterData({
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
        token.mint(address(vaultMock), amount);

        // when/then
        vm.expectEmit(false, false, false, true);
        emit AaveV4SupplyFuse.AaveV4SupplyFuseEnter(
            address(supplyFuse),
            address(spoke),
            address(token),
            RESERVE_ID,
            amount
        );
        vaultMock.enterAaveV4Supply(
            AaveV4SupplyFuseEnterData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: amount,
                minShares: 0
            })
        );
    }

    // ============ Exit (Withdraw) Tests ============

    function testShouldBeAbleToWithdraw() public {
        // given - supply first
        uint256 amount = 1_000e18;
        token.mint(address(vaultMock), amount);
        vaultMock.enterAaveV4Supply(
            AaveV4SupplyFuseEnterData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: amount,
                minShares: 0
            })
        );

        uint256 balanceBefore = token.balanceOf(address(vaultMock));

        // when
        vaultMock.exitAaveV4Supply(
            AaveV4SupplyFuseExitData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: amount,
                minAmount: 0
            })
        );

        // then
        uint256 balanceAfter = token.balanceOf(address(vaultMock));
        assertEq(balanceAfter - balanceBefore, amount, "Vault balance should increase by withdrawn amount");

        uint256 supplyShares = spoke.getUserSuppliedShares(RESERVE_ID, address(vaultMock));
        assertEq(supplyShares, 0, "Supply shares should be zero after full withdrawal");
    }

    function testShouldReturnEarlyWhenWithdrawAmountIsZero() public {
        // given - supply first
        uint256 amount = 1_000e18;
        token.mint(address(vaultMock), amount);
        vaultMock.enterAaveV4Supply(
            AaveV4SupplyFuseEnterData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: amount,
                minShares: 0
            })
        );

        // when - withdraw 0
        vaultMock.exitAaveV4Supply(
            AaveV4SupplyFuseExitData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: 0,
                minAmount: 0
            })
        );

        // then - no change
        uint256 supplyShares = spoke.getUserSuppliedShares(RESERVE_ID, address(vaultMock));
        assertEq(supplyShares, amount, "Supply shares should not change");
    }

    function testShouldWithdrawMinOfPositionAndAmount() public {
        // given - supply 500, try to withdraw 1000
        uint256 supplyAmount = 500e18;
        token.mint(address(vaultMock), supplyAmount);
        vaultMock.enterAaveV4Supply(
            AaveV4SupplyFuseEnterData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: supplyAmount,
                minShares: 0
            })
        );

        // when - request more than position
        vaultMock.exitAaveV4Supply(
            AaveV4SupplyFuseExitData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: 1_000e18,
                minAmount: 0
            })
        );

        // then - should only withdraw available (capped at position)
        uint256 supplyShares = spoke.getUserSuppliedShares(RESERVE_ID, address(vaultMock));
        assertEq(supplyShares, 0, "All shares should be withdrawn");
    }

    function testShouldEmitExitEvent() public {
        // given - supply first
        uint256 amount = 500e18;
        token.mint(address(vaultMock), amount);
        vaultMock.enterAaveV4Supply(
            AaveV4SupplyFuseEnterData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: amount,
                minShares: 0
            })
        );

        // when/then
        vm.expectEmit(false, false, false, true);
        emit AaveV4SupplyFuse.AaveV4SupplyFuseExit(
            address(supplyFuse),
            address(spoke),
            address(token),
            RESERVE_ID,
            amount
        );
        vaultMock.exitAaveV4Supply(
            AaveV4SupplyFuseExitData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: amount,
                minAmount: 0
            })
        );
    }

    // ============ Instant Withdraw Tests ============

    function testShouldInstantWithdraw() public {
        // given - supply first
        uint256 amount = 1_000e18;
        token.mint(address(vaultMock), amount);
        vaultMock.enterAaveV4Supply(
            AaveV4SupplyFuseEnterData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: amount,
                minShares: 0
            })
        );

        // when - instant withdraw (params: [0] amount, [1] asset, [2] spoke, [3] reserveId, [4] minAmount)
        bytes32[] memory params = new bytes32[](5);
        params[0] = bytes32(amount);
        params[1] = bytes32(uint256(uint160(address(token))));
        params[2] = bytes32(uint256(uint160(address(spoke))));
        params[3] = bytes32(RESERVE_ID);
        params[4] = bytes32(uint256(0)); // minAmount

        vaultMock.instantWithdraw(params);

        // then
        uint256 supplyShares = spoke.getUserSuppliedShares(RESERVE_ID, address(vaultMock));
        assertEq(supplyShares, 0, "All shares should be withdrawn via instant withdraw");
    }

    function testShouldEmitExitFailedOnInstantWithdrawFailure() public {
        // given - supply first
        uint256 amount = 1_000e18;
        token.mint(address(vaultMock), amount);
        vaultMock.enterAaveV4Supply(
            AaveV4SupplyFuseEnterData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: amount,
                minShares: 0
            })
        );

        // Make spoke revert on withdraw
        spoke.setShouldRevertOnWithdraw(true);

        // when/then
        vm.expectEmit(false, false, false, true);
        emit AaveV4SupplyFuse.AaveV4SupplyFuseExitFailed(
            address(supplyFuse),
            address(spoke),
            address(token),
            RESERVE_ID,
            amount
        );

        bytes32[] memory params = new bytes32[](5);
        params[0] = bytes32(amount);
        params[1] = bytes32(uint256(uint160(address(token))));
        params[2] = bytes32(uint256(uint160(address(spoke))));
        params[3] = bytes32(RESERVE_ID);
        params[4] = bytes32(uint256(0)); // minAmount

        vaultMock.instantWithdraw(params);
    }

    // ============ Transient Storage Tests ============

    function testShouldEnterTransient() public {
        // given
        uint256 amount = 500e18;
        token.mint(address(vaultMock), amount);

        bytes32[] memory inputs = new bytes32[](5);
        inputs[0] = bytes32(uint256(uint160(address(spoke))));
        inputs[1] = bytes32(uint256(uint160(address(token))));
        inputs[2] = bytes32(RESERVE_ID);
        inputs[3] = bytes32(amount);
        inputs[4] = bytes32(uint256(0)); // minShares

        vaultMock.setInputs(address(supplyFuse), inputs);

        // when
        vaultMock.enterAaveV4SupplyTransient();

        // then
        uint256 supplyShares = spoke.getUserSuppliedShares(RESERVE_ID, address(vaultMock));
        assertEq(supplyShares, amount, "Supply should succeed via transient storage");

        bytes32[] memory outputs = vaultMock.getOutputs(address(supplyFuse));
        assertEq(outputs.length, 2);
        assertEq(address(uint160(uint256(outputs[0]))), address(token));
        assertEq(uint256(outputs[1]), amount);
    }

    function testShouldExitTransient() public {
        // given - supply first
        uint256 amount = 500e18;
        token.mint(address(vaultMock), amount);
        vaultMock.enterAaveV4Supply(
            AaveV4SupplyFuseEnterData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: amount,
                minShares: 0
            })
        );

        // Set transient inputs for exit
        bytes32[] memory inputs = new bytes32[](5);
        inputs[0] = bytes32(uint256(uint160(address(spoke))));
        inputs[1] = bytes32(uint256(uint160(address(token))));
        inputs[2] = bytes32(RESERVE_ID);
        inputs[3] = bytes32(amount);
        inputs[4] = bytes32(uint256(0)); // minAmount

        vaultMock.setInputs(address(supplyFuse), inputs);

        // when
        vaultMock.exitAaveV4SupplyTransient();

        // then
        uint256 supplyShares = spoke.getUserSuppliedShares(RESERVE_ID, address(vaultMock));
        assertEq(supplyShares, 0, "All supply should be withdrawn via transient exit");

        bytes32[] memory outputs = vaultMock.getOutputs(address(supplyFuse));
        assertEq(outputs.length, 2);
        assertEq(address(uint160(uint256(outputs[0]))), address(token));
        assertEq(uint256(outputs[1]), amount);
    }

    // ============ Additional Coverage Tests ============

    function testShouldReturnEarlyWhenBalanceIsZeroOnEnter() public {
        // given - vault has no tokens, but amount is non-zero
        uint256 requestedAmount = 1_000e18;
        // vault has 0 balance of token

        // when
        vaultMock.enterAaveV4Supply(
            AaveV4SupplyFuseEnterData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: requestedAmount,
                minShares: 0
            })
        );

        // then - no supply should occur
        uint256 supplyShares = spoke.getUserSuppliedShares(RESERVE_ID, address(vaultMock));
        assertEq(supplyShares, 0, "Should not supply when vault has zero balance");
    }

    function testShouldReturnEarlyWhenNoPositionOnExit() public {
        // given - no supply, try to withdraw
        // when
        vaultMock.exitAaveV4Supply(
            AaveV4SupplyFuseExitData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: 1_000e18,
                minAmount: 0
            })
        );

        // then - should return early with zero
        uint256 supplyShares = spoke.getUserSuppliedShares(RESERVE_ID, address(vaultMock));
        assertEq(supplyShares, 0, "Supply shares should remain 0");
    }

    function testShouldRevertWhenAssetSubstrateNotGrantedOnExit() public {
        // given - new token not in substrates
        ERC20Mock ungrantedToken = new ERC20Mock("Other", "OTH", 18);

        // when/then
        bytes32 expectedSubstrate = AaveV4SubstrateLib.encodeAsset(address(ungrantedToken));
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4SupplyFuse.AaveV4SupplyFuseUnsupportedSubstrate.selector,
                "exit",
                expectedSubstrate
            )
        );
        vaultMock.exitAaveV4Supply(
            AaveV4SupplyFuseExitData({
                spoke: address(spoke),
                asset: address(ungrantedToken),
                reserveId: RESERVE_ID,
                amount: 100e18,
                minAmount: 0
            })
        );
    }

    function testShouldRevertWhenSpokeSubstrateNotGrantedOnExit() public {
        // given
        MockAaveV4Spoke ungrantedSpoke = new MockAaveV4Spoke();

        // when/then
        bytes32 expectedSubstrate = AaveV4SubstrateLib.encodeSpoke(address(ungrantedSpoke));
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4SupplyFuse.AaveV4SupplyFuseUnsupportedSubstrate.selector,
                "exit",
                expectedSubstrate
            )
        );
        vaultMock.exitAaveV4Supply(
            AaveV4SupplyFuseExitData({
                spoke: address(ungrantedSpoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: 100e18,
                minAmount: 0
            })
        );
    }

    // ============ Slippage Protection Tests ============

    function testShouldRevertWhenReceivedSharesBelowMinSharesOnEnter() public {
        // given - spoke returns 90% shares (slippage)
        spoke.setShareRate(90, 100);
        uint256 amount = 1_000e18;
        token.mint(address(vaultMock), amount);

        uint256 expectedShares = amount * 90 / 100; // 900e18
        uint256 minShares = 950e18; // require at least 950 shares

        // when/then
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4SupplyFuse.AaveV4SupplyFuseInsufficientShares.selector,
                expectedShares,
                minShares
            )
        );
        vaultMock.enterAaveV4Supply(
            AaveV4SupplyFuseEnterData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: amount,
                minShares: minShares
            })
        );
    }

    function testShouldSucceedWhenReceivedSharesEqualMinSharesOnEnter() public {
        // given - spoke returns 90% shares
        spoke.setShareRate(90, 100);
        uint256 amount = 1_000e18;
        token.mint(address(vaultMock), amount);

        uint256 expectedShares = amount * 90 / 100; // 900e18

        // when - minShares exactly matches received
        vaultMock.enterAaveV4Supply(
            AaveV4SupplyFuseEnterData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: amount,
                minShares: expectedShares
            })
        );

        // then - supply succeeded
        uint256 supplyShares = spoke.getUserSuppliedShares(RESERVE_ID, address(vaultMock));
        assertEq(supplyShares, expectedShares, "Supply should succeed when shares == minShares");
    }

    function testShouldRevertWhenWithdrawnAmountBelowMinAmountOnExit() public {
        // given - supply first with 1:1
        uint256 amount = 1_000e18;
        token.mint(address(vaultMock), amount);
        vaultMock.enterAaveV4Supply(
            AaveV4SupplyFuseEnterData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: amount,
                minShares: 0
            })
        );

        // Set withdraw rate to 90% (slippage on exit)
        spoke.setWithdrawRate(90, 100);

        uint256 expectedWithdrawn = amount * 90 / 100; // 900e18
        uint256 minAmount = 950e18; // require at least 950

        // when/then
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4SupplyFuse.AaveV4SupplyFuseInsufficientAmount.selector,
                expectedWithdrawn,
                minAmount
            )
        );
        vaultMock.exitAaveV4Supply(
            AaveV4SupplyFuseExitData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: amount,
                minAmount: minAmount
            })
        );
    }

    function testShouldSucceedWhenWithdrawnAmountEqualMinAmountOnExit() public {
        // given - supply first with 1:1
        uint256 amount = 1_000e18;
        token.mint(address(vaultMock), amount);
        vaultMock.enterAaveV4Supply(
            AaveV4SupplyFuseEnterData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: amount,
                minShares: 0
            })
        );

        // Set withdraw rate to 90%
        spoke.setWithdrawRate(90, 100);
        uint256 expectedWithdrawn = amount * 90 / 100; // 900e18

        // when - minAmount exactly matches withdrawn
        vaultMock.exitAaveV4Supply(
            AaveV4SupplyFuseExitData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: amount,
                minAmount: expectedWithdrawn
            })
        );

        // then - exit succeeded
        uint256 vaultBalance = token.balanceOf(address(vaultMock));
        assertEq(vaultBalance, expectedWithdrawn, "Vault should receive withdrawn amount");
    }
}
