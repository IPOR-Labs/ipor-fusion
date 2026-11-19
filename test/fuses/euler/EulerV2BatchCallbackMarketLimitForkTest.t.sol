// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IEVC} from "ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";
import {IVault} from "ethereum-vault-connector/src/interfaces/IVault.sol";

import {
    PlasmaVault,
    PlasmaVaultInitData,
    MarketBalanceFuseConfig,
    MarketSubstratesConfig,
    FuseAction
} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultCloneLib} from "../../test_helpers/PlasmaVaultCloneLib.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {
    AssetDistributionProtectionLib,
    MarketLimit
} from "../../../contracts/libraries/AssetDistributionProtectionLib.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {FixedValuePriceFeed} from "../../../contracts/price_oracle/price_feed/FixedValuePriceFeed.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {FeeManagerFactory, FeeConfig} from "../../../contracts/managers/fee/FeeManagerFactory.sol";
import {EulerFuseLib, EulerSubstrate} from "../../../contracts/fuses/euler/EulerFuseLib.sol";
import {EulerV2BalanceFuse} from "../../../contracts/fuses/euler/EulerV2BalanceFuse.sol";
import {
    EulerV2BatchFuse,
    EulerV2BatchItem,
    EulerV2BatchFuseData
} from "../../../contracts/fuses/euler/EulerV2BatchFuse.sol";
import {IBorrowing} from "../../../contracts/fuses/euler/ext/IBorrowing.sol";
import {Erc4626SupplyFuse, Erc4626SupplyFuseEnterData} from "../../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {Erc4626BalanceFuse} from "../../../contracts/fuses/erc4626/Erc4626BalanceFuse.sol";
import {CallbackHandlerEuler} from "../../../contracts/handlers/callbacks/CallbackHandlerEuler.sol";
import {CallbackData} from "../../../contracts/libraries/CallbackHandlerLib.sol";
import {PlasmaVaultConfigurator} from "../../utils/PlasmaVaultConfigurator.sol";
import {RoleLib, UsersToRoles} from "../../RoleLib.sol";

