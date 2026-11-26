// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";

import {ReserveVaultTestBase} from "./ReserveVaultTestBase.sol";
import {WindowRecorder, WindowProbeHook} from "./ReserveVaultLossFullExitTest.t.sol";

/// @dev Partial exits of the reserve vault while the member vault is at a loss, a gain followed by a loss, and a member
///      vault oracle price that is off the 1e6 grid of its 6-decimal asset
contract ReserveVaultLossPartialExitTest is ReserveVaultTestBase {
    bytes32 internal constant MARKET_BALANCES_UPDATED = keccak256("MarketBalancesUpdated(uint256[],int256)");
    bytes32 internal constant EXIT_EVENT =
        keccak256("ReserveVaultSupplyFuseExit(address,address,address,uint256,uint256,uint256,uint256,uint256)");

    uint256 internal constant C_SHARES = 10_000_000_000;

    struct ExitInfo {
        uint256 amount;
        uint256 sharesBurned;
        uint256 boost;
        uint256 surplusAssets;
        uint256 principal;
        uint256 exitCount;
        int256[] deltas;
    }

    /// @dev Vault formula with offset 2 (supply + 100), one virtual asset and zero fees
    function _assetsOf(uint256 shares_, PlasmaVault vault_) internal view returns (uint256) {
        return Math.mulDiv(shares_, vault_.totalAssets() + 1, vault_.totalSupply() + 100);
    }

    /// @dev Smallest boost that makes all `shares_` worth `principal_` (independent model of the fuse)
    function _modelBoost(PlasmaVault vault_, uint256 principal_, uint256 shares_) internal view returns (uint256) {
        uint256 needed = Math.mulDiv(principal_, vault_.totalSupply() + 100, shares_, Math.Rounding.Ceil);
        uint256 current = vault_.totalAssets() + 1;
        return needed > current ? needed - current : 0;
    }

    function _parse(Vm.Log[] memory logs_) internal view returns (ExitInfo memory info) {
        info.deltas = new int256[](4);
        uint256 deltaCount;
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == address(vaultA) && logs_[i].topics[0] == MARKET_BALANCES_UPDATED) {
                (uint256[] memory marketIds, int256 delta) = abi.decode(logs_[i].data, (uint256[], int256));
                assertEq(marketIds.length, 1, "one market refreshed");
                assertEq(marketIds[0], BOOST_MARKET, "boost market refreshed");
                info.deltas[deltaCount++] = delta;
            } else if (logs_[i].emitter == address(vaultC) && logs_[i].topics[0] == EXIT_EVENT) {
                ++info.exitCount;
                (, , , info.amount, info.sharesBurned, info.boost, info.surplusAssets, info.principal) = abi.decode(
                    logs_[i].data,
                    (address, address, address, uint256, uint256, uint256, uint256, uint256)
                );
            }
        }
    }

    function _exitRecorded(uint256 amount_) internal returns (ExitInfo memory info, uint256 received) {
        uint256 usdcBefore = usdc.balanceOf(address(vaultC));
        vm.recordLogs();
        _reserveExit(vaultA, amount_);
        info = _parse(vm.getRecordedLogs());
        received = usdc.balanceOf(address(vaultC)) - usdcBefore;
    }

    function _assertBoostGone(string memory label_) internal view {
        assertEq(vaultA.totalAssetsInMarket(BOOST_MARKET), 0, string.concat(label_, ": market 62"));
        assertEq(_boost(vaultA), 0, string.concat(label_, ": boost"));
    }

    function testShouldPayPrincipalInTwoPartialExitsWhenMemberVaultLost() public {
        // given
        uint256 usersShares = _userDeposit(USERS_DEPOSIT);
        _fundC(PRINCIPAL);
        _reserveEnter(vaultA, PRINCIPAL);
        _loss(vaultA, LOSS);
        assertEq(vaultA.balanceOf(address(vaultC)), C_SHARES, "C shares");
        assertEq(vaultA.convertToAssets(C_SHARES), 90_000_000, "C position below principal");

        uint256 firstBoost = _modelBoost(vaultA, PRINCIPAL, C_SHARES);
        assertEq(firstBoost, 111_111_111, "model: first boost");

        // when: first exit 40
        (ExitInfo memory first, uint256 receivedFirst) = _exitRecorded(40_000_000);

        // then
        assertEq(first.exitCount, 1, "one exit event");
        assertEq(first.amount, 40_000_000, "first amount");
        assertEq(first.sharesBurned, 4_000_000_000, "first burns 40%");
        assertEq(first.boost, firstBoost, "first boost");
        assertEq(first.surplusAssets, 0, "first surplus");
        assertEq(first.principal, 60_000_000, "first principal");
        assertEq(first.deltas[0], int256(firstBoost), "first boost booked");
        assertEq(first.deltas[1], -int256(firstBoost), "first boost released");
        assertEq(first.deltas[2], 0, "no further refresh");
        assertEq(receivedFirst, 40_000_000, "first received");
        assertEq(vaultA.balanceOf(address(vaultC)), 6_000_000_000, "C shares after first");
        assertEq(_principal(vaultA), 60_000_000, "principal after first");
        assertEq(vaultA.totalAssets(), 960_000_000, "A assets after first");
        assertEq(_sharePrice(vaultA), 896_265, "A price after first");
        assertEq(_assetsOf(usersShares, vaultA), vaultA.convertToAssets(usersShares), "model: others after first");
        _assertBoostGone("after first");

        // and: second exit takes the rest, boost computed again from the remainder
        uint256 secondBoost = _modelBoost(vaultA, 60_000_000, 6_000_000_000);
        assertGt(secondBoost, 0, "model: second boost");

        // when
        (ExitInfo memory second, uint256 receivedSecond) = _exitRecorded(60_000_000);

        // then
        assertEq(second.exitCount, 1, "one second exit event");
        assertEq(second.sharesBurned, 6_000_000_000, "second burns the rest");
        assertEq(second.boost, secondBoost, "second boost");
        assertEq(second.surplusAssets, 0, "second surplus");
        assertEq(second.principal, 0, "second principal");
        assertEq(second.deltas[0], int256(secondBoost), "second boost booked");
        assertEq(second.deltas[1], -int256(secondBoost), "second boost released");
        assertEq(receivedSecond, 60_000_000, "second received");
        assertEq(receivedFirst + receivedSecond, PRINCIPAL, "total received equals principal");
        assertEq(vaultA.balanceOf(address(vaultC)), 0, "no C shares left");
        assertEq(_principal(vaultA), 0, "principal zero, no dust");
        assertEq(vaultA.totalSupply(), usersShares, "A supply");
        assertEq(vaultA.totalAssets(), 900_000_000, "A assets after second");
        assertEq(_sharePrice(vaultA), 890_109, "A price after second");
        assertEq(vaultA.convertToAssets(usersShares), 900_000_000, "others after second");
        assertEq(_assetsOf(usersShares, vaultA), 900_000_000, "model: others after second");
        _assertBoostGone("after second");
        assertEq(vaultC.totalAssets(), PRINCIPAL, "C total assets");
        assertEq(vaultC.totalAssetsInMarket(RESERVE_MARKET), 0, "C market 61");
    }

    function testShouldExitRemainderWithBoostAfterProfitPartialExitWithoutBoost() public {
        // given: C enters, A gains, so the position is above the principal
        uint256 usersShares = _userDeposit(USERS_DEPOSIT);
        _fundC(PRINCIPAL);
        _reserveEnter(vaultA, PRINCIPAL);
        _gain(vaultA, GAIN);
        assertGt(vaultA.convertToAssets(C_SHARES), PRINCIPAL, "position above principal");

        // when: partial exit while in profit
        (ExitInfo memory first, uint256 receivedFirst) = _exitRecorded(40_000_000);

        // then: no boost
        assertEq(first.exitCount, 1, "one exit event");
        assertEq(first.boost, 0, "no boost in profit");
        assertEq(first.deltas[0], 0, "no market 62 refresh");
        assertEq(first.surplusAssets, 0, "no surplus on partial exit");
        assertEq(first.principal, 60_000_000, "principal after first");
        assertEq(receivedFirst, 40_000_000, "received first");
        uint256 sharesLeft = vaultA.balanceOf(address(vaultC));
        assertEq(sharesLeft, C_SHARES - first.sharesBurned, "shares left");
        assertGt(sharesLeft, 0, "shares left non-zero");
        _assertBoostGone("after first");

        // and: A then loses so that the remaining position is below the remaining principal
        _loss(vaultA, 2 * GAIN + 111_111_111);
        assertLt(vaultA.convertToAssets(sharesLeft), 60_000_000, "remainder below principal");
        uint256 boost = _modelBoost(vaultA, 60_000_000, sharesLeft);
        assertGt(boost, 0, "model: boost");

        WindowRecorder recorder = new WindowRecorder(vaultA, vaultC, address(boostFuse), BOOST_MARKET);
        _setPreHook(vaultA, IERC4626.withdraw.selector, address(new WindowProbeHook(recorder)));

        // when: exit the rest
        (ExitInfo memory second, uint256 receivedSecond) = _exitRecorded(60_000_000);

        // then
        assertEq(second.exitCount, 1, "one second exit event");
        assertEq(second.boost, boost, "boost of the remainder");
        assertEq(second.deltas[0], int256(boost), "boost booked");
        assertEq(second.deltas[1], -int256(boost), "boost released");
        assertEq(second.sharesBurned, sharesLeft, "all remaining shares burned");
        assertEq(second.surplusAssets, 0, "no surplus");
        assertEq(second.principal, 0, "principal zero");
        assertEq(receivedSecond, 60_000_000, "exactly the remaining principal");
        assertEq(recorder.calls(), 1, "probe ran once");
        assertEq(recorder.boostMarketAssets(), boost, "window: market 62");
        assertEq(recorder.reservePosition(), 60_000_000, "window: C position equals remaining principal");
        assertEq(vaultA.balanceOf(address(vaultC)), 0, "no C shares left");
        assertEq(_principal(vaultA), 0, "principal zero");
        assertEq(vaultA.totalSupply(), usersShares, "A supply");
        _assertBoostGone("after second");
    }

    function testShouldBookExactBoostWhenOraclePriceIsOffTheGrid() public {
        // given: USDC at 0.999873211457913207 USD, 18 decimals
        feedA.setPrice(999_873_211_457_913_207);
        uint256 usersShares = _userDeposit(USERS_DEPOSIT);
        _fundC(PRINCIPAL);
        _reserveEnter(vaultA, PRINCIPAL);
        _loss(vaultA, LOSS);
        assertEq(vaultA.balanceOf(address(vaultC)), C_SHARES, "C shares");

        uint256 boost = _modelBoost(vaultA, PRINCIPAL, C_SHARES);
        assertEq(boost, 111_111_111, "model: boost");

        WindowRecorder recorder = new WindowRecorder(vaultA, vaultC, address(boostFuse), BOOST_MARKET);
        _setPreHook(vaultA, IERC4626.withdraw.selector, address(new WindowProbeHook(recorder)));

        // when
        (ExitInfo memory info, uint256 received) = _exitRecorded(PRINCIPAL);

        // then: A books exactly X despite the price
        assertEq(info.exitCount, 1, "one exit event");
        assertEq(info.boost, boost, "event boost");
        assertEq(info.deltas[0], int256(boost), "booked exactly the boost");
        assertEq(info.deltas[1], -int256(boost), "released exactly the boost");
        assertEq(recorder.calls(), 1, "probe ran once");
        assertEq(recorder.boostMarketAssets(), boost, "window: market 62 holds exactly X");
        assertEq(recorder.boostRead(), boost, "window: boost read");
        assertEq(recorder.totalAssets(), 1_000_000_000 + boost, "window: A total assets");
        assertEq(recorder.reservePosition(), PRINCIPAL, "window: C position equals principal");

        assertEq(received, PRINCIPAL, "C received the principal");
        assertEq(info.sharesBurned, C_SHARES, "all shares burned");
        assertEq(info.principal, 0, "principal zero");
        assertEq(vaultA.balanceOf(address(vaultC)), 0, "no C shares left");
        assertEq(vaultA.totalSupply(), usersShares, "A supply");
        assertEq(vaultA.totalAssets(), 900_000_000, "A assets after exit");
        _assertBoostGone("after exit");
    }
}
