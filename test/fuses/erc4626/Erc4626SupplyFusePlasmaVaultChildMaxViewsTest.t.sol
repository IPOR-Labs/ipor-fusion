// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import {Erc4626SupplyFuse, Erc4626SupplyFuseExitData} from "../../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";
import {RequestBackingTestBase} from "../../vaults/request_backing/RequestBackingTestBase.sol";
import {TestAddresses} from "../../test_helpers/TestAddresses.sol";

/// @notice IL-9624 follow-up, consumer of the max views: a parent vault that exits a real PlasmaVault child through
///         `Erc4626SupplyFuse` (the fuse sizes a full exit from the child's `maxWithdraw` and `maxRedeem`).
///         A child that reserves assets for released requests caps `maxRedeem` below the balance, so the full exit
///         redeems the capped part instead of reverting; a closed child or a child with a reserve limit of 0 reports
///         0, the fuse falls back to the balance and the child refuses the redeem (`exit` reverts, `instantWithdraw`
///         emits `Erc4626SupplyFuseExitFailed`).
/// @dev Harness: RequestBackingTestBase (real PlasmaVault clone, WithdrawManager wired to the vault, 1 % instant
///      withdraw fee, one-day redemption delay, all assets idle). The parent is a `PlasmaVaultMock` that delegatecalls
///      the fuse and holds 100 000 USDC of child shares next to a 150 000 USDC holder whose request is released.
///      Shares and the withdraw fee: `previewRedeem` pays `floor(shares * (1 - fee))` while the redeem burns
///      `floor(shares * fee)`, so with a fee the payout of `redeem(maxRedeem)` is `previewRedeem(maxRedeem)` only
///      when `maxRedeem` is a multiple of 100 (1 %); the binding fixtures raise R by the remainder to get there.
contract Erc4626SupplyFusePlasmaVaultChildMaxViewsTest is RequestBackingTestBase {
    bytes4 internal constant INVALID_SHARES_TO_RELEASE =
        bytes4(keccak256("WithdrawManagerInvalidSharesToRelease(uint256,uint256,uint256)"));

    event Erc4626SupplyFuseExit(
        address version,
        address asset,
        address vault,
        uint256 vaultAssetAmount,
        uint256 shares
    );
    event Erc4626SupplyFuseExitFailed(address version, address asset, address vault, uint256 vaultAssetAmount);

    uint256 internal constant PARENT_DEPOSIT = 100_000e6;
    uint256 internal constant HOLDER_DEPOSIT = 150_000e6;

    Erc4626SupplyFuse internal fuse;
    PlasmaVaultMock internal parent;
    uint256 internal holderShares;

    function setUp() public override {
        super.setUp();

        fuse = new Erc4626SupplyFuse(1);
        parent = new PlasmaVaultMock(address(fuse), address(fuse));
        address[] memory substrates = new address[](1);
        substrates[0] = address(vault);
        parent.grantAssetsToMarket(fuse.MARKET_ID(), substrates);

        _deposit(address(parent), PARENT_DEPOSIT);
        holderShares = _depositAndRequest(HONEST, HOLDER_DEPOSIT);
        vm.warp(block.timestamp + 1 hours);
    }

    // ------------------------------------------------------------------ (a) child limited by the reserve

    /// @dev Full exit from a child whose reserve binds: exactly `maxRedeem` shares are redeemed, the rest stays, and
    ///      the payout is the view of the child (C19: R is raised so that `maxRedeem` is a multiple of 100 shares and
    ///      the fee rounding of the burn and of the preview agree)
    function testShouldRedeemExactlyMaxRedeem_whenFullExitFromChildLimitedByReserve() public {
        uint256 maxShares = _releaseBindingReserve();
        uint256 maxAssets = vault.maxWithdraw(address(parent));
        uint256 parentShares = vault.balanceOf(address(parent));
        assertLt(maxShares, parentShares, "precondition: the reserve binds");
        assertGt(maxShares, 0, "precondition: maxRedeem is positive");
        assertEq(maxShares % 100, 0, "precondition: maxRedeem is a multiple of the 1 % fee");
        assertEq(maxAssets, vault.previewRedeem(maxShares), "precondition: maxWithdraw prices maxRedeem");

        uint256 assetsBefore = usdc.balanceOf(address(parent));
        _exit(type(uint256).max, 0);

        assertEq(vault.balanceOf(address(parent)), parentShares - maxShares, "exactly maxRedeem shares are redeemed");
        assertGt(vault.balanceOf(address(parent)), 0, "the rest of the position stays");
        assertEq(usdc.balanceOf(address(parent)) - assetsBefore, maxAssets, "payout equals previewRedeem(maxRedeem)");
    }

    /// @dev Control (passes on the base too): the views of the child agree, also while the reserve binds
    function testShouldPriceMaxWithdrawAsPreviewRedeemOfMaxRedeem_whenReserveBinds() public {
        uint256 maxShares = _releaseBindingReserve();

        assertEq(
            vault.maxWithdraw(address(parent)),
            vault.previewRedeem(maxShares),
            "maxWithdraw == previewRedeem(maxRedeem)"
        );
    }

    // ------------------------------------------------------------------ (b) minAssetsOut under the whole position

    /// @dev `minAssetsOut` set for the whole position makes the capped exit revert with the received amount
    function testShouldRevertWithInsufficientAssets_whenMinAssetsOutCoversWholePositionAndReserveBinds() public {
        uint256 maxShares = _releaseBindingReserve();
        uint256 wholePosition = vault.previewRedeem(vault.balanceOf(address(parent)));
        uint256 capped = vault.previewRedeem(maxShares);
        assertLt(capped, wholePosition, "precondition: the capped payout is below the whole position");
        uint256 parentShares = vault.balanceOf(address(parent));

        vm.expectRevert(
            abi.encodeWithSelector(
                Erc4626SupplyFuse.Erc4626SupplyFuseInsufficientAssets.selector,
                capped,
                wholePosition
            )
        );
        _exit(type(uint256).max, wholePosition);

        assertEq(vault.balanceOf(address(parent)), parentShares, "nothing redeemed after the revert");
    }

    // ------------------------------------------------------------------ (c) instantWithdraw, child limited

    /// @dev `instantWithdraw` against a child limited by the reserve exits the capped part and emits the exit event
    function testShouldExitCappedPart_whenInstantWithdrawFromChildLimitedByReserve() public {
        uint256 maxShares = _releaseBindingReserve();
        uint256 maxAssets = vault.maxWithdraw(address(parent));
        uint256 parentShares = vault.balanceOf(address(parent));

        vm.expectEmit(true, true, true, true, address(parent));
        emit Erc4626SupplyFuseExit(address(fuse), address(usdc), address(vault), maxAssets, maxShares);
        parent.instantWithdraw(_instantWithdrawParams());

        assertEq(vault.balanceOf(address(parent)), parentShares - maxShares, "the capped part is redeemed");
        assertEq(usdc.balanceOf(address(parent)), maxAssets, "payout equals previewRedeem(maxRedeem)");
    }

    // ------------------------------------------------------------------ (d) closed child

    /// @dev A closed child reports 0 on both views; the fuse falls back to the balance and `exit` reverts with the
    ///      access manager error (the revert itself also holds on the base)
    function testShouldRevertExit_whenChildIsClosed() public {
        uint256 maxShares = vault.maxRedeem(address(parent));
        uint256 maxAssets = vault.maxWithdraw(address(parent));
        assertGt(maxShares, 0, "precondition: maxRedeem is positive before closing");
        assertGt(maxAssets, 0, "precondition: maxWithdraw is positive before closing");
        _closeChild();

        assertEq(vault.maxWithdraw(address(parent)), 0, "maxWithdraw is 0 while closed");
        assertEq(vault.maxRedeem(address(parent)), 0, "maxRedeem is 0 while closed");

        uint256 parentShares = vault.balanceOf(address(parent));
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(parent)));
        _exit(type(uint256).max, 0);
        assertEq(vault.balanceOf(address(parent)), parentShares, "the position is untouched");
    }

    /// @dev Control (passes on the base too): `exit` of a closed child reverts. Without the views the closed child
    ///      still pays nothing, so this isolates the revert from the view assertions above
    function testShouldRevertExitWithAccessManagedUnauthorized_whenChildClosedAndViewsIgnored() public {
        _closeChild();

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(parent)));
        _exit(type(uint256).max, 0);
    }

    /// @dev `instantWithdraw` against a closed child catches the refusal and emits the failure event with the
    ///      preview of the whole position
    function testShouldEmitExitFailed_whenInstantWithdrawFromClosedChild() public {
        _closeChild();
        uint256 parentShares = vault.balanceOf(address(parent));
        uint256 preview = vault.previewRedeem(parentShares);

        vm.expectEmit(true, true, true, true, address(parent));
        emit Erc4626SupplyFuseExitFailed(address(fuse), address(usdc), address(vault), preview);
        parent.instantWithdraw(_instantWithdrawParams());

        assertEq(vault.balanceOf(address(parent)), parentShares, "the position is untouched");
        assertEq(usdc.balanceOf(address(parent)), 0, "nothing paid");
    }

    // ------------------------------------------------------------------ (e) reserve limit 0

    /// @dev The released shares cover the whole supply: both views of the child read 0 (they read the balance on the
    ///      base)
    function testShouldReturnZeroMaxViews_whenChildReserveLimitIsZero() public {
        assertGt(vault.maxRedeem(address(parent)), 0, "precondition: maxRedeem is positive before the release");
        _releaseWholeSupply();

        assertEq(vault.maxRedeem(address(parent)), 0, "maxRedeem is 0");
        assertEq(vault.maxWithdraw(address(parent)), 0, "maxWithdraw is 0");
    }

    /// @dev The released shares cover the whole supply: the limit is 0, `exit` reverts with the WithdrawManager error
    ///      (control: the base reverts the same way)
    function testShouldRevertExit_whenChildReserveLimitIsZero() public {
        _releaseWholeSupply();
        uint256 parentShares = vault.balanceOf(address(parent));

        vm.expectPartialRevert(INVALID_SHARES_TO_RELEASE);
        _exit(type(uint256).max, 0);

        assertEq(vault.balanceOf(address(parent)), parentShares, "the position is untouched");
    }

    /// @dev Control (passes on the base too): `instantWithdraw` against a child with limit 0 emits the failure event
    function testShouldEmitExitFailed_whenInstantWithdrawFromChildWithReserveLimitZero() public {
        _releaseWholeSupply();
        uint256 parentShares = vault.balanceOf(address(parent));
        uint256 preview = vault.previewRedeem(parentShares);

        vm.expectEmit(true, true, true, true, address(parent));
        emit Erc4626SupplyFuseExitFailed(address(fuse), address(usdc), address(vault), preview);
        parent.instantWithdraw(_instantWithdrawParams());

        assertEq(vault.balanceOf(address(parent)), parentShares, "the position is untouched");
    }

    // ------------------------------------------------------------------ gas reports (no assertions on numbers)

    /// @notice Gas of a partial exit of the parent through the fuse, R = 0.
    /// @dev Method: warm. One partial exit (assets / 10) warms the storage and the access manager, then a second
    ///      identical partial exit is measured with `vm.lastCallGas().gasTotalUsed` taken right after the call; the
    ///      position is non-empty before and after. Comparable with the base.
    function testGasReportComparablePartialExit() public {
        uint256 assets = vault.previewRedeem(vault.balanceOf(address(parent))) / 10;
        _exit(assets, 0);
        assertGt(vault.balanceOf(address(parent)), 0, "position not empty before the measured exit");

        _exit(assets, 0);
        uint256 gas = vm.lastCallGas().gasTotalUsed;

        assertGt(vault.balanceOf(address(parent)), 0, "position not empty after the measured exit");
        emit log_named_uint("gas parent exit partial, warm, R = 0", gas);
    }

    /// @notice Gas of a full exit of the parent through the fuse, R = 0.
    /// @dev Method: one warm-up partial exit (assets / 10) in the same test, then ONE full exit (amount = max) is
    ///      measured with `vm.lastCallGas().gasTotalUsed` on the non-empty position (a second full exit would measure
    ///      an empty one). Comparable with the base.
    function testGasReportComparableFullExit() public {
        _exit(vault.previewRedeem(vault.balanceOf(address(parent))) / 10, 0);
        uint256 sharesBefore = vault.balanceOf(address(parent));
        assertGt(sharesBefore, 0, "position not empty before the measured exit");

        _exit(type(uint256).max, 0);
        uint256 gas = vm.lastCallGas().gasTotalUsed;

        assertEq(vault.balanceOf(address(parent)), 0, "full exit emptied the position");
        emit log_named_uint("gas parent exit full, one call after a partial warm-up, R = 0", gas);
    }

    /// @notice Gas of a full exit of the parent from a child limited by the reserve (HEAD only: on the base this exit
    ///         reverts because the fuse redeems the whole balance).
    /// @dev Method: the reserve binds, one warm-up partial exit (assets / 10, below the limit) in the same test, then
    ///      ONE full exit (amount = max) is measured with `vm.lastCallGas().gasTotalUsed`; the position is non-empty
    ///      before and after (the capped part is redeemed).
    function testGasReportHeadOnlyFullExitFromChildLimitedByReserve() public {
        _releaseBindingReserve();
        _exit(vault.previewRedeem(vault.balanceOf(address(parent))) / 10, 0);
        uint256 sharesBefore = vault.balanceOf(address(parent));
        assertGt(sharesBefore, 0, "position not empty before the measured exit");

        _exit(type(uint256).max, 0);
        uint256 gas = vm.lastCallGas().gasTotalUsed;

        assertGt(vault.balanceOf(address(parent)), 0, "the capped exit leaves the rest");
        assertLt(vault.balanceOf(address(parent)), sharesBefore, "the capped exit redeemed shares");
        emit log_named_uint("gas parent exit full from reserve-limited child, one call after a partial warm-up", gas);
    }

    // ------------------------------------------------------------------ helpers

    /// @dev Releases the request of the holder plus a fifth of the parent position, so the limit of the parent is
    ///      about 80 % of its balance, then raises R by `maxRedeem % 100` so that `maxRedeem` is a multiple of 100.
    ///      Returns the final `maxRedeem` of the parent.
    function _releaseBindingReserve() internal returns (uint256 maxShares) {
        uint256 reserve = holderShares + vault.balanceOf(address(parent)) / 5;
        _release(reserve);
        maxShares = vault.maxRedeem(address(parent));
        uint256 remainder = maxShares % 100;
        if (remainder > 0) {
            vm.warp(block.timestamp + 1);
            _release(reserve + remainder);
            maxShares = vault.maxRedeem(address(parent));
        }
    }

    function _releaseWholeSupply() internal {
        _release(vault.totalSupply());
    }

    function _closeChild() internal {
        vm.prank(TestAddresses.GUARDIAN);
        accessManager.updateTargetClosed(address(vault), true);
    }

    function _exit(uint256 assets_, uint256 minAssetsOut_) internal {
        parent.exitErc4626Supply(
            Erc4626SupplyFuseExitData({
                vault: address(vault),
                vaultAssetAmount: assets_,
                maxSharesBurned: 0,
                minAssetsOut: minAssetsOut_
            })
        );
    }

    function _instantWithdrawParams() internal view returns (bytes32[] memory params) {
        params = new bytes32[](2);
        params[0] = bytes32(type(uint256).max);
        params[1] = bytes32(uint256(uint160(address(vault))));
    }
}
