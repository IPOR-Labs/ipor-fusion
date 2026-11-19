// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMorpho, MarketParams, Id} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morpho-org/morpho-blue/src/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "@morpho-org/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";

import {MorphoBalanceFuse} from "../../../contracts/fuses/morpho/MorphoBalanceFuse.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {IporMath} from "../../../contracts/libraries/math/IporMath.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../../../contracts/libraries/PlasmaVaultLib.sol";
import {IPriceOracleMiddleware} from "../../../contracts/price_oracle/IPriceOracleMiddleware.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {WstETHPriceFeedEthereum} from "../../../contracts/price_oracle/price_feed/chains/ethereum/WstETHPriceFeedEthereum.sol";

/// @dev Morpho oracle with a settable price (collateral priced in loan token, scaled by 1e36)
contract MorphoBalanceFuseMarketFloorMockOracle {
    uint256 public price;

    constructor(uint256 price_) {
        price = price_;
    }

    function setPrice(uint256 price_) external {
        price = price_;
    }
}

/// @dev Stand-in for a Plasma Vault: holds the Morpho positions, the market substrates and the oracle address in its own
///      storage, and runs the balance fuse by delegatecall, exactly as the vault does. The USD value returned by the
///      fuse is read directly (the vault would convert it to its underlying asset), so the test compares exact values.
contract MorphoBalanceFuseMarketFloorHarness {
    function configure(uint256 marketId_, bytes32[] memory substrates_, address priceOracleMiddleware_) external {
        PlasmaVaultConfigLib.grantMarketSubstrates(marketId_, substrates_);
        PlasmaVaultLib.setPriceOracleMiddleware(priceOracleMiddleware_);
    }

    function approve(address token_, address spender_) external {
        ERC20(token_).approve(spender_, type(uint256).max);
    }

    function balanceOf(address fuse_) external returns (uint256) {
        (bool success, bytes memory result) = fuse_.delegatecall(abi.encodeWithSignature("balanceOf()"));
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
        return abi.decode(result, (uint256));
    }
}

