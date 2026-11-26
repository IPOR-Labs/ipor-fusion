// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";

import {PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {RedemptionDelayLib} from "../../../contracts/managers/access/RedemptionDelayLib.sol";
import {UpdateBalancesPreHook} from "../../../contracts/handlers/pre_hooks/pre_hooks/UpdateBalancesPreHook.sol";
import {FeeManager} from "../../../contracts/managers/fee/FeeManager.sol";
import {FeeAccount} from "../../../contracts/managers/fee/FeeAccount.sol";
import {RecipientFee} from "../../../contracts/managers/fee/FeeManagerFactory.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";

import {ReserveVaultTestBase} from "./ReserveVaultTestBase.sol";
import {WindowRecorder, WindowProbeHook} from "./ReserveVaultLossFullExitTest.t.sol";

/// @dev Boost window, update role and the characterisation of the member vault's refreshing redeem hook.
///      Real clones, zero fees, C exempt from the redemption delay of A and B (the base defaults).
contract ReserveVaultBoostWindowTest is ReserveVaultTestBase {
    uint256 internal constant BOOST = 111_111_111;

    function _updateMarkets(PlasmaVault vault_, uint256 marketId_) internal {
        uint256[] memory ids = new uint256[](1);
        ids[0] = marketId_;
        vm.prank(ATOMIST);
        vault_.updateMarketsBalances(ids);
    }

    function _positionOfAInC() internal view returns (uint256) {
        return vaultC.convertToAssets(vaultC.balanceOf(address(vaultA)));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Probe inside the window
    // ---------------------------------------------------------------------------------------------------------------

    function testShouldShowPrincipalAndBoostInsideWithdrawAndNothingAfter() public {
        // given
        _setUpPrincipalInA();
        _loss(vaultA, LOSS);
        WindowRecorder recorder = new WindowRecorder(vaultA, vaultC, address(boostFuse), BOOST_MARKET);
        _setPreHook(vaultA, IERC4626.withdraw.selector, address(new WindowProbeHook(recorder)));

        // when
        _reserveExit(vaultA, PRINCIPAL);

        // then: inside A.withdraw
        assertEq(recorder.calls(), 1, "probe ran once");
        assertEq(recorder.reservePosition(), PRINCIPAL, "window: convertToAssets(C shares) is the principal");
        assertEq(recorder.boostMarketAssets(), BOOST, "window: market 62 is X");
        assertEq(recorder.boostRead(), BOOST, "window: boost read through C is X");

        // then: after execute
        assertEq(vaultA.totalAssetsInMarket(BOOST_MARKET), 0, "market 62 cleared");
        assertEq(_boost(vaultA), 0, "boost cleared");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Update role
    // ---------------------------------------------------------------------------------------------------------------

    function testShouldRevertUpdateMarketsBalancesWhenCallerHasNoRole() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = BOOST_MARKET;

        vm.expectRevert(abi.encodeWithSelector(IporFusionAccessManager.AccessManagedUnauthorized.selector, OUTSIDER));
        vm.prank(OUTSIDER);
        vaultA.updateMarketsBalances(ids);
    }

    function testShouldRevertLossExitWhenReserveVaultLostUpdateRole() public {
        // given
        _setUpPrincipalInA();
        _loss(vaultA, LOSS);
        vm.prank(ATOMIST);
        accessManagerA.revokeRole(Roles.UPDATE_MARKETS_BALANCES_ROLE, address(vaultC));

        // when / then: the boost cannot be booked
        vm.expectRevert(
            abi.encodeWithSelector(IporFusionAccessManager.AccessManagedUnauthorized.selector, address(vaultC))
        );
        _reserveExit(vaultA, PRINCIPAL);

        assertEq(_principal(vaultA), PRINCIPAL, "principal unchanged");
        assertEq(vaultA.balanceOf(address(vaultC)), 10_000_000_000, "shares unchanged");
    }

    function testShouldExitInProfitWhenReserveVaultLostUpdateRole() public {
        // given: with a real gain that covers the deposit rounding no boost is needed, so the role is not used
        _setUpPrincipalInA();
        _gain(vaultA, GAIN);
        vm.prank(ATOMIST);
        accessManagerA.revokeRole(Roles.UPDATE_MARKETS_BALANCES_ROLE, address(vaultC));
        uint256 usdcBeforeC = usdc.balanceOf(address(vaultC));

        // when
        _reserveExit(vaultA, PRINCIPAL);

        // then
        assertEq(usdc.balanceOf(address(vaultC)) - usdcBeforeC, PRINCIPAL, "C received the principal");
        assertEq(_principal(vaultA), 0, "principal zero");
        assertEq(vaultA.balanceOf(address(vaultC)), 0, "all C shares burned");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Substrate
    // ---------------------------------------------------------------------------------------------------------------

    function testShouldRevertFullExitInLossWhenBoostMarketHasNoSubstrateC() public {
        // given: market 62 of A grants only B
        _setUpPrincipalInA();
        _loss(vaultA, LOSS);
        address[] memory onlyB = new address[](1);
        onlyB[0] = address(vaultB);
        vm.prank(FUSE_MANAGER);
        PlasmaVaultGovernance(address(vaultA)).grantMarketSubstrates(BOOST_MARKET, _toSubstrates(onlyB));

        // when / then: the boost is not booked, so the withdrawal exceeds the max
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626Upgradeable.ERC4626ExceededMaxWithdraw.selector,
                address(vaultC),
                PRINCIPAL,
                90_000_000
            )
        );
        _reserveExit(vaultA, PRINCIPAL);

        assertEq(_principal(vaultA), PRINCIPAL, "principal unchanged");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Refreshing redeem hook (known limitation)
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev A holds C shares (50 USDC), C holds 100 USDC of principal in A, A gains, C exits in full
    function _setUpHookScenario() internal {
        _userDeposit(USERS_DEPOSIT);
        _fundC(PRINCIPAL);
        _memberDepositToC(vaultA, 50_000_000);
        _reserveEnter(vaultA, PRINCIPAL);
        _gain(vaultA, GAIN);
    }

    function testShouldLeaveAStaleCPositionAfterFullExitWithRefreshingRedeemHook() public {
        // given
        _setUpHookScenario();
        uint256 snapshot = vm.snapshotState();

        // baseline without the hook
        _reserveExit(vaultA, PRINCIPAL);
        uint256 usdcA = usdc.balanceOf(address(vaultA));
        uint256 usdcC = usdc.balanceOf(address(vaultC));
        uint256 supplyA = vaultA.totalSupply();
        vm.revertToState(snapshot);

        _setPreHook(vaultA, IERC4626.redeem.selector, address(new UpdateBalancesPreHook()));

        // when
        _reserveExit(vaultA, PRINCIPAL);

        // then: the hook ran inside the surplus redeem while C was between its withdraw and its own refresh
        assertEq(vaultA.balanceOf(address(vaultC)), 0, "surplus redeemed");
        assertGt(
            vaultA.totalAssetsInMarket(ERC4626_MARKET),
            _positionOfAInC(),
            "A caches a higher value of its C position than C reports"
        );

        // then: the outcome of the exit does not depend on the hook
        assertEq(usdc.balanceOf(address(vaultA)), usdcA, "A USDC same as without hook");
        assertEq(usdc.balanceOf(address(vaultC)), usdcC, "C USDC same as without hook");
        assertEq(vaultA.totalSupply(), supplyA, "A supply same as without hook");

        // then: the next refresh repairs the cache
        _updateMarkets(vaultA, ERC4626_MARKET);
        assertEq(vaultA.totalAssetsInMarket(ERC4626_MARKET), _positionOfAInC(), "refresh aligns the cache");
    }
}

/// @dev C is not exempt from the redemption delay of A and B
contract ReserveVaultRedemptionLockTest is ReserveVaultTestBase {
    function _cExemptFromRedemptionDelay() internal pure override returns (bool) {
        return false;
    }

    function testShouldRevertExitInTheBlockOfTheEnterWhenReserveVaultIsNotExempt() public {
        // given
        _setUpPrincipalInA();

        // when / then
        vm.expectRevert(abi.encodeWithSelector(RedemptionDelayLib.AccountIsLocked.selector, block.timestamp + DELAY));
        _reserveExit(vaultA, PRINCIPAL);

        // and: after the delay the exit passes
        vm.warp(block.timestamp + DELAY);
        _reserveExit(vaultA, PRINCIPAL);
        assertEq(_principal(vaultA), 0, "principal zero after the delay");
    }
}

/// @dev A charges a performance fee: the zero-fee precondition of the boost is not vacuous
contract ReserveVaultBoostFeeNegativeControlTest is ReserveVaultTestBase {
    function _configureFeesA() internal override {
        // the base helper's prank is consumed by the nested FEE_MANAGER() read, so the call is made here
        address feeAccount = PlasmaVaultGovernance(address(vaultA)).getPerformanceFeeData().feeAccount;
        FeeManager feeManager = FeeManager(FeeAccount(feeAccount).FEE_MANAGER());
        RecipientFee[] memory recipients = new RecipientFee[](1);
        recipients[0] = RecipientFee(FEE_RECIPIENT, 1000);
        vm.prank(ATOMIST);
        feeManager.updatePerformanceFee(recipients);
    }

    /// @dev The performance fee shares are minted to the fee account until they are harvested to the recipients
    function _feeAccountA() internal view returns (address) {
        return PlasmaVaultGovernance(address(vaultA)).getPerformanceFeeData().feeAccount;
    }

    /// @dev HWM 1.0, gain to 1.2 with no fee realised, C enters at 1.2, loss to 0.9
    function _setUpFeeScenario() internal {
        _userDeposit(USERS_DEPOSIT);
        uint256[] memory ids = new uint256[](1);
        ids[0] = ERC4626_MARKET;
        vm.prank(ATOMIST);
        vaultA.updateMarketsBalances(ids);

        _gain(vaultA, (USERS_DEPOSIT * 2) / 10);
        _fundC(PRINCIPAL);
        _reserveEnter(vaultA, PRINCIPAL);

        uint256 assets = vaultA.totalAssets();
        _loss(vaultA, assets / 4);
    }

    function testShouldMintFeeSharesOnBoostedRateAndKeepThemAfterPartialExit() public {
        // given
        _setUpFeeScenario();
        assertEq(_sharePrice(vaultA), 900_000, "A price is 0.9");
        uint256 feeSharesBefore = vaultA.balanceOf(_feeAccountA());

        // when
        _reserveExit(vaultA, 40_000_000);

        // then
        uint256 feeSharesAfter = vaultA.balanceOf(_feeAccountA());
        assertGt(feeSharesAfter, feeSharesBefore, "performance fee account got shares from the boosted rate");
        assertEq(_boost(vaultA), 0, "boost cleared");
        assertEq(_principal(vaultA), 60_000_000, "principal left");
    }

    function testShouldRevertFullExitWhenBoostedRateRealisesPerformanceFee() public {
        // given
        _setUpFeeScenario();
        uint256 maxWithdrawFull = vaultA.maxWithdraw(address(vaultC));
        assertLt(maxWithdrawFull, PRINCIPAL, "C position is below the principal");

        // when / then: the fee shares minted in the window dilute the boosted rate
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626Upgradeable.ERC4626ExceededMaxWithdraw.selector,
                address(vaultC),
                PRINCIPAL,
                FULL_EXIT_MAX_WITHDRAW
            )
        );
        _reserveExit(vaultA, PRINCIPAL);
    }

    uint256 internal constant FULL_EXIT_MAX_WITHDRAW = 98_333_333;
}
