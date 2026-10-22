// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TestAddresses} from "../../test_helpers/TestAddresses.sol";
import {FusionFactoryDaoFeePackagesHelper} from "../../test_helpers/FusionFactoryDaoFeePackagesHelper.sol";
import {FusionFactoryLogicLib} from "../../../contracts/factory/lib/FusionFactoryLogicLib.sol";
import {FusionFactory} from "../../../contracts/factory/FusionFactory.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {PriceOracleMiddlewareManager} from "../../../contracts/managers/price/PriceOracleMiddlewareManager.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVault, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {InstantWithdrawalFusesParamsStruct} from "../../../contracts/libraries/PlasmaVaultLib.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {FixedValuePriceFeed} from "../../../contracts/price_oracle/price_feed/FixedValuePriceFeed.sol";

import {FxMintCollateralFuse, FxMintCollateralFuseEnterData, FxMintCollateralFuseExitData} from "../../../contracts/fuses/fxmint/FxMintCollateralFuse.sol";
import {FxMintBorrowFuse, FxMintBorrowFuseEnterData, FxMintBorrowFuseExitData} from "../../../contracts/fuses/fxmint/FxMintBorrowFuse.sol";
import {FxMintCollateralAndBorrowFuse, FxMintCollateralAndBorrowFuseEnterData, FxMintCollateralAndBorrowFuseExitData} from "../../../contracts/fuses/fxmint/FxMintCollateralAndBorrowFuse.sol";
import {FxMintBalanceFuse} from "../../../contracts/fuses/fxmint/FxMintBalanceFuse.sol";
import {IFxPool, IFxPoolLimits, IFxPriceOracle} from "../../../contracts/fuses/fxmint/ext/IFxPool.sol";
import {IFxPoolManager} from "../../../contracts/fuses/fxmint/ext/IFxPoolManager.sol";

/// @dev Test-only Chainlink-style feed returning an f(x) pool's anchor price (USD, 18 decimals)
contract FxAnchorPriceFeedMock {
    address public immutable ORACLE;

    constructor(address oracle_) {
        ORACLE = oracle_;
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        (uint256 anchor, , ) = IFxPriceOracle(ORACLE).getPrice();
        return (0, int256(anchor), block.timestamp, block.timestamp, 0);
    }
}

