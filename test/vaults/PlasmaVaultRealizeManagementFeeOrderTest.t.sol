// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {
    PlasmaVault,
    FuseAction,
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
import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {ZeroBalanceFuse} from "../../contracts/fuses/ZeroBalanceFuse.sol";
import {RealizeManagementFeeFuse} from "../../contracts/fuses/management_fee/RealizeManagementFeeFuse.sol";
import {PlasmaVaultConfigurator} from "../utils/PlasmaVaultConfigurator.sol";
import {RoleLib, UsersToRoles} from "../RoleLib.sol";
import {MockERC20Decimals} from "../unitTest/fuses/term_finance/mocks/MockERC20Decimals.sol";
import {MarketValueHolder, HolderBalanceFuse} from "./PlasmaVaultManagementFeePerformanceFeeTest.t.sol";
import {PlasmaVaultCloneLib} from "../test_helpers/PlasmaVaultCloneLib.sol";

/// @notice Test fuse that moves idle assets out of the vault into a "market" (a sink address) and records the
///         same amount as the market value in the holder. The value is recorded in the holder at once, but the
///         vault keeps the OLD stored market balance until the post-execute refresh, so while the batch runs the
///         gross assets the vault reads (idle + stored market balances) are short by the amount in flight.
contract MoveAssetsToMarketFuse {
    uint256 public immutable MARKET_ID;
    address public immutable ASSET;
    address public immutable SINK;
    MarketValueHolder public immutable HOLDER;

    /// @dev holder value is USD with 18 decimals; the asset has 6 decimals at 1 USD
    uint256 private constant _WAD_PER_ASSET_UNIT = 1e12;

    constructor(uint256 marketId_, address asset_, address sink_, MarketValueHolder holder_) {
        MARKET_ID = marketId_;
        ASSET = asset_;
        SINK = sink_;
        HOLDER = holder_;
    }

    /// @dev Runs by delegatecall in the vault
    function enter(uint256 amount_) external {
        require(IERC20(ASSET).transfer(SINK, amount_), "transfer failed");
        HOLDER.set(HOLDER.value() + amount_ * _WAD_PER_ASSET_UNIT);
    }
}

