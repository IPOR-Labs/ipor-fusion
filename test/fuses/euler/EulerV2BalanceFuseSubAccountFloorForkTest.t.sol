// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IEVC} from "@ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";

import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {IPriceFeed} from "../../../contracts/price_oracle/price_feed/IPriceFeed.sol";
import {EulerFuseLib, EulerSubstrate} from "../../../contracts/fuses/euler/EulerFuseLib.sol";
import {EulerV2SupplyFuse, EulerV2SupplyFuseEnterData} from "../../../contracts/fuses/euler/EulerV2SupplyFuse.sol";
import {
    EulerV2CollateralFuse,
    EulerV2CollateralFuseEnterData
} from "../../../contracts/fuses/euler/EulerV2CollateralFuse.sol";
import {
    EulerV2ControllerFuse,
    EulerV2ControllerFuseEnterData
} from "../../../contracts/fuses/euler/EulerV2ControllerFuse.sol";
import {EulerV2BorrowFuse, EulerV2BorrowFuseEnterData} from "../../../contracts/fuses/euler/EulerV2BorrowFuse.sol";
import {EulerV2BalanceFuse} from "../../../contracts/fuses/euler/EulerV2BalanceFuse.sol";
import {IBorrowing} from "../../../contracts/fuses/euler/ext/IBorrowing.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {
    PlasmaVault,
    PlasmaVaultInitData,
    MarketBalanceFuseConfig,
    MarketSubstratesConfig,
    FuseAction
} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {FeeAccount} from "../../../contracts/managers/fee/FeeAccount.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {
    IporFusionAccessManagerInitializerLibV1,
    InitializationData,
    DataForInitialization,
    PlasmaVaultAddress
} from "../../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";

import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {PlasmaVaultCloneLib} from "../../test_helpers/PlasmaVaultCloneLib.sol";
import {PlasmaVaultConfigurator} from "../../utils/PlasmaVaultConfigurator.sol";
import {IToken} from "./IToken.sol";