/// @notice FxMint fuses on an Ethereum mainnet fork against the f(x) Protocol v2 WBTC (8-dec collateral) and wstETH
///         (18-dec collateral) long pools, installed on a fresh PlasmaVault cloned from the mainnet FusionFactory.
///         Run with --isolate (f(x) allows one operate per transaction).
contract FxMintFusesEthereumForkTest is Test {
    address private constant ETHEREUM_FUSION_FACTORY = 0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852;
    address private constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address private constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address private constant FXUSD = 0x085780639CC2cACd35E474e71f4d000e2405d8f6;
    address private constant WBTC_POOL = 0xAB709e26Fa6B0A30c119D8c55B887DeD24952473;
    address private constant WSTETH_POOL = 0x6Ecfa38FeE8a5277B91eFdA204c235814F0122E8;
    uint256 private constant M = IporFusionMarkets.FX_MINT;

    address private constant USER = TestAddresses.USER;
    address private constant ATOMIST = TestAddresses.ATOMIST;
    address private constant FUSE_MANAGER = TestAddresses.FUSE_MANAGER;
    address private constant ALPHA = TestAddresses.ALPHA;

    FusionFactoryLogicLib.FusionInstance private _fi;
    PlasmaVault private _vault;
    FxMintCollateralFuse private _collateralFuse;
    FxMintBorrowFuse private _borrowFuse;
    FxMintCollateralAndBorrowFuse private _bothFuse;
    FxMintBalanceFuse private _balanceFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), vm.envOr("ETHEREUM_FORK_BLOCK", uint256(26143668)));
        FusionFactory factory = FusionFactory(ETHEREUM_FUSION_FACTORY);
        FusionFactoryDaoFeePackagesHelper.setupDefaultDaoFeePackages(vm, factory);
        _fi = factory.clone("FxMintFusesTest", "FXMT", WBTC, 0, ATOMIST, 0);
        _vault = PlasmaVault(_fi.plasmaVault);

        vm.startPrank(ATOMIST);
        IporFusionAccessManager am = IporFusionAccessManager(_fi.accessManager);
        am.grantRole(Roles.ATOMIST_ROLE, ATOMIST, 0);
        am.grantRole(Roles.FUSE_MANAGER_ROLE, FUSE_MANAGER, 0);
        am.grantRole(Roles.ALPHA_ROLE, ALPHA, 0);
        am.grantRole(Roles.PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE, ATOMIST, 0);
        am.grantRole(Roles.CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE, ATOMIST, 0);
        PlasmaVaultGovernance(_fi.plasmaVault).convertToPublicVault();
        PlasmaVaultGovernance(_fi.plasmaVault).enableTransferShares();
        // prices: collateral = the f(x) anchor price; fxUSD = $1 (the vault may use a market feed instead)
        address[] memory assets = new address[](3);
        address[] memory sources = new address[](3);
        (assets[0], sources[0]) = (WBTC, address(new FxAnchorPriceFeedMock(IFxPoolLimits(WBTC_POOL).priceOracle())));
        (assets[1], sources[1]) = (WSTETH, address(new FxAnchorPriceFeedMock(IFxPoolLimits(WSTETH_POOL).priceOracle())));
        (assets[2], sources[2]) = (FXUSD, address(new FixedValuePriceFeed(1e18)));
        PriceOracleMiddlewareManager(_fi.priceManager).setAssetsPriceSources(assets, sources);
        vm.stopPrank();

        _collateralFuse = new FxMintCollateralFuse(M);
        _borrowFuse = new FxMintBorrowFuse(M);
        _bothFuse = new FxMintCollateralAndBorrowFuse(M);
        _balanceFuse = new FxMintBalanceFuse(M);

        vm.startPrank(FUSE_MANAGER);
        address[] memory fuses = new address[](3);
        (fuses[0], fuses[1], fuses[2]) = (address(_collateralFuse), address(_borrowFuse), address(_bothFuse));
        PlasmaVaultGovernance(_fi.plasmaVault).addFuses(fuses);
        PlasmaVaultGovernance(_fi.plasmaVault).addBalanceFuse(M, address(_balanceFuse));
        PlasmaVaultGovernance(_fi.plasmaVault).addBalanceFuse(
            IporFusionMarkets.ERC20_VAULT_BALANCE,
            address(new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE))
        );
        bytes32[] memory pools = new bytes32[](2);
        pools[0] = bytes32(uint256(uint160(WBTC_POOL)));
        pools[1] = bytes32(uint256(uint160(WSTETH_POOL)));
        PlasmaVaultGovernance(_fi.plasmaVault).grantMarketSubstrates(M, pools);
        uint256[] memory ids = new uint256[](1);
        ids[0] = M;
        uint256[][] memory deps = new uint256[][](1);
        deps[0] = new uint256[](1);
        deps[0][0] = IporFusionMarkets.ERC20_VAULT_BALANCE;
        PlasmaVaultGovernance(_fi.plasmaVault).updateDependencyBalanceGraphs(ids, deps);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- helpers

    function _exec(address fuse_, bytes memory data_) private {
        FuseAction[] memory c = new FuseAction[](1);
        c[0] = FuseAction(fuse_, data_);
        vm.prank(ALPHA);
        _vault.execute(c);
    }

    function _positionId(address pool_) private view returns (uint256) {
        bytes32 slot = keccak256(
            abi.encode(pool_, uint256(0xdab5b7d53c456d684bd7aab42036d7f8a41a58fdd80195990e6fa923e0f6d200))
        );
        return uint256(vm.load(address(_vault), slot));
    }

    function _position(address pool_) private view returns (uint256 id, uint256 rawColls, uint256 rawDebts) {
        id = _positionId(pool_);
        if (id != 0) (rawColls, rawDebts) = IFxPool(pool_).getPosition(id);
    }

    /// @dev collateral - debt in USD (WAD) for a position, using the vault's prices; f(x) withdraw fee applied
    function _expectedUsd(address pool_, address token_, uint256 tokenDecimals_) private view returns (int256) {
        (, uint256 rawColls, uint256 rawDebts) = _position(pool_);
        uint256 amount = (rawColls * 1e18) / IFxPoolManager(IFxPool(pool_).poolManager()).getTokenScalingFactor(token_);
        (uint256 p, uint256 pd) = PriceOracleMiddlewareManager(_fi.priceManager).getAssetPrice(token_);
        uint256 collUsd = (amount * p * 1e18) / 10 ** (tokenDecimals_ + pd);
        return int256(collUsd) - int256(rawDebts);
    }

    function _borrowFor(address pool_, address token_, uint256 tokenDecimals_, uint256 amount_, uint256 ltvBps_)
        private
        view
        returns (uint256)
    {
        (uint256 p, uint256 pd) = PriceOracleMiddlewareManager(_fi.priceManager).getAssetPrice(token_);
        pool_;
        return (amount_ * p * ltvBps_) / 10_000 / 10 ** (tokenDecimals_ + pd - 18);
    }

    // ---------------------------------------------------------------- tests

    function test_wbtc8Decimals_openValueClose() public {
        deal(WBTC, address(_vault), 1e8); // 1 WBTC
        uint256 debt = _borrowFor(WBTC_POOL, WBTC, 8, 1e8, 4_000);
        _exec(address(_bothFuse), abi.encodeCall(_bothFuse.enter, (FxMintCollateralAndBorrowFuseEnterData(WBTC_POOL, 1e8, debt))));

        (uint256 id, uint256 rawColls, uint256 rawDebts) = _position(WBTC_POOL);
        assertGt(id, 0, "position stored");
        assertGt(rawColls, 0);
        assertApproxEqAbs(rawDebts, debt, 1, "debt");

        // balance fuse (USD) -> vault market balance in WBTC units
        int256 usd = _expectedUsd(WBTC_POOL, WBTC, 8);
        (uint256 p, uint256 pd) = PriceOracleMiddlewareManager(_fi.priceManager).getAssetPrice(WBTC);
        uint256 expectedUnits = (uint256(usd) * 10 ** (8 + pd)) / p / 1e18;
        assertApproxEqAbs(_vault.totalAssetsInMarket(M), expectedUnits, 2, "market value == collateral - debt (8 dec)");

        deal(FXUSD, address(_vault), IERC20(FXUSD).balanceOf(address(_vault)) + 1_000e18); // repay fee headroom
        _exec(
            address(_bothFuse),
            abi.encodeCall(_bothFuse.exit, (FxMintCollateralAndBorrowFuseExitData(WBTC_POOL, type(uint256).max, type(uint256).max)))
        );
        (id, , ) = _position(WBTC_POOL);
        assertEq(id, 0, "storage cleared");
        assertEq(_vault.totalAssetsInMarket(M), 0, "market empty");
        assertApproxEqRel(IERC20(WBTC).balanceOf(address(_vault)), 1e8, 0.001e18, "collateral back (minus fees)");
    }

    function test_wsteth18Decimals_twoPoolsValuedTogether() public {
        deal(WBTC, address(_vault), 1e8);
        deal(WSTETH, address(_vault), 10e18);
        _exec(
            address(_bothFuse),
            abi.encodeCall(_bothFuse.enter, (FxMintCollateralAndBorrowFuseEnterData(WBTC_POOL, 1e8, _borrowFor(WBTC_POOL, WBTC, 8, 1e8, 3_000))))
        );
        _exec(
            address(_bothFuse),
            abi.encodeCall(_bothFuse.enter, (FxMintCollateralAndBorrowFuseEnterData(WSTETH_POOL, 10e18, _borrowFor(WSTETH_POOL, WSTETH, 18, 10e18, 3_000))))
        );
        (uint256 idW, , ) = _position(WBTC_POOL);
        (uint256 idS, , ) = _position(WSTETH_POOL);
        assertGt(idW, 0);
        assertGt(idS, 0);

        int256 usd = _expectedUsd(WBTC_POOL, WBTC, 8) + _expectedUsd(WSTETH_POOL, WSTETH, 18);
        (uint256 p, uint256 pd) = PriceOracleMiddlewareManager(_fi.priceManager).getAssetPrice(WBTC);
        uint256 expectedUnits = (uint256(usd) * 10 ** (8 + pd)) / p / 1e18;
        assertApproxEqAbs(_vault.totalAssetsInMarket(M), expectedUnits, 3, "both pools, 8 + 18 dec");
    }

    function test_separateFuses_adjustOpenPosition() public {
        deal(WSTETH, address(_vault), 20e18);
        _exec(
            address(_bothFuse),
            abi.encodeCall(_bothFuse.enter, (FxMintCollateralAndBorrowFuseEnterData(WSTETH_POOL, 10e18, _borrowFor(WSTETH_POOL, WSTETH, 18, 10e18, 2_000))))
        );
        (, uint256 c0, uint256 d0) = _position(WSTETH_POOL);

        _exec(address(_collateralFuse), abi.encodeCall(_collateralFuse.enter, (FxMintCollateralFuseEnterData(WSTETH_POOL, 5e18))));
        (, uint256 c1, ) = _position(WSTETH_POOL);
        assertGt(c1, c0, "collateral added");

        _exec(address(_borrowFuse), abi.encodeCall(_borrowFuse.enter, (FxMintBorrowFuseEnterData(WSTETH_POOL, 1_000e18))));
        (, , uint256 d1) = _position(WSTETH_POOL);
        assertApproxEqAbs(d1, d0 + 1_000e18, 1, "borrowed more");

        _exec(address(_borrowFuse), abi.encodeCall(_borrowFuse.exit, (FxMintBorrowFuseExitData(WSTETH_POOL, 500e18))));
        (, , uint256 d2) = _position(WSTETH_POOL);
        assertApproxEqAbs(d2, d1 - 500e18, 1, "repaid part");

        _exec(address(_collateralFuse), abi.encodeCall(_collateralFuse.exit, (FxMintCollateralFuseExitData(WSTETH_POOL, 3e18))));
        (, uint256 c2, ) = _position(WSTETH_POOL);
        assertLt(c2, c1, "collateral withdrawn");
    }

    function test_collateralOnlyOpen_reverts() public {
        deal(WBTC, address(_vault), 1e8);
        FuseAction[] memory c = new FuseAction[](1);
        c[0] = FuseAction(address(_collateralFuse), abi.encodeCall(_collateralFuse.enter, (FxMintCollateralFuseEnterData(WBTC_POOL, 1e8))));
        vm.prank(ALPHA);
        vm.expectRevert(bytes4(keccak256("ErrorDebtRatioTooSmall()")));
        _vault.execute(c);
    }

    function test_unsupportedPool_reverts() public {
        address notGranted = address(0xBAD);
        FuseAction[] memory c = new FuseAction[](1);
        c[0] = FuseAction(address(_bothFuse), abi.encodeCall(_bothFuse.enter, (FxMintCollateralAndBorrowFuseEnterData(notGranted, 1, 1))));
        vm.prank(ALPHA);
        vm.expectRevert();
        _vault.execute(c);
    }

    function test_instantWithdraw_userExitThroughFxMint() public {
        // instant-withdraw config: the collateral fuse for the WBTC pool
        InstantWithdrawalFusesParamsStruct[] memory cfg = new InstantWithdrawalFusesParamsStruct[](1);
        bytes32[] memory params = new bytes32[](2);
        params[1] = bytes32(uint256(uint160(WBTC_POOL)));
        cfg[0] = InstantWithdrawalFusesParamsStruct({fuse: address(_collateralFuse), params: params});
        vm.prank(ATOMIST);
        PlasmaVaultGovernance(_fi.plasmaVault).configureInstantWithdrawalFuses(cfg);

        deal(WBTC, USER, 2e8);
        vm.startPrank(USER);
        IERC20(WBTC).approve(address(_vault), 2e8);
        _vault.deposit(2e8, USER);
        vm.stopPrank();
        _exec(
            address(_bothFuse),
            abi.encodeCall(_bothFuse.enter, (FxMintCollateralAndBorrowFuseEnterData(WBTC_POOL, 2e8, _borrowFor(WBTC_POOL, WBTC, 8, 2e8, 2_000))))
        );
        assertEq(IERC20(WBTC).balanceOf(address(_vault)), 0, "all idle in f(x)");
        (, uint256 c0, uint256 d0) = _position(WBTC_POOL);

        vm.prank(USER);
        _vault.withdraw(0.5e8, USER, USER);
        assertEq(IERC20(WBTC).balanceOf(USER), 0.5e8, "user paid from f(x) collateral");
        (, uint256 c1, uint256 d1) = _position(WBTC_POOL);
        assertLt(c1, c0, "collateral freed");
        assertEq(d1, d0, "no repayment");
    }
}
