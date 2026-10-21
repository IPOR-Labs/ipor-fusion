// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ExchangeRateValidatorPreHook} from "../../contracts/handlers/pre_hooks/pre_hooks/ExchangeRateValidatorPreHook.sol";
import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {
    ExchangeRateValidatorConfigLib,
    ExchangeRateValidatorConfig,
    HookType,
    ValidatorData
} from "../../contracts/handlers/pre_hooks/pre_hooks/ExchangeRateValidatorConfigLib.sol";

/// @dev Unprivileged attacker contract (port of the IL-8738 PoC). Everything runs inside ONE external call:
///      move the vault exchange rate by a step below the validator threshold (donation to idle), then make a
///      dust deposit so that the hooked `deposit` validates and, before the fix, re-anchored the stored rate.
contract ExchangeRateRatchetAttacker {
    IERC20 public immutable usdc;
    IERC4626 public immutable vault;

    constructor(IERC20 usdc_, IERC4626 vault_) {
        usdc = usdc_;
        vault = vault_;
    }

    function attack(uint256 steps_, uint256 stepBps_) external {
        usdc.approve(address(vault), type(uint256).max);
        for (uint256 i; i < steps_; ++i) {
            usdc.transfer(address(vault), (vault.totalAssets() * stepBps_) / 10_000);
            vault.deposit(1e6, address(this));
        }
    }
}

