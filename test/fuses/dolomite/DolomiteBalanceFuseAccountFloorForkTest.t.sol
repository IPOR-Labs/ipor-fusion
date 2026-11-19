// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PlasmaVault, PlasmaVaultInitData, FuseAction, FeeConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {IPriceFeed} from "../../../contracts/price_oracle/price_feed/IPriceFeed.sol";
import {IporMath} from "../../../contracts/libraries/math/IporMath.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {PlasmaVaultCloneLib} from "../../test_helpers/PlasmaVaultCloneLib.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";
import {RoleLib, UsersToRoles} from "../../RoleLib.sol";

import {
    DolomiteSupplyFuse,
    DolomiteSupplyFuseEnterData
} from "../../../contracts/fuses/dolomite/DolomiteSupplyFuse.sol";
import {DolomiteBalanceFuse} from "../../../contracts/fuses/dolomite/DolomiteBalanceFuse.sol";
import {DolomiteFuseLib, DolomiteSubstrate} from "../../../contracts/fuses/dolomite/DolomiteFuseLib.sol";
import {IDolomiteMargin} from "../../../contracts/fuses/dolomite/ext/IDolomiteMargin.sol";

/// @notice WETH/USD price feed of the vault price oracle whose answer the test controls
contract DolomiteFloorTestEthUsdFeed is IPriceFeed {
    int256 public price;

    constructor(int256 price_) {
        price = price_;
    }

    function setPrice(int256 price_) external {
        price = price_;
    }

    function decimals() external pure override returns (uint8) {
        return 8;
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (0, price, block.timestamp, block.timestamp, 0);
    }
}

