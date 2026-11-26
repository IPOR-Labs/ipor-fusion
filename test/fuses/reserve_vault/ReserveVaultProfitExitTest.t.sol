// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";
import {ReserveVaultSupplyFuse} from "../../../contracts/fuses/reserve_vault/ReserveVaultSupplyFuse.sol";

import {ReserveVaultTestBase} from "./ReserveVaultTestBase.sol";

/// @dev Profit case: the reserve vault C lent PRINCIPAL to member vault A, A gained, C's position is worth more than the
///      principal. The exit is a plain withdraw (no boost); the surplus goes back to A only when the principal reaches
///      zero. Real clones, `C.execute`, real `A.updateMarketsBalances` hooks.
contract ReserveVaultProfitExitTest is ReserveVaultTestBase {
    /// @dev keccak256("MarketBalancesUpdated(uint256[],int256)")
    bytes32 internal constant MARKET_BALANCES_UPDATED = keccak256("MarketBalancesUpdated(uint256[],int256)");
    bytes32 internal constant EXIT_EVENT =
        keccak256("ReserveVaultSupplyFuseExit(address,address,address,uint256,uint256,uint256,uint256,uint256)");

    uint256 internal constant C_SHARES = 10_000_000_000;
    uint256 internal constant SURPLUS = 9_999_999;

    struct ExitEvent {
        uint256 amount;
        uint256 sharesBurned;
        uint256 boost;
        uint256 surplusAssets;
        uint256 principal;
    }

    /// @dev Vault formula with offset 2 (supply + 100), one virtual asset and zero fees
    function _assetsOf(uint256 shares_, PlasmaVault vault_) internal view returns (uint256) {
        return Math.mulDiv(shares_, vault_.totalAssets() + 1, vault_.totalSupply() + 100);
    }

    /// @dev Shares burned by a withdraw of `assets_`, rounded up
    function _sharesFor(uint256 assets_, PlasmaVault vault_) internal view returns (uint256) {
        return Math.mulDiv(assets_, vault_.totalSupply() + 100, vault_.totalAssets() + 1, Math.Rounding.Ceil);
    }

    function _setUpProfit() internal returns (uint256 usersShares) {
        usersShares = _userDeposit(USERS_DEPOSIT);
        _fundC(PRINCIPAL);
        _reserveEnter(vaultA, PRINCIPAL);
        _gain(vaultA, 111_111_111);
    }

    function _decodeExit(bytes memory data_) internal view returns (ExitEvent memory ev) {
        address version;
        address vault;
        address asset;
        uint256[5] memory values;
        (version, vault, asset, values[0], values[1], values[2], values[3], values[4]) = abi.decode(
            data_,
            (address, address, address, uint256, uint256, uint256, uint256, uint256)
        );
        assertEq(version, address(supplyFuse), "event version");
        assertEq(vault, address(vaultA), "event vault");
        assertEq(asset, address(usdc), "event asset");
        ev = ExitEvent(values[0], values[1], values[2], values[3], values[4]);
    }

    /// @dev Reads the single exit event of C and counts the market balance updates in A
    function _readExit(Vm.Log[] memory logs_) internal view returns (ExitEvent memory ev, uint256 exitCount) {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == address(vaultA) && logs_[i].topics[0] == MARKET_BALANCES_UPDATED) {
                revert("unexpected market balance update in A");
            }
            if (logs_[i].emitter == address(vaultC) && logs_[i].topics[0] == EXIT_EVENT) {
                ++exitCount;
                ev = _decodeExit(logs_[i].data);
            }
        }
    }

    function testShouldReturnSurplusToMemberVaultOnFullExitInProfit() public {
        // given
        uint256 usersShares = _setUpProfit();
        uint256 cSharesBefore = vaultC.totalSupply();
        uint256 cPriceBefore = _sharePrice(vaultC);

        assertEq(vaultA.totalAssets(), 1_222_222_222, "A total assets after gain");
        assertEq(_sharePrice(vaultA), 1_099_999, "A price after gain");
        assertEq(vaultA.convertToAssets(C_SHARES), 109_999_999, "C position after gain");
        assertEq(vaultA.convertToAssets(C_SHARES), _assetsOf(C_SHARES, vaultA), "model: C position");
        assertEq(_sharePrice(vaultC), cPriceBefore, "C price after gain");

        uint256 withdrawShares = _sharesFor(PRINCIPAL, vaultA);
        assertEq(withdrawShares, 9_090_909_093, "model: shares burned by withdraw");
        uint256 usdcBeforeC = usdc.balanceOf(address(vaultC));
        vm.recordLogs();

        // when
        _reserveExit(vaultA, PRINCIPAL);

        // then: the event, and no boost refresh in A
        (ExitEvent memory ev, uint256 exitCount) = _readExit(vm.getRecordedLogs());
        assertEq(exitCount, 1, "one exit event");
        assertEq(ev.amount, PRINCIPAL, "event amount");
        assertEq(ev.boost, 0, "event boost");
        assertEq(ev.surplusAssets, SURPLUS, "event surplus");
        assertEq(ev.principal, 0, "event principal");
        assertEq(ev.sharesBurned, C_SHARES, "event shares burned: withdraw plus surplus redeem");
        assertEq(ev.sharesBurned - withdrawShares, 909_090_907, "surplus shares");

        // then: C got exactly its principal and all its A shares are gone
        assertEq(usdc.balanceOf(address(vaultC)) - usdcBeforeC, PRINCIPAL, "C received the principal");
        assertEq(vaultA.balanceOf(address(vaultC)), 0, "all C shares burned");
        assertEq(_principal(vaultA), 0, "principal zero");
        assertEq(_boost(vaultA), 0, "no boost");
        assertEq(vaultA.totalAssetsInMarket(BOOST_MARKET), 0, "market 62 is zero");

        // then: the surplus stayed in A and its price rises
        assertEq(vaultA.totalSupply(), usersShares, "A supply after exit");
        assertEq(usdc.balanceOf(address(vaultA)), 1_122_222_222, "A assets after exit");
        assertEq(vaultA.totalAssets(), 1_122_222_222, "A total assets after exit");
        assertEq(_sharePrice(vaultA), 1_109_890, "A price after exit");
        assertGt(_sharePrice(vaultA), 1_099_999, "A price rose");
        assertEq(vaultA.convertToAssets(usersShares), _assetsOf(usersShares, vaultA), "model: others after exit");

        // then: C stays 1:1
        assertEq(vaultC.totalAssets(), PRINCIPAL, "C total assets after exit");
        assertEq(vaultC.totalAssetsInMarket(RESERVE_MARKET), 0, "C market 61 after exit");
        assertEq(vaultC.totalSupply(), cSharesBefore, "C supply after exit");
        assertEq(_sharePrice(vaultC), cPriceBefore, "C price after exit");

        _assertBUntouched();
    }

    function testShouldReturnSurplusOnlyOnLastPartialExitInProfit() public {
        // given
        uint256 usersShares = _setUpProfit();
        uint256 cSharesBefore = vaultC.totalSupply();
        uint256 cPriceBefore = _sharePrice(vaultC);
        uint256 firstShares = _sharesFor(40_000_000, vaultA);
        uint256 usdcBeforeC = usdc.balanceOf(address(vaultC));
        vm.recordLogs();

        // when: first exit
        _reserveExit(vaultA, 40_000_000);

        // then: no surplus, no boost, no refresh of market 62
        (ExitEvent memory ev, uint256 exitCount) = _readExit(vm.getRecordedLogs());
        assertEq(exitCount, 1, "one exit event");
        assertEq(ev.amount, 40_000_000, "first: event amount");
        assertEq(ev.boost, 0, "first: event boost");
        assertEq(ev.surplusAssets, 0, "first: no surplus returned");
        assertEq(ev.principal, 60_000_000, "first: event principal");
        assertEq(ev.sharesBurned, firstShares, "first: shares burned");

        assertEq(usdc.balanceOf(address(vaultC)) - usdcBeforeC, 40_000_000, "first: C received 40");
        assertEq(_principal(vaultA), 60_000_000, "first: principal left");
        assertEq(vaultA.balanceOf(address(vaultC)), C_SHARES - firstShares, "first: C shares left");
        assertEq(vaultA.convertToAssets(vaultA.balanceOf(address(vaultC))), 69_999_999, "first: C position");
        assertEq(vaultA.totalAssets(), 1_222_222_222 - 40_000_000, "first: A total assets");
        assertEq(vaultA.totalSupply(), usersShares + C_SHARES - firstShares, "first: A supply");
        assertEq(_boost(vaultA), 0, "first: no boost");
        assertEq(vaultA.totalAssetsInMarket(BOOST_MARKET), 0, "first: market 62 is zero");
        assertEq(_sharePrice(vaultC), cPriceBefore, "first: C price");
        assertEq(vaultC.totalAssets(), PRINCIPAL, "first: C total assets");

        // when: second exit
        uint256 secondShares = _sharesFor(60_000_000, vaultA);
        vm.recordLogs();
        _reserveExit(vaultA, 60_000_000);

        // then: the surplus goes back to A
        (ev, exitCount) = _readExit(vm.getRecordedLogs());
        assertEq(exitCount, 1, "one exit event");
        assertEq(ev.amount, 60_000_000, "second: event amount");
        assertEq(ev.boost, 0, "second: event boost");
        assertEq(ev.surplusAssets, SURPLUS, "second: surplus returned");
        assertEq(ev.principal, 0, "second: event principal");
        assertEq(ev.sharesBurned, C_SHARES - firstShares, "second: all remaining shares burned");
        assertGt(ev.sharesBurned, secondShares, "second: surplus shares redeemed on top of the withdraw");

        assertEq(usdc.balanceOf(address(vaultC)) - usdcBeforeC, PRINCIPAL, "C received the whole principal");
        assertEq(vaultA.balanceOf(address(vaultC)), 0, "no C shares left");
        assertEq(_principal(vaultA), 0, "principal zero");
        assertEq(vaultA.totalSupply(), usersShares, "A supply after exit");
        assertEq(vaultA.totalAssets(), 1_122_222_222, "A total assets after exit");
        assertEq(_sharePrice(vaultA), 1_109_890, "A price after exit");
        assertEq(vaultA.totalAssetsInMarket(BOOST_MARKET), 0, "market 62 is zero");

        // then: C stays 1:1
        assertEq(vaultC.totalAssets(), PRINCIPAL, "C total assets after exit");
        assertEq(vaultC.totalSupply(), cSharesBefore, "C supply after exit");
        assertEq(_sharePrice(vaultC), cPriceBefore, "C price after exit");

        _assertBUntouched();
    }

    function testShouldRevertWhenExitAmountExceedsPrincipalInProfit() public {
        // given
        _setUpProfit();

        // when / then: the position is worth more than the principal, still no more than the principal can be taken
        vm.expectRevert(
            abi.encodeWithSelector(
                ReserveVaultSupplyFuse.ReserveVaultSupplyFuseAmountExceedsPrincipal.selector,
                address(vaultA),
                PRINCIPAL + 1,
                PRINCIPAL
            )
        );
        _reserveExit(vaultA, PRINCIPAL + 1);

        assertEq(_principal(vaultA), PRINCIPAL, "principal unchanged");
        assertEq(vaultA.balanceOf(address(vaultC)), C_SHARES, "shares unchanged");
    }

    function testShouldRevertSecondExitBeyondRemainingPrincipalAfterPartialExitInProfit() public {
        // given
        _setUpProfit();
        _reserveExit(vaultA, 40_000_000);

        // when / then
        vm.expectRevert(
            abi.encodeWithSelector(
                ReserveVaultSupplyFuse.ReserveVaultSupplyFuseAmountExceedsPrincipal.selector,
                address(vaultA),
                60_000_001,
                60_000_000
            )
        );
        _reserveExit(vaultA, 60_000_001);
    }

    function _assertBUntouched() internal view {
        assertEq(vaultB.totalAssets(), 0, "B total assets");
        assertEq(vaultB.totalSupply(), 0, "B supply");
        assertEq(_principal(vaultB), 0, "B principal");
        assertEq(_boost(vaultB), 0, "B boost");
        assertEq(vaultB.totalAssetsInMarket(BOOST_MARKET), 0, "B market 62");
    }
}
