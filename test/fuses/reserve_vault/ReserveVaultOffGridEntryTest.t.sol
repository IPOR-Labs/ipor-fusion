// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {UpdateBalancesPreHook} from "../../../contracts/handlers/pre_hooks/pre_hooks/UpdateBalancesPreHook.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";

import {ReserveVaultTestBase} from "./ReserveVaultTestBase.sol";

/// @dev C enters A at a share price that is not a round number ("off-grid"). The vault rounds the entry shares down,
///      so C's position is worth less than the principal right after the enter. Characterises two consequences:
///      every exit without a real gain needs a boost of at least 1 wei, and a boosted full exit leaves dust shares
///      worth 0 wei that the surplus step redeems. Expected values are recomputed with the vault formulas
///      (offset 2, one virtual asset, zero fees).
contract ReserveVaultOffGridEntryTest is ReserveVaultTestBase {
    /// @dev A gain before C enters, so the share price of A is not a round number
    uint256 internal constant PRE_GAIN = 111_111_111;
    /// @dev The share-supply offset of the vault (10^2) added to the total supply
    uint256 internal constant VIRTUAL_SHARES = 100;

    bytes32 internal constant WITHDRAW_TOPIC = keccak256("Withdraw(address,address,address,uint256,uint256)");
    bytes32 internal constant EXIT_TOPIC =
        keccak256("ReserveVaultSupplyFuseExit(address,address,address,uint256,uint256,uint256,uint256,uint256)");

    struct ExitEvent {
        address version;
        address vault;
        address asset;
        uint256 amount;
        uint256 sharesBurned;
        uint256 boost;
        uint256 surplusAssets;
        uint256 principal;
    }

    struct WithdrawEvent {
        address owner;
        uint256 assets;
        uint256 shares;
    }

    function _cShares() internal view returns (uint256) {
        return vaultA.balanceOf(address(vaultC));
    }

    /// @dev Vault formula: assets = shares * (totalAssets + 1) / (totalSupply + 100), rounded down
    function _modelAssets(uint256 shares_, uint256 totalAssets_, uint256 totalSupply_) internal pure returns (uint256) {
        return Math.mulDiv(shares_, totalAssets_ + 1, totalSupply_ + VIRTUAL_SHARES);
    }

    /// @dev Pre-gain, then C funds and enters A: C's shares are floor(P * D / (G + 1))
    function _setUpOffGridEntry() internal returns (uint256 shares) {
        _userDeposit(USERS_DEPOSIT);
        _gain(vaultA, PRE_GAIN);
        _fundC(PRINCIPAL);

        uint256 expectedShares = Math.mulDiv(
            PRINCIPAL,
            vaultA.totalSupply() + VIRTUAL_SHARES,
            vaultA.totalAssets() + 1
        );

        _reserveEnter(vaultA, PRINCIPAL);

        shares = _cShares();
        assertEq(shares, expectedShares, "entry shares are floor(P * D / (G + 1))");
        assertEq(_principal(vaultA), PRINCIPAL, "principal recorded");
        assertLt(
            _modelAssets(shares, vaultA.totalAssets(), vaultA.totalSupply()),
            PRINCIPAL,
            "off-grid: C position is below the principal right after the enter"
        );
    }

    function _findExit(Vm.Log[] memory logs_) internal view returns (ExitEvent memory e, uint256 count) {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == address(vaultC) && logs_[i].topics[0] == EXIT_TOPIC) {
                // a struct of static fields has the same encoding as the flat event data
                e = abi.decode(logs_[i].data, (ExitEvent));
                ++count;
            }
        }
    }

    /// @dev Withdraw events of A whose owner is C, in emission order
    function _cWithdraws(Vm.Log[] memory logs_) internal view returns (WithdrawEvent[] memory out) {
        uint256 n;
        for (uint256 i; i < logs_.length; ++i) {
            if (_isCWithdraw(logs_[i])) ++n;
        }
        out = new WithdrawEvent[](n);
        uint256 k;
        for (uint256 i; i < logs_.length; ++i) {
            if (_isCWithdraw(logs_[i])) {
                (uint256 assets, uint256 shares) = abi.decode(logs_[i].data, (uint256, uint256));
                out[k++] = WithdrawEvent(address(uint160(uint256(logs_[i].topics[3]))), assets, shares);
            }
        }
    }

    function _isCWithdraw(Vm.Log memory log_) private view returns (bool) {
        return
            log_.emitter == address(vaultA) &&
            log_.topics[0] == WITHDRAW_TOPIC &&
            address(uint160(uint256(log_.topics[3]))) == address(vaultC);
    }

    /// @dev Boost needed for a full exit: ceil(P * D / s) - (G + 1), zero when the position is worth the principal
    function _modelBoost(uint256 shares_) internal view returns (uint256) {
        uint256 needed = Math.mulDiv(PRINCIPAL, vaultA.totalSupply() + VIRTUAL_SHARES, shares_, Math.Rounding.Ceil);
        uint256 have = vaultA.totalAssets() + 1;
        return needed > have ? needed - have : 0;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Boosted full exit at a loss: dust redeem
    // ---------------------------------------------------------------------------------------------------------------

    function testShouldRedeemZeroValueDustAfterBoostedFullExitAtLossWhenEnteredOffGrid() public {
        // given
        uint256 shares = _setUpOffGridEntry();
        _loss(vaultA, LOSS);

        uint256 boost = _modelBoost(shares);
        assertGt(boost, 0, "model: a boost is needed at a loss");
        // the withdraw at the boosted total burns ceil(P * D / (G + boost + 1)) shares
        uint256 burnedByWithdraw = Math.mulDiv(
            PRINCIPAL,
            vaultA.totalSupply() + VIRTUAL_SHARES,
            vaultA.totalAssets() + boost + 1,
            Math.Rounding.Ceil
        );
        uint256 dust = shares - burnedByWithdraw;
        assertGt(dust, 0, "model: dust shares are left after the withdraw");

        uint256 idleBefore = usdc.balanceOf(address(vaultA));
        uint256 usdcCBefore = usdc.balanceOf(address(vaultC));

        // when
        vm.recordLogs();
        _reserveExit(vaultA, PRINCIPAL);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // then: the exit event reports the boost, all shares burned and a zero surplus
        (ExitEvent memory exitEvent, uint256 exitCount) = _findExit(logs);
        assertEq(exitCount, 1, "one exit event");
        assertEq(exitEvent.version, address(supplyFuse), "event version");
        assertEq(exitEvent.vault, address(vaultA), "event vault");
        assertEq(exitEvent.asset, address(usdc), "event asset");
        assertEq(exitEvent.amount, PRINCIPAL, "event amount");
        assertEq(exitEvent.sharesBurned, shares, "event: withdraw plus dust redeem burned every share");
        assertEq(exitEvent.boost, boost, "event boost");
        assertEq(exitEvent.surplusAssets, 0, "event: the dust is worth 0 wei");
        assertEq(exitEvent.principal, 0, "event principal");

        // then: A emitted two Withdraw events with owner C, the second one is the dust redeem of 0 assets
        WithdrawEvent[] memory withdraws = _cWithdraws(logs);
        assertEq(withdraws.length, 2, "withdraw and dust redeem");
        assertEq(withdraws[0].assets, PRINCIPAL, "first: the principal");
        assertEq(withdraws[0].shares, burnedByWithdraw, "first: shares burned by withdraw");
        assertEq(withdraws[1].assets, 0, "second: 0 assets");
        assertEq(withdraws[1].shares, dust, "second: dust shares");

        // then: C is made whole and the ledger is closed
        assertEq(usdc.balanceOf(address(vaultC)) - usdcCBefore, PRINCIPAL, "C received exactly the principal");
        assertEq(_cShares(), 0, "C holds no shares");
        assertEq(_principal(vaultA), 0, "principal zero");
        assertEq(_boost(vaultA), 0, "boost cleared");
        assertEq(vaultA.totalAssetsInMarket(BOOST_MARKET), 0, "market 62 cleared");
        assertEq(usdc.balanceOf(address(vaultA)), idleBefore - PRINCIPAL, "A idle fell by exactly the principal");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Flat exit: the boost is the normal path
    // ---------------------------------------------------------------------------------------------------------------

    function testShouldNeedBoostForFlatFullExitWhenEnteredOffGrid() public {
        // given: no gain and no loss after the enter
        uint256 shares = _setUpOffGridEntry();
        assertLt(vaultA.convertToAssets(shares), PRINCIPAL, "position is below the principal without any loss");
        uint256 boost = _modelBoost(shares);
        assertGt(boost, 0, "model: a boost of at least 1 wei is needed");
        uint256 usdcCBefore = usdc.balanceOf(address(vaultC));

        // when
        vm.recordLogs();
        _reserveExit(vaultA, PRINCIPAL);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // then
        (ExitEvent memory exitEvent, uint256 exitCount) = _findExit(logs);
        assertEq(exitCount, 1, "one exit event");
        assertEq(exitEvent.boost, boost, "event boost matches the model");
        assertGe(exitEvent.boost, 1, "boost of at least 1 wei");
        assertEq(exitEvent.amount, PRINCIPAL, "event amount");
        assertEq(exitEvent.sharesBurned, shares, "event: every share burned");
        assertEq(exitEvent.principal, 0, "event principal");
        assertEq(usdc.balanceOf(address(vaultC)) - usdcCBefore, PRINCIPAL, "C received exactly the principal");
        assertEq(_cShares(), 0, "C holds no shares");
        assertEq(_boost(vaultA), 0, "boost cleared");
        assertEq(vaultA.totalAssetsInMarket(BOOST_MARKET), 0, "market 62 cleared");
    }

    function testShouldRevertFlatFullExitWhenEnteredOffGridAndReserveVaultLostUpdateRole() public {
        // given
        uint256 shares = _setUpOffGridEntry();
        vm.prank(ATOMIST);
        accessManagerA.revokeRole(Roles.UPDATE_MARKETS_BALANCES_ROLE, address(vaultC));

        // when / then: the boost of at least 1 wei cannot be booked
        vm.expectRevert(
            abi.encodeWithSelector(IporFusionAccessManager.AccessManagedUnauthorized.selector, address(vaultC))
        );
        _reserveExit(vaultA, PRINCIPAL);

        assertEq(_principal(vaultA), PRINCIPAL, "principal unchanged");
        assertEq(_cShares(), shares, "shares unchanged");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Refreshing redeem hook on a loss exit with dust
    // ---------------------------------------------------------------------------------------------------------------

    function _positionOfAInC() internal view returns (uint256) {
        return vaultC.convertToAssets(vaultC.balanceOf(address(vaultA)));
    }

    /// @dev A holds C shares (50 USDC), then the off-grid enter and a loss of A
    function _setUpHookScenarioAtLoss() internal returns (uint256 shares) {
        _userDeposit(USERS_DEPOSIT);
        _gain(vaultA, PRE_GAIN);
        _fundC(PRINCIPAL);
        _memberDepositToC(vaultA, 50_000_000);
        _reserveEnter(vaultA, PRINCIPAL);
        shares = _cShares();
        _loss(vaultA, LOSS);
    }

    function testShouldRunRefreshingRedeemHookOnLossFullExitWithDust() public {
        // given
        uint256 shares = _setUpHookScenarioAtLoss();
        uint256 snapshot = vm.snapshotState();

        // baseline without the hook
        vm.recordLogs();
        _reserveExit(vaultA, PRINCIPAL);
        Vm.Log[] memory baselineLogs = vm.getRecordedLogs();
        uint256 usdcA = usdc.balanceOf(address(vaultA));
        uint256 usdcC = usdc.balanceOf(address(vaultC));
        uint256 supplyA = vaultA.totalSupply();
        (ExitEvent memory baselineExit, ) = _findExit(baselineLogs);
        vm.revertToState(snapshot);

        _setPreHook(vaultA, IERC4626.redeem.selector, address(new UpdateBalancesPreHook()));

        // when
        vm.recordLogs();
        _reserveExit(vaultA, PRINCIPAL);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // then: it was a loss exit with a dust redeem of 0 assets
        (ExitEvent memory exitEvent, ) = _findExit(logs);
        assertGt(exitEvent.boost, 0, "loss exit: boosted");
        assertEq(exitEvent.surplusAssets, 0, "loss exit: the surplus is 0 assets");
        assertEq(exitEvent.sharesBurned, shares, "every share burned");
        WindowCheck memory w = _windowCheck(logs);
        assertEq(w.withdraws, 2, "withdraw and dust redeem");
        assertEq(w.dustAssets, 0, "dust redeem pays 0 assets");
        assertGt(w.dustShares, 0, "dust redeem burns shares");
        assertEq(_cShares(), 0, "C holds no shares");

        // then: the hook ran inside the dust redeem, while C was between its withdraw and its own refresh
        assertGt(
            vaultA.totalAssetsInMarket(ERC4626_MARKET),
            _positionOfAInC(),
            "A caches a higher value of its C position than C reports"
        );

        // then: the outcome of the exit does not depend on the hook
        assertEq(exitEvent.boost, baselineExit.boost, "boost same as without hook");
        assertEq(exitEvent.sharesBurned, baselineExit.sharesBurned, "burned shares same as without hook");
        assertEq(usdc.balanceOf(address(vaultA)), usdcA, "A USDC same as without hook");
        assertEq(usdc.balanceOf(address(vaultC)), usdcC, "C USDC same as without hook");
        assertEq(vaultA.totalSupply(), supplyA, "A supply same as without hook");

        // then: the next refresh repairs the cache
        uint256[] memory ids = new uint256[](1);
        ids[0] = ERC4626_MARKET;
        vm.prank(ATOMIST);
        vaultA.updateMarketsBalances(ids);
        assertEq(vaultA.totalAssetsInMarket(ERC4626_MARKET), _positionOfAInC(), "refresh aligns the cache");
    }

    struct WindowCheck {
        uint256 withdraws;
        uint256 dustAssets;
        uint256 dustShares;
    }

    function _windowCheck(Vm.Log[] memory logs_) private view returns (WindowCheck memory w) {
        WithdrawEvent[] memory withdraws = _cWithdraws(logs_);
        w.withdraws = withdraws.length;
        if (withdraws.length == 2) {
            w.dustAssets = withdraws[1].assets;
            w.dustShares = withdraws[1].shares;
        }
    }
}
