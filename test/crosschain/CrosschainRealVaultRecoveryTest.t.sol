// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
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
import {Roles} from "../../contracts/libraries/Roles.sol";
import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {
    AssetDistributionProtectionLib,
    MarketLimit
} from "../../contracts/libraries/AssetDistributionProtectionLib.sol";

import {
    StargateCrosschainSupplyFuse,
    StargateCrosschainSupplyFuseEnterData
} from "../../contracts/fuses/crosschain/stargate/StargateCrosschainSupplyFuse.sol";
import {
    CrosschainClaimFuse,
    CrosschainClaimFuseEnterData
} from "../../contracts/fuses/crosschain/CrosschainClaimFuse.sol";
import {StargateCrosschainCommandFuse} from "../../contracts/fuses/crosschain/stargate/StargateCrosschainCommandFuse.sol";
import {CrosschainBalanceFuse} from "../../contracts/fuses/crosschain/CrosschainBalanceFuse.sol";
import {
    CrosschainSubstrateLib,
    CrosschainSubstrateType
} from "../../contracts/fuses/crosschain/lib/CrosschainSubstrateLib.sol";
import {CrosschainNavValidationPreHook} from "../../contracts/handlers/pre_hooks/pre_hooks/CrosschainNavValidationPreHook.sol";
import {StargateCrosschainExecutor} from "../../contracts/crosschain/stargate/StargateCrosschainExecutor.sol";
import {BalanceObservation} from "../../contracts/crosschain/interfaces/ICrosschainExecutor.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";

import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {ExternalValueBalanceFuse, MarketValueSource} from "./mocks/ExternalValueBalanceFuse.sol";
import {RecoveryBatcher} from "./mocks/RecoveryBatcher.sol";
import {TestAddresses} from "../test_helpers/TestAddresses.sol";
import {IporFusionAccessManagerHelper} from "../test_helpers/IporFusionAccessManagerHelper.sol";
import {MutableValuePriceFeed} from "../managers/MutableValuePriceFeed.sol";

