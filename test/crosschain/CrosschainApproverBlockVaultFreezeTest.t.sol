// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
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

/// @title CrosschainApproverBlockVaultFreezeTest
/// @notice IL-9627 (Olympix M37): on a real `PlasmaVault` with `CrosschainNavValidationPreHook` wired as in
///         `ConfigureMainVault`, one `BALANCE_APPROVER` key (`rejectAndBlockProposal`) fails the NAV gate closed
///         for every share-price-sensitive user selector - `deposit`, `withdraw` (even when idle covers it),
///         `redeem` and `redeemFromRequest` - until the timelocked force-set executes. `execute` (recovery
///         actions) and `updateMarketsBalances` for other markets stay callable, the approver cannot lift the
///         block itself, and the same single key can freeze the vault again afterwards. This is the intended
///         fail-closed design (Q12 / D-051): the runbook is documented in the crosschain READMEs.
///         Pinning test: it passes on the base commit 8692fbe5; no behaviour changed.
/// forge-config: default.isolate = true
contract CrosschainApproverBlockVaultFreezeTest is CrosschainTestBase {
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
    // Tests
    // =====================================================================

    function _blockChain() private {
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL + 1);
        BalanceObservation memory o = BalanceObservation({
            chainId: REMOTE_CHAIN,
            settledBalance: executor.settledRemoteBalance(REMOTE_CHAIN),
            stateVersion: executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN),
            remoteBlock: 1,
            remoteTimestamp: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 30 minutes),
            trackedPositionSetHash: bytes32(0)
        });
        vm.prank(proposer);
        executor.proposeBalance(o);
        uint256 pid = executor.proposalCount();
        vm.prank(approver);
        executor.rejectAndBlockProposal(pid);
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "one approver key blocked the chain");
    }

    function _expectBlocked() private {
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ChainBlocked.selector, REMOTE_CHAIN));
    }

    function _forceSetUnblock() private {
        uint256 settled = executor.settledRemoteBalance(REMOTE_CHAIN);
        uint64 version = executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN);
        uint64 obs = _markFsObs();
        vm.prank(admin);
        uint256 id = executor.scheduleForceSetSettledBalance(REMOTE_CHAIN, settled, version, obs, false);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeForceSetSettledBalance(id, REMOTE_CHAIN, settled, version, obs, false);
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "timelocked force-set lifted the block");
    }

    /// @notice All four user selectors revert while one approver key holds the block, even a `withdraw` the
    ///         vault's idle balance fully covers.
    function testShouldFreezeEveryUserSelectorWhileApproverBlockHolds() public {
        _bridgeAndSettle();
        _blockChain();
        assertGt(usdc.balanceOf(address(vault)), 10e6, "idle fully covers the withdrawal");

        usdc.mint(USER, 10e6);
        vm.startPrank(USER);
        usdc.approve(address(vault), 10e6);
        _expectBlocked();
        vault.deposit(10e6, USER);
        _expectBlocked();
        vault.withdraw(10e6, USER, USER);
        _expectBlocked();
        vault.redeem(1e6, USER, USER);
        _expectBlocked();
        vault.redeemFromRequest(1e6, USER, USER);
        vm.stopPrank();
    }

    /// @notice Recovery stays reachable: `execute` with a claim of idle and `updateMarketsBalances` for a
    ///         market that is not CROSSCHAIN both pass; the CROSSCHAIN refresh itself stays fail-closed.
    function testShouldKeepRecoveryExecuteAndOtherMarketRefreshCallable() public {
        _bridgeSettleAndRecall40();
        _blockChain();

        _claim(40e6);
        assertEq(executor.idleLedger(), 0, "claim of idle executed under the block");

        _refresh(OTHER_MARKET);

        vm.prank(ATOMIST);
        _expectBlocked();
        vault.updateMarketsBalances(_markets(MARKET));
    }

    /// @notice The block is not self-lifting: a fresh propose/approve round leaves it in place; only the
    ///         timelocked force-set lifts it, and the same single key can freeze the vault again.
    function testShouldLiftOnlyThroughTimelockedForceSetAndFreezeAgain() public {
        _bridgeAndSettle();
        _blockChain();

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL + 1);
        _attest(executor.settledRemoteBalance(REMOTE_CHAIN), executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN));
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "approval does not lift the block");
        usdc.mint(USER, 10e6);
        vm.startPrank(USER);
        usdc.approve(address(vault), 10e6);
        _expectBlocked();
        vault.deposit(10e6, USER);
        vm.stopPrank();

        _forceSetUnblock();
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL + 1);
        _attest(executor.settledRemoteBalance(REMOTE_CHAIN), executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN));
        vm.prank(USER);
        vault.deposit(10e6, USER);
        assertEq(vault.balanceOf(USER) > 0, true, "deposits work again");

        _blockChain();
        vm.startPrank(USER);
        _expectBlocked();
        vault.withdraw(1e6, USER, USER);
        vm.stopPrank();
    }

    /// @notice The proposer alone cannot freeze the vault.
    function testShouldNotFreezeVaultWithProposerKeyAlone() public {
        _bridgeAndSettle();
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL + 1);
        BalanceObservation memory o = BalanceObservation({
            chainId: REMOTE_CHAIN,
            settledBalance: executor.settledRemoteBalance(REMOTE_CHAIN),
            stateVersion: executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN),
            remoteBlock: 1,
            remoteTimestamp: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 30 minutes),
            trackedPositionSetHash: bytes32(0)
        });
        vm.prank(proposer);
        executor.proposeBalance(o);
        uint256 pid = executor.proposalCount();
        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSignature("UnauthorizedApprover(address)", proposer));
        executor.rejectAndBlockProposal(pid);
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "no block without the approver key");
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
        vault = PlasmaVaultCloneLib.clone(vm.deployCode("PlasmaVault.sol:PlasmaVault"));
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
