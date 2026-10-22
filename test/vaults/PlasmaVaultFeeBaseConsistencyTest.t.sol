// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";

import {
    PlasmaVault,
    MarketBalanceFuseConfig,
    MarketSubstratesConfig,
    PlasmaVaultInitData
} from "contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "contracts/vaults/PlasmaVaultGovernance.sol";
import {PriceOracleMiddleware} from "contracts/price_oracle/PriceOracleMiddleware.sol";
import {FixedValuePriceFeed} from "contracts/price_oracle/price_feed/FixedValuePriceFeed.sol";
import {IporFusionAccessManager} from "contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "contracts/managers/withdraw/WithdrawManager.sol";
import {FeeManagerFactory, FeeConfig} from "contracts/managers/fee/FeeManagerFactory.sol";
import {FeeManager} from "contracts/managers/fee/FeeManager.sol";
import {FeeAccount} from "contracts/managers/fee/FeeAccount.sol";
import {Roles} from "contracts/libraries/Roles.sol";
import {PlasmaVaultConfigurator} from "test/utils/PlasmaVaultConfigurator.sol";
import {RoleLib, UsersToRoles} from "test/RoleLib.sol";
import {MockERC20Decimals} from "test/unitTest/fuses/term_finance/mocks/MockERC20Decimals.sol";
import {PlasmaVaultGovernance as Governance} from "contracts/vaults/PlasmaVaultGovernance.sol";
import {FuseAction} from "contracts/vaults/PlasmaVault.sol";
import {InstantWithdrawalFusesParamsStruct} from "contracts/libraries/PlasmaVaultLib.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {IFuseCommon} from "contracts/fuses/IFuseCommon.sol";
import {
    MockExternalMarket,
    MockMarketSupplyFuse,
    MockMarketBalanceFuse
} from "test/vaults/PlasmaVaultRedeemFromRequestReentrancy.t.sol";