/// @title CrosschainRealVaultRecoveryTest
/// @notice IL-8268: runs the crosschain recovery runbook against a real `PlasmaVault`, the production
///         `IporFusionAccessManager` role set (`IporFusionAccessManagerInitializerLibV1`), a real `FeeManager`
///         with a performance fee, and `CrosschainNavValidationPreHook` wired the way `ConfigureMainVault`
///         wires it. The rest of the crosschain suite uses a vault harness, so `restricted`, the pre-hook
///         dispatch, `checkLimits`, `_addPerformanceFee` and the GUARDIAN pause are proven only here.
///
///         Paths covered (review 2026-09-15, §2 item 18):
///         - write-off -> re-grant -> refresh of the CROSSCHAIN market;
///         - pre-hook x `updateMarketsBalances`;
///         - claim under the recovery fallback x performance fee;
///         - GUARDIAN pause x recovery.
///
///         The executor is a real `StargateCrosschainExecutor` whose MANAGER is the vault. Transport plumbing
///         (dispatcher bring-up, inbound receipts) still uses the base helpers; every vault-level step goes
///         through the vault with the production role that the runbook names.
///
///         Runs isolated: each top-level call is its own transaction, as on chain. The fuses keep the
///         recovery and new-exposure flags in transient storage, so without isolation a supply earlier in a
///         test would still be flagged when a later claim runs and the claim would be rejected
///         (`RecoveryExposureBatchForbidden`). A real vault cannot be reset with the harness's
///         `clearContext`, and isolation also makes the atomic batch the only multi-call transaction.
/// forge-config: default.isolate = true
contract CrosschainRealVaultRecoveryTest is CrosschainTestBase {
    using IporFusionAccessManagerHelper for IporFusionAccessManager;

    uint256 internal constant MARKET = IporFusionMarkets.CROSSCHAIN;
    /// @dev Any non-crosschain market; it stands in for Aave, Morpho, ... in the pre-hook tests.
    uint256 internal constant OTHER_MARKET = 1_000_001;

    /// @dev 10% IPOR DAO performance fee (FeeManager basis: 10_000 = 100%).
    uint256 internal constant PERFORMANCE_FEE = 1_000;
    uint256 internal constant USER_DEPOSIT = 1_000e6;
    uint256 internal constant BRIDGED = 100e6;

    address internal constant ATOMIST = TestAddresses.ATOMIST;
    address internal constant ALPHA = TestAddresses.ALPHA;
    address internal constant FUSE_MANAGER = TestAddresses.FUSE_MANAGER;
    address internal constant GUARDIAN = TestAddresses.GUARDIAN;
    address internal constant OWNER = TestAddresses.OWNER;
    address internal constant USER = TestAddresses.USER;
    address internal constant LATE_USER = address(0x1A7E);
    address internal constant OPERATOR = address(0x0FE4);

    PlasmaVault internal vault;
    IporFusionAccessManager internal accessManager;
    FeeManager internal feeManager;
    address internal feeAccount;

    StargateCrosschainSupplyFuse internal supplyFuse;
    CrosschainClaimFuse internal claimFuse;
    StargateCrosschainCommandFuse internal commandFuse;
    CrosschainBalanceFuse internal balanceFuse;
    CrosschainNavValidationPreHook internal preHook;
    MarketValueSource internal otherMarketValue;

    function setUp() public {
        _baseSetUp();
        _deployVault();

        // The executor built by `_baseSetUp` is managed by a placeholder address. Every crosschain fuse and
        // the pre-hook require `executor.MANAGER() == vault`, so rebuild it with the vault as manager.
        manager = address(vault);
        executor = _deployExecutor(address(factory), _params());
        vm.deal(address(executor), 100 ether);
        vm.label(address(executor), "StargateCrosschainExecutor");

        _configureMarkets();
        _deposit(USER, USER_DEPOSIT);
    }

    // =====================================================================
    // (a) write-off -> re-grant -> refresh
    // =====================================================================

    /// @notice Runbook: write the CROSSCHAIN market off with `grantMarketSubstrates` + `updateMarketsBalances`
    ///         while the executor is fail-closed, repair the executor, then re-grant and refresh.
    function testShouldWriteOffAndRestoreCrosschainMarketOnRealVault() public {
        _bridgeAndSettle();
        assertEq(vault.totalAssetsInMarket(MARKET), BRIDGED, "crosschain market holds the bridged value");
        assertEq(vault.totalAssets(), USER_DEPOSIT, "no value created by bridging");

        _makeExecutorStale();
        vm.prank(ATOMIST);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.NavSettledStale.selector, REMOTE_CHAIN));
        vault.updateMarketsBalances(_markets(MARKET));

        // Write-off: no balance gate on `grantMarketSubstrates`, and the balance fuse reports 0 with no
        // EXECUTOR substrate.
        _writeOff();
        assertEq(vault.totalAssetsInMarket(MARKET), 0, "market written off");
        assertEq(vault.totalAssets(), USER_DEPOSIT - BRIDGED, "NAV excludes the written-off value");

        // Repair the executor (fresh attestation), then re-grant and refresh.
        _attest(BRIDGED, 1);
        _grantExecutor();
        _refresh(MARKET);

        assertEq(vault.totalAssetsInMarket(MARKET), BRIDGED, "market restored");
        assertEq(vault.totalAssets(), USER_DEPOSIT, "NAV restored");
        assertEq(vault.balanceOf(feeAccount), 0, "restoring to the previous peak mints no performance fee");
    }

    /// @notice The restore refresh arms no recovery marker, so it needs a healthy executor: re-granting while
    ///         the executor is still fail-closed makes the refresh revert, and the written-off NAV stays.
    function testShouldNotRestoreWrittenOffMarketWhileExecutorIsStillFailClosed() public {
        _bridgeAndSettle();
        _makeExecutorStale();
        _writeOff();

        _grantExecutor();
        vm.prank(ATOMIST);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.NavSettledStale.selector, REMOTE_CHAIN));
        vault.updateMarketsBalances(_markets(MARKET));

        assertEq(vault.totalAssetsInMarket(MARKET), 0, "cache keeps the written-off value");
        assertEq(vault.totalAssets(), USER_DEPOSIT - BRIDGED, "NAV unchanged by the failed restore");
    }

    /// @notice With market limits active, the restore must also fit the CROSSCHAIN market limit. The
    ///         write-off (value 0) always fits; the restore of 10% of NAV does not fit a 5% limit.
    function testShouldRejectRestoreAboveActiveMarketLimit() public {
        _bridgeAndSettle();
        _makeExecutorStale();
        _writeOff();

        MarketLimit[] memory limits = new MarketLimit[](1);
        limits[0] = MarketLimit({marketId: MARKET, limitInPercentage: 5e16}); // 5%
        vm.startPrank(ATOMIST);
        PlasmaVaultGovernance(address(vault)).setupMarketsLimits(limits);
        PlasmaVaultGovernance(address(vault)).activateMarketsLimits();
        vm.stopPrank();

        _attest(BRIDGED, 1);
        _grantExecutor();
        vm.prank(ATOMIST);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetDistributionProtectionLib.MarketLimitExceeded.selector,
                MARKET,
                BRIDGED,
                (USER_DEPOSIT * 5) / 100
            )
        );
        vault.updateMarketsBalances(_markets(MARKET));
    }

    /// @notice Documents a runbook requirement: with no EXECUTOR granted the pre-hook has nothing to check,
    ///         so deposits go through at the written-off share price and the restore hands part of the
    ///         restored value to the late depositor. The vault must stay paused for the whole write-off window
    ///         (see the GUARDIAN tests below).
    function testShouldLetDepositAtWrittenOffPriceCaptureRestoredValue() public {
        _bridgeAndSettle();
        _makeExecutorStale();

        usdc.mint(LATE_USER, 90e6);
        vm.startPrank(LATE_USER);
        usdc.approve(address(vault), 90e6);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.NavSettledStale.selector, REMOTE_CHAIN));
        vault.deposit(90e6, LATE_USER);
        vm.stopPrank();

        _writeOff();
        uint256 lateShares = _deposit(LATE_USER, 90e6);

        _attest(BRIDGED, 1);
        _grantExecutor();
        _refresh(MARKET);

        uint256 lateValue = vault.convertToAssets(lateShares);
        assertGt(lateValue, 90e6 + 9e6 - 1e6, "late depositor gains about 10% from the restore");
        assertLt(vault.convertToAssets(vault.balanceOf(USER)), USER_DEPOSIT, "existing LP bears that gain");
    }

    // =====================================================================
    // (b) pre-hook x updateMarketsBalances
    // =====================================================================

    /// @notice IL-8258 on a real vault: even when the pre-hook is also wired to `updateMarketsBalances` (as the
    ///         old NatSpec said), a fail-closed executor does not stop the refresh of other markets. The
    ///         CROSSCHAIN market itself still fails closed in the balance fuse, and deposits stay gated.
    function testShouldRefreshOtherMarketsWhileExecutorIsFailClosed() public {
        _bridgeAndSettle();
        _wirePreHook(IPlasmaVault.updateMarketsBalances.selector);
        _makeExecutorStale();

        otherMarketValue.setValue(50e18); // +50 USD accrued on the other market
        _refresh(OTHER_MARKET);
        assertEq(vault.totalAssetsInMarket(OTHER_MARKET), 50e6, "other market refreshed through the hook");
        assertEq(vault.totalAssetsInMarket(MARKET), BRIDGED, "crosschain cache untouched");

        vm.prank(ATOMIST);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.NavSettledStale.selector, REMOTE_CHAIN));
        vault.updateMarketsBalances(_markets(MARKET));

        usdc.mint(LATE_USER, 10e6);
        vm.startPrank(LATE_USER);
        usdc.approve(address(vault), 10e6);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.NavSettledStale.selector, REMOTE_CHAIN));
        vault.deposit(10e6, LATE_USER);
        vm.stopPrank();
    }

    // =====================================================================
    // (c) claim under the recovery fallback x performance fee
    // =====================================================================

    /// @notice ALPHA claims the executor's idle assets while its NAV is fail-closed. The claim arms the
    ///         recovery marker, the balance fuse falls back to the cache minus the claimed value, NAV does not
    ///         move and no performance fee is minted (no phantom gain from double counting).
    function testShouldClaimIdleUnderFallbackWithoutMintingPerformanceFee() public {
        _bridgeSettleAndRecall40();
        _makeExecutorStale();
        uint256 supplyBefore = vault.totalSupply();

        _claim(40e6);

        assertEq(executor.idleLedger(), 0, "idle claimed");
        assertEq(usdc.balanceOf(address(vault)), USER_DEPOSIT - BRIDGED + 40e6, "claimed assets in the vault");
        assertEq(vault.totalAssetsInMarket(MARKET), BRIDGED - 40e6, "cache reduced by the claimed value");
        assertEq(vault.totalAssets(), USER_DEPOSIT, "NAV unchanged");
        assertEq(vault.totalSupply(), supplyBefore, "no fee shares");
        assertEq(vault.balanceOf(feeAccount), 0, "no performance fee on the claim");
    }

    /// @notice The claim fuse requires the EXECUTOR substrate, so a claim after the write-off is impossible.
    ///         Runbook order: claim first, write off after.
    function testShouldRejectClaimAfterWriteOff() public {
        _bridgeSettleAndRecall40();
        _makeExecutorStale();
        _writeOff();

        vm.prank(ALPHA);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainSubstrateLib.CrosschainFuseUnsupportedSubstrate.selector,
                uint8(CrosschainSubstrateType.EXECUTOR),
                address(executor)
            )
        );
        vault.execute(_claimAction(40e6));
    }

    /// @notice With a second executor in the market the claim is no longer rolled back (IL-8611): the stale
    ///         executor, marked by the claim, is valued by its ungated booked balance and the healthy sibling by
    ///         its own `getBalance()`. NAV is the same as in the single-executor case (the sibling holds nothing).
    function testShouldServeUncheckedBalanceForMarkedExecutorWithSecondExecutorInMarket() public {
        _bridgeSettleAndRecall40();
        StargateCrosschainExecutor sibling = _deployExecutor(address(factory), _params());
        bytes32[] memory subs = new bytes32[](2);
        subs[0] = CrosschainSubstrateLib.executorSubstrate(address(executor));
        subs[1] = CrosschainSubstrateLib.executorSubstrate(address(sibling));
        vm.prank(FUSE_MANAGER);
        PlasmaVaultGovernance(address(vault)).grantMarketSubstrates(MARKET, subs);

        _makeExecutorStale();
        uint256 supplyBefore = vault.totalSupply();

        _claim(40e6);

        assertEq(executor.idleLedger(), 0, "idle claimed");
        assertEq(vault.totalAssetsInMarket(MARKET), BRIDGED - 40e6, "unchecked booked balance of the marked executor");
        assertEq(vault.totalAssets(), USER_DEPOSIT, "NAV unchanged");
        assertEq(vault.totalSupply(), supplyBefore, "no fee shares");
    }

    /// @notice With the default `updateInterval == 0` the high-water mark survives the write-off, so the
    ///         later restore mints no performance fee.
    function testShouldKeepHighWaterMarkAcrossWriteOffWithDefaultInterval() public {
        _bridgeAndSettle();
        _makeExecutorStale();
        _writeOff();

        vm.warp(block.timestamp + 2 days);
        _refresh(MARKET); // NAV unchanged: the HWM must not decay

        _attest(BRIDGED, 1);
        _grantExecutor();
        _refresh(MARKET);

        assertEq(vault.totalAssets(), USER_DEPOSIT, "NAV restored");
        assertEq(vault.balanceOf(feeAccount), 0, "no performance fee on recovered principal");
    }

    /// @notice IL-8256 residual risk: with a non-zero `updateInterval` the high-water mark decays to the
    ///         written-off share price, and the restore is charged as profit. Fee shares cannot be clawed back.
    function testShouldChargePerformanceFeeOnRestoreWhenHighWaterMarkDecayed() public {
        _bridgeAndSettle();
        vm.prank(OWNER);
        feeManager.updateIntervalHighWaterMarkPerformanceFee(1 days);

        _makeExecutorStale();
        _writeOff();

        vm.warp(block.timestamp + 1 days);
        _refresh(MARKET); // NAV unchanged, interval elapsed: HWM lowered to the written-off rate
        uint256 supplyBefore = vault.totalSupply();

        _attest(BRIDGED, 1);
        _grantExecutor();
        _refresh(MARKET);

        // Gain 900 -> 1000 = 10% of the restored rate; 10% fee on it = 1% of supply.
        uint256 feeShares = vault.balanceOf(feeAccount);
        assertApproxEqRel(feeShares, supplyBefore / 100, 1e16, "fee minted on recovered principal");
        assertLt(vault.convertToAssets(vault.balanceOf(USER)), USER_DEPOSIT, "LP diluted by the fee");
    }

    // =====================================================================
    // (d) GUARDIAN pause x recovery
    // =====================================================================

    /// @notice A GUARDIAN pause closes the vault in the AccessManager: every restricted call reverts,
    ///         governance and recovery included.
    function testShouldBlockRecoveryCallsWhileGuardianPauseIsOn() public {
        _bridgeSettleAndRecall40();
        _pause();

        vm.prank(FUSE_MANAGER);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, FUSE_MANAGER));
        PlasmaVaultGovernance(address(vault)).grantMarketSubstrates(MARKET, new bytes32[](0));

        vm.prank(ATOMIST);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, ATOMIST));
        vault.updateMarketsBalances(_markets(MARKET));

        vm.prank(ALPHA);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, ALPHA));
        vault.execute(_claimAction(40e6));

        usdc.mint(LATE_USER, 10e6);
        vm.startPrank(LATE_USER);
        usdc.approve(address(vault), 10e6);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, LATE_USER));
        vault.deposit(10e6, LATE_USER);
        vm.stopPrank();
    }

    /// @notice Runbook under pause: one atomic batch unpause -> claim -> write-off -> refresh -> pause. The
    ///         vault is never open between transactions, so nobody can deposit at the written-off price.
    function testShouldRunClaimAndWriteOffAsOneAtomicBatchOnPausedVault() public {
        _bridgeSettleAndRecall40();
        RecoveryBatcher batcher = _recoveryBatcher();
        _pause();
        _makeExecutorStale();

        RecoveryBatcher.Call[] memory calls = new RecoveryBatcher.Call[](5);
        calls[0] = _call(
            address(accessManager),
            abi.encodeCall(IporFusionAccessManager.updateTargetClosed, (address(vault), false))
        );
        calls[1] = _call(address(vault), abi.encodeCall(IPlasmaVault.execute, (_claimAction(40e6))));
        calls[2] = _call(
            address(vault),
            abi.encodeCall(PlasmaVaultGovernance.grantMarketSubstrates, (MARKET, new bytes32[](0)))
        );
        calls[3] = _call(address(vault), abi.encodeCall(IPlasmaVault.updateMarketsBalances, (_markets(MARKET))));
        calls[4] = _call(
            address(accessManager),
            abi.encodeCall(IporFusionAccessManager.updateTargetClosed, (address(vault), true))
        );
        vm.prank(OPERATOR);
        batcher.run(calls);

        assertTrue(accessManager.isTargetClosed(address(vault)), "vault paused again");
        assertEq(executor.idleLedger(), 0, "idle claimed before the write-off");
        assertEq(vault.totalAssetsInMarket(MARKET), 0, "remaining remote value written off");
        assertEq(vault.totalAssets(), USER_DEPOSIT - BRIDGED + 40e6, "NAV = local assets + claimed idle");
        assertEq(vault.balanceOf(feeAccount), 0, "no performance fee");

        usdc.mint(LATE_USER, 10e6);
        vm.startPrank(LATE_USER);
        usdc.approve(address(vault), 10e6);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, LATE_USER));
        vault.deposit(10e6, LATE_USER);
        vm.stopPrank();
    }

    /// @notice Restore under pause, same shape: unpause -> re-grant -> refresh -> pause in one batch, after the
    ///         executor has been repaired.
    function testShouldRestoreWrittenOffMarketAsOneAtomicBatchOnPausedVault() public {
        _bridgeAndSettle();
        RecoveryBatcher batcher = _recoveryBatcher();
        _makeExecutorStale();
        _writeOff();
        _pause();

        _attest(BRIDGED, 1);
        bytes32[] memory subs = new bytes32[](1);
        subs[0] = CrosschainSubstrateLib.executorSubstrate(address(executor));

        RecoveryBatcher.Call[] memory calls = new RecoveryBatcher.Call[](4);
        calls[0] = _call(
            address(accessManager),
            abi.encodeCall(IporFusionAccessManager.updateTargetClosed, (address(vault), false))
        );
        calls[1] = _call(address(vault), abi.encodeCall(PlasmaVaultGovernance.grantMarketSubstrates, (MARKET, subs)));
        calls[2] = _call(address(vault), abi.encodeCall(IPlasmaVault.updateMarketsBalances, (_markets(MARKET))));
        calls[3] = _call(
            address(accessManager),
            abi.encodeCall(IporFusionAccessManager.updateTargetClosed, (address(vault), true))
        );
        vm.prank(OPERATOR);
        batcher.run(calls);

        assertTrue(accessManager.isTargetClosed(address(vault)), "vault paused again");
        assertEq(vault.totalAssetsInMarket(MARKET), BRIDGED, "market restored");
        assertEq(vault.totalAssets(), USER_DEPOSIT, "NAV restored");
    }

    // =====================================================================
    // Setup
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
        sources[0] = address(new MutableValuePriceFeed(1e18)); // $1.00, 18-decimal feed
        vm.prank(ATOMIST);
        oracle.setAssetsPricesSources(assets, sources);

        // Heavy contracts come from their artifacts to keep this test contract small.
        address plasmaVaultBase = vm.deployCode("PlasmaVaultBase.sol:PlasmaVaultBase");
        address feeFactory = vm.deployCode("FeeManagerFactory.sol:FeeManagerFactory");
        vault = PlasmaVault(vm.deployCode("PlasmaVault.sol:PlasmaVault"));
        vm.label(address(vault), "PlasmaVault");

        vm.startPrank(ATOMIST);
        vault.proxyInitialize(
            PlasmaVaultInitData({
                assetName: "Crosschain Recovery Vault",
                assetSymbol: "xcRV",
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
        feeManager = FeeManager(FeeAccount(feeAccount).FEE_MANAGER());
        feeManager.initialize();
    }

    /// @dev Mirrors `ConfigureMainVault`: three crosschain fuses, the balance fuse, the executor substrate and
    ///      the pre-hook on the seven user selectors. Adds one non-crosschain market for the refresh tests.
    function _configureMarkets() private {
        supplyFuse = new StargateCrosschainSupplyFuse(MARKET);
        commandFuse = new StargateCrosschainCommandFuse(MARKET);
        claimFuse = new CrosschainClaimFuse(MARKET);
        balanceFuse = new CrosschainBalanceFuse(MARKET);
        preHook = new CrosschainNavValidationPreHook(MARKET);
        otherMarketValue = new MarketValueSource();
        ExternalValueBalanceFuse otherBalanceFuse = new ExternalValueBalanceFuse(OTHER_MARKET, otherMarketValue);

        address[] memory fuses = new address[](3);
        fuses[0] = address(supplyFuse);
        fuses[1] = address(commandFuse);
        fuses[2] = address(claimFuse);

        PlasmaVaultGovernance governance = PlasmaVaultGovernance(address(vault));
        vm.startPrank(FUSE_MANAGER);
        governance.addFuses(fuses);
        governance.addBalanceFuse(MARKET, address(balanceFuse));
        governance.addBalanceFuse(OTHER_MARKET, address(otherBalanceFuse));
        vm.stopPrank();
        _grantExecutor();

        _wirePreHook(bytes4(0));
    }

    /// @dev Wires the pre-hook on the seven `ConfigureMainVault` selectors, plus `extraSelector_` if non-zero.
    function _wirePreHook(bytes4 extraSelector_) private {
        uint256 count = extraSelector_ == bytes4(0) ? 7 : 8;
        bytes4[] memory selectors = new bytes4[](count);
        selectors[0] = IERC4626.deposit.selector;
        selectors[1] = IPlasmaVault.depositWithPermit.selector;
        selectors[2] = IERC4626.mint.selector;
        selectors[3] = IERC4626.withdraw.selector;
        selectors[4] = IERC4626.redeem.selector;
        selectors[5] = IPlasmaVault.redeemFromRequest.selector;
        selectors[6] = IPlasmaVault.execute.selector;
        if (count == 8) selectors[7] = extraSelector_;

        address[] memory implementations = new address[](count);
        bytes32[][] memory substrates = new bytes32[][](count);
        for (uint256 i; i < count; ++i) {
            implementations[i] = address(preHook);
            substrates[i] = new bytes32[](0);
        }
        vm.prank(ATOMIST); // PRE_HOOKS_MANAGER in the default role set
        PlasmaVaultGovernance(address(vault)).setPreHookImplementations(selectors, implementations, substrates);
    }

    /// @dev Stands in for the recovery Safe: holds every role the paused-vault batch needs.
    function _recoveryBatcher() private returns (RecoveryBatcher batcher) {
        batcher = new RecoveryBatcher(OPERATOR);
        vm.prank(OWNER);
        accessManager.grantRole(Roles.GUARDIAN_ROLE, address(batcher), 0);
        vm.startPrank(ATOMIST);
        accessManager.grantRole(Roles.ALPHA_ROLE, address(batcher), 0);
        accessManager.grantRole(Roles.FUSE_MANAGER_ROLE, address(batcher), 0);
        accessManager.grantRole(Roles.UPDATE_MARKETS_BALANCES_ROLE, address(batcher), 0);
        vm.stopPrank();
    }

    // =====================================================================
    // Crosschain state helpers
    // =====================================================================

    /// @dev ALPHA bridges `BRIDGED` through the supply fuse; the dispatcher settles it and the executor gets a
    ///      fresh attestation. Leaves settled = 100e6, frontier = 1, market cache = 100e6.
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
        _refresh(MARKET);
    }

    /// @dev `_bridgeAndSettle`, then recall 40e6 into the executor's idle ledger: idle = 40e6, settled = 60e6,
    ///      frontier = 2, market cache still 100e6.
    function _bridgeSettleAndRecall40() private {
        _bridgeAndSettle();
        (bytes32 requestId, , ) = _requestAssets(40e6, 0);
        _deliverReturnStarted(requestId, RGUID, 40e6, 40e6, 2);
        usdc.mint(address(executor), 40e6);
        _deliverReturnCompose(requestId, RGUID, 40e6);

        assertEq(executor.idleLedger(), 40e6, "idle funded");
        _refresh(MARKET);
        assertEq(vault.totalAssetsInMarket(MARKET), BRIDGED, "idle still inside the crosschain market");
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

    function _makeExecutorStale() private {
        vm.warp(block.timestamp + STALENESS_MAX + 1);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.NavSettledStale.selector, REMOTE_CHAIN));
        executor.getBalance();
    }

    // =====================================================================
    // Vault action helpers
    // =====================================================================

    function _deposit(address user_, uint256 amount_) private returns (uint256 shares) {
        usdc.mint(user_, amount_);
        vm.startPrank(user_);
        usdc.approve(address(vault), amount_);
        shares = vault.deposit(amount_, user_);
        vm.stopPrank();
    }

    function _grantExecutor() private {
        bytes32[] memory subs = new bytes32[](1);
        subs[0] = CrosschainSubstrateLib.executorSubstrate(address(executor));
        vm.prank(FUSE_MANAGER);
        PlasmaVaultGovernance(address(vault)).grantMarketSubstrates(MARKET, subs);
    }

    function _writeOff() private {
        vm.prank(FUSE_MANAGER);
        PlasmaVaultGovernance(address(vault)).grantMarketSubstrates(MARKET, new bytes32[](0));
        _refresh(MARKET);
    }

    function _refresh(uint256 marketId_) private {
        vm.prank(ATOMIST); // UPDATE_MARKETS_BALANCES in the default role set
        vault.updateMarketsBalances(_markets(marketId_));
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

    function _pause() private {
        vm.prank(GUARDIAN);
        accessManager.updateTargetClosed(address(vault), true);
    }

    function _markets(uint256 marketId_) private pure returns (uint256[] memory markets) {
        markets = new uint256[](1);
        markets[0] = marketId_;
    }

    function _call(address target_, bytes memory data_) private pure returns (RecoveryBatcher.Call memory) {
        return RecoveryBatcher.Call({target: target_, data: data_});
    }
}
