// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {PlasmaVaultCloneLib} from "../test_helpers/PlasmaVaultCloneLib.sol";
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
import {Roles} from "../../contracts/libraries/Roles.sol";
import {Erc4626SupplyFuse, Erc4626SupplyFuseExitData} from "../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {PlasmaVaultConfigurator} from "../utils/PlasmaVaultConfigurator.sol";
import {PlasmaVaultMock} from "../fuses/PlasmaVaultMock.sol";
import {RoleLib, UsersToRoles} from "../RoleLib.sol";
import {MockERC20Decimals} from "../unitTest/fuses/term_finance/mocks/MockERC20Decimals.sol";

/// @title PlasmaVaultManagementFeeMaxPreviewTest
/// @notice Regression suite for IL-8319 and IL-8343 - withdraw and redeem realize the pending management fee
///         (minting fee shares while the gross total assets stay unchanged) before they price the operation,
///         but maxWithdraw, previewRedeem and previewWithdraw priced against the pre-mint supply. As a result
///         withdraw(maxWithdraw(owner)) reverted with ERC4626ExceededMaxWithdraw, redeem paid less than
///         previewRedeem and withdraw burned more shares than previewWithdraw. The views now price against the
///         supply after the fee shares that the realization would mint.
///         IL-8490 is the deposit side of the same effect: deposit and mint realize the management fee before they
///         check maxDeposit / maxMint, and the fee shares bypass the total supply cap, so with a binding cap
///         deposit(maxDeposit) and mint(maxMint) reverted. Both views now count the pending fee shares.
contract PlasmaVaultManagementFeeMaxPreviewTest is Test {
    address public atomist = address(this);
    address public alpha = address(0x1);
    address public user = address(0xA11CE);
    address public other = address(0xB0B);

    /// @dev 2% per year, FeeManager percentages use 2 decimals (10000 = 100%)
    uint256 public constant MANAGEMENT_FEE = 200;
    uint256 public constant USER_DEPOSIT = 1_000_000e6;
    uint256 public constant ACCRUAL_PERIOD = 30 days;
    /// @dev 1% in WAD
    uint256 public constant WITHDRAW_FEE = 1e16;
    /// @dev 1% in WAD
    uint256 public constant DEPOSIT_FEE = 1e16;
    /// @dev headroom under the cap in shares (8 decimals: 6 asset decimals + 2 offset), about 100k tokens
    uint256 public constant CAP_HEADROOM = 100_000e8;

    MockERC20Decimals public asset;
    UsersToRoles public usersToRoles;
    IporFusionAccessManager public accessManager;
    WithdrawManager public withdrawManager;
    PlasmaVault public plasmaVault;
    address public managementFeeAccount;

    function setUp() public {
        asset = new MockERC20Decimals("Mock USDC", "mUSDC", 6);

        PriceOracleMiddleware implementation = new PriceOracleMiddleware(address(0));
        PriceOracleMiddleware priceOracleMiddlewareProxy = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );
        address[] memory assets = new address[](1);
        assets[0] = address(asset);
        address[] memory sources = new address[](1);
        sources[0] = address(new FixedValuePriceFeed(1e8));
        priceOracleMiddlewareProxy.setAssetsPricesSources(assets, sources);

        accessManager = _createAccessManager();
        withdrawManager = new WithdrawManager(address(accessManager));

        plasmaVault = PlasmaVaultCloneLib.newPlasmaVault();
        plasmaVault.proxyInitialize(
            PlasmaVaultInitData(
                "IPOR Fusion mUSDC",
                "ipfmUSDC",
                address(asset),
                address(priceOracleMiddlewareProxy),
                FeeConfig({
                    iporDaoManagementFee: MANAGEMENT_FEE,
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

        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            atomist,
            address(plasmaVault),
            new address[](0),
            new MarketBalanceFuseConfig[](0),
            new MarketSubstratesConfig[](0)
        );

        bytes4[] memory withdrawFeeSig = new bytes4[](1);
        withdrawFeeSig[0] = WithdrawManager.updateWithdrawFee.selector;
        accessManager.setTargetFunctionRole(address(withdrawManager), withdrawFeeSig, Roles.ATOMIST_ROLE);

        managementFeeAccount = PlasmaVaultGovernance(address(plasmaVault)).getManagementFeeData().feeAccount;

        _fund(user, USER_DEPOSIT);
        _fund(other, USER_DEPOSIT);
    }

    /// @dev IL-8319: the canonical "withdraw everything" flow
    function testShouldWithdrawMaxWithdraw_whenManagementFeeAccrued() public {
        _deposit(user, USER_DEPOSIT);
        vm.warp(block.timestamp + ACCRUAL_PERIOD);
        _assertFeeWouldMintShares();

        uint256 maxAssets = plasmaVault.maxWithdraw(user);

        vm.prank(user);
        plasmaVault.withdraw(maxAssets, user, user);

        assertEq(asset.balanceOf(user), maxAssets, "user received maxWithdraw");
        assertEq(plasmaVault.convertToAssets(plasmaVault.balanceOf(user)), 0, "only sub-unit share dust left");
        assertGt(plasmaVault.balanceOf(managementFeeAccount), 0, "management fee realized");
    }

    /// @dev IL-8319 with the withdraw fee branch of maxWithdraw
    function testShouldWithdrawMaxWithdraw_whenManagementFeeAccruedAndWithdrawFeeSet() public {
        withdrawManager.updateWithdrawFee(WITHDRAW_FEE);
        _deposit(user, USER_DEPOSIT);
        vm.warp(block.timestamp + ACCRUAL_PERIOD);
        _assertFeeWouldMintShares();

        uint256 maxAssets = plasmaVault.maxWithdraw(user);

        vm.prank(user);
        plasmaVault.withdraw(maxAssets, user, user);

        assertEq(asset.balanceOf(user), maxAssets, "user received maxWithdraw");
    }

    /// @dev IL-8319: withdrawing one unit above maxWithdraw must still revert, so the bound is tight
    function testShouldRevertAboveMaxWithdraw_whenManagementFeeAccrued() public {
        _deposit(user, USER_DEPOSIT);
        _deposit(other, USER_DEPOSIT);
        vm.warp(block.timestamp + ACCRUAL_PERIOD);

        uint256 maxAssets = plasmaVault.maxWithdraw(user);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC4626ExceededMaxWithdraw(address,uint256,uint256)",
                user,
                maxAssets + 1,
                maxAssets
            )
        );
        plasmaVault.withdraw(maxAssets + 1, user, user);
    }

    /// @dev IL-8343: previewRedeem must not exceed what redeem pays in the same block
    function testShouldRedeemExactlyPreviewRedeem_whenManagementFeeAccrued() public {
        _deposit(user, USER_DEPOSIT);
        vm.warp(block.timestamp + ACCRUAL_PERIOD);
        _assertFeeWouldMintShares();

        uint256 shares = plasmaVault.balanceOf(user) / 2;
        uint256 previewAssets = plasmaVault.previewRedeem(shares);

        vm.prank(user);
        uint256 redeemedAssets = plasmaVault.redeem(shares, user, user);

        assertEq(redeemedAssets, previewAssets, "redeem pays previewRedeem");
    }

    /// @dev IL-8343: previewWithdraw must not be below the shares withdraw burns in the same block
    function testShouldBurnExactlyPreviewWithdraw_whenManagementFeeAccrued() public {
        _deposit(user, USER_DEPOSIT);
        vm.warp(block.timestamp + ACCRUAL_PERIOD);
        _assertFeeWouldMintShares();

        uint256 assets = USER_DEPOSIT / 2;
        uint256 previewShares = plasmaVault.previewWithdraw(assets);
        uint256 sharesBefore = plasmaVault.balanceOf(user);

        vm.prank(user);
        uint256 burnedShares = plasmaVault.withdraw(assets, user, user);

        assertEq(burnedShares, previewShares, "withdraw burns previewWithdraw");
        assertEq(sharesBefore - plasmaVault.balanceOf(user), previewShares, "owner balance reduced by preview");
    }

    /// @dev IL-8343 with the withdraw fee branch of the previews
    function testShouldHonourPreviews_whenManagementFeeAccruedAndWithdrawFeeSet() public {
        withdrawManager.updateWithdrawFee(WITHDRAW_FEE);
        _deposit(user, USER_DEPOSIT);
        vm.warp(block.timestamp + ACCRUAL_PERIOD);
        _assertFeeWouldMintShares();

        uint256 shares = plasmaVault.balanceOf(user) / 4;
        uint256 previewAssets = plasmaVault.previewRedeem(shares);
        vm.prank(user);
        uint256 redeemedAssets = plasmaVault.redeem(shares, user, user);
        assertGe(redeemedAssets, previewAssets, "redeem pays at least previewRedeem");

        vm.warp(block.timestamp + ACCRUAL_PERIOD);
        _assertFeeWouldMintShares();

        uint256 assets = USER_DEPOSIT / 4;
        uint256 previewShares = plasmaVault.previewWithdraw(assets);
        vm.prank(user);
        uint256 burnedShares = plasmaVault.withdraw(assets, user, user);
        assertLe(burnedShares, previewShares, "withdraw burns at most previewWithdraw");
    }

    /// @dev Once the fee is realized in the block, the views fall back to the plain conversion
    function testShouldPriceAtCurrentSupply_whenManagementFeeAlreadyRealized() public {
        _deposit(user, USER_DEPOSIT);
        vm.warp(block.timestamp + ACCRUAL_PERIOD);
        _assertFeeWouldMintShares();

        /// @dev any deposit realizes the management fee first
        _deposit(other, 1e6);

        uint256 userShares = plasmaVault.balanceOf(user);
        assertEq(plasmaVault.maxWithdraw(user), plasmaVault.convertToAssets(userShares), "maxWithdraw");
        assertEq(plasmaVault.previewRedeem(userShares), plasmaVault.convertToAssets(userShares), "previewRedeem");
        uint256 previewShares = plasmaVault.previewWithdraw(USER_DEPOSIT / 2);
        uint256 floorShares = plasmaVault.convertToShares(USER_DEPOSIT / 2);
        assertGe(previewShares, floorShares, "previewWithdraw rounds up");
        assertLe(previewShares, floorShares + 1, "previewWithdraw");
    }

    /// @dev IL-8318 interplay: a fee that rounds to zero shares is kept pending, not minted, so it must not be
    ///      simulated as a dilution either
    function testShouldNotSimulateDilution_whenPendingFeeRoundsToZeroShares() public {
        _deposit(user, 1);
        vm.prank(other);
        asset.transfer(address(plasmaVault), 1_000e6);

        /// @dev 1 hour at 2% on 1 000 tokens is ~2.28 tokens, below one share at this inflated rate
        vm.warp(block.timestamp + 1 hours);
        assertGt(plasmaVault.getUnrealizedManagementFee(), 0, "fee accrued");
        assertEq(plasmaVault.convertToShares(plasmaVault.getUnrealizedManagementFee()), 0, "fee below one share");

        uint256 userShares = plasmaVault.balanceOf(user);
        uint256 maxAssets = plasmaVault.maxWithdraw(user);
        assertEq(maxAssets, plasmaVault.convertToAssets(userShares), "no simulated dilution");

        vm.prank(user);
        plasmaVault.withdraw(maxAssets, user, user);

        assertEq(plasmaVault.balanceOf(managementFeeAccount), 0, "no fee shares minted");
    }

    function testFuzzShouldWithdrawMaxWithdraw_whenManagementFeeAccrued(
        uint256 userDeposit_,
        uint256 otherDeposit_,
        uint256 elapsed_,
        bool withWithdrawFee_
    ) public {
        userDeposit_ = bound(userDeposit_, 1e6, USER_DEPOSIT);
        otherDeposit_ = bound(otherDeposit_, 0, USER_DEPOSIT);
        elapsed_ = bound(elapsed_, 1, 3 * 365 days);

        if (withWithdrawFee_) {
            withdrawManager.updateWithdrawFee(WITHDRAW_FEE);
        }

        _deposit(user, userDeposit_);
        if (otherDeposit_ > 0) {
            _deposit(other, otherDeposit_);
        }
        vm.warp(block.timestamp + elapsed_);

        uint256 maxAssets = plasmaVault.maxWithdraw(user);
        uint256 shares = plasmaVault.balanceOf(user) / 3;
        uint256 previewAssets = plasmaVault.previewRedeem(shares);

        uint256 snapshot = vm.snapshotState();

        vm.prank(user);
        plasmaVault.withdraw(maxAssets, user, user);
        assertEq(asset.balanceOf(user), USER_DEPOSIT - userDeposit_ + maxAssets, "user received maxWithdraw");

        vm.revertToState(snapshot);

        if (shares > 0) {
            vm.prank(user);
            uint256 redeemedAssets = plasmaVault.redeem(shares, user, user);
            assertGe(redeemedAssets, previewAssets, "redeem pays at least previewRedeem");
        }
    }

    /// @dev IL-8493 (review item B-57): the previews bound what redeem and withdraw actually do, with only the
    ///      management fee pending (performance fee 0, no markets). previewRedeem <= redeem and
    ///      previewWithdraw >= shares burned. Without a withdraw fee the fix claims equality; with it the
    ///      WithdrawManager floors the fee shares while the previews round in the vault's favour, so the actual
    ///      result may be better by one share unit. Fails on 15bb830 (before IL-8343), where the previews priced
    ///      against the raw supply.
    function testFuzzShouldBoundActualsByPreviews_whenManagementFeeAccrued(
        uint256 userDeposit_,
        uint256 otherDeposit_,
        uint256 elapsed1_,
        uint256 elapsed2_,
        uint256 donation_,
        uint256 withdrawFee_,
        uint256 redeemShares_,
        uint256 withdrawAssets_
    ) public {
        userDeposit_ = bound(userDeposit_, 1, USER_DEPOSIT);
        otherDeposit_ = bound(otherDeposit_, 1e6, USER_DEPOSIT);
        elapsed1_ = bound(elapsed1_, 1, 400 days);
        elapsed2_ = bound(elapsed2_, 0, 400 days);
        donation_ = bound(donation_, 0, 1_000_000e6);
        withdrawFee_ = withdrawFee_ % 3 == 0 ? 0 : bound(withdrawFee_, 1, 5e16);

        if (withdrawFee_ > 0) {
            withdrawManager.updateWithdrawFee(withdrawFee_);
        }

        _deposit(user, userDeposit_);
        vm.warp(block.timestamp + elapsed1_);
        if (donation_ > 0) {
            asset.mint(address(plasmaVault), donation_);
        }
        vm.assume(plasmaVault.previewDeposit(otherDeposit_) > 0);
        /// @dev realizes the management fee, or keeps it pending when it is below one share (IL-8318)
        _deposit(other, otherDeposit_);
        vm.warp(block.timestamp + elapsed2_);

        uint256 userShares = plasmaVault.balanceOf(user);
        uint256 oneShareUnitInAssets = plasmaVault.convertToAssets(1) + 1;
        uint256 snapshot = vm.snapshotState();

        /// @dev redeem vs previewRedeem
        redeemShares_ = bound(redeemShares_, 1, userShares);
        uint256 previewAssets = plasmaVault.previewRedeem(redeemShares_);
        vm.prank(user);
        uint256 paid = plasmaVault.redeem(redeemShares_, user, user);
        assertGe(paid, previewAssets, "previewRedeem <= redeem");
        if (withdrawFee_ == 0) {
            assertEq(paid, previewAssets, "redeem == previewRedeem without a withdraw fee");
        } else {
            assertLe(paid - previewAssets, oneShareUnitInAssets, "within one share unit with a withdraw fee");
        }

        vm.revertToState(snapshot);

        /// @dev withdraw vs previewWithdraw
        uint256 maxAssets = plasmaVault.maxWithdraw(user);
        vm.assume(maxAssets > 0);
        withdrawAssets_ = bound(withdrawAssets_, 1, maxAssets);
        uint256 previewShares = plasmaVault.previewWithdraw(withdrawAssets_);
        vm.prank(user);
        uint256 burned = plasmaVault.withdraw(withdrawAssets_, user, user);
        assertEq(userShares - plasmaVault.balanceOf(user), burned, "withdraw returns the shares it burned");
        assertLe(burned, previewShares, "previewWithdraw >= burned");
        if (withdrawFee_ == 0) {
            assertEq(burned, previewShares, "burned == previewWithdraw without a withdraw fee");
        } else {
            assertLe(previewShares - burned, 1, "within one share unit with a withdraw fee");
        }
    }

    /// @dev IL-8319 in-repo impact: a parent vault exiting a nested PlasmaVault through Erc4626SupplyFuse clamps to
    ///      maxWithdraw, so a full exit reverted in execute
    function testShouldFullyExitNestedPlasmaVaultThroughErc4626SupplyFuse_whenManagementFeeAccrued() public {
        PlasmaVaultMock parent = _nestedParent();

        parent.exitErc4626Supply(
            Erc4626SupplyFuseExitData({
                vault: address(plasmaVault),
                vaultAssetAmount: type(uint256).max,
                maxSharesBurned: 0
            })
        );

        assertGt(asset.balanceOf(address(parent)), 0, "parent received assets");
        assertEq(
            plasmaVault.convertToAssets(plasmaVault.balanceOf(address(parent))),
            0,
            "only sub-unit share dust left"
        );
    }

    /// @dev IL-8319 in-repo impact: the instant withdrawal path caught the revert and silently skipped the exit
    function testShouldFullyInstantWithdrawNestedPlasmaVault_whenManagementFeeAccrued() public {
        PlasmaVaultMock parent = _nestedParent();

        bytes32[] memory params = new bytes32[](2);
        params[0] = bytes32(type(uint256).max);
        params[1] = bytes32(uint256(uint160(address(plasmaVault))));
        parent.instantWithdraw(params);

        assertGt(asset.balanceOf(address(parent)), 0, "parent received assets");
        assertEq(
            plasmaVault.convertToAssets(plasmaVault.balanceOf(address(parent))),
            0,
            "only sub-unit share dust left"
        );
    }

    /// @dev IL-8490: deposit realizes the management fee (fee shares bypass the cap) before it checks maxDeposit
    function testShouldDepositMaxDeposit_whenSupplyCapBindsAndManagementFeeAccrued() public {
        _bindSupplyCap(CAP_HEADROOM);
        uint256 cap = PlasmaVaultGovernance(address(plasmaVault)).getTotalSupplyCap();

        uint256 maxAssets = plasmaVault.maxDeposit(other);
        assertGt(_maxDepositBeforeIl8490(), maxAssets, "fixture reaches the defect: old maxDeposit is higher");

        vm.prank(other);
        plasmaVault.deposit(maxAssets, other);

        uint256 supply = plasmaVault.totalSupply();
        assertLe(supply, cap, "supply within the cap");
        assertGt(plasmaVault.balanceOf(managementFeeAccount), 0, "management fee realized");
        /// @dev deposit(maxDeposit) leaves less than one asset unit worth of shares under the cap: maxDeposit
        ///      floors the assets, so the minted shares are below the share headroom by the rounding of at most
        ///      one asset unit (about 100 shares at 8 share decimals over 6 asset decimals)
        assertLt(cap - supply, _sharesPerAssetUnit() + 1, "headroom below one asset unit of shares");
    }

    /// @dev IL-8490: mint fills the cap exactly, there is no conversion rounding on the share side
    function testShouldMintMaxMintAndFillCap_whenSupplyCapBindsAndManagementFeeAccrued() public {
        _bindSupplyCap(CAP_HEADROOM);
        uint256 cap = PlasmaVaultGovernance(address(plasmaVault)).getTotalSupplyCap();

        uint256 maxShares = plasmaVault.maxMint(other);
        assertGt(_maxMintBeforeIl8490(), maxShares, "fixture reaches the defect: old maxMint is higher");

        vm.prank(other);
        plasmaVault.mint(maxShares, other);

        assertEq(plasmaVault.totalSupply(), cap, "supply fills the cap exactly");
        assertGt(plasmaVault.balanceOf(managementFeeAccount), 0, "management fee realized");
    }

    /// @dev IL-8490 with a deposit fee: the fee shares minted after the deposit also count toward the cap
    function testShouldDepositMaxDeposit_whenSupplyCapBindsAndDepositFeeSet() public {
        _setDepositFee(DEPOSIT_FEE);
        _bindSupplyCap(CAP_HEADROOM);
        uint256 cap = PlasmaVaultGovernance(address(plasmaVault)).getTotalSupplyCap();
        uint256 headroomAfterFee = cap - _supplyAfterManagementFee();

        uint256 maxAssets = plasmaVault.maxDeposit(other);
        assertGt(_maxDepositBeforeIl8490(), maxAssets, "fixture reaches the defect: old maxDeposit is higher");

        vm.prank(other);
        plasmaVault.deposit(maxAssets, other);

        uint256 supply = plasmaVault.totalSupply();
        assertLe(supply, cap, "supply within the cap");
        assertGt(plasmaVault.balanceOf(address(withdrawManager)), 0, "deposit fee minted");
        /// @dev maxDeposit reserves the deposit fee on the whole remaining headroom, although the fee is taken
        ///      out of the gross shares, so it leaves that reserve (1% of the headroom) plus the asset rounding
        assertLe(
            cap - supply,
            _depositFeeShares(headroomAfterFee) + _sharesPerAssetUnit() + 1,
            "headroom is the deposit fee reserve plus rounding"
        );
    }

    /// @dev IL-8490 with a deposit fee on the mint side
    function testShouldMintMaxMint_whenSupplyCapBindsAndDepositFeeSet() public {
        _setDepositFee(DEPOSIT_FEE);
        _bindSupplyCap(CAP_HEADROOM);
        uint256 cap = PlasmaVaultGovernance(address(plasmaVault)).getTotalSupplyCap();
        uint256 headroomAfterFee = cap - _supplyAfterManagementFee();

        uint256 maxShares = plasmaVault.maxMint(other);
        assertGt(_maxMintBeforeIl8490(), maxShares, "fixture reaches the defect: old maxMint is higher");

        vm.prank(other);
        plasmaVault.mint(maxShares, other);

        uint256 supply = plasmaVault.totalSupply();
        assertLe(supply, cap, "supply within the cap");
        assertEq(plasmaVault.balanceOf(other), maxShares, "receiver got maxMint shares");
        assertGt(plasmaVault.balanceOf(address(withdrawManager)), 0, "deposit fee minted");
        /// @dev maxMint reserves the fee on the whole headroom R, the mint then takes fee(maxMint) only, so
        ///      the gap is fee(R) - fee(R - fee(R)), which is at most fee(fee(R)) plus one unit of rounding
        assertLe(
            cap - supply,
            _depositFeeShares(_depositFeeShares(headroomAfterFee)) + 2,
            "headroom is the second order deposit fee"
        );
    }

    /// @dev IL-8490: when the pending management fee alone reaches the cap nothing can be deposited or minted
    function testShouldReturnZeroMaxDepositAndMaxMint_whenPendingManagementFeeReachesSupplyCap() public {
        /// @dev headroom of about 1 000 tokens, the pending fee of 30 days on 1M is about 1 666 tokens
        _bindSupplyCap(1_000e8);
        uint256 cap = PlasmaVaultGovernance(address(plasmaVault)).getTotalSupplyCap();

        assertLt(plasmaVault.totalSupply(), cap, "raw supply is below the cap");
        assertGe(_supplyAfterManagementFee(), cap, "pending fee alone reaches the cap");
        assertGt(_maxDepositBeforeIl8490(), 0, "fixture reaches the defect: old maxDeposit is not zero");
        assertGt(_maxMintBeforeIl8490(), 0, "fixture reaches the defect: old maxMint is not zero");

        assertEq(plasmaVault.maxDeposit(other), 0, "maxDeposit");
        assertEq(plasmaVault.maxMint(other), 0, "maxMint");

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSignature("ERC4626ExceededMaxDeposit(address,uint256,uint256)", other, 1e6, 0));
        plasmaVault.deposit(1e6, other);

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSignature("ERC4626ExceededMaxMint(address,uint256,uint256)", other, 1e8, 0));
        plasmaVault.mint(1e8, other);
    }

    /// @dev IL-8490: the views are exact against the in-call limits, so one unit above them still reverts
    function testShouldRevertAboveMaxDepositAndMaxMint_whenSupplyCapBindsAndManagementFeeAccrued() public {
        _bindSupplyCap(CAP_HEADROOM);

        uint256 maxAssets = plasmaVault.maxDeposit(other);
        uint256 maxShares = plasmaVault.maxMint(other);
        assertGt(_maxDepositBeforeIl8490(), maxAssets, "fixture reaches the defect: old maxDeposit is higher");
        assertGt(_maxMintBeforeIl8490(), maxShares, "fixture reaches the defect: old maxMint is higher");

        /// @dev the in-call limit is computed after the fee realization and equals the view, so the error carries
        ///      the very same maximum
        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC4626ExceededMaxDeposit(address,uint256,uint256)",
                other,
                maxAssets + 1,
                maxAssets
            )
        );
        plasmaVault.deposit(maxAssets + 1, other);

        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSignature("ERC4626ExceededMaxMint(address,uint256,uint256)", other, maxShares + 1, maxShares)
        );
        plasmaVault.mint(maxShares + 1, other);
    }

    /// @dev IL-8490: with the fee already realized in the block the views use the plain supply
    function testShouldPriceMaxDepositAndMaxMintAtCurrentSupply_whenManagementFeeAlreadyRealized() public {
        _bindSupplyCap(CAP_HEADROOM);

        /// @dev any deposit realizes the management fee first
        _deposit(other, 1e6);
        assertEq(_supplyAfterManagementFee(), plasmaVault.totalSupply(), "nothing pending");

        assertEq(plasmaVault.maxDeposit(other), _maxDepositBeforeIl8490(), "maxDeposit");
        assertEq(plasmaVault.maxMint(other), _maxMintBeforeIl8490(), "maxMint");
    }

    /// @dev Deposit, then cap the supply headroom_ shares above it and let the management fee accrue
    function _bindSupplyCap(uint256 headroom_) internal {
        _deposit(user, USER_DEPOSIT);

        bytes4[] memory capSig = new bytes4[](1);
        capSig[0] = PlasmaVaultGovernance.setTotalSupplyCap.selector;
        accessManager.setTargetFunctionRole(address(plasmaVault), capSig, Roles.ATOMIST_ROLE);
        PlasmaVaultGovernance(address(plasmaVault)).setTotalSupplyCap(plasmaVault.totalSupply() + headroom_);

        vm.warp(block.timestamp + ACCRUAL_PERIOD);
        _assertFeeWouldMintShares();
    }

    function _setDepositFee(uint256 fee_) internal {
        FeeManager feeManager = FeeManager(FeeAccount(managementFeeAccount).FEE_MANAGER());
        bytes4[] memory feeSig = new bytes4[](1);
        feeSig[0] = FeeManager.setDepositFee.selector;
        accessManager.setTargetFunctionRole(address(feeManager), feeSig, Roles.ATOMIST_ROLE);
        feeManager.setDepositFee(fee_);
    }

    /// @dev Supply once the pending management fee is minted, the way realization does it (Floor on the raw supply)
    function _supplyAfterManagementFee() internal view returns (uint256) {
        return plasmaVault.totalSupply() + plasmaVault.convertToShares(plasmaVault.getUnrealizedManagementFee());
    }

    function _depositFeeShares(uint256 shares_) internal view returns (uint256) {
        return FeeManager(FeeAccount(managementFeeAccount).FEE_MANAGER()).calculateDepositFee(shares_);
    }

    /// @dev Shares one asset unit converts to, rounded up
    function _sharesPerAssetUnit() internal view returns (uint256) {
        return plasmaVault.convertToShares(1e6) / 1e6 + 1;
    }

    /// @dev maxDeposit as it was before IL-8490, priced against the raw total supply
    function _maxDepositBeforeIl8490() internal view returns (uint256) {
        uint256 cap = PlasmaVaultGovernance(address(plasmaVault)).getTotalSupplyCap();
        uint256 supply = plasmaVault.totalSupply();
        if (supply >= cap) {
            return 0;
        }
        return plasmaVault.convertToAssets(cap - supply - _depositFeeShares(cap - supply));
    }

    /// @dev maxMint as it was before IL-8490, priced against the raw total supply
    function _maxMintBeforeIl8490() internal view returns (uint256) {
        uint256 cap = PlasmaVaultGovernance(address(plasmaVault)).getTotalSupplyCap();
        uint256 supply = plasmaVault.totalSupply();
        if (supply >= cap) {
            return 0;
        }
        return cap - supply - _depositFeeShares(cap - supply);
    }

    function _nestedParent() internal returns (PlasmaVaultMock parent) {
        Erc4626SupplyFuse fuse = new Erc4626SupplyFuse(1);
        parent = new PlasmaVaultMock(address(fuse), address(fuse));

        address[] memory substrates = new address[](1);
        substrates[0] = address(plasmaVault);
        parent.grantAssetsToMarket(fuse.MARKET_ID(), substrates);

        vm.prank(user);
        plasmaVault.deposit(USER_DEPOSIT, address(parent));
        _deposit(other, USER_DEPOSIT);

        vm.warp(block.timestamp + ACCRUAL_PERIOD);
        _assertFeeWouldMintShares();
    }

    function _assertFeeWouldMintShares() internal view {
        assertGt(
            plasmaVault.convertToShares(plasmaVault.getUnrealizedManagementFee()),
            0,
            "pending management fee mints shares"
        );
    }

    function _deposit(address user_, uint256 amount_) internal {
        vm.prank(user_);
        plasmaVault.deposit(amount_, user_);
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