/// @title MorphoBalanceFuseMarketFloorForkTest
/// @notice IL-9528 (b) (3sigma audit finding #1, Pete D-014): MorphoBalanceFuse values every Morpho Blue market on its
///         own and floors it at zero, so an underwater market no longer drags the other markets down or reverts the
///         whole market refresh. Runs on an Ethereum mainnet fork against the real Morpho Blue. Two fresh markets
///         (wstETH collateral, WETH loan, mock Morpho oracles) are created so the test controls liquidation.
contract MorphoBalanceFuseMarketFloorForkTest is Test {
    using MorphoBalancesLib for IMorpho;

    /// @dev Own fork block of this suite (forks are not shared with other suites)
    uint256 private constant _FORK_BLOCK = 21_100_000;

    address private constant _W_ETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant _WST_ETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address private constant _MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address private constant _ETH_USD_CHAINLINK = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address private constant _CHAINLINK_REGISTRY = 0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf;

    /// @dev LLTVs enabled on Morpho Blue mainnet; the IRM is address(0) (no interest, exact accounting)
    uint256 private constant _LLTV_A = 0.86e18;
    uint256 private constant _LLTV_B = 0.77e18;
    /// @dev 1 wstETH = 1.15 WETH in the Morpho oracle of the markets
    uint256 private constant _ORACLE_PRICE = 1.15e36;

    address private _vault;
    address private _fuse;
    address private _priceOracle;

    MorphoBalanceFuseMarketFloorMockOracle private _oracleA;
    MorphoBalanceFuseMarketFloorMockOracle private _oracleB;
    MarketParams private _marketA;
    MarketParams private _marketB;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), _FORK_BLOCK);

        (bytes32 idA, bytes32 idB) = _createMarkets();
        _priceOracle = _createPriceOracle();

        MorphoBalanceFuseMarketFloorHarness vault = new MorphoBalanceFuseMarketFloorHarness();
        _vault = address(vault);
        _fuse = address(new MorphoBalanceFuse(IporFusionMarkets.MORPHO, _MORPHO));

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = idA;
        substrates[1] = idB;
        vault.configure(IporFusionMarkets.MORPHO, substrates, _priceOracle);
        vault.approve(_W_ETH, _MORPHO);
        vault.approve(_WST_ETH, _MORPHO);

        // Liquidity of other suppliers in both markets
        deal(_W_ETH, address(this), 2_000e18);
        ERC20(_W_ETH).approve(_MORPHO, type(uint256).max);
        IMorpho(_MORPHO).supply(_marketA, 500e18, 0, address(this), "");
        IMorpho(_MORPHO).supply(_marketB, 500e18, 0, address(this), "");

        // Funds of the vault for its positions on Morpho Blue; the balance fuse only reads the resulting positions
        deal(_W_ETH, _vault, 1_000e18);
        deal(_WST_ETH, _vault, 1_000e18);
    }

    // -------------------------------
    // Tests
    // -------------------------------

    /// @dev (a) Market A is underwater and market B holds plain supply: the market is worth B (the shortfall of A is
    ///      not charged to B). On 870f0a3b the result was B - shortfall(A) (a positive total, so no revert, only an understated NAV).
    function testShouldValueMarketAsSupplyOfBWhenMarketAIsUnderwater() external {
        // given
        _vaultSupply(_marketB, 100e18);
        _vaultSupplyCollateral(_marketA, 100e18);
        _vaultBorrow(_marketA, 50e18);

        (uint256 wstEthPrice, ) = _price(_WST_ETH);
        _mockPrice(_WST_ETH, wstEthPrice / 4);

        // value of the collateral of A is below the debt of A
        assertLt(_toUsd(_WST_ETH, 100e18), _toUsd(_W_ETH, 50e18), "A is underwater for the vault");

        // when
        uint256 marketValue = _refreshMorphoMarket();

        // then
        assertEq(marketValue, _toUsd(_W_ETH, 100e18), "market is worth B only");
    }

    /// @dev (b) The only market is underwater: the refresh returns zero. On 870f0a3b it reverted with
    ///      SafeCastOverflowedIntToUint, which blocked every call refreshing the market.
    function testShouldReturnZeroWhenOnlyMarketIsUnderwater() external {
        // given
        _vaultSupplyCollateral(_marketA, 100e18);
        _vaultBorrow(_marketA, 50e18);

        (uint256 wstEthPrice, ) = _price(_WST_ETH);
        _mockPrice(_WST_ETH, wstEthPrice / 4);

        // when
        uint256 marketValue = _refreshMorphoMarket();

        // then
        assertEq(marketValue, 0, "underwater market contributes zero");
    }

    /// @dev (c) Healthy configuration: exactly the value of the unfloored sum (collateral + supply - borrow)
    function testShouldKeepValueOfHealthyConfiguration() external {
        // given
        _vaultSupply(_marketB, 10e18);
        _vaultSupplyCollateral(_marketA, 100e18);
        _vaultBorrow(_marketA, 50e18);

        uint256 expected = _toUsd(_WST_ETH, 100e18) + _toUsd(_W_ETH, 10e18) - _toUsd(_W_ETH, 50e18);

        // when
        uint256 marketValue = _refreshMorphoMarket();

        // then
        assertEq(marketValue, expected, "healthy value is unchanged");
        assertGt(marketValue, 0, "healthy value is positive");
    }

    /// @dev (d) Rounding parity: with a fractional price the loan token difference is converted once (as before the
    ///      floor), not as two separate conversions. The amounts are chosen so that the two ways differ by 1 wei.
    function testShouldConvertSupplyMinusBorrowOnceAtFractionalPrice() external {
        // given
        _mockPrice(_W_ETH, 123_456_789, 8);

        uint256 supplyAmount = 3e18 + 1;
        uint256 borrowAmount = 1e18 + 2;

        _vaultSupply(_marketA, supplyAmount);
        _vaultSupplyCollateral(_marketA, 10e18);
        _vaultBorrow(_marketA, borrowAmount);

        uint256 netConversion = _toUsd(_W_ETH, supplyAmount - borrowAmount);
        uint256 splitConversion = _toUsd(_W_ETH, supplyAmount) - _toUsd(_W_ETH, borrowAmount);
        assertTrue(netConversion != splitConversion, "amounts must distinguish one conversion from two");

        // when
        uint256 marketValue = _refreshMorphoMarket();

        // then
        assertEq(marketValue, _toUsd(_WST_ETH, 10e18) + netConversion, "one conversion of supply - borrow");
    }

    /// @dev (e) Plain supply and a borrow in the same market: a liquidation seizes only the collateral, so while the
    ///      market is underwater the supply counts in full minus the vault's part of the debt Morpho will write off
    ///      against the lenders, bounded by the whole debt: supply - supply * borrow / market supply, rounded against
    ///      the vault. After the liquidation (bad debt written off, supply of the lenders reduced pro rata) the value
    ///      never falls and steps up only by the vault's part of the debt the liquidator repaid. Netting the supply
    ///      against the debt (b14f20c8) valued the market at zero here and stepped up by the surviving supply.
    function testShouldFloorMixedMarketAndRebound() external {
        // given
        _vaultSupply(_marketA, 2e18);
        _vaultSupplyCollateral(_marketA, 100e18);
        _vaultBorrow(_marketA, 50e18);

        (uint256 wstEthPrice, ) = _price(_WST_ETH);
        _mockPrice(_WST_ETH, wstEthPrice / 4);

        // the vault supplies 2 of the 502 WETH of market A (no IRM: no interest) and owes 50 WETH
        uint256 vaultSupplyAssets = IMorpho(_MORPHO).expectedSupplyAssets(_marketA, _vault);
        uint256 vaultBorrowAssets = IMorpho(_MORPHO).expectedBorrowAssets(_marketA, _vault);
        (uint256 marketSupplyAssets, , , ) = IMorpho(_MORPHO).expectedMarketBalances(_marketA);
        assertEq(marketSupplyAssets, 502e18, "market A supply: 500 WETH of others + 2 WETH of the vault");
        assertEq(vaultBorrowAssets, 50e18, "debt of the vault in market A");
        assertLt(
            _toUsd(_WST_ETH, 100e18),
            _toUsd(_W_ETH, 50e18),
            "market A is underwater for the vault (collateral below debt)"
        );
        assertLt(
            _toUsd(_WST_ETH, 100e18) + _toUsd(_W_ETH, vaultSupplyAssets),
            _toUsd(_W_ETH, 50e18),
            "netting the supply against the debt would value market A at zero"
        );

        uint256 supplyUsd = _toUsd(_W_ETH, vaultSupplyAssets);
        uint256 expectedUnderwaterValue = supplyUsd -
            Math.mulDiv(supplyUsd, vaultBorrowAssets, marketSupplyAssets, Math.Rounding.Ceil);

        // when: underwater (870f0a3b: negative component, reverts for a single market; b14f20c8: zero)
        uint256 underwaterValue = _refreshMorphoMarket();

        // then
        assertEq(
            underwaterValue,
            expectedUnderwaterValue,
            "underwater mixed market: supply minus the vault's part of the debt"
        );
        assertGt(underwaterValue, 0, "the supply is not seized");
        assertLt(underwaterValue, supplyUsd, "the supply bears its part of the bad debt up front");

        // when: Morpho liquidates the position; the collateral is worth 10 WETH, the debt is 50 WETH
        _oracleA.setPrice(0.1e36);
        deal(_W_ETH, address(this), 100e18);
        (uint256 seizedAssets, uint256 repaidAssets) = IMorpho(_MORPHO).liquidate(_marketA, _vault, 100e18, 0, "");
        uint256 afterLiquidation = _refreshMorphoMarket();

        // then: all collateral seized, the remaining debt written off and spread over the lenders
        assertEq(seizedAssets, 100e18, "all collateral seized");
        assertGt(repaidAssets, 0, "debt repaid by the liquidator");
        assertEq(IMorpho(_MORPHO).expectedBorrowAssets(_marketA, _vault), 0, "bad debt written off");
        assertGt(afterLiquidation, 0, "surviving supply is worth something after the liquidation");
        assertLt(afterLiquidation, _toUsd(_W_ETH, 2e18), "supply of the vault is reduced by the bad debt");
        assertGe(afterLiquidation, underwaterValue, "the liquidation does not lower the value");
        // the step is the vault's part of the repaid debt; tolerance: Morpho share rounding of the vault's supply
        // (at most 3 wei of WETH)
        assertApproxEqAbs(
            afterLiquidation - underwaterValue,
            Math.mulDiv(supplyUsd, repaidAssets, marketSupplyAssets),
            _toUsd(_W_ETH, 3),
            "the liquidation steps the value up by the vault's part of the repaid debt"
        );
    }

    // -------------------------------
    // Helpers
    // -------------------------------

    function _refreshMorphoMarket() private returns (uint256) {
        return MorphoBalanceFuseMarketFloorHarness(_vault).balanceOf(_fuse);
    }

    function _vaultSupply(MarketParams memory market_, uint256 amount_) private {
        vm.prank(_vault);
        IMorpho(_MORPHO).supply(market_, amount_, 0, _vault, "");
    }

    function _vaultSupplyCollateral(MarketParams memory market_, uint256 amount_) private {
        vm.prank(_vault);
        IMorpho(_MORPHO).supplyCollateral(market_, amount_, _vault, "");
    }

    function _vaultBorrow(MarketParams memory market_, uint256 amount_) private {
        vm.prank(_vault);
        IMorpho(_MORPHO).borrow(market_, amount_, 0, _vault, _vault);
    }

    function _price(address asset_) private view returns (uint256 price, uint256 decimals) {
        return IPriceOracleMiddleware(_priceOracle).getAssetPrice(asset_);
    }

    /// @dev Mocks the middleware price of an asset as read by the balance fuse, keeping the decimals of its feed
    function _mockPrice(address asset_, uint256 price_) private {
        (, uint256 decimals) = _price(asset_);
        _mockPrice(asset_, price_, decimals);
    }

    function _mockPrice(address asset_, uint256 price_, uint256 decimals_) private {
        vm.mockCall(
            _priceOracle,
            abi.encodeWithSelector(IPriceOracleMiddleware.getAssetPrice.selector, asset_),
            abi.encode(price_, decimals_)
        );
    }

    /// @dev Same conversion as MorphoBalanceFuse: amount * price in WAD, decimals of the asset + decimals of the price
    function _toUsd(address asset_, uint256 amount_) private view returns (uint256) {
        (uint256 price, uint256 priceDecimals) = _price(asset_);
        return IporMath.convertToWad(amount_ * price, ERC20(asset_).decimals() + priceDecimals);
    }

    function _createMarkets() private returns (bytes32 idA, bytes32 idB) {
        _oracleA = new MorphoBalanceFuseMarketFloorMockOracle(_ORACLE_PRICE);
        _oracleB = new MorphoBalanceFuseMarketFloorMockOracle(_ORACLE_PRICE);

        _marketA = MarketParams(_W_ETH, _WST_ETH, address(_oracleA), address(0), _LLTV_A);
        _marketB = MarketParams(_W_ETH, _WST_ETH, address(_oracleB), address(0), _LLTV_B);

        IMorpho(_MORPHO).createMarket(_marketA);
        IMorpho(_MORPHO).createMarket(_marketB);

        idA = Id.unwrap(MarketParamsLib.id(_marketA));
        idB = Id.unwrap(MarketParamsLib.id(_marketB));
    }

    function _createPriceOracle() private returns (address) {
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(_CHAINLINK_REGISTRY);
        PriceOracleMiddleware priceOracle = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );

        address[] memory assets = new address[](2);
        address[] memory sources = new address[](2);
        assets[0] = _WST_ETH;
        sources[0] = address(new WstETHPriceFeedEthereum());
        assets[1] = _W_ETH;
        sources[1] = _ETH_USD_CHAINLINK;

        priceOracle.setAssetsPricesSources(assets, sources);
        return address(priceOracle);
    }
}
