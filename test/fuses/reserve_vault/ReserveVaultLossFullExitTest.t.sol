// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";

import {PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";
import {IPreHook} from "../../../contracts/handlers/pre_hooks/IPreHook.sol";
import {UniversalReader} from "../../../contracts/universal_reader/UniversalReader.sol";
import {ReserveVaultBoostBalanceFuse} from "../../../contracts/fuses/reserve_vault/ReserveVaultBoostBalanceFuse.sol";

import {ReserveVaultTestBase} from "./ReserveVaultTestBase.sol";

/// @dev Records the member vault's view of the boost window; called by `WindowProbeHook` from inside the member vault
contract WindowRecorder {
    PlasmaVault internal immutable MEMBER;
    PlasmaVault internal immutable RESERVE;
    address internal immutable BOOST_FUSE;
    uint256 internal immutable BOOST_MARKET_ID;

    uint256 public calls;
    uint256 public totalAssets;
    uint256 public sharePrice;
    uint256 public reservePosition;
    uint256 public boostMarketAssets;
    uint256 public boostRead;

    constructor(PlasmaVault member_, PlasmaVault reserve_, address boostFuse_, uint256 boostMarketId_) {
        MEMBER = member_;
        RESERVE = reserve_;
        BOOST_FUSE = boostFuse_;
        BOOST_MARKET_ID = boostMarketId_;
    }

    function record() external {
        ++calls;
        totalAssets = MEMBER.totalAssets();
        sharePrice = MEMBER.convertToAssets(1e8);
        reservePosition = MEMBER.convertToAssets(MEMBER.balanceOf(address(RESERVE)));
        boostMarketAssets = MEMBER.totalAssetsInMarket(BOOST_MARKET_ID);
        boostRead = abi.decode(
            UniversalReader(address(RESERVE))
                .read(BOOST_FUSE, abi.encodeCall(ReserveVaultBoostBalanceFuse.readBoost, (address(MEMBER))))
                .data,
            (uint256)
        );
    }
}

/// @dev Pre-hook that runs by delegatecall in the member vault and reports to the recorder
contract WindowProbeHook is IPreHook {
    WindowRecorder public immutable RECORDER;

    constructor(WindowRecorder recorder_) {
        RECORDER = recorder_;
    }

    function run(bytes4) external override {
        RECORDER.record();
    }
}

/// @dev First proof of the whole chain: the reserve vault C lent PRINCIPAL to member vault A, A lost, C's whole position
///      is worth less than its principal, and C exits with the full principal. Real clones, `C.execute`, real
///      `A.updateMarketsBalances`; the boost is visible only inside the exit.
contract ReserveVaultLossFullExitTest is ReserveVaultTestBase {
    /// @dev keccak256("MarketBalancesUpdated(uint256[],int256)")
    bytes32 internal constant MARKET_BALANCES_UPDATED = keccak256("MarketBalancesUpdated(uint256[],int256)");
    bytes32 internal constant EXIT_EVENT =
        keccak256("ReserveVaultSupplyFuseExit(address,address,address,uint256,uint256,uint256,uint256,uint256)");

    uint256 internal constant C_SHARES = 10_000_000_000;
    uint256 internal constant BOOST = 111_111_111;

    /// @dev Vault formula with offset 2 (supply + 100), one virtual asset and zero fees
    function _assetsOf(uint256 shares_, PlasmaVault vault_) internal view returns (uint256) {
        return Math.mulDiv(shares_, vault_.totalAssets() + 1, vault_.totalSupply() + 100);
    }

    function testShouldPayFullPrincipalWhenMemberVaultLostAndPositionIsBelowPrincipal() public {
        // given: users deposit, C enters the principal
        uint256 usersShares = _userDeposit(USERS_DEPOSIT);
        _fundC(PRINCIPAL);
        uint256 cSharesBefore = vaultC.totalSupply();
        uint256 cPriceBefore = _sharePrice(vaultC);
        assertEq(cPriceBefore, 1_000_000, "C price 1:1 before enter");

        _reserveEnter(vaultA, PRINCIPAL);

        assertEq(vaultA.balanceOf(address(vaultC)), C_SHARES, "C shares in A");
        assertEq(_principal(vaultA), PRINCIPAL, "principal recorded");
        assertEq(vaultC.totalAssets(), PRINCIPAL, "C total assets after enter");
        assertEq(vaultC.totalAssetsInMarket(RESERVE_MARKET), PRINCIPAL, "C market 61 after enter");
        assertEq(_sharePrice(vaultC), cPriceBefore, "C price after enter");
        assertEq(vaultC.totalSupply(), cSharesBefore, "C supply after enter");

        // and: A loses
        _loss(vaultA, LOSS);

        assertEq(vaultA.totalAssets(), 1_000_000_000, "A total assets after loss");
        assertEq(_sharePrice(vaultA), 900_000, "A price after loss");
        assertEq(vaultA.convertToAssets(C_SHARES), 90_000_000, "C position after loss");
        assertEq(vaultA.convertToAssets(usersShares), 910_000_000, "others after loss");
        assertEq(vaultA.convertToAssets(C_SHARES), _assetsOf(C_SHARES, vaultA), "model: C position");
        assertEq(_assetsOf(usersShares, vaultA), 910_000_000, "model: others");
        assertEq(_sharePrice(vaultC), cPriceBefore, "C price after loss");
        assertEq(vaultC.totalAssets(), PRINCIPAL, "C total assets after loss");

        // and: without the boost the same withdrawal as C reverts (non-vacuity control)
        uint256 maxWithdraw = vaultA.maxWithdraw(address(vaultC));
        assertEq(maxWithdraw, 90_000_000, "max withdraw of C");
        vm.prank(address(vaultC));
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626Upgradeable.ERC4626ExceededMaxWithdraw.selector,
                address(vaultC),
                PRINCIPAL,
                maxWithdraw
            )
        );
        vaultA.withdraw(PRINCIPAL, address(vaultC), address(vaultC));

        // and: a probe inside the window (pre-hook on A.withdraw)
        WindowRecorder recorder = new WindowRecorder(vaultA, vaultC, address(boostFuse), BOOST_MARKET);
        _setPreHook(vaultA, IERC4626.withdraw.selector, address(new WindowProbeHook(recorder)));

        // independent model of the boost: the smallest X that makes all C shares worth the principal
        uint256 supplyPlusOffset = vaultA.totalSupply() + 100;
        uint256 neededAssets = Math.mulDiv(PRINCIPAL, supplyPlusOffset, C_SHARES, Math.Rounding.Ceil);
        assertEq(neededAssets - 1 - vaultA.totalAssets(), BOOST, "model: boost");

        uint256 usdcBeforeC = usdc.balanceOf(address(vaultC));
        vm.recordLogs();

        // when
        _reserveExit(vaultA, PRINCIPAL);

        // then: events
        Vm.Log[] memory logs = vm.getRecordedLogs();
        int256[] memory deltas = new int256[](4);
        uint256 deltaCount;
        uint256 exitCount;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(vaultA) && logs[i].topics[0] == MARKET_BALANCES_UPDATED) {
                (uint256[] memory marketIds, int256 delta) = abi.decode(logs[i].data, (uint256[], int256));
                assertEq(marketIds.length, 1, "one market refreshed");
                assertEq(marketIds[0], BOOST_MARKET, "boost market refreshed");
                deltas[deltaCount++] = delta;
            } else if (logs[i].emitter == address(vaultC) && logs[i].topics[0] == EXIT_EVENT) {
                ++exitCount;
                (
                    address version,
                    address vault,
                    address asset,
                    uint256 amount,
                    uint256 sharesBurned,
                    uint256 boost,
                    uint256 surplusAssets,
                    uint256 principal
                ) = abi.decode(logs[i].data, (address, address, address, uint256, uint256, uint256, uint256, uint256));
                assertEq(version, address(supplyFuse), "event version");
                assertEq(vault, address(vaultA), "event vault");
                assertEq(asset, address(usdc), "event asset");
                assertEq(amount, PRINCIPAL, "event amount");
                assertEq(sharesBurned, C_SHARES, "event shares burned");
                assertGt(boost, 0, "event boost");
                assertEq(boost, BOOST, "event boost value");
                assertEq(surplusAssets, 0, "event surplus");
                assertEq(principal, 0, "event principal");
            }
        }
        assertEq(exitCount, 1, "one exit event");
        assertEq(deltaCount, 2, "two market balance updates in A");
        assertEq(deltas[0], int256(BOOST), "boost booked");
        assertEq(deltas[1], -int256(BOOST), "boost released");

        // then: the window as seen from inside A.withdraw
        assertEq(recorder.calls(), 1, "probe ran once");
        assertEq(recorder.totalAssets(), 1_000_000_000 + BOOST, "window: A total assets");
        assertEq(recorder.sharePrice(), 1_000_000, "window: A price");
        assertEq(recorder.reservePosition(), PRINCIPAL, "window: C position");
        assertEq(recorder.boostMarketAssets(), BOOST, "window: market 62");
        assertEq(recorder.boostRead(), BOOST, "window: boost read");

        // then: C got exactly its principal
        assertEq(usdc.balanceOf(address(vaultC)) - usdcBeforeC, PRINCIPAL, "C received the principal");
        assertEq(vaultA.balanceOf(address(vaultC)), 0, "all C shares burned");
        assertEq(vaultA.totalSupply(), usersShares, "A supply after exit");
        assertEq(usdc.balanceOf(address(vaultA)), 900_000_000, "A assets after exit");
        assertEq(vaultA.totalAssets(), 900_000_000, "A total assets after exit");

        // then: the boost is gone after the transaction (isolate = false: explicit clear, not the end of the tx)
        assertEq(vaultA.totalAssetsInMarket(BOOST_MARKET), 0, "market 62 is zero");
        assertEq(_boost(vaultA), 0, "boost cleared");
        assertEq(_principal(vaultA), 0, "principal zero");

        // then: the holders left in A absorb the shortfall
        assertEq(_sharePrice(vaultA), 890_109, "A price after exit");
        assertEq(vaultA.convertToAssets(usersShares), 900_000_000, "others after exit");
        assertEq(_assetsOf(usersShares, vaultA), 900_000_000, "model: others after exit");

        // then: C stays 1:1
        assertEq(vaultC.totalAssets(), PRINCIPAL, "C total assets after exit");
        assertEq(vaultC.totalAssetsInMarket(RESERVE_MARKET), 0, "C market 61 after exit");
        assertEq(vaultC.totalSupply(), cSharesBefore, "C supply after exit");
        assertEq(_sharePrice(vaultC), cPriceBefore, "C price after exit");

        // then: B is untouched
        assertEq(vaultB.totalAssets(), 0, "B total assets");
        assertEq(vaultB.totalSupply(), 0, "B supply");
        assertEq(_principal(vaultB), 0, "B principal");
        assertEq(_boost(vaultB), 0, "B boost");
        assertEq(vaultB.totalAssetsInMarket(BOOST_MARKET), 0, "B market 62");
    }
}
