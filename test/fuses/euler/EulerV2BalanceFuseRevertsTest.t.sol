// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IEVC} from "@ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";

import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {EulerFuseLib, EulerSubstrate} from "../../../contracts/fuses/euler/EulerFuseLib.sol";
import {EulerV2SupplyFuse, EulerV2SupplyFuseEnterData} from "../../../contracts/fuses/euler/EulerV2SupplyFuse.sol";
import {EulerV2BalanceFuse} from "../../../contracts/fuses/euler/EulerV2BalanceFuse.sol";
import {IBorrowing} from "../../../contracts/fuses/euler/ext/IBorrowing.sol";
import {IEulerV2VaultGovernance} from "../../../contracts/fuses/euler/ext/IEulerV2VaultGovernance.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {IporMath} from "../../../contracts/libraries/math/IporMath.sol";
import {Errors} from "../../../contracts/libraries/errors/Errors.sol";
import {
    PlasmaVault,
    PlasmaVaultInitData,
    MarketBalanceFuseConfig,
    MarketSubstratesConfig,
    FuseAction
} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultCloneLib} from "../../test_helpers/PlasmaVaultCloneLib.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {FeeAccount} from "../../../contracts/managers/fee/FeeAccount.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {PlasmaVaultConfigurator} from "../../utils/PlasmaVaultConfigurator.sol";
import {
    IporFusionAccessManagerInitializerLibV1,
    InitializationData,
    DataForInitialization,
    PlasmaVaultAddress
} from "../../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";

/// @title EulerV2BalanceFuseRevertsTest
/// @notice Unit test (mocked Euler vault and oracle): the zero-price revert of EulerV2BalanceFuse.balanceOf, the floor
///         at zero of an underwater sub-account (IL-9528: a negative net no longer reverts), plus a positive control.
contract EulerV2BalanceFuseRevertsTest is Test {
    uint256 private constant _MARKET_ID = IporFusionMarkets.EULER_V2;
    address private constant _EVC = address(0x1234);
    address private constant _EULER_VAULT = address(0xE1);
    address private constant _ASSET = address(0xA1);
    address private constant _ORACLE = address(0x0AC1E);
    bytes1 private constant _SUB_ACCOUNT = 0x01;

    uint256 private constant _PRICE = 2000e8;
    uint256 private constant _PRICE_DECIMALS = 8;
    uint256 private constant _ASSET_DECIMALS = 18;

    EulerV2BalanceFuse private _balanceFuse;
    PlasmaVaultMock private _vault;
    address private _subAccount;

    function setUp() public {
        _balanceFuse = new EulerV2BalanceFuse(_MARKET_ID, _EVC);
        _vault = new PlasmaVaultMock(address(0), address(_balanceFuse));
        _subAccount = EulerFuseLib.generateSubAccountAddress(address(_vault), _SUB_ACCOUNT);

        _vault.setPriceOracleMiddleware(_ORACLE);

        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: _EULER_VAULT, isCollateral: true, canBorrow: true, subAccounts: _SUB_ACCOUNT})
        );
        _vault.grantMarketSubstrates(_MARKET_ID, substrates);

        vm.mockCall(_EULER_VAULT, abi.encodeWithSignature("asset()"), abi.encode(_ASSET));
        vm.mockCall(_ASSET, abi.encodeWithSignature("decimals()"), abi.encode(uint8(_ASSET_DECIMALS)));
        // 10e18 shares convert 1:1 to 10e18 assets => collateral 10 * 2000 = 20_000 USD
        vm.mockCall(_EULER_VAULT, abi.encodeWithSignature("balanceOf(address)", _subAccount), abi.encode(10e18));
        vm.mockCall(_EULER_VAULT, abi.encodeWithSignature("convertToAssets(uint256)", 10e18), abi.encode(10e18));

        // the eVault is the controller of its own debt and the only collateral enabled on the EVC; an EVault never
        // recognizes its own shares, so nothing is seizable: the sub-account is valued max(0, collateral - debt)
        vm.mockCall(
            _EULER_VAULT,
            abi.encodeWithSelector(IEulerV2VaultGovernance.configFlags.selector),
            abi.encode(uint32(0))
        );
        address[] memory collaterals = new address[](1);
        collaterals[0] = _EULER_VAULT;
        vm.mockCall(_EVC, abi.encodeWithSelector(IEVC.getCollaterals.selector, _subAccount), abi.encode(collaterals));
        vm.mockCall(
            _EULER_VAULT,
            abi.encodeWithSelector(IEulerV2VaultGovernance.LTVFull.selector, _EULER_VAULT),
            abi.encode(uint16(0), uint16(0), uint16(0), uint48(0), uint32(0))
        );
    }

    function testShouldRevertWithUnsupportedQuoteCurrencyWhenOraclePriceIsZero() public {
        // given - the oracle returns price 0 for the Euler vault asset
        _mockPrice(0);
        _mockDebt(0);

        // then
        vm.expectRevert(Errors.UnsupportedQuoteCurrencyFromOracle.selector);

        // when
        _vault.balanceOf();
    }

    function testShouldReturnZeroWhenDebtExceedsCollateral() public {
        // given - collateral 20_000 USD, debt 30_000 USD => net -10_000 USD (WAD)
        _mockPrice(_PRICE);
        _mockDebt(15e18);

        // then - the debt branch runs (the controller is read) ...
        vm.expectCall(_EULER_VAULT, abi.encodeWithSelector(IEulerV2VaultGovernance.configFlags.selector));

        // when
        uint256 balance = _vault.balanceOf();

        // ... and the underwater sub-account is floored at zero instead of reverting (IL-9528)
        assertEq(balance, 0, "underwater sub-account floored at zero");
    }

    function testShouldReturnNetBalanceWhenCollateralExceedsDebt() public {
        // given - collateral 20_000 USD, debt 5_000 USD
        _mockPrice(_PRICE);
        _mockDebt(2.5e18);

        // when
        uint256 balance = _vault.balanceOf();

        // then
        assertEq(balance, 15_000e18, "net balance in WAD");
    }

    function testShouldReturnZeroWhenDebtEqualsCollateral() public {
        // given - net exactly 0 is the boundary that does not revert
        _mockPrice(_PRICE);
        _mockDebt(10e18);

        // when
        uint256 balance = _vault.balanceOf();

        // then
        assertEq(balance, 0, "zero net does not revert");
    }

    function _mockPrice(uint256 price_) private {
        vm.mockCall(
            _ORACLE,
            abi.encodeWithSignature("getAssetPrice(address)", _ASSET),
            abi.encode(price_, _PRICE_DECIMALS)
        );
    }

    function _mockDebt(uint256 debt_) private {
        vm.mockCall(_EULER_VAULT, abi.encodeWithSignature("debtOf(address)", _subAccount), abi.encode(debt_));
    }
}

