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
import {CrosschainBalanceFuse} from "../../contracts/fuses/crosschain/CrosschainBalanceFuse.sol";
import {CrosschainSubstrateLib} from "../../contracts/fuses/crosschain/lib/CrosschainSubstrateLib.sol";
import {CrosschainNavValidationPreHook} from "../../contracts/handlers/pre_hooks/pre_hooks/CrosschainNavValidationPreHook.sol";
import {UpdateBalancesPreHook} from "../../contracts/handlers/pre_hooks/pre_hooks/UpdateBalancesPreHook.sol";

import {BalanceObservation} from "../../contracts/crosschain/interfaces/ICrosschainExecutor.sol";
import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {TestAddresses} from "../test_helpers/TestAddresses.sol";
import {IporFusionAccessManagerHelper} from "../test_helpers/IporFusionAccessManagerHelper.sol";
import {MutableValuePriceFeed} from "../managers/MutableValuePriceFeed.sol";

/// @title CrosschainFeeRealizingDeliveryWindowBase
/// @notice Real PlasmaVault clone + real StargateCrosschainExecutor. A supply of 100 whose `TRANSFER_SETTLED`
///         credits 99 (a transport fee of 1) lowers the executor's NAV; the vault's CROSSCHAIN cache is not
///         refreshed by the delivery (IL-8596, IL-9221).
abstract contract CrosschainFeeRealizingDeliveryWindowBase is CrosschainTestBase {
    using IporFusionAccessManagerHelper for IporFusionAccessManager;

    uint256 internal constant MARKET = IporFusionMarkets.CROSSCHAIN;
    uint256 internal constant SENT = 100e6;
    uint256 internal constant CREDITED = 99e6;
    uint256 internal constant FEE = SENT - CREDITED;
    uint256 internal constant HOLDER_DEPOSIT = 500e6;

    address internal constant ATOMIST = TestAddresses.ATOMIST;
    address internal constant ALPHA = TestAddresses.ALPHA;
    address internal constant FUSE_MANAGER = TestAddresses.FUSE_MANAGER;
    address internal constant HOLDER = TestAddresses.USER;
    address internal constant EXITER = address(0xE17E4);

    PlasmaVault internal vault;
    IporFusionAccessManager internal accessManager;
    StargateCrosschainSupplyFuse internal supplyFuse;
    CrosschainBalanceFuse internal balanceFuse;
    CrosschainNavValidationPreHook internal preHook;

    /// @dev True: `withdraw` / `redeem` are hooked with `UpdateBalancesPreHook`.
    function _refreshOnExit() internal pure virtual returns (bool);

    function setUp() public {
        _baseSetUp();
        _deployVault();

        manager = address(vault);
        executor = _deployExecutor(address(factory), _params());
        vm.deal(address(executor), 100 ether);

        _configureMarkets();
        _deposit(HOLDER, HOLDER_DEPOSIT);
        _deposit(EXITER, HOLDER_DEPOSIT);

        _readyDispatcher();
        StargateCrosschainSupplyFuseEnterData memory data = StargateCrosschainSupplyFuseEnterData({
            executor: address(executor),
            asset: address(usdc),
            dstChainId: REMOTE_CHAIN,
            amount: SENT,
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

        // The delivery credits 99 of the 100 sent: a transport fee realized on the executor's books.
        _deliverTransferSettled(transferId, guid, CREDITED, 1);
        // The executor's NAV is fail-closed until the delivered bucket is attested (ordinary round, no vault refresh).
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL + 1);
        _attest(CREDITED, 1);
    }

    function _attest(uint256 settledLD_, uint64 stateVersion_) internal {
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

    /// @dev State right after the fee-realizing delivery: the live NAV is 99, the vault cache still 100.
    function _assertWindowOpen() internal view {
        assertEq(executor.getBalance(), CREDITED, "live executor NAV already lost the fee");
        assertEq(vault.totalAssetsInMarket(MARKET), SENT, "vault cache not refreshed by the delivery");
        assertEq(usdc.balanceOf(address(vault)), 2 * HOLDER_DEPOSIT - SENT, "vault idle");
    }

    function _exiterRedeemAll() internal returns (uint256 received) {
        uint256 shares = vault.balanceOf(EXITER);
        vm.prank(EXITER);
        received = vault.redeem(shares, EXITER, EXITER);
    }

    function _deployVault() internal {
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
                assetName: "L07 window vault",
                assetSymbol: "xl7",
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
        roles.alphas = new address[](1);
        roles.alphas[0] = ALPHA;
        accessManager.setupInitRoles(vault, roles, address(withdrawManager), address(rewardsClaimManager));
        vm.stopPrank();

        address feeAccount = PlasmaVaultGovernance(address(vault)).getPerformanceFeeData().feeAccount;
        FeeManager(FeeAccount(feeAccount).FEE_MANAGER()).initialize();
    }

    function _configureMarkets() internal {
        supplyFuse = new StargateCrosschainSupplyFuse(MARKET);
        balanceFuse = new CrosschainBalanceFuse(MARKET);
        preHook = new CrosschainNavValidationPreHook(MARKET);

        address[] memory fuses = new address[](1);
        fuses[0] = address(supplyFuse);

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
        if (_refreshOnExit()) {
            // withdraw and redeem refresh every active market (here: CROSSCHAIN) before pricing.
            implementations[3] = address(new UpdateBalancesPreHook());
            implementations[4] = implementations[3];
        }
        vm.prank(ATOMIST);
        PlasmaVaultGovernance(address(vault)).setPreHookImplementations(selectors, implementations, substrates);
    }

    function _deposit(address user_, uint256 amount_) internal returns (uint256 shares) {
        usdc.mint(user_, amount_);
        vm.startPrank(user_);
        usdc.approve(address(vault), amount_);
        shares = vault.deposit(amount_, user_);
        vm.stopPrank();
    }

    function _markets(uint256 marketId_) internal pure returns (uint256[] memory markets) {
        markets = new uint256[](1);
        markets[0] = marketId_;
    }
}

/// @title CrosschainFeeRealizingDeliveryWindowTest
/// @notice IL-9638 (L07) pinning test, configuration WITHOUT a refresh hook on exits: the accepted window of
///         IL-8596 / IL-8577 / IL-9221. A holder who redeems after a fee-realizing delivery and before the CROSSCHAIN
///         market is refreshed is priced at the old cache and leaves the fee to the remaining holders; the
///         difference to the post-refresh price is exactly the holder's share of the transfer fee.
/// @dev Pinning: passes on base 8692fbe5 and on the current series state (no code change in IL-9638).
/// forge-config: default.isolate = true
contract CrosschainFeeRealizingDeliveryWindowTest is CrosschainFeeRealizingDeliveryWindowBase {
    function _refreshOnExit() internal pure override returns (bool) {
        return false;
    }

    function testShouldPriceAnExitAtTheOldCacheUntilTheMarketIsRefreshed() public {
        _assertWindowOpen();
        uint256 snap = vm.snapshotState();

        // Exit ahead of the refresh: priced at the old cache.
        uint256 staleReceived = _exiterRedeemAll();

        // The same exit after the refresh: priced after the fee.
        vm.revertToState(snap);
        vm.prank(ATOMIST);
        vault.updateMarketsBalances(_markets(MARKET));
        assertEq(vault.totalAssetsInMarket(MARKET), CREDITED, "cache refreshed to the live NAV");
        uint256 freshReceived = _exiterRedeemAll();

        assertGt(staleReceived, freshReceived, "the early exit is paid more");
        // The exiter holds half of the shares, so it dodges half of the one-transfer fee.
        assertApproxEqAbs(staleReceived - freshReceived, FEE / 2, 5, "difference = share x fee of ONE transfer");
        assertApproxEqAbs(staleReceived, HOLDER_DEPOSIT, 5, "stale price: the exiter takes its deposit back whole");
    }

    function testShouldLeaveTheFeeToTheRemainingHoldersAfterAnEarlyExit() public {
        _assertWindowOpen();
        _exiterRedeemAll();

        vm.prank(ATOMIST);
        vault.updateMarketsBalances(_markets(MARKET));

        // The whole fee now sits on the remaining holder: its claim is below its deposit by the full fee.
        uint256 holderAssets = vault.convertToAssets(vault.balanceOf(HOLDER));
        assertApproxEqAbs(HOLDER_DEPOSIT - holderAssets, FEE, 5, "remaining holder bears the whole fee");
    }
}

/// @title CrosschainFeeRealizingDeliveryWindowHookedTest
/// @notice IL-9638 (L07) pinning test, configuration WITH `UpdateBalancesPreHook` on `withdraw` / `redeem` for the
///         CROSSCHAIN market (the README rule): the same exit is priced after the fee, identically to an exit that
///         follows an explicit refresh, so the hook closes the window.
/// forge-config: default.isolate = true
contract CrosschainFeeRealizingDeliveryWindowHookedTest is CrosschainFeeRealizingDeliveryWindowBase {
    function _refreshOnExit() internal pure override returns (bool) {
        return true;
    }

    function testShouldPriceTheExitAfterTheFeeWhenExitsRefreshTheMarket() public {
        _assertWindowOpen();
        uint256 snap = vm.snapshotState();

        uint256 hookedReceived = _exiterRedeemAll();
        assertEq(vault.totalAssetsInMarket(MARKET), CREDITED, "the exit refreshed the cache");

        vm.revertToState(snap);
        vm.prank(ATOMIST);
        vault.updateMarketsBalances(_markets(MARKET));
        uint256 afterExplicitRefresh = _exiterRedeemAll();

        assertEq(hookedReceived, afterExplicitRefresh, "hooked exit == exit after an explicit refresh");
        assertLt(hookedReceived, HOLDER_DEPOSIT - 1, "the exiter bears its share of the fee");
        assertApproxEqAbs(HOLDER_DEPOSIT - hookedReceived, FEE / 2, 5, "exiter pays half of the fee (half of shares)");
    }
}
