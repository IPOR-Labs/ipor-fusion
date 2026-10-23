// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HyperCoreEffectSettlementBase} from "./HyperCoreEffectSettlementBase.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {FuseAction} from "../../../contracts/interfaces/IPlasmaVault.sol";
import {FeeManager} from "../../../contracts/managers/fee/FeeManager.sol";
import {FeeAccount} from "../../../contracts/managers/fee/FeeAccount.sol";
import {RecipientFee} from "../../../contracts/managers/fee/FeeManagerFactory.sol";
import {
    HyperCoreDepositFuse,
    HyperCoreDepositFuseEnterData
} from "../../../contracts/fuses/hypercore/HyperCoreDepositFuse.sol";
import {HyperCoreLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreLib.sol";
import {CoreSimulatorLib} from "./simulation/CoreSimulatorLib.sol";

/// @title HyperCoreCapitalFlowPerformanceFeeTest (IL-8936, C-015)
/// @notice Every other HyperCore fixture runs with zero fees. This suite configures a 20% performance fee and proves
///         that a Core gain which has not been refreshed yet is crystallized by the nested
///         `updateMarketsBalances` refresh of `HyperCoreCapitalFlowPreHook`: fee shares are minted exactly once, the
///         high-water mark moves to the post-mint share price (IL-8744) and the depositor's shares are priced on the
///         supply that already contains the fee shares. The ordering of the performance fee against the management
///         fee (C-031) is by design and is not asserted here.
contract HyperCoreCapitalFlowPerformanceFeeTest is HyperCoreEffectSettlementBase {
    /// @dev 20% performance fee, `FeeManager` percentages use two decimals (10000 = 100%)
    uint256 internal constant PERFORMANCE_FEE = 2000;
    /// @dev USDC the vault bridges to Core before the gain
    uint256 internal constant CORE_DEPOSIT = 100_000e6;
    /// @dev Unrefreshed Core profit (USDC, 6 decimals)
    uint256 internal constant CORE_GAIN = 10_000e6;
    /// @dev Vault shares have 8 decimals over the 6-decimals USDC, so `10 ** 2` is the vault share scale multiplier
    uint256 internal constant ONE_SHARE = 1e8;
    uint256 internal constant SHARE_SCALE = 100;
    uint256 internal constant USER_DEPOSIT = 100_000e6;

    FeeManager internal _feeManager;
    address internal _feeAccount;

    function setUp() public override {
        super.setUp();
        _feeAccount = PlasmaVaultGovernance(address(_vault)).getPerformanceFeeData().feeAccount;
        _feeManager = FeeManager(FeeAccount(_feeAccount).FEE_MANAGER());

        RecipientFee[] memory recipientFees = new RecipientFee[](1);
        recipientFees[0] = RecipientFee({recipient: makeAddr("FEE_RECIPIENT"), feeValue: PERFORMANCE_FEE});
        vm.prank(_atomist);
        _feeManager.updatePerformanceFee(recipientFees);
    }

    function testPerformanceFeeConfigured() public view {
        assertEq(
            PlasmaVaultGovernance(address(_vault)).getPerformanceFeeData().feeInPercentage,
            PERFORMANCE_FEE,
            "vault performance fee is 20%"
        );
    }

    /// @dev The hook's nested refresh is the only crystallization point of the deposit: the user's deposit mints
    ///      fee shares once, moves the HWM to the post-mint price and is priced on the post-fee supply.
    function testDepositThroughHookCrystallizesCoreGainFeeOnce() public {
        _bridgeToCoreAndRefresh();
        _approveUserDeposit();
        uint256 hwmBefore = _hwm();
        uint256 supplyBefore = _vault.totalSupply();
        uint256 navBefore = _vault.totalAssets();
        // the first Core credit loses 1 USDC to the Core account activation fee
        assertEq(navBefore, 999_999e6, "precondition: NAV is 1,000,000 USDC minus the activation fee");
        assertEq(_vault.balanceOf(_feeAccount), 0, "precondition: no fee shares yet");
        assertEq(hwmBefore, 1e6, "precondition: HWM is the starting rate");

        // Core profit that nobody has refreshed: the vault NAV is still the cached one
        _addCoreGain(CORE_GAIN);
        assertEq(_vault.totalAssets(), navBefore, "the gain is not refreshed yet");

        // Independent expectation (FeeManager.calculateAndUpdatePerformanceFee, FeeManager.sol:604-606; ERC4626
        // convertToAssets of PlasmaVault with the vault share scale multiplier)
        uint256 navAfterRefresh = navBefore + CORE_GAIN;
        uint256 preMintRate = Math.mulDiv(ONE_SHARE, navAfterRefresh + 1, supplyBefore + SHARE_SCALE);
        uint256 harvested = Math.mulDiv(supplyBefore, preMintRate - hwmBefore, preMintRate);
        uint256 expectedFeeShares = Math.mulDiv(harvested, PERFORMANCE_FEE, 10000);
        uint256 expectedHwm = Math.mulDiv(
            ONE_SHARE,
            navAfterRefresh + 1,
            supplyBefore + expectedFeeShares + SHARE_SCALE
        );
        // Pinned literals of the same computation (S = 1e14, NAV = 1,009,999 USDC, H = 1e6)
        assertEq(preMintRate, 1_009_998, "pre-mint share price");
        assertEq(harvested, 989_902_950_302, "shares worth the gain above the HWM");
        assertEq(expectedFeeShares, 197_980_590_060, "20% of the harvested shares");
        assertEq(expectedHwm, 1_008_003, "post-mint share price");
        uint256 expectedUserShares = Math.mulDiv(
            USER_DEPOSIT,
            supplyBefore + expectedFeeShares + SHARE_SCALE,
            navAfterRefresh + 1
        );

        vm.prank(_user);
        uint256 userShares = _vault.deposit(USER_DEPOSIT, _user);

        assertEq(
            _vault.balanceOf(_feeAccount),
            expectedFeeShares,
            "fee shares minted exactly once by the hook refresh"
        );
        assertEq(_hwm(), expectedHwm, "HWM is the post-mint share price (IL-8744)");
        assertEq(userShares, 9_920_601_960_007, "pinned user shares");
        assertApproxEqRel(
            _hwm(),
            _vault.convertToAssets(ONE_SHARE),
            1e9,
            "HWM is the price of one share after the mint (the deposit is price-neutral up to dust)"
        );
        assertLt(expectedHwm, preMintRate, "the mint diluted the price");
        assertEq(userShares, expectedUserShares, "user shares are priced on the supply that includes the fee shares");
        assertEq(
            _vault.totalSupply(),
            supplyBefore + expectedFeeShares + userShares,
            "supply = old supply + fee shares + user shares"
        );
        assertEq(_vault.totalAssets(), navAfterRefresh + USER_DEPOSIT, "NAV holds the refreshed Core gain");
    }

    /// @dev A redeem in the same block as the fee-crystallizing deposit finds the HWM at the post-mint price, so the
    ///      outer `redeem` crystallization (and its hook refresh) mints no second fee.
    function testRedeemInSameBlockDoesNotMintSecondFee() public {
        _bridgeToCoreAndRefresh();
        _approveUserDeposit();
        _addCoreGain(CORE_GAIN);

        vm.prank(_user);
        uint256 userShares = _vault.deposit(USER_DEPOSIT, _user);
        uint256 feeSharesAfterDeposit = _vault.balanceOf(_feeAccount);
        uint256 hwmAfterDeposit = _hwm();
        assertGt(feeSharesAfterDeposit, 0, "precondition: the deposit minted fee shares");

        vm.prank(_user);
        _vault.redeem(userShares, _user, _user);

        assertEq(_vault.balanceOf(_feeAccount), feeSharesAfterDeposit, "no second fee in the same block");
        assertEq(_hwm(), hwmAfterDeposit, "HWM unchanged by the redeem");
    }

    function _approveUserDeposit() internal {
        _usdc.mint(_user, USER_DEPOSIT);
        vm.prank(_user);
        _usdc.approve(address(_vault), USER_DEPOSIT);
    }

    function _hwm() internal view returns (uint256) {
        return _feeManager.getPlasmaVaultHighWaterMarkPerformanceFee().highWaterMark;
    }

    /// @dev Bridges `CORE_DEPOSIT` to Core, lets the credit land and refreshes the NAV (no gain yet)
    function _bridgeToCoreAndRefresh() internal {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_depositFuse),
            abi.encodeWithSelector(
                HyperCoreDepositFuse.enter.selector,
                HyperCoreDepositFuseEnterData({tokenIndex: USDC_TOKEN, amount: CORE_DEPOSIT})
            )
        );
        _vault.execute(actions);
        _settle(2);
        _refreshAndTotalAssets();
    }

    /// @dev Raises the vault's Core spot USDC balance (8 wei decimals) by `usdc_` (6 decimals) without a refresh
    function _addCoreGain(uint256 usdc_) internal {
        uint64 current = HyperCoreLib.spotBalance(address(_vault), USDC_TOKEN).total;
        CoreSimulatorLib.forceSpotBalance(address(_vault), USDC_TOKEN, current + uint64(usdc_ * 100));
    }
}