/// @title IL-8743 / IL-8751: the deposit and withdraw fees are charged on the same (gross) base on every entry
/// @notice deposit and redeem charge the fee as a share of the GROSS shares. mint and withdraw used to charge it on
///         the NET shares (effective fee f/(1+f) and w/(1+w)). No fork: real PlasmaVault, WithdrawManager and
///         FeeManagerFactory with a mock underlying.
abstract contract PlasmaVaultFeeBaseConsistencyBase is Test {
    address public atomist = address(this);
    address public alpha = address(0x1);
    address public seeder = address(0x5EED);
    address public depositUser = address(0xD0D0);
    address public mintUser = address(0xA11CE);
    address public carol = address(0xCA201);

    uint256 public constant DEPOSIT_FEE = 1e17;

    MockERC20Decimals public asset;
    UsersToRoles public usersToRoles;
    PlasmaVault public plasmaVault;
    IporFusionAccessManager public accessManager;
    WithdrawManager public withdrawManager;
    FeeManager public feeManager;

    function _assetDecimals() internal pure virtual returns (uint8);

    function _unit() internal view returns (uint256) {
        return 10 ** uint256(asset.decimals());
    }

    function setUp() public {
        asset = new MockERC20Decimals("Mock Asset", "mAsset", _assetDecimals());

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

        plasmaVault = new PlasmaVault();
        plasmaVault.proxyInitialize(
            PlasmaVaultInitData(
                "IPOR Fusion mAsset",
                "ipfmAsset",
                address(asset),
                address(priceOracleMiddlewareProxy),
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

        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            atomist,
            address(plasmaVault),
            new address[](0),
            new MarketBalanceFuseConfig[](0),
            new MarketSubstratesConfig[](0)
        );

        feeManager = FeeManager(
            FeeAccount(PlasmaVaultGovernance(address(plasmaVault)).getPerformanceFeeData().feeAccount).FEE_MANAGER()
        );

        bytes4[] memory feeSig = new bytes4[](1);
        feeSig[0] = FeeManager.setDepositFee.selector;
        accessManager.setTargetFunctionRole(address(feeManager), feeSig, Roles.ATOMIST_ROLE);

        bytes4[] memory withdrawFeeSig = new bytes4[](1);
        withdrawFeeSig[0] = WithdrawManager.updateWithdrawFee.selector;
        accessManager.setTargetFunctionRole(address(withdrawManager), withdrawFeeSig, Roles.ATOMIST_ROLE);

        _fund(seeder, 1_000_000_000 * _unit());
        _fund(depositUser, 1_000_000_000 * _unit());
        _fund(mintUser, 1_000_000_000 * _unit());
        _fund(carol, 1_000_000_000 * _unit());
    }

    // ---------------------------------------------------------------------------------------------
    // (1) IL-8743 PoC c291af5a: mint charges the same fee as deposit
    // ---------------------------------------------------------------------------------------------

    function test_mintChargesTheSameDepositFeeAsDeposit() public {
        _deposit(seeder, 1_000_000 * _unit());

        feeManager.setDepositFee(DEPOSIT_FEE);

        // deposit path
        uint256 wmBefore = plasmaVault.balanceOf(address(withdrawManager));
        uint256 assetsBefore = asset.balanceOf(depositUser);
        uint256 depositAmount = 1_000_000 * _unit();
        vm.prank(depositUser);
        uint256 depositUserShares = plasmaVault.deposit(depositAmount, depositUser);
        uint256 depositPaid = assetsBefore - asset.balanceOf(depositUser);
        uint256 depositFeeShares = plasmaVault.balanceOf(address(withdrawManager)) - wmBefore;

        // mint path: the same net shares the deposit user received
        wmBefore = plasmaVault.balanceOf(address(withdrawManager));
        assetsBefore = asset.balanceOf(mintUser);
        vm.prank(mintUser);
        uint256 mintPaid = plasmaVault.mint(depositUserShares, mintUser);
        assertEq(assetsBefore - asset.balanceOf(mintUser), mintPaid, "mint paid matches returned");
        uint256 mintFeeShares = plasmaVault.balanceOf(address(withdrawManager)) - wmBefore;
        uint256 mintUserShares = plasmaVault.balanceOf(mintUser);

        assertEq(mintUserShares, depositUserShares, "mint gives exactly the requested net shares");

        // the effective fee of both paths is the configured 10% of the gross shares
        uint256 depositRate = (depositFeeShares * 1e18) / (depositFeeShares + depositUserShares);
        uint256 mintRate = (mintFeeShares * 1e18) / (mintFeeShares + mintUserShares);
        assertApproxEqRel(depositRate, DEPOSIT_FEE, 1e14, "deposit path charges the configured fee");
        assertApproxEqRel(mintRate, DEPOSIT_FEE, 1e14, "mint path charges the configured fee");

        // and the effective fee in asset terms
        assertApproxEqRel(
            plasmaVault.convertToAssets(mintFeeShares),
            (mintPaid * DEPOSIT_FEE) / 1e18,
            1e14,
            "fee value collected on mint is 10% of what the minter paid"
        );

        // mint(N) costs what the deposit that yields N costs, and the fee is the same (+-1 wei, vault's favour)
        assertGe(mintFeeShares, depositFeeShares, "mint fee is not below the deposit fee");
        assertApproxEqAbs(mintFeeShares, depositFeeShares, 1, "mint fee equals the deposit fee");
        assertApproxEqAbs(mintPaid, depositPaid, 1, "mint costs what the equivalent deposit costs");
        assertEq(plasmaVault.previewMint(depositUserShares), mintPaid, "previewMint equals the assets paid");
    }

    // ---------------------------------------------------------------------------------------------
    // (2) maxMint is tight against the supply cap and mint(maxMint) does not exceed it
    // ---------------------------------------------------------------------------------------------

    function testFuzz_mintMaxMintFitsBindingCap(uint256 room_, bool highFee_) public {
        uint256 fee = highFee_ ? 1e17 : 1e16;
        room_ = bound(room_, 1_000, 1_000_000 * 10 ** uint256(plasmaVault.decimals()));

        _deposit(seeder, 1_000 * _unit());
        feeManager.setDepositFee(fee);

        uint256 cap = plasmaVault.totalSupply() + room_;
        PlasmaVaultGovernance(address(plasmaVault)).setTotalSupplyCap(cap);

        uint256 maxMintShares = plasmaVault.maxMint(mintUser);
        assertGt(maxMintShares, 0, "room leaves something to mint");
        assertEq(maxMintShares, Math.mulDiv(room_, 1e18 - fee, 1e18), "maxMint is the net share of the room");

        uint256 previewed = plasmaVault.previewMint(maxMintShares);

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626Upgradeable.ERC4626ExceededMaxMint.selector,
                mintUser,
                maxMintShares + 1,
                maxMintShares
            )
        );
        vm.prank(mintUser);
        plasmaVault.mint(maxMintShares + 1, mintUser);

        uint256 assetsBefore = asset.balanceOf(mintUser);
        vm.prank(mintUser);
        uint256 paid = plasmaVault.mint(maxMintShares, mintUser);

        assertEq(paid, previewed, "previewMint equals the assets paid");
        assertEq(assetsBefore - asset.balanceOf(mintUser), paid, "assets paid");
        assertLe(plasmaVault.totalSupply(), cap, "mint(maxMint) does not exceed the cap");
        assertLe(cap - plasmaVault.totalSupply(), 3, "maxMint uses the cap up to rounding");
    }

    // ---------------------------------------------------------------------------------------------
    // (3) IL-8751 PoC b6f9c9c7 #1: withdraw(maxWithdraw) pays what redeem(balance) pays
    // ---------------------------------------------------------------------------------------------

    function test_withdrawMaxWithdrawPaysTheSameAsRedeem() public {
        uint256 deposit = 1_000_000 * _unit();
        _deposit(mintUser, deposit);
        _deposit(carol, deposit);

        withdrawManager.updateWithdrawFee(2e17);

        uint256 aliceShares = plasmaVault.balanceOf(mintUser);
        uint256 carolShares = plasmaVault.balanceOf(carol);

        // Path A: full exit via redeem
        uint256 snap = vm.snapshotState();
        vm.prank(mintUser);
        uint256 redeemPaid = plasmaVault.redeem(aliceShares, mintUser, mintUser);
        uint256 carolAfterRedeem = plasmaVault.convertToAssets(carolShares);
        vm.revertToState(snap);

        // Path B: full exit via withdraw(maxWithdraw)
        uint256 maxAssets = plasmaVault.maxWithdraw(mintUser);
        assertApproxEqAbs(maxAssets, redeemPaid, 2, "maxWithdraw follows previewRedeem (1 - fee)");
        uint256 assetsBefore = asset.balanceOf(mintUser);
        vm.prank(mintUser);
        uint256 burned = plasmaVault.withdraw(maxAssets, mintUser, mintUser);
        uint256 withdrawPaid = asset.balanceOf(mintUser) - assetsBefore;
        uint256 carolAfterWithdraw = plasmaVault.convertToAssets(carolShares);

        assertApproxEqAbs(withdrawPaid, redeemPaid, 2, "withdraw pays what redeem pays");
        assertApproxEqAbs(carolAfterWithdraw, carolAfterRedeem, 2, "remaining holder value is the same");
        assertLe(burned, aliceShares, "burned at most the balance");
        assertLe(plasmaVault.convertToAssets(plasmaVault.balanceOf(mintUser)), 2, "position exited up to dust");

        // the effective fee of the withdraw path is the configured 20% of the gross shares burned
        assertApproxEqRel(
            plasmaVault.previewWithdraw(1 * _unit()),
            Math.mulDiv(plasmaVault.convertToShares(1 * _unit()), 1e18, 8e17, Math.Rounding.Ceil),
            1e14,
            "previewWithdraw is net / (1 - fee)"
        );
    }

    // ---------------------------------------------------------------------------------------------
    // (4) IL-8751 PoC b6f9c9c7 #2: a 100% withdraw fee leaves nothing to withdraw
    // ---------------------------------------------------------------------------------------------

    function test_fullWithdrawFeeLeavesNothingToWithdraw() public {
        _deposit(mintUser, 1_000_000 * _unit());
        _deposit(carol, 1_000_000 * _unit());

        withdrawManager.updateWithdrawFee(1e18);

        uint256 aliceShares = plasmaVault.balanceOf(mintUser);

        uint256 snap = vm.snapshotState();
        vm.prank(mintUser);
        assertEq(plasmaVault.redeem(aliceShares, mintUser, mintUser), 0, "redeem pays nothing at a 100% fee");
        vm.revertToState(snap);

        assertEq(plasmaVault.maxWithdraw(mintUser), 0, "maxWithdraw is 0 at a 100% fee");
        assertEq(plasmaVault.previewWithdraw(1), type(uint256).max, "previewWithdraw is max at a 100% fee");
        assertEq(plasmaVault.previewWithdraw(0), 0, "previewWithdraw(0) is 0 at a 100% fee");

        vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxWithdraw.selector, mintUser, 1, 0));
        vm.prank(mintUser);
        plasmaVault.withdraw(1, mintUser, mintUser);
    }

    // ---------------------------------------------------------------------------------------------
    // (5) previewWithdraw is an upper bound of the burn (ERC-4626) and within 1 wei of it
    // ---------------------------------------------------------------------------------------------

    function testFuzz_withdrawBurnsWhatPreviewWithdrawSays(uint256 fee_, uint256 assets_) public {
        fee_ = bound(fee_, 0, 0.99e18);
        _deposit(mintUser, 1_000_000 * _unit());
        _deposit(carol, 1_000_000 * _unit());
        withdrawManager.updateWithdrawFee(fee_);

        uint256 maxAssets = plasmaVault.maxWithdraw(mintUser);
        assets_ = bound(assets_, 1_000, maxAssets);

        uint256 previewed = plasmaVault.previewWithdraw(assets_);
        uint256 sharesBefore = plasmaVault.balanceOf(mintUser);
        uint256 assetsBefore = asset.balanceOf(mintUser);

        vm.prank(mintUser);
        uint256 returned = plasmaVault.withdraw(assets_, mintUser, mintUser);

        uint256 burned = sharesBefore - plasmaVault.balanceOf(mintUser);
        assertEq(returned, burned, "withdraw returns the shares burned");
        assertEq(asset.balanceOf(mintUser) - assetsBefore, assets_, "receiver gets the requested assets");
        assertLe(burned, previewed, "previewWithdraw is an upper bound");
        assertGe(burned + 1, previewed, "previewWithdraw is within 1 wei");
        assertLe(burned, sharesBefore, "burned at most the balance");
    }

    // ---------------------------------------------------------------------------------------------
    // (6) sharesToRelease > 0: the unallocated check sees the gross shares, as for redeem
    // ---------------------------------------------------------------------------------------------

    function test_withdrawChecksGrossSharesAgainstSharesToRelease() public {
        _deposit(mintUser, 1_000_000 * _unit());
        _deposit(carol, 1_000_000 * _unit());
        withdrawManager.updateWithdrawFee(2e17);

        uint256 assets = 100_000 * _unit();
        uint256 gross = plasmaVault.previewWithdraw(assets);
        uint256 unallocated = plasmaVault.convertToShares(asset.balanceOf(address(plasmaVault)));

        vm.warp(block.timestamp + 1_000);

        // exactly enough unallocated shares for the gross amount: passes, as redeem(gross) would
        uint256 snap = vm.snapshotState();
        vm.prank(alpha);
        withdrawManager.releaseFunds(block.timestamp - 1, unallocated - gross);
        vm.prank(mintUser);
        plasmaVault.withdraw(assets, mintUser, mintUser);
        vm.revertToState(snap);

        // one share short: reverts with the gross shares, exactly like redeem(gross)
        vm.prank(alpha);
        withdrawManager.releaseFunds(block.timestamp - 1, unallocated - gross + 1);

        bytes memory expected = abi.encodeWithSelector(
            WithdrawManager.WithdrawManagerInvalidSharesToRelease.selector,
            unallocated - gross + 1,
            gross,
            unallocated
        );

        snap = vm.snapshotState();
        vm.expectRevert(expected);
        vm.prank(mintUser);
        plasmaVault.redeem(gross, mintUser, mintUser);
        vm.revertToState(snap);

        vm.expectRevert(expected);
        vm.prank(mintUser);
        plasmaVault.withdraw(assets, mintUser, mintUser);
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
}

