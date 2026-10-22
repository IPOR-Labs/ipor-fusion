// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PlasmaVault, PlasmaVaultInitData, FeeConfig} from "../../contracts/vaults/PlasmaVault.sol";
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
import {
    StargateCrosschainCommandFuse,
    StargateCrosschainCommandFuseEnterData,
    StargateCrosschainCommandType
} from "../../contracts/fuses/crosschain/stargate/StargateCrosschainCommandFuse.sol";
import {CrosschainBalanceFuse} from "../../contracts/fuses/crosschain/CrosschainBalanceFuse.sol";
import {CrosschainSubstrateLib} from "../../contracts/fuses/crosschain/lib/CrosschainSubstrateLib.sol";
import {
    CrosschainNavValidationPreHook
} from "../../contracts/handlers/pre_hooks/pre_hooks/CrosschainNavValidationPreHook.sol";
import {StargateCrosschainExecutor} from "../../contracts/crosschain/stargate/StargateCrosschainExecutor.sol";
import {BalanceObservation} from "../../contracts/crosschain/interfaces/ICrosschainExecutor.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {ResolveOutcome, BusinessAction} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {Command} from "../../contracts/crosschain/lib/CrosschainMessages.sol";

import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {TestAddresses} from "../test_helpers/TestAddresses.sol";
import {IporFusionAccessManagerHelper} from "../test_helpers/IporFusionAccessManagerHelper.sol";
import {MutableValuePriceFeed} from "../managers/MutableValuePriceFeed.sol";

