// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {InstantWithdrawalFusesParamsStruct} from "../../../contracts/libraries/PlasmaVaultLib.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {IPreHook} from "../../../contracts/handlers/pre_hooks/IPreHook.sol";
import {UpdateBalancesPreHook} from "../../../contracts/handlers/pre_hooks/pre_hooks/UpdateBalancesPreHook.sol";
import {
    Erc4626SupplyFuse,
    Erc4626SupplyFuseEnterData,
    Erc4626SupplyFuseExitData
} from "../../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {Erc4626BalanceFuse} from "../../../contracts/fuses/erc4626/Erc4626BalanceFuse.sol";
import {ReserveVaultSupplyFuse} from "../../../contracts/fuses/reserve_vault/ReserveVaultSupplyFuse.sol";

import {MockERC20} from "../../test_helpers/MockERC20.sol";
import {MockERC4626} from "../../test_helpers/MockErc4626.sol";
import {TestAddresses} from "../../test_helpers/TestAddresses.sol";

import {ReserveVaultTestBase} from "./ReserveVaultTestBase.sol";

/// @dev Pre-hook that runs by delegatecall in the member vault and changes the vault's USDC balance by a fixed amount
contract IdleMoverHook is IPreHook {
    address internal immutable TOKEN;
    address internal immutable SINK_ADDRESS;
    uint256 internal immutable AMOUNT;
    bool internal immutable MOVE_IN;

    constructor(address token_, address sink_, uint256 amount_, bool moveIn_) {
        TOKEN = token_;
        SINK_ADDRESS = sink_;
        AMOUNT = amount_;
        MOVE_IN = moveIn_;
    }

    function run(bytes4) external override {
        if (MOVE_IN) {
            MockERC20(TOKEN).mint(address(this), AMOUNT);
        } else {
            IERC20(TOKEN).transfer(SINK_ADDRESS, AMOUNT);
        }
    }
}

