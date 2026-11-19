// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {PlasmaVaultMockMarketsTestBase} from "./PlasmaVaultMockMarketsTestBase.sol";
import {
    PlasmaVault,
    MarketBalanceFuseConfig,
    MarketSubstratesConfig,
    PlasmaVaultInitData
} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVaultConfigLib} from "../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {FeeManagerFactory, FeeConfig} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {PlasmaVaultCloneLib} from "../test_helpers/PlasmaVaultCloneLib.sol";
import {PlasmaVaultConfigurator} from "../utils/PlasmaVaultConfigurator.sol";
import {RoleLib} from "../RoleLib.sol";

/// @title PlasmaVaultManagementFeeOlympixRegressionTest
/// @notice Olympix scan 2026-11-06, findings 5.1.30 (IL-9620, M30) and 5.1.36 (IL-9626, M36), both fixed by PR #61
///         (IL-8870): the management fee shares were priced before their own mint, and `convertToAssets` ignored the
///         accrued but unminted management fee. Every assertion is an economic outcome in asset units, not a storage
///         value, so the same file is a valid regression proof on the audited commit 8692fbe5 (fails) and on the
///         tree that contains PR #61 (passes).
/// @dev Runs on locally built vaults (never FusionFactory clones). The parent vault of PlasmaVaultMockMarketsTestBase
///      holds a child PlasmaVault in its ERC-4626 market B for the nested-vault case. No performance fee, no exit fee.
contract PlasmaVaultManagementFeeOlympixRegressionTest is PlasmaVaultMockMarketsTestBase {
    /// @dev 5% per year management fee (the maximum): one year of dormancy accrues F = 5% of the assets
    uint256 internal constant MAX_FEE = 500;
    /// @dev 2% per year management fee
    uint256 internal constant FEE_2_PERCENT = 200;
    uint256 internal constant CHILD_DEPOSIT = 1_000_000e6;
    uint256 internal constant PARENT_DEPOSIT = 100_000e6;
    /// @dev rounding tolerance in asset units (6 decimals): a few wei, far below the 0.24% (M30) and 2% (M36) errors
    uint256 internal constant TOLERANCE = 10;

    function _performanceFee() internal pure override returns (uint256) {
        return 0;
    }

    /// @notice M30 (IL-9620): the shares minted for the management fee F must be worth F after they exist
    /// @dev One year at 5% with no flows: F = 50_000e6 of 1_000_000e6. Priced before the mint the recipient got
    ///      F * G / (G + F) = 47_619.04e6, short by F^2 / (G + F) = 2_380.95e6 (0.24% of the assets, 4.76% of the fee).
    function testShouldMintFeeSharesWorthTheAccruedFee_whenFeeIsRealizedAfterOneYear() public {
        PlasmaVault child = _createChild(MAX_FEE);
        address feeAccount = PlasmaVaultGovernance(address(child)).getManagementFeeData().feeAccount;
        _depositInto(child, user, CHILD_DEPOSIT);

        vm.warp(block.timestamp + 365 days);
        uint256 expectedFee = (CHILD_DEPOSIT * MAX_FEE) / 10_000;
        assertEq(expectedFee, 50_000e6, "premise: F is 5% of the assets");
        assertEq(child.balanceOf(feeAccount), 0, "premise: nothing realized yet");

        // a small deposit realizes the management fee first
        _depositInto(child, other, 1e6);

        uint256 feeShares = child.balanceOf(feeAccount);
        assertGt(feeShares, 0, "the fee was realized");
        assertApproxEqAbs(
            child.convertToAssets(feeShares),
            expectedFee,
            TOLERANCE,
            "fee recipient shares must be worth the accrued fee F (M30)"
        );
    }

    /// @notice M30: the loss shrinks nothing on the user side, the user keeps the assets net of exactly F
    function testShouldLeaveHolderValueNetOfExactlyTheFee_whenFeeIsRealizedAfterOneYear() public {
        PlasmaVault child = _createChild(MAX_FEE);
        _depositInto(child, user, CHILD_DEPOSIT);
        vm.warp(block.timestamp + 365 days);

        _depositInto(child, other, 1e6);

        uint256 expectedFee = (CHILD_DEPOSIT * MAX_FEE) / 10_000;
        assertApproxEqAbs(
            child.convertToAssets(child.balanceOf(user)),
            CHILD_DEPOSIT - expectedFee,
            TOLERANCE,
            "holder is left with the assets net of exactly F"
        );
    }

    /// @notice M36 (IL-9626), child: while the fee is accrued but unminted, `convertToAssets` must equal what a full
    ///         redeem pays and what `previewRedeem` says
    function testShouldPriceConvertToAssetsNetOfPendingFee_whenChildIsDormantForAYear() public {
        PlasmaVault child = _createChild(FEE_2_PERCENT);
        _depositInto(child, user, CHILD_DEPOSIT);
        vm.warp(block.timestamp + 365 days);

        uint256 shares = child.balanceOf(user);
        uint256 reported = child.convertToAssets(shares);
        uint256 previewed = child.previewRedeem(shares);
        assertGt(child.getUnrealizedManagementFee(), 0, "premise: the fee is pending");

        vm.prank(user);
        uint256 paid = child.redeem(shares, user, user);

        assertLt(paid, CHILD_DEPOSIT, "premise: the redeem paid less than the deposit, the fee was charged");
        assertApproxEqAbs(reported, paid, TOLERANCE, "convertToAssets must equal the redeem payout (M36)");
        assertApproxEqAbs(previewed, paid, TOLERANCE, "previewRedeem equals the redeem payout");
    }

    /// @notice M36, parent: the parent NAV of a held child share (Erc4626BalanceFuse -> convertToAssets) must equal
    ///         what redeeming that share from the child pays
    function testShouldBookParentNavNetOfChildPendingFee_whenChildIsDormantForAYear() public {
        PlasmaVault child = _createChild(FEE_2_PERCENT);
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(address(marketB));
        substrates[1] = PlasmaVaultConfigLib.addressToBytes32(address(child));
        PlasmaVaultGovernance(address(plasmaVault)).grantMarketSubstrates(MARKET_B, substrates);

        _deposit(user, PARENT_DEPOSIT);
        _allocate(address(child), PARENT_DEPOSIT);
        uint256 childShares = child.balanceOf(address(plasmaVault));
        assertGt(childShares, 0, "premise: the parent holds child shares");

        vm.warp(block.timestamp + 365 days);

        uint256[] memory markets = new uint256[](1);
        markets[0] = MARKET_B;
        vm.prank(updater);
        plasmaVault.updateMarketsBalances(markets);
        uint256 parentNav = plasmaVault.totalAssetsInMarket(MARKET_B);

        vm.prank(address(plasmaVault));
        uint256 paid = child.redeem(childShares, address(plasmaVault), address(plasmaVault));

        assertLt(paid, PARENT_DEPOSIT, "premise: the child charged its pending fee");
        assertApproxEqAbs(parentNav, paid, TOLERANCE, "parent NAV of the child position equals the child payout (M36)");
    }

    // ------------------------------------------------------------------ child fixture

    function _depositInto(PlasmaVault vault_, address user_, uint256 amount_) internal {
        vm.startPrank(user_);
        asset.approve(address(vault_), type(uint256).max);
        vault_.deposit(amount_, user_);
        vm.stopPrank();
    }

    /// @dev A plain PlasmaVault on the same asset and oracle, with only a management fee and no markets
    function _createChild(uint256 managementFee_) internal returns (PlasmaVault child) {
        IporFusionAccessManager childAccess = RoleLib.createAccessManager(usersToRoles, 0, vm);
        WithdrawManager childWithdrawManager = new WithdrawManager(address(childAccess));

        child = PlasmaVaultCloneLib.newPlasmaVault();
        child.proxyInitialize(
            PlasmaVaultInitData(
                "IPOR Fusion child",
                "ipfChild",
                address(asset),
                PlasmaVaultGovernance(address(plasmaVault)).getPriceOracleMiddleware(),
                FeeConfig({
                    iporDaoManagementFee: managementFee_,
                    iporDaoPerformanceFee: 0,
                    feeFactory: address(new FeeManagerFactory()),
                    iporDaoFeeRecipientAddress: address(98989898)
                }),
                address(childAccess),
                address(new PlasmaVaultBase()),
                address(childWithdrawManager),
                address(0)
            )
        );
        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(child), childAccess, address(childWithdrawManager));
        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            atomist,
            address(child),
            new address[](0),
            new MarketBalanceFuseConfig[](0),
            new MarketSubstratesConfig[](0)
        );
    }
}
