// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {
    PlasmaVault,
    MarketBalanceFuseConfig,
    MarketSubstratesConfig,
    PlasmaVaultInitData
} from "../../contracts/vaults/PlasmaVault.sol";
import {FuseAction} from "../../contracts/interfaces/IPlasmaVault.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {FixedValuePriceFeed} from "../../contracts/price_oracle/price_feed/FixedValuePriceFeed.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {FeeManagerFactory, FeeConfig} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {FeeAccount} from "../../contracts/managers/fee/FeeAccount.sol";
import {ZeroBalanceFuse} from "../../contracts/fuses/ZeroBalanceFuse.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {PlasmaVaultConfigurator} from "../utils/PlasmaVaultConfigurator.sol";
import {DoNothingFuse} from "../fuses/DoNothingFuse.sol";
import {RoleLib, UsersToRoles} from "../RoleLib.sol";
import {MockERC20Decimals} from "../unitTest/fuses/term_finance/mocks/MockERC20Decimals.sol";
import {PlasmaVaultCloneLib} from "../test_helpers/PlasmaVaultCloneLib.sol";

/// @title PlasmaVaultManagementFeeInPriceBase
/// @notice IL-8870 option A: the accrued management fee F is part of the share price (virtual fee shares V on the
///         supply side) while totalAssets() stays gross. Pete D-002: a realization mints exactly
///         V = floor(min(F, G) * (S + off) / (G - min(F, G) + 1)). Pete D-003: execute() and updateMarketsBalances()
///         never realize the fee. Every expected value below is computed in the test from the formula, not read
///         back from the vault.
/// @dev Concrete suites below fix the asset decimals (6 and 18). The share offset is 100 for both.
abstract contract PlasmaVaultManagementFeeInPriceBase is Test {
    /// @dev Storage slot of the pending management fee (PlasmaVaultStorageLib.PENDING_MANAGEMENT_FEE_SLOT)
    bytes32 internal constant PENDING_SLOT = 0x612d50d27ffbb749a9804ec5bba7933bff2377ff69afba55e14b5cf7180bff00;
    /// @dev Storage slot of ManagementFeeData (PlasmaVaultStorageLib.PLASMA_VAULT_MANAGEMENT_FEE_DATA)
    bytes32 internal constant MANAGEMENT_FEE_DATA_SLOT =
        0x239dd7e43331d2af55e2a25a6908f3bcec2957025f1459db97dcdc37c0003f00;

    enum CapMode {
        DEFAULT,
        ROOMY,
        TIGHT
    }

    event ManagementFeeRealized(uint256 unrealizedFeeInUnderlying, uint256 unrealizedFeeInShares);

    address public atomist = address(this);
    address public alpha = address(0x1);
    address public user = address(0xA11CE);
    address public other = address(0xB0B);

    /// @dev 2% per year, FeeManager percentages use 2 decimals (10000 = 100%)
    uint256 public constant MANAGEMENT_FEE = 200;
    /// @dev 5% per year, the maximum rate: 20 years of accrual equal exactly the assets
    uint256 public constant MAX_MANAGEMENT_FEE = 500;
    uint256 public constant ACCRUAL_PERIOD = 30 days;

    MockERC20Decimals public asset;
    UsersToRoles public usersToRoles;
    IporFusionAccessManager public accessManager;
    WithdrawManager public withdrawManager;
    PlasmaVault public plasmaVault;
    DoNothingFuse public doNothingFuse;
    address public managementFeeAccount;
    /// @dev one million tokens
    uint256 public userDeposit;
    /// @dev share offset 10 ** (vault decimals - asset decimals)
    uint256 public off;

    function _assetDecimals() internal pure virtual returns (uint8);

    function setUp() public {
        asset = new MockERC20Decimals("Mock Asset", "mA", _assetDecimals());
        userDeposit = 1_000_000 * 10 ** uint256(_assetDecimals());

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
                "IPOR Fusion mA",
                "ipfmA",
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

        doNothingFuse = new DoNothingFuse(1);
        address[] memory fuses = new address[](1);
        fuses[0] = address(doNothingFuse);
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig({marketId: 1, fuse: address(new ZeroBalanceFuse(1))});

        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            atomist,
            address(plasmaVault),
            fuses,
            balanceFuses,
            new MarketSubstratesConfig[](0)
        );

        /// @dev realizeManagementFee is mapped to ALPHA_ROLE by the initializer; this hand-built access manager
        ///      does not use the initializer, so map it here the same way
        bytes4[] memory realizeSig = new bytes4[](1);
        realizeSig[0] = PlasmaVault.realizeManagementFee.selector;
        accessManager.setTargetFunctionRole(address(plasmaVault), realizeSig, Roles.ALPHA_ROLE);

        bytes4[] memory updateSig = new bytes4[](1);
        updateSig[0] = PlasmaVault.updateMarketsBalances.selector;
        accessManager.setTargetFunctionRole(address(plasmaVault), updateSig, Roles.UPDATE_MARKETS_BALANCES_ROLE);
        accessManager.grantRole(Roles.UPDATE_MARKETS_BALANCES_ROLE, alpha, 0);

        bytes4[] memory capSig = new bytes4[](1);
        capSig[0] = PlasmaVaultGovernance.setTotalSupplyCap.selector;
        accessManager.setTargetFunctionRole(address(plasmaVault), capSig, Roles.ATOMIST_ROLE);

        managementFeeAccount = PlasmaVaultGovernance(address(plasmaVault)).getManagementFeeData().feeAccount;
        off = 10 ** uint256(plasmaVault.decimals() - _assetDecimals());

        _fund(user, userDeposit);
        _fund(other, userDeposit);
    }

    // ---------------------------------------------------------------------------------------------
    // 1. The price falls without a transaction, totalAssets() stays gross
    // ---------------------------------------------------------------------------------------------

    function testShouldFallPriceWithoutTransaction_whenManagementFeeAccrues() public {
        _deposit(user, userDeposit);
        uint256 grossAssets = plasmaVault.totalAssets();
        uint256 supply = plasmaVault.totalSupply();
        uint256 priceBefore = _price();
        uint256 sharesPerTokenBefore = plasmaVault.convertToShares(10 ** uint256(_assetDecimals()));

        vm.warp(block.timestamp + ACCRUAL_PERIOD);

        uint256 fee = Math.mulDiv(grossAssets * ACCRUAL_PERIOD, MANAGEMENT_FEE, 365 days * 1e4);
        assertGt(fee, 0, "fixture accrues a fee");
        uint256 virtualShares = _feeShares(fee, supply, grossAssets);
        uint256 priceAfter30Days = _price();

        assertEq(plasmaVault.totalAssets(), grossAssets, "totalAssets stays gross");
        assertLt(priceAfter30Days, priceBefore, "price of one unit fell with no transaction");
        assertEq(
            priceAfter30Days,
            Math.mulDiv(10 ** uint256(plasmaVault.decimals()), grossAssets + 1, supply + virtualShares + off),
            "price is (G + 1) / (S + V + off)"
        );
        assertGt(
            plasmaVault.convertToShares(10 ** uint256(_assetDecimals())),
            sharesPerTokenBefore,
            "one token buys more shares"
        );
        assertEq(plasmaVault.balanceOf(managementFeeAccount), 0, "nothing was minted");

        vm.warp(block.timestamp + ACCRUAL_PERIOD);

        assertLt(_price(), priceAfter30Days, "price keeps falling");
        assertEq(plasmaVault.totalAssets(), grossAssets, "totalAssets still gross");
        assertEq(plasmaVault.totalSupply(), supply, "supply unchanged");
    }

    // ---------------------------------------------------------------------------------------------
    // 2. The price is the same before and after a realization
    // ---------------------------------------------------------------------------------------------

    /// @dev Realization by the ALPHA method: nothing else moves, so the equality is exact
    function testShouldKeepPriceExactly_whenAlphaRealizesManagementFee() public {
        _deposit(user, userDeposit);
        vm.warp(block.timestamp + ACCRUAL_PERIOD);

        uint256 tokenUnit = 10 ** uint256(_assetDecimals());
        uint256 priceBefore = _price();
        uint256 sharesPerTokenBefore = plasmaVault.convertToShares(tokenUnit);
        uint256 assetsPerHalfBefore = plasmaVault.convertToAssets(plasmaVault.balanceOf(user) / 2);

        uint256 minted = _realize();

        assertGt(minted, 0, "fixture realizes shares");
        assertEq(plasmaVault.balanceOf(managementFeeAccount), minted, "fee account holds the shares");
        assertEq(_price(), priceBefore, "price of one unit");
        assertEq(plasmaVault.convertToShares(tokenUnit), sharesPerTokenBefore, "convertToShares");
        assertEq(plasmaVault.convertToAssets(plasmaVault.balanceOf(user) / 2), assetsPerHalfBefore, "convertToAssets");
    }

    /// @dev Realization by a deposit (no entry fee): the deposit adds assets and shares, so the price may only move
    ///      by the rounding of the minted shares (1 wei), and only in favour of the holders
    function testShouldKeepPriceWithinOneWei_whenDepositRealizesManagementFee() public {
        _deposit(user, userDeposit);
        vm.warp(block.timestamp + ACCRUAL_PERIOD);

        uint256 tokenUnit = 10 ** uint256(_assetDecimals());
        uint256 priceBefore = _price();
        uint256 sharesPerTokenBefore = plasmaVault.convertToShares(tokenUnit);

        _deposit(other, userDeposit / 10);

        assertGt(plasmaVault.balanceOf(managementFeeAccount), 0, "the deposit realized the fee");
        uint256 priceAfter = _price();
        assertGe(priceAfter, priceBefore, "price does not fall");
        assertLe(priceAfter - priceBefore, 1, "price of one unit within 1 wei");
        uint256 sharesPerTokenAfter = plasmaVault.convertToShares(tokenUnit);
        assertLe(sharesPerTokenAfter, sharesPerTokenBefore, "convertToShares does not rise");
        assertLe(sharesPerTokenBefore - sharesPerTokenAfter, 1, "convertToShares within 1");
    }

    /// @dev Realization by a withdraw (no exit fee), same tolerance as the deposit
    function testShouldKeepPriceWithinOneWei_whenWithdrawRealizesManagementFee() public {
        _deposit(user, userDeposit);
        _deposit(other, userDeposit);
        vm.warp(block.timestamp + ACCRUAL_PERIOD);

        uint256 tokenUnit = 10 ** uint256(_assetDecimals());
        uint256 priceBefore = _price();
        uint256 sharesPerTokenBefore = plasmaVault.convertToShares(tokenUnit);

        vm.prank(user);
        plasmaVault.withdraw(userDeposit / 10, user, user);

        assertGt(plasmaVault.balanceOf(managementFeeAccount), 0, "the withdraw realized the fee");
        uint256 priceAfter = _price();
        assertGe(priceAfter, priceBefore, "price does not fall");
        assertLe(priceAfter - priceBefore, 1, "price of one unit within 1 wei");
        uint256 sharesPerTokenAfter = plasmaVault.convertToShares(tokenUnit);
        assertLe(sharesPerTokenAfter, sharesPerTokenBefore, "convertToShares does not rise");
        assertLe(sharesPerTokenBefore - sharesPerTokenAfter, 1, "convertToShares within 1");
    }

    // ---------------------------------------------------------------------------------------------
    // 3. Exact formula D-002 and the value of the fee shares
    // ---------------------------------------------------------------------------------------------

    function testShouldMintExactlyFormulaShares_whenManagementFeeRealized() public {
        _deposit(user, userDeposit);
        _deposit(other, userDeposit / 3);
        vm.warp(block.timestamp + ACCRUAL_PERIOD);

        uint256 supply = plasmaVault.totalSupply();
        uint256 grossAssets = plasmaVault.totalAssets();
        uint256 fee = Math.mulDiv(grossAssets * ACCRUAL_PERIOD, MANAGEMENT_FEE, 365 days * 1e4);
        assertEq(plasmaVault.getUnrealizedManagementFee(), fee, "accrued fee is G * rate * dt");
        uint256 expected = _feeShares(fee, supply, grossAssets);
        uint256 oldGrossFormula = Math.mulDiv(fee, supply + off, grossAssets + 1);
        assertGt(expected, oldGrossFormula, "fixture tells D-002 from convertToShares(F) on the gross price");

        vm.expectEmit(false, false, false, true, address(plasmaVault));
        emit ManagementFeeRealized(fee, expected);
        uint256 minted = _realize();

        assertEq(minted, expected, "returned shares equal the formula");
        assertEq(plasmaVault.balanceOf(managementFeeAccount), expected, "fee account holds exactly the formula shares");
        assertEq(plasmaVault.totalSupply(), supply + expected, "supply grew by the formula shares");

        /// @dev value of the fee shares: never above F, short of F by less than one share plus conversion rounding
        uint256 value = plasmaVault.convertToAssets(expected);
        assertLe(value, fee, "fee shares are not worth more than F");
        assertLe(
            fee - value,
            Math.ceilDiv(grossAssets + 1, supply + expected + off) + 1,
            "shortfall below the value of one share plus 1 wei"
        );
        /// @dev a share is worth less than one asset unit here (offset 100), so the shortfall is at most 1 wei
        assertLt(Math.ceilDiv(grossAssets + 1, supply + expected + off), 2, "fixture: a share is worth < 1 unit");
        assertLe(fee - value, 1, "[F - 1, F] where a share is worth less than one unit");
    }

    /// @dev Codex #6: a share worth many asset units (donation inflated price). The value shortfall is bounded by
    ///      one share's value, which is far above 1 wei. S = 100, off = 100, G = 1 000 000 001, F = 10^7, V = 2
    function testShouldBoundShortfallByOneShare_whenSharePriceInflatedByDonation() public {
        _deposit(user, 1);
        assertEq(plasmaVault.totalSupply(), 100, "S = 100");
        asset.mint(address(plasmaVault), 1_000_000_000);
        assertEq(plasmaVault.totalAssets(), 1_000_000_001, "G = 1 000 000 001");

        /// @dev 182.5 days at 2% on G is G / 100 = 10 000 000
        vm.warp(block.timestamp + 15_768_000);
        uint256 fee = plasmaVault.getUnrealizedManagementFee();
        assertEq(fee, 10_000_000, "F = 10^7");

        uint256 expected = _feeShares(fee, 100, 1_000_000_001);
        assertEq(expected, 2, "V = floor(10^7 * 200 / 990 000 002) = 2");
        uint256 priceBefore = _price();

        uint256 minted = _realize();

        assertEq(minted, 2, "two shares minted");
        assertEq(plasmaVault.balanceOf(managementFeeAccount), 2, "fee account holds 2 shares");
        assertEq(_price(), priceBefore, "price unchanged");
        uint256 value = plasmaVault.convertToAssets(2);
        uint256 oneShare = Math.ceilDiv(1_000_000_001 + 1, 100 + 2 + off);
        assertEq(value, 9_900_990, "2 shares are worth floor(2 * 1 000 000 002 / 202) = 9 900 990 units");
        assertGt(fee - value, 1, "the shortfall is not 1 wei here");
        assertLe(fee - value, oneShare + 1, "the shortfall is bounded by one share plus 1 wei");
    }

    // ---------------------------------------------------------------------------------------------
    // 4. execute() and updateMarketsBalances() never realize the fee (D-003)
    // ---------------------------------------------------------------------------------------------

    function testShouldNotRealizeManagementFee_whenExecuteRunsAnotherFuse() public {
        _deposit(user, userDeposit);
        vm.warp(block.timestamp + ACCRUAL_PERIOD);
        assertGt(plasmaVault.getUnrealizedManagementFee(), 0, "fee accrued");

        uint256 feeBalance = plasmaVault.balanceOf(managementFeeAccount);
        uint256 lastUpdate = _lastUpdate();
        uint256 pending = _pending();
        uint256 supply = plasmaVault.totalSupply();
        uint256 priceBefore = _price();
        assertLt(lastUpdate, block.timestamp, "fee clock is behind");

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(doNothingFuse),
            data: abi.encodeWithSignature("enter((address))", DoNothingFuse.DoNothingFuseEnterData(address(asset)))
        });
        vm.recordLogs();
        vm.prank(alpha);
        plasmaVault.execute(actions);

        assertEq(plasmaVault.balanceOf(managementFeeAccount), feeBalance, "fee account balance unchanged");
        assertEq(_lastUpdate(), lastUpdate, "lastUpdateTimestamp unchanged");
        assertEq(_pending(), pending, "pending fee unchanged");
        assertEq(plasmaVault.totalSupply(), supply, "supply unchanged");
        assertEq(_price(), priceBefore, "price is still net of the accrued fee");
        assertEq(_countRealizedEvents(), 0, "no ManagementFeeRealized event");

        /// @dev control: the realization does move all of them, so the checks above can fail
        _realize();
        assertGt(plasmaVault.balanceOf(managementFeeAccount), feeBalance, "control: ALPHA realization mints");
        assertEq(_lastUpdate(), block.timestamp, "control: clock advanced");
    }

    function testShouldNotRealizeManagementFee_whenUpdateMarketsBalancesRuns() public {
        _deposit(user, userDeposit);
        vm.warp(block.timestamp + ACCRUAL_PERIOD);
        assertGt(plasmaVault.getUnrealizedManagementFee(), 0, "fee accrued");

        uint256 feeBalance = plasmaVault.balanceOf(managementFeeAccount);
        uint256 lastUpdate = _lastUpdate();
        uint256 pending = _pending();
        uint256 priceBefore = _price();
        assertLt(lastUpdate, block.timestamp, "fee clock is behind");

        uint256[] memory markets = new uint256[](1);
        markets[0] = 1;
        vm.recordLogs();
        vm.prank(alpha);
        plasmaVault.updateMarketsBalances(markets);

        assertEq(plasmaVault.balanceOf(managementFeeAccount), feeBalance, "fee account balance unchanged");
        assertEq(_lastUpdate(), lastUpdate, "lastUpdateTimestamp unchanged");
        assertEq(_pending(), pending, "pending fee unchanged");
        assertEq(_price(), priceBefore, "price is still net of the accrued fee");
        assertEq(_countRealizedEvents(), 0, "no ManagementFeeRealized event");
    }

    // ---------------------------------------------------------------------------------------------
    // 5. Edge cases
    // ---------------------------------------------------------------------------------------------

    /// @dev S == 0 with assets in the vault: nobody to charge, V = 0, the accrual is dropped, the clock advances
    function testShouldMintNothingAndDropAccrual_whenSupplyIsZero() public {
        asset.mint(address(plasmaVault), userDeposit);
        vm.warp(block.timestamp + ACCRUAL_PERIOD);
        assertEq(plasmaVault.totalSupply(), 0, "S == 0");
        assertGt(plasmaVault.getUnrealizedManagementFee(), 0, "fee accrued on the donation");

        assertEq(plasmaVault.convertToShares(1e6), 1e6 * off, "S == 0 branch of convertToShares");
        assertEq(plasmaVault.previewDeposit(1e6), 1e6 * off, "S == 0 branch of previewDeposit");

        assertEq(_realize(), 0, "no shares minted");
        assertEq(plasmaVault.balanceOf(managementFeeAccount), 0, "fee account empty");
        assertEq(_pending(), 0, "accrual dropped");
        assertEq(_lastUpdate(), block.timestamp, "clock advanced");
        assertEq(plasmaVault.getUnrealizedManagementFee(), 0, "nothing accrued after the restart");
    }

    /// @dev G == 0 with shares outstanding: V = 0, the pending fee is dropped, the clock advances, views do not revert
    function testShouldMintNothingAndDropPending_whenGrossAssetsAreZero() public {
        _deposit(user, userDeposit);
        vm.warp(block.timestamp + ACCRUAL_PERIOD);
        _configureRate(MANAGEMENT_FEE);
        assertGt(_pending(), 0, "checkpoint left a pending fee");

        _drain(plasmaVault.totalAssets());
        assertEq(plasmaVault.totalAssets(), 0, "G == 0");
        vm.warp(block.timestamp + 1 days);

        assertEq(plasmaVault.convertToAssets(plasmaVault.balanceOf(user)), 0, "shares are worth 0");
        plasmaVault.previewDeposit(1e6);
        plasmaVault.previewMint(1e8);
        plasmaVault.maxDeposit(other);
        plasmaVault.maxMint(other);

        assertEq(_realize(), 0, "no shares minted");
        assertEq(plasmaVault.balanceOf(managementFeeAccount), 0, "fee account empty");
        assertEq(_pending(), 0, "pending dropped");
        assertEq(_lastUpdate(), block.timestamp, "clock advanced");
    }

    /// @dev Fee account address(0): F = 0 everywhere, the price does not move, the realization mints nothing
    function testShouldNotAccrueInPrice_whenFeeAccountIsZeroAddress() public {
        _deposit(user, userDeposit);
        _clearFeeAccount();
        assertEq(
            PlasmaVaultGovernance(address(plasmaVault)).getManagementFeeData().feeAccount,
            address(0),
            "fee account cleared"
        );

        uint256 priceBefore = _price();
        vm.warp(block.timestamp + ACCRUAL_PERIOD);

        assertEq(_price(), priceBefore, "price does not fall without a fee account");

        assertEq(_realize(), 0, "nothing minted");
        assertEq(plasmaVault.totalSupply(), userDeposit * off, "supply unchanged");
        assertEq(_lastUpdate(), block.timestamp, "clock advanced");
        assertEq(_price(), priceBefore, "price unchanged");
    }

    /// @dev Rate 0: the price stays put and the realization mints nothing
    function testShouldNotAccrueInPrice_whenRateIsZero() public {
        _deposit(user, userDeposit);
        _configureRate(0);

        uint256 priceBefore = _price();
        vm.warp(block.timestamp + ACCRUAL_PERIOD);

        assertEq(_price(), priceBefore, "price does not fall at rate 0");
        assertEq(plasmaVault.getUnrealizedManagementFee(), 0, "no fee at rate 0");
        assertEq(_realize(), 0, "nothing minted");
        assertEq(plasmaVault.balanceOf(managementFeeAccount), 0, "fee account empty");
        assertEq(_lastUpdate(), block.timestamp, "clock advanced");
    }

    /// @dev Only a pending fee (rate set to 0 after a checkpoint): the price already nets it and stays flat
    function testShouldPriceOnlyPendingFee_whenRateCheckpointedToZero() public {
        _deposit(user, userDeposit);
        uint256 priceFresh = _price();
        vm.warp(block.timestamp + ACCRUAL_PERIOD);
        uint256 grossAssets = plasmaVault.totalAssets();
        uint256 supply = plasmaVault.totalSupply();
        uint256 expectedPending = Math.mulDiv(grossAssets * ACCRUAL_PERIOD, MANAGEMENT_FEE, 365 days * 1e4);

        _configureRate(0);

        assertEq(_pending(), expectedPending, "checkpoint moved the accrual to pending");
        assertEq(plasmaVault.balanceOf(managementFeeAccount), 0, "checkpoint mints nothing");
        uint256 priceAfterCheckpoint = _price();
        assertLt(priceAfterCheckpoint, priceFresh, "pending fee is in the price");
        assertEq(
            priceAfterCheckpoint,
            Math.mulDiv(
                10 ** uint256(plasmaVault.decimals()),
                grossAssets + 1,
                supply + _feeShares(expectedPending, supply, grossAssets) + off
            ),
            "price nets exactly the pending fee"
        );

        vm.warp(block.timestamp + 60 days);
        assertEq(_price(), priceAfterCheckpoint, "no further accrual at rate 0");

        uint256 minted = _realize();

        assertEq(minted, _feeShares(expectedPending, supply, grossAssets), "formula shares for the pending fee");
        assertEq(plasmaVault.balanceOf(managementFeeAccount), minted, "fee account holds them");
        assertEq(_pending(), 0, "pending cleared");
        assertEq(_price(), priceAfterCheckpoint, "price unchanged by the realization");
    }

    /// @dev F > G after a loss: V is the clamped mint (denominator 1), the price is ~0, nothing reverts, and a second
    ///      realization in the same block mints nothing
    function testShouldClampAndNotRevert_whenPendingFeeExceedsAssetsAfterLoss() public {
        _deposit(user, userDeposit);
        vm.warp(block.timestamp + 365 days);
        _configureRate(MANAGEMENT_FEE);
        uint256 pending = _pending();
        assertGt(pending, 0, "pending fee from a year of accrual");

        /// @dev a loss: all but 100 wei of the assets are gone
        _drain(plasmaVault.totalAssets() - 100);
        uint256 grossAssets = plasmaVault.totalAssets();
        uint256 supply = plasmaVault.totalSupply();
        assertEq(grossAssets, 100, "G = 100");
        uint256 fee = plasmaVault.getUnrealizedManagementFee();
        assertGt(fee, grossAssets, "F > G");

        uint256 expected = grossAssets * (supply + off);
        assertEq(_feeShares(fee, supply, grossAssets), expected, "clamped formula: min(F, G) = G, denominator 1");
        assertEq(_price(), 0, "price is ~0");
        plasmaVault.maxDeposit(other);
        plasmaVault.maxMint(other);
        plasmaVault.maxWithdraw(user);
        plasmaVault.previewDeposit(1e6);
        plasmaVault.previewRedeem(1e8);

        uint256 minted = _realize();

        assertEq(minted, expected, "V is the clamped mint");
        assertEq(plasmaVault.balanceOf(managementFeeAccount), expected, "fee account holds it");
        assertEq(_price(), 0, "price still ~0");
        assertEq(_pending(), 0, "pending cleared");

        assertEq(_realize(), 0, "same block after a realization: V = 0");
        assertEq(plasmaVault.balanceOf(managementFeeAccount), expected, "balance unchanged by the second call");
        assertEq(plasmaVault.getUnrealizedManagementFee(), 0, "nothing accrued in the same block");
    }

    // ---------------------------------------------------------------------------------------------
    // 6. View consistency (no exit fee, no entry fee)
    // ---------------------------------------------------------------------------------------------

    function testShouldKeepViewsConsistent_whenManagementFeeAccrued() public {
        _deposit(user, userDeposit);
        _deposit(other, userDeposit / 2);
        vm.warp(block.timestamp + ACCRUAL_PERIOD);
        assertGt(plasmaVault.getUnrealizedManagementFee(), 0, "fee accrued");

        uint256 shares = plasmaVault.balanceOf(user) / 3;
        uint256 assets = userDeposit / 7;

        assertEq(plasmaVault.previewRedeem(shares), plasmaVault.convertToAssets(shares), "previewRedeem");
        assertEq(
            plasmaVault.maxWithdraw(user),
            plasmaVault.convertToAssets(plasmaVault.balanceOf(user)),
            "maxWithdraw"
        );
        assertEq(plasmaVault.previewDeposit(assets), plasmaVault.convertToShares(assets), "previewDeposit");

        uint256 mintCost = plasmaVault.previewMint(shares);
        assertGe(mintCost, plasmaVault.convertToAssets(shares), "previewMint rounds up");
        assertLe(mintCost - plasmaVault.convertToAssets(shares), 1, "previewMint within 1");
        uint256 withdrawShares = plasmaVault.previewWithdraw(assets);
        assertGe(withdrawShares, plasmaVault.convertToShares(assets), "previewWithdraw rounds up");
        assertLe(withdrawShares - plasmaVault.convertToShares(assets), 1, "previewWithdraw within 1");

        /// @dev the operations deliver exactly what the previews promised, although they realize the fee first
        uint256 snapshot = vm.snapshotState();

        uint256 previewedRedeem = plasmaVault.previewRedeem(shares);
        vm.prank(user);
        assertEq(plasmaVault.redeem(shares, user, user), previewedRedeem, "redeem pays previewRedeem");
        vm.revertToState(snapshot);

        uint256 previewedShares = plasmaVault.previewDeposit(assets);
        vm.prank(other);
        assertEq(plasmaVault.deposit(assets, other), previewedShares, "deposit mints previewDeposit");
        vm.revertToState(snapshot);

        uint256 previewedCost = plasmaVault.previewMint(shares);
        vm.prank(other);
        assertEq(plasmaVault.mint(shares, other), previewedCost, "mint costs previewMint");
        vm.revertToState(snapshot);

        uint256 previewedBurn = plasmaVault.previewWithdraw(assets);
        vm.prank(user);
        assertEq(plasmaVault.withdraw(assets, user, user), previewedBurn, "withdraw burns previewWithdraw");
    }

    // ---------------------------------------------------------------------------------------------
    // 7. F = G and F > G: no view reverts, deposit and mint within the limit pass
    // ---------------------------------------------------------------------------------------------

    /// @dev Example S = 10^14, G = F = 10^12 (6 decimals), off = 100, default cap
    function testShouldNotRevertAnyView_whenFeeEqualsAssetsWithDefaultCap() public {
        (uint256 supply, uint256 grossAssets) = _accrueFeeEqualToAssets(CapMode.DEFAULT, false);
        _assertViewsDoNotRevert(supply, grossAssets);

        assertGt(plasmaVault.maxDeposit(other), 0, "default cap leaves room to deposit");
        assertGt(plasmaVault.maxMint(other), 0, "default cap leaves room to mint");

        uint256 snapshot = vm.snapshotState();
        uint256 previewedShares = plasmaVault.previewDeposit(10 ** uint256(_assetDecimals()));
        vm.prank(other);
        assertEq(
            plasmaVault.deposit(10 ** uint256(_assetDecimals()), other),
            previewedShares,
            "deposit within the limit passes at previewDeposit"
        );
        vm.revertToState(snapshot);

        uint256 previewedCost = plasmaVault.previewMint(1e8);
        vm.prank(other);
        assertEq(plasmaVault.mint(1e8, other), previewedCost, "mint within the limit passes at previewMint");
    }

    function testShouldNotRevertAnyView_whenFeeExceedsAssetsWithDefaultCap() public {
        (uint256 supply, uint256 grossAssets) = _accrueFeeEqualToAssets(CapMode.DEFAULT, true);
        assertGt(plasmaVault.getUnrealizedManagementFee(), grossAssets, "F > G");
        _assertViewsDoNotRevert(supply, grossAssets);

        uint256 snapshot = vm.snapshotState();
        uint256 previewedShares = plasmaVault.previewDeposit(10 ** uint256(_assetDecimals()));
        vm.prank(other);
        assertEq(
            plasmaVault.deposit(10 ** uint256(_assetDecimals()), other),
            previewedShares,
            "deposit within the limit passes"
        );
        vm.revertToState(snapshot);

        uint256 previewedCost = plasmaVault.previewMint(1e8);
        vm.prank(other);
        assertEq(plasmaVault.mint(1e8, other), previewedCost, "mint within the limit passes");
    }

    /// @dev A binding (finite) cap with room above the virtual supply: the views do not divide by the zero unit
    ///      price, deposit and mint within the limit pass
    function testShouldNotRevertAnyView_whenFeeEqualsAssetsWithBindingCap() public {
        (uint256 supply, uint256 grossAssets) = _accrueFeeEqualToAssets(CapMode.ROOMY, false);
        _assertViewsDoNotRevert(supply, grossAssets);

        uint256 virtualSupply = supply + grossAssets * (supply + off);
        uint256 cap = PlasmaVaultGovernance(address(plasmaVault)).getTotalSupplyCap();
        assertGt(cap, virtualSupply, "cap has room above the virtual supply");
        uint256 room = cap - virtualSupply;
        assertEq(plasmaVault.maxMint(other), room, "maxMint is the room under the cap");
        /// @dev the unit price is 0, so one share is worth less than one unit and the room converts to few units
        assertEq(
            plasmaVault.maxDeposit(other),
            Math.mulDiv(room, grossAssets + 1, virtualSupply + off),
            "maxDeposit converts the room at the net price"
        );

        uint256 maxShares = plasmaVault.maxMint(other);
        uint256 previewedCost = plasmaVault.previewMint(maxShares);
        vm.prank(other);
        assertEq(plasmaVault.mint(maxShares, other), previewedCost, "mint(maxMint) passes");
        assertEq(plasmaVault.totalSupply(), cap, "supply fills the cap exactly");
    }

    /// @dev A binding cap with no room above the virtual supply: capacity is zero, views do not revert, deposit and
    ///      mint revert with the exact selector and the zero limit
    function testShouldReportZeroCapacity_whenFeeEqualsAssetsAndCapIsTight() public {
        (uint256 supply, uint256 grossAssets) = _accrueFeeEqualToAssets(CapMode.TIGHT, false);
        _assertViewsDoNotRevert(supply, grossAssets);

        assertEq(plasmaVault.maxDeposit(other), 0, "maxDeposit is 0");
        assertEq(plasmaVault.maxMint(other), 0, "maxMint is 0");

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSignature("ERC4626ExceededMaxDeposit(address,uint256,uint256)", other, 1e6, 0));
        plasmaVault.deposit(1e6, other);

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSignature("ERC4626ExceededMaxMint(address,uint256,uint256)", other, 1e8, 0));
        plasmaVault.mint(1e8, other);
    }

    // ---------------------------------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------------------------------

    /// @dev Deposits, raises the rate to the 5% maximum (a checkpoint with no time passed), sets the supply cap per
    ///      capMode_ and warps 20 years so that F = G (one more year for F > G).
    ///      ROOMY: finite cap with 1e12 shares of room above the virtual supply S + V.
    ///      TIGHT: finite cap 1e8 shares above the minted supply, so no room once the virtual shares count.
    function _accrueFeeEqualToAssets(
        CapMode capMode_,
        bool exceed_
    ) internal returns (uint256 supply, uint256 grossAssets) {
        _deposit(user, userDeposit);
        _configureRate(MAX_MANAGEMENT_FEE);
        supply = plasmaVault.totalSupply();
        grossAssets = plasmaVault.totalAssets();
        assertEq(supply, userDeposit * off, "S = deposit * off");

        if (capMode_ == CapMode.ROOMY) {
            /// @dev virtual supply is S + G * (S + off), the clamped mint of F >= G
            PlasmaVaultGovernance(address(plasmaVault)).setTotalSupplyCap(supply + grossAssets * (supply + off) + 1e12);
        } else if (capMode_ == CapMode.TIGHT) {
            PlasmaVaultGovernance(address(plasmaVault)).setTotalSupplyCap(supply + 1e8);
        }

        vm.warp(block.timestamp + 20 * 365 days + (exceed_ ? 365 days : 0));

        uint256 fee = plasmaVault.getUnrealizedManagementFee();
        if (exceed_) {
            assertGt(fee, grossAssets, "F > G");
        } else {
            assertEq(fee, grossAssets, "F == G");
        }
    }

    /// @dev Calls every max, preview and convert view; none may revert. The unit price is the formula value
    function _assertViewsDoNotRevert(uint256 supply_, uint256 grossAssets_) internal view {
        uint256 virtualShares = grossAssets_ * (supply_ + off);
        assertEq(
            plasmaVault.convertToAssets(10 ** uint256(plasmaVault.decimals())),
            Math.mulDiv(10 ** uint256(plasmaVault.decimals()), grossAssets_ + 1, supply_ + virtualShares + off),
            "unit price follows the clamped formula (and may be 0)"
        );
        plasmaVault.maxDeposit(other);
        plasmaVault.maxMint(other);
        plasmaVault.maxWithdraw(user);
        plasmaVault.maxRedeem(user);
        plasmaVault.previewDeposit(1e6);
        plasmaVault.previewMint(1e8);
        plasmaVault.previewWithdraw(1e6);
        plasmaVault.previewRedeem(1e8);
        plasmaVault.convertToShares(1e6);
        plasmaVault.convertToAssets(1e8);
    }

    /// @dev D-002, computed independently of the vault: F is clamped to G, the denominator is G - F + 1
    function _feeShares(uint256 fee_, uint256 supply_, uint256 grossAssets_) internal view returns (uint256) {
        if (fee_ == 0 || supply_ == 0 || grossAssets_ == 0) {
            return 0;
        }
        uint256 clamped = fee_ > grossAssets_ ? grossAssets_ : fee_;
        return Math.mulDiv(clamped, supply_ + off, grossAssets_ - clamped + 1);
    }

    /// @dev Price of one vault share unit (10 ** vault decimals), in asset units
    function _price() internal view returns (uint256) {
        return plasmaVault.convertToAssets(10 ** uint256(plasmaVault.decimals()));
    }

    function _pending() internal view returns (uint256) {
        return uint256(vm.load(address(plasmaVault), PENDING_SLOT));
    }

    function _lastUpdate() internal view returns (uint256) {
        return PlasmaVaultGovernance(address(plasmaVault)).getManagementFeeData().lastUpdateTimestamp;
    }

    function _realize() internal returns (uint256) {
        vm.prank(alpha);
        return plasmaVault.realizeManagementFee();
    }

    /// @dev FeeManager is the holder of TECH_MANAGEMENT_FEE_MANAGER_ROLE; a rate change is a checkpoint (IL-8742)
    function _configureRate(uint256 rate_) internal {
        vm.prank(FeeAccount(managementFeeAccount).FEE_MANAGER());
        PlasmaVaultGovernance(address(plasmaVault)).configureManagementFee(managementFeeAccount, rate_);
    }

    /// @dev Zeroes the fee account (lowest 20 bytes of the ManagementFeeData slot), keeps rate and clock
    function _clearFeeAccount() internal {
        bytes32 packed = vm.load(address(plasmaVault), MANAGEMENT_FEE_DATA_SLOT);
        vm.store(address(plasmaVault), MANAGEMENT_FEE_DATA_SLOT, packed & ~bytes32(uint256(type(uint160).max)));
    }

    /// @dev A loss: assets leave the vault
    function _drain(uint256 amount_) internal {
        vm.prank(address(plasmaVault));
        asset.transfer(address(0xDEAD), amount_);
    }

    function _countRealizedEvents() internal returns (uint256 count) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(plasmaVault) && logs[i].topics[0] == ManagementFeeRealized.selector) {
                ++count;
            }
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

    function _createAccessManager() internal returns (IporFusionAccessManager) {
        usersToRoles.superAdmin = atomist;
        usersToRoles.atomist = atomist;
        address[] memory alphas = new address[](1);
        alphas[0] = alpha;
        usersToRoles.alphas = alphas;
        return RoleLib.createAccessManager(usersToRoles, 0, vm);
    }
}

/// @title PlasmaVaultManagementFeeInPrice6Test
/// @notice IL-8870 management fee in the share price, 6 asset decimals
contract PlasmaVaultManagementFeeInPrice6Test is PlasmaVaultManagementFeeInPriceBase {
    function _assetDecimals() internal pure override returns (uint8) {
        return 6;
    }
}

/// @title PlasmaVaultManagementFeeInPrice18Test
/// @notice IL-8870 management fee in the share price, 18 asset decimals
contract PlasmaVaultManagementFeeInPrice18Test is PlasmaVaultManagementFeeInPriceBase {
    function _assetDecimals() internal pure override returns (uint8) {
        return 18;
    }
}
