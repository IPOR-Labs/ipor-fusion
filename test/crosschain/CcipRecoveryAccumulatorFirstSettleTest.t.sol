// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, StdStorage, stdStorage} from "forge-std/Test.sol";

import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipExecutorTransferLib} from "../../contracts/crosschain/ccip/lib/CcipExecutorTransferLib.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {
    CrosschainClaimFuse,
    CrosschainClaimFuseEnterData
} from "../../contracts/fuses/crosschain/CrosschainClaimFuse.sol";
import {CrosschainBalanceFuse} from "../../contracts/fuses/crosschain/CrosschainBalanceFuse.sol";
import {CrosschainSubstrateLib} from "../../contracts/fuses/crosschain/lib/CrosschainSubstrateLib.sol";

import {PlasmaVaultExecuteHarness} from "./CrosschainRecoveryBatchScopingTest.t.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";
import {MockPriceOracleMiddleware} from "./mocks/MockPriceOracleMiddleware.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";

/// @notice One transaction: batch 1, a permissionless delivery of the held first `TRANSFER_SETTLED`, batch 2.
///         Nobody but ALPHA (here: this contract) is needed, because the OffRamp executes for any caller.
contract FirstSettleOperator {
    uint256 public cacheAfterFirstBatch;
    uint256 public totalAssetsAfterFirstBatch;

    function run(
        PlasmaVaultExecuteHarness vault_,
        MockCcipRouter router_,
        uint256 heldIndex_,
        CrosschainClaimFuseEnterData memory first_,
        CrosschainClaimFuseEnterData memory second_
    ) external {
        vault_.executeClaimBatch(first_);
        cacheAfterFirstBatch = vault_.cachedMarketBalance();
        totalAssetsAfterFirstBatch = vault_.totalAssets();

        router_.deliverHeld(heldIndex_);

        vault_.executeClaimBatch(second_);
    }
}

