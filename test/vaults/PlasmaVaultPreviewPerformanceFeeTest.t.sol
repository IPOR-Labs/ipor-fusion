// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PlasmaVaultCloneLib} from "../test_helpers/PlasmaVaultCloneLib.sol";
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
import {PlasmaVaultConfigurator} from "../utils/PlasmaVaultConfigurator.sol";
import {RoleLib, UsersToRoles} from "../RoleLib.sol";
import {MockERC20Decimals} from "../unitTest/fuses/term_finance/mocks/MockERC20Decimals.sol";

/// @title PlasmaVaultPreviewPerformanceFeeTestBase
/// @notice IL-9624 (Olympix 2026-11-06 M34): previewRedeem, previewWithdraw and maxWithdraw price the performance fee
///         that withdraw and redeem crystallize before they pay, so with fresh market balances the previews equal the
///         results and withdraw(maxWithdraw(owner)) succeeds (ERC-4626: a preview must not promise more than the call
///         gives). Before IL-9624 the views priced only the accrued management fee (IL-8489): with the share rate
///         above the high-water mark previewRedeem and maxWithdraw over-promised by the holder's share of the pending
///         performance fee and previewWithdraw under-promised the shares burned.
/// @dev Assertions are in asset and share units only (no high-water-mark unit), so the suite runs unchanged on the
///      code before IL-9601 and fails there on every pending-fee case. The FeeManager view is reached through a
///      low-level static call for the same reason. Controls (no pending fee, deposits) pass on both builds.
abstract contract PlasmaVaultPreviewPerformanceFeeTestBase is Test {
    address public atomist = address(this);
    address public alpha = address(0x1);
    address public user = address(0xA11CE);
    address public other = address(0xB0B);

    /// @dev 2% per year, FeeManager percentages use 2 decimals (10000 = 100%)
    uint256 public constant MANAGEMENT_FEE = 200;
    /// @dev 10%
    uint256 public constant PERFORMANCE_FEE = 1000;
    /// @dev 1% in WAD
    uint256 public constant WITHDRAW_FEE = 1e16;

    bytes4 internal constant EXCEEDED_MAX_WITHDRAW =
        bytes4(keccak256("ERC4626ExceededMaxWithdraw(address,uint256,uint256)"));

    MockERC20Decimals public asset;
    UsersToRoles internal usersToRoles;
    IporFusionAccessManager public accessManager;
    WithdrawManager public withdrawManager;
    PlasmaVault public plasmaVault;

    /// @dev one asset in its smallest unit
    uint256 internal unit;
    uint256 internal userDeposit;

    function _assetDecimals() internal pure virtual returns (uint8);

    function setUp() public {
        unit = 10 ** _assetDecimals();
        userDeposit = 1_000_000 * unit;
        _deploy();

        _fund(user, userDeposit);
        _fund(other, userDeposit);
        _deposit(user, userDeposit);
        _deposit(other, userDeposit);

        /// @dev the management fee accrues for a day, so both fees are pending in the scenarios below
        vm.warp(block.timestamp + 1 days);
    }

    // ---------------------------------------------------------------------------------------------
    // Pending performance fee from a donation (share rate above the high-water mark)
    // ---------------------------------------------------------------------------------------------

    function testShouldPreviewRedeemWhatRedeemPays_whenPerformanceFeePending() public {
        _donate(20_000 * unit);
        uint256 shares = plasmaVault.balanceOf(user) / 2;

        uint256 previewAssets = plasmaVault.previewRedeem(shares);
        vm.prank(user);
        uint256 paid = plasmaVault.redeem(shares, user, user);

        assertEq(paid, previewAssets, "redeem pays previewRedeem");
    }

    function testShouldPreviewRedeemWholePosition_whenPerformanceFeePending() public {
        _donate(20_000 * unit);
        uint256 shares = plasmaVault.balanceOf(user);

        uint256 previewAssets = plasmaVault.previewRedeem(shares);
        uint256 maxAssets = plasmaVault.maxWithdraw(user);
        vm.prank(user);
        uint256 paid = plasmaVault.redeem(shares, user, user);

        assertEq(paid, previewAssets, "redeem of the whole position pays previewRedeem");
        assertEq(maxAssets, paid, "maxWithdraw equals what the whole position redeems for");
    }

    function testShouldPreviewWithdrawTheSharesWithdrawBurns_whenPerformanceFeePending() public {
        _donate(20_000 * unit);
        uint256 assets = 300_000 * unit;

        uint256 previewShares = plasmaVault.previewWithdraw(assets);
        uint256 sharesBefore = plasmaVault.balanceOf(user);
        vm.prank(user);
        uint256 burned = plasmaVault.withdraw(assets, user, user);

        assertEq(sharesBefore - plasmaVault.balanceOf(user), burned, "withdraw returns the shares it burned");
        assertEq(burned, previewShares, "withdraw burns previewWithdraw");
    }

    function testShouldWithdrawMaxWithdraw_whenPerformanceFeePending() public {
        _donate(20_000 * unit);

        uint256 maxAssets = plasmaVault.maxWithdraw(user);
        assertEq(_enforcedWithdrawLimit(user, maxAssets), maxAssets, "maxWithdraw equals the in-call limit");

        uint256 balanceBefore = asset.balanceOf(user);
        vm.prank(user);
        plasmaVault.withdraw(maxAssets, user, user);

        assertEq(asset.balanceOf(user) - balanceBefore, maxAssets, "user received maxWithdraw");
        assertLe(
            plasmaVault.convertToAssets(plasmaVault.balanceOf(user)),
            1,
            "the shares left are worth at most one asset unit of rounding"
        );
    }

    /// @dev A long dormancy: a large accrued management fee and a large gain above the high-water mark at once
    function testShouldPreviewExactly_whenBothFeesPendingAfterLongDormancy() public {
        vm.warp(block.timestamp + 180 days);
        _donate(150_000 * unit);

        uint256 shares = plasmaVault.balanceOf(user) / 3;
        uint256 previewAssets = plasmaVault.previewRedeem(shares);
        uint256 assets = 200_000 * unit;
        uint256 previewShares = plasmaVault.previewWithdraw(assets);
        uint256 maxAssets = plasmaVault.maxWithdraw(user);

        uint256 snapshot = vm.snapshotState();
        vm.prank(user);
        assertEq(plasmaVault.redeem(shares, user, user), previewAssets, "redeem pays previewRedeem");
        vm.revertToState(snapshot);

        snapshot = vm.snapshotState();
        vm.prank(user);
        assertEq(plasmaVault.withdraw(assets, user, user), previewShares, "withdraw burns previewWithdraw");
        vm.revertToState(snapshot);

        assertEq(_enforcedWithdrawLimit(user, maxAssets), maxAssets, "maxWithdraw equals the in-call limit");
    }

    // ---------------------------------------------------------------------------------------------
    // Pending performance fee from the withdraw fee burn, with the withdraw fee branches of the views
    // ---------------------------------------------------------------------------------------------

    function testShouldNotOverPromisePreviewRedeem_whenWithdrawFeeBurnLeftPerformanceFeePending() public {
        _setupWithdrawFeeBurnScenario();
        uint256 shares = plasmaVault.balanceOf(user) / 2;

        uint256 previewAssets = plasmaVault.previewRedeem(shares);
        vm.prank(user);
        uint256 paid = plasmaVault.redeem(shares, user, user);

        /// @dev the vault burns floor(shares * fee) and the view prices floor(shares * (1 - fee)): at most one share
        ///      unit apart, which is worth less than one asset unit
        assertGe(paid, previewAssets, "previewRedeem does not promise more than redeem pays");
        assertLe(paid - previewAssets, 1, "redeem pays previewRedeem up to the withdraw fee rounding");
    }

    function testShouldNotUnderPromisePreviewWithdraw_whenWithdrawFeeBurnLeftPerformanceFeePending() public {
        _setupWithdrawFeeBurnScenario();
        uint256 assets = 200_000 * unit;

        uint256 previewShares = plasmaVault.previewWithdraw(assets);
        vm.prank(user);
        uint256 burned = plasmaVault.withdraw(assets, user, user);

        /// @dev gross = ceil(net / (1 - fee)) in the view, net + floor(gross * fee) burned: at most one unit apart
        assertLe(burned, previewShares, "withdraw burns no more than previewWithdraw");
        assertLe(previewShares - burned, 1, "withdraw burns previewWithdraw up to the withdraw fee rounding");
    }

    function testShouldWithdrawMaxWithdraw_whenWithdrawFeeBurnLeftPerformanceFeePending() public {
        _setupWithdrawFeeBurnScenario();

        uint256 maxAssets = plasmaVault.maxWithdraw(user);
        assertEq(_enforcedWithdrawLimit(user, maxAssets), maxAssets, "maxWithdraw equals the in-call limit");

        uint256 balanceBefore = asset.balanceOf(user);
        vm.prank(user);
        plasmaVault.withdraw(maxAssets, user, user);
        assertEq(asset.balanceOf(user) - balanceBefore, maxAssets, "user received maxWithdraw");
    }

    // ---------------------------------------------------------------------------------------------
    // FeeManager view
    // ---------------------------------------------------------------------------------------------

    /// @dev The FeeManager view returns the shares calculateAndUpdatePerformanceFee sizes for the same inputs, at
    ///      the rate and supply the vault passes
    function testShouldSizePendingPerformanceFeeSharesInFeeManager_whenRateAboveHighWaterMark() public {
        _donate(20_000 * unit);
        FeeManager feeManager = _feeManager();

        (bool okScale, bytes memory scaleRet) = address(feeManager).staticcall(
            abi.encodeWithSignature("HIGH_WATER_MARK_SCALE()")
        );
        assertTrue(okScale, "FeeManager exposes HIGH_WATER_MARK_SCALE");
        uint256 scale = abi.decode(scaleRet, (uint256));

        uint256 supply = plasmaVault.totalSupply() + _managementFeeShares();
        uint128 rate = uint128(plasmaVault.convertToAssets(10 ** plasmaVault.decimals() * scale));

        (bool ok, bytes memory ret) = address(feeManager).staticcall(
            abi.encodeWithSignature(
                "pendingPerformanceFeeShares(uint128,uint256,uint256)",
                rate,
                supply,
                PERFORMANCE_FEE
            )
        );
        assertTrue(ok, "FeeManager.pendingPerformanceFeeShares exists");
        uint256 previewShares = abi.decode(ret, (uint256));

        vm.prank(address(plasmaVault));
        (address recipient, uint256 feeShares) = feeManager.calculateAndUpdatePerformanceFee(
            rate,
            supply,
            PERFORMANCE_FEE,
            _assetDecimals()
        );

        assertGt(feeShares, 0, "precondition: a performance fee is owed");
        assertEq(recipient, feeManager.PERFORMANCE_FEE_ACCOUNT(), "fee goes to the performance fee account");
        assertEq(previewShares, feeShares, "the view sizes the same fee shares");

        /// @dev the mutating call moved the high-water mark to the rate after the mint: no fee is owed at that rate
        uint128 highWaterMark = feeManager.getPlasmaVaultHighWaterMarkPerformanceFee().highWaterMark;
        assertLt(highWaterMark, rate, "precondition: the mark is the rate after the fee mint");
        (ok, ret) = address(feeManager).staticcall(
            abi.encodeWithSignature(
                "pendingPerformanceFeeShares(uint128,uint256,uint256)",
                highWaterMark,
                supply,
                PERFORMANCE_FEE
            )
        );
        assertTrue(ok, "view callable");
        assertEq(abi.decode(ret, (uint256)), 0, "no fee at a rate equal to the high-water mark");
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz: previews equal the results for any gain and dormancy
    // ---------------------------------------------------------------------------------------------

    function testFuzzShouldPreviewRedeemAndWithdrawExactly_whenPerformanceFeePending(
        uint256 gain_,
        uint256 dormancy_,
        uint256 fraction_
    ) public {
        gain_ = bound(gain_, 1, 500_000 * unit);
        dormancy_ = bound(dormancy_, 0, 365 days);
        fraction_ = bound(fraction_, 1, 1e18);

        vm.warp(block.timestamp + dormancy_);
        /// @dev a tiny gain may stay below the high-water mark after the management fee: exact in both cases
        asset.mint(address(plasmaVault), gain_);

        uint256 shares = Math.mulDiv(plasmaVault.balanceOf(user), fraction_, 1e18);
        vm.assume(shares > 0);
        uint256 previewAssets = plasmaVault.previewRedeem(shares);
        vm.assume(previewAssets > 0);

        uint256 snapshot = vm.snapshotState();
        vm.prank(user);
        assertEq(plasmaVault.redeem(shares, user, user), previewAssets, "redeem pays previewRedeem");
        vm.revertToState(snapshot);

        uint256 assets = previewAssets;
        uint256 previewShares = plasmaVault.previewWithdraw(assets);
        vm.prank(user);
        assertEq(plasmaVault.withdraw(assets, user, user), previewShares, "withdraw burns previewWithdraw");
    }

    // ---------------------------------------------------------------------------------------------
    // Controls: behaviour that IL-9624 does not change (pass before and after)
    // ---------------------------------------------------------------------------------------------

    /// @dev Deposits do not crystallize the performance fee (IL-8327, IL-8756), so previewDeposit and previewMint
    ///      keep pricing the management fee only and still equal deposit and mint with a fee pending
    function testShouldKeepPreviewDepositAndPreviewMint_whenPerformanceFeePending() public {
        _donate(20_000 * unit);
        _fund(user, 2 * userDeposit);

        uint256 assets = 100_000 * unit;
        uint256 previewShares = plasmaVault.previewDeposit(assets);
        uint256 snapshot = vm.snapshotState();
        vm.prank(user);
        assertEq(plasmaVault.deposit(assets, user), previewShares, "deposit mints previewDeposit");
        vm.revertToState(snapshot);

        uint256 shares = plasmaVault.balanceOf(user) / 10;
        uint256 previewAssets = plasmaVault.previewMint(shares);
        vm.prank(user);
        assertEq(plasmaVault.mint(shares, user), previewAssets, "mint takes previewMint");
    }

    /// @dev Share rate below the high-water mark (only the management fee accrued) and the HWM update interval
    ///      passed: withdraw and redeem lower the mark without a fee, and the views price no performance fee
    function testShouldPreviewExactly_whenRateBelowHighWaterMarkAndIntervalPassed() public {
        FeeManager feeManager = _feeManager();
        bytes4[] memory intervalSig = new bytes4[](1);
        intervalSig[0] = FeeManager.updateIntervalHighWaterMarkPerformanceFee.selector;
        accessManager.setTargetFunctionRole(address(feeManager), intervalSig, Roles.ATOMIST_ROLE);
        feeManager.updateIntervalHighWaterMarkPerformanceFee(1 days);
        vm.warp(block.timestamp + 2 days);

        address feeAccount = PlasmaVaultGovernance(address(plasmaVault)).getPerformanceFeeData().feeAccount;
        uint256 shares = plasmaVault.balanceOf(user) / 2;
        uint256 previewAssets = plasmaVault.previewRedeem(shares);
        assertEq(previewAssets, plasmaVault.convertToAssets(shares), "no pending performance fee is priced");

        uint256 feeSharesBefore = plasmaVault.balanceOf(feeAccount);
        vm.prank(user);
        assertEq(plasmaVault.redeem(shares, user, user), previewAssets, "redeem pays previewRedeem");
        assertEq(plasmaVault.balanceOf(feeAccount), feeSharesBefore, "no performance fee was charged");
    }

    /// @dev Only the management fee accrued since the deposits, so the share rate is below the high-water mark and no
    ///      performance fee is pending: the views equal the conversions
    function testShouldPreviewLikeConversions_whenNoPerformanceFeePending() public view {
        uint256 shares = plasmaVault.balanceOf(user) / 2;
        assertEq(plasmaVault.previewRedeem(shares), plasmaVault.convertToAssets(shares), "previewRedeem");
        assertEq(
            plasmaVault.maxWithdraw(user),
            plasmaVault.convertToAssets(plasmaVault.balanceOf(user)),
            "maxWithdraw"
        );
        uint256 assets = 100_000 * unit;
        assertEq(
            plasmaVault.previewWithdraw(assets),
            Math.mulDiv(
                assets,
                plasmaVault.totalSupply() + _managementFeeShares() + _shareScale(),
                plasmaVault.totalAssets() + 1,
                Math.Rounding.Ceil
            ),
            "previewWithdraw"
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Scenarios and helpers
    // ---------------------------------------------------------------------------------------------

    /// @dev Assets sent to the vault without shares lift the share rate above the high-water mark
    function _donate(uint256 amount_) internal {
        asset.mint(address(plasmaVault), amount_);
        assertGt(_crystallizedPerformanceFeeShares(), 0, "precondition: a performance fee is pending");
    }

    /// @dev A withdraw fee is set and an unrelated holder exits: its performance fee check runs at the high-water
    ///      mark (no fee), then its withdraw fee shares are burned, which lifts the rate above the mark
    function _setupWithdrawFeeBurnScenario() internal {
        bytes4[] memory withdrawFeeSig = new bytes4[](1);
        withdrawFeeSig[0] = WithdrawManager.updateWithdrawFee.selector;
        accessManager.setTargetFunctionRole(address(withdrawManager), withdrawFeeSig, Roles.ATOMIST_ROLE);
        withdrawManager.updateWithdrawFee(WITHDRAW_FEE);

        vm.prank(other);
        plasmaVault.withdraw(userDeposit / 2, other, other);
        assertGt(_crystallizedPerformanceFeeShares(), 0, "precondition: a performance fee is pending");
    }

    /// @dev Lets another holder crystallize the pending fees with a tiny exit in a snapshot and returns the
    ///      performance fee shares minted; the state is restored
    function _crystallizedPerformanceFeeShares() internal returns (uint256 feeShares) {
        address feeAccount = PlasmaVaultGovernance(address(plasmaVault)).getPerformanceFeeData().feeAccount;
        uint256 snapshot = vm.snapshotState();
        uint256 before = plasmaVault.balanceOf(feeAccount);
        vm.prank(other);
        plasmaVault.withdraw(unit, other, other);
        feeShares = plasmaVault.balanceOf(feeAccount) - before;
        vm.revertToState(snapshot);
    }

    /// @dev Calls withdraw one unit above maxAssets_ and returns the limit the vault enforces in the call
    function _enforcedWithdrawLimit(address owner_, uint256 maxAssets_) internal returns (uint256 enforced) {
        uint256 snapshot = vm.snapshotState();
        vm.prank(owner_);
        (bool ok, bytes memory ret) = address(plasmaVault).call(
            abi.encodeCall(PlasmaVault.withdraw, (maxAssets_ + 1, owner_, owner_))
        );
        assertFalse(ok, "withdraw above the limit reverts");
        assertEq(bytes4(ret), EXCEEDED_MAX_WITHDRAW, "ERC4626ExceededMaxWithdraw");
        (, , enforced) = abi.decode(_slice(ret, 4), (address, uint256, uint256));
        vm.revertToState(snapshot);
    }

    /// @dev IL-8870 (D-002): management fee shares V = floor(min(F, G) * (S + scale) / (G - min(F, G) + 1)),
    ///      recomputed from the accrued fee F, the supply S and the gross assets G, not through the vault
    function _managementFeeShares() internal view returns (uint256) {
        uint256 gross = plasmaVault.totalAssets();
        uint256 fee = plasmaVault.getUnrealizedManagementFee();
        if (fee == 0) {
            return 0;
        }
        if (fee > gross) {
            fee = gross;
        }
        return Math.mulDiv(fee, plasmaVault.totalSupply() + _shareScale(), gross - fee + 1);
    }

    function _shareScale() internal view returns (uint256) {
        return 10 ** (plasmaVault.decimals() - asset.decimals());
    }

    function _feeManager() internal view returns (FeeManager) {
        return
            FeeManager(
                FeeAccount(PlasmaVaultGovernance(address(plasmaVault)).getPerformanceFeeData().feeAccount).FEE_MANAGER()
            );
    }

    function _slice(bytes memory data_, uint256 start_) private pure returns (bytes memory out) {
        out = new bytes(data_.length - start_);
        for (uint256 i; i < out.length; ++i) {
            out[i] = data_[start_ + i];
        }
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

    function _deploy() internal {
        asset = new MockERC20Decimals("Mock Asset", "mAST", _assetDecimals());

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

        usersToRoles.superAdmin = atomist;
        usersToRoles.atomist = atomist;
        address[] memory alphas = new address[](1);
        alphas[0] = alpha;
        usersToRoles.alphas = alphas;
        accessManager = RoleLib.createAccessManager(usersToRoles, 0, vm);
        withdrawManager = new WithdrawManager(address(accessManager));

        plasmaVault = PlasmaVaultCloneLib.newPlasmaVault();
        plasmaVault.proxyInitialize(
            PlasmaVaultInitData(
                "IPOR Fusion mAST",
                "ipfmAST",
                address(asset),
                address(priceOracleMiddlewareProxy),
                FeeConfig({
                    iporDaoManagementFee: MANAGEMENT_FEE,
                    iporDaoPerformanceFee: PERFORMANCE_FEE,
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
    }
}

/// @notice 6-decimal asset (USDC-like): shares have 8 decimals
contract PlasmaVaultPreviewPerformanceFee6DecimalsTest is PlasmaVaultPreviewPerformanceFeeTestBase {
    function _assetDecimals() internal pure override returns (uint8) {
        return 6;
    }
}

/// @notice 18-decimal asset (WETH-like): shares have 20 decimals
contract PlasmaVaultPreviewPerformanceFee18DecimalsTest is PlasmaVaultPreviewPerformanceFeeTestBase {
    function _assetDecimals() internal pure override returns (uint8) {
        return 18;
    }
}