/// @title EulerV2BalanceFuseSubAccountFloorForkTest
/// @notice IL-9528 (3sigma audit finding #1) on an Ethereum mainnet fork with the real Euler Vault Kit.
///         Sub-account A holds plain supply in the eUSDT-1 escrow vault, outside the pair of sub-account B, so the
///         debt socialization that follows the liquidation of B does not move the value of A. Sub-account B holds
///         WETH collateral in eWETH-2 and borrows USDC from eUSDC-2 (Euler Prime, socializes bad debt).
///         B is pushed underwater by one mock of the Chainlink ETH/USD feed, which is read both by the Plasma Vault
///         price oracle middleware (WETH source in this test) and by the ChainlinkOracle adapter of the eUSDC-2
///         EulerRouter, so the vault and Euler see the same price. B is then liquidated by EVK itself.
///         Each sub-account is valued from zero: the market is worth A while B is underwater and stays at A when B
///         is liquidated (netting across sub-accounts gave A - shortfall, then stepped up by the shortfall).
contract EulerV2BalanceFuseSubAccountFloorForkTest is Test {
    /// @dev Own fork block of this suite (forks are not shared with other suites)
    uint256 private constant _FORK_BLOCK = 21_050_000;

    address private constant _EVC = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;

    /// @dev eUSDT-1: escrow vault (no oracle, no borrowing, no interest) holding the plain supply of sub-account A
    address private constant _EULER_VAULT_ESCROW_USDT = 0x2343b4bCB96EC35D8653Fb154461fc673CB20a7e;
    /// @dev eWETH-2: Euler Prime WETH, collateral of sub-account B (liquidation LTV 85% in eUSDC-2)
    address private constant _EULER_VAULT_PRIME_WETH = 0xD8b27CF359b7D15710a5BE299AF6e7Bf904984C2;
    /// @dev eUSDC-2: Euler Prime USDC, controller of sub-account B (configFlags = 0: socializes bad debt)
    address private constant _EULER_VAULT_PRIME_USDC = 0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9;
    /// @dev EulerRouter returned by eUSDC-2 `oracle()`; its WETH/USD adapter reads the Chainlink ETH/USD feed
    address private constant _EULER_PRIME_ROUTER = 0x83B3b76873D36A28440cF53371dF404c42497136;
    /// @dev Unit of account of eUSDC-2 (USD, ISO 4217 code 840)
    address private constant _USD = address(840);

    address private constant _W_ETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant _USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    /// @dev Binance wallet - USDT whale (deal() does not work with USDT)
    address private constant _USDT_WHALE = 0xF977814e90dA44bFA03b6295A0616a897441aceC;

    address private constant _ETH_USD_CHAINLINK = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address private constant _CHAINLINK_REGISTRY = 0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf;

    bytes1 private constant _SUB_ACCOUNT_A = 0x01;
    bytes1 private constant _SUB_ACCOUNT_B = 0x02;

    uint256 private constant _SUPPLY_A_USDT = 5_000e6;
    /// @dev Plain supply of sub-account B in the eUSDT-1 escrow vault (not enabled as collateral), below the
    ///      shortfall of B once B is underwater
    uint256 private constant _FREE_SUPPLY_B_USDT = 300e6;
    uint256 private constant _COLLATERAL_B_WETH = 1e18;
    /// @dev About 77% of the collateral value at the fork block (borrow LTV 83%)
    uint256 private constant _BORROW_B_USDC = 1_900e6;
    /// @dev Euler liquidation cool-off of eUSDC-2 is 1 second
    uint256 private constant _WARP_BEFORE_LIQUIDATION = 10;

    address private constant _ATOMIST = address(1111111);
    address private constant _ALPHA = address(2222222);
    address private constant _USER = address(12121212);

    address private _plasmaVault;
    address private _priceOracle;
    address private _accessManager;

    address private _eulerSupplyFuse;
    address private _eulerCollateralFuse;
    address private _eulerControllerFuse;
    address private _eulerBorrowFuse;

    address private _subAccountA;
    address private _subAccountB;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), _FORK_BLOCK);

        _priceOracle = _createPriceOracle();
        _accessManager = address(new IporFusionAccessManager(_ATOMIST, 0));

        vm.startPrank(_ATOMIST);
        _plasmaVault = address(PlasmaVaultCloneLib.newPlasmaVault());
        PlasmaVault(_plasmaVault).proxyInitialize(
            PlasmaVaultInitData(
                "TEST PLASMA VAULT",
                "USDC",
                _USDC,
                _priceOracle,
                FeeConfigHelper.createZeroFeeConfig(),
                _accessManager,
                address(new PlasmaVaultBase()),
                address(new WithdrawManager(_accessManager)),
                address(0)
            )
        );
        vm.stopPrank();

        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            _ATOMIST,
            _plasmaVault,
            _setupFuses(),
            _setupBalanceFuses(),
            _setupMarketConfigs()
        );

        _initAccessManager();
        _fundPlasmaVault();

        _subAccountA = EulerFuseLib.generateSubAccountAddress(_plasmaVault, _SUB_ACCOUNT_A);
        _subAccountB = EulerFuseLib.generateSubAccountAddress(_plasmaVault, _SUB_ACCOUNT_B);
    }

    //******************************************************************************************************************
    //********************                              TESTS                                       ********************
    //******************************************************************************************************************

    /// @notice An underwater sub-account B contributes 0 to market 11; sub-account A counts in full.
    function testShouldValueUnderwaterSubAccountAtZero() external {
        // given
        uint256 marketValueOfSubAccountA = _openSubAccountA();
        _openSubAccountB();
        _pushSubAccountBUnderwater();

        // when
        _refreshEulerMarket();

        // then
        assertEq(
            _eulerMarketValue(),
            marketValueOfSubAccountA,
            "underwater sub-account B contributes 0, its shortfall is not charged to sub-account A"
        );
    }

    /// @notice Liquidating the underwater sub-account B through EVK does not step the market value up.
    function testShouldKeepNavFlatWhenUnderwaterSubAccountIsLiquidated() external {
        // given
        uint256 marketValueOfSubAccountA = _openSubAccountA();
        _openSubAccountB();
        _pushSubAccountBUnderwater();
        _refreshEulerMarket();
        uint256 marketValueUnderwater = _eulerMarketValue();

        // when
        _liquidateSubAccountB();
        _refreshEulerMarket();

        // then
        assertEq(ERC4626(_EULER_VAULT_PRIME_WETH).balanceOf(_subAccountB), 0, "collateral of B seized");
        assertEq(IBorrowing(_EULER_VAULT_PRIME_USDC).debtOf(_subAccountB), 0, "residual debt of B socialized");
        assertEq(_eulerMarketValue(), marketValueUnderwater, "no NAV step-up when B is liquidated");
        assertEq(_eulerMarketValue(), marketValueOfSubAccountA, "market worth sub-account A");
    }

    /// @notice (S1) Plain supply next to socialized debt in one sub-account: B also holds USDT in the eUSDT-1 escrow
    ///         vault without enabling it as collateral. A liquidation seizes only the WETH, eUSDC-2 socializes the rest
    ///         of the debt and the USDT stays with B, so B is worth its USDT before and after the liquidation. Netting
    ///         the free supply against the debt (e42fcbf3) valued B at 0 while underwater and stepped up by the USDT
    ///         when B was liquidated.
    function testShouldKeepFreeSupplyOfUnderwaterSubAccountThroughLiquidation() external {
        // given
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = _supplyAction(_EULER_VAULT_ESCROW_USDT, _FREE_SUPPLY_B_USDT, _SUB_ACCOUNT_B);
        _execute(calls);
        uint256 marketValueOfFreeSupply = _eulerMarketValue();
        uint256 freeSharesOfB = ERC4626(_EULER_VAULT_ESCROW_USDT).balanceOf(_subAccountB);
        assertGt(marketValueOfFreeSupply, 0, "free supply of B opened");

        _openSubAccountB();
        assertFalse(
            IEVC(_EVC).isCollateralEnabled(_subAccountB, _EULER_VAULT_ESCROW_USDT),
            "the USDT of B is plain supply"
        );
        _pushSubAccountBUnderwater();
        assertLt(
            _sharesUsd(_EULER_VAULT_PRIME_WETH, _W_ETH, _subAccountB) +
                _sharesUsd(_EULER_VAULT_ESCROW_USDT, _USDT, _subAccountB),
            _debtOfSubAccountBUsd(),
            "netting the free supply against the debt would value B at 0"
        );

        // when
        _refreshEulerMarket();
        uint256 marketValueUnderwater = _eulerMarketValue();

        // then: the vault holds no eUSDC-2 shares, so no part of the debt to be socialized is charged to it
        assertEq(ERC4626(_EULER_VAULT_PRIME_USDC).balanceOf(_subAccountA), 0, "no shares of the controller (A)");
        assertEq(ERC4626(_EULER_VAULT_PRIME_USDC).balanceOf(_subAccountB), 0, "no shares of the controller (B)");
        assertEq(marketValueUnderwater, marketValueOfFreeSupply, "underwater B is worth its free supply");

        // when
        _liquidateSubAccountB();
        _refreshEulerMarket();

        // then
        assertEq(ERC4626(_EULER_VAULT_PRIME_WETH).balanceOf(_subAccountB), 0, "collateral of B seized");
        assertEq(IBorrowing(_EULER_VAULT_PRIME_USDC).debtOf(_subAccountB), 0, "residual debt of B socialized");
        assertEq(
            ERC4626(_EULER_VAULT_ESCROW_USDT).balanceOf(_subAccountB),
            freeSharesOfB,
            "the free supply of B survives the liquidation"
        );
        assertEq(_eulerMarketValue(), marketValueUnderwater, "no NAV step-up by the free supply when B is liquidated");
    }

    //******************************************************************************************************************
    //********************                              HELPERS                                     ********************
    //******************************************************************************************************************

    /// @dev Supplies USDT into the escrow vault from sub-account A; returns the market value with A alone
    function _openSubAccountA() private returns (uint256 marketValueOfSubAccountA) {
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = _supplyAction(_EULER_VAULT_ESCROW_USDT, _SUPPLY_A_USDT, _SUB_ACCOUNT_A);
        _execute(calls);

        marketValueOfSubAccountA = _eulerMarketValue();
        assertGt(marketValueOfSubAccountA, 0, "sub-account A opened");
    }

    /// @dev Supplies WETH as collateral and borrows USDC from sub-account B (healthy)
    function _openSubAccountB() private {
        FuseAction[] memory calls = new FuseAction[](4);
        calls[0] = _supplyAction(_EULER_VAULT_PRIME_WETH, _COLLATERAL_B_WETH, _SUB_ACCOUNT_B);
        calls[1] = FuseAction({
            fuse: _eulerCollateralFuse,
            data: abi.encodeWithSignature(
                "enter((address,bytes1))",
                EulerV2CollateralFuseEnterData({eulerVault: _EULER_VAULT_PRIME_WETH, subAccount: _SUB_ACCOUNT_B})
            )
        });
        calls[2] = FuseAction({
            fuse: _eulerControllerFuse,
            data: abi.encodeWithSignature(
                "enter((address,bytes1))",
                EulerV2ControllerFuseEnterData({eulerVault: _EULER_VAULT_PRIME_USDC, subAccount: _SUB_ACCOUNT_B})
            )
        });
        calls[3] = FuseAction({
            fuse: _eulerBorrowFuse,
            data: abi.encodeWithSignature(
                "enter((address,uint256,bytes1))",
                EulerV2BorrowFuseEnterData({
                    eulerVault: _EULER_VAULT_PRIME_USDC,
                    assetAmount: _BORROW_B_USDC,
                    subAccount: _SUB_ACCOUNT_B
                })
            )
        });
        _execute(calls);

        assertEq(IBorrowing(_EULER_VAULT_PRIME_USDC).debtOf(_subAccountB), _BORROW_B_USDC, "sub-account B borrowed");
    }

    /// @dev Halves the Chainlink ETH/USD answer after the liquidation cool-off. The Plasma Vault middleware and the
    ///      eUSDC-2 EulerRouter both read this feed, so B is underwater for the vault and liquidatable for Euler.
    function _pushSubAccountBUnderwater() private {
        vm.warp(vm.getBlockTimestamp() + _WARP_BEFORE_LIQUIDATION);

        uint256 underwaterAnswer = _halveEthUsdAnswer();

        _assertBothPricePathsRead(underwaterAnswer);
        _assertSubAccountBUnderwaterAtVaultPrices();
        _assertSubAccountBLiquidatableOnEuler();
    }

    function _halveEthUsdAnswer() private returns (uint256) {
        (uint80 roundId, int256 answer, uint256 startedAt, , uint80 answeredInRound) = IPriceFeed(_ETH_USD_CHAINLINK)
            .latestRoundData();
        int256 underwaterAnswer = answer / 2;
        vm.mockCall(
            _ETH_USD_CHAINLINK,
            abi.encodeWithSelector(IPriceFeed.latestRoundData.selector),
            abi.encode(roundId, underwaterAnswer, startedAt, vm.getBlockTimestamp(), answeredInRound)
        );
        return uint256(underwaterAnswer);
    }

    /// @dev The vault middleware and the eUSDC-2 EulerRouter both price WETH with the mocked answer
    function _assertBothPricePathsRead(uint256 answer_) private view {
        // the middleware rescales the 8-decimal feed answer to its own price decimals
        (uint256 wethPrice, uint256 wethPriceDecimals) = PriceOracleMiddleware(_priceOracle).getAssetPrice(_W_ETH);
        assertEq(wethPrice * 1e8, answer_ * 10 ** wethPriceDecimals, "middleware reads the mocked ETH/USD answer");

        assertEq(_staticAddress(_EULER_VAULT_PRIME_USDC, "oracle()"), _EULER_PRIME_ROUTER, "eUSDC-2 router");
        (bool ok, bytes memory quote) = _EULER_PRIME_ROUTER.staticcall(
            abi.encodeWithSignature("getQuote(uint256,address,address)", 1e18, _W_ETH, _USD)
        );
        assertTrue(ok, "router quote");
        // 1 WETH -> answer * 1e10 in 18-decimal USD
        assertEq(abi.decode(quote, (uint256)), answer_ * 1e10, "EVK reads the mocked ETH/USD answer");
    }

    /// @dev Collateral value of B below its debt value, both in 18-decimal USD at the middleware prices
    function _assertSubAccountBUnderwaterAtVaultPrices() private view {
        (uint256 wethPrice, uint256 wethPriceDecimals) = PriceOracleMiddleware(_priceOracle).getAssetPrice(_W_ETH);
        uint256 collateralUsd = (ERC4626(_EULER_VAULT_PRIME_WETH).convertToAssets(
            ERC4626(_EULER_VAULT_PRIME_WETH).balanceOf(_subAccountB)
        ) * wethPrice) / 10 ** wethPriceDecimals;

        (uint256 usdcPrice, uint256 usdcPriceDecimals) = PriceOracleMiddleware(_priceOracle).getAssetPrice(_USDC);
        uint256 debtUsd = (IBorrowing(_EULER_VAULT_PRIME_USDC).debtOf(_subAccountB) * 1e12 * usdcPrice) /
            10 ** usdcPriceDecimals;

        assertLt(collateralUsd, debtUsd, "sub-account B underwater at the vault's prices");
    }

    /// @dev Value in 18-decimal USD, at the middleware prices, of the shares of `account_` in `eulerVault_`
    function _sharesUsd(address eulerVault_, address asset_, address account_) private view returns (uint256) {
        (uint256 price, uint256 priceDecimals) = PriceOracleMiddleware(_priceOracle).getAssetPrice(asset_);
        return
            (ERC4626(eulerVault_).convertToAssets(ERC4626(eulerVault_).balanceOf(account_)) *
                10 ** (18 - ERC20(asset_).decimals()) *
                price) / 10 ** priceDecimals;
    }

    /// @dev Debt of sub-account B in 18-decimal USD at the middleware prices
    function _debtOfSubAccountBUsd() private view returns (uint256) {
        (uint256 usdcPrice, uint256 usdcPriceDecimals) = PriceOracleMiddleware(_priceOracle).getAssetPrice(_USDC);
        return (IBorrowing(_EULER_VAULT_PRIME_USDC).debtOf(_subAccountB) * 1e12 * usdcPrice) / 10 ** usdcPriceDecimals;
    }

    /// @dev Euler sees B as liquidatable, with its whole collateral as the liquidation yield
    function _assertSubAccountBLiquidatableOnEuler() private {
        (bool ok, bytes memory result) = _EULER_VAULT_PRIME_USDC.staticcall(
            abi.encodeWithSignature(
                "checkLiquidation(address,address,address)",
                makeAddr("liquidator"),
                _subAccountB,
                _EULER_VAULT_PRIME_WETH
            )
        );
        assertTrue(ok, "checkLiquidation");
        (uint256 maxRepay, uint256 maxYield) = abi.decode(result, (uint256, uint256));
        assertGt(maxRepay, 0, "Euler sees sub-account B as liquidatable");
        assertEq(maxYield, ERC4626(_EULER_VAULT_PRIME_WETH).balanceOf(_subAccountB), "whole collateral seizable");
    }

    /// @dev A liquidator takes over the debt of B and its collateral through EVK `liquidate`, then repays the debt it
    ///      took over, in one EVC batch; EVK socializes the rest of the debt of B
    function _liquidateSubAccountB() private {
        address liquidator = makeAddr("liquidator");
        deal(_USDC, liquidator, 10_000e6);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](3);
        items[0] = IEVC.BatchItem({
            targetContract: _EULER_VAULT_PRIME_USDC,
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeWithSignature(
                "liquidate(address,address,uint256,uint256)",
                _subAccountB,
                _EULER_VAULT_PRIME_WETH,
                type(uint256).max,
                0
            )
        });
        items[1] = IEVC.BatchItem({
            targetContract: _EULER_VAULT_PRIME_USDC,
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeWithSignature("repay(uint256,address)", type(uint256).max, liquidator)
        });
        items[2] = IEVC.BatchItem({
            targetContract: _EULER_VAULT_PRIME_USDC,
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeWithSignature("disableController()")
        });

        vm.startPrank(liquidator);
        ERC20(_USDC).approve(_EULER_VAULT_PRIME_USDC, type(uint256).max);
        IEVC(_EVC).enableController(liquidator, _EULER_VAULT_PRIME_USDC);
        IEVC(_EVC).batch(items);
        vm.stopPrank();

        assertGt(ERC4626(_EULER_VAULT_PRIME_WETH).balanceOf(liquidator), 0, "liquidator received the collateral");
    }

    function _refreshEulerMarket() private {
        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.EULER_V2;
        PlasmaVault(_plasmaVault).updateMarketsBalances(marketIds);
    }

    function _eulerMarketValue() private view returns (uint256) {
        return PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.EULER_V2);
    }

    function _execute(FuseAction[] memory calls_) private {
        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(calls_);
        vm.stopPrank();
    }

    function _supplyAction(
        address eulerVault_,
        uint256 amount_,
        bytes1 subAccount_
    ) private view returns (FuseAction memory) {
        return
            FuseAction({
                fuse: _eulerSupplyFuse,
                data: abi.encodeWithSignature(
                    "enter((address,uint256,bytes1))",
                    EulerV2SupplyFuseEnterData({eulerVault: eulerVault_, maxAmount: amount_, subAccount: subAccount_})
                )
            });
    }

    function _staticAddress(address target_, string memory signature_) private view returns (address) {
        (bool ok, bytes memory data) = target_.staticcall(abi.encodeWithSignature(signature_));
        assertTrue(ok, signature_);
        return abi.decode(data, (address));
    }

    //******************************************************************************************************************
    //********************                              SETUP                                       ********************
    //******************************************************************************************************************

    function _createPriceOracle() private returns (address) {
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(_CHAINLINK_REGISTRY);
        PriceOracleMiddleware priceOracle = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );

        // WETH from the Chainlink ETH/USD feed; USDC and USDT from the Chainlink feed registry
        address[] memory assets = new address[](1);
        address[] memory sources = new address[](1);
        assets[0] = _W_ETH;
        sources[0] = _ETH_USD_CHAINLINK;
        priceOracle.setAssetsPricesSources(assets, sources);

        return address(priceOracle);
    }

    function _setupFuses() private returns (address[] memory fuses) {
        _eulerSupplyFuse = address(new EulerV2SupplyFuse(IporFusionMarkets.EULER_V2, _EVC));
        _eulerCollateralFuse = address(new EulerV2CollateralFuse(IporFusionMarkets.EULER_V2, _EVC));
        _eulerControllerFuse = address(new EulerV2ControllerFuse(IporFusionMarkets.EULER_V2, _EVC));
        _eulerBorrowFuse = address(new EulerV2BorrowFuse(IporFusionMarkets.EULER_V2, _EVC));

        fuses = new address[](4);
        fuses[0] = _eulerSupplyFuse;
        fuses[1] = _eulerCollateralFuse;
        fuses[2] = _eulerControllerFuse;
        fuses[3] = _eulerBorrowFuse;
    }

    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses) {
        balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(
            IporFusionMarkets.EULER_V2,
            address(new EulerV2BalanceFuse(IporFusionMarkets.EULER_V2, _EVC))
        );
    }

    function _setupMarketConfigs() private pure returns (MarketSubstratesConfig[] memory marketConfigs) {
        bytes32[] memory substrates = new bytes32[](4);
        substrates[0] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({
                eulerVault: _EULER_VAULT_ESCROW_USDT,
                isCollateral: false,
                canBorrow: false,
                subAccounts: _SUB_ACCOUNT_A
            })
        );
        substrates[1] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({
                eulerVault: _EULER_VAULT_PRIME_WETH,
                isCollateral: true,
                canBorrow: false,
                subAccounts: _SUB_ACCOUNT_B
            })
        );
        substrates[2] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({
                eulerVault: _EULER_VAULT_PRIME_USDC,
                isCollateral: false,
                canBorrow: true,
                subAccounts: _SUB_ACCOUNT_B
            })
        );
        /// @dev plain supply of sub-account B (S1); empty in the other tests
        substrates[3] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({
                eulerVault: _EULER_VAULT_ESCROW_USDT,
                isCollateral: false,
                canBorrow: false,
                subAccounts: _SUB_ACCOUNT_B
            })
        );

        marketConfigs = new MarketSubstratesConfig[](1);
        marketConfigs[0] = MarketSubstratesConfig(IporFusionMarkets.EULER_V2, substrates);
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
                withdrawManager: address(0x123),
                feeManager: FeeAccount(PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeAccount)
                    .FEE_MANAGER(),
                contextManager: address(0x123),
                priceOracleMiddlewareManager: address(0x123)
            })
        });
        InitializationData memory initializationData = IporFusionAccessManagerInitializerLibV1
            .generateInitializeIporPlasmaVault(data);
        vm.startPrank(_ATOMIST);
        IporFusionAccessManager(_accessManager).initialize(initializationData);
        vm.stopPrank();
    }

    function _fundPlasmaVault() private {
        deal(_USDC, _USER, 10_000e6);
        vm.startPrank(_USER);
        ERC20(_USDC).approve(_plasmaVault, 10_000e6);
        PlasmaVault(_plasmaVault).deposit(10_000e6, _USER);
        vm.stopPrank();

        /// @dev test-only transfers; in production the vault swaps its underlying into these assets
        vm.prank(_USDT_WHALE);
        IToken(_USDT).transfer(_plasmaVault, _SUPPLY_A_USDT);
        deal(_W_ETH, _plasmaVault, _COLLATERAL_B_WETH);
    }
}
