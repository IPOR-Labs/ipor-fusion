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
import {FeeManagerFactory, FeeConfig, RecipientFee} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {FeeManager, FeeManagerInitData} from "../../contracts/managers/fee/FeeManager.sol";
import {FeeAccount} from "../../contracts/managers/fee/FeeAccount.sol";
import {FuseAction} from "../../contracts/interfaces/IPlasmaVault.sol";
import {IMarketBalanceFuse} from "../../contracts/fuses/IMarketBalanceFuse.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {PlasmaVaultConfigurator} from "../utils/PlasmaVaultConfigurator.sol";
import {RoleLib, UsersToRoles} from "../RoleLib.sol";
import {MockERC20Decimals} from "../unitTest/fuses/term_finance/mocks/MockERC20Decimals.sol";

/// @dev Empty market with a zero balance; only lets updateMarketsBalances run through a registered market
contract ZeroBalanceFuse is IMarketBalanceFuse {
    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    function balanceOf() external pure override returns (uint256) {
        return 0;
    }
}

/// @title FeeManager high-water mark after the fee mint (IL-8744)
/// @notice The HWM must be the share price right after the performance fee shares are minted, otherwise the
///         recovery from the diluted price back to the pre-mint rate is fee-free and frequent crystallization
///         collects only p / (1 + p) instead of p.
contract FeeManagerHwmPostDilutionTest is Test {
    address public atomist = address(this);
    address public alpha = address(0x1);
    address public user = address(0xA11CE);

    /// @dev 20% performance fee (FeeManager percentages use 2 decimals, 10000 = 100%)
    uint256 public constant PERFORMANCE_FEE = 2000;

    MockERC20Decimals public asset;
    UsersToRoles public usersToRoles;
    IporFusionAccessManager public accessManager;
    WithdrawManager public withdrawManager;
    PlasmaVault public plasmaVault;
    address public performanceFeeAccount;
    uint256 public oneShare;
    uint256 public userDeposit;

    /// @dev IL-9601: the HWM and the performance fee rate are stored per 10 ** decimals() shares times this scale
    uint256 public constant HWM_SCALE = 1e12;

    // ---------------------------------------------------------------------------------------------
    // T1 - the HWM is the post-mint price and the recovery to the pre-mint rate is charged
    // ---------------------------------------------------------------------------------------------

    function testShouldStorePostMintPriceAsHwmAndChargeRecoveryToPreMintRate() public {
        _deployVault(6);
        _deposit();

        asset.mint(address(plasmaVault), userDeposit / 10);
        uint256 preMintRate = _rate();
        _crystallize();

        uint256 feeShares1 = plasmaVault.balanceOf(performanceFeeAccount);
        uint256 hwm = _hwm();
        uint256 postMintRate = _rate();

        assertGt(feeShares1, 0, "round 1: performance fee minted");
        assertEq(hwm, postMintRate, "HWM equals the share price after the fee mint");
        assertLt(postMintRate, preMintRate, "the mint diluted the price");

        // Round 2: gain that lifts the price from the post-mint rate up to (just under) the pre-mint rate
        uint256 donation2 = ((preMintRate - postMintRate) * plasmaVault.totalSupply()) / (oneShare * HWM_SCALE) - 3e6;
        asset.mint(address(plasmaVault), donation2);
        assertLe(_rate(), preMintRate, "precondition: still below the pre-mint rate");
        _crystallize();

        uint256 feeShares2 = plasmaVault.balanceOf(performanceFeeAccount) - feeShares1;
        assertGt(feeShares2, 0, "round 2: recovery to the old pre-mint rate is charged");

        uint256 feeValue2 = plasmaVault.convertToAssets(feeShares2);
        assertApproxEqRel(
            feeValue2,
            (donation2 * PERFORMANCE_FEE) / 10000,
            0.005e18,
            "round 2 fee is about 20% of gain"
        );
        assertEq(_hwm(), _rate(), "HWM follows the post-mint price again");
    }

    // ---------------------------------------------------------------------------------------------
    // T2 / T3 - effective fee with frequent crystallization
    // ---------------------------------------------------------------------------------------------

    /// @dev Before the fix 20 x +1% collected 16.79% (p / (1 + p) = 16.67%)
    function testShouldCollectConfiguredFeeWithTwentyOnePercentSteps() public {
        _deployVault(6);
        _deposit();

        uint256 bps = _runSteps(20, 10_000);

        assertGe(bps, 1990, "effective fee is at least 19.90%");
        assertLe(bps, 2010, "effective fee is at most 20.10%");
    }

    /// @dev 1000 x +9 ppm on a 6-decimals asset: pins the rounding of the stored HWM. Analytic Floor
    ///      (mulDiv(R, S, S + f)) overcharges at 20.36%, Ceil undercharges at 18.51%.
    function testShouldCollectConfiguredFeeWithTinyStepsUsdc() public {
        _deployVault(6);
        _deposit();

        uint256 bps = _runSteps(1000, 9);

        assertGe(bps, 1990, "effective fee (6 decimals) >= 19.90%");
        assertLe(bps, 2010, "effective fee (6 decimals) <= 20.10%");
    }

    function testShouldCollectConfiguredFeeWithTinyStepsEighteenDecimals() public {
        _deployVault(18);
        _deposit();

        uint256 bps = _runSteps(1000, 9);

        assertGe(bps, 1990, "effective fee (18 decimals) >= 19.90%");
        assertLe(bps, 2010, "effective fee (18 decimals) <= 20.10%");
    }

    // ---------------------------------------------------------------------------------------------
    // T4 - parity on every crystallization path
    // ---------------------------------------------------------------------------------------------

    function testShouldStorePostMintPriceOnExecute() public {
        _deployVault(6);
        _deposit();
        asset.mint(address(plasmaVault), userDeposit / 10);

        _crystallize();

        assertGt(plasmaVault.balanceOf(performanceFeeAccount), 0, "fee minted");
        assertEq(_hwm(), _rate(), "execute: HWM == price of one share");
    }

    function testShouldStorePostMintPriceOnUpdateMarketsBalances() public {
        _deployVault(6);
        _deposit();
        _grantUpdateMarketsBalances();
        asset.mint(address(plasmaVault), userDeposit / 10);

        uint256[] memory markets = new uint256[](1);
        markets[0] = 1;
        vm.prank(alpha);
        plasmaVault.updateMarketsBalances(markets);

        assertGt(plasmaVault.balanceOf(performanceFeeAccount), 0, "fee minted");
        assertEq(_hwm(), _rate(), "updateMarketsBalances: HWM == price of one share");
    }

    /// @dev withdraw / redeem crystallize before burning the caller's shares; the burn pays assets rounded
    ///      down and burns shares rounded up, so it is price-neutral up to dust and never lowers the price:
    ///      HWM <= price (no fee-free gap) and HWM ~ price within 1e-9 relative
    function testShouldStorePostMintPriceOnWithdraw() public {
        _deployVault(6);
        _deposit();
        asset.mint(address(plasmaVault), userDeposit / 10);

        uint256 preMintRate = _rate();
        vm.prank(user);
        plasmaVault.withdraw(1_000e6, user, user);

        assertGt(plasmaVault.balanceOf(performanceFeeAccount), 0, "fee minted");
        assertLe(_hwm(), _rate(), "withdraw: price is not below the HWM");
        assertApproxEqRel(_hwm(), _rate(), 1e9, "withdraw: HWM ~ price of one share");
        assertLt(_hwm(), preMintRate, "HWM is below the pre-mint rate");
    }

    function testShouldStorePostMintPriceOnRedeem() public {
        _deployVault(6);
        _deposit();
        asset.mint(address(plasmaVault), userDeposit / 10);

        uint256 preMintRate = _rate();
        vm.prank(user);
        plasmaVault.redeem(1_000e8, user, user);

        assertGt(plasmaVault.balanceOf(performanceFeeAccount), 0, "fee minted");
        assertLe(_hwm(), _rate(), "redeem: price is not below the HWM");
        assertApproxEqRel(_hwm(), _rate(), 1e9, "redeem: HWM ~ price of one share");
        assertLt(_hwm(), preMintRate, "HWM is below the pre-mint rate");
    }

    // ---------------------------------------------------------------------------------------------
    // T5 - second crystallization in the same block
    // ---------------------------------------------------------------------------------------------

    function testShouldNotChargeTwiceInTheSameBlock() public {
        _deployVault(6);
        _deposit();
        asset.mint(address(plasmaVault), userDeposit / 10);

        _crystallize();
        uint256 feeShares1 = plasmaVault.balanceOf(performanceFeeAccount);
        uint256 hwm1 = _hwm();

        _crystallize();

        assertGt(feeShares1, 0, "first crystallization minted");
        assertEq(plasmaVault.balanceOf(performanceFeeAccount), feeShares1, "second crystallization mints nothing");
        assertEq(_hwm(), hwm1, "HWM unchanged by the second crystallization");
    }

    // ---------------------------------------------------------------------------------------------
    // T6 - unchanged behaviour
    // ---------------------------------------------------------------------------------------------

    /// @dev initialize() sets the HWM to the starting rate and no fee shares exist
    function testShouldInitializeHwmToStartingRateWithoutFee() public {
        _deployVault(6);

        assertEq(_hwm(), 10 ** 6 * HWM_SCALE, "HWM = initial rate (1 asset unit per share, scaled)");
        assertEq(plasmaVault.balanceOf(performanceFeeAccount), 0, "no fee shares");
    }

    /// @dev First positive fee: 1,000,000 deposited, 100,000 donated, 20% fee, HWM 1_000_000 * 1e12 (IL-9601 scale),
    ///      rate 1_099_999_999_999_900_000 (1.1 less the virtual share offset: 1.0999999999999 asset units per share).
    ///      Before IL-9601 the unit was 1e12 smaller: HWM 1_000_000, rate 1_099_999 (the floor of 1.1). IL-8870: the fee shares are sized on the price after their
    ///      own mint, S * f / (10000 * rate - f) with f = fee * (rate - HWM), so they are worth 20% of the gain
    ///      (less the fee on the price unit the floor of the rate drops: 0.2 asset on 1,000,000 shares). The sizing
    ///      before IL-8870, S * (rate - HWM) / rate * fee = 1818165289241 shares (unchanged by IL-8744), was worth
    ///      19,642.68, that is 19.64% of the gain.
    function testShouldSizeFirstFeeSharesOnPostMintPrice() public {
        _deployVault(6);
        _deposit();
        uint256 gain = userDeposit / 10;
        asset.mint(address(plasmaVault), gain);

        _crystallize();

        uint256 feeShares = plasmaVault.balanceOf(performanceFeeAccount);
        uint256 feeValue = PERFORMANCE_FEE * (RATE_AFTER_GAIN - 1_000_000 * HWM_SCALE);
        assertEq(
            feeShares,
            (plasmaVault.balanceOf(user) * feeValue) / (10000 * RATE_AFTER_GAIN - feeValue),
            "first fee shares: S * f / (10000 * rate - f)"
        );
        assertEq(feeShares, FIRST_FEE_SHARES, "first fee shares");
        assertApproxEqAbs(
            plasmaVault.convertToAssets(feeShares),
            (gain * PERFORMANCE_FEE) / 10000,
            0.2e6,
            "the fee shares are worth 20% of the gain"
        );
    }

    /// @dev feeShares == 0 keeps storing the current rate (S = 1 wei of supply, delta = 1)
    function testShouldStoreCurrentRateWhenFeeSharesAreZero() public {
        address vaultMock = makeAddr("vaultMock");
        address authority = makeAddr("authority");
        vm.etch(authority, hex"00");
        RecipientFee[] memory emptyFees = new RecipientFee[](0);
        FeeManager feeManager = new FeeManager(
            FeeManagerInitData({
                initialAuthority: authority,
                plasmaVault: vaultMock,
                iporDaoManagementFee: 0,
                iporDaoPerformanceFee: 0,
                iporDaoFeeRecipientAddress: makeAddr("dao"),
                recipientManagementFees: emptyFees,
                recipientPerformanceFees: emptyFees
            })
        );

        vm.startPrank(vaultMock);
        feeManager.calculateAndUpdatePerformanceFee(1e18, 1, PERFORMANCE_FEE, 18);
        (, uint256 feeShares) = feeManager.calculateAndUpdatePerformanceFee(1e18 + 1, 1, PERFORMANCE_FEE, 18);
        vm.stopPrank();

        assertEq(feeShares, 0, "no fee shares");
        assertEq(feeManager.getPlasmaVaultHighWaterMarkPerformanceFee().highWaterMark, 1e18 + 1, "HWM = current rate");
    }

    /// @dev IL-5727 drawdown: with updateInterval > 0 the HWM is lowered to the current rate after the interval
    function testShouldLowerHwmAfterDrawdownWithUpdateInterval() public {
        _deployVault(6);
        _deposit();
        FeeManager(FeeAccount(performanceFeeAccount).FEE_MANAGER()).updateIntervalHighWaterMarkPerformanceFee(1 days);

        asset.mint(address(plasmaVault), userDeposit / 10);
        _crystallize();
        uint256 hwmAfterGain = _hwm();

        // 50% drawdown
        uint256 loss = plasmaVault.totalAssets() / 2;
        vm.prank(address(plasmaVault));
        asset.transfer(address(0xdead), loss);
        uint256 lowRate = _rate();
        assertLt(lowRate, hwmAfterGain, "precondition: price below HWM");

        _crystallize();
        assertEq(_hwm(), hwmAfterGain, "interval not passed: HWM kept");

        vm.warp(block.timestamp + 1 days);
        _crystallize();
        assertEq(_hwm(), lowRate, "interval passed: HWM lowered to the current rate");
    }

    // ---------------------------------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------------------------------

    /// @dev floor(1e20 * (1.1e12 + 1) / (1e14 + 100)): the scaled rate after the 10% gain, 1e14 shares, offset 100
    uint256 internal constant RATE_AFTER_GAIN = 1_099_999_999_999_900_000;

    /// @dev 1e14 * f / (10000 * RATE_AFTER_GAIN - f) with f = 2000 * (RATE_AFTER_GAIN - 1e18) = 1.999999999998e20
    ///      (see testShouldSizeFirstFeeSharesOnPostMintPrice); 1851834705062 before IL-9601, the exact value of the
    ///      unscaled rate 1.1 is 1851851851851
    uint256 internal constant FIRST_FEE_SHARES = 1851851851850;

    /// @dev Effective fee paid by the depositor in bps of its gross gain over `steps_` crystallized gains of
    ///      `ppm_` parts per million of total assets (10_000 ppm = 1%)
    function _runSteps(uint256 steps_, uint256 ppm_) internal returns (uint256 effectiveFeeBps) {
        uint256 userShares = plasmaVault.balanceOf(user);
        uint256 userGrossGain;

        for (uint256 i; i < steps_; ++i) {
            uint256 yield_ = (plasmaVault.totalAssets() * ppm_) / 1_000_000;
            userGrossGain += (yield_ * userShares) / plasmaVault.totalSupply();
            asset.mint(address(plasmaVault), yield_);
            _crystallize();
        }

        uint256 userNetGain = plasmaVault.convertToAssets(userShares) - userDeposit;
        uint256 feePaid = userGrossGain - userNetGain;
        effectiveFeeBps = (feePaid * 10000) / userGrossGain;
    }

    /// @dev Share price in the HWM unit: assets per 10 ** decimals() shares times HWM_SCALE
    function _rate() internal view returns (uint256) {
        return plasmaVault.convertToAssets(oneShare * HWM_SCALE);
    }

    function _hwm() internal view returns (uint256) {
        return _feeManager().getPlasmaVaultHighWaterMarkPerformanceFee().highWaterMark;
    }

    function _crystallize() internal {
        vm.prank(alpha);
        plasmaVault.execute(new FuseAction[](0));
    }

    function _feeManager() internal view returns (FeeManager) {
        return FeeManager(FeeAccount(performanceFeeAccount).FEE_MANAGER());
    }

    function _grantUpdateMarketsBalances() internal {
        bytes4[] memory updateSig = new bytes4[](1);
        updateSig[0] = PlasmaVault.updateMarketsBalances.selector;
        accessManager.setTargetFunctionRole(address(plasmaVault), updateSig, Roles.UPDATE_MARKETS_BALANCES_ROLE);
        accessManager.grantRole(Roles.UPDATE_MARKETS_BALANCES_ROLE, alpha, 0);
    }

    function _deposit() internal {
        asset.mint(user, userDeposit);
        vm.startPrank(user);
        asset.approve(address(plasmaVault), type(uint256).max);
        plasmaVault.deposit(userDeposit, user);
        vm.stopPrank();
    }

    function _deployVault(uint8 assetDecimals_) internal {
        asset = new MockERC20Decimals("Mock Asset", "mA", assetDecimals_);
        userDeposit = 1_000_000 * 10 ** assetDecimals_;

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
                    iporDaoManagementFee: 0,
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

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig({marketId: 1, fuse: address(new ZeroBalanceFuse(1))});

        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            atomist,
            address(plasmaVault),
            new address[](0),
            balanceFuses,
            new MarketSubstratesConfig[](0)
        );

        performanceFeeAccount = PlasmaVaultGovernance(address(plasmaVault)).getPerformanceFeeData().feeAccount;
        oneShare = 10 ** uint256(plasmaVault.decimals());
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