/// @title CcipRecoveryAccumulatorFirstSettleTest
/// @notice IL-9114 (C-006), CCIP variant. The first `TRANSFER_SETTLED` on a chain with no approved observation
///         moves outbound to settled without writing an observation, so `getBalance()` flips from healthy to
///         `ObservationStale` in the middle of a transaction. Batch 1 claims exactly the un-refreshed gain, so the
///         live refresh persists the SAME cache number; batch 2 then falls back to the cache and must subtract only
///         its own claim. Real CCIP executor + dispatcher + router, with the vault shape of `PlasmaVault.execute`.
contract CcipRecoveryAccumulatorFirstSettleTest is Test {
    using stdStorage for StdStorage;

    event CrosschainCachedBalanceServed(uint256 marketId, address executor, bytes4 reason);

    uint256 internal constant MARKET = IporFusionMarkets.CROSSCHAIN;
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 1;
    uint64 internal constant DISPATCHER_SELECTOR = 2;

    uint256 internal constant IDLE = 40e6;
    uint256 internal constant SENT = 60e6;
    uint256 internal constant CLAIM_1 = 6e6;
    uint256 internal constant CLAIM_2 = 5e6;
    uint256 internal constant VAULT_IDLE = 900e6;
    /// @dev Live NAV (idle 40 + outbound 60) minus the un-refreshed gain claimed by batch 1.
    uint256 internal constant CACHE = IDLE + SENT - CLAIM_1;

    MockERC20 internal token;
    MockCcipRouter internal router;
    PlasmaVaultExecuteHarness internal vault;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;
    FirstSettleOperator internal operator;
    uint256 internal heldSettleIndex;

    function setUp() public {
        token = new MockERC20("USD Coin", "USDC", 6);
        router = new MockCcipRouter();
        MockCcipRouteValidator routeValidator = new MockCcipRouteValidator();
        address factory = address(routeValidator);
        vault = new PlasmaVaultExecuteHarness(address(token), 6, MARKET);
        operator = new FirstSettleOperator();

        executor = new CcipCrosschainExecutor(
            address(router),
            factory,
            address(vault),
            address(token),
            keccak256("USDC"),
            6,
            CcipCrosschainExecutor.SafetyConfig({
                rescueAdmin: address(0xA11),
                rescueGuardian: address(0xB22),
                balanceProposer: address(0xA33),
                balanceApprover: address(0xB44),
                rescueDelay: 3 days,
                balanceStalenessMax: 7 days,
                bigChangeBps: 2_000,
                minUpdateInterval: 1 hours,
                transferStalenessMax: 1 days
            })
        );
        dispatcher = new CcipCrosschainDispatcher(
            address(router),
            factory,
            address(token),
            keccak256("USDC"),
            6,
            block.chainid,
            CcipRouteConfig({
                chainSelector: EXECUTOR_SELECTOR,
                peer: address(executor),
                feeToken: address(0),
                messageGasLimit: 2_000_000,
                tokenGasLimit: 2_000_000,
                maxFee: 0,
                enabled: true
            }),
            address(0xA11),
            address(0xB22),
            3 days
        );
        vm.prank(factory);
        dispatcher.configureVaults(new address[](0), true);
        CcipRouteConfig memory executorRoute = CcipRouteConfig({
            chainSelector: DISPATCHER_SELECTOR,
            peer: address(dispatcher),
            feeToken: address(0),
            messageGasLimit: 2_000_000,
            tokenGasLimit: 2_000_000,
            maxFee: 0,
            enabled: true
        });
        routeValidator.setRoute(REMOTE_CHAIN, executorRoute);
        routeValidator.registerExecutorRoute(address(executor), REMOTE_CHAIN, executorRoute);
        vm.prank(factory);
        executor.markDispatcherReady(REMOTE_CHAIN);
        router.setSelector(address(executor), EXECUTOR_SELECTOR);
        router.setSelector(address(dispatcher), DISPATCHER_SELECTOR);

        CrosschainClaimFuse claimFuse = new CrosschainClaimFuse(MARKET);
        CrosschainBalanceFuse balanceFuse = new CrosschainBalanceFuse(MARKET);
        vault.setFuses(address(claimFuse), address(balanceFuse));
        bytes32[] memory subs = new bytes32[](1);
        subs[0] = CrosschainSubstrateLib.executorSubstrate(address(executor));
        vault.grantSubstrates(subs);
        MockPriceOracleMiddleware oracle = new MockPriceOracleMiddleware();
        oracle.setPrice(address(token), 1e8, 8);
        vault.setPriceOracleMiddleware(address(oracle));

        // Executor idle ledger: 40 claimable (tokens + ledger entry; no observation exists for the chain).
        token.mint(address(executor), IDLE);
        stdstore.target(address(executor)).sig("idleLedger()").checked_write(IDLE);

        // First supply to the chain: 60 leaves the executor, the dispatcher receives it, and its
        // TRANSFER_SETTLED reply is held back (CCIP 2.0: executable later by anyone).
        router.setAutoDeliver(false);
        router.setHoldTokenMessages(true);
        token.mint(address(executor), SENT);
        vm.prank(address(vault));
        executor.sendAssetToDispatcher(REMOTE_CHAIN, SENT, 0, address(0), 2_000_000);
        router.deliverHeld(router.heldCount() - 1);
        heldSettleIndex = router.heldCount() - 1;
        router.setHoldTokenMessages(false);
        router.setAutoDeliver(true);

        // The vault: idle 900, cache lags live NAV (100) by the gain of 6 that batch 1 will claim.
        token.mint(address(vault), VAULT_IDLE);
        vault.seedMarketBalance(CACHE);
    }

    function testShouldNotSubtractTheFirstClaimAgainAfterFirstSettleFlipsNav() public {
        // Preconditions: healthy live NAV 100, no settled bucket, no approved observation yet.
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "no settled balance on the chain");
        assertEq(executor.outboundInFlight(REMOTE_CHAIN), SENT, "supply in flight");
        assertEq(executor.getBalance(), IDLE + SENT, "live NAV 100 (healthy)");
        assertEq(vault.cachedMarketBalance(), CACHE, "cache 94");
        assertEq(vault.totalAssets(), VAULT_IDLE + CACHE, "totalAssets 994 (gain not refreshed yet)");

        operator.run(
            vault,
            router,
            heldSettleIndex,
            CrosschainClaimFuseEnterData({executor: address(executor), amount: CLAIM_1}),
            CrosschainClaimFuseEnterData({executor: address(executor), amount: CLAIM_2})
        );

        // Batch 1: live refresh persisted the SAME number as the old cache (94), which already excludes claim 1.
        assertEq(operator.cacheAfterFirstBatch(), CACHE, "batch1: persisted cache = 94 (same number)");
        assertEq(operator.totalAssetsAfterFirstBatch(), VAULT_IDLE + CLAIM_1 + CACHE, "batch1: totalAssets 1000");

        // The first settle flipped live NAV to fail-closed: settled 60 with no approved observation.
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), SENT, "first TRANSFER_SETTLED credited 60");
        assertEq(executor.outboundInFlight(REMOTE_CHAIN), 0, "outbound moved to settled");
        vm.expectRevert(abi.encodeWithSelector(CcipExecutorTransferLib.ObservationStale.selector, REMOTE_CHAIN));
        executor.getBalance();

        // Real state: the executor holds idle 29 + settled 60 = 89, the vault holds 911.
        uint256 trueRemaining = executor.idleLedger() + executor.settledRemoteBalance(REMOTE_CHAIN);
        assertEq(trueRemaining, 89e6, "executor really holds idle 29 + settled 60");
        assertEq(token.balanceOf(address(vault)), VAULT_IDLE + CLAIM_1 + CLAIM_2, "vault idle 911");

        // Fixed: batch 2 subtracts only claim 2 from the cache (94 - 5 = 89) and NAV is conserved.
        assertEq(vault.cachedMarketBalance(), CACHE - CLAIM_2, "cache persisted at 89");
        assertEq(vault.cachedMarketBalance(), trueRemaining, "cache equals the executor's real remaining value");
        assertEq(vault.totalAssets(), VAULT_IDLE + CLAIM_1 + CACHE, "totalAssets stays 1000 after batch 2");
        assertEq(vault.totalAssets(), operator.totalAssetsAfterFirstBatch(), "batch 2 did not change totalAssets");
    }

    /// @dev The batch-2 fallback is the cached branch (`ObservationStale` served from the cache), so the numbers
    ///      above are produced by the path under test.
    function testShouldServeTheCachedBalanceForBatchTwoWithObservationStale() public {
        vm.expectEmit(false, false, false, true, address(vault));
        emit CrosschainCachedBalanceServed(
            MARKET,
            address(executor),
            CcipExecutorTransferLib.ObservationStale.selector
        );

        operator.run(
            vault,
            router,
            heldSettleIndex,
            CrosschainClaimFuseEnterData({executor: address(executor), amount: CLAIM_1}),
            CrosschainClaimFuseEnterData({executor: address(executor), amount: CLAIM_2})
        );

        assertEq(vault.cachedMarketBalance(), CACHE - CLAIM_2, "cache 89");
    }
}
