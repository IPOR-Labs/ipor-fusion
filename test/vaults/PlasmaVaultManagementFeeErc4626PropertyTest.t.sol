// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {
    PlasmaVault,
    MarketBalanceFuseConfig,
    MarketSubstratesConfig,
    PlasmaVaultInitData
} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {FixedValuePriceFeed} from "../../contracts/price_oracle/price_feed/FixedValuePriceFeed.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {FeeManagerFactory, FeeConfig} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {FeeManager} from "../../contracts/managers/fee/FeeManager.sol";
import {FeeAccount} from "../../contracts/managers/fee/FeeAccount.sol";
import {IPlasmaVault} from "../../contracts/interfaces/IPlasmaVault.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {PlasmaVaultConfigurator} from "../utils/PlasmaVaultConfigurator.sol";
import {RoleLib, UsersToRoles} from "../RoleLib.sol";
import {MockERC20Decimals} from "../unitTest/fuses/term_finance/mocks/MockERC20Decimals.sol";
import {PlasmaVaultCloneLib} from "../test_helpers/PlasmaVaultCloneLib.sol";

/// @title PlasmaVaultManagementFeeErc4626PropertyTest
/// @notice IL-8870 property fuzz: with an accrued management fee the vault prices the fee on the supply side
///         (virtual fee shares), so every ERC-4626 preview equals what the operation does in the same block, the
///         share price does not move when the fee is realized, and the max views are exact against the supply cap.
///         The performance fee is off (or its rate stays at the high-water mark) so that IL-8489 effects do not mix in.
contract PlasmaVaultManagementFeeErc4626PropertyTest is Test {
    address public atomist = address(this);
    address public alpha = address(0x1);
    address public user = address(0xA11CE);
    address public other = address(0xB0B);

    uint256 public constant SEED_DEPOSIT = 1_000_000e6;
    uint256 public constant MAX_TIME = 2 * 365 days;
    uint256 public constant ONE_SHARE = 1e8;
    /// @dev Upper bound of the rounding gap with an exit fee of at most 90%: 1 / (1 - fee) = 10 units
    uint256 public constant EXIT_FEE_ROUNDING_GAP = 10;

    MockERC20Decimals public asset;
    UsersToRoles public usersToRoles;
    IporFusionAccessManager public accessManager;
    WithdrawManager public withdrawManager;
    PlasmaVault public plasmaVault;
    PriceOracleMiddleware public oracle;
    address public managementFeeAccount;

    function setUp() public {
        asset = new MockERC20Decimals("Mock USDC", "mUSDC", 6);

        PriceOracleMiddleware implementation = new PriceOracleMiddleware(address(0));
        oracle = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );
        address[] memory assets = new address[](1);
        assets[0] = address(asset);
        address[] memory sources = new address[](1);
        sources[0] = address(new FixedValuePriceFeed(1e8));
        oracle.setAssetsPricesSources(assets, sources);
    }

    // ---------------------------------------------------------------------------------------------
    // Entry: previewDeposit / previewMint, price invariance
    // ---------------------------------------------------------------------------------------------

    function testFuzzShouldMatchPreviewDeposit_whenManagementFeeAccrued(
        uint256 rate_,
        uint256 time_,
        uint256 amount_,
        uint256 entryFee_
    ) public {
        _deployAndSeed(bound(rate_, 1, 500), 0, 0);
        _setDepositFee(bound(entryFee_, 0, 1e17));
        _accrue(time_);
        amount_ = bound(amount_, 1e3, 5_000_000e6);

        uint256 previewShares = plasmaVault.previewDeposit(amount_);
        uint256 balanceBefore = plasmaVault.balanceOf(other);
        _fund(other, amount_);
        vm.prank(other);
        uint256 shares = plasmaVault.deposit(amount_, other);

        assertEq(plasmaVault.balanceOf(other) - balanceBefore, shares, "returned shares are minted");
        assertGe(shares, previewShares, "previewDeposit <= shares minted");
        assertEq(shares, previewShares, "previewDeposit equals shares minted");
    }

    function testFuzzShouldMatchPreviewMint_whenManagementFeeAccrued(
        uint256 rate_,
        uint256 time_,
        uint256 shares_,
        uint256 entryFee_
    ) public {
        _deployAndSeed(bound(rate_, 1, 500), 0, 0);
        _setDepositFee(bound(entryFee_, 0, 1e17));
        _accrue(time_);
        shares_ = bound(shares_, 1e5, 5_000_000e8);

        uint256 previewAssets = plasmaVault.previewMint(shares_);
        _fund(other, previewAssets * 2 + 1);
        uint256 balanceBefore = asset.balanceOf(other);
        vm.prank(other);
        uint256 assets = plasmaVault.mint(shares_, other);

        assertEq(balanceBefore - asset.balanceOf(other), assets, "returned assets are pulled");
        assertGe(previewAssets, assets, "previewMint >= assets pulled");
        assertEq(previewAssets, assets, "previewMint equals assets pulled");
    }

    function testFuzzShouldKeepSharePrice_whenManagementFeeRealized(uint256 rate_, uint256 time_) public {
        _deployAndSeed(bound(rate_, 1, 500), 0, 0);
        _accrue(time_);

        uint256 priceBefore = plasmaVault.convertToAssets(ONE_SHARE);
        uint256 supplyBefore = plasmaVault.totalSupply();

        bytes4[] memory realizeSig = new bytes4[](1);
        realizeSig[0] = IPlasmaVault.realizeManagementFee.selector;
        accessManager.setTargetFunctionRole(address(plasmaVault), realizeSig, Roles.ALPHA_ROLE);

        vm.prank(alpha);
        uint256 feeShares = plasmaVault.realizeManagementFee();

        assertEq(plasmaVault.totalSupply() - supplyBefore, feeShares, "fee shares minted");
        assertEq(plasmaVault.convertToAssets(ONE_SHARE), priceBefore, "price before == price after realization");
        assertEq(plasmaVault.getUnrealizedManagementFee(), 0, "nothing pending after realization");
    }

    // ---------------------------------------------------------------------------------------------
    // Exit: previewRedeem / previewWithdraw
    // ---------------------------------------------------------------------------------------------

    function testFuzzShouldMatchPreviewRedeem_whenManagementFeeAndExitFeeSet(
        uint256 rate_,
        uint256 time_,
        uint256 shares_,
        uint256 exitFee_
    ) public {
        exitFee_ = bound(exitFee_, 0, 9e17);
        _deployAndSeed(bound(rate_, 1, 500), 0, exitFee_);
        _accrue(time_);
        shares_ = bound(shares_, 1, plasmaVault.balanceOf(user));

        uint256 previewAssets = plasmaVault.previewRedeem(shares_);
        uint256 balanceBefore = asset.balanceOf(user);
        vm.prank(user);
        uint256 assets = plasmaVault.redeem(shares_, user, user);

        assertEq(asset.balanceOf(user) - balanceBefore, assets, "returned assets are received");
        assertLe(previewAssets, assets, "previewRedeem <= assets received");
        // The exit fee rounds on the gross side, so a fee leaves up to the rounding gap; without it the preview is exact
        assertLe(assets - previewAssets, exitFee_ == 0 ? 0 : EXIT_FEE_ROUNDING_GAP, "previewRedeem within rounding");
    }

    function testFuzzShouldMatchPreviewWithdraw_whenManagementFeeAndExitFeeSet(
        uint256 rate_,
        uint256 time_,
        uint256 assets_,
        uint256 exitFee_
    ) public {
        exitFee_ = bound(exitFee_, 0, 9e17);
        _deployAndSeed(bound(rate_, 1, 500), 0, exitFee_);
        _accrue(time_);
        uint256 maxAssets = plasmaVault.maxWithdraw(user);
        vm.assume(maxAssets > 0);
        assets_ = bound(assets_, 1, maxAssets);

        uint256 previewShares = plasmaVault.previewWithdraw(assets_);
        uint256 sharesBefore = plasmaVault.balanceOf(user);
        vm.prank(user);
        uint256 burned = plasmaVault.withdraw(assets_, user, user);

        assertEq(sharesBefore - plasmaVault.balanceOf(user), burned, "returned shares are burned");
        assertGe(previewShares, burned, "previewWithdraw >= shares burned");
        assertLe(previewShares - burned, exitFee_ == 0 ? 0 : EXIT_FEE_ROUNDING_GAP, "previewWithdraw within rounding");
    }

    /// @dev withdraw(maxWithdraw) must not revert and pays exactly maxWithdraw
    function testFuzzShouldWithdrawMaxWithdraw_whenManagementFeeAccrued(
        uint256 rate_,
        uint256 time_,
        uint256 exitFee_
    ) public {
        _deployAndSeed(bound(rate_, 1, 500), 0, bound(exitFee_, 0, 9e17));
        _accrue(time_);
        uint256 maxAssets = plasmaVault.maxWithdraw(user);
        vm.assume(maxAssets > 0);

        uint256 balanceBefore = asset.balanceOf(user);
        vm.prank(user);
        plasmaVault.withdraw(maxAssets, user, user);

        assertEq(asset.balanceOf(user) - balanceBefore, maxAssets, "user received maxWithdraw");
    }

    // ---------------------------------------------------------------------------------------------
    // Supply cap: maxDeposit / maxMint with and without headroom
    // ---------------------------------------------------------------------------------------------

    function testFuzzShouldDepositMaxDeposit_whenCapSetAndManagementFeeAccrued(
        uint256 rate_,
        uint256 time_,
        uint256 headroom_,
        uint256 entryFee_
    ) public {
        _deployAndSeed(bound(rate_, 1, 500), 0, 0);
        _setDepositFee(bound(entryFee_, 0, 1e17));
        _setCap(bound(headroom_, 0, 2_000_000e8));
        _accrue(time_);

        uint256 maxAssets = plasmaVault.maxDeposit(other);
        if (maxAssets == 0) {
            _assertNoDepositCapacity();
            return;
        }

        uint256 previewShares = plasmaVault.previewDeposit(maxAssets);
        _fund(other, maxAssets);
        vm.prank(other);
        uint256 shares = plasmaVault.deposit(maxAssets, other);

        assertEq(shares, previewShares, "previewDeposit equals shares minted");
        assertLe(
            plasmaVault.totalSupply(),
            PlasmaVaultGovernance(address(plasmaVault)).getTotalSupplyCap(),
            "cap holds"
        );
    }

    function testFuzzShouldMintMaxMint_whenCapSetAndManagementFeeAccrued(
        uint256 rate_,
        uint256 time_,
        uint256 headroom_,
        uint256 entryFee_
    ) public {
        _deployAndSeed(bound(rate_, 1, 500), 0, 0);
        _setDepositFee(bound(entryFee_, 0, 1e17));
        _setCap(bound(headroom_, 0, 2_000_000e8));
        _accrue(time_);

        uint256 maxShares = plasmaVault.maxMint(other);
        if (maxShares == 0) {
            _assertNoMintCapacity();
            return;
        }

        uint256 previewAssets = plasmaVault.previewMint(maxShares);
        _fund(other, previewAssets);
        vm.prank(other);
        uint256 assets = plasmaVault.mint(maxShares, other);

        assertEq(assets, previewAssets, "previewMint equals assets pulled");
        assertLe(
            plasmaVault.totalSupply(),
            PlasmaVaultGovernance(address(plasmaVault)).getTotalSupplyCap(),
            "cap holds"
        );
    }

    /// @dev Zero headroom is a fixed case, so the zero-capacity branch is always exercised
    function testShouldHaveZeroCapacity_whenCapEqualsSupplyAndManagementFeeAccrued() public {
        _deployAndSeed(200, 0, 0);
        _setCap(0);
        _accrue(30 days);

        assertEq(plasmaVault.maxDeposit(other), 0, "maxDeposit");
        assertEq(plasmaVault.maxMint(other), 0, "maxMint");
        _assertNoDepositCapacity();
        _assertNoMintCapacity();
    }

    /// @dev At zero capacity a zero amount is rejected by the zero-amount check, not by the cap check (K3)
    function testShouldRevertOnZeroAmounts_whenCapacityZero() public {
        _deployAndSeed(200, 0, 0);
        _setCap(0);
        _accrue(30 days);

        assertEq(plasmaVault.maxDeposit(other), 0, "maxDeposit");
        assertEq(plasmaVault.maxMint(other), 0, "maxMint");

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSignature("NoAssetsToDeposit()"));
        plasmaVault.deposit(0, other);

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSignature("NoSharesToMint()"));
        plasmaVault.mint(0, other);
    }

    /// @dev Headroom that the pending fee shares consume entirely
    function testShouldHaveZeroCapacity_whenPendingFeeSharesConsumeHeadroom() public {
        _deployAndSeed(500, 0, 0);
        _setCap(1e8);
        _accrue(MAX_TIME);

        assertEq(plasmaVault.maxDeposit(other), 0, "maxDeposit");
        assertEq(plasmaVault.maxMint(other), 0, "maxMint");
        _assertNoDepositCapacity();
        _assertNoMintCapacity();
    }

    /// @dev Positive headroom is a fixed case, so the deposit(maxDeposit) / mint(maxMint) branch is always exercised
    function testShouldDepositAndMintMax_whenHeadroomLeftAfterManagementFee() public {
        _deployAndSeed(200, 0, 0);
        _setCap(500_000e8);
        _accrue(30 days);

        uint256 maxAssets = plasmaVault.maxDeposit(other);
        assertGt(maxAssets, 0, "headroom left");
        _fund(other, maxAssets);
        vm.prank(other);
        plasmaVault.deposit(maxAssets, other);
        assertLe(
            plasmaVault.totalSupply(),
            PlasmaVaultGovernance(address(plasmaVault)).getTotalSupplyCap(),
            "cap holds"
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Zero amounts, performance fee without growth
    // ---------------------------------------------------------------------------------------------

    function testShouldRevertOnZeroAmounts_whenManagementFeeAccrued() public {
        _deployAndSeed(200, 0, 0);
        _accrue(30 days);

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSignature("NoAssetsToDeposit()"));
        plasmaVault.deposit(0, other);

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSignature("NoSharesToMint()"));
        plasmaVault.mint(0, other);
    }

    /// @dev A configured performance fee with no growth (rate stays at the high-water mark) does not change the
    ///      previews or the realization price invariance
    function testFuzzShouldMatchPreviews_whenPerformanceFeeConfiguredWithoutGrowth(
        uint256 rate_,
        uint256 time_,
        uint256 amount_
    ) public {
        _deployAndSeed(bound(rate_, 1, 500), 1000, 0);
        _accrue(time_);
        amount_ = bound(amount_, 1e3, 5_000_000e6);

        uint256 priceBefore = plasmaVault.convertToAssets(ONE_SHARE);
        uint256 previewShares = plasmaVault.previewDeposit(amount_);
        _fund(other, amount_);
        vm.prank(other);
        uint256 shares = plasmaVault.deposit(amount_, other);
        assertEq(shares, previewShares, "previewDeposit equals shares minted");

        uint256 redeemShares = plasmaVault.balanceOf(user) / 2;
        uint256 previewAssets = plasmaVault.previewRedeem(redeemShares);
        vm.prank(user);
        assertEq(plasmaVault.redeem(redeemShares, user, user), previewAssets, "previewRedeem equals assets");

        assertEq(
            plasmaVault.balanceOf(PlasmaVaultGovernance(address(plasmaVault)).getPerformanceFeeData().feeAccount),
            0,
            "no performance fee shares"
        );
        assertLe(plasmaVault.convertToAssets(ONE_SHARE), priceBefore, "price never rises without growth");
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    function _deployAndSeed(uint256 managementRate_, uint256 performanceRate_, uint256 exitFee_) internal {
        accessManager = _createAccessManager();
        withdrawManager = new WithdrawManager(address(accessManager));

        plasmaVault = PlasmaVaultCloneLib.newPlasmaVault();
        plasmaVault.proxyInitialize(
            PlasmaVaultInitData(
                "IPOR Fusion mUSDC",
                "ipfmUSDC",
                address(asset),
                address(oracle),
                FeeConfig({
                    iporDaoManagementFee: managementRate_,
                    iporDaoPerformanceFee: performanceRate_,
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

        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            atomist,
            address(plasmaVault),
            new address[](0),
            new MarketBalanceFuseConfig[](0),
            new MarketSubstratesConfig[](0)
        );

        managementFeeAccount = PlasmaVaultGovernance(address(plasmaVault)).getManagementFeeData().feeAccount;

        if (exitFee_ > 0) {
            bytes4[] memory withdrawFeeSig = new bytes4[](1);
            withdrawFeeSig[0] = WithdrawManager.updateWithdrawFee.selector;
            accessManager.setTargetFunctionRole(address(withdrawManager), withdrawFeeSig, Roles.ATOMIST_ROLE);
            withdrawManager.updateWithdrawFee(exitFee_);
        }

        _fund(user, SEED_DEPOSIT);
        vm.prank(user);
        plasmaVault.deposit(SEED_DEPOSIT, user);
    }

    function _accrue(uint256 time_) internal {
        vm.warp(block.timestamp + bound(time_, 1, MAX_TIME));
    }

    function _setCap(uint256 headroom_) internal {
        bytes4[] memory capSig = new bytes4[](1);
        capSig[0] = PlasmaVaultGovernance.setTotalSupplyCap.selector;
        accessManager.setTargetFunctionRole(address(plasmaVault), capSig, Roles.ATOMIST_ROLE);
        PlasmaVaultGovernance(address(plasmaVault)).setTotalSupplyCap(plasmaVault.totalSupply() + headroom_);
    }

    function _setDepositFee(uint256 fee_) internal {
        FeeManager feeManager = FeeManager(FeeAccount(managementFeeAccount).FEE_MANAGER());
        bytes4[] memory feeSig = new bytes4[](1);
        feeSig[0] = FeeManager.setDepositFee.selector;
        accessManager.setTargetFunctionRole(address(feeManager), feeSig, Roles.ATOMIST_ROLE);
        feeManager.setDepositFee(fee_);
    }

    function _assertNoDepositCapacity() internal {
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSignature("ERC4626ExceededMaxDeposit(address,uint256,uint256)", other, 1, 0));
        plasmaVault.deposit(1, other);
    }

    function _assertNoMintCapacity() internal {
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSignature("ERC4626ExceededMaxMint(address,uint256,uint256)", other, 1, 0));
        plasmaVault.mint(1, other);
    }

    function _fund(address user_, uint256 amount_) internal {
        asset.mint(user_, amount_);
        vm.prank(user_);
        asset.approve(address(plasmaVault), type(uint256).max);
    }

    function _createAccessManager() internal returns (IporFusionAccessManager) {
        usersToRoles.superAdmin = atomist;
        usersToRoles.atomist = atomist;
        address[] memory alphas = new address[](1);
        alphas[0] = alpha;
        usersToRoles.alphas = alphas;
        return RoleLib.createAccessManager(usersToRoles, 0, vm);
    }
}