/// @title EulerV2BatchCallbackMarketLimitForkTest
/// @notice IL-9404: markets touched by fuse actions inside an Euler EVC batch callback (PlasmaVault.executeInternal) are
///         refreshed and limit-checked again at the end of PlasmaVault.execute, after the batch repaid the borrowed
///         liquidity. Fork test against the real EVC and EVaults on a locally built PlasmaVault and PlasmaVaultBase
///         (never a FusionFactory clone, which would run the implementation deployed on chain).
/// @dev The batch borrows 20x the NAV from an EVault, supplies USDC to a second EVault (a separate ERC-4626 market with
///      a share-of-NAV limit) inside the callback and repays the borrow. The check inside the callback sees a NAV that
///      still holds the borrowed tokens (the EULER_V2 cache is not refreshed in the callback), so only the check after
///      the batch can produce the limit asserted here. The outer batch market is EULER_V2, the callback market is
///      ERC4626_0001, so recording the callback markets is the only way the post-batch check can reach it.
///      Own fork block, shared with no other suite; no vm.warp.
contract EulerV2BatchCallbackMarketLimitForkTest is Test {
    uint256 internal constant FORK_BLOCK = 23485843;

    address internal constant EULER_V2_EVC = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;
    /// @dev Borrowed from inside the batch (flash liquidity)
    address internal constant EULER_BORROW_VAULT = 0xe0a80d35bB6618CBA260120b279d357978c42BCE;
    /// @dev Supplied to inside the callback; a separate ERC-4626 market of the PlasmaVault
    address internal constant EULER_MARKET_VAULT = 0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    uint256 internal constant CALLBACK_MARKET = IporFusionMarkets.ERC4626_0001;
    uint256 internal constant DEPOSIT = 500e6;
    /// @dev 20x the NAV, inflates the NAV seen by the check inside the callback
    uint256 internal constant BORROW_AMOUNT = 10_000e6;
    uint256 internal constant LIMIT_10_PERCENT = 1e17;

    address internal atomist = address(this);
    address internal alpha = address(0x1);
    address internal user = address(0xA11CE);

    UsersToRoles internal usersToRoles;
    IporFusionAccessManager internal accessManager;
    PlasmaVault internal plasmaVault;
    EulerV2BatchFuse internal batchFuse;
    Erc4626SupplyFuse internal supplyFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), FORK_BLOCK);

        PriceOracleMiddleware oracle = _createOracle();

        usersToRoles.superAdmin = atomist;
        usersToRoles.atomist = atomist;
        address[] memory alphas = new address[](1);
        alphas[0] = alpha;
        usersToRoles.alphas = alphas;
        accessManager = RoleLib.createAccessManager(usersToRoles, 0, vm);
        WithdrawManager withdrawManager = new WithdrawManager(address(accessManager));

        plasmaVault = PlasmaVaultCloneLib.newPlasmaVault();
        plasmaVault.proxyInitialize(
            PlasmaVaultInitData(
                "IPOR Fusion Euler batch",
                "ipfEB",
                USDC,
                address(oracle),
                FeeConfig({
                    iporDaoManagementFee: 0,
                    iporDaoPerformanceFee: 0,
                    feeFactory: address(new FeeManagerFactory()),
                    iporDaoFeeRecipientAddress: address(98989898)
                }),
                address(accessManager),
                address(new PlasmaVaultBase()),
                address(withdrawManager),
                address(0)
            )
        );
        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(plasmaVault), accessManager, address(withdrawManager));

        batchFuse = new EulerV2BatchFuse(IporFusionMarkets.EULER_V2, EULER_V2_EVC);
        supplyFuse = new Erc4626SupplyFuse(CALLBACK_MARKET);

        address[] memory fuses = new address[](2);
        fuses[0] = address(batchFuse);
        fuses[1] = address(supplyFuse);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](2);
        balanceFuses[0] = MarketBalanceFuseConfig(
            IporFusionMarkets.EULER_V2,
            address(new EulerV2BalanceFuse(IporFusionMarkets.EULER_V2, EULER_V2_EVC))
        );
        balanceFuses[1] = MarketBalanceFuseConfig(CALLBACK_MARKET, address(new Erc4626BalanceFuse(CALLBACK_MARKET)));

        bytes32[] memory eulerSubstrates = new bytes32[](1);
        eulerSubstrates[0] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: EULER_BORROW_VAULT, isCollateral: true, canBorrow: true, subAccounts: 0x00})
        );
        bytes32[] memory marketSubstrates = new bytes32[](1);
        marketSubstrates[0] = PlasmaVaultConfigLib.addressToBytes32(EULER_MARKET_VAULT);

        MarketSubstratesConfig[] memory substrates = new MarketSubstratesConfig[](2);
        substrates[0] = MarketSubstratesConfig(IporFusionMarkets.EULER_V2, eulerSubstrates);
        substrates[1] = MarketSubstratesConfig(CALLBACK_MARKET, marketSubstrates);

        PlasmaVaultConfigurator.setupPlasmaVault(vm, atomist, address(plasmaVault), fuses, balanceFuses, substrates);

        PlasmaVaultGovernance(address(plasmaVault)).updateCallbackHandler(
            address(new CallbackHandlerEuler(EULER_V2_EVC)),
            EULER_V2_EVC,
            CallbackHandlerEuler.onEulerFlashLoan.selector
        );

        deal(USDC, user, DEPOSIT);
        vm.startPrank(user);
        IERC20(USDC).approve(address(plasmaVault), DEPOSIT);
        plasmaVault.deposit(DEPOSIT, user);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ tests

    /// @dev Regression of IL-9404: 10% limit on the callback market, a borrow of 20x the NAV, the whole NAV supplied
    ///      to the market inside the callback. The in-callback check sees DEPOSIT + BORROW_AMOUNT and passes; the
    ///      check after the batch sees the NAV after repayment (DEPOSIT) and reverts with those arguments.
    function test_eulerBatchCallbackAllocationAboveMarketLimitReverts() public {
        // given
        _setLimit(LIMIT_10_PERCENT);
        uint256 expectedMarketBalance = _marketValueOf(DEPOSIT);
        FuseAction[] memory calls = _batchCalls(DEPOSIT);

        // when / then
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetDistributionProtectionLib.MarketLimitExceeded.selector,
                CALLBACK_MARKET,
                expectedMarketBalance,
                // the whole NAV sits in the market after repayment: NAV after the batch = market value
                expectedMarketBalance / 10
            )
        );
        vm.prank(alpha);
        plasmaVault.execute(calls);

        // and the allocation did not happen
        assertEq(plasmaVault.totalAssetsInMarket(CALLBACK_MARKET), 0, "no cached balance in the callback market");
        assertEq(IERC4626(EULER_MARKET_VAULT).balanceOf(address(plasmaVault)), 0, "no shares of the callback market");
        assertEq(IERC20(USDC).balanceOf(address(plasmaVault)), DEPOSIT, "assets stay idle");
        assertEq(IBorrowing(EULER_BORROW_VAULT).debtOf(address(plasmaVault)), 0, "no debt remains");
    }

    function test_eulerBatchCallbackAllocationWithinMarketLimitPasses() public {
        // given: 8% of the NAV, below the 10% limit
        _setLimit(LIMIT_10_PERCENT);
        uint256 amount = (DEPOSIT * 8) / 100;
        FuseAction[] memory calls = _batchCalls(amount);

        // when
        vm.prank(alpha);
        plasmaVault.execute(calls);

        // then
        assertEq(
            plasmaVault.totalAssetsInMarket(CALLBACK_MARKET),
            _marketValueOfHeld(),
            "the callback market holds the allocation"
        );
        assertGt(plasmaVault.totalAssetsInMarket(CALLBACK_MARKET), 0, "precondition: the market was allocated");
        assertEq(IERC20(USDC).balanceOf(address(plasmaVault)), DEPOSIT - amount, "borrow repaid from the vault");
        assertEq(IBorrowing(EULER_BORROW_VAULT).debtOf(address(plasmaVault)), 0, "no debt remains");
        assertApproxEqAbs(plasmaVault.totalAssets(), DEPOSIT, 2, "NAV unchanged");
    }

    // ------------------------------------------------------------------ helpers

    /// @dev Borrow from EULER_BORROW_VAULT, supply `supplyAmount_` to EULER_MARKET_VAULT in the callback, repay, cleanup
    function _batchCalls(uint256 supplyAmount_) internal view returns (FuseAction[] memory calls) {
        FuseAction[] memory callbackActions = new FuseAction[](1);
        callbackActions[0] = FuseAction(
            address(supplyFuse),
            abi.encodeCall(Erc4626SupplyFuse.enter, (Erc4626SupplyFuseEnterData(EULER_MARKET_VAULT, supplyAmount_, 0)))
        );

        EulerV2BatchItem[] memory items = new EulerV2BatchItem[](5);
        items[0] = EulerV2BatchItem(
            EULER_V2_EVC,
            bytes1(0x00),
            abi.encodeWithSelector(IEVC.enableController.selector, address(plasmaVault), EULER_BORROW_VAULT)
        );
        items[1] = EulerV2BatchItem(
            EULER_BORROW_VAULT,
            bytes1(0x00),
            abi.encodeWithSelector(IBorrowing.borrow.selector, BORROW_AMOUNT, address(plasmaVault))
        );
        items[2] = EulerV2BatchItem(
            address(plasmaVault),
            bytes1(0x00),
            abi.encodeWithSelector(
                CallbackHandlerEuler.onEulerFlashLoan.selector,
                abi.encode(
                    CallbackData({
                        asset: USDC,
                        addressToApprove: EULER_BORROW_VAULT,
                        amountToApprove: BORROW_AMOUNT,
                        actionData: abi.encode(callbackActions)
                    })
                )
            )
        );
        items[3] = EulerV2BatchItem(
            EULER_BORROW_VAULT,
            bytes1(0x00),
            abi.encodeWithSelector(IBorrowing.repay.selector, BORROW_AMOUNT, address(plasmaVault))
        );
        items[4] = EulerV2BatchItem(
            EULER_BORROW_VAULT,
            bytes1(0x00),
            abi.encodeWithSelector(IVault.disableController.selector)
        );

        address[] memory assetsForApprovals = new address[](1);
        assetsForApprovals[0] = USDC;
        address[] memory eulerVaultsForApprovals = new address[](1);
        eulerVaultsForApprovals[0] = EULER_BORROW_VAULT;

        calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(batchFuse),
            abi.encodeWithSelector(
                EulerV2BatchFuse.enter.selector,
                EulerV2BatchFuseData(items, assetsForApprovals, eulerVaultsForApprovals)
            )
        );
    }

    function _setLimit(uint256 limit_) internal {
        MarketLimit[] memory limits = new MarketLimit[](1);
        limits[0] = MarketLimit(CALLBACK_MARKET, limit_);
        PlasmaVaultGovernance(address(plasmaVault)).setupMarketsLimits(limits);
        PlasmaVaultGovernance(address(plasmaVault)).activateMarketsLimits();
    }

    /// @dev Value in assets of the shares minted for a deposit of `assets_`, on the current state of the market vault
    function _marketValueOf(uint256 assets_) internal view returns (uint256) {
        IERC4626 marketVault = IERC4626(EULER_MARKET_VAULT);
        return marketVault.convertToAssets(marketVault.previewDeposit(assets_));
    }

    function _marketValueOfHeld() internal view returns (uint256) {
        IERC4626 marketVault = IERC4626(EULER_MARKET_VAULT);
        return marketVault.convertToAssets(marketVault.balanceOf(address(plasmaVault)));
    }

    function _createOracle() private returns (PriceOracleMiddleware oracle) {
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(address(0));
        oracle = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );
        address[] memory assets = new address[](1);
        assets[0] = USDC;
        address[] memory sources = new address[](1);
        sources[0] = address(new FixedValuePriceFeed(1e8));
        oracle.setAssetsPricesSources(assets, sources);
    }
}