/// @title ExchangeRateValidatorRatchetTest
/// @notice IL-8832: the stored exchange rate re-anchors at most once per block.timestamp, so repeated hooked
///         deposits in one timestamp cannot walk the accepted rate past the threshold.
contract ExchangeRateValidatorRatchetTest is Test {
    address private constant PLASMA_VAULT = 0x6f66b845604dad6E80b2A1472e6cAcbbE66A8C40;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant ATOMIST = 0x8c52fE65e3AfE15392F23536aAd128edE9aE4102;
    address private constant OWNER = 0xf2C6a2225BE9829eD77263b032E3D92C52aE6694;
    address private constant USER = 0x1212121212121212121212121212121212121212;

    /// @dev 1% threshold
    uint80 private constant THRESHOLD = 1e16;

    ExchangeRateValidatorPreHook private _hook;
    PlasmaVault private _vault = PlasmaVault(PLASMA_VAULT);

    function setUp() public {
        // own fork block (not shared with ExchangeRateValidatorPreHookTest, which warps)
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 23739500);

        IporFusionAccessManager accessManager = IporFusionAccessManager(_vault.authority());
        vm.startPrank(OWNER);
        _hook = new ExchangeRateValidatorPreHook(IporFusionMarkets.EXCHANGE_RATE_VALIDATOR);
        accessManager.grantRole(Roles.PRE_HOOKS_MANAGER_ROLE, ATOMIST, 0);
        vm.stopPrank();

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = PlasmaVault.deposit.selector;
        address[] memory hooks = new address[](1);
        hooks[0] = address(_hook);
        bytes32[][] memory substrates = new bytes32[][](1);
        substrates[0] = new bytes32[](0);
        vm.prank(ATOMIST);
        PlasmaVaultGovernance(PLASMA_VAULT).setPreHookImplementations(selectors, hooks, substrates);

        deal(USDC, USER, 1_000_000e6);
        vm.prank(USER);
        IERC20(USDC).approve(PLASMA_VAULT, type(uint256).max);
    }

    // ============ helpers ============

    function _rate() private view returns (uint256) {
        return _vault.convertToAssets(10 ** _vault.decimals());
    }

    /// @dev Moves the vault exchange rate to ~target_ by changing the idle USDC balance (rate is linear in assets).
    function _moveRateTo(uint256 target_) private {
        uint256 current = _rate();
        uint256 totalAssets = _vault.totalAssets();
        uint256 idle = IERC20(USDC).balanceOf(PLASMA_VAULT);
        if (target_ >= current) {
            deal(USDC, PLASMA_VAULT, idle + (totalAssets * (target_ - current)) / current);
        } else {
            deal(USDC, PLASMA_VAULT, idle - (totalAssets * (current - target_)) / current);
        }
    }

    function _pct(uint256 base_, uint256 numerator_, uint256 denominator_) private pure returns (uint256) {
        return (base_ * numerator_) / denominator_;
    }

    function _configureRaw(bytes31 data_) private {
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(
            ExchangeRateValidatorConfig({typ: HookType.VALIDATOR, data: data_})
        );
        vm.prank(ATOMIST);
        PlasmaVaultGovernance(PLASMA_VAULT).grantMarketSubstrates(
            IporFusionMarkets.EXCHANGE_RATE_VALIDATOR,
            substrates
        );
    }

    function _configure(uint256 rate_, uint40 timestamp_) private {
        _configureRaw(
            ExchangeRateValidatorConfigLib.validatorDataToBytes31(
                ValidatorData({exchangeRate: uint128(rate_), threshold: THRESHOLD, lastUpdateTimestamp: timestamp_})
            )
        );
    }

    function _stored() private view returns (ValidatorData memory) {
        bytes32[] memory substrates = PlasmaVaultGovernance(PLASMA_VAULT).getMarketSubstrates(
            IporFusionMarkets.EXCHANGE_RATE_VALIDATOR
        );
        assertEq(substrates.length, 1, "one validator substrate expected");
        return
            ExchangeRateValidatorConfigLib.bytes31ToValidatorData(
                ExchangeRateValidatorConfigLib.bytes32ToExchangeRateValidatorConfig(substrates[0]).data
            );
    }

    function _storedRaw() private view returns (bytes32) {
        return PlasmaVaultGovernance(PLASMA_VAULT).getMarketSubstrates(IporFusionMarkets.EXCHANGE_RATE_VALIDATOR)[0];
    }

    function _deposit() private {
        vm.prank(USER);
        _vault.deposit(1e6, USER);
    }

    function _expectOutOfRange(uint256 current_, uint256 stored_) private {
        vm.expectRevert(
            abi.encodeWithSelector(
                ExchangeRateValidatorPreHook.ExchangeRateOutOfRange.selector,
                current_,
                stored_,
                uint256(THRESHOLD)
            )
        );
    }

    /// @dev Lifts the rate by 20% so that downward moves are possible by reducing the idle balance.
    function _liftRate() private returns (uint256 r0) {
        _moveRateTo(_pct(_rate(), 120, 100));
        r0 = _rate();
    }

    // ============ 1. same timestamp ============

    function testSameTimestampSecondReanchorBlocked() public {
        uint256 r0 = _rate();
        _configure(r0, 0);

        // +0.6% (> t/2): first re-anchor in this timestamp
        _moveRateTo(_pct(r0, 1006, 1000));
        uint256 r1 = _rate();
        assertGt(r1, (r0 * (1e18 + THRESHOLD / 2)) / 1e18, "precondition: outside the half band");
        _deposit();
        ValidatorData memory data = _stored();
        assertEq(uint256(data.exchangeRate), r1, "stored rate re-anchored to R1");
        assertEq(data.lastUpdateTimestamp, uint40(block.timestamp), "timestamp recorded");
        assertEq(data.threshold, THRESHOLD, "threshold unchanged");

        // +1.2% from R0 (= +0.6% from R1, again outside R1's half band): passes WITHOUT a write
        _moveRateTo(_pct(r0, 1012, 1000));
        assertGt(_rate(), (r1 * (1e18 + THRESHOLD / 2)) / 1e18, "precondition: outside R1 half band");
        bytes32 before = _storedRaw();
        _deposit();
        assertEq(_storedRaw(), before, "second re-anchor in the same timestamp must not write");

        // +1.7% from R0 (> t above R1): reverts with the stored R1
        _moveRateTo(_pct(r0, 1017, 1000));
        uint256 current = _rate();
        assertGt(current, (r1 * (1e18 + THRESHOLD)) / 1e18, "precondition: outside R1 band");
        _expectOutOfRange(current, r1);
        _deposit();
    }

    // ============ 2. next timestamp ============

    function testNextTimestampReanchorsAgain() public {
        uint256 r0 = _rate();
        _configure(r0, 0);

        _moveRateTo(_pct(r0, 1006, 1000));
        _deposit();
        uint40 firstTimestamp = _stored().lastUpdateTimestamp;

        _moveRateTo(_pct(r0, 1012, 1000));
        uint256 r2 = _rate();
        vm.warp(block.timestamp + 1);
        _deposit();

        ValidatorData memory data = _stored();
        assertEq(uint256(data.exchangeRate), r2, "re-anchored again in the next timestamp");
        assertEq(data.lastUpdateTimestamp, firstTimestamp + 1, "timestamp advanced");
        assertEq(data.threshold, THRESHOLD, "threshold unchanged");
    }

    function testNextTimestampReanchorsAgainDownward() public {
        uint256 r0 = _liftRate();
        _configure(r0, 0);

        _moveRateTo(_pct(r0, 994, 1000));
        uint256 r1 = _rate();
        _deposit();
        assertEq(uint256(_stored().exchangeRate), r1, "first downward re-anchor");

        // -1.2% from R0 in the same timestamp: no write
        _moveRateTo(_pct(r0, 988, 1000));
        bytes32 before = _storedRaw();
        _deposit();
        assertEq(_storedRaw(), before, "same timestamp: no second re-anchor");

        // -1.7% from R0 (> t below R1) in the same timestamp: reverts
        _moveRateTo(_pct(r0, 983, 1000));
        uint256 current = _rate();
        assertLt(current, (r1 * (1e18 - THRESHOLD)) / 1e18, "precondition: below R1 band");
        _expectOutOfRange(current, r1);
        _deposit();

        // back to -1.2% and next timestamp: re-anchors down again
        _moveRateTo(_pct(r0, 988, 1000));
        uint256 r2 = _rate();
        vm.warp(block.timestamp + 1);
        _deposit();
        assertEq(uint256(_stored().exchangeRate), r2, "downward re-anchor in the next timestamp");
    }

    // ============ 3. PoC port ============

    function testAttackerCannotWalkRateInOneTransaction() public {
        uint256 r0 = _rate();
        _configure(r0, 0);

        ExchangeRateRatchetAttacker attacker = new ExchangeRateRatchetAttacker(IERC20(USDC), IERC4626(PLASMA_VAULT));
        deal(USDC, address(attacker), 100_000_000e6);

        // 25 steps of 0.9% (> t/2, < t): before the fix every step re-anchored and none reverted.
        // Now step 1 re-anchors, step 2 passes without a write, step 3 is outside R1's band.
        vm.expectPartialRevert(ExchangeRateValidatorPreHook.ExchangeRateOutOfRange.selector);
        attacker.attack(25, 90);

        // Two steps are accepted; the accepted rate stays within (1 + t)^2 of the original rate.
        attacker.attack(2, 90);
        uint256 accepted = _rate();
        assertLe(accepted, (((r0 * (1e18 + THRESHOLD)) / 1e18) * (1e18 + THRESHOLD)) / 1e18, "rate <= R0 (1 + t)^2");
        assertGt(accepted, (r0 * (1e18 + THRESHOLD)) / 1e18, "second step moved the rate beyond one band");
        ValidatorData memory data = _stored();
        assertLt(uint256(data.exchangeRate), (r0 * (1e18 + THRESHOLD)) / 1e18, "anchor moved only once");
    }

    // ============ 4. legacy config ============

    function testLegacyConfigTimestampZeroAllowsOneReanchor() public {
        uint256 r0 = _rate();
        // config as written before IL-8832: threshold in the old 120-bit field, rate in bits 120-247
        uint120 legacyThreshold = THRESHOLD;
        _configureRaw(bytes31(uint248(uint256(legacyThreshold) | (uint256(r0) << 120))));
        assertEq(_stored().lastUpdateTimestamp, 0, "legacy config decodes with timestamp 0");

        _moveRateTo(_pct(r0, 1006, 1000));
        uint256 r1 = _rate();
        _deposit();
        ValidatorData memory data = _stored();
        assertEq(uint256(data.exchangeRate), r1, "legacy config re-anchors once");
        assertEq(data.threshold, THRESHOLD, "stored threshold unchanged");
        assertEq(data.lastUpdateTimestamp, uint40(block.timestamp), "timestamp added");

        _moveRateTo(_pct(r0, 1012, 1000));
        bytes32 before = _storedRaw();
        _deposit();
        assertEq(_storedRaw(), before, "no second re-anchor in the same timestamp");
    }

    // ============ 5. downward grief (documented behaviour) ============

    /// @dev Pins the NatSpec: after a re-anchor DOWN by d in (t/(1+t), t], the return to the previous level is
    ///      outside the band (d/(1-d) > t) and keeps reverting, in later timestamps too, until the ATOMIST resets
    ///      the validator config.
    function testDownwardReanchorThenReturnRevertsUntilAtomistReset() public {
        uint256 r0 = _liftRate();
        _configure(r0, 0);

        // d = 0.995% > t/(1+t) = 0.990% and <= t
        _moveRateTo(_pct(r0, 99_005, 100_000));
        uint256 r1 = _rate();
        assertGe(r1, (r0 * (1e18 - THRESHOLD)) / 1e18, "precondition: inside the band");
        _deposit();
        assertEq(uint256(_stored().exchangeRate), r1, "re-anchored down");

        // the rate returns to the previous level R0
        _moveRateTo(r0);
        uint256 back = _rate();
        assertGt(back, (r1 * (1e18 + THRESHOLD)) / 1e18, "precondition: return is outside the band");

        vm.warp(block.timestamp + 1);
        _expectOutOfRange(back, r1);
        _deposit();
        vm.warp(block.timestamp + 1 days);
        back = _rate(); // time-dependent accrual may change the rate slightly
        assertGt(back, (r1 * (1e18 + THRESHOLD)) / 1e18, "still outside the band a day later");
        _expectOutOfRange(back, r1);
        _deposit();

        // ATOMIST reset recovers
        _configure(back, 0);
        _deposit();
    }

    function testShouldRevertThresholdTooHighWhenThresholdAboveOneHundredPercent() public {
        uint80 tooHigh = uint80(1e18 + 1);
        _configureRaw(
            ExchangeRateValidatorConfigLib.validatorDataToBytes31(
                ValidatorData({exchangeRate: uint128(_rate()), threshold: tooHigh, lastUpdateTimestamp: 0})
            )
        );
        vm.expectRevert(
            abi.encodeWithSelector(ExchangeRateValidatorPreHook.ThresholdTooHigh.selector, uint256(tooHigh))
        );
        _deposit();
    }
}
