// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {RequestBackingTestBase, RequestBackingActor} from "./RequestBackingTestBase.sol";

/// @notice IL-9603 (M13, Olympix 2026-11-06 #5.1.13): the Olympix path is `requestShares` without shares followed by
///         `redeemFromRequest` in the same transaction, which used to consume the shared `sharesToRelease` pool that
///         ALPHA released for honest requesters. The fix landed in IL-9531 (requests are backed by a balance, the vault
///         keeps a request cap that only goes down). This test pins the exact report path with inverted assertions:
///         the unbacked request is refused, a request whose backing left cannot redeem, and the honest requester still
///         gets the full release afterwards. It passes on the base commit as well (pinning, no regression proof).
contract OlympixUnbackedRequestPoolDrainTest is RequestBackingTestBase {
    bytes4 internal constant NOT_BACKED = bytes4(keccak256("WithdrawManagerRequestNotBacked(address,uint256,uint256)"));
    bytes4 internal constant CAP_EXCEEDED =
        bytes4(keccak256("WithdrawManagerRequestCapExceeded(address,uint256,uint256)"));

    /// (a) The attacker holds no shares: the request that would have claimed the pool is refused.
    function testUnbackedRequestIsRefused() public {
        uint256 q = _depositAndRequest(HONEST, 100_000e6);
        vm.warp(block.timestamp + 1 hours);
        _release(q);

        vm.expectRevert(abi.encodeWithSelector(NOT_BACKED, address(actor), 0, q));
        actor.request(wm, q);

        assertEq(_requestShares(address(actor)), 0, "no request was stored");
        assertEq(wm.getSharesToRelease(), q, "the released pool is untouched");
    }

    /// (b) deposit -> request -> transfer shares away -> redeemFromRequest with fresh shares: the pool is not used
    ///     beyond the request cap, which followed the balance down to zero.
    function testRedeemFromRequestDoesNotConsumePoolAboveCap() public {
        uint256 q = _deposit(HONEST, 100_000e6);
        uint256 x = actor.deposit(vault, IERC20(address(usdc)), _mintTo(address(actor), 1_000_000e6));
        vm.warp(block.timestamp + DELAY + 1);
        vm.prank(HONEST);
        wm.requestShares(q);
        actor.request(wm, x);
        actor.transfer(vault, BYSTANDER, x);
        assertEq(vault.getRequestCap(address(actor)), 0, "cap followed the balance to zero");

        vm.warp(block.timestamp + 1 hours);
        _release(q);

        // Fresh shares minted just before the redeem (stand-in for a flash loan) do not refill the cap
        uint256 s = actor.deposit(vault, IERC20(address(usdc)), _mintTo(address(actor), vault.previewMint(q)));
        vm.warp(block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(CAP_EXCEEDED, address(actor), 0, s));
        actor.redeemFromRequest(vault, s);

        assertEq(wm.getSharesToRelease(), q, "the pool was not consumed by the attacker");
    }

    /// (b') Same-transaction strike (mint + redeemFromRequest) on a request without backing is refused as well.
    function testSameTransactionStrikeIsRefused() public {
        uint256 q = _depositAndRequest(HONEST, 100_000e6);
        uint256 x = actor.deposit(vault, IERC20(address(usdc)), _mintTo(address(actor), 200_000e6));
        vm.warp(block.timestamp + DELAY + 1);
        actor.request(wm, x);
        actor.transfer(vault, BYSTANDER, x);
        vm.warp(block.timestamp + 1 hours);
        _release(q);

        usdc.mint(address(actor), vault.previewMint(q));
        vm.expectRevert(abi.encodeWithSelector(CAP_EXCEEDED, address(actor), 0, q));
        actor.strike(vault, IERC20(address(usdc)), q);

        assertEq(wm.getSharesToRelease(), q, "the pool is intact after the refused strike");
    }

    /// (c) After the attempted attack the honest requester redeems the whole release and the pool is emptied by it.
    function testHonestRequesterKeepsFullReleaseAfterAttempt() public {
        uint256 q = _depositAndRequest(HONEST, 100_000e6);
        uint256 x = actor.deposit(vault, IERC20(address(usdc)), _mintTo(address(actor), 1_000_000e6));
        vm.warp(block.timestamp + DELAY + 1);
        actor.request(wm, x);
        actor.transfer(vault, BYSTANDER, x);
        vm.warp(block.timestamp + 1 hours);
        _release(q);

        vm.expectRevert(abi.encodeWithSelector(CAP_EXCEEDED, address(actor), 0, x));
        actor.redeemFromRequest(vault, x);

        vm.prank(HONEST);
        uint256 assets = vault.redeemFromRequest(q, HONEST, HONEST);

        assertApproxEqAbs(assets, 100_000e6, 1, "the honest requester got the full amount");
        assertEq(wm.getSharesToRelease(), 0, "the release was consumed by the honest requester only");
        assertEq(usdc.balanceOf(address(actor)), 0, "the attacker received nothing");
    }
}
