// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {PlasmaVaultLib} from "../../contracts/libraries/PlasmaVaultLib.sol";
import {CrosschainRecoveryLib} from "../../contracts/fuses/crosschain/lib/CrosschainRecoveryLib.sol";

/// @notice Models `PlasmaVault.execute()` batches over two crosschain markets inside one transaction, using the
///         same correction `CrosschainBalanceFuse._cachedBalanceValueUsd` applies (cache minus recovered value).
contract TwoMarketRecoveryHarness {
    function seed(uint256 marketId_, uint256 value_) external {
        PlasmaVaultLib.updateTotalAssetsInMarket(marketId_, value_);
    }

    function cache(uint256 marketId_) external view returns (uint256) {
        return PlasmaVaultLib.getTotalAssetsInMarket(marketId_);
    }

    /// @dev One batch: recovery fuse (mark + add), then the balance refresh persisting the corrected cache.
    function batch(uint256 marketId_, address executor_, uint256 claim_) external {
        CrosschainRecoveryLib.markRecovery(marketId_, executor_);
        CrosschainRecoveryLib.addRecoveredUsd(marketId_, claim_);
        _refresh(marketId_);
    }

    /// @dev One batch with two recovery fuse calls on the same market, then a single refresh.
    function doubleBatch(uint256 marketId_, address executor_, uint256 first_, uint256 second_) external {
        CrosschainRecoveryLib.markRecovery(marketId_, executor_);
        CrosschainRecoveryLib.addRecoveredUsd(marketId_, first_);
        CrosschainRecoveryLib.markRecovery(marketId_, executor_);
        CrosschainRecoveryLib.addRecoveredUsd(marketId_, second_);
        _refresh(marketId_);
    }

    function _refresh(uint256 marketId_) private {
        uint256 cached = PlasmaVaultLib.getTotalAssetsInMarket(marketId_);
        if (CrosschainRecoveryLib.isRecoveredUsdApplicable(marketId_)) {
            uint256 recovered = CrosschainRecoveryLib.recoveredUsd(marketId_);
            cached = recovered >= cached ? 0 : cached - recovered;
        }
        PlasmaVaultLib.updateTotalAssetsInMarket(marketId_, cached);
    }
}

/// @title CrosschainRecoveryMarketScopingTest
/// @notice IL-8595: the recovered-value accumulator and cache snapshot are keyed by market.
contract CrosschainRecoveryMarketScopingTest is Test {
    uint256 internal constant MARKET_A = 100;
    uint256 internal constant MARKET_B = 101;
    address internal constant EXEC_A = address(0xAA);
    address internal constant EXEC_B = address(0xBB);

    TwoMarketRecoveryHarness internal h;

    function setUp() public {
        h = new TwoMarketRecoveryHarness();
        h.seed(MARKET_A, 1_000e6);
        h.seed(MARKET_B, 1_000e6); // equal numeric snapshot to market A
    }

    function testSecondMarketSubtractsOnlyItsOwnClaim() public {
        h.batch(MARKET_A, EXEC_A, 300e6);
        assertEq(h.cache(MARKET_A), 700e6, "A reduced by its own claim");

        h.batch(MARKET_B, EXEC_B, 200e6);
        assertEq(h.cache(MARKET_B), 800e6, "B must not also subtract A's claim");
        assertEq(h.cache(MARKET_A), 700e6, "A untouched by B's batch");
    }

    function testTwoRecoveriesInOneBatchAccumulate() public {
        h.doubleBatch(MARKET_A, EXEC_A, 300e6, 200e6);
        assertEq(h.cache(MARKET_A), 500e6, "both claims of one batch subtracted once each");
        assertEq(h.cache(MARKET_B), 1_000e6, "B never touched");
    }

    function testSameMarketBehaviourUnchanged() public {
        // Two batches on the same market: the second rebases against the persisted cache.
        h.batch(MARKET_A, EXEC_A, 300e6);
        h.batch(MARKET_A, EXEC_A, 200e6);
        assertEq(h.cache(MARKET_A), 500e6, "A: each claim subtracted exactly once across batches");
        assertEq(h.cache(MARKET_B), 1_000e6, "B never touched");
    }
}