/// @title DolomiteBalanceFuseAccountFloorForkTest
/// @notice IL-9555 on an Arbitrum fork with the real DolomiteMargin. DolomiteMargin keeps every account number as a
///         separate margin account (liquidity, collateralization and liquidation are evaluated per `(owner, number)`),
///         so the balance fuse must floor each account number at zero and add the accounts up.
///         Account number 0 holds plain USDC supply. Account number 1 holds WETH supply and a real USDC borrow opened
///         with `DolomiteMargin.operate`. The WETH price of the vault price oracle is lowered so that, valued with
///         the vault prices, account number 1 is underwater.
contract DolomiteBalanceFuseAccountFloorForkTest is Test {
    /// @dev Own fork block of this suite
    uint256 private constant _FORK_BLOCK = 420_000_001;

    address private constant _DOLOMITE_MARGIN = 0x6Bd780E7fDf01D77e4d475c821f1e7AE05409072;
    address private constant _DEPOSIT_WITHDRAWAL_ROUTER = 0xf8b2c637A68cF6A17b1DF9F8992EeBeFf63d2dFf;
    address private constant _USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant _WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address private constant _CHAINLINK_USDC_USD = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    address private constant _BASE_CURRENCY_PRICE_SOURCE = 0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf;

    uint256 private constant _DOLOMITE_MARKET_ID = 47;

    uint256 private constant _ACCOUNT_FREE = 0;
    uint256 private constant _ACCOUNT_LEVERED = 1;

    uint256 private constant _SUPPLY_FREE_USDC = 300_000e6;
    uint256 private constant _COLLATERAL_WETH = 50e18;
    uint256 private constant _BORROW_USDC = 50_000e6;

    /// @dev Vault price of WETH (8 decimals) at which account number 1 is solvent: 150k of collateral, 50k of debt
    int256 private constant _PRICE_HIGH = 3_000e8;
    /// @dev Vault price of WETH (8 decimals) at which account number 1 is underwater: 25k of collateral, 50k of debt
    int256 private constant _PRICE_LOW = 500e8;
    /// @dev Vault price of WETH (8 decimals) at which the collateral covers about a fifth of the debt
    int256 private constant _PRICE_CRASH = 100e8;

    /// @dev Rounding tolerance of the market balance in underlying (USDC, 6 decimals)
    uint256 private constant _TOLERANCE = 10;

    address private _admin = address(1001);
    address private _alpha = address(1002);

    address private _plasmaVault;
    address private _priceOracle;
    address private _accessManager;
    DolomiteFloorTestEthUsdFeed private _wethFeed;
    DolomiteSupplyFuse private _supplyFuse;
    DolomiteBalanceFuse private _balanceFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), _FORK_BLOCK);

        _supplyFuse = new DolomiteSupplyFuse(_DOLOMITE_MARKET_ID, _DOLOMITE_MARGIN, _DEPOSIT_WITHDRAWAL_ROUTER);
        _balanceFuse = new DolomiteBalanceFuse(_DOLOMITE_MARKET_ID, _DOLOMITE_MARGIN);

        _setupPriceOracle();
        _deployPlasmaVault();

        // account number 0: plain USDC supply
        deal(_USDC, _plasmaVault, _SUPPLY_FREE_USDC);
        _supply(_USDC, _SUPPLY_FREE_USDC, _ACCOUNT_FREE);
    }

    /// @dev Account 1 is underwater in vault prices (-25k), account 0 holds 300k: market value is 300k. Netting the
    ///      accounts gave 275k.
    function testUnderwaterAccountIsNotChargedToHealthyAccount() public {
        _openLeveredAccount();
        _wethFeed.setPrice(_PRICE_LOW);

        uint256 freeValue = _valueOfAccount(_ACCOUNT_FREE);
        uint256 leveredNet = _collateralUsd(_WETH, _ACCOUNT_LEVERED);
        uint256 debtUsd = _debtUsd(_USDC, _ACCOUNT_LEVERED);
        // preconditions: the levered account is underwater when valued with the vault prices
        assertGt(debtUsd, leveredNet, "levered account must be underwater");
        assertGt(freeValue, 299_000e18, "free account value");

        uint256 balance = _marketBalance();

        assertApproxEqAbs(balance, _toUnderlying(freeValue), _TOLERANCE, "balance must equal the healthy account");
        // the previous aggregation returned freeValue - shortfall
        assertGt(balance, _toUnderlying(freeValue - (debtUsd - leveredNet)) + 1e6, "shortfall must not be charged");
    }

    /// @dev Only the underwater account holds a position: the market is worth 0, no revert
    function testOnlyUnderwaterAccountIsWorthZero() public {
        // remove the plain supply of account number 0
        _withdraw(_USDC, type(uint256).max, _ACCOUNT_FREE);
        assertLt(_valueOfAccount(_ACCOUNT_FREE), 1e18, "account 0 must be empty");

        _openLeveredAccount();
        _wethFeed.setPrice(_PRICE_CRASH);

        assertGt(_debtUsd(_USDC, _ACCOUNT_LEVERED), _collateralUsd(_WETH, _ACCOUNT_LEVERED), "must be underwater");

        assertEq(_marketBalance(), 0, "market value must be floored at zero");
    }

    /// @dev A solvent levered account is valued at collateral minus debt, added to the healthy account
    function testSolventAccountIsValuedNet() public {
        _openLeveredAccount();
        _wethFeed.setPrice(_PRICE_HIGH);

        uint256 expected = _valueOfAccount(_ACCOUNT_FREE) +
            _collateralUsd(_WETH, _ACCOUNT_LEVERED) -
            _debtUsd(_USDC, _ACCOUNT_LEVERED);

        assertApproxEqAbs(_marketBalance(), _toUnderlying(expected), _TOLERANCE, "balance must be the sum of the nets");
        assertGt(expected, 399_000e18, "sanity: 300k + (150k - 50k)");
    }

    // ============ Helpers ============

    /// @dev Supplies WETH to account number 1 and borrows USDC against it with the real DolomiteMargin
    function _openLeveredAccount() private {
        _wethFeed.setPrice(_PRICE_HIGH);
        deal(_WETH, _plasmaVault, _COLLATERAL_WETH);
        _supply(_WETH, _COLLATERAL_WETH, _ACCOUNT_LEVERED);

        IDolomiteMargin.AccountInfo[] memory accounts = new IDolomiteMargin.AccountInfo[](1);
        accounts[0] = IDolomiteMargin.AccountInfo({owner: _plasmaVault, number: _ACCOUNT_LEVERED});
        IDolomiteMargin.ActionArgs[] memory actions = new IDolomiteMargin.ActionArgs[](1);
        actions[0] = IDolomiteMargin.ActionArgs({
            actionType: IDolomiteMargin.ActionType.Withdraw,
            accountId: 0,
            amount: IDolomiteMargin.AssetAmount({
                sign: false,
                denomination: IDolomiteMargin.AssetDenomination.Wei,
                ref: IDolomiteMargin.AssetReference.Delta,
                value: _BORROW_USDC
            }),
            primaryMarketId: IDolomiteMargin(_DOLOMITE_MARGIN).getMarketIdByTokenAddress(_USDC),
            secondaryMarketId: 0,
            otherAddress: _plasmaVault,
            otherAccountId: 0,
            data: ""
        });

        vm.prank(_plasmaVault);
        IDolomiteMargin(_DOLOMITE_MARGIN).operate(accounts, actions);

        IDolomiteMargin.Wei memory debt = _accountWei(_USDC, _ACCOUNT_LEVERED);
        assertFalse(debt.sign, "account 1 must carry a USDC debt");
        assertGe(debt.value, _BORROW_USDC, "debt amount");
    }

    function _supply(address asset_, uint256 amount_, uint256 accountNumber_) private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(_supplyFuse),
            data: abi.encodeCall(
                _supplyFuse.enter,
                (
                    DolomiteSupplyFuseEnterData({
                        asset: asset_,
                        amount: amount_,
                        minBalanceIncrease: 0,
                        subAccountId: uint8(accountNumber_),
                        isolationModeMarketId: 0
                    })
                )
            )
        });
        vm.prank(_alpha);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    function _withdraw(address asset_, uint256 amount_, uint256 accountNumber_) private {
        IDolomiteMargin.Wei memory current = _accountWei(asset_, accountNumber_);
        uint256 value = amount_ > current.value ? current.value : amount_;
        IDolomiteMargin.AccountInfo[] memory accounts = new IDolomiteMargin.AccountInfo[](1);
        accounts[0] = IDolomiteMargin.AccountInfo({owner: _plasmaVault, number: accountNumber_});
        IDolomiteMargin.ActionArgs[] memory actions = new IDolomiteMargin.ActionArgs[](1);
        actions[0] = IDolomiteMargin.ActionArgs({
            actionType: IDolomiteMargin.ActionType.Withdraw,
            accountId: 0,
            amount: IDolomiteMargin.AssetAmount({
                sign: false,
                denomination: IDolomiteMargin.AssetDenomination.Wei,
                ref: IDolomiteMargin.AssetReference.Delta,
                value: value
            }),
            primaryMarketId: IDolomiteMargin(_DOLOMITE_MARGIN).getMarketIdByTokenAddress(asset_),
            secondaryMarketId: 0,
            otherAddress: _plasmaVault,
            otherAccountId: 0,
            data: ""
        });
        vm.prank(_plasmaVault);
        IDolomiteMargin(_DOLOMITE_MARGIN).operate(accounts, actions);
    }

    function _accountWei(address asset_, uint256 accountNumber_) private view returns (IDolomiteMargin.Wei memory) {
        return
            IDolomiteMargin(_DOLOMITE_MARGIN).getAccountWei(
                IDolomiteMargin.AccountInfo({owner: _plasmaVault, number: accountNumber_}),
                IDolomiteMargin(_DOLOMITE_MARGIN).getMarketIdByTokenAddress(asset_)
            );
    }

    /// @dev The balance fuse runs by delegatecall in the vault context: refresh market 47 and read the cached value
    ///      (underlying units, 6 decimals)
    function _marketBalance() private returns (uint256) {
        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = _DOLOMITE_MARKET_ID;
        vm.prank(_alpha);
        PlasmaVault(_plasmaVault).updateMarketsBalances(marketIds);
        return PlasmaVault(_plasmaVault).totalAssetsInMarket(_DOLOMITE_MARKET_ID);
    }

    /// @dev Converts a USD WAD value into underlying units the way the vault does
    function _toUnderlying(uint256 usdWad_) private view returns (uint256) {
        (uint256 price, uint256 decimals) = PriceOracleMiddleware(_priceOracle).getAssetPrice(_USDC);
        return IporMath.division(usdWad_ * 10 ** decimals, price) / 1e12;
    }

    function _usd(address asset_, uint256 amount_) private view returns (uint256) {
        (uint256 price, uint256 decimals) = PriceOracleMiddleware(_priceOracle).getAssetPrice(asset_);
        return IporMath.convertToWad(amount_ * price, ERC20(asset_).decimals() + decimals);
    }

    function _collateralUsd(address asset_, uint256 accountNumber_) private view returns (uint256) {
        IDolomiteMargin.Wei memory w = _accountWei(asset_, accountNumber_);
        return w.sign ? _usd(asset_, w.value) : 0;
    }

    function _debtUsd(address asset_, uint256 accountNumber_) private view returns (uint256) {
        IDolomiteMargin.Wei memory w = _accountWei(asset_, accountNumber_);
        return w.sign ? 0 : _usd(asset_, w.value);
    }

    /// @dev Vault-price value of USDC of one account number (supply minus debt, USDC only)
    function _valueOfAccount(uint256 accountNumber_) private view returns (uint256) {
        return _collateralUsd(_USDC, accountNumber_);
    }

    function _setupPriceOracle() private {
        vm.startPrank(_admin);
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(_BASE_CURRENCY_PRICE_SOURCE);
        _priceOracle = address(
            new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", _admin))
        );
        _wethFeed = new DolomiteFloorTestEthUsdFeed(_PRICE_HIGH);

        address[] memory assets = new address[](2);
        address[] memory sources = new address[](2);
        assets[0] = _USDC;
        sources[0] = _CHAINLINK_USDC_USD;
        assets[1] = _WETH;
        sources[1] = address(_wethFeed);
        PriceOracleMiddleware(_priceOracle).setAssetsPricesSources(assets, sources);
        vm.stopPrank();
    }

    function _toSelectors(bytes4 selector_) private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = selector_;
    }

    function _deployPlasmaVault() private {
        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = _admin;
        usersToRoles.atomist = _admin;
        address[] memory alphas = new address[](1);
        alphas[0] = _alpha;
        usersToRoles.alphas = alphas;
        _accessManager = address(RoleLib.createAccessManager(usersToRoles, 0, vm));

        vm.startPrank(_admin);
        address withdrawManager = address(new WithdrawManager(_accessManager));
        _plasmaVault = address(PlasmaVaultCloneLib.newPlasmaVault());
        PlasmaVault(_plasmaVault).proxyInitialize(
            PlasmaVaultInitData({
                assetName: "Dolomite Account Floor Test Vault",
                assetSymbol: "DAFVault",
                underlyingToken: _USDC,
                priceOracleMiddleware: _priceOracle,
                feeConfig: FeeConfigHelper.createZeroFeeConfig(),
                accessManager: _accessManager,
                plasmaVaultBase: address(new PlasmaVaultBase()),
                withdrawManager: withdrawManager,
                plasmaVaultVotesPlugin: address(0)
            })
        );
        vm.stopPrank();

        RoleLib.setupPlasmaVaultRoles(
            usersToRoles,
            vm,
            _plasmaVault,
            IporFusionAccessManager(_accessManager),
            withdrawManager
        );

        vm.startPrank(_admin);
        address[] memory fuses = new address[](1);
        fuses[0] = address(_supplyFuse);
        PlasmaVaultGovernance(_plasmaVault).addFuses(fuses);
        PlasmaVaultGovernance(_plasmaVault).addBalanceFuse(_DOLOMITE_MARKET_ID, address(_balanceFuse));

        bytes32[] memory substrates = new bytes32[](3);
        substrates[0] = DolomiteFuseLib.substrateToBytes32(
            DolomiteSubstrate({asset: _USDC, subAccountId: uint8(_ACCOUNT_FREE), canBorrow: false})
        );
        substrates[1] = DolomiteFuseLib.substrateToBytes32(
            DolomiteSubstrate({asset: _USDC, subAccountId: uint8(_ACCOUNT_LEVERED), canBorrow: true})
        );
        substrates[2] = DolomiteFuseLib.substrateToBytes32(
            DolomiteSubstrate({asset: _WETH, subAccountId: uint8(_ACCOUNT_LEVERED), canBorrow: false})
        );
        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(_DOLOMITE_MARKET_ID, substrates);
        IporFusionAccessManager(_accessManager).grantRole(Roles.UPDATE_MARKETS_BALANCES_ROLE, _alpha, 0);
        IporFusionAccessManager(_accessManager).setTargetFunctionRole(
            _plasmaVault,
            _toSelectors(PlasmaVault.updateMarketsBalances.selector),
            Roles.UPDATE_MARKETS_BALANCES_ROLE
        );
        vm.stopPrank();
    }
}
