// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FxMintCollateralFuse, FxMintCollateralFuseEnterData, FxMintCollateralFuseExitData} from "../../../contracts/fuses/fxmint/FxMintCollateralFuse.sol";
import {FxMintBorrowFuse, FxMintBorrowFuseEnterData, FxMintBorrowFuseExitData} from "../../../contracts/fuses/fxmint/FxMintBorrowFuse.sol";
import {FxMintCollateralAndBorrowFuse, FxMintCollateralAndBorrowFuseEnterData, FxMintCollateralAndBorrowFuseExitData} from "../../../contracts/fuses/fxmint/FxMintCollateralAndBorrowFuse.sol";
import {FxMintBalanceFuse} from "../../../contracts/fuses/fxmint/FxMintBalanceFuse.sol";
import {IFxPool} from "../../../contracts/fuses/fxmint/ext/IFxPool.sol";
import {IFxPoolManager} from "../../../contracts/fuses/fxmint/ext/IFxPoolManager.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";

struct FuseActionT {
    address fuse;
    bytes data;
}

struct InstantFuseT {
    address fuse;
    bytes32[] params;
}

interface IVaultT {
    function execute(FuseActionT[] calldata calls) external;
    function addFuses(address[] calldata fuses) external;
    function addBalanceFuse(uint256 marketId, address fuse) external;
    function grantMarketSubstrates(uint256 marketId, bytes32[] calldata substrates) external;
    function updateDependencyBalanceGraphs(uint256[] memory marketIds, uint256[][] memory deps) external;
    function configureInstantWithdrawalFuses(InstantFuseT[] calldata fuses) external;
    function totalAssetsInMarket(uint256 marketId) external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256);
}

interface IPriceManagerT {
    function setAssetsPriceSources(address[] calldata assets, address[] calldata sources) external;
    function getAssetPrice(address asset) external view returns (uint256 price, uint256 decimals);
}

