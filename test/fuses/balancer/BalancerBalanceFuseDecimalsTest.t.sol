// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BalancerSubstrateLib, BalancerSubstrate, BalancerSubstrateType} from "contracts/fuses/balancer/BalancerSubstrateLib.sol";

import {BalancerBalanceFuseHarness} from "./mocks/BalancerBalanceFuseHarness.sol";
import {MockBalancerPoolForBalance} from "./mocks/MockBalancerPoolForBalance.sol";
import {MockERC20DecimalsForBalance} from "./mocks/MockERC20DecimalsForBalance.sol";
import {MockPriceOracleMiddlewareForBalance} from "./mocks/MockPriceOracleMiddlewareForBalance.sol";

/// @title BalancerBalanceFuseDecimalsTest
/// @notice Local (non-fork) regression test for the decimals-normalization half of the IL-7953 fix
///         to `BalancerBalanceFuse._convertToUsd`.
///
///         IL-7953's cycle-1 fork tests (test/fuses/balancer/BalancerTest.t.sol) prove the
///         "raw balances instead of live-scaled balances" half of the fix, but both pool tokens at
///         the pinned fork block (fwstETH, fwETH) happen to have 18 decimals, so they cannot
///         distinguish the fixed body
///         `IporMath.convertToWad(amount_ * price, IERC20Metadata(token_).decimals() + priceDecimals)`
///         from the pre-fix body `(amount_ * price) / 10 ** priceDecimals`, which implicitly assumed
///         18-decimal input amounts. This file closes that gap with a pool containing one 6-decimal
///         token (e.g. a USDC-like wrapper such as waUSDC), where the two bodies diverge sharply.
///
///         Non-fork by design: no on-chain pool at the pinned block (23137973) pairs a WITH_RATE
///         6-decimal token with routes wired into the existing fork setup (see cycle-1-verification.md
///         non-blocking observation #1). Per IL-7953's plan (02-plan.md, "Mock fallback"), a local
///         `MockBalancerPool` is used instead: BalancerBalanceFuseHarness inherits
///         BalancerBalanceFuse directly (mirrors test/unitTest/fuses/midas's
///         MidasBalanceFuseHarness convention) so `balanceOf()` runs the fuse's real bytecode against
///         a mock pool, mock price oracle and mock ERC20 tokens — no PlasmaVault/FusionFactory/fork
///         wiring needed, since BalancerBalanceFuse only ever reads `PlasmaVaultConfigLib` and
///         `PlasmaVaultLib` storage plus the external pool contract.
contract BalancerBalanceFuseDecimalsTest is Test {
    uint256 constant MARKET_ID = 777;
    uint256 constant WAD = 1e18;

    BalancerBalanceFuseHarness harness;
    MockBalancerPoolForBalance pool;
    MockPriceOracleMiddlewareForBalance oracle;

    MockERC20DecimalsForBalance token18; // 18-decimal pool token (e.g. WETH-like)
    MockERC20DecimalsForBalance token6; // 6-decimal pool token (e.g. USDC-like, such as waUSDC)

    function setUp() public {
        harness = new BalancerBalanceFuseHarness(MARKET_ID);
        pool = new MockBalancerPoolForBalance();
        oracle = new MockPriceOracleMiddlewareForBalance();

        token18 = new MockERC20DecimalsForBalance(18);
        token6 = new MockERC20DecimalsForBalance(6);

        vm.label(address(harness), "BalancerBalanceFuseHarness");
        vm.label(address(pool), "MockBalancerPool");
        vm.label(address(oracle), "MockPriceOracle");
        vm.label(address(token18), "Token18Decimals");
        vm.label(address(token6), "Token6Decimals");
    }

    function _poolSubstrate(address pool_) internal pure returns (bytes32) {
        return
            BalancerSubstrateLib.substrateToBytes32(
                BalancerSubstrate({substrateType: BalancerSubstrateType.POOL, substrateAddress: pool_})
            );
    }

    /// @notice Configures a pool with a 6-decimal WITH_RATE-shaped token (native raw balance in
    ///         6 decimals) alongside a plain 18-decimal token, both priced at exactly $1, and the
    ///         vault holding 100% of the BPT supply so `computeProportionalAmountsOut` returns the
    ///         raw balances unchanged (bptIn == totalSupply).
    ///
    ///         `lastBalancesLiveScaled18` is deliberately set to a DIFFERENT figure than
    ///         `balancesRaw` so this test also fails if a future change accidentally reads the
    ///         live-scaled array again instead of the raw one (the other half of IL-7953's fix).
    function _configurePoolWithSixDecimalToken() internal {
        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(token18));
        tokens[1] = IERC20(address(token6));
        pool.setTokens(tokens);
        pool.setTokenInfoLength(2);

        uint256[] memory balancesRaw = new uint256[](2);
        balancesRaw[0] = 1_000 ether; // 1000 units, 18 decimals
        balancesRaw[1] = 1_000 * 1e6; // 1000 units, 6 decimals (e.g. waUSDC-like)
        pool.setBalancesRaw(balancesRaw);

        // Deliberately different from balancesRaw (see NatSpec above).
        uint256[] memory liveScaled18 = new uint256[](2);
        liveScaled18[0] = 1_234 ether;
        liveScaled18[1] = 5_678 ether;
        pool.setLastBalancesLiveScaled18(liveScaled18);

        pool.setTotalSupply(2_000 ether);
        pool.setBptBalance(address(harness), 2_000 ether); // vault owns 100% of the pool

        oracle.setAssetPrice(address(token18), 1e8, 8); // $1.00, 8-decimal price feed
        oracle.setAssetPrice(address(token6), 1e8, 8); // $1.00, 8-decimal price feed

        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = _poolSubstrate(address(pool));
        harness.setMarketSubstrates(MARKET_ID, substrates);
        harness.setPriceOracle(address(oracle));
    }

    /// @notice With the fix, both legs are valued at exactly $1000 each (1000 raw units at $1,
    ///         normalized by each token's own decimals), for a total of exactly $2000 WAD.
    ///
    ///         Pre-fix (`(amount_ * price) / 10 ** priceDecimals`, no token-decimals normalization),
    ///         the 18-decimal leg accidentally still computes correctly (1000e18 happens to already
    ///         be in WAD units), but the 6-decimal leg is undervalued by exactly 1e12x:
    ///         `1000e6 * 1e8 / 1e8 = 1000e6` is treated as if it were WAD (i.e. $0.000000000001
    ///         instead of $1000). The pre-fix total is therefore ~1000e18 + 1e6 instead of 2000e18 —
    ///         off by roughly half, not a rounding-sized difference — so this test fails hard, not
    ///         marginally, if the decimals-normalization half of the fix is reverted.
    function testShouldNormalizeSixDecimalTokenBalanceCorrectly() public {
        _configurePoolWithSixDecimalToken();

        uint256 expectedUsd18 = 1_000 * WAD; // 18-decimal leg: 1000 * $1
        uint256 expectedUsd6 = 1_000 * WAD; // 6-decimal leg: 1000 * $1, correctly normalized

        uint256 balance = harness.balanceOf();

        assertEq(balance, expectedUsd18 + expectedUsd6, "BalancerBalanceFuse must value the 6-decimal token at its true USD value, not undervalue it by 1e12x");
        assertEq(balance, 2_000 * WAD, "sanity: total must equal exactly $2000 WAD");
    }

    /// @notice Isolates the 6-decimal leg alone against a $1 price so the expected/actual comparison
    ///         has no 18-decimal leg to "hide" behind — the pre-fix body would return `amount_`
    ///         itself (1000e6) instead of `1000e18`, a difference of 1e12x, impossible to pass by
    ///         accident.
    function testShouldNotUndervalueSixDecimalTokenByDecimalsFactor() public {
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(token6));
        pool.setTokens(tokens);
        pool.setTokenInfoLength(1);

        uint256[] memory balancesRaw = new uint256[](1);
        balancesRaw[0] = 1_000 * 1e6; // 1000 units, 6 decimals
        pool.setBalancesRaw(balancesRaw);

        uint256[] memory liveScaled18 = new uint256[](1);
        liveScaled18[0] = 4_242 ether;
        pool.setLastBalancesLiveScaled18(liveScaled18);

        pool.setTotalSupply(1_000 ether);
        pool.setBptBalance(address(harness), 1_000 ether);

        oracle.setAssetPrice(address(token6), 1e8, 8); // $1.00

        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = _poolSubstrate(address(pool));
        harness.setMarketSubstrates(MARKET_ID, substrates);
        harness.setPriceOracle(address(oracle));

        uint256 balance = harness.balanceOf();

        assertEq(balance, 1_000 * WAD, "1000 units of a 6-decimal $1 token must be worth exactly $1000 WAD");
        assertGt(balance, 1_000 * 1e6, "sanity: correct value must be far above the undernormalized (pre-fix) magnitude");
    }
}