/// @dev The liquidity rule of the reserve vault exit: the member vault A must not pull liquidity from its markets while
///      the reserve vault C exits. Real clones, `C.execute`, real pre-hooks, real instant-withdraw pulls.
contract ReserveVaultLiquidityGuardTest is ReserveVaultTestBase {
    error ReserveVaultSupplyFuseInsufficientIdleLiquidity(address vault, uint256 idle, uint256 required);
    error ReserveVaultSupplyFuseIdleBalanceMismatch(address vault, uint256 expected, uint256 actual);

    bytes32 internal constant EXIT_EVENT =
        keccak256("ReserveVaultSupplyFuseExit(address,address,address,uint256,uint256,uint256,uint256,uint256)");
    bytes32 internal constant ERC4626_EXIT_FAILED =
        keccak256("Erc4626SupplyFuseExitFailed(address,address,address,uint256)");

    uint256 internal constant C_SHARES = 10_000_000_000;
    uint256 internal constant WITHDRAW_OFFSET = 10;

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Loss case: users deposit, C enters `PRINCIPAL` into A, A loses so that its idle balance is `idle_`; A has no
    ///      other market position, so C's position is worth far less than the principal and the exit needs a boost
    function _setUpLossWithIdle(uint256 idle_) internal {
        _setUpPrincipalInA();
        _loss(vaultA, usdc.balanceOf(address(vaultA)) - idle_);
        assertEq(usdc.balanceOf(address(vaultA)), idle_, "idle of A (loss)");
        assertEq(vaultA.totalAssets(), idle_, "A total assets (loss)");
    }

    /// @dev No-boost case: A parks its surplus USDC in C (standard ERC4626 market), so that its idle balance is `idle_`
    ///      while its total assets are unchanged
    function _moveIdleOutOfA(uint256 idle_) internal {
        _memberDepositToC(vaultA, usdc.balanceOf(address(vaultA)) - idle_);
        assertEq(usdc.balanceOf(address(vaultA)), idle_, "idle of A (parked)");
    }

    /// @dev Profit case: C entered `PRINCIPAL` into A and A gained, the position is worth more than the principal
    function _setUpProfit() internal {
        _setUpPrincipalInA();
        _gain(vaultA, GAIN);
    }

    /// @dev Value of the surplus shares that remain after C's exit of `amount_`, as `ReserveVaultSupplyFuse` reads it
    ///      right before the surplus `redeem` (vault formula: supply + 100, assets + 1, floor)
    function _surplusValue(uint256 amount_) internal view returns (uint256) {
        uint256 burned = vaultA.previewWithdraw(amount_);
        uint256 rest = vaultA.balanceOf(address(vaultC)) - burned;
        return Math.mulDiv(rest, vaultA.totalAssets() - amount_ + 1, vaultA.totalSupply() - burned + 100);
    }

    function _surplusRequired(uint256 amount_) internal view returns (uint256 value, uint256 required) {
        value = _surplusValue(amount_);
        required = value + (value * 2) / 100;
    }

    struct State {
        uint256 principal;
        uint256 boost;
        uint256 idleA;
        uint256 sharesOfCInA;
        uint256 usdcC;
        uint256 supplyA;
        uint256 supplyC;
    }

    function _state() internal view returns (State memory s) {
        s.principal = _principal(vaultA);
        s.boost = _boost(vaultA);
        s.idleA = usdc.balanceOf(address(vaultA));
        s.sharesOfCInA = vaultA.balanceOf(address(vaultC));
        s.usdcC = usdc.balanceOf(address(vaultC));
        s.supplyA = vaultA.totalSupply();
        s.supplyC = vaultC.totalSupply();
    }

    function _assertSameState(State memory before_, string memory what_) internal view {
        State memory after_ = _state();
        assertEq(after_.principal, before_.principal, string.concat(what_, ": principal"));
        assertEq(after_.boost, before_.boost, string.concat(what_, ": boost"));
        assertEq(after_.idleA, before_.idleA, string.concat(what_, ": idle of A"));
        assertEq(after_.sharesOfCInA, before_.sharesOfCInA, string.concat(what_, ": C shares in A"));
        assertEq(after_.usdcC, before_.usdcC, string.concat(what_, ": USDC of C"));
        assertEq(after_.supplyA, before_.supplyA, string.concat(what_, ": supply of A"));
        assertEq(after_.supplyC, before_.supplyC, string.concat(what_, ": supply of C"));
    }

    function _expectInsufficient(uint256 idle_, uint256 required_) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                ReserveVaultSupplyFuseInsufficientIdleLiquidity.selector,
                address(vaultA),
                idle_,
                required_
            )
        );
    }

    function _countFailed(Vm.Log[] memory logs_) internal view returns (uint256 count) {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == address(vaultA) && logs_[i].topics[0] == ERC4626_EXIT_FAILED) {
                ++count;
            }
        }
    }

    function _exitEventAssets(Vm.Log[] memory logs_) internal view returns (uint256 surplusAssets, uint256 count) {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == address(vaultC) && logs_[i].topics[0] == EXIT_EVENT) {
                ++count;
                (, , , , , , surplusAssets, ) = abi.decode(
                    logs_[i].data,
                    (address, address, address, uint256, uint256, uint256, uint256, uint256)
                );
            }
        }
    }

    /// @dev A's instant-withdraw list: the standard ERC4626 fuse on the market whose substrate is C. A is also exempted
    ///      from C's redemption delay (the member vaults of a reserve vault are exempt), so the only thing that can stop
    ///      A's pull from C is C's own reentrancy lock
    function _configureInstantWithdrawOfAOnC() internal {
        address[] memory exempt = new address[](1);
        exempt[0] = address(vaultA);
        vm.prank(OWNER);
        PlasmaVaultGovernance(address(vaultC)).setRedemptionDelayExemption(exempt, true);

        bytes32[] memory params = new bytes32[](2);
        params[0] = bytes32(0);
        params[1] = PlasmaVaultConfigLib.addressToBytes32(address(vaultC));
        InstantWithdrawalFusesParamsStruct[] memory list = new InstantWithdrawalFusesParamsStruct[](1);
        list[0] = InstantWithdrawalFusesParamsStruct(address(erc4626SupplyFuse), params);
        vm.prank(TestAddresses.CONFIG_INSTANT_WITHDRAWAL_FUSES_MANAGER);
        PlasmaVaultGovernance(address(vaultA)).configureInstantWithdrawalFuses(list);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // 1. Precondition for withdraw: idle > amount + 10
    // ---------------------------------------------------------------------------------------------------------------

    function testShouldRevertWhenIdleEqualsAmountPlusOffsetOnLossPathWithBoost() public {
        // given: A lost, its idle balance is exactly amount + 10; C's whole position is below its principal
        _setUpLossWithIdle(PRINCIPAL + WITHDRAW_OFFSET);
        assertLt(vaultA.convertToAssets(C_SHARES), PRINCIPAL, "position below principal: a boost is needed");
        State memory before_ = _state();

        // when / then
        _expectInsufficient(PRINCIPAL + WITHDRAW_OFFSET, PRINCIPAL + WITHDRAW_OFFSET);
        _reserveExit(vaultA, PRINCIPAL);

        // then: nothing changed
        _assertSameState(before_, "loss boundary revert");
        assertEq(before_.principal, PRINCIPAL, "principal kept");
        assertEq(vaultA.totalAssetsInMarket(BOOST_MARKET), 0, "no boost booked");
    }

    function testShouldExitWhenIdleIsOneAboveAmountPlusOffsetOnLossPathWithBoost() public {
        // given
        _setUpLossWithIdle(PRINCIPAL + WITHDRAW_OFFSET + 1);
        uint256 usdcCBefore = usdc.balanceOf(address(vaultC));
        vm.recordLogs();

        // when
        _reserveExit(vaultA, PRINCIPAL);

        // then: the exit passed with a boost, and A paid exactly the amount
        (uint256 surplusAssets, uint256 exitCount) = _exitEventAssets(vm.getRecordedLogs());
        assertEq(exitCount, 1, "one exit event");
        assertEq(surplusAssets, 0, "no surplus on the loss path");
        assertEq(usdc.balanceOf(address(vaultC)) - usdcCBefore, PRINCIPAL, "C got the principal");
        assertEq(usdc.balanceOf(address(vaultA)), WITHDRAW_OFFSET + 1, "A paid only the amount");
        assertEq(_principal(vaultA), 0, "principal zero");
        assertEq(_boost(vaultA), 0, "boost cleared");
        assertEq(vaultA.balanceOf(address(vaultC)), 0, "all C shares burned");
    }

    function testShouldRevertWhenIdleEqualsAmountPlusOffsetOnNoBoostPath() public {
        // given: A did not lose; its idle balance is exactly amount + 10 (the rest is parked in C)
        _setUpPrincipalInA();
        _moveIdleOutOfA(PRINCIPAL + WITHDRAW_OFFSET);
        assertEq(vaultA.convertToAssets(C_SHARES), PRINCIPAL, "position equals principal: no boost");
        State memory before_ = _state();

        // when / then
        _expectInsufficient(PRINCIPAL + WITHDRAW_OFFSET, PRINCIPAL + WITHDRAW_OFFSET);
        _reserveExit(vaultA, PRINCIPAL);

        // then
        _assertSameState(before_, "no-boost boundary revert");
    }

    function testShouldExitWhenIdleIsOneAboveAmountPlusOffsetOnNoBoostPath() public {
        // given
        _setUpPrincipalInA();
        _moveIdleOutOfA(PRINCIPAL + WITHDRAW_OFFSET + 1);
        uint256 usdcCBefore = usdc.balanceOf(address(vaultC));

        // when
        _reserveExit(vaultA, PRINCIPAL);

        // then
        assertEq(usdc.balanceOf(address(vaultC)) - usdcCBefore, PRINCIPAL, "C got the principal");
        assertEq(usdc.balanceOf(address(vaultA)), WITHDRAW_OFFSET + 1, "A paid only the amount");
        assertEq(_principal(vaultA), 0, "principal zero");
        assertEq(vaultA.balanceOf(address(vaultC)), 0, "all C shares burned");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // 2. Surplus buffer at a full exit in profit: idle after the withdraw > value + 2%
    // ---------------------------------------------------------------------------------------------------------------

    function testShouldRevertAtomicallyWhenIdleAfterWithdrawDoesNotCoverSurplusBuffer() public {
        // given: profit; the buffer for the surplus redeem is value + 2%
        _setUpProfit();
        (uint256 value, uint256 required) = _surplusRequired(PRINCIPAL);
        assertGt(value, 0, "there is a surplus");
        assertGt(required, value, "buffer above value");
        assertGt(required + PRINCIPAL, PRINCIPAL + WITHDRAW_OFFSET, "the first check alone would pass");

        // and: the idle balance after the withdraw equals the buffer exactly (pull threshold: idle <= required)
        _moveIdleOutOfA(PRINCIPAL + required);
        State memory before_ = _state();

        // when / then: the surplus check reverts, and so does the earlier withdraw
        _expectInsufficient(required, required);
        _reserveExit(vaultA, PRINCIPAL);

        _assertSameState(before_, "surplus buffer revert");
        assertEq(before_.principal, PRINCIPAL, "principal kept");
    }

    function testShouldReturnSurplusWhenIdleAfterWithdrawIsOneAboveSurplusBuffer() public {
        // given
        _setUpProfit();
        (uint256 value, uint256 required) = _surplusRequired(PRINCIPAL);
        _moveIdleOutOfA(PRINCIPAL + required + 1);
        uint256 usdcCBefore = usdc.balanceOf(address(vaultC));
        vm.recordLogs();

        // when
        _reserveExit(vaultA, PRINCIPAL);

        // then
        (uint256 surplusAssets, uint256 exitCount) = _exitEventAssets(vm.getRecordedLogs());
        assertEq(exitCount, 1, "one exit event");
        assertEq(surplusAssets, value, "surplus redeemed at the modelled value");
        assertEq(usdc.balanceOf(address(vaultC)) - usdcCBefore, PRINCIPAL, "C kept the principal only");
        assertEq(usdc.balanceOf(address(vaultA)), required + 1, "A paid only the amount in the end");
        assertEq(_principal(vaultA), 0, "principal zero");
        assertEq(vaultA.balanceOf(address(vaultC)), 0, "all C shares burned");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // 3. The final check fires
    // ---------------------------------------------------------------------------------------------------------------

    function testShouldRevertWithMismatchWhenHookTakesUsdcOutOfMemberVaultDuringWithdraw() public {
        // given: profit (a 7 wei loss does not lower C's position below the principal) and plenty of idle cash, so
        //        both liquidity checks pass; a pre-hook on A.withdraw removes 7 wei
        _setUpProfit();
        _moveIdleOutOfA(PRINCIPAL + 20_000_000);
        _setPreHook(vaultA, IERC4626.withdraw.selector, address(new IdleMoverHook(address(usdc), SINK, 7, false)));
        State memory before_ = _state();

        // when / then
        vm.expectRevert(
            abi.encodeWithSelector(
                ReserveVaultSupplyFuseIdleBalanceMismatch.selector,
                address(vaultA),
                20_000_000,
                20_000_000 - 7
            )
        );
        _reserveExit(vaultA, PRINCIPAL);

        _assertSameState(before_, "idle mismatch (out)");
    }

    function testShouldRevertWithMismatchWhenHookAddsUsdcToMemberVaultDuringWithdraw() public {
        // given: a pre-hook on A.withdraw adds 7 wei
        _setUpPrincipalInA();
        _moveIdleOutOfA(PRINCIPAL + 1_000_000);
        _setPreHook(vaultA, IERC4626.withdraw.selector, address(new IdleMoverHook(address(usdc), SINK, 7, true)));
        State memory before_ = _state();

        // when / then
        vm.expectRevert(
            abi.encodeWithSelector(
                ReserveVaultSupplyFuseIdleBalanceMismatch.selector,
                address(vaultA),
                1_000_000,
                1_000_000 + 7
            )
        );
        _reserveExit(vaultA, PRINCIPAL);

        _assertSameState(before_, "idle mismatch (in)");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // 4. Violated no-request assumption: the final check is the hard guarantee
    // ---------------------------------------------------------------------------------------------------------------

    function testShouldRevertWithMismatchWhenMemberVaultPullsForReleasedRequestShares() public {
        // given: A has an extra market with a mock ERC4626 on its instant-withdraw list, holding most of A's cash
        _setUpPrincipalInA();
        MockERC4626 mock = new MockERC4626(IERC20(address(usdc)), "Mock", "MOCK");
        Erc4626SupplyFuse mockSupplyFuse = new Erc4626SupplyFuse(IporFusionMarkets.ERC4626_0002);
        Erc4626BalanceFuse mockBalanceFuse = new Erc4626BalanceFuse(IporFusionMarkets.ERC4626_0002);
        address[] memory mockSubstrate = new address[](1);
        mockSubstrate[0] = address(mock);
        _addFuse(vaultA, address(mockSupplyFuse));
        _addMarket(vaultA, IporFusionMarkets.ERC4626_0002, address(mockBalanceFuse), _toSubstrates(mockSubstrate));

        bytes32[] memory params = new bytes32[](2);
        params[0] = bytes32(0);
        params[1] = PlasmaVaultConfigLib.addressToBytes32(address(mock));
        InstantWithdrawalFusesParamsStruct[] memory list = new InstantWithdrawalFusesParamsStruct[](1);
        list[0] = InstantWithdrawalFusesParamsStruct(address(mockSupplyFuse), params);
        vm.prank(TestAddresses.CONFIG_INSTANT_WITHDRAWAL_FUSES_MANAGER);
        PlasmaVaultGovernance(address(vaultA)).configureInstantWithdrawalFuses(list);

        uint256 idle0 = 150_000_000;
        _execute(
            vaultA,
            address(mockSupplyFuse),
            abi.encodeCall(
                Erc4626SupplyFuse.enter,
                (Erc4626SupplyFuseEnterData(address(mock), usdc.balanceOf(address(vaultA)) - idle0, 0))
            )
        );
        assertEq(usdc.balanceOf(address(vaultA)), idle0, "idle of A");

        // and: a released withdraw request of USER (200 USDC of shares)
        vm.warp(block.timestamp + DELAY + 1);
        vm.prank(ATOMIST);
        withdrawManagerA.updateWithdrawWindow(DELAY);
        uint256 requested = 20_000_000_000;
        vm.prank(USER);
        withdrawManagerA.requestShares(requested);
        vm.warp(block.timestamp + 2);
        vm.prank(ALPHA);
        withdrawManagerA.releaseFunds(block.timestamp - 1, requested);
        assertEq(withdrawManagerA.getSharesToRelease(), requested, "shares released");

        // and: idle is above amount + 10 (the fuse check passes) but below the real target with the reserved shares
        uint256 target = PRINCIPAL + WITHDRAW_OFFSET + (vaultA.convertToAssets(requested) * 10001) / 10000;
        assertGt(idle0, PRINCIPAL + WITHDRAW_OFFSET, "the fuse precondition passes");
        assertLt(idle0, target, "A would pull for the released shares");
        State memory before_ = _state();

        // when / then: A pulls from the mock during withdraw, its balance moves, the final check reverts the exit
        vm.expectRevert(
            abi.encodeWithSelector(
                ReserveVaultSupplyFuseIdleBalanceMismatch.selector,
                address(vaultA),
                idle0 - PRINCIPAL,
                target - PRINCIPAL
            )
        );
        _reserveExit(vaultA, PRINCIPAL);

        _assertSameState(before_, "pull for released request");
        assertEq(usdc.balanceOf(address(mock)), 1_111_111_111 - idle0, "mock market untouched after the revert");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // 5. Characterization: the locked reserve vault never pays a pull of the member vault
    // ---------------------------------------------------------------------------------------------------------------

    function testShouldKeepFundsInLockedReserveVaultWhenMemberVaultPullsDuringStandardErc4626Exit() public {
        // given: C holds A shares through the standard ERC4626 market (not the reserve fuse); A holds C shares in its
        //        ERC4626 market, with C on its instant-withdraw list
        _userDeposit(USERS_DEPOSIT);
        _fundC(PRINCIPAL);
        address[] memory memberSubstrate = new address[](1);
        memberSubstrate[0] = address(vaultA);
        _addFuse(vaultC, address(erc4626SupplyFuse));
        _addMarket(vaultC, ERC4626_MARKET, address(erc4626BalanceFuse), _toSubstrates(memberSubstrate));
        _execute(
            vaultC,
            address(erc4626SupplyFuse),
            abi.encodeCall(Erc4626SupplyFuse.enter, (Erc4626SupplyFuseEnterData(address(vaultA), PRINCIPAL, 0)))
        );
        _configureInstantWithdrawOfAOnC();

        // and: A's idle is in the band [amount, amount + 10]: enough for the withdrawal, but A still tries to pull
        uint256 amount = 60_000_000;
        _moveIdleOutOfA(amount + 5);
        uint256 usdcCBefore = usdc.balanceOf(address(vaultC));
        uint256 supplyCBefore = vaultC.totalSupply();
        uint256 sharesOfAInCBefore = vaultC.balanceOf(address(vaultA));
        vm.recordLogs();

        // when: C exits A with the standard fuse
        _execute(
            vaultC,
            address(erc4626SupplyFuse),
            abi.encodeCall(Erc4626SupplyFuse.exit, (Erc4626SupplyFuseExitData(address(vaultA), amount, 0, 0)))
        );

        // then: A tried to pull from C, the attempt failed on C's lock and was reported, the withdrawal was paid from idle
        assertEq(_countFailed(vm.getRecordedLogs()), 1, "A's pull from C failed (C is locked)");
        assertEq(usdc.balanceOf(address(vaultC)) - usdcCBefore, amount, "C received the amount from A's idle cash");
        assertEq(usdc.balanceOf(address(vaultA)), 5, "A paid from idle");

        // and: C's funds never left C
        assertEq(vaultC.totalSupply(), supplyCBefore, "C supply unchanged");
        assertEq(vaultC.balanceOf(address(vaultA)), sharesOfAInCBefore, "A kept its C shares");
    }

    function testShouldPayPullOfMemberVaultWhenReserveVaultIsNotLocked() public {
        // given: the same setup as the locked characterization (A is exempt from C's delay, C is on A's list)
        _userDeposit(USERS_DEPOSIT);
        _fundC(PRINCIPAL);
        _configureInstantWithdrawOfAOnC();
        uint256 amount = 10_000_000;
        _moveIdleOutOfA(amount + 5);
        uint256 usdcCBefore = usdc.balanceOf(address(vaultC));
        uint256 usdcABefore = usdc.balanceOf(address(vaultA));
        uint256 sharesOfAInCBefore = vaultC.balanceOf(address(vaultA));
        vm.recordLogs();

        // when: the same pull of A from C, outside C's execute
        _execute(
            vaultA,
            address(erc4626SupplyFuse),
            abi.encodeCall(Erc4626SupplyFuse.exit, (Erc4626SupplyFuseExitData(address(vaultC), amount, 0, 0)))
        );

        // then: it is paid and moves C's funds, so in the locked case only C's reentrancy lock stops it
        assertEq(_countFailed(vm.getRecordedLogs()), 0, "A's pull from C did not fail");
        assertEq(usdc.balanceOf(address(vaultA)) - usdcABefore, amount, "A received the amount from C");
        assertEq(usdcCBefore - usdc.balanceOf(address(vaultC)), amount, "C paid the amount");
        assertLt(vaultC.balanceOf(address(vaultA)), sharesOfAInCBefore, "A's C shares were burned");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // 6. Characterization: a pull attempt on the locked reserve vault moves nothing and is not detected
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Profit; A parks cash in C and lists C for instant withdraw; during C's full exit the surplus `redeem` of A
    ///      starts with a pre-hook that refreshes all of A's markets. C holds the withdrawn principal while its market
    ///      balance is stale, so its share price is inflated, A's position in C is revalued upward, and A's real pull
    ///      threshold for the redeem is above the one the fuse mirrors. A's idle is between the inflated value and
    ///      the inflated value + 2%.
    function _runRefreshingHookScenario(bool withHook_) internal returns (uint256 failedPulls, uint256 surplusAssets) {
        _setUpProfit();
        _configureInstantWithdrawOfAOnC();
        if (withHook_) {
            _setPreHook(vaultA, IERC4626.redeem.selector, address(new UpdateBalancesPreHook()));
        }

        // A parks 500 USDC in C; idle after the withdraw is just above the inflated value, below inflated + 2%
        uint256 idleAfterWithdraw = 10_900_000;
        _moveIdleOutOfA(PRINCIPAL + idleAfterWithdraw);
        (uint256 value, uint256 required) = _surplusRequired(PRINCIPAL);
        assertGt(idleAfterWithdraw, required, "the fuse check passes");
        assertLt(value, idleAfterWithdraw, "sanity: idle above the uninflated value");
        State memory before_ = _state();
        vm.recordLogs();

        // when
        _reserveExit(vaultA, PRINCIPAL);

        // then: the exit passed in both variants
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 exitCount;
        (surplusAssets, exitCount) = _exitEventAssets(logs);
        failedPulls = _countFailed(logs);
        assertEq(exitCount, 1, "one exit event");
        assertEq(_principal(vaultA), 0, "principal zero");
        assertEq(usdc.balanceOf(address(vaultA)), idleAfterWithdraw, "idle of A: expected balance, no mismatch");
        assertEq(usdc.balanceOf(address(vaultC)) - before_.usdcC, PRINCIPAL, "C kept the principal only");
    }

    function testShouldNotDetectPullAttemptOnLockedReserveVaultWhenRefreshingHookRaisesThreshold() public {
        (uint256 failedPulls, uint256 surplusAssets) = _runRefreshingHookScenario(true);

        // A tried to pull from the locked C and got nothing: the exit still passed, the pull was not detected
        assertEq(failedPulls, 1, "A attempted a pull on locked C");
        assertGt(surplusAssets, 10_200_000, "the surplus was revalued above the fuse's mirror");
        assertLe(surplusAssets, 10_900_000, "A held enough idle cash to pay the revalued surplus");
        assertGt(surplusAssets + (surplusAssets * 2) / 100, 10_900_000, "idle was within A's real pull threshold");
    }

    function testShouldNotAttemptPullWithoutRefreshingHook() public {
        // control: the same scenario without the hook has no pull attempt at all
        (uint256 failedPulls, ) = _runRefreshingHookScenario(false);

        assertEq(failedPulls, 0, "no pull attempt without the hook");
    }
}
