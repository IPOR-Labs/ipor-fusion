// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PlasmaVault, PlasmaVaultInitData, FeeConfig} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultCloneLib} from "../test_helpers/PlasmaVaultCloneLib.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IPlasmaVault, FuseAction} from "../../contracts/interfaces/IPlasmaVault.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {RewardsClaimManager} from "../../contracts/managers/rewards/RewardsClaimManager.sol";
import {FeeManager} from "../../contracts/managers/fee/FeeManager.sol";
import {FeeAccount} from "../../contracts/managers/fee/FeeAccount.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";

import {
    StargateCrosschainSupplyFuse,
    StargateCrosschainSupplyFuseEnterData
} from "../../contracts/fuses/crosschain/stargate/StargateCrosschainSupplyFuse.sol";
import {
    CrosschainClaimFuse,
    CrosschainClaimFuseEnterData
} from "../../contracts/fuses/crosschain/CrosschainClaimFuse.sol";
import {CrosschainBalanceFuse} from "../../contracts/fuses/crosschain/CrosschainBalanceFuse.sol";
import {CrosschainSubstrateLib} from "../../contracts/fuses/crosschain/lib/CrosschainSubstrateLib.sol";
import {CrosschainNavValidationPreHook} from "../../contracts/handlers/pre_hooks/pre_hooks/CrosschainNavValidationPreHook.sol";
import {StargateCrosschainExecutor} from "../../contracts/crosschain/stargate/StargateCrosschainExecutor.sol";
import {BalanceObservation} from "../../contracts/crosschain/interfaces/ICrosschainExecutor.sol";

import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {TestAddresses} from "../test_helpers/TestAddresses.sol";
import {IporFusionAccessManagerHelper} from "../test_helpers/IporFusionAccessManagerHelper.sol";
import {MutableValuePriceFeed} from "../managers/MutableValuePriceFeed.sol";

/// @notice One operator contract that holds ALPHA_ROLE on the vault and is the executor's BALANCE_APPROVER.
///         `run` is ONE real transaction: execute batch 1, reject a pending proposal, execute batch 2.
contract AlphaApproverOperator {
    uint256 public cacheAfterFirstBatch;
    uint256 public liveAfterFirstBatch;
    uint256 public totalAssetsAfterFirstBatch;

    function run(
        PlasmaVault vault_,
        StargateCrosschainExecutor executor_,
        uint256 marketId_,
        FuseAction[] memory first_,
        uint256 proposalId_,
        FuseAction[] memory second_
    ) external {
        vault_.execute(first_);
        cacheAfterFirstBatch = vault_.totalAssetsInMarket(marketId_);
        liveAfterFirstBatch = executor_.getBalance();
        totalAssetsAfterFirstBatch = vault_.totalAssets();

        executor_.rejectAndBlockProposal(proposalId_);

        vault_.execute(second_);
    }
}

