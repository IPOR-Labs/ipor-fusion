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
import {PlasmaVaultConfigLib} from "../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {ExternalValueBalanceFuse, MarketValueSource} from "./mocks/ExternalValueBalanceFuse.sol";
import {RecoveryBatcher} from "./mocks/RecoveryBatcher.sol";
import {TestAddresses} from "../test_helpers/TestAddresses.sol";
import {IporFusionAccessManagerHelper} from "../test_helpers/IporFusionAccessManagerHelper.sol";
import {MutableValuePriceFeed} from "../managers/MutableValuePriceFeed.sol";

/// @title CrosschainWatchedVaultRealVaultsTest
/// @notice IL-9720 (3sigma #26, part 3) on two REAL `PlasmaVault`s: vault 5 holds the CROSSCHAIN market (Stargate executor,
///         `CrosschainNavValidationPreHook` with an empty list, as `ConfigureMainVault` wires it) and an index vault that
///         holds no executor and registers the same hook DIRECTLY on `deposit`, `mint`, `depositWithPermit`, `withdraw`,
///         `redeem` and `redeemFromRequest` with `[vault 5]` as the pre-hook substrates of each selector.
///         Positive control: the six holder operations pass before the block and after the repair (force-set plus a fresh
///         attestation). Negative control: while vault 5's executor fails `getBalance()` (chain blocked with value) every
///         one of the six reverts `CrosschainNavValidationPreHookWatchedVaultUnhealthy(vault5)`; `execute` and
///         `updateMarketsBalances` of the holder keep working. The file uses no symbol the base commit lacks (the new error
///         is derived from its signature, `VERSION()` is not called): on the base the hook ignores the list, the six
///         operations do not revert and the negative tests fail, which `base_regression.sh` records.
/// forge-config: default.isolate = true
contract CrosschainWatchedVaultRealVaultsTest is CrosschainTestBase {
    using IporFusionAccessManagerHelper for IporFusionAccessManager;

    uint256 internal constant MARKET = IporFusionMarkets.CROSSCHAIN;
    uint256 internal constant BRIDGED = 100e6;
    uint256 internal constant PERFORMANCE_FEE = 1_000;
    /// @dev `CrosschainNavValidationPreHookWatchedVaultUnhealthy(address)`, derived from the signature on purpose.
    bytes4 internal constant WATCHED_UNHEALTHY =
        bytes4(keccak256("CrosschainNavValidationPreHookWatchedVaultUnhealthy(address)"));

    address internal constant ATOMIST = TestAddresses.ATOMIST;
    address internal constant ALPHA = TestAddresses.ALPHA;
    address internal constant FUSE_MANAGER = TestAddresses.FUSE_MANAGER;
    address internal constant USER = TestAddresses.USER;

    // vault 5 (CROSSCHAIN)
    PlasmaVault internal vault5;
    IporFusionAccessManager internal accessManager5;
    StargateCrosschainSupplyFuse internal supplyFuse;
    CrosschainBalanceFuse internal balanceFuse;
    CrosschainNavValidationPreHook internal preHook;
    // index (holder)
    PlasmaVault internal index;
    IporFusionAccessManager internal accessManagerIndex;
    WithdrawManager internal withdrawManagerIndex;

    function setUp() public {
        _baseSetUp();
        (vault5, accessManager5, ) = _newVault("Crosschain Vault 5", "xc5");
        (index, accessManagerIndex, withdrawManagerIndex) = _newVault("Index", "idx");

        // vault 5 is the executor's manager (every crosschain fuse and the hook require `MANAGER() == vault`)
        manager = address(vault5);
        executor = _deployExecutor(address(factory), _params());
        vm.deal(address(executor), 100 ether);

        _configureVault5();
        _configureIndex();
        // the index has idle funds of its own: a user deposit and the withdraw window
        _deposit(USER, 1_000e6);
        vm.startPrank(ATOMIST);
        withdrawManagerIndex.updatePlasmaVaultAddress(address(index));
        withdrawManagerIndex.updateWithdrawWindow(1 days);
        vm.stopPrank();
    }

    // =====================================================================
    // Tests
    // =====================================================================

    /// @notice Positive control before any block: the six holder operations pass while vault 5 is healthy.
    function testShouldPassAllSixHolderOperationsWhileTheWatchedVaultIsHealthy() public {
        _bridgeAndSettle();
        assertTrue(preHook.isNavHealthy(address(vault5)), "probe: vault 5 is healthy");
        _allSixOperations();
    }

    /// @notice Negative control: with vault 5's executor failing `getBalance()` every one of the six reverts with the hook's
    ///         error naming vault 5; the hook on vault 5 itself still gates vault 5 with its own error.
    function testShouldRevertAllSixHolderOperationsWhileTheWatchedVaultIsBlocked() public {
        _bridgeAndSettle();
        _blockChain();
        assertFalse(preHook.isNavHealthy(address(vault5)), "probe: vault 5 is not healthy");

        _prepareOperations();
        bytes memory err = abi.encodeWithSelector(WATCHED_UNHEALTHY, address(vault5));
        vm.startPrank(USER);
        vm.expectRevert(err);
        index.deposit(10e6, USER);
        vm.expectRevert(err);
        index.mint(10e6, USER);
        vm.expectRevert(err);
        index.depositWithPermit(10e6, USER, block.timestamp + 1 days, 0, bytes32(0), bytes32(0));
        vm.expectRevert(err);
        index.withdraw(1e6, USER, USER);
        vm.expectRevert(err);
        index.redeem(1e6, USER, USER);
        vm.expectRevert(err);
        index.redeemFromRequest(1e6, USER, USER);
        vm.stopPrank();
    }

    /// @notice `execute` and `updateMarketsBalances` of the holder keep working while the watched vault is blocked.
    function testShouldKeepExecuteAndUpdateMarketsBalancesOfTheHolderWorking() public {
        _bridgeAndSettle();
        _blockChain();
        vm.prank(ALPHA);
        index.execute(new FuseAction[](0));
        vm.prank(ATOMIST);
        index.updateMarketsBalances(new uint256[](0));
    }

    /// @notice The same six operations pass again after the repair: a timelocked force-set lifts the block and a fresh
    ///         attestation follows.
    function testShouldPassAllSixHolderOperationsAfterTheRepair() public {
        _bridgeAndSettle();
        _blockChain();
        _forceSetUnblock();
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL + 1);
        _attest(executor.settledRemoteBalance(REMOTE_CHAIN), executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN));
        assertTrue(preHook.isNavHealthy(address(vault5)), "probe: vault 5 is healthy again");
        _allSixOperations();
    }

    /// @notice A stale attestation (settled value, nobody re-attested) closes the holder too.
    function testShouldRevertTheHolderOnAStaleAttestationOfTheWatchedVault() public {
        _bridgeAndSettle();
        vm.warp(block.timestamp + STALENESS_MAX + 1);
        assertFalse(preHook.isNavHealthy(address(vault5)));
        usdc.mint(USER, 10e6);
        vm.startPrank(USER);
        usdc.approve(address(index), 10e6);
        vm.expectRevert(abi.encodeWithSelector(WATCHED_UNHEALTHY, address(vault5)));
        index.deposit(10e6, USER);
        vm.stopPrank();
    }

    /// @notice `isNavHealthy` on a REAL vault (until now only harnesses): true for a healthy vault 5, false when blocked, and
    ///         true for the holder (it has no executor of its own, so the probe does not see the list: README limit 5).
    function testShouldAnswerIsNavHealthyOnRealVaults() public {
        _bridgeAndSettle();
        assertTrue(preHook.isNavHealthy(address(vault5)));
        assertTrue(preHook.isNavHealthy(address(index)));
        _blockChain();
        assertFalse(preHook.isNavHealthy(address(vault5)));
        assertTrue(preHook.isNavHealthy(address(index)), "the probe of the holder does not read the list");
    }

    /// @notice Gas report (no pin): `deposit` of the holder with an empty list, one and two watched vaults, warm state.
    function testReportDepositGasWithZeroOneAndTwoWatchedVaults() public {
        _bridgeAndSettle();
        uint256[3] memory gasUsed;
        for (uint256 n; n < 3; ++n) {
            bytes32[] memory list = new bytes32[](n);
            for (uint256 i; i < n; ++i) list[i] = PlasmaVaultConfigLib.addressToBytes32(address(vault5));
            _registerHookOnIndex(list);
            for (uint256 k; k < 2; ++k) {
                usdc.mint(USER, 1e6);
                vm.startPrank(USER);
                usdc.approve(address(index), 1e6);
                index.deposit(1e6, USER);
                vm.stopPrank();
            }
            gasUsed[n] = vm.lastCallGas().gasTotalUsed;
        }
        emit log_named_uint("deposit gas, empty list", gasUsed[0]);
        emit log_named_uint("deposit gas, 1 watched vault", gasUsed[1]);
        emit log_named_uint("deposit gas, 2 watched vaults", gasUsed[2]);
        assertGt(gasUsed[1], 0);
    }

    // =====================================================================
    // Operations
    // =====================================================================

    function _prepareOperations() private {
        usdc.mint(USER, 100e6);
        vm.startPrank(USER);
        usdc.approve(address(index), type(uint256).max);
        vm.stopPrank();
        // a request for `redeemFromRequest`, released inside its window
        uint256 shares = index.balanceOf(USER) / 10;
        vm.prank(USER);
        withdrawManagerIndex.requestShares(shares);
        vm.warp(block.timestamp + 2);
        vm.prank(ALPHA);
        withdrawManagerIndex.releaseFunds(block.timestamp - 1, shares);
    }

    function _allSixOperations() private {
        _prepareOperations();
        uint256 before = index.balanceOf(USER);
        vm.startPrank(USER);
        index.deposit(10e6, USER);
        index.mint(10e6, USER);
        index.depositWithPermit(10e6, USER, block.timestamp + 1 days, 0, bytes32(0), bytes32(0));
        assertGt(index.balanceOf(USER), before, "deposit, mint and depositWithPermit minted shares");
        uint256 assets = index.withdraw(1e6, USER, USER);
        assertGt(assets, 0, "withdraw paid out");
        uint256 redeemed = index.redeem(1e6, USER, USER);
        assertGt(redeemed, 0, "redeem paid out");
        uint256 fromRequest = index.redeemFromRequest(1e6, USER, USER);
        assertGt(fromRequest, 0, "redeemFromRequest paid out");
        vm.stopPrank();
    }

    // =====================================================================
    // Setup
    // =====================================================================

    function _newVault(
        string memory name_,
        string memory symbol_
    ) private returns (PlasmaVault v, IporFusionAccessManager am, WithdrawManager wm) {
        am = new IporFusionAccessManager(ATOMIST, 0);
        wm = new WithdrawManager(address(am));

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
        v = PlasmaVaultCloneLib.clone(vm.deployCode("PlasmaVault.sol:PlasmaVault"));

        vm.startPrank(ATOMIST);
        v.proxyInitialize(
            PlasmaVaultInitData({
                assetName: name_,
                assetSymbol: symbol_,
                underlyingToken: address(usdc),
                priceOracleMiddleware: address(oracle),
                feeConfig: FeeConfig({
                    iporDaoManagementFee: 0,
                    iporDaoPerformanceFee: PERFORMANCE_FEE,
                    feeFactory: feeFactory,
                    iporDaoFeeRecipientAddress: TestAddresses.IPOR_DAO_FEE_RECIPIENT_ADDRESS
                }),
                accessManager: address(am),
                plasmaVaultBase: plasmaVaultBase,
                withdrawManager: address(wm),
                plasmaVaultVotesPlugin: address(0)
            })
        );
        RewardsClaimManager rewardsClaimManager = new RewardsClaimManager(address(am), address(v));
        am.setupInitRoles(v, address(wm), address(rewardsClaimManager));
        vm.stopPrank();

        address feeAccount = PlasmaVaultGovernance(address(v)).getPerformanceFeeData().feeAccount;
        FeeManager(FeeAccount(feeAccount).FEE_MANAGER()).initialize();
    }

    /// @dev Vault 5 as `ConfigureMainVault` wires it: supply fuse, balance fuse, executor substrate and the hook with an
    ///      EMPTY list on the seven user selectors.
    function _configureVault5() private {
        supplyFuse = new StargateCrosschainSupplyFuse(MARKET);
        balanceFuse = new CrosschainBalanceFuse(MARKET);
        preHook = new CrosschainNavValidationPreHook(MARKET);

        address[] memory fuses = new address[](1);
        fuses[0] = address(supplyFuse);
        PlasmaVaultGovernance governance = PlasmaVaultGovernance(address(vault5));
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
        governance.setPreHookImplementations(selectors, implementations, substrates);
    }

    function _configureIndex() private {
        _registerHookOnIndex(_listOf(address(vault5)));
    }

    function _listOf(address watched_) private pure returns (bytes32[] memory list_) {
        list_ = new bytes32[](1);
        list_[0] = PlasmaVaultConfigLib.addressToBytes32(watched_);
    }

    /// @dev Registers the hook DIRECTLY on the six user selectors of the index, the same list on each, in one call.
    function _registerHookOnIndex(bytes32[] memory list_) private {
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = IERC4626.deposit.selector;
        selectors[1] = IPlasmaVault.depositWithPermit.selector;
        selectors[2] = IERC4626.mint.selector;
        selectors[3] = IERC4626.withdraw.selector;
        selectors[4] = IERC4626.redeem.selector;
        selectors[5] = IPlasmaVault.redeemFromRequest.selector;
        address[] memory implementations = new address[](6);
        bytes32[][] memory substrates = new bytes32[][](6);
        for (uint256 i; i < 6; ++i) {
            implementations[i] = address(preHook);
            substrates[i] = list_;
        }
        vm.prank(ATOMIST);
        PlasmaVaultGovernance(address(index)).setPreHookImplementations(selectors, implementations, substrates);
    }

    // =====================================================================
    // Crosschain state helpers (vault 5)
    // =====================================================================

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
        // vault 5 needs idle to bridge
        usdc.mint(address(vault5), BRIDGED);
        vm.recordLogs();
        vm.prank(ALPHA);
        vault5.execute(actions);
        (bytes32 transferId, bytes32 guid, ) = _captureAssetSent();
        _deliverTransferSettled(transferId, guid, BRIDGED, 1);
        _attest(BRIDGED, 1);
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
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "the chain is blocked");
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
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "the timelocked force-set lifted the block");
    }

    function _deposit(address user_, uint256 amount_) private returns (uint256 shares) {
        usdc.mint(user_, amount_);
        vm.startPrank(user_);
        usdc.approve(address(index), amount_);
        shares = index.deposit(amount_, user_);
        vm.stopPrank();
    }
}
