// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {
    PlasmaVault,
    MarketBalanceFuseConfig,
    MarketSubstratesConfig,
    PlasmaVaultInitData,
    FuseAction
} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVaultConfigLib} from "../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {FeeConfig, FeeManagerFactory} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {Erc4626SupplyFuse, Erc4626SupplyFuseEnterData} from "../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {Erc4626BalanceFuse} from "../../contracts/fuses/erc4626/Erc4626BalanceFuse.sol";
import {UpdateBalancesPreHook} from "../../contracts/handlers/pre_hooks/pre_hooks/UpdateBalancesPreHook.sol";
import {PlasmaVaultCloneLib} from "../test_helpers/PlasmaVaultCloneLib.sol";
import {PlasmaVaultConfigurator} from "../utils/PlasmaVaultConfigurator.sol";
import {RoleLib} from "../RoleLib.sol";
import {PlasmaVaultMockMarketsTestBase} from "./PlasmaVaultMockMarketsTestBase.sol";

/// @title CachedNavNestedChildPinTest
/// @notice IL-9703: a parent Plasma Vault that holds a child Plasma Vault as an ERC-4626 substrate values the position
///         through the child's `convertToAssets`, i.e. from the child's idle balance and the market balances the child
///         stored last. Refreshing the parent, also through `UpdateBalancesPreHook` on its deposit and redeem, does not
///         refresh the child, so an unbooked loss in the child's market is not in the parent's NAV until the child is
///         refreshed.
/// @dev Pinning test of documented behaviour (NatSpec of Erc4626BalanceFuse): it passes on the base commit, nothing in
///      the contracts changes (Pete's decision D-002: the child may have another atomist, so no guard). The child is the
///      vault of PlasmaVaultMockMarketsTestBase (read only here, except for its own market loss and refresh), the parent is
///      built in `setUp` with one ERC-4626 market whose substrate is the child.
contract CachedNavNestedChildPinTest is PlasmaVaultMockMarketsTestBase {
    uint256 public constant PARENT_MARKET = IporFusionMarkets.ERC4626_0003;
    uint256 public constant CHILD_USER_AMOUNT = 1_000_000e6;
    uint256 public constant PARENT_AMOUNT = 1_000_000e6;
    /// @dev Absolute dust allowed on rounding of the share conversions, 0.01 asset unit
    uint256 public constant DUST = 1e4;

    address public depositor = address(0xD3A0);

    PlasmaVault public parent;
    Erc4626SupplyFuse public parentSupplyFuse;

    function _performanceFee() internal pure override returns (uint256) {
        return 0;
    }

    function setUp() public override {
        super.setUp();

        /// @dev child: a third-party deposit and the whole child balance in its market A
        _deposit(user, CHILD_USER_AMOUNT);
        _allocate(address(marketA), CHILD_USER_AMOUNT);

        _buildParent();

        /// @dev parent: deposit, then the whole amount into the child through the supply fuse (market PARENT_MARKET)
        vm.prank(depositor);
        parent.deposit(PARENT_AMOUNT, depositor);
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(parentSupplyFuse),
            abi.encodeCall(
                Erc4626SupplyFuse.enter,
                (Erc4626SupplyFuseEnterData(address(plasmaVault), PARENT_AMOUNT, 0))
            )
        );
        vm.prank(alpha);
        parent.execute(calls);

        /// @dev what the parent put into the child is also moved into the child's market A, so that the whole child NAV is
        ///      in the market whose loss the tests book and refresh
        _allocate(address(marketA), asset.balanceOf(address(plasmaVault)));

        vm.prank(updater);
        parent.updateMarketsBalances(_parentMarkets());
        vm.prank(updater);
        plasmaVault.updateMarketsBalances(_ids());

        _wireParentHook(PlasmaVault.deposit.selector);
        _wireParentHook(PlasmaVault.redeem.selector);
    }

    // ------------------------------------------------------------------ parent deposit with the hook

    function testShouldNotRefreshChildMarketNorParentPositionWhenParentDepositRunsWithHook() public {
        uint256 childMarketBefore = plasmaVault.totalAssetsInMarket(MARKET_A);
        uint256 positionBefore = parent.totalAssetsInMarket(PARENT_MARKET);
        assertApproxEqAbs(positionBefore, PARENT_AMOUNT, DUST, "setup: position is the deposit");

        uint256 marketAssetsBefore = asset.balanceOf(address(marketA));
        _loss(address(marketA), 5000);
        assertEq(asset.balanceOf(address(marketA)), marketAssetsBefore / 2, "premise: the market really lost half");
        assertEq(plasmaVault.totalAssetsInMarket(MARKET_A), childMarketBefore, "premise: the child did not book it");

        _fundParentDepositor(1_000e6);
        vm.prank(depositor);
        parent.deposit(1_000e6, depositor);

        assertEq(
            plasmaVault.totalAssetsInMarket(MARKET_A),
            childMarketBefore,
            "the parent's hook does not refresh the child's market"
        );
        assertEq(
            parent.totalAssetsInMarket(PARENT_MARKET),
            positionBefore,
            "the parent's position in the child is unchanged by the refresh"
        );
    }

    /// @dev Control: the hook does refresh the parent, it only reads the child's stored values. A donation to the child's
    ///      idle balance is live in `convertToAssets`, so the refresh on the parent's deposit shows it.
    function testShouldRefreshParentPositionOnDepositButStillReadChildStoredMarketValues() public {
        uint256 childMarketBefore = plasmaVault.totalAssetsInMarket(MARKET_A);
        uint256 positionBefore = parent.totalAssetsInMarket(PARENT_MARKET);

        _loss(address(marketA), 5000);
        _donate(CHILD_USER_AMOUNT);

        _fundParentDepositor(1_000e6);
        vm.prank(depositor);
        parent.deposit(1_000e6, depositor);

        assertGt(parent.totalAssetsInMarket(PARENT_MARKET), positionBefore, "the hook ran and read the child's idle");
        assertEq(
            plasmaVault.totalAssetsInMarket(MARKET_A),
            childMarketBefore,
            "the child's stored market is unchanged"
        );
    }

    // ------------------------------------------------------------------ parent redeem with the hook

    function testShouldNotRefreshChildMarketNorParentPositionWhenParentRedeemRunsWithHook() public {
        /// @dev idle of the parent that covers the redeem, so that the redeem itself does not touch the child
        _fundParentDepositor(10_000e6);
        vm.prank(depositor);
        parent.deposit(10_000e6, depositor);
        vm.prank(updater);
        parent.updateMarketsBalances(_parentMarkets());

        uint256 childMarketBefore = plasmaVault.totalAssetsInMarket(MARKET_A);
        uint256 positionBefore = parent.totalAssetsInMarket(PARENT_MARKET);

        _loss(address(marketA), 5000);

        uint256 sharesOut = parent.balanceOf(depositor) / 200;
        vm.prank(depositor);
        parent.redeem(sharesOut, depositor, depositor);

        assertEq(
            plasmaVault.totalAssetsInMarket(MARKET_A),
            childMarketBefore,
            "the parent's hook does not refresh the child's market on redeem"
        );
        assertEq(
            parent.totalAssetsInMarket(PARENT_MARKET),
            positionBefore,
            "the parent's position in the child is unchanged by the refresh on redeem"
        );
    }

    // ------------------------------------------------------------------ the loss shows after the child is refreshed

    function testShouldShowChildLossInParentOnlyAfterChildMarketsAreUpdated() public {
        uint256 positionBefore = parent.totalAssetsInMarket(PARENT_MARKET);
        _loss(address(marketA), 5000);

        vm.prank(updater);
        parent.updateMarketsBalances(_parentMarkets());
        assertEq(parent.totalAssetsInMarket(PARENT_MARKET), positionBefore, "stale: the child was not refreshed");

        vm.prank(updater);
        plasmaVault.updateMarketsBalances(_ids());
        vm.prank(updater);
        parent.updateMarketsBalances(_parentMarkets());

        uint256 positionAfter = parent.totalAssetsInMarket(PARENT_MARKET);
        assertLt(positionAfter, positionBefore, "after the child refresh the next parent refresh shows the loss");
        /// @dev the parent owns PARENT_AMOUNT of (CHILD_USER_AMOUNT + PARENT_AMOUNT) child assets, and half of them is lost
        assertApproxEqAbs(positionAfter, positionBefore / 2, DUST, "the position is about half of what it was");
    }

    // ------------------------------------------------------------------ helpers

    function _parentMarkets() private pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = PARENT_MARKET;
    }

    function _ids() private pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        ids[0] = MARKET_A;
        ids[1] = MARKET_B;
    }

    function _fundParentDepositor(uint256 amount_) private {
        asset.mint(depositor, amount_);
    }

    function _wireParentHook(bytes4 selector_) private {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector_;
        address[] memory hooks = new address[](1);
        hooks[0] = address(new UpdateBalancesPreHook());
        bytes32[][] memory substrates = new bytes32[][](1);
        substrates[0] = new bytes32[](0);
        vm.prank(atomist);
        PlasmaVaultGovernance(address(parent)).setPreHookImplementations(selectors, hooks, substrates);
    }

    function _buildParent() private {
        WithdrawManager parentWithdrawManager = new WithdrawManager(address(accessManager));
        parent = PlasmaVaultCloneLib.newPlasmaVault();
        parent.proxyInitialize(
            PlasmaVaultInitData(
                "Parent mUSDC",
                "pmUSDC",
                address(asset),
                PlasmaVaultGovernance(address(plasmaVault)).getPriceOracleMiddleware(),
                FeeConfig({
                    iporDaoManagementFee: 0,
                    iporDaoPerformanceFee: 0,
                    feeFactory: address(new FeeManagerFactory()),
                    iporDaoFeeRecipientAddress: address(98989898)
                }),
                address(accessManager),
                address(new PlasmaVaultBase()),
                address(parentWithdrawManager),
                address(0)
            )
        );
        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(parent), accessManager, address(parentWithdrawManager));

        bytes4[] memory updateSig = new bytes4[](1);
        updateSig[0] = PlasmaVault.updateMarketsBalances.selector;
        accessManager.setTargetFunctionRole(address(parent), updateSig, Roles.UPDATE_MARKETS_BALANCES_ROLE);
        accessManager.grantRole(Roles.UPDATE_MARKETS_BALANCES_ROLE, address(parent), 0);
        bytes4[] memory hookSig = new bytes4[](1);
        hookSig[0] = PlasmaVaultGovernance.setPreHookImplementations.selector;
        accessManager.setTargetFunctionRole(address(parent), hookSig, Roles.ATOMIST_ROLE);

        parentSupplyFuse = new Erc4626SupplyFuse(PARENT_MARKET);
        address[] memory fuses = new address[](1);
        fuses[0] = address(parentSupplyFuse);
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(PARENT_MARKET, address(new Erc4626BalanceFuse(PARENT_MARKET)));
        MarketSubstratesConfig[] memory substrates = new MarketSubstratesConfig[](1);
        bytes32[] memory childSubstrate = new bytes32[](1);
        childSubstrate[0] = PlasmaVaultConfigLib.addressToBytes32(address(plasmaVault));
        substrates[0] = MarketSubstratesConfig(PARENT_MARKET, childSubstrate);
        PlasmaVaultConfigurator.setupPlasmaVault(vm, atomist, address(parent), fuses, balanceFuses, substrates);

        asset.mint(depositor, PARENT_AMOUNT);
        vm.prank(depositor);
        asset.approve(address(parent), type(uint256).max);
    }
}