contract PlasmaVaultFeeBaseConsistency6DecTest is PlasmaVaultFeeBaseConsistencyBase {
    function _assetDecimals() internal pure override returns (uint8) {
        return 6;
    }
}

contract PlasmaVaultFeeBaseConsistency18DecTest is PlasmaVaultFeeBaseConsistencyBase {
    function _assetDecimals() internal pure override returns (uint8) {
        return 18;
    }
}

/// @notice Instant withdrawal fuse that pays exactly the requested amount from the mock market.
///         Stateless, delegatecalled by the PlasmaVault.
contract ExactInstantWithdrawFuse is IFuseCommon {
    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address public immutable MARKET;

    constructor(uint256 marketId_, address market_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        MARKET = market_;
    }

    /// @param params_ [0] amount to withdraw (set by the vault)
    function instantWithdraw(bytes32[] calldata params_) external {
        uint256 amount = uint256(params_[0]);
        uint256 available = MockExternalMarket(MARKET).balanceOf(address(this));
        if (amount > available) {
            amount = available;
        }
        if (amount > 0) {
            MockExternalMarket(MARKET).withdraw(amount);
        }
    }
}

/// @title IL-8751 follow-up: withdraw must pull liquidity from markets for the GROSS shares
/// @notice With sharesToRelease > 0 and a withdraw fee, the WithdrawManager check needs
///         released + gross shares unallocated. withdraw used to pull only the net amount, so it reverted
///         where the equivalent redeem(gross) passed. Real market (mock) behind an instant-withdraw fuse.
contract PlasmaVaultFeeBaseMarketPullTest is Test {
    uint256 public constant MARKET_ID = 999_999;

    address public atomist = address(this);
    address public alpha = address(0x1);
    address public user = address(0xA11CE);
    address public other = address(0xB0B);

    MockERC20Decimals public asset;
    UsersToRoles public usersToRoles;
    IporFusionAccessManager public accessManager;
    WithdrawManager public withdrawManager;
    PlasmaVault public plasmaVault;
    MockExternalMarket public market;
    MockMarketSupplyFuse public supplyFuse;

    function setUp() public {
        asset = new MockERC20Decimals("Mock USDC", "mUSDC", 6);
        market = new MockExternalMarket(address(asset));

        PriceOracleMiddleware implementation = new PriceOracleMiddleware(address(0));
        PriceOracleMiddleware oracle = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );
        address[] memory assets = new address[](1);
        assets[0] = address(asset);
        address[] memory sources = new address[](1);
        sources[0] = address(new FixedValuePriceFeed(1e8));
        oracle.setAssetsPricesSources(assets, sources);

        usersToRoles.superAdmin = atomist;
        usersToRoles.atomist = atomist;
        address[] memory alphas = new address[](1);
        alphas[0] = alpha;
        usersToRoles.alphas = alphas;
        accessManager = RoleLib.createAccessManager(usersToRoles, 0, vm);
        withdrawManager = new WithdrawManager(address(accessManager));

        plasmaVault = new PlasmaVault();
        plasmaVault.proxyInitialize(
            PlasmaVaultInitData(
                "IPOR Fusion mUSDC",
                "ipfmUSDC",
                address(asset),
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

        supplyFuse = new MockMarketSupplyFuse(MARKET_ID, address(market));
        ExactInstantWithdrawFuse instantFuse = new ExactInstantWithdrawFuse(MARKET_ID, address(market));

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuse);
        fuses[1] = address(instantFuse);
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig({
            marketId: MARKET_ID,
            fuse: address(new MockMarketBalanceFuse(MARKET_ID, address(market)))
        });
        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](1);
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(address(asset));
        marketConfigs[0] = MarketSubstratesConfig({marketId: MARKET_ID, substrates: substrates});
        PlasmaVaultConfigurator.setupPlasmaVault(vm, atomist, address(plasmaVault), fuses, balanceFuses, marketConfigs);

        bytes4[] memory configureSig = new bytes4[](1);
        configureSig[0] = Governance.configureInstantWithdrawalFuses.selector;
        accessManager.setTargetFunctionRole(address(plasmaVault), configureSig, Roles.ATOMIST_ROLE);
        InstantWithdrawalFusesParamsStruct[] memory instant = new InstantWithdrawalFusesParamsStruct[](1);
        instant[0] = InstantWithdrawalFusesParamsStruct({fuse: address(instantFuse), params: new bytes32[](1)});
        Governance(address(plasmaVault)).configureInstantWithdrawalFuses(instant);

        bytes4[] memory withdrawFeeSig = new bytes4[](1);
        withdrawFeeSig[0] = WithdrawManager.updateWithdrawFee.selector;
        accessManager.setTargetFunctionRole(address(withdrawManager), withdrawFeeSig, Roles.ATOMIST_ROLE);

        _fund(user, 5_000e6);
        _fund(other, 5_000e6);
        vm.prank(user);
        plasmaVault.deposit(5_000e6, user);
        vm.prank(other);
        plasmaVault.deposit(5_000e6, other);

        // 9 000 in the market, 1 000 idle; release exactly the idle amount
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction({
            fuse: address(supplyFuse),
            data: abi.encodeWithSignature(
                "enter((uint256))",
                MockMarketSupplyFuse.MockMarketSupplyFuseEnterData({amount: 9_000e6})
            )
        });
        vm.prank(alpha);
        plasmaVault.execute(calls);

        vm.warp(block.timestamp + 1 hours);
        uint256 sharesToRelease = plasmaVault.convertToShares(1_000e6);
        vm.prank(alpha);
        withdrawManager.releaseFunds(block.timestamp - 1, sharesToRelease);
    }

    function test_withdrawPullsGrossFromMarketsWhenSharesAreReleased() public {
        _assertWithdrawMatchesRedeem(15e15); // 1.5%
    }

    function test_withdrawPullsGrossFromMarketsWhenSharesAreReleasedHighFee() public {
        _assertWithdrawMatchesRedeem(5e16); // 5%
    }

    function _assertWithdrawMatchesRedeem(uint256 fee_) internal {
        withdrawManager.updateWithdrawFee(fee_);
        uint256 assets = 500e6;
        uint256 gross = plasmaVault.previewWithdraw(assets);
        uint256 idleBefore = asset.balanceOf(address(plasmaVault));
        assertEq(idleBefore, 1_000e6, "released amount is all idle, the rest is in the market");

        uint256 snap = vm.snapshotState();

        // redeem of the equivalent gross shares: pulls for the gross amount and passes the check
        vm.prank(user);
        uint256 redeemed = plasmaVault.redeem(gross, user, user);
        uint256 redeemBalanceOfUser = plasmaVault.balanceOf(user);
        uint256 redeemMarket = market.balanceOf(address(plasmaVault));
        vm.revertToState(snap);

        // withdraw must pass too and pay the requested assets
        vm.prank(user);
        plasmaVault.withdraw(assets, user, user);

        assertEq(asset.balanceOf(user), assets, "withdraw pays the requested assets");
        assertApproxEqAbs(redeemed, assets, 2, "redeem of the gross shares pays the same assets");
        assertApproxEqAbs(plasmaVault.balanceOf(user), redeemBalanceOfUser, 1, "same shares burned as redeem");
        assertGe(
            plasmaVault.convertToShares(asset.balanceOf(address(plasmaVault))),
            withdrawManager.getSharesToRelease(),
            "released shares stay covered by idle liquidity"
        );
        assertLt(market.balanceOf(address(plasmaVault)), 9_000e6, "liquidity was pulled from the market");
        assertGt(redeemMarket, 0, "market still holds funds");
    }

    function _fund(address user_, uint256 amount_) internal {
        asset.mint(user_, amount_);
        vm.prank(user_);
        asset.approve(address(plasmaVault), type(uint256).max);
    }
}