/// @title CrosschainBlockedChainUncheckedBalanceTest
/// @notice IL-8611 follow-up (TP-M-33 review): in a MULTI-executor market the balance fuse may substitute the
///         booked `getBalanceUnchecked()` for a recovery-marked executor only when its `getBalance()` reverted
///         with a STALENESS selector. A blocked chain means the books are known-inconsistent until a rescue
///         completes, so the batch must keep reverting `ChainBlocked`.
///
///         The motivating case is the Stargate rescue `DROP_RETURN_METADATA_INCLUDED` (compose arrived,
///         `RETURN_STARTED` lost): the returned amount moves into `idleLedger` while `settledRemoteBalance` still
///         holds it, and only `chainBlocked` keeps NAV from counting it twice until the force-set. Real
///         PlasmaVault + real StargateCrosschainExecutor, same fixture shape as `CrosschainRealVaultRecoveryTest`
///         (the review PoC `ClusterDPoC` ported to regression tests).
/// forge-config: default.isolate = true
contract CrosschainBlockedChainUncheckedBalanceTest is CrosschainTestBase {
    using IporFusionAccessManagerHelper for IporFusionAccessManager;
    using stdStorage for StdStorage;

    uint256 internal constant MARKET = IporFusionMarkets.CROSSCHAIN;
    uint256 internal constant PERFORMANCE_FEE = 1_000; // 10%
    uint256 internal constant USER_DEPOSIT = 1_000e6;
    uint256 internal constant BRIDGED = 100e6;
    uint256 internal constant RECALLED = 40e6;
    uint256 internal constant OTHER_CHAIN = 10;
    uint32 internal constant OTHER_EID = 30111;
    /// @dev Value booked on the blocked second chain in the combined-case fixture.
    uint256 internal constant OTHER_CHAIN_VALUE = 5e6;

    address internal constant ATOMIST = TestAddresses.ATOMIST;
    address internal constant ALPHA = TestAddresses.ALPHA;
    address internal constant FUSE_MANAGER = TestAddresses.FUSE_MANAGER;
    address internal constant USER = TestAddresses.USER;
    address internal constant REMOTE_VAULT = address(0xBEEF01);

    PlasmaVault internal vault;
    IporFusionAccessManager internal accessManager;
    address internal feeAccount;

    StargateCrosschainSupplyFuse internal supplyFuse;
    CrosschainClaimFuse internal claimFuse;
    StargateCrosschainCommandFuse internal commandFuse;
    CrosschainBalanceFuse internal balanceFuse;
    CrosschainNavValidationPreHook internal preHook;

    function setUp() public {
        _baseSetUp();
        _deployVault();

        manager = address(vault);
        executor = _deployExecutor(address(factory), _params());
        vm.deal(address(executor), 100 ether);

        _configureMarkets();
        _deposit(USER, USER_DEPOSIT);
    }

    // =====================================================================
    // Reviewer PoC (TP-M-33): a blocked chain must not be served in a multi-executor market
    // =====================================================================

    /// @notice ALPHA claims the idle the rescue just released while the settled force-set has not run yet. Before the
    ///         follow-up the fuse substituted the unchecked (double counting) balance and persisted it as NAV.
    function testShouldRevertClaimInDropWindowWithSecondExecutorInMarket() public {
        _bridgeAndSettle();
        _grantSubstrates(true, false);
        _composeFirstRecallAndDrop();

        // The documented window: the returned amount is in idle AND still in settled; only the block protects NAV.
        assertEq(executor.idleLedger(), RECALLED, "idle credited by the drop");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), BRIDGED, "settled still counts the recalled amount");
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ChainBlocked.selector, REMOTE_CHAIN));
        executor.getBalance();

        uint256 navBefore = vault.totalAssets();
        uint256 supplyBefore = vault.totalSupply();
        assertEq(navBefore, USER_DEPOSIT, "NAV before the recovery batch");

        FuseAction[] memory actions = _claimAction(RECALLED);
        vm.prank(ALPHA);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ChainBlocked.selector, REMOTE_CHAIN));
        vault.execute(actions);

        assertEq(executor.idleLedger(), RECALLED, "claim rolled back");
        assertEq(vault.totalAssetsInMarket(MARKET), BRIDGED, "market cache untouched");
        assertEq(vault.totalAssets(), navBefore, "NAV unchanged");
        assertEq(vault.totalSupply(), supplyBefore, "no performance-fee shares minted");
        assertEq(vault.balanceOf(feeAccount), 0, "fee account received nothing");
    }

    /// @notice A REDEEM command (kept open on a blocked chain as a repair action) arms the marker for the executor;
    ///         the batch must revert as well instead of persisting idle + settled.
    function testShouldRevertRedeemCommandInDropWindowWithSecondExecutorInMarket() public {
        _bridgeAndSettle();
        _grantSubstrates(true, true);
        _composeFirstRecallAndDrop();

        uint256 supplyBefore = vault.totalSupply();

        StargateCrosschainCommandFuseEnterData memory data = StargateCrosschainCommandFuseEnterData({
            commandType: StargateCrosschainCommandType.SEND_COMMAND,
            executor: address(executor),
            chainId: REMOTE_CHAIN,
            eid: 0,
            enforcedOptions: "",
            plasmaVaults: new address[](0),
            requestId: 0,
            command: Command({
                commandId: bytes32(0),
                sequence: 0,
                commandConfigEpoch: 0,
                action: uint8(BusinessAction.REDEEM),
                minExecutionGas: 0,
                actionData: abi.encode(REMOTE_VAULT, uint256(1e6), uint256(0))
            })
        });
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(commandFuse),
            data: abi.encodeCall(StargateCrosschainCommandFuse.enter, (data))
        });
        vm.prank(ALPHA);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ChainBlocked.selector, REMOTE_CHAIN));
        vault.execute(actions);

        assertEq(vault.totalAssetsInMarket(MARKET), BRIDGED, "market cache untouched");
        assertEq(vault.totalAssets(), USER_DEPOSIT, "NAV unchanged");
        assertEq(vault.totalSupply(), supplyBefore, "no performance-fee shares minted");
    }

    /// @notice Control: the same sequence with ONE executor in the market uses the cache fallback (with the
    ///         recovered-USD correction) and stays NAV-neutral. The single-executor branch is unchanged.
    function testShouldKeepNavNeutralForClaimInDropWindowWithSingleExecutor() public {
        _bridgeAndSettle();
        _composeFirstRecallAndDrop();

        uint256 supplyBefore = vault.totalSupply();
        _claim(RECALLED);

        assertEq(vault.totalAssetsInMarket(MARKET), BRIDGED - RECALLED, "cache reduced by the claimed value");
        assertEq(vault.totalAssets(), USER_DEPOSIT, "NAV unchanged");
        assertEq(vault.totalSupply(), supplyBefore, "no fee shares");
    }

    /// @notice Once the rescue completes (force-set to the true remote value plus a fresh attestation) the same claim
    ///         goes through in the multi-executor market and prices the market at the true remote value.
    function testShouldAllowClaimWithSecondExecutorOnceTheRescueCompletes() public {
        _bridgeAndSettle();
        _grantSubstrates(true, false);
        (, uint256 settleId, uint64 observedVersion) = _composeFirstRecallAndDrop();

        vm.prank(admin);
        executor.executeForceSetSettledBalance(
            settleId, REMOTE_CHAIN, BRIDGED - RECALLED, observedVersion, fsObs, false
        );
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL + 1);
        _attest(BRIDGED - RECALLED, observedVersion);
        assertEq(executor.getBalance(), BRIDGED, "live NAV: idle 40 + settled 60");

        _claim(RECALLED);

        assertEq(vault.totalAssetsInMarket(MARKET), BRIDGED - RECALLED, "true remote value");
        assertEq(vault.totalAssets(), USER_DEPOSIT, "NAV unchanged");
    }

    // =====================================================================
    // Staleness is still substituted in a multi-executor market (IL-8611 stays fixed)
    // =====================================================================

    /// @notice A recovery batch whose marked executor is only STALE still works with a sibling in the market: the
    ///         marked executor is valued by its booked balance (idle 40 claimed, settled 60 left).
    function testShouldServeUncheckedBalanceForOnlyStaleMarkedExecutorWithSecondExecutor() public {
        _bridgeSettleRecallAndGoStale();
        _grantSubstrates(true, false);
        uint256 supplyBefore = vault.totalSupply();

        vm.expectEmit(address(vault));
        emit CrosschainBalanceFuse.CrosschainUncheckedBalanceServed(
            MARKET, address(executor), CrosschainErrors.NavSettledStale.selector
        );
        _claim(RECALLED);

        assertEq(executor.idleLedger(), 0, "idle claimed");
        assertEq(vault.totalAssetsInMarket(MARKET), BRIDGED - RECALLED, "booked balance of the marked executor");
        assertEq(vault.totalAssets(), USER_DEPOSIT, "NAV unchanged");
        assertEq(vault.totalSupply(), supplyBefore, "no fee shares");
    }

    // =====================================================================
    // getBalanceUnchecked: staleness gates skipped, blocked chain refused
    // =====================================================================

    function testShouldReturnBookedBalanceFromUncheckedGetterWhenOnlyStale() public {
        _bridgeSettleRecallAndGoStale();
        assertEq(executor.getBalanceUnchecked(), BRIDGED, "idle 40 + settled 60, no staleness gate");
    }

    function testShouldRevertUncheckedGetterChainBlockedWhileAChainIsBlocked() public {
        _bridgeAndSettle();
        _composeFirstRecallAndDrop();
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "chain blocked by the drop");

        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ChainBlocked.selector, REMOTE_CHAIN));
        executor.getBalanceUnchecked();
    }

    /// @notice `getBalance()` surfaces a STALENESS selector for the first chain while a second chain is blocked and
    ///         tracks value. The fuse's caught reason is then a staleness selector, so the executor-side check in
    ///         `getBalanceUnchecked()` is the only thing that keeps the batch reverting.
    function testShouldRevertBatchWhenStalenessSelectorSurfacesBeforeABlockedChain() public {
        _bridgeSettleRecallAndGoStaleWithBlockedSecondChain(OTHER_CHAIN_VALUE);

        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.NavSettledStale.selector, REMOTE_CHAIN));
        executor.getBalance();
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ChainBlocked.selector, OTHER_CHAIN));
        executor.getBalanceUnchecked();

        uint256 supplyBefore = vault.totalSupply();
        FuseAction[] memory actions = _claimAction(RECALLED);
        vm.prank(ALPHA);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ChainBlocked.selector, OTHER_CHAIN));
        vault.execute(actions);

        assertEq(executor.idleLedger(), RECALLED, "claim rolled back");
        assertEq(vault.totalAssetsInMarket(MARKET), BRIDGED, "market cache untouched");
        assertEq(vault.totalSupply(), supplyBefore, "nothing minted");
    }

    /// @notice A blocked chain with EMPTY books does not make the unchecked view revert (matching `getBalance()`,
    ///         IL-8260): the stale recovery batch still goes through in the multi-executor market.
    function testShouldNotRevertUncheckedGetterForABlockedChainWithEmptyBooks() public {
        _bridgeSettleRecallAndGoStaleWithBlockedSecondChain(0);

        assertEq(executor.getBalanceUnchecked(), BRIDGED, "idle 40 + settled 60 of the first chain only");
        _claim(RECALLED);
        assertEq(vault.totalAssetsInMarket(MARKET), BRIDGED - RECALLED, "booked balance of the marked executor");
        assertEq(vault.totalAssets(), USER_DEPOSIT, "NAV unchanged");
    }

    // =====================================================================
    // Scenario helpers
    // =====================================================================

    /// @dev Settled 60e6 (with an approved observation), idle 40e6, market cache 100e6; then the observation ages
    ///      out so `getBalance()` reverts `NavSettledStale`.
    function _bridgeSettleRecallAndGoStale() private {
        _bridgeAndSettle();
        (bytes32 requestId,,) = _requestAssets(RECALLED, 0);
        _deliverReturnStarted(requestId, RGUID, RECALLED, RECALLED, 2);
        usdc.mint(address(executor), RECALLED);
        _deliverReturnCompose(requestId, RGUID, RECALLED);
        assertEq(executor.idleLedger(), RECALLED, "idle funded");
        vm.prank(ATOMIST);
        vault.updateMarketsBalances(_markets(MARKET));
        assertEq(vault.totalAssetsInMarket(MARKET), BRIDGED, "idle still inside the crosschain market");

        vm.warp(block.timestamp + STALENESS_MAX + 1);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.NavSettledStale.selector, REMOTE_CHAIN));
        executor.getBalance();
    }

    /// @dev `_bridgeSettleRecallAndGoStale` with a second dispatcher chain that a rejected proposal blocked before the
    ///      first chain aged out, carrying `otherChainSettled_` of booked value (0 = empty books). Two executors are
    ///      granted to the market.
    function _bridgeSettleRecallAndGoStaleWithBlockedSecondChain(uint256 otherChainSettled_) private {
        _bridgeAndSettle();
        (bytes32 requestId,,) = _requestAssets(RECALLED, 0);
        _deliverReturnStarted(requestId, RGUID, RECALLED, RECALLED, 2);
        usdc.mint(address(executor), RECALLED);
        _deliverReturnCompose(requestId, RGUID, RECALLED);
        vm.prank(ATOMIST);
        vault.updateMarketsBalances(_markets(MARKET));
        _grantSubstrates(true, false);

        factory.setPath(OTHER_CHAIN, OTHER_EID);
        vm.startPrank(address(vault));
        executor.registerChain(OTHER_CHAIN, OTHER_EID, _commandLaneOptions(OTHER_EID));
        executor.createDispatcher(OTHER_CHAIN, new address[](0));
        vm.stopPrank();
        factory.ackDispatcher(address(executor), 2, OTHER_CHAIN);

        BalanceObservation memory o = BalanceObservation({
            chainId: OTHER_CHAIN,
            settledBalance: 0,
            stateVersion: executor.acknowledgedRemoteStateVersion(OTHER_CHAIN),
            remoteBlock: 1,
            remoteTimestamp: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 30 minutes),
            trackedPositionSetHash: bytes32(0)
        });
        vm.prank(proposer);
        executor.proposeBalance(o);
        uint256 proposalId = executor.proposalCount();
        vm.prank(approver);
        executor.rejectAndBlockProposal(proposalId);
        assertTrue(executor.chainBlocked(OTHER_CHAIN), "second chain blocked");
        if (otherChainSettled_ != 0) {
            stdstore.target(address(executor)).sig("settledRemoteBalance(uint256)").with_key(OTHER_CHAIN).checked_write(
                otherChainSettled_
            );
        }

        vm.warp(block.timestamp + STALENESS_MAX + 1);
    }

    /// @dev Recall 40e6, the Stargate compose lands first and `RETURN_STARTED` never arrives. The rescue admin
    ///      schedules the documented pair (README "Lost recall metadata", step 3) and executes only the first half.
    function _composeFirstRecallAndDrop() private returns (bytes32 requestId, uint256 settleId, uint64 observedVersion) {
        (requestId, , ) = _requestAssets(RECALLED, 0);
        usdc.mint(address(executor), RECALLED);
        _deliverReturnCompose(requestId, RGUID, RECALLED);
        assertEq(executor.pendingArrivalReserve(), RECALLED, "compose-first amount reserved outside NAV");
        assertEq(executor.getBalance(), BRIDGED, "live NAV before the rescue counts the value once");

        observedVersion = executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN);
        vm.startPrank(admin);
        uint256 resolveId =
            executor.scheduleForceResolveTransfer(requestId, ResolveOutcome.DROP_RETURN_METADATA_INCLUDED);
        settleId =
            executor.scheduleForceSetSettledBalance(
                REMOTE_CHAIN, BRIDGED - RECALLED, observedVersion, _markFsObs(), false
            );
        vm.stopPrank();

        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeForceResolveTransfer(resolveId, requestId, ResolveOutcome.DROP_RETURN_METADATA_INCLUDED);
    }

    // =====================================================================
    // Setup (copied from CrosschainRealVaultRecoveryTest)
    // =====================================================================

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
        vault = PlasmaVault(vm.deployCode("PlasmaVault.sol:PlasmaVault"));

        vm.startPrank(ATOMIST);
        vault.proxyInitialize(
            PlasmaVaultInitData({
                assetName: "Cluster D PoC Vault",
                assetSymbol: "xcD",
                underlyingToken: address(usdc),
                priceOracleMiddleware: address(oracle),
                feeConfig: FeeConfig({
                    iporDaoManagementFee: 0,
                    iporDaoPerformanceFee: PERFORMANCE_FEE,
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
        accessManager.setupInitRoles(vault, address(withdrawManager), address(rewardsClaimManager));
        vm.stopPrank();

        feeAccount = PlasmaVaultGovernance(address(vault)).getPerformanceFeeData().feeAccount;
        FeeManager(FeeAccount(feeAccount).FEE_MANAGER()).initialize();
    }

    function _configureMarkets() private {
        supplyFuse = new StargateCrosschainSupplyFuse(MARKET);
        commandFuse = new StargateCrosschainCommandFuse(MARKET);
        claimFuse = new CrosschainClaimFuse(MARKET);
        balanceFuse = new CrosschainBalanceFuse(MARKET);
        preHook = new CrosschainNavValidationPreHook(MARKET);

        address[] memory fuses = new address[](3);
        fuses[0] = address(supplyFuse);
        fuses[1] = address(commandFuse);
        fuses[2] = address(claimFuse);

        PlasmaVaultGovernance governance = PlasmaVaultGovernance(address(vault));
        vm.startPrank(FUSE_MANAGER);
        governance.addFuses(fuses);
        governance.addBalanceFuse(MARKET, address(balanceFuse));
        vm.stopPrank();
        _grantSubstrates(false, false);

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

    /// @dev Grants the executor, optionally an (empty, healthy) sibling executor and a REMOTE_VAULT substrate.
    function _grantSubstrates(bool withSibling_, bool withRemoteVault_) private {
        uint256 count = 1 + (withSibling_ ? 1 : 0) + (withRemoteVault_ ? 1 : 0);
        bytes32[] memory subs = new bytes32[](count);
        uint256 i;
        subs[i++] = CrosschainSubstrateLib.executorSubstrate(address(executor));
        if (withSibling_) {
            StargateCrosschainExecutor sibling = _deployExecutor(address(factory), _params());
            subs[i++] = CrosschainSubstrateLib.executorSubstrate(address(sibling));
        }
        if (withRemoteVault_) {
            subs[i++] = CrosschainSubstrateLib.remoteVaultSubstrate(REMOTE_CHAIN, REMOTE_VAULT);
        }
        vm.prank(FUSE_MANAGER);
        PlasmaVaultGovernance(address(vault)).grantMarketSubstrates(MARKET, subs);
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
        assertEq(vault.totalAssetsInMarket(MARKET), BRIDGED, "market cache after bridge");
    }

    function _attest(uint256 settledLD_, uint64 stateVersion_) private {
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
        uint256 proposalId = executor.proposalCount();
        vm.prank(approver);
        executor.approveBalance(proposalId);
    }

    function _deposit(address user_, uint256 amount_) private returns (uint256 shares) {
        usdc.mint(user_, amount_);
        vm.startPrank(user_);
        usdc.approve(address(vault), amount_);
        shares = vault.deposit(amount_, user_);
        vm.stopPrank();
    }

    function _claim(uint256 amount_) private {
        vm.prank(ALPHA);
        vault.execute(_claimAction(amount_));
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
