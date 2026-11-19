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
import {Roles} from "../../contracts/libraries/Roles.sol";
import {PlasmaVaultConfigurator} from "../utils/PlasmaVaultConfigurator.sol";
import {RoleLib, UsersToRoles} from "../RoleLib.sol";
import {MockERC20Decimals} from "../unitTest/fuses/term_finance/mocks/MockERC20Decimals.sol";

/// @title PlasmaVaultMaxViewsReleasedReserveFeesTestBase
/// @notice IL-9624 follow-up: with released request shares R on a WithdrawManager wired to the vault, `maxRedeem`
///         and `maxWithdraw` cap the owner's gross shares by the reserve limit `max(C - R, 0)`, where C prices all
///         assets on the supply after both pending fees (the management fee shares and the performance fee shares
///         that the exit mints before it pays). `redeem(maxRedeem)` and `withdraw(maxWithdraw)` pass, and one unit
///         more is refused by the WithdrawManager (`WithdrawManagerInvalidSharesToRelease`), not by the vault limit.
///         A pair "passes / one more fails" catches both an over-stated and an under-stated limit, for instance a
///         supply without the performance fee shares.
/// @dev Fixture: the deployment of `PlasmaVaultPreviewPerformanceFeeTest` (management fee 2 %, performance fee 10 %,
///      no redemption delay) plus a WithdrawManager that this suite wires itself (`updatePlasmaVaultAddress`) and a
///      real `releaseFunds` call by ALPHA, so R passes the supply bound of the WithdrawManager. All assets stay idle
///      (no market), so the limit is exact. The owner holds 3 000 000 assets and another holder 1 000 000. Every
///      scenario with fees asserts, before R is released, that both the management fee shares and the performance
///      fee shares are pending and positive, and that the owner's balance exceeds the cap by at least five whole
///      assets in shares, so a probe one unit above the cap reaches the WithdrawManager and not the balance limit.
///      Each boundary probe starts from the same restored state (`vm.snapshotState` / `vm.revertToState`).
abstract contract PlasmaVaultMaxViewsReleasedReserveFeesTestBase is Test {
    address public atomist = address(this);
    address public alpha = address(0x1);
    address public user = address(0xA11CE);
    address public other = address(0xB0B);

    /// @dev 2% per year, FeeManager percentages use 2 decimals (10000 = 100%)
    uint256 public constant MANAGEMENT_FEE = 200;
    /// @dev 10%
    uint256 public constant PERFORMANCE_FEE = 1000;

    bytes4 internal constant INVALID_SHARES_TO_RELEASE =
        bytes4(keccak256("WithdrawManagerInvalidSharesToRelease(uint256,uint256,uint256)"));
    bytes4 internal constant EXCEEDED_MAX_REDEEM =
        bytes4(keccak256("ERC4626ExceededMaxRedeem(address,uint256,uint256)"));
    bytes4 internal constant EXCEEDED_MAX_WITHDRAW =
        bytes4(keccak256("ERC4626ExceededMaxWithdraw(address,uint256,uint256)"));

    MockERC20Decimals public asset;
    UsersToRoles internal usersToRoles;
    IporFusionAccessManager public accessManager;
    WithdrawManager public withdrawManager;
    PlasmaVault public plasmaVault;

    /// @dev one whole asset in its smallest unit
    uint256 internal unit;

    function _assetDecimals() internal pure virtual returns (uint8);

    /// @dev withdraw fee in WAD (0 or 1e16)
    function _withdrawFee() internal pure virtual returns (uint256);

    function setUp() public {
        unit = 10 ** _assetDecimals();
        _deploy();
        _wireWithdrawManager();

        _fund(user, 3_000_000 * unit);
        _fund(other, 1_000_000 * unit);
        _deposit(user, 3_000_000 * unit);
        _deposit(other, 1_000_000 * unit);
    }

    // ---------------------------------------------------------------------------------------------
    // Reserve with pending management and performance fees
    // ---------------------------------------------------------------------------------------------

    /// @dev Shares of the owner above the cap are refused by the WithdrawManager, the cap itself passes
    function testShouldRedeemMaxRedeemAndRefuseOneMore_whenBothFeesPendingAndReserveBinds() public {
        _prepareScenario(100_000 * unit, 30 days, _supply() / 2);
        uint256 maxShares = plasmaVault.maxRedeem(user);
        _assertCapBinds(maxShares);

        _assertRedeemBoundary(maxShares);
    }

    function testShouldWithdrawMaxWithdrawAndRefuseOneMore_whenBothFeesPendingAndReserveBinds() public {
        _prepareScenario(100_000 * unit, 30 days, _supply() / 2);
        uint256 maxShares = plasmaVault.maxRedeem(user);
        _assertCapBinds(maxShares);

        _assertWithdrawBoundary(plasmaVault.maxWithdraw(user));
    }

    function testShouldPriceMaxWithdrawAsPreviewRedeemOfMaxRedeem_whenBothFeesPendingAndReserveBinds() public {
        _prepareScenario(100_000 * unit, 30 days, _supply() / 2);
        uint256 maxShares = plasmaVault.maxRedeem(user);
        _assertCapBinds(maxShares);

        assertEq(plasmaVault.maxWithdraw(user), plasmaVault.previewRedeem(maxShares), "maxWithdraw = previewRedeem");
        assertGt(plasmaVault.maxWithdraw(user), 0, "maxWithdraw positive");
    }

    /// @dev Control: with nothing released the views keep the balance, with both fees pending
    function testShouldKeepBalanceInMaxViews_whenBothFeesPendingAndNothingReleased() public {
        _prepareScenario(100_000 * unit, 30 days, 0);

        uint256 balance = plasmaVault.balanceOf(user);
        assertEq(withdrawManager.getSharesToRelease(), 0, "precondition: nothing released");
        assertEq(plasmaVault.maxRedeem(user), balance, "maxRedeem is the balance");
        assertEq(plasmaVault.maxWithdraw(user), plasmaVault.previewRedeem(balance), "maxWithdraw prices the balance");
    }

    /// @dev Fuzz. Ranges (the fee-free assertions of the scenario hold in all of them): profit donated to the vault
    ///      6.25 % to 25 % of its 4 000 000 assets (above the 4 % management fee of the longest period, so the rate
    ///      ends above the high-water mark and a performance fee is pending); time since the deposits one day to two years (the management fee is pending); released shares
    ///      45 % to 90 % of the supply (the owner holds 75 % of the supply, so the balance stays above the cap with
    ///      a margin, and the cap is positive). Both maxima are positive; both pairs of boundaries are probed from
    ///      the same restored state.
    function testFuzzShouldRedeemAndWithdrawTheCapAndRefuseOneMore(
        uint256 profit_,
        uint256 elapsed_,
        uint256 released_
    ) public {
        uint256 profit = bound(profit_, 250_000 * unit, 1_000_000 * unit);
        uint256 elapsed = bound(elapsed_, 1 days, 730 days);
        uint256 reserve = bound(released_, (_supply() * 45) / 100, (_supply() * 90) / 100);

        _prepareScenario(profit, elapsed, reserve);

        uint256 maxShares = plasmaVault.maxRedeem(user);
        uint256 maxAssets = plasmaVault.maxWithdraw(user);
        _assertCapBinds(maxShares);
        assertGt(maxAssets, 0, "maxWithdraw positive");
        assertEq(maxAssets, plasmaVault.previewRedeem(maxShares), "maxWithdraw = previewRedeem(maxRedeem)");

        _assertRedeemBoundary(maxShares);
        _assertWithdrawBoundary(maxAssets);
    }

    // ---------------------------------------------------------------------------------------------
    // Boundary probes (each from the same restored state)
    // ---------------------------------------------------------------------------------------------

    function _assertRedeemBoundary(uint256 maxShares_) internal {
        uint256 maxAssets = plasmaVault.maxWithdraw(user);
        uint256 snapshot = vm.snapshotState();

        uint256 sharesBefore = plasmaVault.balanceOf(user);
        vm.prank(user);
        uint256 paid = plasmaVault.redeem(maxShares_, user, user);
        /// @dev redeem may pay one asset unit more than previewRedeem (rounding of the fee split), never less
        assertGe(paid, maxAssets, "redeem(maxRedeem) pays at least maxWithdraw");
        assertLe(paid, maxAssets + 1, "redeem(maxRedeem) pays at most one unit more than maxWithdraw");
        assertEq(sharesBefore - plasmaVault.balanceOf(user), maxShares_, "redeem(maxRedeem) burns maxRedeem");
        vm.revertToState(snapshot);

        vm.prank(user);
        (bool ok, bytes memory ret) = address(plasmaVault).call(
            abi.encodeCall(PlasmaVault.redeem, (maxShares_ + 1, user, user))
        );
        assertFalse(ok, "redeem(maxRedeem + 1) reverts");
        assertEq(bytes4(ret), INVALID_SHARES_TO_RELEASE, "the WithdrawManager refuses, not the vault limit");
        assertTrue(bytes4(ret) != EXCEEDED_MAX_REDEEM, "not ERC4626ExceededMaxRedeem");
        vm.revertToState(snapshot);
    }

    function _assertWithdrawBoundary(uint256 maxAssets_) internal {
        uint256 snapshot = vm.snapshotState();

        uint256 balanceBefore = asset.balanceOf(user);
        vm.prank(user);
        plasmaVault.withdraw(maxAssets_, user, user);
        assertEq(asset.balanceOf(user) - balanceBefore, maxAssets_, "withdraw(maxWithdraw) pays maxWithdraw");
        vm.revertToState(snapshot);

        vm.prank(user);
        (bool ok, bytes memory ret) = address(plasmaVault).call(
            abi.encodeCall(PlasmaVault.withdraw, (maxAssets_ + 1, user, user))
        );
        assertFalse(ok, "withdraw(maxWithdraw + 1) reverts");
        assertEq(bytes4(ret), INVALID_SHARES_TO_RELEASE, "the WithdrawManager refuses, not the vault limit");
        assertTrue(bytes4(ret) != EXCEEDED_MAX_WITHDRAW, "not ERC4626ExceededMaxWithdraw");
        vm.revertToState(snapshot);
    }

    // ---------------------------------------------------------------------------------------------
    // Scenario and helpers
    // ---------------------------------------------------------------------------------------------

    /// @dev Time passes (management fee), assets are donated (share rate above the high-water mark, performance
    ///      fee), then ALPHA releases `released_` shares through the real `releaseFunds` (0 = nothing released).
    ///      Asserts both pending fees before the release
    function _prepareScenario(uint256 profit_, uint256 elapsed_, uint256 released_) internal {
        vm.warp(block.timestamp + elapsed_);
        asset.mint(address(plasmaVault), profit_);

        assertGt(_managementFeeShares(), 0, "precondition: management fee shares are pending");
        assertGt(_crystallizedPerformanceFeeShares(), 0, "precondition: performance fee shares are pending");

        if (released_ > 0) {
            vm.prank(alpha);
            withdrawManager.releaseFunds(block.timestamp - 1, released_);
            assertEq(withdrawManager.getSharesToRelease(), released_, "precondition: shares released");
        }
    }

    /// @dev The cap binds with a margin: positive, below the balance by at least five whole assets in shares
    function _assertCapBinds(uint256 maxShares_) internal view {
        assertGt(maxShares_, 0, "precondition: maxRedeem positive");
        assertGe(
            plasmaVault.balanceOf(user),
            maxShares_ + 5 * unit * _shareScale(),
            "precondition: the balance exceeds the cap by at least five whole assets"
        );
    }

    function _supply() internal view returns (uint256) {
        return plasmaVault.totalSupply();
    }

    /// @dev Performance fee shares that an exit mints now: another holder withdraws one unit in a snapshot (the state
    ///      is restored)
    function _crystallizedPerformanceFeeShares() internal returns (uint256 feeShares) {
        address feeAccount = PlasmaVaultGovernance(address(plasmaVault)).getPerformanceFeeData().feeAccount;
        uint256 snapshot = vm.snapshotState();
        uint256 before = plasmaVault.balanceOf(feeAccount);
        vm.prank(other);
        plasmaVault.withdraw(unit, other, other);
        feeShares = plasmaVault.balanceOf(feeAccount) - before;
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

    function _deposit(address user_, uint256 amount_) internal {
        vm.prank(user_);
        plasmaVault.deposit(amount_, user_);
    }

    function _fund(address user_, uint256 amount_) internal {
        asset.mint(user_, amount_);
        vm.prank(user_);
        asset.approve(address(plasmaVault), type(uint256).max);
    }

    /// @dev `RoleLib` and the configurator do not call `updatePlasmaVaultAddress`: an unwired manager skips the supply
    ///      bound of `releaseFunds`. The ATOMIST role is mapped to the selectors like for `updateWithdrawFee`
    function _wireWithdrawManager() internal {
        bytes4[] memory atomistSigs = new bytes4[](2);
        atomistSigs[0] = WithdrawManager.updateWithdrawFee.selector;
        atomistSigs[1] = WithdrawManager.updatePlasmaVaultAddress.selector;
        accessManager.setTargetFunctionRole(address(withdrawManager), atomistSigs, Roles.ATOMIST_ROLE);

        withdrawManager.updatePlasmaVaultAddress(address(plasmaVault));
        assertEq(withdrawManager.getPlasmaVaultAddress(), address(plasmaVault), "withdraw manager wired");

        if (_withdrawFee() > 0) {
            withdrawManager.updateWithdrawFee(_withdrawFee());
        }
        assertEq(withdrawManager.getWithdrawFee(), _withdrawFee(), "withdraw fee");
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

/// @notice 6-decimal asset (USDC-like), no withdraw fee
contract PlasmaVaultMaxViewsReleasedReserveFees6DecimalsTest is PlasmaVaultMaxViewsReleasedReserveFeesTestBase {
    function _assetDecimals() internal pure override returns (uint8) {
        return 6;
    }

    function _withdrawFee() internal pure override returns (uint256) {
        return 0;
    }
}

/// @notice 6-decimal asset, 1 % withdraw fee
contract PlasmaVaultMaxViewsReleasedReserveFees6DecimalsWithdrawFeeTest is
    PlasmaVaultMaxViewsReleasedReserveFeesTestBase
{
    function _assetDecimals() internal pure override returns (uint8) {
        return 6;
    }

    function _withdrawFee() internal pure override returns (uint256) {
        return 1e16;
    }
}

/// @notice 18-decimal asset (WETH-like), no withdraw fee
contract PlasmaVaultMaxViewsReleasedReserveFees18DecimalsTest is PlasmaVaultMaxViewsReleasedReserveFeesTestBase {
    function _assetDecimals() internal pure override returns (uint8) {
        return 18;
    }

    function _withdrawFee() internal pure override returns (uint256) {
        return 0;
    }
}

/// @notice 18-decimal asset, 1 % withdraw fee
contract PlasmaVaultMaxViewsReleasedReserveFees18DecimalsWithdrawFeeTest is
    PlasmaVaultMaxViewsReleasedReserveFeesTestBase
{
    function _assetDecimals() internal pure override returns (uint8) {
        return 18;
    }

    function _withdrawFee() internal pure override returns (uint256) {
        return 1e16;
    }
}
