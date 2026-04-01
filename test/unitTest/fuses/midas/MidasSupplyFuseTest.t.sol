// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {MidasSupplyFuse, MidasSupplyFuseEnterData, MidasSupplyFuseExitData} from "../../../../contracts/fuses/midas/MidasSupplyFuse.sol";
import {MidasSubstrateLib} from "../../../../contracts/fuses/midas/lib/MidasSubstrateLib.sol";
import {Errors} from "../../../../contracts/libraries/errors/Errors.sol";
import {IporMath} from "../../../../contracts/libraries/math/IporMath.sol";
import {MidasSupplyFuseHarness} from "./mocks/supply_fuse/MidasSupplyFuseHarness.sol";
import {MockERC20ForSupplyFuse} from "./mocks/supply_fuse/MockERC20ForSupplyFuse.sol";
import {MockMidasDepositVaultForSupplyFuse} from "./mocks/supply_fuse/MockMidasDepositVaultForSupplyFuse.sol";
import {MockMidasRedemptionVaultForSupplyFuse} from "./mocks/supply_fuse/MockMidasRedemptionVaultForSupplyFuse.sol";

/// @title MidasSupplyFuseTest
/// @notice Unit tests for MidasSupplyFuse — 100% branch coverage target
/// @dev MidasSupplyFuse runs via delegatecall from PlasmaVault. Tests use a harness that:
///      1. Holds ERC20 balances (acts as address(this) for the fuse)
///      2. Has PlasmaVault storage layout for substrate grants
///      3. Delegatecalls enter/exit/instantWithdraw to the fuse
contract MidasSupplyFuseTest is Test {
    // ============ Constants ============

    uint256 public constant MARKET_ID = 7;

    // ============ State Variables ============

    MidasSupplyFuse public fuse;
    MidasSupplyFuseHarness public harness;

    MockERC20ForSupplyFuse public tokenIn;
    MockERC20ForSupplyFuse public mToken;
    MockERC20ForSupplyFuse public tokenOut;
    MockMidasDepositVaultForSupplyFuse public depositVault;
    MockMidasRedemptionVaultForSupplyFuse public redemptionVault;

    // ============ Setup ============

    function setUp() public {
        // Deploy the fuse (reads MARKET_ID immutable)
        fuse = new MidasSupplyFuse(MARKET_ID);

        // Deploy token mocks (harness will hold balances)
        tokenIn = new MockERC20ForSupplyFuse("USDC", "USDC", 6);
        mToken = new MockERC20ForSupplyFuse("mTBILL", "mTBILL", 18);
        tokenOut = new MockERC20ForSupplyFuse("USDC-out", "USDC", 6);

        // Deploy vault mocks
        depositVault = new MockMidasDepositVaultForSupplyFuse(address(mToken));
        redemptionVault = new MockMidasRedemptionVaultForSupplyFuse(address(tokenOut));

        // Deploy harness pointing at the fuse
        harness = new MidasSupplyFuseHarness(address(fuse));

        // Label addresses
        vm.label(address(fuse), "MidasSupplyFuse");
        vm.label(address(harness), "MidasSupplyFuseHarness");
        vm.label(address(tokenIn), "TokenIn(USDC-6dec)");
        vm.label(address(mToken), "mToken(18dec)");
        vm.label(address(tokenOut), "TokenOut(USDC-6dec)");
        vm.label(address(depositVault), "MockDepositVault");
        vm.label(address(redemptionVault), "MockRedemptionVault");
    }

    // ============ Helpers ============

    /// @dev Grant all substrates needed for enter: mToken + depositVault + tokenIn
    function _grantEnterSubstrates() internal {
        harness.grantEnterSubstrates(MARKET_ID, address(mToken), address(depositVault), address(tokenIn));
    }

    /// @dev Grant all substrates needed for exit: mToken + instantRedemptionVault + tokenOut
    function _grantExitSubstrates() internal {
        harness.grantExitSubstrates(MARKET_ID, address(mToken), address(redemptionVault), address(tokenOut));
    }

    /// @dev Set tokenIn balance on the harness (simulates PlasmaVault holding tokens)
    function _setTokenInBalance(uint256 amount) internal {
        tokenIn.mint(address(harness), amount);
    }

    /// @dev Set mToken balance on the harness
    function _setMTokenBalance(uint256 amount) internal {
        mToken.mint(address(harness), amount);
    }

    /// @dev Set tokenOut balance on the redemption vault (so it can transfer to harness)
    function _setTokenOutBalanceOnVault(uint256 amount) internal {
        tokenOut.mint(address(redemptionVault), amount);
    }

    /// @dev Build a standard enter data struct
    function _enterData(uint256 amount_, uint256 minMTokenAmountOut_) internal view returns (MidasSupplyFuseEnterData memory) {
        return MidasSupplyFuseEnterData({
            mToken: address(mToken),
            tokenIn: address(tokenIn),
            amount: amount_,
            minMTokenAmountOut: minMTokenAmountOut_,
            depositVault: address(depositVault)
        });
    }

    /// @dev Build a standard exit data struct
    function _exitData(uint256 amount_, uint256 minTokenOutAmount_) internal view returns (MidasSupplyFuseExitData memory) {
        return MidasSupplyFuseExitData({
            mToken: address(mToken),
            amount: amount_,
            minTokenOutAmount: minTokenOutAmount_,
            tokenOut: address(tokenOut),
            instantRedemptionVault: address(redemptionVault)
        });
    }

    // ============================================================
    // 1. Constructor Tests
    // ============================================================

    /// @notice C2 — constructor sets VERSION and MARKET_ID correctly
    function test_constructor_ShouldSetVersionAndMarketId() public view {
        // then
        assertEq(fuse.VERSION(), address(fuse), "VERSION should be the fuse deployment address");
        assertEq(fuse.MARKET_ID(), MARKET_ID, "MARKET_ID should match the constructor argument");
    }

    /// @notice C1 — constructor reverts when marketId == 0
    function test_constructor_ShouldRevert_WhenMarketIdIsZero() public {
        // when/then
        vm.expectRevert(abi.encodeWithSelector(Errors.WrongValue.selector));
        new MidasSupplyFuse(0);
    }

    // ============================================================
    // 2. Enter Tests
    // ============================================================

    /// @notice E1 — early return when amount == 0, no external calls
    function test_enter_ShouldReturnEarly_WhenAmountIsZero() public {
        // given — substrates not granted (would revert if we passed amount check)
        MidasSupplyFuseEnterData memory data = _enterData(0, 0);

        // when — record logs to detect any events
        vm.recordLogs();
        harness.enter(data);

        // then — no events should have been emitted, no revert
        assertEq(vm.getRecordedLogs().length, 0, "No events should be emitted for zero amount");
        assertEq(depositVault.depositInstantCallCount(), 0, "depositInstant should not be called for zero amount");
    }

    /// @notice E2 — revert when mToken substrate not granted
    function test_enter_ShouldRevert_WhenMTokenNotGranted() public {
        // given — no substrates granted
        MidasSupplyFuseEnterData memory data = _enterData(1000e6, 0);

        // when/then
        vm.expectRevert(
            abi.encodeWithSelector(MidasSubstrateLib.MidasFuseUnsupportedSubstrate.selector, uint8(1), address(mToken))
        );
        harness.enter(data);
    }

    /// @notice E3 — revert when depositVault substrate not granted (mToken is granted)
    function test_enter_ShouldRevert_WhenDepositVaultNotGranted() public {
        // given — only mToken granted
        harness.grantMToken(MARKET_ID, address(mToken));

        MidasSupplyFuseEnterData memory data = _enterData(1000e6, 0);

        // when/then
        vm.expectRevert(
            abi.encodeWithSelector(MidasSubstrateLib.MidasFuseUnsupportedSubstrate.selector, uint8(2), address(depositVault))
        );
        harness.enter(data);
    }

    /// @notice E4 — revert when tokenIn substrate not granted (mToken + depositVault granted)
    function test_enter_ShouldRevert_WhenTokenInNotGranted() public {
        // given — Deploy a separate fuse/harness with specialMarket.
        // grantEnterSubstrates is called with fakeTokenIn (not address(tokenIn)),
        // so address(tokenIn) is not a granted ASSET substrate.
        uint256 specialMarket = 999;
        address fakeTokenIn = makeAddr("fakeTokenIn");
        vm.label(fakeTokenIn, "FakeTokenIn");

        MidasSupplyFuse fuse999 = new MidasSupplyFuse(specialMarket);
        MidasSupplyFuseHarness harness999 = new MidasSupplyFuseHarness(address(fuse999));
        harness999.grantEnterSubstrates(specialMarket, address(mToken), address(depositVault), fakeTokenIn);

        MidasSupplyFuseEnterData memory data = MidasSupplyFuseEnterData({
            mToken: address(mToken),
            tokenIn: address(tokenIn), // real tokenIn — not granted
            amount: 1000e6,
            minMTokenAmountOut: 0,
            depositVault: address(depositVault)
        });

        // when/then
        vm.expectRevert(
            abi.encodeWithSelector(MidasSubstrateLib.MidasFuseUnsupportedSubstrate.selector, uint8(5), address(tokenIn))
        );
        harness999.enter(data);
    }

    /// @notice E7 — early return when tokenIn balance is zero (finalAmount == 0)
    function test_enter_ShouldReturnEarly_WhenTokenInBalanceIsZero() public {
        // given
        _grantEnterSubstrates();
        // harness has 0 tokenIn balance
        // data.amount = 1000 → finalAmount = min(0, 1000) = 0 → early return

        vm.recordLogs();
        harness.enter(_enterData(1000e6, 0));

        // then — no depositInstant call, no event
        assertEq(depositVault.depositInstantCallCount(), 0, "depositInstant should not be called when balance is 0");
        assertEq(vm.getRecordedLogs().length, 0, "No event emitted when finalAmount == 0");
    }

    /// @notice E5 + E9 — caps amount to balance when balance < requested amount
    function test_enter_ShouldCapAmount_WhenBalanceLessThanRequestedAmount() public {
        // given
        _grantEnterSubstrates();
        uint256 balance = 500e6;
        uint256 requestedAmount = 1000e6;
        uint256 minMTokenOut = 500e18;
        _setTokenInBalance(balance);
        depositVault.setMTokensToMint(500e18); // mint exactly minMTokenOut

        MidasSupplyFuseEnterData memory data = MidasSupplyFuseEnterData({
            mToken: address(mToken),
            tokenIn: address(tokenIn),
            amount: requestedAmount,
            minMTokenAmountOut: minMTokenOut,
            depositVault: address(depositVault)
        });

        // when
        harness.enter(data);

        // then — depositInstant called with WAD(500e6, 6) = 500e18
        uint256 expectedAmountInWad = IporMath.convertToWad(balance, 6);
        assertEq(depositVault.lastAmountToken(), expectedAmountInWad, "depositInstant should receive WAD-converted capped amount");
        assertEq(depositVault.lastTokenIn(), address(tokenIn), "depositInstant should receive correct tokenIn");
    }

    /// @notice E6 + E9 — uses requested amount when balance >= requested amount
    function test_enter_ShouldUseRequestedAmount_WhenBalanceGreaterOrEqual() public {
        // given
        _grantEnterSubstrates();
        uint256 requestedAmount = 1000e6;
        _setTokenInBalance(2000e6); // balance > amount
        depositVault.setMTokensToMint(1000e18);

        MidasSupplyFuseEnterData memory data = _enterData(requestedAmount, 1000e18);

        // when
        harness.enter(data);

        // then — depositInstant called with WAD(1000e6, 6) = 1000e18
        uint256 expectedAmountInWad = IporMath.convertToWad(requestedAmount, 6);
        assertEq(depositVault.lastAmountToken(), expectedAmountInWad, "depositInstant should receive WAD of requested amount");
    }

    /// @notice E8 — revert when mToken received < minMTokenAmountOut
    function test_enter_ShouldRevert_WhenInsufficientMTokenReceived() public {
        // given
        _grantEnterSubstrates();
        _setTokenInBalance(1000e6);
        uint256 minMTokenOut = 1000e18;
        depositVault.setMTokensToMint(999e18); // mint less than minimum

        MidasSupplyFuseEnterData memory data = _enterData(1000e6, minMTokenOut);

        // when/then
        vm.expectRevert(
            abi.encodeWithSelector(
                MidasSupplyFuse.MidasSupplyFuseInsufficientMTokenReceived.selector,
                minMTokenOut,
                999e18
            )
        );
        harness.enter(data);
    }

    /// @notice E9 (boundary) — succeeds when mTokenReceived == minMTokenAmountOut exactly
    function test_enter_ShouldSucceed_WhenExactMinMTokenReceived() public {
        // given
        _grantEnterSubstrates();
        _setTokenInBalance(1000e6);
        uint256 minMTokenOut = 1000e18;
        depositVault.setMTokensToMint(1000e18); // exactly equal

        MidasSupplyFuseEnterData memory data = _enterData(1000e6, minMTokenOut);

        // when — must not revert
        harness.enter(data);

        // then
        assertEq(mToken.balanceOf(address(harness)), 1000e18, "Harness should hold the minted mTokens");
    }

    /// @notice E9 — approve before deposit, clear after deposit (approval lifecycle)
    function test_enter_ShouldApproveAndClearApproval() public {
        // given
        _grantEnterSubstrates();
        uint256 amount = 500e6;
        _setTokenInBalance(amount);
        depositVault.setMTokensToMint(500e18);

        MidasSupplyFuseEnterData memory data = _enterData(amount, 500e18);

        // Clear any prior approve history
        tokenIn.clearApproveHistory();

        // when
        harness.enter(data);

        // then — two approve calls: (depositVault, finalAmount) then (depositVault, 0)
        assertEq(tokenIn.approveCallCount(), 2, "Should have exactly 2 approve calls");
        assertEq(tokenIn.approveSpenders(0), address(depositVault), "First approve: spender must be depositVault");
        assertEq(tokenIn.approveAmounts(0), amount, "First approve: amount must be finalAmount");
        assertEq(tokenIn.approveSpenders(1), address(depositVault), "Second approve: spender must be depositVault");
        assertEq(tokenIn.approveAmounts(1), 0, "Second approve: amount must be 0 (clear approval)");
    }

    /// @notice E9 — correct event emitted on successful enter
    function test_enter_ShouldEmitCorrectEvent() public {
        // given
        _grantEnterSubstrates();
        uint256 amount = 500e6;
        _setTokenInBalance(amount);
        depositVault.setMTokensToMint(500e18);

        MidasSupplyFuseEnterData memory data = _enterData(amount, 500e18);

        // when/then
        vm.expectEmit(true, true, true, true, address(harness));
        emit MidasSupplyFuse.MidasSupplyFuseEnter(fuse.VERSION(), address(mToken), amount, address(depositVault));
        harness.enter(data);
    }

    /// @notice E9 (decimal conversion) — WAD conversion for 6-decimal token
    function test_enter_ShouldConvertToWad_WhenTokenHas6Decimals() public {
        // given — tokenIn already has 6 decimals
        _grantEnterSubstrates();
        uint256 finalAmount = 1_000_000; // 1 USDC = 1e6
        _setTokenInBalance(finalAmount);
        depositVault.setMTokensToMint(1e18);

        MidasSupplyFuseEnterData memory data = _enterData(finalAmount, 1e18);

        // when
        harness.enter(data);

        // then — amountInWad = 1e6 * 10^(18-6) = 1e18
        assertEq(depositVault.lastAmountToken(), 1e18, "1 USDC (6 dec) should convert to 1e18 WAD");
    }

    /// @notice E9 (decimal conversion) — no scaling for 18-decimal token
    function test_enter_ShouldConvertToWad_WhenTokenHas18Decimals() public {
        // given — deploy 18-decimal tokenIn
        MockERC20ForSupplyFuse tokenIn18 = new MockERC20ForSupplyFuse("WETH", "WETH", 18);
        vm.label(address(tokenIn18), "TokenIn18Dec");

        MockMidasDepositVaultForSupplyFuse depositVault18 = new MockMidasDepositVaultForSupplyFuse(address(mToken));
        MidasSupplyFuse fuse18 = new MidasSupplyFuse(MARKET_ID + 1);
        MidasSupplyFuseHarness harness18 = new MidasSupplyFuseHarness(address(fuse18));
        harness18.grantEnterSubstrates(MARKET_ID + 1, address(mToken), address(depositVault18), address(tokenIn18));

        uint256 finalAmount = 1e18;
        tokenIn18.mint(address(harness18), finalAmount);
        depositVault18.setMTokensToMint(1e18);

        MidasSupplyFuseEnterData memory data = MidasSupplyFuseEnterData({
            mToken: address(mToken),
            tokenIn: address(tokenIn18),
            amount: finalAmount,
            minMTokenAmountOut: 1e18,
            depositVault: address(depositVault18)
        });

        // when
        harness18.enter(data);

        // then — amountInWad = 1e18 (no conversion)
        assertEq(depositVault18.lastAmountToken(), 1e18, "18-decimal token should not be scaled (identity conversion)");
    }

    /// @notice E9 (decimal conversion) — scale up for 8-decimal token
    function test_enter_ShouldConvertToWad_WhenTokenHas8Decimals() public {
        // given — deploy 8-decimal tokenIn (e.g., WBTC)
        MockERC20ForSupplyFuse tokenIn8 = new MockERC20ForSupplyFuse("WBTC", "WBTC", 8);
        vm.label(address(tokenIn8), "TokenIn8Dec");

        MockMidasDepositVaultForSupplyFuse depositVault8 = new MockMidasDepositVaultForSupplyFuse(address(mToken));
        MidasSupplyFuse fuse8 = new MidasSupplyFuse(MARKET_ID + 2);
        MidasSupplyFuseHarness harness8 = new MidasSupplyFuseHarness(address(fuse8));
        harness8.grantEnterSubstrates(MARKET_ID + 2, address(mToken), address(depositVault8), address(tokenIn8));

        uint256 finalAmount = 1e8; // 1 WBTC
        tokenIn8.mint(address(harness8), finalAmount);
        depositVault8.setMTokensToMint(1e18);

        MidasSupplyFuseEnterData memory data = MidasSupplyFuseEnterData({
            mToken: address(mToken),
            tokenIn: address(tokenIn8),
            amount: finalAmount,
            minMTokenAmountOut: 1e18,
            depositVault: address(depositVault8)
        });

        // when
        harness8.enter(data);

        // then — amountInWad = 1e8 * 10^(18-8) = 1e18
        assertEq(depositVault8.lastAmountToken(), 1e18, "1 WBTC (8 dec) should convert to 1e18 WAD");
    }

    // ============================================================
    // 3. Exit Tests (catchExceptions_ = false)
    // ============================================================

    /// @notice X1 — early return when amount == 0
    function test_exit_ShouldReturnEarly_WhenAmountIsZero() public {
        // given — substrates not granted (would revert if we passed amount check)
        vm.recordLogs();
        harness.exit(_exitData(0, 0));

        assertEq(redemptionVault.redeemInstantCallCount(), 0, "redeemInstant should not be called for zero amount");
        assertEq(vm.getRecordedLogs().length, 0, "No events should be emitted for zero amount");
    }

    /// @notice X2 — revert when mToken substrate not granted
    function test_exit_ShouldRevert_WhenMTokenNotGranted() public {
        // given — no substrates
        vm.expectRevert(
            abi.encodeWithSelector(MidasSubstrateLib.MidasFuseUnsupportedSubstrate.selector, uint8(1), address(mToken))
        );
        harness.exit(_exitData(1000e18, 0));
    }

    /// @notice X3 — revert when instantRedemptionVault substrate not granted
    function test_exit_ShouldRevert_WhenInstantRedemptionVaultNotGranted() public {
        // given — only mToken granted
        harness.grantMToken(MARKET_ID, address(mToken));

        vm.expectRevert(
            abi.encodeWithSelector(
                MidasSubstrateLib.MidasFuseUnsupportedSubstrate.selector,
                uint8(4),
                address(redemptionVault)
            )
        );
        harness.exit(_exitData(1000e18, 0));
    }

    /// @notice X4 — revert when tokenOut substrate not granted (mToken + vault granted)
    function test_exit_ShouldRevert_WhenTokenOutNotGranted() public {
        // given — grant mToken + instantRedemptionVault but NOT tokenOut (ASSET)
        // Use same approach as E4: separate harness with fakeTokenOut
        address fakeTokenOut = makeAddr("fakeTokenOut");
        vm.label(fakeTokenOut, "FakeTokenOut");

        MidasSupplyFuse fuse2 = new MidasSupplyFuse(MARKET_ID + 10);
        MidasSupplyFuseHarness harness2 = new MidasSupplyFuseHarness(address(fuse2));
        harness2.grantExitSubstrates(MARKET_ID + 10, address(mToken), address(redemptionVault), fakeTokenOut);

        MidasSupplyFuseExitData memory data = MidasSupplyFuseExitData({
            mToken: address(mToken),
            amount: 1000e18,
            minTokenOutAmount: 0,
            tokenOut: address(tokenOut), // real tokenOut — not granted
            instantRedemptionVault: address(redemptionVault)
        });

        vm.expectRevert(
            abi.encodeWithSelector(MidasSubstrateLib.MidasFuseUnsupportedSubstrate.selector, uint8(5), address(tokenOut))
        );
        harness2.exit(data);
    }

    /// @notice X7 — early return when mToken balance is zero
    function test_exit_ShouldReturnEarly_WhenMTokenBalanceIsZero() public {
        // given — all substrates granted, but mToken balance = 0
        _grantExitSubstrates();
        // harness has 0 mToken balance → finalAmount = min(0, 1000e18) = 0 → early return

        vm.recordLogs();
        harness.exit(_exitData(1000e18, 0));

        assertEq(redemptionVault.redeemInstantCallCount(), 0, "redeemInstant should not be called when mToken balance is 0");
        assertEq(vm.getRecordedLogs().length, 0, "No event emitted when finalAmount == 0");
    }

    /// @notice X5 + X9 — caps amount to mToken balance when balance < requested
    function test_exit_ShouldCapAmount_WhenMTokenBalanceLessThanRequested() public {
        // given
        _grantExitSubstrates();
        uint256 mTokenBalance = 500e18;
        uint256 requestedAmount = 1000e18;
        uint256 tokenOutAmount = 500e6;
        _setMTokenBalance(mTokenBalance);
        _setTokenOutBalanceOnVault(tokenOutAmount);
        redemptionVault.setTokenOutToTransfer(tokenOutAmount);

        MidasSupplyFuseExitData memory data = _exitData(requestedAmount, tokenOutAmount);

        // when
        harness.exit(data);

        // then — redeemInstant called with 500e18 (capped)
        assertEq(redemptionVault.lastAmountMTokenIn(), mTokenBalance, "redeemInstant should receive capped mToken amount");
        assertEq(redemptionVault.lastTokenOut(), address(tokenOut), "redeemInstant should receive correct tokenOut");
    }

    /// @notice X6 + X9 — uses requested amount when mToken balance sufficient
    function test_exit_ShouldUseRequestedAmount_WhenMTokenBalanceSufficient() public {
        // given
        _grantExitSubstrates();
        uint256 requestedAmount = 1000e18;
        uint256 tokenOutAmount = 1000e6;
        _setMTokenBalance(2000e18); // balance > amount
        _setTokenOutBalanceOnVault(tokenOutAmount);
        redemptionVault.setTokenOutToTransfer(tokenOutAmount);

        // when
        harness.exit(_exitData(requestedAmount, tokenOutAmount));

        // then
        assertEq(redemptionVault.lastAmountMTokenIn(), requestedAmount, "redeemInstant should receive the requested amount");
    }

    /// @notice X8 — revert when tokenOut received < minTokenOutAmount
    function test_exit_ShouldRevert_WhenInsufficientTokenOutReceived() public {
        // given
        _grantExitSubstrates();
        uint256 mTokenBalance = 1000e18;
        uint256 minTokenOut = 1000e6;
        uint256 actualTransferred = 999e6;
        _setMTokenBalance(mTokenBalance);
        _setTokenOutBalanceOnVault(actualTransferred);
        redemptionVault.setTokenOutToTransfer(actualTransferred);

        MidasSupplyFuseExitData memory data = _exitData(mTokenBalance, minTokenOut);

        // when/then
        vm.expectRevert(
            abi.encodeWithSelector(
                MidasSupplyFuse.MidasSupplyFuseInsufficientTokenOutReceived.selector,
                minTokenOut,
                actualTransferred
            )
        );
        harness.exit(data);
    }

    /// @notice X9 (boundary) — succeeds when tokenOutReceived == minTokenOutAmount exactly
    function test_exit_ShouldSucceed_WhenExactMinTokenOutReceived() public {
        // given
        _grantExitSubstrates();
        uint256 mTokenBalance = 1000e18;
        uint256 minTokenOut = 1000e6;
        _setMTokenBalance(mTokenBalance);
        _setTokenOutBalanceOnVault(minTokenOut);
        redemptionVault.setTokenOutToTransfer(minTokenOut);

        // when — must not revert
        harness.exit(_exitData(mTokenBalance, minTokenOut));

        // then
        assertEq(tokenOut.balanceOf(address(harness)), minTokenOut, "Harness should hold exactly the min tokenOut");
    }

    /// @notice X10 — propagates revert when redeemInstant reverts (catchExceptions_ = false)
    function test_exit_ShouldPropagateRevert_WhenRedeemInstantReverts() public {
        // given
        _grantExitSubstrates();
        _setMTokenBalance(1000e18);
        redemptionVault.setShouldRevert(true);

        // when/then — revert propagated, not caught (specific error from mock)
        vm.expectRevert(abi.encodeWithSignature("MockRedemptionVaultReverted()"));
        harness.exit(_exitData(1000e18, 0));
    }

    /// @notice X9 — approve lifecycle: approve before redeem, clear after
    function test_exit_ShouldApproveAndClearApproval() public {
        // given
        _grantExitSubstrates();
        uint256 finalAmount = 500e18;
        _setMTokenBalance(finalAmount);
        uint256 tokenOutAmt = 500e6;
        _setTokenOutBalanceOnVault(tokenOutAmt);
        redemptionVault.setTokenOutToTransfer(tokenOutAmt);

        mToken.clearApproveHistory();

        // when
        harness.exit(_exitData(finalAmount, tokenOutAmt));

        // then — two approve calls: (redemptionVault, finalAmount) then (redemptionVault, 0)
        assertEq(mToken.approveCallCount(), 2, "Should have exactly 2 approve calls on mToken");
        assertEq(mToken.approveSpenders(0), address(redemptionVault), "First approve: spender must be redemptionVault");
        assertEq(mToken.approveAmounts(0), finalAmount, "First approve: amount must be finalAmount");
        assertEq(mToken.approveSpenders(1), address(redemptionVault), "Second approve: spender must be redemptionVault");
        assertEq(mToken.approveAmounts(1), 0, "Second approve: amount must be 0 (clear approval)");
    }

    /// @notice X9 — correct event emitted on successful exit
    function test_exit_ShouldEmitCorrectEvent() public {
        // given
        _grantExitSubstrates();
        uint256 finalAmount = 1000e18;
        uint256 tokenOutAmt = 1000e6;
        _setMTokenBalance(finalAmount);
        _setTokenOutBalanceOnVault(tokenOutAmt);
        redemptionVault.setTokenOutToTransfer(tokenOutAmt);

        // when/then
        vm.expectEmit(true, true, true, true, address(harness));
        emit MidasSupplyFuse.MidasSupplyFuseExit(
            fuse.VERSION(), address(mToken), finalAmount, address(tokenOut), address(redemptionVault)
        );
        harness.exit(_exitData(finalAmount, tokenOutAmt));
    }

    // ============================================================
    // 4. InstantWithdraw Tests (catchExceptions_ = true)
    // ============================================================

    /// @notice IW1 + IW2 — decode params and execute successful exit
    function test_instantWithdraw_ShouldDecodeParams_AndCallExit() public {
        // given
        _grantExitSubstrates();
        uint256 amount = 1000e18;
        uint256 minTokenOutAmount = 500e6;
        _setMTokenBalance(amount);
        _setTokenOutBalanceOnVault(minTokenOutAmount);
        redemptionVault.setTokenOutToTransfer(minTokenOutAmount);

        // Build params_: [amount, mToken, tokenOut, instantRedemptionVault, minTokenOutAmount]
        bytes32[] memory params = new bytes32[](5);
        params[0] = bytes32(amount);
        params[1] = bytes32(uint256(uint160(address(mToken))));
        params[2] = bytes32(uint256(uint160(address(tokenOut))));
        params[3] = bytes32(uint256(uint160(address(redemptionVault))));
        params[4] = bytes32(minTokenOutAmount);

        // when
        harness.instantWithdraw(params);

        // then — successful redemption, correct mToken amount used
        assertEq(redemptionVault.lastAmountMTokenIn(), amount, "redeemInstant should receive the decoded amount");
        assertEq(redemptionVault.lastTokenOut(), address(tokenOut), "redeemInstant should receive decoded tokenOut");
    }

    /// @notice IW1 (X1) — early return when decoded amount == 0
    function test_instantWithdraw_ShouldReturnEarly_WhenAmountIsZero() public {
        // given
        bytes32[] memory params = new bytes32[](5);
        params[0] = bytes32(0); // amount = 0
        params[1] = bytes32(uint256(uint160(address(mToken))));
        params[2] = bytes32(uint256(uint160(address(tokenOut))));
        params[3] = bytes32(uint256(uint160(address(redemptionVault))));
        params[4] = bytes32(0);

        vm.recordLogs();
        harness.instantWithdraw(params);

        // then — no external calls
        assertEq(redemptionVault.redeemInstantCallCount(), 0, "redeemInstant should not be called for zero amount");
        assertEq(vm.getRecordedLogs().length, 0, "No events for zero amount");
    }

    /// @notice IW4 — catch revert from redeemInstant and emit ExitFailed event
    function test_instantWithdraw_ShouldCatchRedeemRevert_AndEmitFailedEvent() public {
        // given
        _grantExitSubstrates();
        uint256 amount = 1000e18;
        _setMTokenBalance(amount);
        redemptionVault.setShouldRevert(true);

        bytes32[] memory params = new bytes32[](5);
        params[0] = bytes32(amount);
        params[1] = bytes32(uint256(uint160(address(mToken))));
        params[2] = bytes32(uint256(uint160(address(tokenOut))));
        params[3] = bytes32(uint256(uint160(address(redemptionVault))));
        params[4] = bytes32(uint256(0));

        // when/then — NO revert (caught), ExitFailed event emitted
        vm.expectEmit(true, true, true, true, address(harness));
        emit MidasSupplyFuse.MidasSupplyFuseExitFailed(
            fuse.VERSION(), address(mToken), amount, address(tokenOut), address(redemptionVault)
        );
        harness.instantWithdraw(params); // must not revert
    }

    /// @notice IW4 — approval cleared in catch block even when redeemInstant reverts
    function test_instantWithdraw_ShouldClearApproval_WhenRedeemReverts() public {
        // given
        _grantExitSubstrates();
        uint256 amount = 500e18;
        _setMTokenBalance(amount);
        redemptionVault.setShouldRevert(true);

        mToken.clearApproveHistory();

        bytes32[] memory params = new bytes32[](5);
        params[0] = bytes32(amount);
        params[1] = bytes32(uint256(uint160(address(mToken))));
        params[2] = bytes32(uint256(uint160(address(tokenOut))));
        params[3] = bytes32(uint256(uint160(address(redemptionVault))));
        params[4] = bytes32(uint256(0));

        // when
        harness.instantWithdraw(params);

        // then — two approve calls: (redemptionVault, amount) then (redemptionVault, 0) in catch
        assertEq(mToken.approveCallCount(), 2, "Should have 2 approve calls even when redeemInstant reverts");
        assertEq(mToken.approveAmounts(0), amount, "First approve: must set finalAmount");
        assertEq(mToken.approveAmounts(1), 0, "Second approve (catch): must clear to 0");
    }

    /// @notice IW3 — revert when slippage fails inside try block (slippage check not caught)
    function test_instantWithdraw_ShouldRevert_WhenSlippageExceeded_InTryBlock() public {
        // given
        _grantExitSubstrates();
        uint256 amount = 1000e18;
        uint256 minTokenOut = 1000e6;
        uint256 actualTransferred = 999e6; // less than min
        _setMTokenBalance(amount);
        _setTokenOutBalanceOnVault(actualTransferred);
        redemptionVault.setTokenOutToTransfer(actualTransferred);

        bytes32[] memory params = new bytes32[](5);
        params[0] = bytes32(amount);
        params[1] = bytes32(uint256(uint160(address(mToken))));
        params[2] = bytes32(uint256(uint160(address(tokenOut))));
        params[3] = bytes32(uint256(uint160(address(redemptionVault))));
        params[4] = bytes32(minTokenOut);

        // when/then — slippage check inside try block → revert (not caught by catch)
        vm.expectRevert(
            abi.encodeWithSelector(
                MidasSupplyFuse.MidasSupplyFuseInsufficientTokenOutReceived.selector,
                minTokenOut,
                actualTransferred
            )
        );
        harness.instantWithdraw(params);
    }

    /// @notice IW2 — successful instantWithdraw with event emitted
    function test_instantWithdraw_ShouldSucceed_WhenTokenOutSufficient() public {
        // given
        _grantExitSubstrates();
        uint256 amount = 1000e18;
        uint256 minTokenOut = 500e6;
        _setMTokenBalance(amount);
        _setTokenOutBalanceOnVault(minTokenOut);
        redemptionVault.setTokenOutToTransfer(minTokenOut);

        bytes32[] memory params = new bytes32[](5);
        params[0] = bytes32(amount);
        params[1] = bytes32(uint256(uint160(address(mToken))));
        params[2] = bytes32(uint256(uint160(address(tokenOut))));
        params[3] = bytes32(uint256(uint160(address(redemptionVault))));
        params[4] = bytes32(minTokenOut);

        // when
        harness.instantWithdraw(params);

        // then — MidasSupplyFuseExit event emitted (not ExitFailed)
        // Approval cleared
        assertEq(mToken.allowance(address(harness), address(redemptionVault)), 0, "mToken approval should be cleared after success");
        assertEq(tokenOut.balanceOf(address(harness)), minTokenOut, "Harness should receive tokenOut");
    }

    // ============================================================
    // 5. Fuzz Tests
    // ============================================================

    /// @notice Fuzz: enter with various amounts and balances — verifies capping and WAD conversion
    function test_enter_Fuzz_ShouldHandleVariousAmountsAndBalances(
        uint128 amount,
        uint128 balance
    ) public {
        vm.assume(amount > 0);
        vm.assume(balance > 0);
        // Avoid overflow in WAD conversion: finalAmount * 10^12 must fit in uint256
        // max safe finalAmount for 6-decimal token: type(uint128).max * 1e12 < type(uint256).max
        // type(uint128).max ≈ 3.4e38, * 1e12 = 3.4e50 << 1.15e77 (uint256 max) — safe

        // given
        _grantEnterSubstrates();
        tokenIn.mint(address(harness), balance);

        uint256 expectedFinalAmount = IporMath.min(uint256(balance), uint256(amount));
        uint256 expectedAmountInWad = IporMath.convertToWad(expectedFinalAmount, 6);
        uint256 mTokensMinted = expectedFinalAmount * 1e12; // same as WAD for 6-dec
        depositVault.setMTokensToMint(mTokensMinted);

        MidasSupplyFuseEnterData memory data = _enterData(uint256(amount), mTokensMinted);

        // when
        harness.enter(data);

        // then — verify finalAmount capping
        assertEq(depositVault.lastAmountToken(), expectedAmountInWad, "depositInstant amountInWad must match IporMath.convertToWad(min(balance, amount), 6)");
        // mTokens minted by vault equal to WAD of finalAmount
        assertEq(mToken.balanceOf(address(harness)), mTokensMinted, "Harness should hold the minted mTokens");
    }

    /// @notice Fuzz: exit with various amounts and mToken balances — verifies capping
    function test_exit_Fuzz_ShouldHandleVariousAmountsAndBalances(
        uint128 amount,
        uint128 mTokenBalance
    ) public {
        vm.assume(amount > 0);
        vm.assume(mTokenBalance > 0);

        // given
        _grantExitSubstrates();
        mToken.mint(address(harness), mTokenBalance);

        uint256 expectedFinalAmount = IporMath.min(uint256(mTokenBalance), uint256(amount));
        uint256 tokenOutAmt = 1e6; // fixed tokenOut, just need >= minTokenOutAmount
        tokenOut.mint(address(redemptionVault), tokenOutAmt);
        redemptionVault.setTokenOutToTransfer(tokenOutAmt);

        MidasSupplyFuseExitData memory data = _exitData(uint256(amount), tokenOutAmt);

        // when
        harness.exit(data);

        // then — redeemInstant called with min(balance, amount)
        assertEq(redemptionVault.lastAmountMTokenIn(), expectedFinalAmount, "redeemInstant must receive min(mTokenBalance, amount)");
    }

    /// @notice Fuzz: exit slippage boundary — verifies minTokenOut check across value pairs
    function test_exit_Fuzz_SlippageBoundary(
        uint64 minTokenOut,
        uint64 tokenOutTransferred
    ) public {
        vm.assume(minTokenOut > 0);
        vm.assume(tokenOutTransferred > 0);

        // given
        _grantExitSubstrates();
        uint256 amount = 1000e18;
        _setMTokenBalance(amount);
        _setTokenOutBalanceOnVault(uint256(tokenOutTransferred));
        redemptionVault.setTokenOutToTransfer(uint256(tokenOutTransferred));

        MidasSupplyFuseExitData memory data = _exitData(amount, uint256(minTokenOut));

        // when/then
        if (uint256(tokenOutTransferred) < uint256(minTokenOut)) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    MidasSupplyFuse.MidasSupplyFuseInsufficientTokenOutReceived.selector,
                    uint256(minTokenOut),
                    uint256(tokenOutTransferred)
                )
            );
            harness.exit(data);
        } else {
            harness.exit(data); // must not revert
            assertEq(tokenOut.balanceOf(address(harness)), uint256(tokenOutTransferred), "Harness should receive transferred tokenOut");
        }
    }

    /// @notice Fuzz: WAD conversion formula verified across decimal range
    function test_enter_Fuzz_WadConversion(uint128 amount, uint8 decimals) public {
        vm.assume(amount > 0);
        vm.assume(decimals <= 18);
        vm.assume(decimals >= 6); // tested separately below 6

        // Deploy fresh tokens/vaults for this decimal
        MockERC20ForSupplyFuse tokenInFuzz = new MockERC20ForSupplyFuse("T", "T", decimals);
        MockMidasDepositVaultForSupplyFuse depositVaultFuzz = new MockMidasDepositVaultForSupplyFuse(address(mToken));

        uint256 fuseMarket = uint256(decimals) + 100;
        MidasSupplyFuse fuseFuzz = new MidasSupplyFuse(fuseMarket);
        MidasSupplyFuseHarness harnessFuzz = new MidasSupplyFuseHarness(address(fuseFuzz));
        harnessFuzz.grantEnterSubstrates(fuseMarket, address(mToken), address(depositVaultFuzz), address(tokenInFuzz));

        tokenInFuzz.mint(address(harnessFuzz), uint256(amount));

        uint256 expectedAmountInWad = IporMath.convertToWad(uint256(amount), decimals);
        depositVaultFuzz.setMTokensToMint(expectedAmountInWad);

        MidasSupplyFuseEnterData memory data = MidasSupplyFuseEnterData({
            mToken: address(mToken),
            tokenIn: address(tokenInFuzz),
            amount: uint256(amount),
            minMTokenAmountOut: expectedAmountInWad,
            depositVault: address(depositVaultFuzz)
        });

        // when
        harnessFuzz.enter(data);

        // then — verify WAD conversion formula
        assertEq(
            depositVaultFuzz.lastAmountToken(),
            expectedAmountInWad,
            "depositInstant must receive IporMath.convertToWad(finalAmount, decimals)"
        );
    }

    // ============================================================
    // 6. Boundary Value Tests
    // ============================================================

    /// @notice E6 boundary — finalAmount == balance when amount == balance
    function test_enter_ShouldWork_WhenAmountEqualsBalance() public {
        // given
        _grantEnterSubstrates();
        uint256 exactAmount = 777e6;
        _setTokenInBalance(exactAmount);
        depositVault.setMTokensToMint(777e18);

        // when
        harness.enter(_enterData(exactAmount, 777e18));

        // then
        assertEq(depositVault.lastAmountToken(), IporMath.convertToWad(exactAmount, 6), "Should use exact amount when balance == amount");
    }

    /// @notice E9 with amount = 1 (minimal value)
    function test_enter_ShouldWork_WhenAmountIsOne() public {
        // given — tokenIn has 6 decimals, amount = 1
        _grantEnterSubstrates();
        _setTokenInBalance(1);
        depositVault.setMTokensToMint(1e12);

        // when
        harness.enter(_enterData(1, 1e12));

        // then — amountInWad = 1 * 10^(18-6) = 1e12
        assertEq(depositVault.lastAmountToken(), 1e12, "1 wei USDC should convert to 1e12 WAD");
    }

    /// @notice X6 boundary — finalAmount == mToken balance when amount == balance
    function test_exit_ShouldWork_WhenAmountEqualsBalance() public {
        // given
        _grantExitSubstrates();
        uint256 exactAmount = 777e18;
        _setMTokenBalance(exactAmount);
        uint256 tokenOutAmt = 777e6;
        _setTokenOutBalanceOnVault(tokenOutAmt);
        redemptionVault.setTokenOutToTransfer(tokenOutAmt);

        // when
        harness.exit(_exitData(exactAmount, tokenOutAmt));

        // then
        assertEq(redemptionVault.lastAmountMTokenIn(), exactAmount, "Should use exact amount when mTokenBalance == amount");
    }

    /// @notice E9 with large values — no overflow in WAD conversion
    function test_enter_ShouldWork_WhenLargeValues() public {
        // given — type(uint128).max amount and balance, 6-decimal token
        _grantEnterSubstrates();
        uint256 largeAmount = type(uint128).max;
        tokenIn.mint(address(harness), largeAmount);
        uint256 expectedWad = IporMath.convertToWad(largeAmount, 6);
        depositVault.setMTokensToMint(expectedWad);

        // when — must not overflow
        harness.enter(_enterData(largeAmount, expectedWad));

        // then
        assertEq(depositVault.lastAmountToken(), expectedWad, "Large amount should convert to correct WAD without overflow");
    }

    /// @notice E9 edge case — zero-decimal token
    function test_enter_ShouldWork_WhenTokenHas0Decimals() public {
        // given
        MockERC20ForSupplyFuse tokenIn0 = new MockERC20ForSupplyFuse("ZDT", "ZDT", 0);
        MockMidasDepositVaultForSupplyFuse depositVault0 = new MockMidasDepositVaultForSupplyFuse(address(mToken));

        uint256 fuseMarket = 200;
        MidasSupplyFuse fuse0 = new MidasSupplyFuse(fuseMarket);
        MidasSupplyFuseHarness harness0 = new MidasSupplyFuseHarness(address(fuse0));
        harness0.grantEnterSubstrates(fuseMarket, address(mToken), address(depositVault0), address(tokenIn0));

        uint256 finalAmount = 1;
        tokenIn0.mint(address(harness0), finalAmount);
        depositVault0.setMTokensToMint(1e18);

        MidasSupplyFuseEnterData memory data = MidasSupplyFuseEnterData({
            mToken: address(mToken),
            tokenIn: address(tokenIn0),
            amount: finalAmount,
            minMTokenAmountOut: 1e18,
            depositVault: address(depositVault0)
        });

        // when
        harness0.enter(data);

        // then — 1 token with 0 decimals = 1e18 WAD
        assertEq(depositVault0.lastAmountToken(), 1e18, "1 unit of 0-decimal token should convert to 1e18 WAD");
    }

    /// @notice E9 edge case — 17-decimal token (minimal scale up)
    function test_enter_ShouldWork_WhenTokenHas17Decimals() public {
        // given
        MockERC20ForSupplyFuse tokenIn17 = new MockERC20ForSupplyFuse("T17", "T17", 17);
        MockMidasDepositVaultForSupplyFuse depositVault17 = new MockMidasDepositVaultForSupplyFuse(address(mToken));

        uint256 fuseMarket = 201;
        MidasSupplyFuse fuse17 = new MidasSupplyFuse(fuseMarket);
        MidasSupplyFuseHarness harness17 = new MidasSupplyFuseHarness(address(fuse17));
        harness17.grantEnterSubstrates(fuseMarket, address(mToken), address(depositVault17), address(tokenIn17));

        uint256 finalAmount = 1e17;
        tokenIn17.mint(address(harness17), finalAmount);
        depositVault17.setMTokensToMint(1e18);

        MidasSupplyFuseEnterData memory data = MidasSupplyFuseEnterData({
            mToken: address(mToken),
            tokenIn: address(tokenIn17),
            amount: finalAmount,
            minMTokenAmountOut: 1e18,
            depositVault: address(depositVault17)
        });

        // when
        harness17.enter(data);

        // then — 1e17 with 17 decimals = 1e17 * 10^(18-17) = 1e18 WAD
        assertEq(depositVault17.lastAmountToken(), 1e18, "1e17 units of 17-decimal token should convert to 1e18 WAD");
    }

    /// @notice E9 edge case — 19-decimal token (scale down)
    function test_enter_ShouldWork_WhenTokenHas19Decimals() public {
        // given
        MockERC20ForSupplyFuse tokenIn19 = new MockERC20ForSupplyFuse("T19", "T19", 19);
        MockMidasDepositVaultForSupplyFuse depositVault19 = new MockMidasDepositVaultForSupplyFuse(address(mToken));

        uint256 fuseMarket = 202;
        MidasSupplyFuse fuse19 = new MidasSupplyFuse(fuseMarket);
        MidasSupplyFuseHarness harness19 = new MidasSupplyFuseHarness(address(fuse19));
        harness19.grantEnterSubstrates(fuseMarket, address(mToken), address(depositVault19), address(tokenIn19));

        uint256 finalAmount = 1e19;
        tokenIn19.mint(address(harness19), finalAmount);
        depositVault19.setMTokensToMint(1e18);

        MidasSupplyFuseEnterData memory data = MidasSupplyFuseEnterData({
            mToken: address(mToken),
            tokenIn: address(tokenIn19),
            amount: finalAmount,
            minMTokenAmountOut: 1e18,
            depositVault: address(depositVault19)
        });

        // when
        harness19.enter(data);

        // then — 1e19 with 19 decimals = 1e19 / 10^(19-18) = 1e18 WAD
        assertEq(depositVault19.lastAmountToken(), 1e18, "1e19 units of 19-decimal token should convert to 1e18 WAD");
    }

    // ============================================================
    // 7. Event Verification Tests
    // ============================================================

    /// @notice E1 — no event emitted when amount == 0
    function test_enter_ShouldNotEmitEvent_WhenAmountIsZero() public {
        // given
        vm.recordLogs();

        // when
        harness.enter(_enterData(0, 0));

        // then
        assertEq(vm.getRecordedLogs().length, 0, "MidasSupplyFuseEnter event must not be emitted for zero amount");
    }

    /// @notice X1 — no event emitted when exit amount == 0
    function test_exit_ShouldNotEmitEvent_WhenAmountIsZero() public {
        // given
        vm.recordLogs();

        // when
        harness.exit(_exitData(0, 0));

        // then
        assertEq(vm.getRecordedLogs().length, 0, "MidasSupplyFuseExit event must not be emitted for zero amount");
    }

    /// @notice IW4 — ExitFailed emitted, Exit NOT emitted when redeemInstant reverts
    function test_instantWithdraw_ShouldEmitExitFailed_NotExit_WhenRedeemReverts() public {
        // given
        _grantExitSubstrates();
        uint256 amount = 1000e18;
        _setMTokenBalance(amount);
        redemptionVault.setShouldRevert(true);

        bytes32[] memory params = new bytes32[](5);
        params[0] = bytes32(amount);
        params[1] = bytes32(uint256(uint160(address(mToken))));
        params[2] = bytes32(uint256(uint160(address(tokenOut))));
        params[3] = bytes32(uint256(uint160(address(redemptionVault))));
        params[4] = bytes32(uint256(0));

        // Record all logs
        vm.recordLogs();
        harness.instantWithdraw(params);

        // Inspect logs
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 exitSelector = keccak256("MidasSupplyFuseExit(address,address,uint256,address,address)");
        bytes32 exitFailedSelector = keccak256("MidasSupplyFuseExitFailed(address,address,uint256,address,address)");

        bool exitEmitted = false;
        bool exitFailedEmitted = false;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == exitSelector) exitEmitted = true;
            if (logs[i].topics[0] == exitFailedSelector) exitFailedEmitted = true;
        }

        assertFalse(exitEmitted, "MidasSupplyFuseExit must NOT be emitted when redeemInstant reverts");
        assertTrue(exitFailedEmitted, "MidasSupplyFuseExitFailed MUST be emitted when redeemInstant reverts");
    }

    // ============================================================
    // 8. exit() vs instantWithdraw() Distinction Tests
    // ============================================================

    /// @notice exit() propagates revert, instantWithdraw() catches it — key behavioral difference
    function test_exitVsInstantWithdraw_DifferentExceptionHandling() public {
        // given
        _grantExitSubstrates();
        uint256 amount = 1000e18;
        redemptionVault.setShouldRevert(true);

        // exit() — must revert with specific error propagated from mock
        _setMTokenBalance(amount);
        vm.expectRevert(abi.encodeWithSignature("MockRedemptionVaultReverted()"));
        harness.exit(_exitData(amount, 0));

        // Reset mToken balance for instantWithdraw test
        // (Balance was consumed by forceApprove but revert rolls state back in EVM)
        // After revert, mToken balance should be restored
        _setMTokenBalance(amount);

        // instantWithdraw() — must NOT revert
        bytes32[] memory params = new bytes32[](5);
        params[0] = bytes32(amount);
        params[1] = bytes32(uint256(uint160(address(mToken))));
        params[2] = bytes32(uint256(uint160(address(tokenOut))));
        params[3] = bytes32(uint256(uint160(address(redemptionVault))));
        params[4] = bytes32(uint256(0));

        harness.instantWithdraw(params); // must not revert — caught
    }
}