/// @title EulerV2BalanceFuseCacheUnchangedForkTest
/// @notice Fork test on a real PlasmaVault: after EulerV2BalanceFuse.balanceOf reverts (zero price), the production
///         refresh path (PlasmaVault.updateMarketsBalances -> PlasmaVaultMarketsLib) propagates the revert and leaves
///         the market 11 cache and totalAssets() unchanged. A negative net of a sub-account does not revert: the
///         sub-account is floored at zero (IL-9528) and the refresh stores that value.
contract EulerV2BalanceFuseCacheUnchangedForkTest is Test {
    address private constant _EVC = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;
    address private constant EULER_VAULT_PRIME_USDC = 0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9;
    address private constant EULER_VAULT_WETH = 0xb3b36220fA7d12f7055dab5c9FD18E860e9a6bF8;

    address private constant _W_ETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant _USDC_HOLDER = 0x137000352B4ed784e8fa8815d225c713AB2e7Dc9;

    address private constant _ETH_USD_CHAINLINK = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address private constant _CHAINLINK_REGISTRY = 0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf;

    bytes1 private constant _SUB_ONE = 0x01;

    address private constant _ATOMIST = address(1111111);
    address private constant _ALPHA = address(2222222);
    address private constant _USER = address(12121212);

    address private _plasmaVault;
    address private _priceOracle;
    address private _accessManager;
    address private _withdrawManager;
    address private _supplyFuse;
    address private _balanceFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 20990351);

        _priceOracle = _createPriceOracle();
        _accessManager = address(new IporFusionAccessManager(_ATOMIST, 0));
        _withdrawManager = address(new WithdrawManager(_accessManager));

        vm.startPrank(_ATOMIST);
        _plasmaVault = address(PlasmaVaultCloneLib.newPlasmaVault());
        PlasmaVault(_plasmaVault).proxyInitialize(
            PlasmaVaultInitData(
                "EULER BALANCE REVERTS",
                "EBR",
                _USDC,
                _priceOracle,
                FeeConfigHelper.createZeroFeeConfig(),
                _accessManager,
                address(new PlasmaVaultBase()),
                _withdrawManager,
                address(0)
            )
        );
        vm.stopPrank();

        address[] memory fuses = new address[](1);
        _supplyFuse = address(new EulerV2SupplyFuse(IporFusionMarkets.EULER_V2, _EVC));
        fuses[0] = _supplyFuse;

        _balanceFuse = address(new EulerV2BalanceFuse(IporFusionMarkets.EULER_V2, _EVC));
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(IporFusionMarkets.EULER_V2, _balanceFuse);

        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            _ATOMIST,
            _plasmaVault,
            fuses,
            balanceFuses,
            new MarketSubstratesConfig[](0)
        );

        _initAccessManager();
        _grantEulerSubstrates();

        // depositor puts 10,000 USDC into the vault; ALPHA supplies 10 WETH into the Euler WETH vault (sub-account 0x01)
        vm.prank(_USDC_HOLDER);
        ERC20(_USDC).transfer(_USER, 10_000e6);
        vm.startPrank(_USER);
        ERC20(_USDC).approve(_plasmaVault, 10_000e6);
        PlasmaVault(_plasmaVault).deposit(10_000e6, _USER);
        vm.stopPrank();

        deal(_W_ETH, _plasmaVault, 10e18);
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            _supplyFuse,
            abi.encodeWithSignature(
                "enter((address,uint256,bytes1))",
                EulerV2SupplyFuseEnterData({eulerVault: EULER_VAULT_WETH, maxAmount: 10e18, subAccount: _SUB_ONE})
            )
        );
        vm.prank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(calls);

        _refreshEulerMarket();
    }

    function testShouldKeepCacheAndTotalAssetsUnchangedWhenOraclePriceIsZero() public {
        // given - a non-zero cached EULER_V2 market value
        uint256 cacheBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.EULER_V2);
        uint256 totalAssetsBefore = PlasmaVault(_plasmaVault).totalAssets();
        assertGt(cacheBefore, 0, "market 11 cache is non-zero before the failure");

        // and - the oracle price of the Euler vault asset (WETH) drops to 0; the price of the vault asset (USDC) stays valid
        vm.mockCall(
            _priceOracle,
            abi.encodeWithSignature("getAssetPrice(address)", _W_ETH),
            abi.encode(uint256(0), uint256(8))
        );

        // then - the production refresh path reverts with the exact error
        vm.expectRevert(Errors.UnsupportedQuoteCurrencyFromOracle.selector);

        // when
        _refreshEulerMarket();

        // and - cache and NAV are untouched
        assertEq(
            PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.EULER_V2),
            cacheBefore,
            "market 11 cache unchanged"
        );
        assertEq(PlasmaVault(_plasmaVault).totalAssets(), totalAssetsBefore, "totalAssets unchanged");
    }

    function testShouldFloorCacheAtZeroWhenNetIsNegative() public {
        // given - a non-zero cached EULER_V2 market value
        uint256 cacheBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.EULER_V2);
        uint256 totalAssetsBefore = PlasmaVault(_plasmaVault).totalAssets();
        assertGt(cacheBefore, 0, "market 11 cache is non-zero before the debt");

        // and - the USDC Euler vault reports a debt of 1,000,000 USDC for sub-account 0x01, far above the WETH collateral
        address subOne = EulerFuseLib.generateSubAccountAddress(_plasmaVault, _SUB_ONE);
        uint256 debt = 1_000_000e6;
        vm.mockCall(
            EULER_VAULT_PRIME_USDC,
            abi.encodeWithSelector(IBorrowing.debtOf.selector, subOne),
            abi.encode(debt)
        );

        int256 expectedNet = _expectedNetWad(subOne, debt);
        assertLt(expectedNet, 0, "net is negative under the vault oracle");

        // when - the production refresh path does not revert
        _refreshEulerMarket();

        // then - the only sub-account is underwater: the market is floored at zero and NAV drops by the old cache
        assertEq(
            PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.EULER_V2),
            0,
            "market 11 cache floored at zero"
        );
        assertEq(
            PlasmaVault(_plasmaVault).totalAssets(),
            totalAssetsBefore - cacheBefore,
            "totalAssets drops by the old market 11 cache"
        );
    }

    function testShouldRefreshCacheAgainOnceMocksAreCleared() public {
        // given - the underwater state: the refresh stores the floored zero
        address subOne = EulerFuseLib.generateSubAccountAddress(_plasmaVault, _SUB_ONE);
        vm.mockCall(
            EULER_VAULT_PRIME_USDC,
            abi.encodeWithSelector(IBorrowing.debtOf.selector, subOne),
            abi.encode(uint256(1_000_000e6))
        );
        _refreshEulerMarket();
        assertEq(PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.EULER_V2), 0, "floored at zero");

        // when - the condition disappears
        vm.clearMockedCalls();
        _refreshEulerMarket();

        // then - the refresh stores the collateral value again (positive control for the floor and the revert test)
        assertGt(PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.EULER_V2), 0, "cache refreshed");
    }

    function _refreshEulerMarket() private {
        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.EULER_V2;
        PlasmaVault(_plasmaVault).updateMarketsBalances(marketIds);
    }

    /// @dev Net of sub-account 0x01 in USD (WAD) as EulerV2BalanceFuse computes it: WETH collateral minus USDC debt
    function _expectedNetWad(address subAccount_, uint256 debt_) private view returns (int256) {
        uint256 shares = ERC20(EULER_VAULT_WETH).balanceOf(subAccount_);
        uint256 assets = ERC4626(EULER_VAULT_WETH).convertToAssets(shares);
        (uint256 ethPrice, uint256 ethPriceDecimals) = PriceOracleMiddleware(_priceOracle).getAssetPrice(_W_ETH);
        (uint256 usdcPrice, uint256 usdcPriceDecimals) = PriceOracleMiddleware(_priceOracle).getAssetPrice(_USDC);
        uint256 collateralWad = IporMath.convertToWad(assets * ethPrice, 18 + ethPriceDecimals);
        uint256 debtWad = IporMath.convertToWad(debt_ * usdcPrice, 6 + usdcPriceDecimals);
        return int256(collateralWad) - int256(debtWad);
    }

    function _createPriceOracle() private returns (address) {
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(_CHAINLINK_REGISTRY);
        PriceOracleMiddleware priceOracle = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );
        address[] memory assets = new address[](1);
        address[] memory sources = new address[](1);
        assets[0] = _W_ETH;
        sources[0] = _ETH_USD_CHAINLINK;
        priceOracle.setAssetsPricesSources(assets, sources);
        return address(priceOracle);
    }

    function _initAccessManager() private {
        address[] memory initAddress = new address[](3);
        initAddress[0] = address(this);
        initAddress[1] = _ATOMIST;
        initAddress[2] = _ALPHA;

        address[] memory whitelist = new address[](1);
        whitelist[0] = _USER;

        address[] memory dao = new address[](1);
        dao[0] = address(this);

        DataForInitialization memory data = DataForInitialization({
            isPublic: false,
            iporDaos: dao,
            admins: initAddress,
            owners: initAddress,
            atomists: initAddress,
            alphas: initAddress,
            whitelist: whitelist,
            guardians: initAddress,
            fuseManagers: initAddress,
            claimRewards: initAddress,
            transferRewardsManagers: initAddress,
            configInstantWithdrawalFusesManagers: initAddress,
            updateMarketsBalancesAccounts: initAddress,
            updateRewardsBalanceAccounts: initAddress,
            withdrawManagerRequestFeeManagers: initAddress,
            withdrawManagerWithdrawFeeManagers: initAddress,
            priceOracleMiddlewareManagers: initAddress,
            preHooksManagers: initAddress,
            plasmaVaultAddress: PlasmaVaultAddress({
                plasmaVault: _plasmaVault,
                accessManager: _accessManager,
                rewardsClaimManager: address(0x123),
                withdrawManager: _withdrawManager,
                feeManager: FeeAccount(PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeAccount)
                    .FEE_MANAGER(),
                contextManager: address(0x123),
                priceOracleMiddlewareManager: address(0x123)
            })
        });
        InitializationData memory initializationData = IporFusionAccessManagerInitializerLibV1
            .generateInitializeIporPlasmaVault(data);
        vm.prank(_ATOMIST);
        IporFusionAccessManager(_accessManager).initialize(initializationData);
    }

    function _grantEulerSubstrates() private {
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({
                eulerVault: EULER_VAULT_PRIME_USDC,
                isCollateral: false,
                canBorrow: true,
                subAccounts: _SUB_ONE
            })
        );
        substrates[1] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: EULER_VAULT_WETH, isCollateral: true, canBorrow: false, subAccounts: _SUB_ONE})
        );
        vm.prank(_ATOMIST);
        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(IporFusionMarkets.EULER_V2, substrates);
    }
}