/// @title IL-8838: withdraw with released shares near a 100% withdraw fee
/// @notice With released shares the market pull is sized on the gross amount. PlasmaVault grosses up the
///         ceil-rounded shares before the WithdrawManager check (which only compares), so the rounding error of the (dust) amount grows by 1 / (1 - fee); the
///         WITHDRAW_FROM_MARKETS_OFFSET buffer has to be grossed up together with assets_, otherwise withdraw reverts
///         with WithdrawManagerInvalidSharesToRelease where the equivalent redeem passes. Share price 1.005, all
///         capital in the market (idle 0), released shares are dust. Amounts are in base units, so the 6- and
///         18-decimal variants see the same numbers.
abstract contract PlasmaVaultFeeBaseDustReleaseBase is Test {
    uint256 public constant MARKET_ID = 999_999;

    address public atomist = address(this);
    address public alpha = address(0x1);
    address public user = address(0xA11CE);
    address public other = address(0xB0B);

    MockERC20Decimals public asset;
    UsersToRoles public usersToRoles;
    IporFusionAccessManager public accessManager;
    WithdrawManager public withdrawManager;
    PlasmaVault public plasmaVault;
    MockExternalMarket public market;
    MockMarketSupplyFuse public supplyFuse;

    function _assetDecimals() internal pure virtual returns (uint8);

    function _unit() internal view returns (uint256) {
        return 10 ** uint256(asset.decimals());
    }

    function setUp() public {
        asset = new MockERC20Decimals("Mock Asset", "mAsset", _assetDecimals());
        market = new MockExternalMarket(address(asset));

        PriceOracleMiddleware implementation = new PriceOracleMiddleware(address(0));
        PriceOracleMiddleware oracle = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );
        address[] memory assets = new address[](1);
        assets[0] = address(asset);
        address[] memory sources = new address[](1);
        sources[0] = address(new FixedValuePriceFeed(1e8));
        oracle.setAssetsPricesSources(assets, sources);

        usersToRoles.superAdmin = atomist;
        usersToRoles.atomist = atomist;
        address[] memory alphas = new address[](1);
        alphas[0] = alpha;
        usersToRoles.alphas = alphas;
        accessManager = RoleLib.createAccessManager(usersToRoles, 0, vm);
        withdrawManager = new WithdrawManager(address(accessManager));

        plasmaVault = new PlasmaVault();
        plasmaVault.proxyInitialize(
            PlasmaVaultInitData(
                "IPOR Fusion mUSDC",
                "ipfmUSDC",
                address(asset),
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

        supplyFuse = new MockMarketSupplyFuse(MARKET_ID, address(market));
        ExactInstantWithdrawFuse instantFuse = new ExactInstantWithdrawFuse(MARKET_ID, address(market));

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuse);
        fuses[1] = address(instantFuse);
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig({
            marketId: MARKET_ID,
            fuse: address(new MockMarketBalanceFuse(MARKET_ID, address(market)))
        });
        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](1);
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(address(asset));
        marketConfigs[0] = MarketSubstratesConfig({marketId: MARKET_ID, substrates: substrates});
        PlasmaVaultConfigurator.setupPlasmaVault(vm, atomist, address(plasmaVault), fuses, balanceFuses, marketConfigs);

        bytes4[] memory configureSig = new bytes4[](1);
        configureSig[0] = Governance.configureInstantWithdrawalFuses.selector;
        accessManager.setTargetFunctionRole(address(plasmaVault), configureSig, Roles.ATOMIST_ROLE);
        InstantWithdrawalFusesParamsStruct[] memory instant = new InstantWithdrawalFusesParamsStruct[](1);
        instant[0] = InstantWithdrawalFusesParamsStruct({fuse: address(instantFuse), params: new bytes32[](1)});
        Governance(address(plasmaVault)).configureInstantWithdrawalFuses(instant);

        bytes4[] memory withdrawFeeSig = new bytes4[](1);
        withdrawFeeSig[0] = WithdrawManager.updateWithdrawFee.selector;
        accessManager.setTargetFunctionRole(address(withdrawManager), withdrawFeeSig, Roles.ATOMIST_ROLE);

        uint256 depositAmount = 5_000 * _unit();
        _fund(user, depositAmount);
        _fund(other, depositAmount);
        vm.prank(user);
        plasmaVault.deposit(depositAmount, user);
        vm.prank(other);
        plasmaVault.deposit(depositAmount, other);
    }

    function _fund(address user_, uint256 amount_) internal {
        asset.mint(user_, amount_);
        vm.prank(user_);
        asset.approve(address(plasmaVault), type(uint256).max);
    }

    /// @dev donation, then ALPHA supplies all idle assets to the market (idle 0), then the release
    function _donateSupplyAndRelease(uint256 donation_, uint256 release_) internal {
        asset.mint(address(plasmaVault), donation_);
        uint256 toSupply = asset.balanceOf(address(plasmaVault));
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction({
            fuse: address(supplyFuse),
            data: abi.encodeWithSignature(
                "enter((uint256))",
                MockMarketSupplyFuse.MockMarketSupplyFuseEnterData({amount: toSupply})
            )
        });
        vm.prank(alpha);
        plasmaVault.execute(calls);

        vm.warp(block.timestamp + 1 hours);
        vm.prank(alpha);
        withdrawManager.releaseFunds(block.timestamp - 1, release_);
        assertEq(asset.balanceOf(address(plasmaVault)), 0, "idle is empty, everything is in the market");
    }

    /// @dev share price 1.005: donation 50 on 10 000 deposited, 1 released share
    function _defaultState() internal {
        _donateSupplyAndRelease(50 * _unit(), 1);
    }

    function test_dustReleaseWithdrawAtKeeperCapFee() public {
        _defaultState();
        withdrawManager.updateWithdrawFee(5e17);
        for (uint256 assets = 1; assets <= 3; ++assets) {
            uint256 snap = vm.snapshotState();
            uint256 gross = plasmaVault.previewWithdraw(assets);
            uint256 userSharesBefore = plasmaVault.balanceOf(user);
            uint256 userAssetsBefore = asset.balanceOf(user);

            vm.prank(user);
            plasmaVault.withdraw(assets, user, user);

            assertEq(asset.balanceOf(user) - userAssetsBefore, assets, "withdraw pays exactly the requested assets");
            uint256 burned = userSharesBefore - plasmaVault.balanceOf(user);
            assertLe(burned, gross, "burned shares do not exceed previewWithdraw");
            assertGe(burned + 1, gross, "burned shares are previewWithdraw or one less");
            assertGe(
                plasmaVault.convertToShares(asset.balanceOf(address(plasmaVault))),
                withdrawManager.getSharesToRelease(),
                "released shares stay covered by idle liquidity"
            );
            vm.revertToState(snap);
        }
    }

    function test_dustReleaseWithdrawNearFullFeePays() public {
        _defaultState();
        uint256[4] memory fees = [uint256(99e16), 999e15, 9999e14, 1e18 - 1e9];
        for (uint256 f = 0; f < fees.length; ++f) {
            withdrawManager.updateWithdrawFee(fees[f]);
            for (uint256 assets = 1; assets <= 3; ++assets) {
                _assertDustWithdrawMatchesRedeem(assets);
            }
        }
    }

    function _assertDustWithdrawMatchesRedeem(uint256 assets_) internal {
        uint256 snap = vm.snapshotState();
        uint256 gross = plasmaVault.previewWithdraw(assets_);
        uint256 userSharesBefore = plasmaVault.balanceOf(user);
        uint256 userAssetsBefore = asset.balanceOf(user);

        // redeem of the gross shares: the reference for payout and burn
        vm.prank(user);
        plasmaVault.redeem(gross, user, user);
        uint256 redeemPaid = asset.balanceOf(user) - userAssetsBefore;
        uint256 redeemBurned = userSharesBefore - plasmaVault.balanceOf(user);
        vm.revertToState(snap);

        vm.prank(user);
        plasmaVault.withdraw(assets_, user, user);

        assertEq(asset.balanceOf(user) - userAssetsBefore, assets_, "withdraw pays the requested assets");
        assertApproxEqAbs(redeemPaid, assets_, 1, "redeem of the gross shares pays the same assets");
        assertApproxEqAbs(
            userSharesBefore - plasmaVault.balanceOf(user),
            redeemBurned,
            1,
            "same shares burned as the equivalent redeem"
        );
        assertGe(
            plasmaVault.convertToShares(asset.balanceOf(address(plasmaVault))),
            withdrawManager.getSharesToRelease(),
            "released shares stay covered by idle liquidity"
        );
        vm.revertToState(snap);
    }

    /// @dev withdraw with released shares must never fail the WithdrawManager release check
    function testFuzz_withdrawWithReleasedSharesPassesReleaseCheck(
        uint256 fee_,
        uint256 assets_,
        uint256 release_,
        uint256 donation_
    ) public {
        fee_ = bound(fee_, 0, 1e18 - 1);
        release_ = bound(release_, 1, 1e4);
        donation_ = bound(donation_, 0, 9 * 10_000 * _unit());
        _donateSupplyAndRelease(donation_, release_);
        withdrawManager.updateWithdrawFee(fee_);

        uint256 maxAssets = plasmaVault.maxWithdraw(user);
        // maxWithdraw is 0 only for dust balances that convert to 0 assets after the fee; nothing to withdraw there
        vm.assume(maxAssets > 0);
        // maxWithdraw is a view taken before the pull. Withdrawing the exact maximum can exceed the post-pull maximum by
        // a few parts in 1e13 (observed: 2.5e9 wei on 1.8e22, ERC4626ExceededMaxWithdraw, not the release check), so the
        // top 1e-6 of the range is left out
        assets_ = bound(assets_, 1, maxAssets - maxAssets / 1e6);

        // no other revert is legitimate below: no management/performance/deposit fee, the instant-withdraw fuse clamps
        uint256 balanceBefore = asset.balanceOf(user);
        vm.prank(user);
        plasmaVault.withdraw(assets_, user, user);

        assertEq(asset.balanceOf(user) - balanceBefore, assets_, "withdraw pays the requested assets");
        assertGe(
            plasmaVault.convertToShares(asset.balanceOf(address(plasmaVault))),
            withdrawManager.getSharesToRelease(),
            "released shares stay covered by idle liquidity"
        );
    }
}

contract PlasmaVaultFeeBaseDustRelease6DecTest is PlasmaVaultFeeBaseDustReleaseBase {
    function _assetDecimals() internal pure override returns (uint8) {
        return 6;
    }
}

contract PlasmaVaultFeeBaseDustRelease18DecTest is PlasmaVaultFeeBaseDustReleaseBase {
    function _assetDecimals() internal pure override returns (uint8) {
        return 18;
    }
}