/// @notice FxMint fuses on a Katana fork, installed on a live PlasmaVault (CurveYield vbWBTC) as market FX_MINT,
///         against the real f(x) vbWBTC long pool. Run with --isolate (f(x) allows one operate per transaction).
contract FxMintFusesKatanaForkTest is Test {
    address internal constant VAULT = 0xBfC4f3E84637c67dbA95B856fcB1a4D98dbdcd3e;
    address internal constant ATOMIST_ALPHA = 0x11b78837cadC8E894F1c6e13fA9f3A085a75FA35;
    address internal constant PRICE_MANAGER = 0x459d12701f88cE8Dcc49c24a9Fa747c5Fe07e3D7;
    address internal constant POOL = 0x49150F136C5a5Af361ECb06cB38A6205461E33CD;
    address internal constant VBWBTC = 0x0913DA6Da4b42f538B445599b46Bb4622342Cf52;
    address internal constant FXUSD = 0x4c03ff0f44A55e7098a09016E02a01d3cdC2FDF9;
    address internal constant USD_FEED = 0x64518f821Cd07A9471711Eba5D8fEF9c75063B01; // fixed $1 (Katana)
    uint256 internal constant M = IporFusionMarkets.FX_MINT;

    FxMintCollateralFuse internal collateralFuse;
    FxMintBorrowFuse internal borrowFuse;
    FxMintCollateralAndBorrowFuse internal bothFuse;
    FxMintBalanceFuse internal balanceFuse;
    IVaultT internal vault = IVaultT(VAULT);

    function setUp() public {
        vm.createSelectFork(vm.envOr("KATANA_RPC_URL", string("https://rpc.katana.network")));
        collateralFuse = new FxMintCollateralFuse(M);
        borrowFuse = new FxMintBorrowFuse(M);
        bothFuse = new FxMintCollateralAndBorrowFuse(M);
        balanceFuse = new FxMintBalanceFuse(M);

        vm.startPrank(ATOMIST_ALPHA);
        address[] memory f = new address[](3);
        (f[0], f[1], f[2]) = (address(collateralFuse), address(borrowFuse), address(bothFuse));
        vault.addFuses(f);
        vault.addBalanceFuse(M, address(balanceFuse));
        bytes32[] memory subs = new bytes32[](1);
        subs[0] = bytes32(uint256(uint160(POOL)));
        vault.grantMarketSubstrates(M, subs);
        uint256[] memory ids = new uint256[](1);
        ids[0] = M;
        uint256[][] memory deps = new uint256[][](1);
        deps[0] = new uint256[](1);
        deps[0][0] = IporFusionMarkets.ERC20_VAULT_BALANCE;
        vault.updateDependencyBalanceGraphs(ids, deps);
        address[] memory a = new address[](1);
        address[] memory s = new address[](1);
        (a[0], s[0]) = (FXUSD, USD_FEED);
        IPriceManagerT(PRICE_MANAGER).setAssetsPriceSources(a, s);
        vm.stopPrank();

        deal(VBWBTC, VAULT, IERC20(VBWBTC).balanceOf(VAULT) + 200_000); // 0.002 vbWBTC of fresh idle
    }

    function _exec(address fuse_, bytes memory data_) internal {
        FuseActionT[] memory c = new FuseActionT[](1);
        c[0] = FuseActionT(fuse_, data_);
        vm.prank(ATOMIST_ALPHA);
        vault.execute(c);
    }

    function _position() internal view returns (uint256 id, uint256 rawColls, uint256 rawDebts) {
        bytes32 slot = keccak256(
            abi.encode(POOL, uint256(0xdab5b7d53c456d684bd7aab42036d7f8a41a58fdd80195990e6fa923e0f6d200))
        );
        id = uint256(vm.load(VAULT, slot));
        if (id != 0) (rawColls, rawDebts) = IFxPool(POOL).getPosition(id);
    }

    /// @dev expected market value (vault units = vbWBTC) from the live position, middleware prices, f(x) withdraw fee
    function _expectedUsd() internal view returns (uint256) {
        (, uint256 rawColls, uint256 rawDebts) = _position();
        uint256 amount = (rawColls * 1e18) /
            IFxPoolManager(IFxPool(POOL).poolManager()).getTokenScalingFactor(VBWBTC);
        (uint256 pc, uint256 dc) = IPriceManagerT(PRICE_MANAGER).getAssetPrice(VBWBTC);
        (uint256 pf, uint256 df) = IPriceManagerT(PRICE_MANAGER).getAssetPrice(FXUSD);
        uint256 collUsd = (amount * pc * 1e18) / 10 ** (8 + dc); // withdraw fee is 0 on Katana today
        uint256 debtUsd = (rawDebts * pf) / 10 ** df;
        return collUsd - debtUsd;
    }

    function test_openBorrowValueRepayClose() public {
        // open + borrow in one operate: 0.001 vbWBTC, ~40% LTV
        (uint256 p, uint256 pd) = IPriceManagerT(PRICE_MANAGER).getAssetPrice(VBWBTC);
        uint256 debt = (100_000 * p * 40) / 100 / 10 ** (pd + 8 - 18);
        _exec(
            address(bothFuse),
            abi.encodeCall(bothFuse.enter, (FxMintCollateralAndBorrowFuseEnterData(POOL, 100_000, debt)))
        );
        (uint256 id, uint256 rawColls, uint256 rawDebts) = _position();
        assertGt(id, 0, "position id stored");
        assertGt(rawColls, 0, "collateral");
        assertApproxEqAbs(rawDebts, debt, 1, "debt");
        assertGt(IERC20(FXUSD).balanceOf(VAULT), 0, "borrowed fxUSD in the vault");

        // balance fuse: collateral - debt, in USD -> the vault stores it in underlying units
        uint256 inMarket = vault.totalAssetsInMarket(M);
        (uint256 pc, uint256 dc) = IPriceManagerT(PRICE_MANAGER).getAssetPrice(VBWBTC);
        uint256 expectedUnits = (_expectedUsd() * 10 ** (8 + dc)) / pc / 1e18;
        assertApproxEqAbs(inMarket, expectedUnits, 2, "market value == collateral - debt");
    }

    function test_separateFusesAndFullClose() public {
        // open with both legs (f(x) rejects a debt-free position)
        _exec(address(bothFuse), abi.encodeCall(bothFuse.enter, (FxMintCollateralAndBorrowFuseEnterData(POOL, 100_000, 10e18))));
        (uint256 id, uint256 rawColls, ) = _position();
        assertGt(id, 0);
        // separate fuses on the open position
        _exec(address(collateralFuse), abi.encodeCall(collateralFuse.enter, (FxMintCollateralFuseEnterData(POOL, 50_000))));
        (, uint256 rawColls2, ) = _position();
        assertGt(rawColls2, rawColls, "collateral added");
        _exec(address(borrowFuse), abi.encodeCall(borrowFuse.enter, (FxMintBorrowFuseEnterData(POOL, 10e18))));
        (, , uint256 rawDebts) = _position();
        assertApproxEqAbs(rawDebts, 20e18, 1);
        _exec(address(collateralFuse), abi.encodeCall(collateralFuse.exit, (FxMintCollateralFuseExitData(POOL, 20_000))));
        (, uint256 rawColls3, ) = _position();
        assertLt(rawColls3, rawColls2, "collateral withdrawn");

        // repay half (the vault holds the borrowed fxUSD; repay fee comes from it as well)
        _exec(address(borrowFuse), abi.encodeCall(borrowFuse.exit, (FxMintBorrowFuseExitData(POOL, 10e18))));
        (, , rawDebts) = _position();
        assertApproxEqAbs(rawDebts, 10e18, 1);

        // top the vault up with fxUSD for the rest + fee, then close everything in one operate
        deal(FXUSD, VAULT, IERC20(FXUSD).balanceOf(VAULT) + 1e18);
        uint256 idleBefore = IERC20(VBWBTC).balanceOf(VAULT);
        _exec(
            address(bothFuse),
            abi.encodeCall(
                bothFuse.exit,
                (FxMintCollateralAndBorrowFuseExitData(POOL, type(uint256).max, type(uint256).max))
            )
        );
        (id, rawColls, rawDebts) = _position();
        assertEq(id, 0, "storage cleared on full close");
        assertGt(IERC20(VBWBTC).balanceOf(VAULT), idleBefore, "collateral returned");
        assertEq(vault.totalAssetsInMarket(M), 0, "market empty");
    }

    function test_collateralOnlyOpenReverts() public {
        FuseActionT[] memory c = new FuseActionT[](1);
        c[0] = FuseActionT(address(collateralFuse), abi.encodeCall(collateralFuse.enter, (FxMintCollateralFuseEnterData(POOL, 100_000))));
        vm.prank(ATOMIST_ALPHA);
        vm.expectRevert(bytes4(keccak256("ErrorDebtRatioTooSmall()")));
        vault.execute(c);
    }

    function test_instantWithdrawFreesOnlyUnencumberedCollateral() public {
        _exec(address(bothFuse), abi.encodeCall(bothFuse.enter, (FxMintCollateralAndBorrowFuseEnterData(POOL, 200_000, 30e18))));
        (, uint256 rawCollsBefore, ) = _position();

        // instantWithdraw runs in the vault context: exercise it through a real vault withdrawal
        InstantFuseT[] memory cfg = new InstantFuseT[](1);
        cfg[0] = InstantFuseT(address(collateralFuse), new bytes32[](2));
        cfg[0].params[1] = bytes32(uint256(uint160(POOL)));
        vm.prank(ATOMIST_ALPHA);
        vault.configureInstantWithdrawalFuses(cfg);

        address user = address(0xBEEF);
        deal(VBWBTC, user, 300_000);
        vm.startPrank(user);
        IERC20(VBWBTC).approve(VAULT, 300_000);
        vault.deposit(300_000, user);
        vm.stopPrank();
        // move almost all idle into f(x) so the withdrawal has to use the instant fuse
        uint256 idle = IERC20(VBWBTC).balanceOf(VAULT);
        _exec(address(collateralFuse), abi.encodeCall(collateralFuse.enter, (FxMintCollateralFuseEnterData(POOL, idle))));
        (, uint256 rawColls, uint256 rawDebts) = _position();
        assertGt(rawColls, rawCollsBefore);

        vm.prank(user);
        vault.withdraw(100_000, user, user);
        assertGe(IERC20(VBWBTC).balanceOf(user), 100_000, "user paid through the instant fuse");
        (, uint256 rawCollsAfter, uint256 rawDebtsAfter) = _position();
        assertLt(rawCollsAfter, rawColls, "collateral freed");
        assertEq(rawDebtsAfter, rawDebts, "no repayment needed");
    }
}
