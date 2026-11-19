// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IEVC} from "ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";

import {PlasmaVault, PlasmaVaultInitData, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {ERC4626PriceFeed} from "../../../contracts/price_oracle/price_feed/ERC4626PriceFeed.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {EulerV2BalanceFuse} from "../../../contracts/fuses/euler/EulerV2BalanceFuse.sol";
import {EulerV2SupplyFuse, EulerV2SupplyFuseEnterData} from "../../../contracts/fuses/euler/EulerV2SupplyFuse.sol";
import {
    EulerV2SwapDeployFuse,
    EulerV2SwapDeployFuseEnterData
} from "../../../contracts/fuses/euler/EulerV2SwapDeployFuse.sol";
import {EulerFuseLib, EulerSubstrate} from "../../../contracts/fuses/euler/EulerFuseLib.sol";
import {IEulerV2Swap} from "../../../contracts/fuses/euler/ext/IEulerV2Swap.sol";
import {IEulerV2SwapFactory} from "../../../contracts/fuses/euler/ext/IEulerV2SwapFactory.sol";
import {PlasmaVaultCloneLib} from "../../test_helpers/PlasmaVaultCloneLib.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {RoleLib, UsersToRoles} from "../../RoleLib.sol";

/// @title EulerV2SwapPoolIdleUnderlyingForkTest
/// @notice IL-9706 (CR #1, 3sigma audit v3 #20 and #21) on a Base fork: pins the leak of an EulerSwap pool on EVC
///         sub-account 0x00 whose supply vault is the Plasma Vault's own `asset()`.
/// @dev The Plasma Vault's asset is the eWETH-1 share. EVC sub-account 0x00 is the vault address, so the eWETH-1 leg of
///      a pool on 0x00 is the vault's idle balance: the pool deposits swap input into eWETH-1 for the vault and
///      withdraws swap output from it. `totalAssets` reads idle live, a donation or a swap therefore moves NAV at once
///      without a market refresh. After a refresh the IL-9707 subtraction takes the eWETH-1 position off sub-account
///      0x00 while the displacement of the pool still counts the WETH leg, and `max(0, v - d)` floors the market value
///      at zero, so the offset is lost. The same pool on a non-zero sub-account is protected (control test).
///      The tests describe the CURRENT behaviour of this tree and pass on it. The pool is deployed directly as the vault
///      (EVC.setAccountOperator + EVC.call to the factory), so the leak tests stay valid when the deploy fuse rejects
///      sub-account 0x00 with a supply vault equal to `asset()`. Only
///      `testShouldRejectPoolOnSubAccountZeroTradingVaultAssetThroughDeployFuse` goes through the deploy fuse and
///      pins its rejection. Own fork block, no `vm.warp`.
contract EulerV2SwapPoolIdleUnderlyingForkTest is Test {
    /// @dev Own fork block of this suite (forks are not shared with other suites)
    uint256 private constant _FORK_BLOCK = 47_493_005;

    uint256 private constant _MARKET_ID = IporFusionMarkets.EULER_V2;

    address private constant _EVC = 0x5301c7dD20bD945D2013b48ed0DEE3A284ca8989;
    address private constant _EULERSWAP_FACTORY = 0x6C5f4c239ceD289447737EAB8eEA64523bd9c05E;

    address private constant _EVAULT_CBETH = 0x358f25F82644eaBb441d0df4AF8746614fb9ea49; // ecbETH-1
    /// @dev eWETH-1: the underlying (`asset()`) of the Plasma Vault in this test
    address private constant _EVAULT_WETH = 0x859160DB5841E5cfB8D3f144C6b3381A85A4b410;
    address private constant _CBETH = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22;
    address private constant _WETH = 0x4200000000000000000000000000000000000006;
    address private constant _CBETH_USD_FEED = 0xd7818272B9e248357d13057AAb0B417aF31E817d;
    address private constant _ETH_USD_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;

    bytes1 private constant _SUB_ACCOUNT_ZERO = 0x00;
    bytes1 private constant _SUB_ACCOUNT_ONE = 0x01;

    uint256 private constant _PRICE_DEVIATION_WAD = 1e16;
    uint64 private constant _FEE = 3e15;
    uint64 private constant _CONCENTRATION = 5e17;

    /// @dev EulerSwap v2 pools are Uniswap-v4 hooks: the low 14 bits of the pool address must equal the permission flags
    uint160 private constant _HOOK_FLAG_MASK = uint160((1 << 14) - 1);
    uint160 private constant _HOOK_FLAG_REQUIRED = uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 5) | (1 << 3));

    /// @dev eWETH-1 shares of the holder (the vault's idle underlying), wrapped from this many WETH
    uint256 private constant _IDLE_WETH = 50e18;
    /// @dev cbETH supplied on the pool sub-account: below the donation, so the donation floors market 11
    uint256 private constant _CBETH_SUPPLY = 1e18;
    /// @dev WETH supplied on the pool sub-account in the control (sub-account 0x01)
    uint256 private constant _WETH_SUPPLY = 10e18;
    uint256 private constant _DONATION = 5e18;
    /// @dev Tolerance for rounding of the conversions (EVK shares, oracle WAD)
    uint256 private constant _TOL = 1e13;

    address private constant _ALPHA = address(0x1);
    address private constant _UPDATER = address(0x2);
    address private constant _USER = address(0xA11CE);
    address private constant _SINK = address(0xD057);

    EulerV2SupplyFuse private _supplyFuse;
    EulerV2SwapDeployFuse private _deployFuse;
    EulerV2BalanceFuse private _balanceFuse;
    PriceOracleMiddleware private _oracle;
    PlasmaVault private _plasmaVault;

    address private _pool;
    bytes32 private _salt;
    address private _eulerAccount;
    bytes1 private _subAccount;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_PROVIDER_URL"), _FORK_BLOCK);

        _oracle = _createOracle();
        _supplyFuse = new EulerV2SupplyFuse(_MARKET_ID, _EVC);
        _deployFuse = new EulerV2SwapDeployFuse(_MARKET_ID, _EVC, _EULERSWAP_FACTORY, _PRICE_DEVIATION_WAD);
        _balanceFuse = new EulerV2BalanceFuse(_MARKET_ID, _EVC);
        _plasmaVault = _createPlasmaVault();

        // the holder wraps WETH into eWETH-1 and deposits the shares: the vault's idle underlying on address(vault)
        deal(_WETH, _USER, _IDLE_WETH);
        vm.startPrank(_USER);
        IERC20(_WETH).approve(_EVAULT_WETH, _IDLE_WETH);
        uint256 shares = IERC4626(_EVAULT_WETH).deposit(_IDLE_WETH, _USER);
        IERC20(_EVAULT_WETH).approve(address(_plasmaVault), shares);
        _plasmaVault.deposit(shares, _USER);
        vm.stopPrank();
    }

    //******************************************************************************************************************
    //********************            SUB-ACCOUNT 0x00: the idle underlying is a pool leg           ********************
    //******************************************************************************************************************

    /// @notice A donation of WETH to a pool on 0x00 plus a dust swap moves `totalAssets` by the donation at once, with
    ///         no market refresh: the pool deposited the whole WETH balance into eWETH-1 for the vault, which is idle.
    function testShouldRaiseTotalAssetsByDonationAtOnceWithoutRefreshOnSubAccountZero() external {
        // given
        _openPool(_SUB_ACCOUNT_ZERO);
        uint256 totalAssetsBefore = _plasmaVault.totalAssets();
        uint256 marketBefore = _plasmaVault.totalAssetsInMarket(_MARKET_ID);
        uint256 idleBefore = IERC20(_EVAULT_WETH).balanceOf(address(_plasmaVault));

        // when
        _donateWeth(_DONATION);

        // then
        uint256 idleDelta = IERC20(_EVAULT_WETH).balanceOf(address(_plasmaVault)) - idleBefore;
        uint256 totalAssetsDelta = _plasmaVault.totalAssets() - totalAssetsBefore;
        emit log_named_uint("0x00 live: idle eWETH delta", idleDelta);
        emit log_named_uint("0x00 live: totalAssets delta (eWETH shares)", totalAssetsDelta);
        emit log_named_uint("0x00 live: donation in eWETH shares", IERC4626(_EVAULT_WETH).convertToShares(_DONATION));
        assertEq(_plasmaVault.totalAssetsInMarket(_MARKET_ID), marketBefore, "market 11 cache untouched: no refresh");
        assertEq(totalAssetsDelta, idleDelta, "NAV moved by the idle balance only");
        assertEq(totalAssetsDelta, 4825287948765684493, "NAV rise equals the donation in eWETH shares");
        assertApproxEqRel(
            IERC4626(_EVAULT_WETH).convertToAssets(totalAssetsDelta),
            _DONATION,
            1e15,
            "NAV rose by about the whole donation at once"
        );
    }

    /// @notice After a refresh market 11 is zero: the IL-9707 subtraction removed the eWETH-1 leg from `v` and the
    ///         pool term `d` still counts the WETH leg, so `max(0, v - d)` floors and the offset is lost.
    ///         `totalAssets` stays above the pre-donation NAV by far more than the LP fee.
    function testShouldLeaveDonationUncompensatedAfterRefreshOnSubAccountZero() external {
        // given
        _openPool(_SUB_ACCOUNT_ZERO);
        uint256 navBefore = _refreshedTotalAssets();
        uint256 marketBefore = _plasmaVault.totalAssetsInMarket(_MARKET_ID);
        assertGt(marketBefore, 0, "the cbETH position is counted before the donation");

        // when
        _donateWeth(_DONATION);
        uint256 navAfter = _refreshedTotalAssets();

        // then
        uint256 gain = navAfter - navBefore;
        uint256 feeInShares = IERC4626(_EVAULT_WETH).convertToShares((_DONATION * _FEE) / 1e18);
        emit log_named_uint("0x00 refreshed: market 11 before", marketBefore);
        emit log_named_uint("0x00 refreshed: totalAssets gain", gain);
        emit log_named_uint("0x00 refreshed: fee on donation in shares", feeInShares);
        assertEq(_plasmaVault.totalAssetsInMarket(_MARKET_ID), 0, "market 11 floors at zero");
        assertGt(gain, 10 * feeInShares, "the donation is not offset: gain far above the LP fee");
        // the whole donation (4.825... eWETH shares) stays in NAV, minus the cbETH value the floor swallowed
        assertEq(marketBefore, 1092436196815730481, "market 11 before the donation (eWETH shares)");
        assertEq(gain, 3732851751949954012, "totalAssets gain after the refresh (eWETH shares)");
        assertEq(
            gain,
            IERC4626(_EVAULT_WETH).convertToShares(_DONATION) - marketBefore,
            "gain = donation - floored market value"
        );
    }

    /// @notice A holder's shares fixed before the donation redeem, paid from idle, above their pre-donation value
    ///         (no refresh needed: the redeem reads `totalAssets` live).
    function testShouldOverpayRedeemOfFixedSharesAfterDonationOnSubAccountZero() external {
        // given
        _openPool(_SUB_ACCOUNT_ZERO);
        _refresh();
        uint256 shares = _plasmaVault.balanceOf(_USER) / 10;
        uint256 valueBefore = _plasmaVault.convertToAssets(shares);

        // when
        _donateWeth(_DONATION);
        uint256 balanceBefore = IERC20(_EVAULT_WETH).balanceOf(_USER);
        vm.prank(_USER);
        uint256 paid = _plasmaVault.redeem(shares, _USER, _USER);

        // then
        emit log_named_uint("0x00 redeem: value before donation", valueBefore);
        emit log_named_uint("0x00 redeem: paid after donation", paid);
        assertEq(IERC20(_EVAULT_WETH).balanceOf(_USER) - balanceBefore, paid, "the holder received the payout");
        assertGt(paid, valueBefore, "paid above the pre-donation value");
        assertEq(valueBefore, 4934531568447257541, "pre-donation value of the fixed shares (eWETH shares)");
        assertEq(paid, 5417060363323825990, "payout after the donation (eWETH shares)");
        // the holder owns 10% of the supply: the overpayment is about a tenth of the donation in eWETH shares
        assertApproxEqRel(
            paid - valueBefore,
            IERC4626(_EVAULT_WETH).convertToShares(_DONATION) / 10,
            2e16,
            "overpayment is about a tenth of the donation"
        );
    }

    /// @notice A zero-input swap pulls the donation back out of idle: `totalAssets` falls at once, the donor loses the
    ///         LP fee only, so the whole round trip is free for the attacker.
    function testShouldReturnDonationFromIdleWithZeroInputSwapOnSubAccountZero() external {
        // given
        _openPool(_SUB_ACCOUNT_ZERO);
        uint256 navBefore = _refreshedTotalAssets();
        _donateWeth(_DONATION);
        uint256 navDonated = _plasmaVault.totalAssets();
        uint256 sinkBefore = IERC20(_WETH).balanceOf(_SINK);

        // when: 90% of the donation net of the fee, no input
        uint256 out1 = (_DONATION * 9 * (1e18 - _FEE)) / (10 * 1e18);
        _poolSwap(0, out1);

        // then
        uint256 returned = IERC20(_WETH).balanceOf(_SINK) - sinkBefore;
        uint256 navAfter = _plasmaVault.totalAssets();
        emit log_named_uint("0x00 round trip: WETH returned to the donor", returned);
        emit log_named_uint("0x00 round trip: totalAssets after extraction", navAfter);
        assertEq(returned, 4486500000000000000, "WETH the donor took back");
        assertEq(returned, out1, "the donor took the donation back");
        assertLt(navAfter, navDonated, "totalAssets fell at once");
        assertApproxEqRel(
            IERC4626(_EVAULT_WETH).convertToAssets(navDonated - navAfter),
            out1,
            1e15,
            "the fall equals the extracted WETH"
        );
        assertGt(navAfter + IERC4626(_EVAULT_WETH).convertToShares(_DONATION) / 4, navBefore, "NAV is back near start");
    }

    //******************************************************************************************************************
    //********************                CONTROL: the same pool on sub-account 0x01                ********************
    //******************************************************************************************************************

    /// @notice The same pool on a non-zero sub-account does not touch the vault's idle balance: the donation does not
    ///         move `totalAssets` before a refresh, and after a refresh it moves by the LP fee only.
    function testShouldMoveNavByFeeOnlyForSamePoolOnSubAccountOne() external {
        // given
        _openPool(_SUB_ACCOUNT_ONE);
        uint256 navBefore = _refreshedTotalAssets();
        uint256 idleBefore = IERC20(_EVAULT_WETH).balanceOf(address(_plasmaVault));

        // when
        _donateWeth(_DONATION);

        // then
        assertEq(IERC20(_EVAULT_WETH).balanceOf(address(_plasmaVault)), idleBefore, "idle balance untouched");
        assertEq(_plasmaVault.totalAssets(), navBefore, "no live NAV move without a refresh");

        uint256 navAfter = _refreshedTotalAssets();
        uint256 gain = navAfter - navBefore;
        uint256 feeInShares = IERC4626(_EVAULT_WETH).convertToShares((_DONATION * _FEE) / 1e18);
        emit log_named_uint("0x01 refreshed: totalAssets gain", gain);
        emit log_named_uint("0x01 refreshed: fee on donation in shares", feeInShares);
        assertApproxEqAbs(gain, feeInShares, _TOL, "protected: value moves by the LP fee only");
    }

    //******************************************************************************************************************
    //********************                   DEPLOY PATH (flips with the T26 fix)                   ********************
    //******************************************************************************************************************

    /// @notice The deploy fuse rejects sub-account 0x00 with `supplyVault1 == asset()` (IL-9706 D-027); the leak tests
    ///         above deploy the pool directly and stay as they are.
    function testShouldRejectPoolOnSubAccountZeroTradingVaultAssetThroughDeployFuse() external {
        // given
        _preparePool(_SUB_ACCOUNT_ZERO);
        _grantSubstrates();
        assertEq(IERC4626(address(_plasmaVault)).asset(), _EVAULT_WETH, "the vault asset is the supply vault");

        // when
        FuseAction[] memory actions = new FuseAction[](2);
        actions[0] = _supplyAction(_EVAULT_CBETH, _CBETH_SUPPLY);
        actions[1] = _deployAction();
        deal(_CBETH, address(_plasmaVault), _CBETH_SUPPLY);
        vm.expectRevert(
            abi.encodeWithSignature("EulerV2SwapDeployFuseSubAccountZeroUsesVaultAsset(address)", address(_plasmaVault))
        );
        vm.prank(_ALPHA);
        _plasmaVault.execute(actions);

        // then
        assertEq(_pool.code.length, 0, "pool not deployed");
        assertFalse(IEVC(_EVC).isAccountOperatorAuthorized(address(_plasmaVault), _pool), "no operator on 0x00");
    }

    //******************************************************************************************************************
    //********************                              HELPERS                                     ********************
    //******************************************************************************************************************

    /// @dev Deploys the pool directly as the vault (no deploy fuse), with the rows and the pool entry granted and the
    ///      cbETH (and, on 0x01, the WETH) supplied on the pool sub-account
    function _openPool(bytes1 subAccount_) private {
        _preparePool(subAccount_);
        _grantSubstrates();

        deal(_CBETH, address(_plasmaVault), _CBETH_SUPPLY);
        uint256 count = subAccount_ == _SUB_ACCOUNT_ZERO ? 1 : 2;
        FuseAction[] memory actions = new FuseAction[](count);
        actions[0] = _supplyActionOn(_EVAULT_CBETH, _CBETH_SUPPLY, subAccount_);
        if (count == 2) {
            deal(_WETH, address(_plasmaVault), _WETH_SUPPLY);
            actions[1] = _supplyActionOn(_EVAULT_WETH, _WETH_SUPPLY, subAccount_);
        }
        vm.prank(_ALPHA);
        _plasmaVault.execute(actions);

        vm.startPrank(address(_plasmaVault));
        IEVC(_EVC).setAccountOperator(_eulerAccount, _pool, true);
        IEVC(_EVC).call(
            _EULERSWAP_FACTORY,
            _eulerAccount,
            0,
            abi.encodeCall(IEulerV2SwapFactory.deployPool, (_staticParams(), _dynamicParams(), _initialState(), _salt))
        );
        vm.stopPrank();
        assertGt(_pool.code.length, 0, "pool deployed directly");

        _refresh();
    }

    function _preparePool(bytes1 subAccount_) private {
        _subAccount = subAccount_;
        _eulerAccount = EulerFuseLib.generateSubAccountAddress(address(_plasmaVault), subAccount_);
        (_salt, _pool) = _mineSalt(_staticParams());
    }

    /// @dev Rows (collateral + borrow) of both eVaults and the pool entry, all on the pool sub-account
    function _grantSubstrates() private {
        bytes32[] memory substrates = new bytes32[](3);
        substrates[0] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: _EVAULT_CBETH, isCollateral: true, canBorrow: true, subAccounts: _subAccount})
        );
        substrates[1] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: _EVAULT_WETH, isCollateral: true, canBorrow: true, subAccounts: _subAccount})
        );
        substrates[2] = EulerFuseLib.swapPoolSubstrateToBytes32(_pool, _subAccount);
        PlasmaVaultGovernance(address(_plasmaVault)).grantMarketSubstrates(_MARKET_ID, substrates);
    }

    function _staticParams() private view returns (IEulerV2Swap.StaticParams memory) {
        return
            IEulerV2Swap.StaticParams({
                supplyVault0: _EVAULT_CBETH,
                supplyVault1: _EVAULT_WETH,
                borrowVault0: _EVAULT_CBETH,
                borrowVault1: _EVAULT_WETH,
                eulerAccount: _eulerAccount,
                feeRecipient: address(0)
            });
    }

    /// @dev asset0 = cbETH, asset1 = WETH; priceX/priceY = 1.13309 is about 0.097% off the oracle ratio of the block
    function _dynamicParams() private pure returns (IEulerV2Swap.DynamicParams memory) {
        return
            IEulerV2Swap.DynamicParams({
                equilibriumReserve0: uint112(5e18),
                equilibriumReserve1: uint112(5e18),
                minReserve0: 0,
                minReserve1: 0,
                priceX: uint80(1133090000000000000),
                priceY: uint80(1e18),
                concentrationX: _CONCENTRATION,
                concentrationY: _CONCENTRATION,
                fee0: _FEE,
                fee1: _FEE,
                expiration: 0,
                swapHookedOperations: 0,
                swapHook: address(0)
            });
    }

    function _initialState() private pure returns (IEulerV2Swap.InitialState memory) {
        return IEulerV2Swap.InitialState({reserve0: uint112(5e18), reserve1: uint112(5e18)});
    }

    function _mineSalt(IEulerV2Swap.StaticParams memory sp_) private view returns (bytes32 salt, address predicted) {
        for (uint256 i; i < 200000; ++i) {
            salt = bytes32(i);
            predicted = IEulerV2SwapFactory(_EULERSWAP_FACTORY).computePoolAddress(sp_, salt);
            if (
                (uint160(predicted) & _HOOK_FLAG_MASK) == _HOOK_FLAG_REQUIRED &&
                !IEulerV2SwapFactory(_EULERSWAP_FACTORY).deployedPools(predicted)
            ) {
                return (salt, predicted);
            }
        }
        revert("salt mining failed");
    }

    function _supplyAction(address eVault_, uint256 amount_) private view returns (FuseAction memory) {
        return _supplyActionOn(eVault_, amount_, _subAccount);
    }

    function _supplyActionOn(
        address eVault_,
        uint256 amount_,
        bytes1 subAccount_
    ) private view returns (FuseAction memory) {
        return
            FuseAction({
                fuse: address(_supplyFuse),
                data: abi.encodeWithSignature(
                    "enter((address,uint256,bytes1))",
                    EulerV2SupplyFuseEnterData({eulerVault: eVault_, maxAmount: amount_, subAccount: subAccount_})
                )
            });
    }

    function _deployAction() private view returns (FuseAction memory) {
        EulerV2SwapDeployFuseEnterData memory data = EulerV2SwapDeployFuseEnterData({
            staticParams: _staticParams(),
            dynamicParams: _dynamicParams(),
            initialState: _initialState(),
            salt: _salt,
            predictedPool: _pool,
            subAccount: _subAccount
        });
        return
            FuseAction({
                fuse: address(_deployFuse),
                data: abi.encodeWithSignature(
                    "enter(((address,address,address,address,address,address),(uint112,uint112,uint112,uint112,uint80,uint80,uint64,uint64,uint64,uint64,uint40,uint8,address),(uint112,uint112),bytes32,address,bytes1))",
                    data
                )
            });
    }

    /// @dev Donation: `amount_` WETH is sent to the pool and a dust swap in cbETH lets the pool book the whole WETH
    ///      balance as swap input, i.e. deposit it into eWETH-1 for the pool's `eulerAccount`
    function _donateWeth(uint256 amount_) private {
        deal(_WETH, _pool, IERC20(_WETH).balanceOf(_pool) + amount_);
        _poolSwap(1e9, 0);
    }

    function _poolSwap(uint256 out0_, uint256 out1_) private {
        (bool ok, bytes memory ret) = _pool.call(
            abi.encodeWithSignature("swap(uint256,uint256,address,bytes)", out0_, out1_, _SINK, "")
        );
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    function _refresh() private {
        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = _MARKET_ID;
        vm.prank(_UPDATER);
        _plasmaVault.updateMarketsBalances(marketIds);
    }

    function _refreshedTotalAssets() private returns (uint256) {
        _refresh();
        return _plasmaVault.totalAssets();
    }

    /// @dev WETH and cbETH from Chainlink, eWETH-1 (the vault asset) from its share price through ERC4626PriceFeed
    function _createOracle() private returns (PriceOracleMiddleware oracle) {
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(address(0));
        oracle = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );
        address[] memory assets = new address[](3);
        assets[0] = _WETH;
        assets[1] = _CBETH;
        assets[2] = _EVAULT_WETH;
        address[] memory sources = new address[](3);
        sources[0] = _ETH_USD_FEED;
        sources[1] = _CBETH_USD_FEED;
        sources[2] = address(new ERC4626PriceFeed(_EVAULT_WETH));
        oracle.setAssetsPricesSources(assets, sources);
    }

    /// @dev A locally built PlasmaVault (never a factory clone, so the test runs the code of this tree) whose asset is
    ///      eWETH-1, with the supply, deploy and balance fuses on market 11; the test contract is atomist and fuse
    ///      manager
    function _createPlasmaVault() private returns (PlasmaVault plasmaVault) {
        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = address(this);
        usersToRoles.atomist = address(this);
        address[] memory alphas = new address[](1);
        alphas[0] = _ALPHA;
        usersToRoles.alphas = alphas;
        IporFusionAccessManager accessManager = RoleLib.createAccessManager(usersToRoles, 0, vm);
        WithdrawManager withdrawManager = new WithdrawManager(address(accessManager));

        plasmaVault = PlasmaVaultCloneLib.newPlasmaVault();
        plasmaVault.proxyInitialize(
            PlasmaVaultInitData(
                "IPOR Fusion eWETH",
                "ipfeWETH",
                _EVAULT_WETH,
                address(_oracle),
                FeeConfigHelper.createZeroFeeConfig(),
                address(accessManager),
                address(new PlasmaVaultBase()),
                address(withdrawManager),
                address(0)
            )
        );
        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(plasmaVault), accessManager, address(withdrawManager));

        bytes4[] memory updateSig = new bytes4[](1);
        updateSig[0] = PlasmaVault.updateMarketsBalances.selector;
        accessManager.setTargetFunctionRole(address(plasmaVault), updateSig, Roles.UPDATE_MARKETS_BALANCES_ROLE);
        accessManager.grantRole(Roles.UPDATE_MARKETS_BALANCES_ROLE, _UPDATER, 0);

        address[] memory fuses = new address[](2);
        fuses[0] = address(_supplyFuse);
        fuses[1] = address(_deployFuse);
        PlasmaVaultGovernance(address(plasmaVault)).addFuses(fuses);
        PlasmaVaultGovernance(address(plasmaVault)).addBalanceFuse(_MARKET_ID, address(_balanceFuse));
    }
}
