// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {AaveV4SubstrateLib} from "../../../contracts/fuses/aave_v4/AaveV4SubstrateLib.sol";
import {
    AaveV4SupplyFuse,
    AaveV4SupplyFuseEnterData,
    AaveV4SupplyFuseExitData
} from "../../../contracts/fuses/aave_v4/AaveV4SupplyFuse.sol";
import {
    AaveV4CollateralFuse,
    AaveV4CollateralFuseEnterData
} from "../../../contracts/fuses/aave_v4/AaveV4CollateralFuse.sol";
import {IAaveV4Spoke} from "../../../contracts/fuses/aave_v4/ext/IAaveV4Spoke.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";
import {MockAaveV4Spoke} from "./MockAaveV4Spoke.sol";
import {ERC20Mock} from "./ERC20Mock.sol";

/// @title AaveV4SupplyFuseTest
/// @notice Tests for AaveV4SupplyFuse contract
contract AaveV4SupplyFuseTest is Test {
    uint256 public constant MARKET_ID = 49;
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

        // Grant the reserve as plain supply (not collateral, not borrowable)
        _grant(AaveV4SubstrateLib.encodeReserve(address(spoke), RESERVE_ID, false, false));

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
        vaultMock.enterAaveV4Supply(_enterData(address(spoke), address(token), RESERVE_ID, amount, 0));

        // then
        uint256 balanceAfter = token.balanceOf(address(vaultMock));
        assertEq(balanceBefore - balanceAfter, amount, "Vault balance should decrease by amount");

        uint256 supplyShares = spoke.getUserSuppliedShares(RESERVE_ID, address(vaultMock));
        assertEq(supplyShares, amount, "Supply shares should equal amount (1:1 in mock)");

        (bool usingAsCollateral, ) = spoke.getUserReserveStatus(RESERVE_ID, address(vaultMock));
        assertFalse(usingAsCollateral, "Supplying must not enable collateral in Aave V4");
    }

    function testShouldReturnEarlyWhenSupplyAmountIsZero() public {
        // when - no revert expected
        vaultMock.enterAaveV4Supply(_enterData(address(spoke), address(token), RESERVE_ID, 0, 0));

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
        vaultMock.enterAaveV4Supply(_enterData(address(spoke), address(token), RESERVE_ID, requestedAmount, 0));

        // then - should supply only available balance
        uint256 supplyShares = spoke.getUserSuppliedShares(RESERVE_ID, address(vaultMock));
        assertEq(supplyShares, vaultBalance, "Should supply only available balance");
    }

    function testShouldRevertWhenReserveNotGrantedOnEnter() public {
        // given - reserve 2 listed on the spoke but not granted
        uint256 ungrantedReserveId = 2;
        spoke.addReserve(ungrantedReserveId, address(token));
        token.mint(address(vaultMock), 1_000e18);

        // when/then
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4SupplyFuse.AaveV4SupplyFuseUnsupportedSubstrate.selector,
                "enter",
                address(spoke),
                ungrantedReserveId
            )
        );
        vaultMock.enterAaveV4Supply(_enterData(address(spoke), address(token), ungrantedReserveId, 100e18, 0));
    }

    function testShouldRevertWhenSpokeNotGrantedOnEnter() public {
        // given - another spoke with the same reserve id and asset, not granted
        MockAaveV4Spoke ungrantedSpoke = new MockAaveV4Spoke();
        ungrantedSpoke.addReserve(RESERVE_ID, address(token));
        token.mint(address(vaultMock), 1_000e18);

        // when/then
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4SupplyFuse.AaveV4SupplyFuseUnsupportedSubstrate.selector,
                "enter",
                address(ungrantedSpoke),
                RESERVE_ID
            )
        );
        vaultMock.enterAaveV4Supply(_enterData(address(ungrantedSpoke), address(token), RESERVE_ID, 100e18, 0));
    }

    function testShouldRevertWhenGrantedReserveNotListedOnSpoke() public {
        // given - atomist granted a reserve id that does not exist on the spoke
        uint256 unlistedReserveId = 9;
        _grant(AaveV4SubstrateLib.encodeReserve(address(spoke), unlistedReserveId, false, false));
        token.mint(address(vaultMock), 1_000e18);

        // when/then - spoke rejects the lookup
        vm.expectRevert(IAaveV4Spoke.ReserveNotListed.selector);
        vaultMock.enterAaveV4Supply(_enterData(address(spoke), address(token), unlistedReserveId, 100e18, 0));
    }

    function testShouldSupplyAndWithdrawWhenGrantedWithAllFlags() public {
        // given - collateral + borrowable grant still allows plain supply/withdraw
        _grant(AaveV4SubstrateLib.encodeReserve(address(spoke), RESERVE_ID, true, true));
        uint256 amount = 1_000e18;
        token.mint(address(vaultMock), amount);

        // when
        vaultMock.enterAaveV4Supply(_enterData(address(spoke), address(token), RESERVE_ID, amount, 0));
        vaultMock.exitAaveV4Supply(_exitData(address(spoke), address(token), RESERVE_ID, amount, 0));

        // then
        assertEq(spoke.getUserSuppliedShares(RESERVE_ID, address(vaultMock)), 0);
        assertEq(token.balanceOf(address(vaultMock)), amount);
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
        vaultMock.enterAaveV4Supply(_enterData(address(spoke), address(token), RESERVE_ID, amount, 0));
    }

    // ============ Exit (Withdraw) Tests ============

    function testShouldBeAbleToWithdraw() public {
        // given - supply first
        uint256 amount = 1_000e18;
        token.mint(address(vaultMock), amount);
        vaultMock.enterAaveV4Supply(_enterData(address(spoke), address(token), RESERVE_ID, amount, 0));

        uint256 balanceBefore = token.balanceOf(address(vaultMock));

        // when
        vaultMock.exitAaveV4Supply(_exitData(address(spoke), address(token), RESERVE_ID, amount, 0));

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
        vaultMock.enterAaveV4Supply(_enterData(address(spoke), address(token), RESERVE_ID, amount, 0));

        // when - withdraw 0
        vaultMock.exitAaveV4Supply(_exitData(address(spoke), address(token), RESERVE_ID, 0, 0));

        // then - no change
        uint256 supplyShares = spoke.getUserSuppliedShares(RESERVE_ID, address(vaultMock));
        assertEq(supplyShares, amount, "Supply shares should not change");
    }

    function testShouldWithdrawMinOfPositionAndAmount() public {
        // given - supply 500, try to withdraw 1000
        uint256 supplyAmount = 500e18;
        token.mint(address(vaultMock), supplyAmount);
        vaultMock.enterAaveV4Supply(_enterData(address(spoke), address(token), RESERVE_ID, supplyAmount, 0));

        // when - request more than position
        vaultMock.exitAaveV4Supply(_exitData(address(spoke), address(token), RESERVE_ID, 1_000e18, 0));

        // then - should only withdraw available (capped at position)
        uint256 supplyShares = spoke.getUserSuppliedShares(RESERVE_ID, address(vaultMock));
        assertEq(supplyShares, 0, "All shares should be withdrawn");
    }

    function testShouldEmitExitEvent() public {
        // given - supply first
        uint256 amount = 500e18;
        token.mint(address(vaultMock), amount);
        vaultMock.enterAaveV4Supply(_enterData(address(spoke), address(token), RESERVE_ID, amount, 0));

        // when/then
        vm.expectEmit(false, false, false, true);
        emit AaveV4SupplyFuse.AaveV4SupplyFuseExit(
            address(supplyFuse),
            address(spoke),
            address(token),
            RESERVE_ID,
            amount
        );
        vaultMock.exitAaveV4Supply(_exitData(address(spoke), address(token), RESERVE_ID, amount, 0));
    }

    // ============ Instant Withdraw Tests ============

    function testShouldInstantWithdraw() public {
        // given - supply first
        uint256 amount = 1_000e18;
        token.mint(address(vaultMock), amount);
        vaultMock.enterAaveV4Supply(_enterData(address(spoke), address(token), RESERVE_ID, amount, 0));

        // when - instant withdraw (params: [0] amount, [1] asset, [2] spoke, [3] reserveId, [4] minAmount)
        vaultMock.instantWithdraw(_instantWithdrawParams(amount, address(token), address(spoke), RESERVE_ID, 0));

        // then
        uint256 supplyShares = spoke.getUserSuppliedShares(RESERVE_ID, address(vaultMock));
        assertEq(supplyShares, 0, "All shares should be withdrawn via instant withdraw");
    }

    function testShouldInstantWithdrawFromBorrowableNonCollateralReserve() public {
        // given - canBorrow does not block instant withdraw, only isCollateral does
        _grant(AaveV4SubstrateLib.encodeReserve(address(spoke), RESERVE_ID, false, true));
        uint256 amount = 1_000e18;
        token.mint(address(vaultMock), amount);
        vaultMock.enterAaveV4Supply(_enterData(address(spoke), address(token), RESERVE_ID, amount, 0));

        // when
        vaultMock.instantWithdraw(_instantWithdrawParams(amount, address(token), address(spoke), RESERVE_ID, 0));

        // then
        assertEq(spoke.getUserSuppliedShares(RESERVE_ID, address(vaultMock)), 0);
    }

    function testShouldRevertInstantWithdrawWhenReserveMayBeCollateral() public {
        // given - reserve granted as collateral
        _grant(AaveV4SubstrateLib.encodeReserve(address(spoke), RESERVE_ID, true, false));
        uint256 amount = 1_000e18;
        token.mint(address(vaultMock), amount);
        vaultMock.enterAaveV4Supply(_enterData(address(spoke), address(token), RESERVE_ID, amount, 0));

        // when/then
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4SupplyFuse.AaveV4SupplyFuseInstantWithdrawNotAllowed.selector,
                address(spoke),
                RESERVE_ID
            )
        );
        vaultMock.instantWithdraw(_instantWithdrawParams(amount, address(token), address(spoke), RESERVE_ID, 0));

        // regular exit is still allowed for a collateral reserve
        vaultMock.exitAaveV4Supply(_exitData(address(spoke), address(token), RESERVE_ID, amount, 0));
        assertEq(spoke.getUserSuppliedShares(RESERVE_ID, address(vaultMock)), 0);
    }

    function testShouldRevertInstantWithdrawWhenReserveIsCollateralOnChain() public {
        // given - enabled as collateral while the grant allowed it, then the atomist downgraded the grant to plain
        _grant(AaveV4SubstrateLib.encodeReserve(address(spoke), RESERVE_ID, true, false));
        uint256 amount = 1_000e18;
        token.mint(address(vaultMock), amount);
        vaultMock.enterAaveV4Supply(_enterData(address(spoke), address(token), RESERVE_ID, amount, 0));

        AaveV4CollateralFuse collateralFuse = new AaveV4CollateralFuse(MARKET_ID);
        vaultMock.execute(
            address(collateralFuse),
            abi.encodeWithSignature(
                "enter((address,uint256))",
                AaveV4CollateralFuseEnterData({spoke: address(spoke), reserveId: RESERVE_ID})
            )
        );
        _grant(AaveV4SubstrateLib.encodeReserve(address(spoke), RESERVE_ID, false, false));

        // when/then - the on-chain status still says collateral
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4SupplyFuse.AaveV4SupplyFuseInstantWithdrawNotAllowed.selector,
                address(spoke),
                RESERVE_ID
            )
        );
        vaultMock.instantWithdraw(_instantWithdrawParams(amount, address(token), address(spoke), RESERVE_ID, 0));
    }

    function testShouldNotEnforceMinAmountOnInstantWithdraw() public {
        // given - supplied; the spoke pays out 90% (hypothetical haircut) and params[4] demands 95%
        uint256 amount = 1_000e18;
        token.mint(address(vaultMock), amount);
        vaultMock.enterAaveV4Supply(_enterData(address(spoke), address(token), RESERVE_ID, amount, 0));
        spoke.setWithdrawRate(90, 100);

        // when - must not revert (a revert here would block every user withdrawal)
        vaultMock.instantWithdraw(_instantWithdrawParams(amount, address(token), address(spoke), RESERVE_ID, 950e18));

        // then
        assertEq(token.balanceOf(address(vaultMock)), 900e18, "withdrawn what the spoke paid out");
    }

    function testShouldRevertInstantWithdrawWhenParamsTooShort() public {
        bytes32[] memory params = new bytes32[](4);
        params[0] = bytes32(uint256(1e18));
        params[1] = bytes32(uint256(uint160(address(token))));
        params[2] = bytes32(uint256(uint160(address(spoke))));
        params[3] = bytes32(RESERVE_ID);

        vm.expectRevert(AaveV4SupplyFuse.AaveV4SupplyFuseInvalidParams.selector);
        vaultMock.instantWithdraw(params);
    }

    function testShouldRevertInstantWithdrawWhenReserveNotGranted() public {
        uint256 ungrantedReserveId = 2;
        spoke.addReserve(ungrantedReserveId, address(token));

        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4SupplyFuse.AaveV4SupplyFuseUnsupportedSubstrate.selector,
                "exit",
                address(spoke),
                ungrantedReserveId
            )
        );
        vaultMock.instantWithdraw(
            _instantWithdrawParams(100e18, address(token), address(spoke), ungrantedReserveId, 0)
        );
    }

    function testShouldEmitExitFailedOnInstantWithdrawFailure() public {
        // given - supply first
        uint256 amount = 1_000e18;
        token.mint(address(vaultMock), amount);
        vaultMock.enterAaveV4Supply(_enterData(address(spoke), address(token), RESERVE_ID, amount, 0));

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

        vaultMock.instantWithdraw(_instantWithdrawParams(amount, address(token), address(spoke), RESERVE_ID, 0));
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
        vaultMock.enterAaveV4Supply(_enterData(address(spoke), address(token), RESERVE_ID, amount, 0));

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

        // when
        vaultMock.enterAaveV4Supply(_enterData(address(spoke), address(token), RESERVE_ID, requestedAmount, 0));

        // then - no supply should occur
        uint256 supplyShares = spoke.getUserSuppliedShares(RESERVE_ID, address(vaultMock));
        assertEq(supplyShares, 0, "Should not supply when vault has zero balance");
    }

    function testShouldReturnEarlyWhenNoPositionOnExit() public {
        // when - no supply, try to withdraw
        vaultMock.exitAaveV4Supply(_exitData(address(spoke), address(token), RESERVE_ID, 1_000e18, 0));

        // then - should return early with zero
        uint256 supplyShares = spoke.getUserSuppliedShares(RESERVE_ID, address(vaultMock));
        assertEq(supplyShares, 0, "Supply shares should remain 0");
    }

    function testShouldRevertWhenReserveNotGrantedOnExit() public {
        // given - reserve 2 listed but not granted
        uint256 ungrantedReserveId = 2;
        spoke.addReserve(ungrantedReserveId, address(token));

        // when/then
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4SupplyFuse.AaveV4SupplyFuseUnsupportedSubstrate.selector,
                "exit",
                address(spoke),
                ungrantedReserveId
            )
        );
        vaultMock.exitAaveV4Supply(_exitData(address(spoke), address(token), ungrantedReserveId, 100e18, 0));
    }

    function testShouldRevertWhenSpokeNotGrantedOnExit() public {
        // given
        MockAaveV4Spoke ungrantedSpoke = new MockAaveV4Spoke();

        // when/then
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4SupplyFuse.AaveV4SupplyFuseUnsupportedSubstrate.selector,
                "exit",
                address(ungrantedSpoke),
                RESERVE_ID
            )
        );
        vaultMock.exitAaveV4Supply(_exitData(address(ungrantedSpoke), address(token), RESERVE_ID, 100e18, 0));
    }

    function testShouldRevertExitWhenGrantRevoked() public {
        // given - supplied, then the atomist removed the grant entirely
        uint256 amount = 1_000e18;
        token.mint(address(vaultMock), amount);
        vaultMock.enterAaveV4Supply(_enterData(address(spoke), address(token), RESERVE_ID, amount, 0));
        vaultMock.grantMarketSubstrates(MARKET_ID, new bytes32[](0));

        // when/then - exit requires a grant (position stays until re-granted)
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4SupplyFuse.AaveV4SupplyFuseUnsupportedSubstrate.selector,
                "exit",
                address(spoke),
                RESERVE_ID
            )
        );
        vaultMock.exitAaveV4Supply(_exitData(address(spoke), address(token), RESERVE_ID, amount, 0));
    }

    // ============ Slippage Protection Tests ============

    function testShouldRevertWhenReceivedSharesBelowMinSharesOnEnter() public {
        // given - spoke returns 90% shares (slippage)
        spoke.setShareRate(90, 100);
        uint256 amount = 1_000e18;
        token.mint(address(vaultMock), amount);

        uint256 expectedShares = (amount * 90) / 100; // 900e18
        uint256 minShares = 950e18; // require at least 950 shares

        // when/then
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4SupplyFuse.AaveV4SupplyFuseInsufficientShares.selector,
                expectedShares,
                minShares
            )
        );
        vaultMock.enterAaveV4Supply(_enterData(address(spoke), address(token), RESERVE_ID, amount, minShares));
    }

    function testShouldSucceedWhenReceivedSharesEqualMinSharesOnEnter() public {
        // given - spoke returns 90% shares
        spoke.setShareRate(90, 100);
        uint256 amount = 1_000e18;
        token.mint(address(vaultMock), amount);

        uint256 expectedShares = (amount * 90) / 100; // 900e18

        // when - minShares exactly matches received
        vaultMock.enterAaveV4Supply(_enterData(address(spoke), address(token), RESERVE_ID, amount, expectedShares));

        // then - supply succeeded
        uint256 supplyShares = spoke.getUserSuppliedShares(RESERVE_ID, address(vaultMock));
        assertEq(supplyShares, expectedShares, "Supply should succeed when shares == minShares");
    }

    function testShouldRevertWhenWithdrawnAmountBelowMinAmountOnExit() public {
        // given - supply first with 1:1
        uint256 amount = 1_000e18;
        token.mint(address(vaultMock), amount);
        vaultMock.enterAaveV4Supply(_enterData(address(spoke), address(token), RESERVE_ID, amount, 0));

        // Set withdraw rate to 90% (slippage on exit)
        spoke.setWithdrawRate(90, 100);

        uint256 expectedWithdrawn = (amount * 90) / 100; // 900e18
        uint256 minAmount = 950e18; // require at least 950

        // when/then
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4SupplyFuse.AaveV4SupplyFuseInsufficientAmount.selector,
                expectedWithdrawn,
                minAmount
            )
        );
        vaultMock.exitAaveV4Supply(_exitData(address(spoke), address(token), RESERVE_ID, amount, minAmount));
    }

    function testShouldSucceedWhenWithdrawnAmountEqualMinAmountOnExit() public {
        // given - supply first with 1:1
        uint256 amount = 1_000e18;
        token.mint(address(vaultMock), amount);
        vaultMock.enterAaveV4Supply(_enterData(address(spoke), address(token), RESERVE_ID, amount, 0));

        // Set withdraw rate to 90%
        spoke.setWithdrawRate(90, 100);
        uint256 expectedWithdrawn = (amount * 90) / 100; // 900e18

        // when - minAmount exactly matches withdrawn
        vaultMock.exitAaveV4Supply(_exitData(address(spoke), address(token), RESERVE_ID, amount, expectedWithdrawn));

        // then - exit succeeded
        uint256 vaultBalance = token.balanceOf(address(vaultMock));
        assertEq(vaultBalance, expectedWithdrawn, "Vault should receive withdrawn amount");
    }

    // ============ Reserve/Asset Mismatch Tests ============

    function testShouldRevertWhenReserveAssetMismatchOnEnter() public {
        // given - token2 at reserve 2 (granted), but we pass token2 with reserveId=1 (which has token)
        ERC20Mock token2 = new ERC20Mock("Token2", "TK2", 18);
        spoke.addReserve(2, address(token2));

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = AaveV4SubstrateLib.encodeReserve(address(spoke), RESERVE_ID, false, false);
        substrates[1] = AaveV4SubstrateLib.encodeReserve(address(spoke), 2, false, false);
        vaultMock.grantMarketSubstrates(MARKET_ID, substrates);

        token2.mint(address(vaultMock), 1_000e18);

        // when/then - reserveId=1 points to token, but data says token2
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4SupplyFuse.AaveV4SupplyFuseReserveAssetMismatch.selector,
                RESERVE_ID,
                address(token2),
                address(token)
            )
        );
        vaultMock.enterAaveV4Supply(_enterData(address(spoke), address(token2), RESERVE_ID, 100e18, 0));
    }

    function testShouldRevertWhenReserveAssetMismatchOnExit() public {
        // given - supply token to reserve 1 first
        token.mint(address(vaultMock), 1_000e18);
        vaultMock.enterAaveV4Supply(_enterData(address(spoke), address(token), RESERVE_ID, 500e18, 0));

        // Add token2 at reserve 2 and grant it
        ERC20Mock token2 = new ERC20Mock("Token2", "TK2", 18);
        spoke.addReserve(2, address(token2));

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = AaveV4SubstrateLib.encodeReserve(address(spoke), RESERVE_ID, false, false);
        substrates[1] = AaveV4SubstrateLib.encodeReserve(address(spoke), 2, false, false);
        vaultMock.grantMarketSubstrates(MARKET_ID, substrates);

        // when/then - try to exit with wrong reserveId
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4SupplyFuse.AaveV4SupplyFuseReserveAssetMismatch.selector,
                2, // reserveId 2
                address(token), // expected
                address(token2) // actual at reserveId 2
            )
        );
        vaultMock.exitAaveV4Supply(_exitData(address(spoke), address(token), 2, 100e18, 0));
    }

    function testShouldDistinguishTwoReservesOfSameAssetOnOneSpoke() public {
        // given - the same underlying listed twice (like USDC via Prime and Core hubs on Bluechip); only reserve 2 granted
        uint256 duplicateReserveId = 2;
        spoke.addReserve(duplicateReserveId, address(token));
        _grant(AaveV4SubstrateLib.encodeReserve(address(spoke), duplicateReserveId, false, false));
        token.mint(address(vaultMock), 1_000e18);

        // when/then - reserve 1 (same asset) is rejected
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4SupplyFuse.AaveV4SupplyFuseUnsupportedSubstrate.selector,
                "enter",
                address(spoke),
                RESERVE_ID
            )
        );
        vaultMock.enterAaveV4Supply(_enterData(address(spoke), address(token), RESERVE_ID, 100e18, 0));

        // and reserve 2 works
        vaultMock.enterAaveV4Supply(_enterData(address(spoke), address(token), duplicateReserveId, 100e18, 0));
        assertEq(spoke.getUserSuppliedShares(duplicateReserveId, address(vaultMock)), 100e18);
        assertEq(spoke.getUserSuppliedShares(RESERVE_ID, address(vaultMock)), 0);
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
    ) private pure returns (AaveV4SupplyFuseEnterData memory) {
        return
            AaveV4SupplyFuseEnterData({
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
        uint256 minAmount_
    ) private pure returns (AaveV4SupplyFuseExitData memory) {
        return
            AaveV4SupplyFuseExitData({
                spoke: spoke_,
                asset: asset_,
                reserveId: reserveId_,
                amount: amount_,
                minAmount: minAmount_
            });
    }

    function _instantWithdrawParams(
        uint256 amount_,
        address asset_,
        address spoke_,
        uint256 reserveId_,
        uint256 minAmount_
    ) private pure returns (bytes32[] memory params) {
        params = new bytes32[](5);
        params[0] = bytes32(amount_);
        params[1] = bytes32(uint256(uint160(asset_)));
        params[2] = bytes32(uint256(uint160(spoke_)));
        params[3] = bytes32(reserveId_);
        params[4] = bytes32(minAmount_);
    }
}
