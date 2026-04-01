// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {MidasExecutor} from "../../../../contracts/fuses/midas/MidasExecutor.sol";
import {IporMath} from "../../../../contracts/libraries/math/IporMath.sol";
import {MockERC20ForMidasExecutor} from "./mocks/MockERC20ForMidasExecutor.sol";
import {MockMidasDepositVaultForExecutor as MockMidasDepositVault} from "./mocks/MockMidasDepositVaultForExecutor.sol";
import {MockMidasRedemptionVault} from "./mocks/MockMidasRedemptionVault.sol";

/// @title MidasExecutorTest
/// @notice Unit tests for MidasExecutor — 100% branch coverage target
contract MidasExecutorTest is Test {
    // ============ State Variables ============

    MidasExecutor public executor;

    MockERC20ForMidasExecutor public tokenIn;
    MockERC20ForMidasExecutor public mToken;
    MockERC20ForMidasExecutor public tokenOut;
    MockERC20ForMidasExecutor public tokenB;
    MockMidasDepositVault public depositVault;
    MockMidasRedemptionVault public redemptionVault;

    // The test contract itself acts as PLASMA_VAULT
    address public plasmaVault;

    address public randomCaller = makeAddr("randomCaller");

    // ============ Setup ============

    function setUp() public {
        plasmaVault = address(this);

        // Deploy executor — test contract is the authorized PlasmaVault
        executor = new MidasExecutor(plasmaVault);

        // Deploy mocks with typical configurations
        tokenIn = new MockERC20ForMidasExecutor("TokenIn", "TKN", 6);
        mToken = new MockERC20ForMidasExecutor("mToken", "mTKN", 18);
        tokenOut = new MockERC20ForMidasExecutor("TokenOut", "TOUT", 6);
        tokenB = new MockERC20ForMidasExecutor("TokenB", "TKNB", 18);
        depositVault = new MockMidasDepositVault(42);
        redemptionVault = new MockMidasRedemptionVault(99);

        // Label addresses for trace readability
        vm.label(address(executor), "MidasExecutor");
        vm.label(address(tokenIn), "TokenIn");
        vm.label(address(mToken), "mToken");
        vm.label(address(tokenOut), "TokenOut");
        vm.label(address(tokenB), "TokenB");
        vm.label(address(depositVault), "MockDepositVault");
        vm.label(address(redemptionVault), "MockRedemptionVault");
        vm.label(randomCaller, "RandomCaller");
    }

    // ============ 1. Constructor Tests ============

    /// @notice Test 1.1 — constructor sets PLASMA_VAULT correctly
    function test_constructor_setsPlasmaVault() public view {
        // then
        assertEq(executor.PLASMA_VAULT(), plasmaVault, "PLASMA_VAULT should be set to the provided address");
    }

    /// @notice Test 1.2 — constructor reverts when zero address is provided
    function test_constructor_revertsWhenZeroAddress() public {
        // when/then
        vm.expectRevert(abi.encodeWithSelector(MidasExecutor.MidasExecutorInvalidPlasmaVaultAddress.selector));
        new MidasExecutor(address(0));
    }

    // ============ 2. depositRequest Tests ============

    /// @notice Test 2.1 — happy path with 6 decimal token (USDC-like), verifies WAD scaling and approval lifecycle
    function test_depositRequest_happyPath_6decimals() public {
        // given
        uint256 amount = 1_000_000; // 1 USDC (6 decimals)
        tokenIn.mint(address(executor), amount);

        // when — called by plasmaVault (address(this))
        uint256 requestId = executor.depositRequest(address(tokenIn), amount, address(depositVault));

        // then: return value
        assertEq(requestId, 42, "requestId should match mock return value");

        // then: depositVault received WAD-scaled amount (1e6 * 1e12 = 1e18)
        assertEq(depositVault.lastTokenIn(), address(tokenIn), "depositVault should receive correct tokenIn");
        assertEq(depositVault.lastAmountToken(), 1e18, "depositVault should receive WAD-scaled amount");
        assertEq(depositVault.lastReferrerId(), bytes32(0), "referrerId should be bytes32(0)");

        // then: approval was set and then cleared
        assertEq(tokenIn.approveCallCount(), 2, "approve should be called exactly twice (set + cleanup)");
        assertEq(tokenIn.approveSpenders(0), address(depositVault), "first approve spender should be depositVault");
        assertEq(tokenIn.approveAmounts(0), amount, "first approve amount should be the deposit amount");
        assertEq(tokenIn.approveSpenders(1), address(depositVault), "second approve spender should be depositVault");
        assertEq(tokenIn.approveAmounts(1), 0, "second approve should reset to zero");
    }

    /// @notice Test 2.2 — happy path with 18 decimal token (no WAD scaling needed)
    function test_depositRequest_happyPath_18decimals() public {
        // given
        MockERC20ForMidasExecutor token18 = new MockERC20ForMidasExecutor("T18", "T18", 18);
        vm.label(address(token18), "Token18");
        depositVault.setNextRequestId(77);
        uint256 amount = 5e18;
        token18.mint(address(executor), amount);

        // when
        uint256 requestId = executor.depositRequest(address(token18), amount, address(depositVault));

        // then
        assertEq(requestId, 77, "requestId should match mock");
        assertEq(depositVault.lastAmountToken(), 5e18, "18-decimal token should not be scaled");
    }

    /// @notice Test 2.3 — happy path with 8 decimal token (WBTC-like), scales up by 1e10
    function test_depositRequest_happyPath_8decimals() public {
        // given
        MockERC20ForMidasExecutor token8 = new MockERC20ForMidasExecutor("T8", "T8", 8);
        vm.label(address(token8), "Token8");
        uint256 amount = 1e8; // 1 WBTC
        token8.mint(address(executor), amount);

        // when
        executor.depositRequest(address(token8), amount, address(depositVault));

        // then: 1e8 * 1e10 = 1e18
        assertEq(depositVault.lastAmountToken(), 1e18, "8-decimal token should scale up by 1e10");
    }

    /// @notice Test 2.4 — reverts when caller is not PLASMA_VAULT
    function test_depositRequest_revertsWhenNotPlasmaVault() public {
        // when/then
        vm.expectRevert(abi.encodeWithSelector(MidasExecutor.MidasExecutorUnauthorizedCaller.selector));
        vm.prank(randomCaller);
        executor.depositRequest(address(tokenIn), 1_000_000, address(depositVault));
    }

    /// @notice Test 2.5 — zero amount edge case: approve(0) called both times, vault receives 0
    function test_depositRequest_zeroAmount() public {
        // when — amount is 0
        executor.depositRequest(address(tokenIn), 0, address(depositVault));

        // then: depositVault called with 0 (IporMath returns 0 for 0 input)
        assertEq(depositVault.lastAmountToken(), 0, "depositVault should receive 0 WAD amount");
        assertEq(depositVault.depositRequestCallCount(), 1, "depositRequest should still be called");

        // approve called twice: first with 0, then cleanup 0
        assertEq(tokenIn.approveCallCount(), 2, "approve should be called twice even for zero amount");
        assertEq(tokenIn.approveAmounts(0), 0, "first approve amount should be 0");
        assertEq(tokenIn.approveAmounts(1), 0, "cleanup approve should also be 0");
    }

    /// @notice Test 2.6 — verifies approval ordering: approve(amount) BEFORE vault call, approve(0) AFTER
    function test_depositRequest_approvesBeforeAndCleansUpAfter() public {
        // given — use a custom token that records call order relative to vault
        uint256 amount = 500e6;
        tokenIn.mint(address(executor), amount);

        // when
        executor.depositRequest(address(tokenIn), amount, address(depositVault));

        // then: approve history shows: [approve(amount), approve(0)]
        // depositVaultCallCount==1 proves the vault was called between the two approves
        assertEq(tokenIn.approveCallCount(), 2, "exactly 2 approve calls expected");
        assertEq(tokenIn.approveAmounts(0), amount, "approve(amount) must happen first");
        assertEq(tokenIn.approveAmounts(1), 0, "approve(0) cleanup must happen last");
        assertEq(depositVault.depositRequestCallCount(), 1, "vault depositRequest must be called once");
    }

    /// @notice Test 2.7 — return value passthrough: max uint256
    function test_depositRequest_returnsRequestIdFromVault() public {
        // given
        depositVault.setNextRequestId(type(uint256).max);
        tokenIn.mint(address(executor), 1e6);

        // when
        uint256 returnedId = executor.depositRequest(address(tokenIn), 1e6, address(depositVault));

        // then
        assertEq(returnedId, type(uint256).max, "should pass through type(uint256).max requestId from vault");
    }

    // ============ 3. redeemRequest Tests ============

    /// @notice Test 3.1 — happy path: correct approval lifecycle and return value
    function test_redeemRequest_happyPath() public {
        // given
        uint256 amount = 1e18;
        mToken.mint(address(executor), amount);

        // when
        uint256 requestId = executor.redeemRequest(address(mToken), amount, address(tokenOut), address(redemptionVault));

        // then: return value
        assertEq(requestId, 99, "requestId should match mock return value");

        // then: redemptionVault received correct args
        assertEq(redemptionVault.lastTokenOut(), address(tokenOut), "tokenOut must be forwarded correctly");
        assertEq(redemptionVault.lastAmountMToken(), amount, "amount must be forwarded as-is (no WAD conversion)");

        // then: approve lifecycle on mToken
        assertEq(mToken.approveCallCount(), 2, "approve should be called twice (set + cleanup)");
        assertEq(mToken.approveSpenders(0), address(redemptionVault), "first approve spender should be redemptionVault");
        assertEq(mToken.approveAmounts(0), amount, "first approve amount should be the redeem amount");
        assertEq(mToken.approveSpenders(1), address(redemptionVault), "second approve spender should be redemptionVault");
        assertEq(mToken.approveAmounts(1), 0, "second approve should reset to zero");
    }

    /// @notice Test 3.2 — reverts when caller is not PLASMA_VAULT
    function test_redeemRequest_revertsWhenNotPlasmaVault() public {
        // when/then
        vm.expectRevert(abi.encodeWithSelector(MidasExecutor.MidasExecutorUnauthorizedCaller.selector));
        vm.prank(randomCaller);
        executor.redeemRequest(address(mToken), 1e18, address(tokenOut), address(redemptionVault));
    }

    /// @notice Test 3.3 — zero amount edge case
    function test_redeemRequest_zeroAmount() public {
        // when
        executor.redeemRequest(address(mToken), 0, address(tokenOut), address(redemptionVault));

        // then: vault called with 0
        assertEq(redemptionVault.lastAmountMToken(), 0, "redemption vault should receive 0 amount");
        assertEq(redemptionVault.redeemRequestCallCount(), 1, "redeemRequest should still be called");

        // approve called twice with 0
        assertEq(mToken.approveCallCount(), 2, "approve should be called twice even for zero amount");
        assertEq(mToken.approveAmounts(0), 0, "first approve amount should be 0");
        assertEq(mToken.approveAmounts(1), 0, "cleanup approve should also be 0");
    }

    /// @notice Test 3.4 — approval lifecycle ordering
    function test_redeemRequest_approvesBeforeAndCleansUpAfter() public {
        // given
        uint256 amount = 2e18;
        mToken.mint(address(executor), amount);

        // when
        executor.redeemRequest(address(mToken), amount, address(tokenOut), address(redemptionVault));

        // then: approve history: [approve(amount), approve(0)]
        assertEq(mToken.approveCallCount(), 2, "exactly 2 approve calls expected");
        assertEq(mToken.approveAmounts(0), amount, "approve(amount) must happen first");
        assertEq(mToken.approveAmounts(1), 0, "approve(0) cleanup must happen last");
        assertEq(redemptionVault.redeemRequestCallCount(), 1, "vault redeemRequest must be called once");
    }

    /// @notice Test 3.5 — return value passthrough: large requestId
    function test_redeemRequest_returnsRequestIdFromVault() public {
        // given
        uint256 expectedId = type(uint256).max - 1;
        redemptionVault.setNextRequestId(expectedId);
        mToken.mint(address(executor), 1e18);

        // when
        uint256 returnedId = executor.redeemRequest(address(mToken), 1e18, address(tokenOut), address(redemptionVault));

        // then
        assertEq(returnedId, expectedId, "should pass through large requestId from vault");
    }

    /// @notice Test 3.6 — tokenOut is forwarded correctly (not confused with mToken)
    function test_redeemRequest_passesCorrectTokenOutToVault() public {
        // given — distinct mToken and tokenOut addresses
        MockERC20ForMidasExecutor differentTokenOut = new MockERC20ForMidasExecutor("TOUT2", "TOUT2", 8);
        vm.label(address(differentTokenOut), "DifferentTokenOut");
        uint256 amount = 3e18;
        mToken.mint(address(executor), amount);

        // when
        executor.redeemRequest(address(mToken), amount, address(differentTokenOut), address(redemptionVault));

        // then: vault received the tokenOut address, NOT the mToken address
        assertEq(
            redemptionVault.lastTokenOut(),
            address(differentTokenOut),
            "redemptionVault must receive tokenOut, not mToken"
        );
        assertTrue(
            redemptionVault.lastTokenOut() != address(mToken),
            "tokenOut and mToken must not be confused"
        );
    }

    // ============ 4. claimAssets Tests ============

    /// @notice Test 4.1 — happy path: balance > 0, transfers full amount to PLASMA_VAULT
    function test_claimAssets_happyPath_nonZeroBalance() public {
        // given
        uint256 balance = 1000e6;
        tokenIn.mint(address(executor), balance);

        uint256 plasmaVaultBalanceBefore = tokenIn.balanceOf(plasmaVault);

        // when
        uint256 claimedAmount = executor.claimAssets(address(tokenIn));

        // then: returned amount correct
        assertEq(claimedAmount, balance, "claimAssets should return the full balance");

        // then: executor balance is drained
        assertEq(tokenIn.balanceOf(address(executor)), 0, "executor should have 0 balance after claim");

        // then: PLASMA_VAULT received the tokens
        assertEq(
            tokenIn.balanceOf(plasmaVault),
            plasmaVaultBalanceBefore + balance,
            "PLASMA_VAULT should receive the full balance"
        );
    }

    /// @notice Test 4.2 — zero balance branch: no transfer, returns 0
    function test_claimAssets_zeroBalance() public {
        // given — executor holds no tokens (no mint)
        assertEq(tokenIn.balanceOf(address(executor)), 0, "executor should start with 0 balance");

        // when
        uint256 claimedAmount = executor.claimAssets(address(tokenIn));

        // then: returns 0
        assertEq(claimedAmount, 0, "claimAssets should return 0 when balance is 0");

        // then: no transfer happened (approve count stays 0, balance stays 0)
        assertEq(tokenIn.balanceOf(address(executor)), 0, "executor balance should remain 0");
        assertEq(tokenIn.balanceOf(plasmaVault), 0, "PLASMA_VAULT should not receive anything");
    }

    /// @notice Test 4.6 — zero balance: safeTransfer must NOT be called (kills guard-removal mutant)
    /// @dev Validates that the `if (amount > 0)` guard in claimAssets() is present and active.
    ///      Without the guard, safeTransfer(PLASMA_VAULT, 0) would be called even when balance == 0,
    ///      incrementing transferCallCount. With the guard, transfer is skipped entirely.
    function test_claimAssets_zeroBalance_noTransferCalled() public {
        // given — executor holds no tokens
        assertEq(tokenIn.balanceOf(address(executor)), 0, "precondition: executor has 0 balance");
        uint256 transferCountBefore = tokenIn.transferCallCount();

        // when
        uint256 claimedAmount = executor.claimAssets(address(tokenIn));

        // then: returns 0
        assertEq(claimedAmount, 0, "claimAssets should return 0 when balance is 0");

        // then: transfer was NOT called — this kills the guard-removal mutant
        assertEq(
            tokenIn.transferCallCount(),
            transferCountBefore,
            "transfer must NOT be called when balance is 0 (if (amount > 0) guard must exist)"
        );
    }

    /// @notice Test 4.3 — reverts when caller is not PLASMA_VAULT
    function test_claimAssets_revertsWhenNotPlasmaVault() public {
        // when/then
        vm.expectRevert(abi.encodeWithSelector(MidasExecutor.MidasExecutorUnauthorizedCaller.selector));
        vm.prank(randomCaller);
        executor.claimAssets(address(tokenIn));
    }

    /// @notice Test 4.4 — full balance is transferred, including large uint128 values
    function test_claimAssets_transfersEntireBalance() public {
        // given
        uint256 largeBalance = type(uint128).max;
        tokenIn.mint(address(executor), largeBalance);

        // when
        uint256 claimedAmount = executor.claimAssets(address(tokenIn));

        // then
        assertEq(claimedAmount, largeBalance, "claimAssets should return type(uint128).max");
        assertEq(tokenIn.balanceOf(address(executor)), 0, "executor should be fully drained");
        assertEq(tokenIn.balanceOf(plasmaVault), largeBalance, "PLASMA_VAULT should receive type(uint128).max");
    }

    /// @notice Test 4.5 — claiming one token doesn't affect another token's balance
    function test_claimAssets_multipleTokens() public {
        // given
        uint256 balanceA = 100e6;
        uint256 balanceB = 200e18;
        tokenIn.mint(address(executor), balanceA);
        tokenB.mint(address(executor), balanceB);

        // when — only claim tokenIn (tokenA)
        uint256 claimedA = executor.claimAssets(address(tokenIn));

        // then: tokenA claimed correctly
        assertEq(claimedA, balanceA, "claimed amount for tokenA should be 100e6");
        assertEq(tokenIn.balanceOf(address(executor)), 0, "executor tokenA balance should be 0");

        // then: tokenB untouched
        assertEq(tokenB.balanceOf(address(executor)), balanceB, "executor tokenB balance should be unchanged");
    }

    // ============ 5. Fuzz Tests ============

    /// @notice Test 5.1 — WAD conversion correctness for all decimals/amount combinations
    function testFuzz_depositRequest_wadConversion(uint128 amount, uint8 decimals) public {
        // given
        vm.assume(decimals <= 36); // realistic ERC20 range
        MockERC20ForMidasExecutor fuzzToken = new MockERC20ForMidasExecutor("FT", "FT", decimals);
        fuzzToken.mint(address(executor), uint256(amount));

        uint256 expectedWad = IporMath.convertToWad(uint256(amount), decimals);

        // when
        executor.depositRequest(address(fuzzToken), uint256(amount), address(depositVault));

        // then: the amount forwarded to the vault matches the IporMath WAD conversion formula
        assertEq(
            depositVault.lastAmountToken(),
            expectedWad,
            "WAD conversion must match IporMath.convertToWad for all decimal/amount combinations"
        );
    }

    /// @notice Test 5.2 — requestId passthrough for any requestId value
    function testFuzz_depositRequest_anyRequestId(uint256 requestId) public {
        // given
        depositVault.setNextRequestId(requestId);
        tokenIn.mint(address(executor), 1e6);

        // when
        uint256 returnedId = executor.depositRequest(address(tokenIn), 1e6, address(depositVault));

        // then: return value always matches the mock's configured return
        assertEq(returnedId, requestId, "depositRequest must pass through any requestId exactly");
    }

    /// @notice Test 5.3 — claimAssets works for any balance (zero and non-zero branch coverage)
    function testFuzz_claimAssets_anyBalance(uint256 balance) public {
        // given
        tokenIn.mint(address(executor), balance);
        uint256 plasmaVaultBefore = tokenIn.balanceOf(plasmaVault);

        // when
        uint256 claimedAmount = executor.claimAssets(address(tokenIn));

        // then: return value matches the balance
        assertEq(claimedAmount, balance, "claimAssets must return the exact balance");

        if (balance > 0) {
            // then: tokens transferred to PLASMA_VAULT
            assertEq(tokenIn.balanceOf(address(executor)), 0, "executor must be drained for non-zero balance");
            assertEq(
                tokenIn.balanceOf(plasmaVault),
                plasmaVaultBefore + balance,
                "PLASMA_VAULT must receive all tokens for non-zero balance"
            );
        } else {
            // then: no transfer for zero balance
            assertEq(tokenIn.balanceOf(address(executor)), 0, "executor stays at 0 for zero balance");
            assertEq(tokenIn.balanceOf(plasmaVault), plasmaVaultBefore, "PLASMA_VAULT balance unchanged for zero balance");
        }
    }

    /// @notice Test 5.4 — redeemRequest passes any amount through to vault correctly
    function testFuzz_redeemRequest_anyAmount(uint256 amount) public {
        // given
        mToken.mint(address(executor), amount);

        // when
        executor.redeemRequest(address(mToken), amount, address(tokenOut), address(redemptionVault));

        // then: vault receives the exact amount (no WAD conversion for redeemRequest)
        assertEq(
            redemptionVault.lastAmountMToken(),
            amount,
            "redemptionVault must receive the exact amount for all values"
        );
        assertEq(
            redemptionVault.lastTokenOut(),
            address(tokenOut),
            "redemptionVault must receive the correct tokenOut for all amounts"
        );
    }

    // ============ 6. Overflow / Large Value Tests ============

    /// @notice Test 6.1 — large amount with 6 decimals: type(uint128).max * 1e12 fits in uint256
    function test_depositRequest_largeAmount_6decimals() public {
        // given
        MockERC20ForMidasExecutor token6 = new MockERC20ForMidasExecutor("T6", "T6", 6);
        uint256 amount = type(uint128).max; // ~3.4e38
        token6.mint(address(executor), amount);

        // when — should NOT revert: type(uint128).max * 1e12 ~= 3.4e50, well under uint256 max
        executor.depositRequest(address(token6), amount, address(depositVault));

        // then: correct WAD conversion
        uint256 expectedWad = IporMath.convertToWad(amount, 6);
        assertEq(depositVault.lastAmountToken(), expectedWad, "large 6-decimal amount should convert to WAD correctly");
    }

    /// @notice Test 6.2 — type(uint256).max with 6 decimals overflows during WAD multiplication
    function test_depositRequest_veryLargeAmount_6decimals() public {
        // given — type(uint256).max * 1e12 overflows uint256
        MockERC20ForMidasExecutor token6 = new MockERC20ForMidasExecutor("T6Large", "T6L", 6);
        uint256 overflowAmount = type(uint256).max;
        token6.mint(address(executor), overflowAmount);

        // when/then — Solidity 0.8 arithmetic overflow panic (0x11)
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        executor.depositRequest(address(token6), overflowAmount, address(depositVault));
    }

    /// @notice Test 6.3 — type(uint256).max with 18 decimals: no scaling, should NOT overflow
    function test_depositRequest_largeAmount_18decimals_noScaling() public {
        // given
        MockERC20ForMidasExecutor token18 = new MockERC20ForMidasExecutor("T18max", "T18M", 18);
        uint256 amount = type(uint256).max;
        token18.mint(address(executor), amount);

        // when — no multiplication for 18 decimals, passes through directly
        executor.depositRequest(address(token18), amount, address(depositVault));

        // then: no scaling applied
        assertEq(depositVault.lastAmountToken(), type(uint256).max, "18-decimal max amount should pass through as-is");
    }

    // ============ 7. Boundary Value Analysis (Decimal Conversions) ============

    /// @notice Test 7.1 — decimals = 17: minimal scale-up (multiply by 10)
    function test_depositRequest_decimals17_scaleUp() public {
        // given
        MockERC20ForMidasExecutor token17 = new MockERC20ForMidasExecutor("T17", "T17", 17);
        uint256 amount = 1e17;
        token17.mint(address(executor), amount);

        // when
        executor.depositRequest(address(token17), amount, address(depositVault));

        // then: 1e17 * 10^(18-17) = 1e17 * 10 = 1e18
        assertEq(depositVault.lastAmountToken(), 1e18, "17-decimal token: 1e17 should scale to 1e18");
    }

    /// @notice Test 7.2 — decimals = 19: minimal scale-down (divide by 10)
    function test_depositRequest_decimals19_scaleDown() public {
        // given
        MockERC20ForMidasExecutor token19 = new MockERC20ForMidasExecutor("T19", "T19", 19);
        uint256 amount = 1e19;
        token19.mint(address(executor), amount);

        // when
        executor.depositRequest(address(token19), amount, address(depositVault));

        // then: 1e19 / 10^(19-18) = 1e19 / 10 = 1e18
        assertEq(depositVault.lastAmountToken(), 1e18, "19-decimal token: 1e19 should scale down to 1e18");
    }

    /// @notice Test 7.3 — decimals = 0: maximum scale-up (multiply by 1e18)
    function test_depositRequest_decimals0() public {
        // given
        MockERC20ForMidasExecutor token0 = new MockERC20ForMidasExecutor("T0", "T0", 0);
        uint256 amount = 1; // 1 unit with 0 decimals
        token0.mint(address(executor), amount);

        // when
        executor.depositRequest(address(token0), amount, address(depositVault));

        // then: 1 * 10^(18-0) = 1e18
        assertEq(depositVault.lastAmountToken(), 1e18, "0-decimal token: 1 unit should scale to 1e18 WAD");
    }
}