/// @title PlasmaVaultRealizeManagementFeeOrderTest
/// @notice IL-8870 (T19, CR #1 / A1): characterization of the order rule of RealizeManagementFeeFuse in one execute
///         (D-026: the fuse must be the only action of its own top-level execute). The vault does not enforce the
///         rule, it is documented. `execute` reads the gross assets as idle balance plus the STORED market
///         balances, and refreshes the stored balances only after the last action, so an action that moves idle
///         assets into a market before the fuse leaves the gross assets the fuse prices on short by the amount in
///         flight.
/// @dev Notation: S = minted supply, G = gross assets, F = realized fee (pending fee P + accrual), off = 100 (share
///      scale: 6 asset decimals, 8 share decimals). D-002: V = floor(min(F, G) * (S + off) / (G - min(F, G) + 1)).
///      Every expected value comes from `_feeShares`, computed here independently of the vault's helper.
///      Numbers (S = 1e14, G = 1,000,000 USDC, F = about 877 USDC): with the fuse first V is about 0.0877% of S
///      and the fee account is worth F. With 999,000 USDC moved first, G seen by the fuse is 1,000 USDC and V is
///      about 4.6 times S: after the refresh the fee account is worth at least 100 times F.
contract PlasmaVaultRealizeManagementFeeOrderTest is Test {
    address public atomist = address(this);
    address public alpha = address(0x1);
    address public user = address(0xA11CE);
    address public sink = address(0xDEAD1);

    /// @dev 2% per year, FeeManager percentages use 2 decimals (10000 = 100%)
    uint256 public constant MANAGEMENT_FEE = 200;
    uint256 public constant PERFORMANCE_FEE = 1000;
    uint256 public constant USER_DEPOSIT = 1_000_000e6;
    uint256 public constant MARKET_ID = 100;
    /// @dev share scale multiplier: 10 ** (share decimals - asset decimals)
    uint256 public constant SHARE_SCALE = 100;
    uint256 public constant ONE_SHARE = 1e8;
    /// @dev the pending fee is created after this long, then one more day of accrual lands on top of it
    uint256 public constant PENDING_PERIOD = 15 days;
    uint256 public constant EXTRA_ACCRUAL = 1 days;

    MockERC20Decimals public asset;
    UsersToRoles public usersToRoles;
    IporFusionAccessManager public accessManager;
    PlasmaVault public plasmaVault;
    MarketValueHolder public holder;
    MoveAssetsToMarketFuse public moveFuse;
    RealizeManagementFeeFuse public realizeFuse;
    FeeManager public feeManager;
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
        sources[0] = address(new FixedValuePriceFeed(1e18));
        priceOracleMiddlewareProxy.setAssetsPricesSources(assets, sources);

        accessManager = _createAccessManager();
        WithdrawManager withdrawManager = new WithdrawManager(address(accessManager));

        plasmaVault = PlasmaVaultCloneLib.newPlasmaVault();
        plasmaVault.proxyInitialize(
            PlasmaVaultInitData(
                "IPOR Fusion mUSDC",
                "ipfmUSDC",
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

        holder = new MarketValueHolder();
        moveFuse = new MoveAssetsToMarketFuse(MARKET_ID, address(asset), sink, holder);
        realizeFuse = new RealizeManagementFeeFuse();

        address[] memory fuses = new address[](2);
        fuses[0] = address(moveFuse);
        fuses[1] = address(realizeFuse);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](2);
        balanceFuses[0] = MarketBalanceFuseConfig(MARKET_ID, address(new HolderBalanceFuse(MARKET_ID, holder)));
        balanceFuses[1] = MarketBalanceFuseConfig(
            IporFusionMarkets.ZERO_BALANCE_MARKET,
            address(new ZeroBalanceFuse(IporFusionMarkets.ZERO_BALANCE_MARKET))
        );

        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            atomist,
            address(plasmaVault),
            fuses,
            balanceFuses,
            new MarketSubstratesConfig[](0)
        );

        managementFeeAccount = PlasmaVaultGovernance(address(plasmaVault)).getManagementFeeData().feeAccount;
        feeManager = FeeManager(FeeAccount(managementFeeAccount).FEE_MANAGER());

        asset.mint(user, USER_DEPOSIT);
        vm.startPrank(user);
        asset.approve(address(plasmaVault), type(uint256).max);
        plasmaVault.deposit(USER_DEPOSIT, user);
        vm.stopPrank();

        /// @dev a pending fee through the production checkpoint: the FeeManager (TECH_MANAGEMENT_FEE_MANAGER_ROLE)
        ///      reconfigures the same rate, which stores the accrued fee as pending, then one more day accrues on top
        ///      of it. Called directly: FeeManager.updateManagementFee reverts while the fee would mint a share
        ///      (IL-9431 gate); the fee account holds no shares here, so its harvest would change nothing.
        vm.warp(block.timestamp + PENDING_PERIOD);
        uint256 currentRate = PlasmaVaultGovernance(address(plasmaVault)).getManagementFeeData().feeInPercentage;
        vm.prank(address(feeManager));
        PlasmaVaultGovernance(address(plasmaVault)).configureManagementFee(managementFeeAccount, currentRate);
        vm.warp(block.timestamp + EXTRA_ACCRUAL);
    }

    // ---------------------------------------------------------------------------------------------------------
    // fuse first (not the documented rule: D-026 says alone; an asset-neutral action after it leaves the fee exact)
    // ---------------------------------------------------------------------------------------------------------

    /// @notice execute([fuse, move 999,000 USDC into the market]): the fuse prices F on the full G, mints exactly the
    ///         D-002 shares, clears the pending fee, restarts the clock, and the fee account is worth F (within one
    ///         asset unit) after the refresh. The unit price does not move.
    function testShouldMintExactFeeShares_whenFuseRunsFirstThenAssetMovingAction() public {
        uint256 supply = plasmaVault.totalSupply();
        uint256 gross = plasmaVault.totalAssets();
        uint256 fee = plasmaVault.getUnrealizedManagementFee();
        uint256 pending = _pending();
        uint256 priceBefore = plasmaVault.convertToAssets(ONE_SHARE);
        uint256 moved = 999_000e6;

        assertGt(pending, 0, "precondition: the checkpoint left a pending fee");
        assertGt(fee, pending, "precondition: accrual on top of the pending fee");
        assertEq(plasmaVault.balanceOf(managementFeeAccount), 0, "precondition: nothing minted yet");
        uint256 expectedShares = _feeShares(fee, supply, gross);
        assertGt(expectedShares, 0, "precondition: fee shares exist");

        vm.prank(alpha);
        plasmaVault.execute(_actions(true, moved));

        assertEq(plasmaVault.balanceOf(managementFeeAccount), expectedShares, "fee shares equal the D-002 model");
        assertEq(plasmaVault.totalSupply(), supply + expectedShares, "supply grew by the fee shares only");
        assertEq(_pending(), 0, "pending fee cleared");
        assertEq(_lastUpdate(), block.timestamp, "fee clock restarted");
        assertEq(plasmaVault.getUnrealizedManagementFee(), 0, "nothing accrued after the realization");
        assertEq(plasmaVault.totalAssets(), gross, "gross assets unchanged by the move");
        assertApproxEqAbs(
            plasmaVault.convertToAssets(plasmaVault.balanceOf(managementFeeAccount)),
            fee,
            1,
            "fee account is worth F"
        );
        assertEq(plasmaVault.convertToAssets(ONE_SHARE), priceBefore, "unit price unchanged");
    }

    // ---------------------------------------------------------------------------------------------------------
    // asset-moving action first (the documented misuse)
    // ---------------------------------------------------------------------------------------------------------

    /// @notice Characterization of the hazard the D-026 rule avoids (the vault does not prevent it): the action moves
    ///         999,000 USDC into the market, so the fuse reads G_mid = 1,000 USDC and mints the D-002 shares on
    ///         that G_mid (F itself is the pending fee plus the accrual on G_mid). After the refresh the fee account is worth at least 100 times F.
    function testShouldOverMintFeeShares_whenAssetMovingActionRunsBeforeFuse() public {
        uint256 supply = plasmaVault.totalSupply();
        uint256 gross = plasmaVault.totalAssets();
        uint256 fee = plasmaVault.getUnrealizedManagementFee();
        uint256 moved = 999_000e6;
        /// @dev gross assets the fuse sees: the idle balance left after the move, the stored market balance is 0
        uint256 grossMid = gross - moved;
        assertLt(
            _pending() + _accrual(grossMid),
            grossMid,
            "precondition: F below G_mid, so the clamp is not the cause"
        );

        /// @dev the accrual part of F is charged on the gross assets the fuse reads, the pending part is fixed
        uint256 feeMid = _pending() + _accrual(grossMid);
        assertEq(fee, _pending() + _accrual(gross), "independent F model equals the vault's accrued fee");

        uint256 correctShares = _feeShares(fee, supply, gross);
        uint256 expectedShares = _feeShares(feeMid, supply, grossMid);
        assertGt(expectedShares, 100 * correctShares, "precondition: the model over-mints");

        vm.prank(alpha);
        plasmaVault.execute(_actions(false, moved));

        assertEq(plasmaVault.balanceOf(managementFeeAccount), expectedShares, "fee shares equal the model on G_mid");
        assertEq(plasmaVault.totalAssets(), gross, "the refresh restored the gross assets");
        assertGe(
            plasmaVault.convertToAssets(plasmaVault.balanceOf(managementFeeAccount)),
            100 * fee,
            "fee account is worth at least 100 times F after the refresh"
        );
    }

    /// @notice Same misuse with every asset moved: G_mid == 0, so the realization drops the pending fee and the
    ///         accrual, restarts the clock and mints nothing. The fee is lost for good.
    function testShouldDropPendingAndAccrual_whenAssetMovingActionBeforeFuseLeavesZeroGross() public {
        uint256 gross = plasmaVault.totalAssets();
        uint256 fee = plasmaVault.getUnrealizedManagementFee();
        assertGt(_pending(), 0, "precondition: pending fee");
        assertGt(fee, _pending(), "precondition: accrual on top of the pending fee");

        vm.prank(alpha);
        plasmaVault.execute(_actions(false, gross));

        assertEq(plasmaVault.totalAssets(), gross, "the refresh restored the gross assets");
        assertEq(plasmaVault.balanceOf(managementFeeAccount), 0, "nothing minted");
        assertEq(_pending(), 0, "pending fee dropped");
        assertEq(_lastUpdate(), block.timestamp, "fee clock restarted");
        assertEq(plasmaVault.getUnrealizedManagementFee(), 0, "the accrued fee is gone");
    }

    // ---------------------------------------------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------------------------------------------

    /// @dev D-002, computed independently of the vault: F is clamped to G, the denominator is G - F + 1
    function _feeShares(uint256 fee_, uint256 supply_, uint256 gross_) internal pure returns (uint256) {
        if (fee_ == 0 || supply_ == 0 || gross_ == 0) {
            return 0;
        }
        uint256 clamped = fee_ > gross_ ? gross_ : fee_;
        return Math.mulDiv(clamped, supply_ + SHARE_SCALE, gross_ - clamped + 1);
    }

    /// @dev Management fee accrued on `assets_` since the fee clock (the checkpoint) for EXTRA_ACCRUAL seconds
    function _accrual(uint256 assets_) internal pure returns (uint256) {
        return Math.mulDiv(assets_ * EXTRA_ACCRUAL, MANAGEMENT_FEE, 365 days * 1e4);
    }

    function _actions(bool fuseFirst_, uint256 moved_) internal view returns (FuseAction[] memory actions) {
        actions = new FuseAction[](2);
        FuseAction memory move = FuseAction(address(moveFuse), abi.encodeCall(MoveAssetsToMarketFuse.enter, (moved_)));
        FuseAction memory realize = FuseAction(address(realizeFuse), abi.encodeWithSignature("enter()"));
        actions[0] = fuseFirst_ ? realize : move;
        actions[1] = fuseFirst_ ? move : realize;
    }

    /// @dev Storage slot of the pending management fee (PlasmaVaultStorageLib.PENDING_MANAGEMENT_FEE_SLOT)
    function _pending() internal view returns (uint256) {
        return
            uint256(vm.load(address(plasmaVault), 0x612d50d27ffbb749a9804ec5bba7933bff2377ff69afba55e14b5cf7180bff00));
    }

    function _lastUpdate() internal view returns (uint256) {
        return PlasmaVaultGovernance(address(plasmaVault)).getManagementFeeData().lastUpdateTimestamp;
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