/// @title CrosschainRecoveryAccumulatorRealVaultTest
/// @notice IL-9114 (C-006): the recovery accumulator must not survive a live refresh that persists the SAME cache
///         number. Batch 1 claims exactly the un-refreshed yield (cache 100 before and after), the chain is then
///         blocked, and batch 2 of the same transaction falls back to the cache. The fallback must subtract only
///         claim 2, not claim 1 again. Real PlasmaVault clone + real StargateCrosschainExecutor.
/// forge-config: default.isolate = true
contract CrosschainRecoveryAccumulatorRealVaultTest is CrosschainTestBase {
    using IporFusionAccessManagerHelper for IporFusionAccessManager;

    uint256 internal constant MARKET = IporFusionMarkets.CROSSCHAIN;
    uint256 internal constant USER_DEPOSIT = 1_000e6;
    uint256 internal constant BRIDGED = 100e6;
    uint256 internal constant RECALLED = 40e6;
    uint256 internal constant SETTLED_AFTER_RECALL = 60e6;
    /// @dev Honest +10% yield attestation on the remaining settled bucket (60 -> 66), not yet in the vault cache.
    uint256 internal constant SETTLED_WITH_YIELD = 66e6;
    /// @dev Batch 1 claims exactly the un-refreshed yield, so the live post-claim NAV equals the old cache (100).
    uint256 internal constant CLAIM_1 = 6e6;
    uint256 internal constant CLAIM_2 = 5e6;
    uint256 internal constant ATTACKER_DEPOSIT = 1_000e6;

    address internal constant ATOMIST = TestAddresses.ATOMIST;
    address internal constant ALPHA = TestAddresses.ALPHA;
    address internal constant FUSE_MANAGER = TestAddresses.FUSE_MANAGER;
    address internal constant USER = TestAddresses.USER;
    address internal constant ATTACKER = address(0xA77AC4);

    PlasmaVault internal vault;
    IporFusionAccessManager internal accessManager;
    AlphaApproverOperator internal operator;

    StargateCrosschainSupplyFuse internal supplyFuse;
    CrosschainClaimFuse internal claimFuse;
    CrosschainBalanceFuse internal balanceFuse;
    CrosschainNavValidationPreHook internal preHook;

    function setUp() public {
        _baseSetUp();
        operator = new AlphaApproverOperator();
        _deployVault();

        manager = address(vault);
        approver = address(operator); // the operator contract is also the BALANCE_APPROVER
        executor = _deployExecutor(address(factory), _params());
        vm.deal(address(executor), 100 ether);

        _configureMarkets();
        _deposit(USER, USER_DEPOSIT);

        // Bridge 100 and settle it; cache = 100, vault idle = 900.
        _bridgeAndSettle();

        // Recall 40 to the executor idle ledger: idle 40, settled 60, live NAV 100, cache refreshed to 100.
        (bytes32 requestId, , ) = _requestAssets(RECALLED, 0);
        _deliverReturnStarted(requestId, RGUID, RECALLED, RECALLED, 2);
        usdc.mint(address(executor), RECALLED);
        _deliverReturnCompose(requestId, RGUID, RECALLED);
        vm.prank(ATOMIST);
        vault.updateMarketsBalances(_markets(MARKET));

        // Ordinary yield attestation 60 -> 66 (inside bigChange and band); no vault refresh follows.
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL + 1);
        _attest(SETTLED_WITH_YIELD, 2);
    }

    function testShouldNotSubtractTheFirstClaimAgainAfterASameValueRefresh() public {
        // Preconditions: the cache lags the live executor NAV by the un-refreshed yield.
        assertEq(executor.idleLedger(), RECALLED, "executor idle 40");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), SETTLED_WITH_YIELD, "settled 66");
        assertEq(executor.getBalance(), RECALLED + SETTLED_WITH_YIELD, "live NAV 106");
        assertEq(vault.totalAssetsInMarket(MARKET), BRIDGED, "cache 100");
        assertEq(vault.totalAssets(), USER_DEPOSIT, "totalAssets 1000 (yield not refreshed yet)");

        // A pending proposal exists that the approver may reject (an ordinary attestation round).
        uint256 proposalId = _propose(SETTLED_WITH_YIELD, 2);

        // ONE transaction: batch 1 claim 6 (live refresh writes 100 again), reject (chain blocked), batch 2 claim 5.
        operator.run(vault, executor, MARKET, _claimAction(CLAIM_1), proposalId, _claimAction(CLAIM_2));

        // Batch 1 refreshed live NAV and persisted the SAME numeric cache, which already excludes claim 1.
        assertEq(operator.liveAfterFirstBatch(), BRIDGED, "batch1: live post-claim NAV = 100");
        assertEq(operator.cacheAfterFirstBatch(), BRIDGED, "batch1: persisted cache = 100 (same number)");
        assertEq(operator.totalAssetsAfterFirstBatch(), USER_DEPOSIT + CLAIM_1, "batch1: totalAssets 1006, correct");

        // Real state after the transaction: nothing left the vault system.
        uint256 trueRemaining = executor.idleLedger() + executor.settledRemoteBalance(REMOTE_CHAIN);
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "chain blocked by the reject");
        assertEq(trueRemaining, 95e6, "executor really holds idle 29 + settled 66");
        assertEq(usdc.balanceOf(address(vault)), 900e6 + CLAIM_1 + CLAIM_2, "vault idle 911");

        // Fixed: batch 2 subtracts only claim 2 from the cache (100 - 5 = 95), the true remaining value.
        uint256 cache = vault.totalAssetsInMarket(MARKET);
        assertEq(cache, BRIDGED - CLAIM_2, "cache persisted at 95");
        assertEq(cache, trueRemaining, "cache equals the executor's real remaining value");
        assertEq(vault.totalAssets(), USER_DEPOSIT + CLAIM_1, "totalAssets stays 1006 after batch 2");
        assertEq(vault.totalAssets(), operator.totalAssetsAfterFirstBatch(), "batch 2 did not change totalAssets");
        assertEq(
            vault.totalAssets(),
            usdc.balanceOf(address(vault)) + trueRemaining,
            "NAV equals vault idle + executor value (1006)"
        );

        // The timelocked rescue + a fresh attestation restore executor health WITHOUT a vault refresh.
        uint64 obs = _markFsObs();
        vm.prank(admin);
        uint256 settleId = executor.scheduleForceSetSettledBalance(REMOTE_CHAIN, SETTLED_WITH_YIELD, 2, obs, false);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeForceSetSettledBalance(settleId, REMOTE_CHAIN, SETTLED_WITH_YIELD, 2, obs, false);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL + 1);
        _attest(SETTLED_WITH_YIELD, 2);
        assertEq(executor.getBalance(), 95e6, "executor healthy again");
        assertEq(vault.totalAssetsInMarket(MARKET), 95e6, "cache already correct, no understatement");

        // The depositor buys at the correct price, so the round trip extracts nothing.
        uint256 shares = _deposit(ATTACKER, ATTACKER_DEPOSIT);
        vm.prank(ATOMIST);
        vault.updateMarketsBalances(_markets(MARKET));
        assertEq(vault.totalAssetsInMarket(MARKET), 95e6, "refresh keeps the true value");

        vm.prank(ATTACKER);
        uint256 received = vault.redeem(shares, ATTACKER, ATTACKER);
        assertLe(received, ATTACKER_DEPOSIT, "depositor extracts nothing from existing holders");
    }

    // =====================================================================
    // Helpers (fixture copied from CrosschainBlockedChainUncheckedBalanceTest)
    // =====================================================================

    function _propose(uint256 settledLD_, uint64 stateVersion_) private returns (uint256) {
        BalanceObservation memory o = BalanceObservation({
            chainId: REMOTE_CHAIN,
            settledBalance: settledLD_,
            stateVersion: stateVersion_,
            remoteBlock: 1,
            remoteTimestamp: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 30 minutes),
            trackedPositionSetHash: bytes32(0)
        });
        vm.prank(proposer);
        executor.proposeBalance(o);
        return executor.proposalCount();
    }

    function _attest(uint256 settledLD_, uint64 stateVersion_) private {
        uint256 proposalId = _propose(settledLD_, stateVersion_);
        vm.prank(approver);
        executor.approveBalance(proposalId);
    }

    function _deployVault() private {
        accessManager = new IporFusionAccessManager(ATOMIST, 0);
        WithdrawManager withdrawManager = new WithdrawManager(address(accessManager));

        PriceOracleMiddleware oracleImpl = new PriceOracleMiddleware(address(0));
        PriceOracleMiddleware oracle = PriceOracleMiddleware(
            address(new ERC1967Proxy(address(oracleImpl), abi.encodeWithSignature("initialize(address)", ATOMIST)))
        );
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        address[] memory sources = new address[](1);
        sources[0] = address(new MutableValuePriceFeed(1e18));
        vm.prank(ATOMIST);
        oracle.setAssetsPricesSources(assets, sources);

        address plasmaVaultBase = vm.deployCode("PlasmaVaultBase.sol:PlasmaVaultBase");
        address feeFactory = vm.deployCode("FeeManagerFactory.sol:FeeManagerFactory");
        vault = PlasmaVaultCloneLib.clone(vm.deployCode("PlasmaVault.sol:PlasmaVault"));

        vm.startPrank(ATOMIST);
        vault.proxyInitialize(
            PlasmaVaultInitData({
                assetName: "C-006 PoC Vault",
                assetSymbol: "xc6",
                underlyingToken: address(usdc),
                priceOracleMiddleware: address(oracle),
                feeConfig: FeeConfig({
                    iporDaoManagementFee: 0,
                    iporDaoPerformanceFee: 0,
                    feeFactory: feeFactory,
                    iporDaoFeeRecipientAddress: TestAddresses.IPOR_DAO_FEE_RECIPIENT_ADDRESS
                }),
                accessManager: address(accessManager),
                plasmaVaultBase: plasmaVaultBase,
                withdrawManager: address(withdrawManager),
                plasmaVaultVotesPlugin: address(0)
            })
        );
        RewardsClaimManager rewardsClaimManager = new RewardsClaimManager(address(accessManager), address(vault));
        IporFusionAccessManagerHelper.RoleAddresses memory roles = IporFusionAccessManagerHelper
            .createDefaultRoleAddresses();
        roles.alphas = new address[](2);
        roles.alphas[0] = ALPHA;
        roles.alphas[1] = address(operator);
        accessManager.setupInitRoles(vault, roles, address(withdrawManager), address(rewardsClaimManager));
        vm.stopPrank();

        address feeAccount = PlasmaVaultGovernance(address(vault)).getPerformanceFeeData().feeAccount;
        FeeManager(FeeAccount(feeAccount).FEE_MANAGER()).initialize();
    }

    function _configureMarkets() private {
        supplyFuse = new StargateCrosschainSupplyFuse(MARKET);
        claimFuse = new CrosschainClaimFuse(MARKET);
        balanceFuse = new CrosschainBalanceFuse(MARKET);
        preHook = new CrosschainNavValidationPreHook(MARKET);

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuse);
        fuses[1] = address(claimFuse);

        PlasmaVaultGovernance governance = PlasmaVaultGovernance(address(vault));
        vm.startPrank(FUSE_MANAGER);
        governance.addFuses(fuses);
        governance.addBalanceFuse(MARKET, address(balanceFuse));
        bytes32[] memory subs = new bytes32[](1);
        subs[0] = CrosschainSubstrateLib.executorSubstrate(address(executor));
        governance.grantMarketSubstrates(MARKET, subs);
        vm.stopPrank();

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = IERC4626.deposit.selector;
        selectors[1] = IPlasmaVault.depositWithPermit.selector;
        selectors[2] = IERC4626.mint.selector;
        selectors[3] = IERC4626.withdraw.selector;
        selectors[4] = IERC4626.redeem.selector;
        selectors[5] = IPlasmaVault.redeemFromRequest.selector;
        selectors[6] = IPlasmaVault.execute.selector;
        address[] memory implementations = new address[](7);
        bytes32[][] memory substrates = new bytes32[][](7);
        for (uint256 i; i < 7; ++i) {
            implementations[i] = address(preHook);
            substrates[i] = new bytes32[](0);
        }
        vm.prank(ATOMIST);
        PlasmaVaultGovernance(address(vault)).setPreHookImplementations(selectors, implementations, substrates);
    }

    /// @dev Leaves settled = 100e6, frontier = 1, market cache = 100e6, vault idle = 900e6.
    function _bridgeAndSettle() private {
        _readyDispatcher();

        StargateCrosschainSupplyFuseEnterData memory data = StargateCrosschainSupplyFuseEnterData({
            executor: address(executor),
            asset: address(usdc),
            dstChainId: REMOTE_CHAIN,
            amount: BRIDGED,
            minAmountLD: 0,
            options: ""
        });
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(supplyFuse),
            data: abi.encodeCall(StargateCrosschainSupplyFuse.enter, (data))
        });

        vm.recordLogs();
        vm.prank(ALPHA);
        vault.execute(actions);
        (bytes32 transferId, bytes32 guid, ) = _captureAssetSent();

        _deliverTransferSettled(transferId, guid, BRIDGED, 1);
        _attest(BRIDGED, 1);
        vm.prank(ATOMIST);
        vault.updateMarketsBalances(_markets(MARKET));
    }

    function _deposit(address user_, uint256 amount_) private returns (uint256 shares) {
        usdc.mint(user_, amount_);
        vm.startPrank(user_);
        usdc.approve(address(vault), amount_);
        shares = vault.deposit(amount_, user_);
        vm.stopPrank();
    }

    function _claimAction(uint256 amount_) private view returns (FuseAction[] memory actions) {
        actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(claimFuse),
            data: abi.encodeCall(
                CrosschainClaimFuse.enter,
                (CrosschainClaimFuseEnterData({executor: address(executor), amount: amount_}))
            )
        });
    }

    function _markets(uint256 marketId_) private pure returns (uint256[] memory markets) {
        markets = new uint256[](1);
        markets[0] = marketId_;
    }
}
