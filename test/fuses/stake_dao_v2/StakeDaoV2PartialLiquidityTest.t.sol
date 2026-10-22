// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {PlasmaVault, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {
    StakeDaoV2SupplyFuse,
    StakeDaoV2SupplyFuseEnterData
} from "../../../contracts/fuses/stake_dao_v2/StakeDaoV2SupplyFuse.sol";
import {StakeDaoV2BalanceFuse} from "../../../contracts/fuses/stake_dao_v2/StakeDaoV2BalanceFuse.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {InstantWithdrawalFusesParamsStruct} from "../../../contracts/libraries/PlasmaVaultLib.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {IPlasmaVaultGovernance} from "../../../contracts/interfaces/IPlasmaVaultGovernance.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";

/// @dev Minimal Curve LlamaLend controller surface used to take real liquidity out of the lending market.
interface ILlamaLendController {
    function create_loan(uint256 collateral, uint256 debt, uint256 n) external payable;
}

/// @notice IL-8790: `StakeDaoV2SupplyFuse` instant withdraw must cap the LP-vault redeem by the LP vault's
/// `maxRedeem` (read after the outer reward-vault redeem) and stake the unredeemed remainder back into the
/// reward vault, instead of "all or nothing" with the remainder left as loose LP-vault shares.
/// @dev Fork test against the live LlamaRisk crvUSD Optimizer vault. The liquidity shortage is created on the
/// real WBTC LlamaLend market by a real loan, not by a mock.
contract StakeDaoV2PartialLiquidityTest is Test {
    address public constant FUSION_PLASMA_VAULT = 0x4c4f752fa54dafB6d51B4A39018271c90bA1156F;
    address public constant FUSION_ACCESS_MANAGER = 0x497F8A5FcA953cd507A67e112B7D95bc712B23F1;
    address public constant CRV_USD = 0x498Bf2B1e120FeD3ad3D42EA2165E9b73f99C1e5;

    address public constant ATOMIST = 0x0Ed2fC947952896E6bf90001045f064Fe5dbC344;
    address public constant FUSE_MANAGER = 0x0Ed2fC947952896E6bf90001045f064Fe5dbC344;
    address public constant ALPHA = 0xd8a1087d6bbCd5533F819A4496a06AF452609b99;
    address public constant USER = address(0xBEEF8790);
    address public constant BORROWER = address(0xB0B8790);

    address public constant REWARD_VAULT_WBTC = 0x1544E663DD326a6d853a0cc4ceEf0860eb82B287;
    address public constant LP_VAULT_WBTC = 0xe07f1151887b8FDC6800f737252f6b91b46b5865;
    address public constant REWARD_VAULT_WETH = 0x2abaD3D0c104fE1C9A412431D070e73108B4eFF8;

    /// @dev LlamaLend controller of the WBTC market and its collateral token (WBTC, 8 decimals).
    address public constant WBTC_CONTROLLER = 0xb9aDddCf4e01c2f64F8F2CD9a050DC35585ea053;
    address public constant WBTC = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;

    uint256 public constant DEPOSIT_AMOUNT = 100_000e18;
    uint256 public constant WBTC_STAKE_AMOUNT = 35_000e18;
    uint256 public constant WETH_STAKE_AMOUNT = 55_000e18;
    /// @dev crvUSD liquidity left in the WBTC LlamaLend market, below the 35_000e18 position.
    uint256 public constant REMAINING_LIQUIDITY = 10_000e18;

    StakeDaoV2SupplyFuse public supplyFuse;
    StakeDaoV2BalanceFuse public balanceFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 382806620);

        vm.prank(ATOMIST);
        PlasmaVaultGovernance(FUSION_PLASMA_VAULT).convertToPublicVault();

        deal(CRV_USD, USER, DEPOSIT_AMOUNT);
        vm.startPrank(USER);
        IERC20(CRV_USD).approve(FUSION_PLASMA_VAULT, type(uint256).max);
        PlasmaVault(FUSION_PLASMA_VAULT).deposit(DEPOSIT_AMOUNT, USER);
        vm.stopPrank();

        supplyFuse = new StakeDaoV2SupplyFuse(IporFusionMarkets.STAKE_DAO_V2);
        balanceFuse = new StakeDaoV2BalanceFuse(IporFusionMarkets.STAKE_DAO_V2);

        address[] memory fuses = new address[](1);
        fuses[0] = address(supplyFuse);
        vm.startPrank(FUSE_MANAGER);
        PlasmaVaultGovernance(FUSION_PLASMA_VAULT).addFuses(fuses);
        PlasmaVaultGovernance(FUSION_PLASMA_VAULT).addBalanceFuse(IporFusionMarkets.STAKE_DAO_V2, address(balanceFuse));
        vm.stopPrank();

        _stakeIntoBothVaults();
        _configureInstantWithdrawalFuses();
    }

    // ---------------------------------------------------------------------------------------------
    // Test 0: venue precondition (real LlamaLend liquidity shortage)
    // ---------------------------------------------------------------------------------------------

    /// @notice Proves on the fork, without mocks, the BugPoCer claim: once the WBTC LlamaLend market has less
    /// liquidity than the position, `maxRedeem` is below the shares and a full `redeem` reverts.
    function test_venuePreconditionLlamaLendRedeemIsLimitedByLiquidity() public {
        uint256 positionShares = IERC20(REWARD_VAULT_WBTC).balanceOf(FUSION_PLASMA_VAULT);
        assertGt(positionShares, 0, "sanity: WBTC position is staked");

        // before the loan the full position is redeemable (liquidity 637k crvUSD >> 35k position)
        uint256 snapshot = vm.snapshotState();
        _redeemOuterAsPlasmaVault(positionShares);
        assertEq(
            IERC4626(LP_VAULT_WBTC).maxRedeem(FUSION_PLASMA_VAULT),
            positionShares,
            "before the loan maxRedeem covers the whole position"
        );
        vm.revertToState(snapshot);

        _drainWbtcMarketLiquidity();

        _redeemOuterAsPlasmaVault(positionShares);

        uint256 lpMax = IERC4626(LP_VAULT_WBTC).maxRedeem(FUSION_PLASMA_VAULT);
        assertLt(lpMax, positionShares, "maxRedeem must be below the LP shares held after the loan");
        assertGt(lpMax, 0, "some liquidity must remain");

        vm.prank(FUSION_PLASMA_VAULT);
        (bool ok, ) = LP_VAULT_WBTC.call(
            abi.encodeCall(IERC4626.redeem, (positionShares, FUSION_PLASMA_VAULT, FUSION_PLASMA_VAULT))
        );
        assertFalse(ok, "a full redeem of the LP shares must revert for lack of liquidity");
    }

    // ---------------------------------------------------------------------------------------------
    // Test 1: partial liquidity is used, nothing is left loose
    // ---------------------------------------------------------------------------------------------

    function test_instantWithdrawUsesPartialLlamaLendLiquidity() public {
        _drainWbtcMarketLiquidity();

        uint256 withdrawAmount = 45_000e18; // idle 10_000e18 + shortfall 35_000e18 > WBTC market liquidity

        uint256 liquidityBefore = IERC20(CRV_USD).balanceOf(WBTC_CONTROLLER);
        uint256 wbtcRewardSharesBefore = IERC20(REWARD_VAULT_WBTC).balanceOf(FUSION_PLASMA_VAULT);
        uint256 totalAssetsBefore = PlasmaVault(FUSION_PLASMA_VAULT).totalAssets();
        uint256 userBefore = IERC20(CRV_USD).balanceOf(USER);
        assertApproxEqAbs(liquidityBefore, REMAINING_LIQUIDITY, 1e18, "sanity: liquidity left in the market");

        vm.warp(block.timestamp + 2);

        vm.recordLogs();
        uint256 gasBefore = gasleft();
        vm.prank(USER);
        PlasmaVault(FUSION_PLASMA_VAULT).withdraw(withdrawAmount, USER, USER);
        uint256 gasUsed = gasBefore - gasleft();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // the WBTC leg pays out the available liquidity (today: 0)
        uint256 liquidityAfter = IERC20(CRV_USD).balanceOf(WBTC_CONTROLLER);
        assertApproxEqAbs(
            liquidityBefore - liquidityAfter,
            REMAINING_LIQUIDITY,
            1e15,
            "WBTC leg must pay out the whole remaining LlamaLend liquidity"
        );

        // nothing left loose
        assertEq(IERC20(LP_VAULT_WBTC).balanceOf(FUSION_PLASMA_VAULT), 0, "no loose WBTC LP-vault shares");
        assertEq(
            IERC20(0xd3cA9BEc3e681b0f578FD87f20eBCf2B7e0bb739).balanceOf(FUSION_PLASMA_VAULT),
            0,
            "no loose WETH LP-vault shares"
        );

        // reward-vault shares dropped only by the redeemed part (shares worth the remaining liquidity)
        uint256 redeemedShares = IERC4626(LP_VAULT_WBTC).convertToShares(REMAINING_LIQUIDITY);
        uint256 wbtcRewardSharesAfter = IERC20(REWARD_VAULT_WBTC).balanceOf(FUSION_PLASMA_VAULT);
        assertGt(wbtcRewardSharesAfter, 0, "most of the WBTC position stays staked");
        assertApproxEqRel(
            wbtcRewardSharesBefore - wbtcRewardSharesAfter,
            redeemedShares,
            1e15,
            "reward-vault shares drop only by the redeemed part"
        );

        // the user got the requested amount and totalAssets dropped by about the payout
        uint256 paidOut = IERC20(CRV_USD).balanceOf(USER) - userBefore;
        assertEq(paidOut, withdrawAmount, "user receives the requested amount");
        assertApproxEqAbs(
            totalAssetsBefore - PlasmaVault(FUSION_PLASMA_VAULT).totalAssets(),
            paidOut,
            withdrawAmount / 10_000,
            "totalAssets drops by about the payout"
        );

        assertEq(_countRestakedEvents(logs), 1, "the unredeemed remainder is restaked once");

        // README "Reading the events": net reward-vault shares unstaked = Exit.finalRewardVaultShares - Restaked.rewardVaultShares
        (, , uint256 exitRewardVaultShares, , ) = abi.decode(
            _singleEventData(
                logs,
                keccak256("StakeDaoV2SupplyFuseExit(address,address,uint256,uint256,uint256)"),
                REWARD_VAULT_WBTC
            ),
            (address, address, uint256, uint256, uint256)
        );
        (, , , uint256 restakedRewardVaultShares) = abi.decode(
            _singleEventData(
                logs,
                keccak256("StakeDaoV2SupplyFuseRestaked(address,address,uint256,uint256)"),
                REWARD_VAULT_WBTC
            ),
            (address, address, uint256, uint256)
        );
        assertEq(
            exitRewardVaultShares - restakedRewardVaultShares,
            wbtcRewardSharesBefore - wbtcRewardSharesAfter,
            "Exit minus Restaked equals the net reward-vault shares unstaked"
        );
        assertEq(
            IERC20(LP_VAULT_WBTC).allowance(FUSION_PLASMA_VAULT, REWARD_VAULT_WBTC),
            0,
            "LP-token approval to the reward vault is reset after the restake"
        );

        // the instant-withdraw path including the restake (deposit into Stake DAO) fits a sane gas budget
        assertLt(gasUsed, 2_500_000, "instant withdraw with partial liquidity and restake stays within 2.5M gas");
    }

    // ---------------------------------------------------------------------------------------------
    // Test 2: inner redeem fails entirely -> everything is restaked
    // ---------------------------------------------------------------------------------------------

    function test_instantWithdrawRestakesWhenInnerRedeemFails() public {
        vm.mockCallRevert(LP_VAULT_WBTC, abi.encodeWithSelector(IERC4626.redeem.selector), "MOCK_INNER_REDEEM_REVERT");

        uint256 wbtcRewardSharesBefore = IERC20(REWARD_VAULT_WBTC).balanceOf(FUSION_PLASMA_VAULT);
        uint256 withdrawAmount = 55_000e18; // WBTC position fully requested, WETH leg covers the rest

        vm.warp(block.timestamp + 2);

        vm.recordLogs();
        vm.prank(USER);
        PlasmaVault(FUSION_PLASMA_VAULT).withdraw(withdrawAmount, USER, USER);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertApproxEqAbs(
            IERC20(REWARD_VAULT_WBTC).balanceOf(FUSION_PLASMA_VAULT),
            wbtcRewardSharesBefore,
            1e9,
            "reward-vault shares are unchanged after the restake"
        );
        assertEq(IERC20(LP_VAULT_WBTC).balanceOf(FUSION_PLASMA_VAULT), 0, "no loose LP-vault shares");
        assertEq(_countRestakedEvents(logs), 1, "Restaked event emitted once (WBTC leg)");
        assertEq(
            IERC20(LP_VAULT_WBTC).allowance(FUSION_PLASMA_VAULT, REWARD_VAULT_WBTC),
            0,
            "LP-token approval to the reward vault is reset after the restake"
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Test 3: restake fails (e.g. gauge shutdown / deposits paused) -> withdrawal still succeeds
    // ---------------------------------------------------------------------------------------------

    function test_instantWithdrawSucceedsWhenRestakeFailsAndLooseSharesStayValued() public {
        _drainWbtcMarketLiquidity();
        vm.mockCallRevert(REWARD_VAULT_WBTC, abi.encodeWithSelector(IERC4626.deposit.selector), "MOCK_DEPOSITS_PAUSED");

        uint256 withdrawAmount = 45_000e18;
        uint256 totalAssetsBefore = PlasmaVault(FUSION_PLASMA_VAULT).totalAssets();
        uint256 userBefore = IERC20(CRV_USD).balanceOf(USER);
        uint256 wbtcRewardSharesBefore = IERC20(REWARD_VAULT_WBTC).balanceOf(FUSION_PLASMA_VAULT);

        vm.warp(block.timestamp + 2);

        vm.recordLogs();
        vm.prank(USER);
        PlasmaVault(FUSION_PLASMA_VAULT).withdraw(withdrawAmount, USER, USER);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(IERC20(CRV_USD).balanceOf(USER) - userBefore, withdrawAmount, "user withdrawal still succeeds");

        // the unredeemed part stays as loose LP-vault shares (nothing was restaked)
        uint256 looseShares = IERC20(LP_VAULT_WBTC).balanceOf(FUSION_PLASMA_VAULT);
        uint256 redeemedShares = IERC4626(LP_VAULT_WBTC).convertToShares(REMAINING_LIQUIDITY);
        assertApproxEqRel(looseShares, wbtcRewardSharesBefore - redeemedShares, 1e15, "unredeemed part stays loose");
        assertLt(
            IERC20(REWARD_VAULT_WBTC).balanceOf(FUSION_PLASMA_VAULT),
            wbtcRewardSharesBefore,
            "the requested shares left the reward vault and were not restaked"
        );
        assertEq(_countRestakedEvents(logs), 0, "no Restaked event");
        assertEq(_countEvents(logs, keccak256("StakeDaoV2SupplyFuseRestakeFailed(address,address,uint256)")), 1);

        // loose shares stay valued: totalAssets drops only by about the payout
        assertApproxEqAbs(
            totalAssetsBefore - PlasmaVault(FUSION_PLASMA_VAULT).totalAssets(),
            withdrawAmount,
            withdrawAmount / 10_000,
            "loose LP-vault shares stay valued in totalAssets"
        );
        assertEq(
            IERC20(LP_VAULT_WBTC).allowance(FUSION_PLASMA_VAULT, REWARD_VAULT_WBTC),
            0,
            "LP-token approval to the reward vault is reset after a failed restake"
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Test 4/5: maxRedeem fallback (0 or revert) -> full amount is attempted, nothing is restaked
    // ---------------------------------------------------------------------------------------------

    function test_instantWithdrawFallsBackToFullRedeemWhenMaxRedeemIsZero() public {
        vm.mockCall(LP_VAULT_WBTC, abi.encodeWithSelector(IERC4626.maxRedeem.selector), abi.encode(uint256(0)));
        _assertFullRedeemFallback();
    }

    function test_instantWithdrawFallsBackToFullRedeemWhenMaxRedeemReverts() public {
        vm.mockCallRevert(LP_VAULT_WBTC, abi.encodeWithSelector(IERC4626.maxRedeem.selector), "");
        _assertFullRedeemFallback();
    }

    /// @dev No liquidity drain: LlamaLend can pay the whole WBTC leg, so the fallback (full `lpTokenAmount`) succeeds.
    function _assertFullRedeemFallback() private {
        uint256 withdrawAmount = 45_000e18; // 10_000e18 idle + the whole 35_000e18 WBTC leg
        uint256 userBefore = IERC20(CRV_USD).balanceOf(USER);
        uint256 wbtcRewardSharesBefore = IERC20(REWARD_VAULT_WBTC).balanceOf(FUSION_PLASMA_VAULT);
        assertGt(wbtcRewardSharesBefore, 0, "sanity: WBTC position is staked");

        vm.warp(block.timestamp + 2);

        vm.recordLogs();
        vm.prank(USER);
        PlasmaVault(FUSION_PLASMA_VAULT).withdraw(withdrawAmount, USER, USER);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(IERC20(CRV_USD).balanceOf(USER) - userBefore, withdrawAmount, "user receives the requested amount");
        assertEq(_countRestakedEvents(logs), 0, "nothing is restaked: the full LP amount was redeemed");
        assertEq(IERC20(LP_VAULT_WBTC).balanceOf(FUSION_PLASMA_VAULT), 0, "no loose WBTC LP-vault shares");

        // Exit reports the full amount redeemed from the LP vault: every LP-vault share received was redeemed
        (, , uint256 exitRewardVaultShares, uint256 exitLpTokenAmount, uint256 exitUnderlying) = abi.decode(
            _singleEventData(
                logs,
                keccak256("StakeDaoV2SupplyFuseExit(address,address,uint256,uint256,uint256)"),
                REWARD_VAULT_WBTC
            ),
            (address, address, uint256, uint256, uint256)
        );
        assertGt(exitUnderlying, 0, "the WBTC leg paid out underlying");
        assertEq(exitLpTokenAmount, exitRewardVaultShares, "Stake DAO is 1:1: LP-vault shares == reward-vault shares");
        assertEq(
            wbtcRewardSharesBefore - IERC20(REWARD_VAULT_WBTC).balanceOf(FUSION_PLASMA_VAULT),
            exitRewardVaultShares,
            "the reward-vault shares dropped by the full redeemed amount, none restaked"
        );
    }

    // ---------------------------------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------------------------------

    /// @dev Takes real liquidity out of the WBTC LlamaLend market with a real loan on its controller.
    function _drainWbtcMarketLiquidity() private {
        uint256 liquidity = IERC20(CRV_USD).balanceOf(WBTC_CONTROLLER);
        uint256 debt = liquidity - REMAINING_LIQUIDITY;

        deal(WBTC, BORROWER, 1_000e8);
        vm.startPrank(BORROWER);
        IERC20(WBTC).approve(WBTC_CONTROLLER, type(uint256).max);
        ILlamaLendController(WBTC_CONTROLLER).create_loan(1_000e8, debt, 10);
        vm.stopPrank();
    }

    function _redeemOuterAsPlasmaVault(uint256 shares_) private {
        vm.prank(FUSION_PLASMA_VAULT);
        IERC4626(REWARD_VAULT_WBTC).redeem(shares_, FUSION_PLASMA_VAULT, FUSION_PLASMA_VAULT);
    }

    function _countRestakedEvents(Vm.Log[] memory logs_) private view returns (uint256) {
        return _countEvents(logs_, keccak256("StakeDaoV2SupplyFuseRestaked(address,address,uint256,uint256)"));
    }

    /// @dev Data of the only `topic` event of the PlasmaVault emitted for `rewardVault_` (second ABI word).
    function _singleEventData(
        Vm.Log[] memory logs_,
        bytes32 topic,
        address rewardVault_
    ) private view returns (bytes memory data) {
        uint256 count;
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == FUSION_PLASMA_VAULT && logs_[i].topics.length == 1 && logs_[i].topics[0] == topic) {
                (, address eventRewardVault) = abi.decode(logs_[i].data, (address, address));
                if (eventRewardVault == rewardVault_) {
                    data = logs_[i].data;
                    ++count;
                }
            }
        }
        assertEq(count, 1, "exactly one matching event for the reward vault");
    }

    function _countEvents(Vm.Log[] memory logs_, bytes32 topic) private view returns (uint256 count) {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == FUSION_PLASMA_VAULT && logs_[i].topics.length == 1 && logs_[i].topics[0] == topic) {
                ++count;
            }
        }
    }

    function _stakeIntoBothVaults() private {
        FuseAction[] memory actions = new FuseAction[](2);
        actions[0] = FuseAction(
            address(supplyFuse),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                StakeDaoV2SupplyFuseEnterData({
                    rewardVault: REWARD_VAULT_WBTC,
                    lpTokenUnderlyingAmount: WBTC_STAKE_AMOUNT,
                    minLpTokenUnderlyingAmount: (WBTC_STAKE_AMOUNT * 99) / 100
                })
            )
        );
        actions[1] = FuseAction(
            address(supplyFuse),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                StakeDaoV2SupplyFuseEnterData({
                    rewardVault: REWARD_VAULT_WETH,
                    lpTokenUnderlyingAmount: WETH_STAKE_AMOUNT,
                    minLpTokenUnderlyingAmount: (WETH_STAKE_AMOUNT * 99) / 100
                })
            )
        );
        vm.prank(ALPHA);
        PlasmaVault(FUSION_PLASMA_VAULT).execute(actions);
    }

    /// @dev WBTC first (the market with the liquidity shortage), then WETH (healthy).
    function _configureInstantWithdrawalFuses() private {
        vm.prank(ATOMIST);
        IporFusionAccessManager(FUSION_ACCESS_MANAGER).grantRole(
            Roles.CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE,
            ATOMIST,
            0
        );

        InstantWithdrawalFusesParamsStruct[] memory instantWithdrawFuses = new InstantWithdrawalFusesParamsStruct[](2);

        bytes32[] memory wbtcParams = new bytes32[](2);
        wbtcParams[1] = PlasmaVaultConfigLib.addressToBytes32(REWARD_VAULT_WBTC);
        instantWithdrawFuses[0] = InstantWithdrawalFusesParamsStruct({fuse: address(supplyFuse), params: wbtcParams});

        bytes32[] memory wethParams = new bytes32[](2);
        wethParams[1] = PlasmaVaultConfigLib.addressToBytes32(REWARD_VAULT_WETH);
        instantWithdrawFuses[1] = InstantWithdrawalFusesParamsStruct({fuse: address(supplyFuse), params: wethParams});

        vm.prank(ATOMIST);
        IPlasmaVaultGovernance(FUSION_PLASMA_VAULT).configureInstantWithdrawalFuses(instantWithdrawFuses);
    }
}
