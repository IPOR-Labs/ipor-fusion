// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {
    Erc4626SupplyFuse,
    Erc4626SupplyFuseEnterData,
    Erc4626SupplyFuseExitData
} from "../../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";
import {TypeConversionLib} from "../../../contracts/libraries/TypeConversionLib.sol";
import {MockERC20} from "../../test_helpers/MockERC20.sol";
import {MockERC4626} from "../../test_helpers/MockErc4626.sol";
import {MockERC4626ZeroMax} from "../../test_helpers/MockERC4626ZeroMax.sol";

/// @notice Tests of `Erc4626SupplyFuse` exits from ERC4626 vaults whose `maxWithdraw` is a constant 0 while
///         `withdraw` works (Morpho Vaults V2, GitHub #554, IL-8505). Every test deposits through the fuse into
///         `MockERC4626ZeroMax` and asserts `maxWithdraw == 0` and `maxRedeem == 0`, so the exit always runs through
///         the fallback that sizes the exit from the held shares (`previewRedeem`, then `convertToAssets`).
contract Erc4626SupplyFuseZeroMaxTest is Test {
    uint256 private constant MARKET_ID = 1;
    uint256 private constant DEPOSIT_AMOUNT = 1_000e18;
    /// @dev Donated to the vault to lift the share price above 1 (deliberately not a round number)
    uint256 private constant YIELD_AMOUNT = 123_456_789_012_345_678_901;
    /// @dev Exit fee of the fee vault scenario: 1% keeps the numbers exact (net value 990e18, fee 10e18)
    uint256 private constant EXIT_FEE_BPS = 100;
    address private constant DEAD = address(0xdead);

    MockERC20 private underlyingToken;
    MockERC4626ZeroMax private zeroMaxVault;
    MockERC4626 private standardVault;
    Erc4626SupplyFuse private fuse;
    PlasmaVaultMock private vaultMock;

    function setUp() public {
        underlyingToken = new MockERC20("Mock Token", "MTK", 18);
        zeroMaxVault = new MockERC4626ZeroMax(underlyingToken, "Zero Max Vault", "zVLT");
        standardVault = new MockERC4626(underlyingToken, "Standard Vault", "sVLT");
        fuse = new Erc4626SupplyFuse(MARKET_ID);
        vaultMock = new PlasmaVaultMock(address(fuse), address(fuse));

        address[] memory assets = new address[](2);
        assets[0] = address(zeroMaxVault);
        assets[1] = address(standardVault);
        vaultMock.grantAssetsToMarket(MARKET_ID, assets);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Exit through the fallback (maxWithdraw == 0)
    // ---------------------------------------------------------------------------------------------------------

    /// @notice Requested < previewRedeem(shares): the fuse withdraws exactly the requested assets.
    function testShouldPartiallyExitWhenMaxWithdrawIsZero() external {
        // given
        uint256 sharesBefore = _depositToZeroMaxVault(DEPOSIT_AMOUNT);
        uint256 requested = 400e18;
        assertLt(requested, zeroMaxVault.previewRedeem(sharesBefore), "requested should be below the position value");
        uint256 expectedShares = zeroMaxVault.previewWithdraw(requested);
        uint256 balanceBefore = underlyingToken.balanceOf(address(vaultMock));

        _expectExitEvent(address(zeroMaxVault), requested, expectedShares);

        // when
        uint256 sharesBurned = _exit(address(zeroMaxVault), requested, 0);

        // then
        assertEq(underlyingToken.balanceOf(address(vaultMock)) - balanceBefore, requested, "requested assets received");
        assertEq(sharesBurned, expectedShares, "returned shares should be the burned shares");
        assertEq(
            zeroMaxVault.balanceOf(address(vaultMock)),
            sharesBefore - expectedShares,
            "shares should be reduced by the burned shares"
        );
        assertEq(zeroMaxVault.withdrawCalls(), 1, "vault withdraw should be called once");
    }

    /// @notice Requested > previewRedeem(shares): the exit is capped to previewRedeem(shares) and the whole position
    ///         leaves the vault. The mock has a 1:1 share price with no rounding loss, so exactly 0 shares remain.
    function testShouldFullyExitWhenRequestedExceedsPreviewRedeem() external {
        // given
        uint256 sharesBefore = _depositToZeroMaxVault(DEPOSIT_AMOUNT);
        uint256 positionValue = zeroMaxVault.previewRedeem(sharesBefore);
        assertEq(positionValue, DEPOSIT_AMOUNT, "share price should be 1:1");
        uint256 balanceBefore = underlyingToken.balanceOf(address(vaultMock));

        _expectExitEvent(address(zeroMaxVault), positionValue, sharesBefore);

        // when
        uint256 sharesBurned = _exit(address(zeroMaxVault), positionValue + 500e18, 0);

        // then
        assertEq(
            underlyingToken.balanceOf(address(vaultMock)) - balanceBefore,
            positionValue,
            "assets received should be previewRedeem(shares)"
        );
        assertEq(sharesBurned, sharesBefore, "all shares should be burned");
        assertEq(zeroMaxVault.balanceOf(address(vaultMock)), 0, "no share dust at a 1:1 price");
    }

    /// @notice Requested == previewRedeem(shares) is the boundary of the full exit: same result as exceeding it.
    function testShouldFullyExitWhenRequestedEqualsPreviewRedeem() external {
        // given
        uint256 sharesBefore = _depositToZeroMaxVault(DEPOSIT_AMOUNT);
        uint256 positionValue = zeroMaxVault.previewRedeem(sharesBefore);
        uint256 balanceBefore = underlyingToken.balanceOf(address(vaultMock));

        // when
        uint256 sharesBurned = _exit(address(zeroMaxVault), positionValue, 0);

        // then
        assertEq(underlyingToken.balanceOf(address(vaultMock)) - balanceBefore, positionValue, "assets received");
        assertEq(sharesBurned, sharesBefore, "all shares should be burned");
        assertEq(zeroMaxVault.balanceOf(address(vaultMock)), 0, "no share dust at a 1:1 price");
    }

    /// @notice With accrued yield (share price > 1) the full exit pays out the yield and still leaves 0 shares:
    ///         withdraw(floor(shares * price)) burns ceil(assets / price) shares, which equals `shares` for price >= 1.
    ///         Share dust is only possible when the price is below 1.
    function testShouldFullyExitWithYieldWhenMaxWithdrawIsZero() external {
        // given
        uint256 sharesBefore = _depositToZeroMaxVault(DEPOSIT_AMOUNT);
        underlyingToken.mint(address(zeroMaxVault), YIELD_AMOUNT); // yield: share price above 1
        uint256 positionValue = zeroMaxVault.previewRedeem(sharesBefore);
        assertGt(positionValue, DEPOSIT_AMOUNT, "position should include the yield");
        uint256 balanceBefore = underlyingToken.balanceOf(address(vaultMock));

        // when
        _exit(address(zeroMaxVault), type(uint256).max, 0);

        // then
        assertEq(
            underlyingToken.balanceOf(address(vaultMock)) - balanceBefore,
            positionValue,
            "assets received should be previewRedeem(shares)"
        );
        assertEq(zeroMaxVault.balanceOf(address(vaultMock)), 0, "no share dust at a price above 1");
    }

    /// @notice Nothing to withdraw (no shares held): returns 0 and never calls the vault's withdraw.
    function testShouldReturnZeroWithoutCallingWithdrawWhenNoSharesHeld() external {
        // given
        underlyingToken.mint(address(vaultMock), 100e18);
        assertEq(zeroMaxVault.balanceOf(address(vaultMock)), 0, "no shares held");
        assertEq(zeroMaxVault.maxWithdraw(address(vaultMock)), 0, "maxWithdraw should be 0");

        // when
        uint256 sharesBurned = _exit(address(zeroMaxVault), 100e18, 0);

        // then
        assertEq(sharesBurned, 0, "nothing to burn");
        assertEq(zeroMaxVault.withdrawCalls(), 0, "vault withdraw should not be called");
        assertEq(underlyingToken.balanceOf(address(vaultMock)), 100e18, "underlying balance untouched");
    }

    /// @notice previewRedeem reverts: the fuse falls back to convertToAssets(shares) and the exit still pays out.
    function testShouldFallbackToConvertToAssetsWhenPreviewRedeemReverts() external {
        // given
        uint256 sharesBefore = _depositToZeroMaxVault(DEPOSIT_AMOUNT);
        uint256 positionValue = zeroMaxVault.convertToAssets(sharesBefore);
        zeroMaxVault.setPreviewRedeemReverts(true);
        vm.expectRevert(MockERC4626ZeroMax.MockERC4626ZeroMaxPreviewRedeemReverted.selector);
        zeroMaxVault.previewRedeem(sharesBefore); // the primary sizing path is really unavailable
        uint256 balanceBefore = underlyingToken.balanceOf(address(vaultMock));

        _expectExitEvent(address(zeroMaxVault), positionValue, sharesBefore);

        // when
        uint256 sharesBurned = _exit(address(zeroMaxVault), DEPOSIT_AMOUNT * 2, 0);

        // then
        assertEq(
            underlyingToken.balanceOf(address(vaultMock)) - balanceBefore,
            positionValue,
            "assets received should be convertToAssets(shares)"
        );
        assertEq(sharesBurned, sharesBefore, "all shares should be burned");
        assertEq(zeroMaxVault.balanceOf(address(vaultMock)), 0, "no share dust at a 1:1 price");
    }

    /// @notice previewRedeem reverts while the share price is above 1: the exit is sized from convertToAssets(shares),
    ///         so it pays out the yield and not just `shares`. Kills a mutant whose `catch` branch returns `shares`.
    function testShouldFallbackToConvertToAssetsWithYieldWhenPreviewRedeemReverts() external {
        // given
        uint256 sharesBefore = _depositToZeroMaxVault(DEPOSIT_AMOUNT);
        underlyingToken.mint(address(zeroMaxVault), YIELD_AMOUNT);
        uint256 positionValue = zeroMaxVault.convertToAssets(sharesBefore);
        assertGt(positionValue, sharesBefore, "share price should be above 1");
        uint256 expectedShares = zeroMaxVault.previewWithdraw(positionValue);
        zeroMaxVault.setPreviewRedeemReverts(true);
        vm.expectRevert(MockERC4626ZeroMax.MockERC4626ZeroMaxPreviewRedeemReverted.selector);
        zeroMaxVault.previewRedeem(sharesBefore); // the primary sizing path is really unavailable
        uint256 balanceBefore = underlyingToken.balanceOf(address(vaultMock));

        _expectExitEvent(address(zeroMaxVault), positionValue, expectedShares);

        // when
        uint256 sharesBurned = _exit(address(zeroMaxVault), type(uint256).max, 0);

        // then
        uint256 received = underlyingToken.balanceOf(address(vaultMock)) - balanceBefore;
        assertEq(received, positionValue, "assets received should be convertToAssets(shares)");
        assertGt(received, sharesBefore, "the yield should be paid out, not just the share count");
        assertEq(sharesBurned, sharesBefore, "all shares should be burned");
        assertEq(zeroMaxVault.balanceOf(address(vaultMock)), 0, "no share dust at a price above 1");
    }

    /// @notice A vault with an exit fee and maxWithdraw == 0: the exit is sized from the fee-adjusted previewRedeem, so
    ///         the full exit succeeds. convertToAssets ignores the fee, so withdrawing that amount would need more
    ///         shares than are held and revert. Kills a mutant that uses convertToAssets in the `try` branch.
    function testShouldSizeExitFromPreviewRedeemNotConvertToAssetsWhenFeeVaultHasZeroMax() external {
        // given
        uint256 sharesBefore = _depositToZeroMaxVault(DEPOSIT_AMOUNT);
        zeroMaxVault.setExitFeeBps(EXIT_FEE_BPS);
        uint256 netValue = zeroMaxVault.previewRedeem(sharesBefore);
        uint256 grossValue = zeroMaxVault.convertToAssets(sharesBefore);
        assertEq(zeroMaxVault.maxWithdraw(address(vaultMock)), 0, "maxWithdraw should still be 0");
        assertLt(netValue, grossValue, "the fee should make previewRedeem smaller than convertToAssets");
        assertGt(
            zeroMaxVault.previewWithdraw(grossValue),
            sharesBefore,
            "withdrawing the fee-free value would need more shares than are held"
        );
        uint256 expectedShares = zeroMaxVault.previewWithdraw(netValue);
        uint256 balanceBefore = underlyingToken.balanceOf(address(vaultMock));

        _expectExitEvent(address(zeroMaxVault), netValue, expectedShares);

        // when
        uint256 sharesBurned = _exit(address(zeroMaxVault), type(uint256).max, 0);

        // then
        uint256 received = underlyingToken.balanceOf(address(vaultMock)) - balanceBefore;
        assertEq(received, netValue, "assets received should be previewRedeem(shares)");
        assertLt(received, zeroMaxVault.convertToAssets(sharesBefore), "the fee stays in the vault");
        assertEq(sharesBurned, expectedShares, "burned shares should be previewWithdraw(received)");
        assertEq(sharesBurned, sharesBefore, "the whole position should be burned");
        assertEq(zeroMaxVault.balanceOf(address(vaultMock)), 0, "no shares left");
    }

    /// @notice Share price below 1: the full exit still succeeds (no over-burn revert) and the rounding of
    ///         previewRedeem followed by previewWithdraw leaves only a dust of shares worth at most 1 wei of assets.
    ///         A second holder with 9 share-wei makes that rounding leave exactly one dust share-wei here.
    function testShouldLeaveNoShareDustOnFullExitWhenSharePriceBelowOne() external {
        // given
        _depositToZeroMaxVaultAs(address(this), 9);
        uint256 sharesBefore = _depositToZeroMaxVault(DEPOSIT_AMOUNT);
        _moveUnderlyingOutOfZeroMaxVault(100e18); // share price is now 0.9
        uint256 positionValue = zeroMaxVault.previewRedeem(sharesBefore);
        assertLt(positionValue, sharesBefore, "share price should be below 1");
        uint256 balanceBefore = underlyingToken.balanceOf(address(vaultMock));

        // a full exit redeems all shares (IL-8489), unlike withdraw(previewRedeem) which would leave share dust
        _expectExitEvent(address(zeroMaxVault), positionValue, sharesBefore);

        // when
        uint256 sharesBurned = _exit(address(zeroMaxVault), type(uint256).max, 0);

        // then
        assertEq(
            underlyingToken.balanceOf(address(vaultMock)) - balanceBefore,
            positionValue,
            "assets received should be previewRedeem(shares)"
        );
        assertEq(sharesBurned, sharesBefore, "all shares should be burned");
        assertEq(zeroMaxVault.balanceOf(address(vaultMock)), 0, "no share dust should remain");
    }

    /// @notice The held shares preview to 0 assets (1 share-wei at a price below 1): nothing can be withdrawn, so the
    ///         exit returns 0 without calling the vault. Kills a mutant without the `== 0` early return, which
    ///         would call `withdraw(0)` and emit an Exit event.
    function testShouldReturnZeroWhenHeldSharesPreviewToZeroAssets() external {
        // given
        _depositToZeroMaxVaultAs(address(this), DEPOSIT_AMOUNT);
        uint256 sharesBefore = _depositToZeroMaxVault(1);
        _moveUnderlyingOutOfZeroMaxVault(100e18); // share price is now below 1
        assertEq(sharesBefore, 1, "1 share-wei should be held");
        assertEq(zeroMaxVault.previewRedeem(sharesBefore), 0, "the held share should preview to 0 assets");
        vm.expectCall(address(zeroMaxVault), abi.encodeWithSelector(IERC4626.withdraw.selector), 0);
        vm.recordLogs();

        // when
        uint256 sharesBurned = _exit(address(zeroMaxVault), type(uint256).max, 0);

        // then
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(sharesBurned, 0, "nothing to burn");
        assertEq(logs.length, 0, "no Exit or ExitFailed event should be emitted");
        assertEq(zeroMaxVault.withdrawCalls(), 0, "vault withdraw should not be called");
        assertEq(zeroMaxVault.balanceOf(address(vaultMock)), sharesBefore, "shares unchanged");
        assertEq(underlyingToken.balanceOf(address(vaultMock)), 0, "no assets received");
    }

    // ---------------------------------------------------------------------------------------------------------
    // Vault withdraw failure: exit() reverts, instantWithdraw() reports and continues
    // ---------------------------------------------------------------------------------------------------------

    /// @notice A vault that cannot pay out must not look like a successful no-op: exit() propagates the revert.
    function testShouldRevertExitWhenVaultWithdrawReverts() external {
        // given
        uint256 sharesBefore = _depositToZeroMaxVault(DEPOSIT_AMOUNT);
        zeroMaxVault.setWithdrawReverts(true);

        // when
        vm.expectRevert(MockERC4626ZeroMax.MockERC4626ZeroMaxWithdrawReverted.selector);
        _exit(address(zeroMaxVault), 400e18, 0);

        // then
        assertEq(zeroMaxVault.balanceOf(address(vaultMock)), sharesBefore, "shares untouched");
        assertEq(underlyingToken.balanceOf(address(vaultMock)), 0, "no assets received");
    }

    /// @notice instantWithdraw() catches the failing vault withdraw and emits Erc4626SupplyFuseExitFailed.
    function testShouldNotRevertInstantWithdrawAndEmitExitFailedWhenVaultWithdrawReverts() external {
        // given
        uint256 sharesBefore = _depositToZeroMaxVault(DEPOSIT_AMOUNT);
        zeroMaxVault.setWithdrawReverts(true);
        uint256 requested = 400e18;
        bytes32[] memory params = _instantWithdrawParams(address(zeroMaxVault), requested);

        // the fuse must really call the vault's withdraw (which then reverts inside the fuse's try/catch)
        vm.expectCall(
            address(zeroMaxVault),
            abi.encodeCall(IERC4626.withdraw, (requested, address(vaultMock), address(vaultMock)))
        );
        vm.expectEmit(address(vaultMock));
        emit Erc4626SupplyFuse.Erc4626SupplyFuseExitFailed(
            address(fuse),
            address(underlyingToken),
            address(zeroMaxVault),
            requested
        );

        // when
        vaultMock.instantWithdraw(params);

        // then
        assertEq(zeroMaxVault.balanceOf(address(vaultMock)), sharesBefore, "shares untouched");
        assertEq(underlyingToken.balanceOf(address(vaultMock)), 0, "no assets received");
    }

    /// @notice instantWithdraw() reaches the fallback too: it withdraws instead of silently doing nothing.
    function testShouldInstantWithdrawWhenMaxWithdrawIsZero() external {
        // given
        uint256 sharesBefore = _depositToZeroMaxVault(DEPOSIT_AMOUNT);
        uint256 requested = 400e18;
        uint256 expectedShares = zeroMaxVault.previewWithdraw(requested);
        bytes32[] memory params = _instantWithdrawParams(address(zeroMaxVault), requested);

        _expectExitEvent(address(zeroMaxVault), requested, expectedShares);

        // when
        vaultMock.instantWithdraw(params);

        // then
        assertEq(underlyingToken.balanceOf(address(vaultMock)), requested, "requested assets received");
        assertEq(zeroMaxVault.balanceOf(address(vaultMock)), sharesBefore - expectedShares, "shares reduced");
        assertEq(zeroMaxVault.withdrawCalls(), 1, "vault withdraw should be called once");
    }

    // ---------------------------------------------------------------------------------------------------------
    // instantWithdraw sizing and guards
    // ---------------------------------------------------------------------------------------------------------

    /// @notice instantWithdraw() sizes the exit from convertToAssets(shares) when previewRedeem reverts. The request
    ///         exceeds the position, so the capped amount is paid out (including the yield).
    function testShouldInstantWithdrawWhenPreviewRedeemReverts() external {
        // given
        uint256 sharesBefore = _depositToZeroMaxVault(DEPOSIT_AMOUNT);
        underlyingToken.mint(address(zeroMaxVault), YIELD_AMOUNT);
        uint256 positionValue = zeroMaxVault.convertToAssets(sharesBefore);
        assertGt(positionValue, sharesBefore, "share price should be above 1");
        uint256 expectedShares = zeroMaxVault.previewWithdraw(positionValue);
        zeroMaxVault.setPreviewRedeemReverts(true);
        bytes32[] memory params = _instantWithdrawParams(address(zeroMaxVault), positionValue + 500e18);

        _expectExitEvent(address(zeroMaxVault), positionValue, expectedShares);

        // when
        vaultMock.instantWithdraw(params);

        // then
        assertEq(
            underlyingToken.balanceOf(address(vaultMock)),
            positionValue,
            "assets received should be convertToAssets(shares)"
        );
        assertEq(zeroMaxVault.balanceOf(address(vaultMock)), sharesBefore - expectedShares, "shares reduced");
        assertEq(zeroMaxVault.balanceOf(address(vaultMock)), 0, "no share dust at a price above 1");
    }

    /// @notice Documents that a failure while sizing the exit is not a withdraw failure: when both previewRedeem and
    ///         convertToAssets revert, instantWithdraw() reverts with the vault's error instead of emitting
    ///         Erc4626SupplyFuseExitFailed.
    function testShouldRevertInstantWithdrawWhenPreviewRedeemAndConvertToAssetsRevert() external {
        // given
        uint256 sharesBefore = _depositToZeroMaxVault(DEPOSIT_AMOUNT);
        zeroMaxVault.setPreviewRedeemReverts(true);
        zeroMaxVault.setConvertToAssetsReverts(true);
        bytes32[] memory params = _instantWithdrawParams(address(zeroMaxVault), 400e18);

        // when
        vm.expectRevert(MockERC4626ZeroMax.MockERC4626ZeroMaxConvertToAssetsReverted.selector);
        vaultMock.instantWithdraw(params);

        // then
        assertEq(zeroMaxVault.balanceOf(address(vaultMock)), sharesBefore, "shares untouched");
        assertEq(underlyingToken.balanceOf(address(vaultMock)), 0, "no assets received");
    }

    /// @notice A vault that is not granted as a substrate of the market cannot be exited, even if shares are held in
    ///         it: instantWithdraw() reverts with Erc4626SupplyFuseUnsupportedVault("exit", vault).
    function testShouldRevertInstantWithdrawWhenVaultNotGranted() external {
        // given
        MockERC4626ZeroMax ungrantedVault = new MockERC4626ZeroMax(underlyingToken, "Ungranted Vault", "uVLT");
        underlyingToken.mint(address(vaultMock), DEPOSIT_AMOUNT);
        vm.startPrank(address(vaultMock));
        underlyingToken.approve(address(ungrantedVault), DEPOSIT_AMOUNT);
        ungrantedVault.deposit(DEPOSIT_AMOUNT, address(vaultMock));
        vm.stopPrank();
        uint256 sharesBefore = ungrantedVault.balanceOf(address(vaultMock));
        assertGt(sharesBefore, 0, "shares are held in the ungranted vault");
        bytes32[] memory params = _instantWithdrawParams(address(ungrantedVault), 400e18);

        // when
        vm.expectRevert(
            abi.encodeWithSelector(
                Erc4626SupplyFuse.Erc4626SupplyFuseUnsupportedVault.selector,
                "exit",
                address(ungrantedVault)
            )
        );
        vaultMock.instantWithdraw(params);

        // then
        assertEq(ungrantedVault.balanceOf(address(vaultMock)), sharesBefore, "shares untouched");
        assertEq(ungrantedVault.withdrawCalls(), 0, "vault withdraw should not be called");
    }

    /// @notice The requested amount exceeds the position and the vault withdraw reverts: Erc4626SupplyFuseExitFailed
    ///         carries the capped amount that was attempted (previewRedeem(shares)), not the requested one.
    function testShouldEmitExitFailedWithCappedAmountWhenRequestedExceedsPosition() external {
        // given
        uint256 sharesBefore = _depositToZeroMaxVault(DEPOSIT_AMOUNT);
        uint256 cappedAmount = zeroMaxVault.previewRedeem(sharesBefore);
        uint256 requested = cappedAmount + 500e18;
        zeroMaxVault.setWithdrawReverts(true);
        bytes32[] memory params = _instantWithdrawParams(address(zeroMaxVault), requested);

        // the request exceeds the position: a full exit, so the fuse redeems all shares (IL-8489)
        vm.expectCall(
            address(zeroMaxVault),
            abi.encodeCall(IERC4626.redeem, (sharesBefore, address(vaultMock), address(vaultMock)))
        );
        vm.expectEmit(address(vaultMock));
        emit Erc4626SupplyFuse.Erc4626SupplyFuseExitFailed(
            address(fuse),
            address(underlyingToken),
            address(zeroMaxVault),
            cappedAmount
        );

        // when
        vaultMock.instantWithdraw(params);

        // then
        assertLt(cappedAmount, requested, "the request should exceed the position");
        assertEq(zeroMaxVault.balanceOf(address(vaultMock)), sharesBefore, "shares untouched");
        assertEq(underlyingToken.balanceOf(address(vaultMock)), 0, "no assets received");
    }

    // ---------------------------------------------------------------------------------------------------------
    // exitTransient and maxSharesBurned on the fallback path
    // ---------------------------------------------------------------------------------------------------------

    /// @notice exitTransient() on the fallback path pays out and writes the burned shares to the outputs.
    function testShouldExitTransientWhenMaxWithdrawIsZero() external {
        // given
        uint256 sharesBefore = _depositToZeroMaxVault(DEPOSIT_AMOUNT);
        uint256 requested = 250e18;
        uint256 expectedShares = zeroMaxVault.previewWithdraw(requested);

        bytes32[] memory inputs = new bytes32[](3);
        inputs[0] = TypeConversionLib.toBytes32(address(zeroMaxVault));
        inputs[1] = TypeConversionLib.toBytes32(requested);
        inputs[2] = TypeConversionLib.toBytes32(uint256(0));
        vaultMock.setInputs(address(fuse), inputs);

        _expectExitEvent(address(zeroMaxVault), requested, expectedShares);

        // when
        vaultMock.exitErc4626SupplyTransient();

        // then
        bytes32[] memory outputs = vaultMock.getOutputs(address(fuse));
        assertEq(outputs.length, 1, "one output expected");
        assertEq(TypeConversionLib.toUint256(outputs[0]), expectedShares, "output should be the burned shares");
        assertEq(underlyingToken.balanceOf(address(vaultMock)), requested, "requested assets received");
        assertEq(zeroMaxVault.balanceOf(address(vaultMock)), sharesBefore - expectedShares, "shares reduced");
        assertEq(zeroMaxVault.withdrawCalls(), 1, "vault withdraw should be called once");
    }

    /// @notice exitTransient() with a requested amount of type(uint256).max exits the whole position.
    function testShouldExitTransientFullyWhenRequestedIsMax() external {
        // given
        uint256 sharesBefore = _depositToZeroMaxVault(DEPOSIT_AMOUNT);
        uint256 positionValue = zeroMaxVault.previewRedeem(sharesBefore);

        bytes32[] memory inputs = new bytes32[](3);
        inputs[0] = TypeConversionLib.toBytes32(address(zeroMaxVault));
        inputs[1] = TypeConversionLib.toBytes32(type(uint256).max);
        inputs[2] = TypeConversionLib.toBytes32(uint256(0));
        vaultMock.setInputs(address(fuse), inputs);

        _expectExitEvent(address(zeroMaxVault), positionValue, sharesBefore);

        // when
        vaultMock.exitErc4626SupplyTransient();

        // then
        bytes32[] memory outputs = vaultMock.getOutputs(address(fuse));
        assertEq(outputs.length, 1, "one output expected");
        assertEq(TypeConversionLib.toUint256(outputs[0]), sharesBefore, "output should be the burned shares");
        assertEq(underlyingToken.balanceOf(address(vaultMock)), positionValue, "whole position received");
        assertEq(zeroMaxVault.balanceOf(address(vaultMock)), 0, "no shares left");
    }

    /// @notice maxSharesBurned below the burned shares reverts with Erc4626SupplyFuseExcessiveSharesBurned.
    function testShouldRevertWhenSharesBurnedExceedMaxOnFallbackPath() external {
        // given
        uint256 sharesBefore = _depositToZeroMaxVault(DEPOSIT_AMOUNT);
        uint256 requested = 400e18;
        uint256 expectedShares = zeroMaxVault.previewWithdraw(requested);
        uint256 maxSharesBurned = expectedShares - 1;

        // when
        vm.expectRevert(
            abi.encodeWithSelector(
                Erc4626SupplyFuse.Erc4626SupplyFuseExcessiveSharesBurned.selector,
                expectedShares,
                maxSharesBurned
            )
        );
        _exit(address(zeroMaxVault), requested, maxSharesBurned);

        // then
        assertEq(zeroMaxVault.balanceOf(address(vaultMock)), sharesBefore, "the exit should be rolled back");
        assertEq(underlyingToken.balanceOf(address(vaultMock)), 0, "no assets received");
    }

    /// @notice maxSharesBurned equal to the burned shares is accepted (boundary of the previous test).
    function testShouldExitWhenSharesBurnedEqualMaxOnFallbackPath() external {
        // given
        uint256 sharesBefore = _depositToZeroMaxVault(DEPOSIT_AMOUNT);
        uint256 requested = 400e18;
        uint256 expectedShares = zeroMaxVault.previewWithdraw(requested);

        // when
        uint256 sharesBurned = _exit(address(zeroMaxVault), requested, expectedShares);

        // then
        assertEq(sharesBurned, expectedShares, "burned shares");
        assertEq(underlyingToken.balanceOf(address(vaultMock)), requested, "requested assets received");
        assertEq(zeroMaxVault.balanceOf(address(vaultMock)), sharesBefore - expectedShares, "shares reduced");
    }

    // ---------------------------------------------------------------------------------------------------------
    // Control: a standard vault (maxWithdraw > 0) behaves as before
    // ---------------------------------------------------------------------------------------------------------

    /// @notice Standard vault, partial exit: the requested assets are paid and the shares are reduced.
    function testShouldExitPartialFromStandardVaultUnchanged() external {
        // given
        uint256 sharesBefore = _depositToStandardVault(DEPOSIT_AMOUNT);
        uint256 requested = 400e18;
        uint256 expectedShares = standardVault.previewWithdraw(requested);
        assertLt(requested, standardVault.maxWithdraw(address(vaultMock)), "requested should be below maxWithdraw");

        _expectExitEvent(address(standardVault), requested, expectedShares);

        // when
        uint256 sharesBurned = _exit(address(standardVault), requested, 0);

        // then
        assertEq(underlyingToken.balanceOf(address(vaultMock)), requested, "requested assets received");
        assertEq(sharesBurned, expectedShares, "returned shares should be the burned shares");
        assertEq(standardVault.balanceOf(address(vaultMock)), sharesBefore - expectedShares, "shares reduced");
    }

    /// @notice Standard vault, full exit: the whole deposit is paid and no shares remain.
    function testShouldExitFullFromStandardVaultUnchanged() external {
        // given
        uint256 sharesBefore = _depositToStandardVault(DEPOSIT_AMOUNT);

        // when
        uint256 sharesBurned = _exit(address(standardVault), type(uint256).max, 0);

        // then
        assertEq(underlyingToken.balanceOf(address(vaultMock)), DEPOSIT_AMOUNT, "whole deposit received");
        assertEq(sharesBurned, sharesBefore, "all shares burned");
        assertEq(standardVault.balanceOf(address(vaultMock)), 0, "no shares remain");
    }

    // ---------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------

    /// @dev Deposits through the fuse and asserts that the vault reports 0 for maxWithdraw and maxRedeem, so the
    ///      following exit is guaranteed to run through the fallback.
    function _depositToZeroMaxVault(uint256 amount_) private returns (uint256 shares) {
        underlyingToken.mint(address(vaultMock), amount_);
        vaultMock.enterErc4626Supply(
            Erc4626SupplyFuseEnterData({vault: address(zeroMaxVault), vaultAssetAmount: amount_, minSharesOut: 0})
        );

        shares = zeroMaxVault.balanceOf(address(vaultMock));
        assertGt(shares, 0, "should have shares after deposit");
        assertEq(zeroMaxVault.maxWithdraw(address(vaultMock)), 0, "maxWithdraw should be 0");
        assertEq(zeroMaxVault.maxRedeem(address(vaultMock)), 0, "maxRedeem should be 0");
        assertEq(zeroMaxVault.withdrawCalls(), 0, "deposit should not call withdraw");
        assertEq(underlyingToken.balanceOf(address(vaultMock)), 0, "all underlying should be deposited");
    }

    /// @dev Deposits `amount_` underlying directly into the zero-max vault as `holder_` (a second depositor)
    function _depositToZeroMaxVaultAs(address holder_, uint256 amount_) private {
        underlyingToken.mint(holder_, amount_);
        vm.startPrank(holder_);
        underlyingToken.approve(address(zeroMaxVault), amount_);
        zeroMaxVault.deposit(amount_, holder_);
        vm.stopPrank();
    }

    /// @dev Moves underlying out of the zero-max vault (a loss), lowering the share price
    function _moveUnderlyingOutOfZeroMaxVault(uint256 amount_) private {
        vm.prank(address(zeroMaxVault));
        underlyingToken.transfer(DEAD, amount_);
    }

    function _depositToStandardVault(uint256 amount_) private returns (uint256 shares) {
        underlyingToken.mint(address(vaultMock), amount_);
        vaultMock.enterErc4626Supply(
            Erc4626SupplyFuseEnterData({vault: address(standardVault), vaultAssetAmount: amount_, minSharesOut: 0})
        );

        shares = standardVault.balanceOf(address(vaultMock));
        assertGt(shares, 0, "should have shares after deposit");
        assertGt(standardVault.maxWithdraw(address(vaultMock)), 0, "maxWithdraw should be positive");
        assertEq(underlyingToken.balanceOf(address(vaultMock)), 0, "all underlying should be deposited");
    }

    /// @dev Calls `exit()` through the vault mock. `PlasmaVaultMock` delegatecalls unknown selectors to the fuse and
    ///      forwards the return data, which gives access to the burned shares returned by the fuse.
    function _exit(address vault_, uint256 amount_, uint256 maxSharesBurned_) private returns (uint256) {
        return
            Erc4626SupplyFuse(address(vaultMock)).exit(
                Erc4626SupplyFuseExitData({vault: vault_, vaultAssetAmount: amount_, maxSharesBurned: maxSharesBurned_})
            );
    }

    /// @dev params[0] - amount in underlying asset, params[1] - vault address (see Erc4626SupplyFuse.instantWithdraw)
    function _instantWithdrawParams(address vault_, uint256 amount_) private pure returns (bytes32[] memory params) {
        params = new bytes32[](2);
        params[0] = bytes32(amount_);
        params[1] = bytes32(uint256(uint160(vault_)));
    }

    /// @dev Expects `Erc4626SupplyFuseExit` from the vault mock (the fuse runs by delegatecall)
    function _expectExitEvent(address vault_, uint256 assets_, uint256 shares_) private {
        vm.expectEmit(address(vaultMock));
        emit Erc4626SupplyFuse.Erc4626SupplyFuseExit(address(fuse), address(underlyingToken), vault_, assets_, shares_);
    }
}
