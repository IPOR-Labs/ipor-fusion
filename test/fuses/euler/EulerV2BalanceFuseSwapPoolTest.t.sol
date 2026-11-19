// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IEVC} from "@ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";

import {EulerV2BalanceFuse} from "../../../contracts/fuses/euler/EulerV2BalanceFuse.sol";
import {EulerFuseLib, EulerSubstrate} from "../../../contracts/fuses/euler/EulerFuseLib.sol";
import {IBorrowing} from "../../../contracts/fuses/euler/ext/IBorrowing.sol";
import {IEulerV2Swap} from "../../../contracts/fuses/euler/ext/IEulerV2Swap.sol";
import {IEulerV2VaultGovernance} from "../../../contracts/fuses/euler/ext/IEulerV2VaultGovernance.sol";
import {IPriceOracleMiddleware} from "../../../contracts/price_oracle/IPriceOracleMiddleware.sol";
import {Errors} from "../../../contracts/libraries/errors/Errors.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";
import {EulerSwapCurveReference} from "./mocks/EulerSwapCurveReference.sol";
import {MockEulerV2SwapPoolState} from "./mocks/MockEulerV2SwapPoolState.sol";

/// @title EulerV2BalanceFuseSwapPoolTest
/// @notice IL-9706 (3sigma audit v3 #20): EulerV2BalanceFuse values the sub-account of a live EulerSwap pool at the
///         oracle-fair point of the pool curve: max(0, v - sum of d), v being the value of the sub-account (IL-9528, after
///         the IL-9707 rule on 0x00) and d the oracle value of the pool reserves above the value of the fair point. A
///         swap or a donation that moves the holdings of the sub-account and the reserves of the pool by the same amounts
///         does not change the result. Positions and the EVC are mocked, the pool is MockEulerV2SwapPoolState; the fuse
///         runs in the storage context of PlasmaVaultMock through a delegatecall, as in a Plasma Vault.
///         Expected values are plain arithmetic; at rho != 1 the fair point is derived in the test and checked against
///         EulerSwapCurveReference (transcribed CurveLib.f / verify), never taken from the library under test.
///         On the base commit every test with a pool entry fails: the base fuse reads a pool entry as an eVault row and
///         calls ERC-4626 `balanceOf` on the pool.
contract EulerV2BalanceFuseSwapPoolTest is Test {
    uint256 private constant _MARKET_ID = 11;

    bytes1 private constant _VAULT_SUB_ACCOUNT = 0x00;
    bytes1 private constant _POOL_SUB_ACCOUNT = 0x01;
    bytes1 private constant _OTHER_SUB_ACCOUNT = 0x02;
    bytes1 private constant _EMPTY_SUB_ACCOUNT = 0x03;

    /// @dev USD prices with 8 decimals, as returned by the price oracle middleware
    uint256 private constant _PRICE_DECIMALS = 8;
    uint256 private constant _ONE_USD = 1e8;
    uint256 private constant _WETH_PRICE_USD = 2_000e8;
    uint256 private constant _GOLD_PRICE_USD = 4e8;

    /// @dev Default curve: equilibrium 1 000 / 1 000 (6 decimals), curve prices 1:1, concentration 0.5 on both sides
    uint256 private constant _EQUILIBRIUM = 1_000e6;
    uint256 private constant _CURVE_PRICE = 1e18;
    uint256 private constant _HALF_CONCENTRATION = 0.5e18;

    /// @dev On the default curve f(500e6) = 1 000e6 + ceil(1e18 * 500e6 * 7.5e26 / (1e18 * 500e6 * 1e18)) = 1 750e6
    uint112 private constant _SWAPPED_RESERVE0 = 500e6;
    uint112 private constant _SWAPPED_RESERVE1 = 1_750e6;
    /// @dev At the oracle prices 1 USD / 1 USD the fair point is the equilibrium: d = 500 + 1 750 - 2 000 = 250 USD
    uint256 private constant _SWAPPED_DISPLACEMENT = 250e18;

    address private _evc;
    address private _middleware;

    /// @dev Tokens: USDC-like, USDT-like and GOLD-like (6 decimals), WETH-like (18 decimals)
    address private _usdc;
    address private _usdt;
    address private _weth;
    address private _gold;

    /// @dev Euler vaults over USDC, USDT and WETH
    address private _eulerVaultUsdc;
    address private _eulerVaultUsdt;
    address private _eulerVaultWeth;

    EulerV2BalanceFuse private _balanceFuse;
    PlasmaVaultMock private _plasmaVault;

    address private _poolAccount;
    address private _otherAccount;

    function setUp() public {
        _evc = _codeAddress("evc");
        _middleware = _codeAddress("priceOracleMiddleware");

        _usdc = _codeAddress("usdc");
        _usdt = _codeAddress("usdt");
        _weth = _codeAddress("weth");
        _gold = _codeAddress("gold");

        _eulerVaultUsdc = _codeAddress("eulerVaultUsdc");
        _eulerVaultUsdt = _codeAddress("eulerVaultUsdt");
        _eulerVaultWeth = _codeAddress("eulerVaultWeth");

        _balanceFuse = new EulerV2BalanceFuse(_MARKET_ID, _evc);
        _plasmaVault = new PlasmaVaultMock(address(0), address(_balanceFuse));
        _plasmaVault.setPriceOracleMiddleware(_middleware);

        _poolAccount = EulerFuseLib.generateSubAccountAddress(address(_plasmaVault), _POOL_SUB_ACCOUNT);
        _otherAccount = EulerFuseLib.generateSubAccountAddress(address(_plasmaVault), _OTHER_SUB_ACCOUNT);

        _mockToken(_usdc, 6, _ONE_USD);
        _mockToken(_usdt, 6, _ONE_USD);
        _mockToken(_weth, 18, _WETH_PRICE_USD);
        _mockToken(_gold, 6, _GOLD_PRICE_USD);

        _mockEulerVaultAsset(_eulerVaultUsdc, _usdc);
        _mockEulerVaultAsset(_eulerVaultUsdt, _usdt);
        _mockEulerVaultAsset(_eulerVaultWeth, _weth);

        _mockConfigFlags(_eulerVaultUsdc, 0);
        _mockConfigFlags(_eulerVaultUsdt, 0);
        _mockConfigFlags(_eulerVaultWeth, 0);
    }

    //******************************************************************************************************************
    //********************                    FAIR-POINT VALUATION                                  ********************
    //******************************************************************************************************************

    /// @notice rho = 1 (curve price = oracle price), reserves moved along the curve from the equilibrium to
    ///         (500, 1 750): the fair point is the equilibrium, so d = 500 + 1 750 - 2 000 = 250 USD. The sub-account
    ///         holds 4 000 USDC and 2 000 USDT of supply: 6 000 - 250 = 5 750 USD.
    function testShouldTakeDisplacementOfReservesShiftedAlongCurveOffSubAccountValue() external {
        // given
        IEulerV2Swap.DynamicParams memory params = _defaultCurve();
        _assertOnCurve(params, _SWAPPED_RESERVE0, _SWAPPED_RESERVE1);
        MockEulerV2SwapPoolState pool = _newPool(_usdc, _usdt, _poolAccount, params);
        pool.setReserves(_SWAPPED_RESERVE0, _SWAPPED_RESERVE1);
        _grantSubstrates(_poolSubAccountSubstrates(address(pool)));

        _mockPosition(_eulerVaultUsdc, _poolAccount, 3_900e6, 4_000e6, 0);
        _mockPosition(_eulerVaultUsdt, _poolAccount, 1_950e6, 2_000e6, 0);

        uint256 displacement = (uint256(_SWAPPED_RESERVE0) + _SWAPPED_RESERVE1 - 2 * _EQUILIBRIUM) * 1e12;
        assertEq(displacement, _SWAPPED_DISPLACEMENT, "d from the reserves and the equilibrium");

        // when
        uint256 balance = _plasmaVault.balanceOf();

        // then
        assertEq(balance, 6_000e18 - displacement, "v - d");
    }

    /// @notice A swap along the curve and a donation move the holdings of the sub-account and the pool reserves by
    ///         the same amounts: v and d move together and the result stays 2 000 USD. Without the pool entry the
    ///         same states show the overpayment of the base valuation: 2 000 -> 2 250 -> 2 350.
    function testShouldKeepSubAccountValueWhenSwapAndDonationMoveHoldingsAndReservesTogether() external {
        // given: equilibrium, the sub-account holds 1 000 USDC and 1 000 USDT
        MockEulerV2SwapPoolState pool = _newPool(_usdc, _usdt, _poolAccount, _defaultCurve());
        pool.setReserves(uint112(_EQUILIBRIUM), uint112(_EQUILIBRIUM));
        _grantSubstrates(_poolSubAccountSubstrates(address(pool)));
        _mockPosition(_eulerVaultUsdc, _poolAccount, 1_000e6, 1_000e6, 0);
        _mockPosition(_eulerVaultUsdt, _poolAccount, 1_000e6, 1_000e6, 0);

        assertEq(_plasmaVault.balanceOf(), 2_000e18, "equilibrium: d = 0");

        // when: a swap pays 500 USDC out for 750 USDT in
        pool.setReserves(_SWAPPED_RESERVE0, _SWAPPED_RESERVE1);
        _mockPosition(_eulerVaultUsdc, _poolAccount, 500e6, 500e6, 0);
        _mockPosition(_eulerVaultUsdt, _poolAccount, 1_750e6, 1_750e6, 0);

        // then
        assertEq(_plasmaVault.balanceOf(), 2_000e18, "swap: v + 250, d + 250");

        // when: a donation of 100 USDC (reserves above the curve)
        pool.setReserves(_SWAPPED_RESERVE0 + 100e6, _SWAPPED_RESERVE1);
        _mockPosition(_eulerVaultUsdc, _poolAccount, 600e6, 600e6, 0);

        // then
        assertEq(_plasmaVault.balanceOf(), 2_000e18, "donation: v + 100, d + 100");

        // and: the same state without the pool entry is the base valuation, which books the overpayment
        _grantSubstrates(_poolSubAccountRows());
        assertEq(_plasmaVault.balanceOf(), 2_350e18, "without the entry: 600 + 1 750");
    }

    /// @notice Just-in-time liquidity: the swap pays 500 USDC out of 300 USDC of supply and a 200 USDC borrow, and the
    ///         750 USDT in are deposited as collateral. Healthy debt keeps v linear: 1 300 before, 1 750 - 200 - 250 after.
    function testShouldKeepSubAccountValueWhenJitBorrowMovesHoldingsAndReservesTogether() external {
        // given
        MockEulerV2SwapPoolState pool = _newPool(_usdc, _usdt, _poolAccount, _defaultCurve());
        pool.setReserves(uint112(_EQUILIBRIUM), uint112(_EQUILIBRIUM));

        bytes32[] memory substrates = new bytes32[](3);
        substrates[0] = _substrate(_eulerVaultUsdc, false, true, _POOL_SUB_ACCOUNT);
        substrates[1] = _substrate(_eulerVaultUsdt, true, false, _POOL_SUB_ACCOUNT);
        substrates[2] = _poolEntry(address(pool), _POOL_SUB_ACCOUNT);
        _grantSubstrates(substrates);

        _mockCollaterals(_poolAccount, _one(_eulerVaultUsdt));
        _mockRecognized(_eulerVaultUsdc, _eulerVaultUsdt, true);
        _mockPosition(_eulerVaultUsdc, _poolAccount, 300e6, 300e6, 0);
        _mockPosition(_eulerVaultUsdt, _poolAccount, 1_000e6, 1_000e6, 0);

        assertEq(_plasmaVault.balanceOf(), 1_300e18, "before the swap");

        // when
        pool.setReserves(_SWAPPED_RESERVE0, _SWAPPED_RESERVE1);
        _mockPosition(_eulerVaultUsdc, _poolAccount, 0, 0, 200e6);
        _mockPosition(_eulerVaultUsdt, _poolAccount, 1_750e6, 1_750e6, 0);

        // then
        assertEq(_plasmaVault.balanceOf(), 1_300e18, "after the swap: 1 750 - 200 - 250");
    }

    /// @notice rho = 1/4 on the asset0 side: GOLD costs 4 USD at the oracle and 1 USDT on the curve (c = 0). The value
    ///         4 x + f(x) is minimal where (x0 / x)^2 = 4, i.e. at (500, 2 000), worth 4 000 USD, while the equilibrium
    ///         reserves are worth 5 000 USD: d = 1 000. The point is checked against EulerSwapCurveReference: on the
    ///         curve, accepted by verify, both integer neighbours on the curve are more expensive.
    function testShouldValuePoolAtFairPointWhenCurvePriceOfAssetZeroIsBelowOracle() external {
        // given
        IEulerV2Swap.DynamicParams memory params = _curve(_EQUILIBRIUM, _EQUILIBRIUM, _CURVE_PRICE, _CURVE_PRICE, 0);
        uint256 fair0 = 500e6;
        uint256 fair1 = EulerSwapCurveReference.f(
            fair0,
            params.priceX,
            params.priceY,
            params.equilibriumReserve0,
            params.equilibriumReserve1,
            params.concentrationX
        );
        assertEq(fair1, 2_000e6, "f(500) = 1 000 + 1 000 * 500 / 500");
        _assertOnCurve(params, fair0, fair1);
        _assertCheapestOnAssetZeroSide(params, fair0, 4, 1);

        MockEulerV2SwapPoolState pool = _newPool(_gold, _usdt, _poolAccount, params);
        pool.setReserves(uint112(_EQUILIBRIUM), uint112(_EQUILIBRIUM));
        _grantSubstrates(_poolSubAccountSubstrates(address(pool)));
        _mockPosition(_eulerVaultUsdc, _poolAccount, 5_000e6, 5_000e6, 0);
        _mockPosition(_eulerVaultUsdt, _poolAccount, 0, 0, 0);

        uint256 displacement = (_EQUILIBRIUM * 4 + _EQUILIBRIUM) * 1e12 - (fair0 * 4 + fair1) * 1e12;
        assertEq(displacement, 1_000e18, "5 000 - 4 000");

        // when
        uint256 balance = _plasmaVault.balanceOf();

        // then
        assertEq(balance, 5_000e18 - displacement, "v - d at the fair point of the asset0 side");
    }

    /// @notice rho = 4 on the asset1 side with mixed decimals: USDC (6) / WETH (18), curve price 500 USDC per WETH
    ///         (px = 2e15, py = 1e6, c = 0), oracle 2 000 USD. The fair point is (15 000 USDC, 5 WETH), worth 25 000 USD;
    ///         the equilibrium (10 000 USDC, 10 WETH) is worth 30 000 USD: d = 5 000. Checked against
    ///         EulerSwapCurveReference like the asset0 case.
    function testShouldValuePoolAtFairPointWhenCurvePriceOfAssetOneIsBelowOracleWithMixedDecimals() external {
        // given
        IEulerV2Swap.DynamicParams memory params = _curve(10_000e6, 10e18, 2e15, 1e6, 0);
        uint256 fair1 = 5e18;
        uint256 fair0 = EulerSwapCurveReference.f(
            fair1,
            params.priceY,
            params.priceX,
            params.equilibriumReserve1,
            params.equilibriumReserve0,
            params.concentrationY
        );
        assertEq(fair0, 15_000e6, "f(5 WETH) = 10 000 USDC + 5 WETH at 500 USDC * 10 / 5");
        _assertOnCurve(params, fair0, fair1);
        _assertCheapestOnAssetOneSide(params, fair1);

        MockEulerV2SwapPoolState pool = _newPool(_usdc, _weth, _poolAccount, params);
        pool.setReserves(10_000e6, 10e18);
        _grantSubstrates(_poolSubAccountSubstrates(address(pool)));
        _mockPosition(_eulerVaultUsdc, _poolAccount, 20_000e6, 20_000e6, 0);
        _mockPosition(_eulerVaultUsdt, _poolAccount, 0, 0, 0);

        uint256 equilibriumValue = 10_000e6 * 1e12 + 10 * 2_000e18;
        uint256 fairValue = fair0 * 1e12 + (fair1 * 2_000e18) / 1e18;
        assertEq(equilibriumValue - fairValue, 5_000e18, "30 000 - 25 000");

        // when
        uint256 balance = _plasmaVault.balanceOf();

        // then
        assertEq(balance, 20_000e18 - (equilibriumValue - fairValue), "v - d at the fair point of the asset1 side");
    }

    //******************************************************************************************************************
    //********************                    FLOOR PER SUB-ACCOUNT                                 ********************
    //******************************************************************************************************************

    /// @notice d (250) above v (100 USDC) floors the pool sub-account at 0; the other sub-account (5 000 USDT) counts
    ///         in full.
    function testShouldFloorPoolSubAccountAtZeroNextToHealthySubAccount() external {
        // given
        MockEulerV2SwapPoolState pool = _newPool(_usdc, _usdt, _poolAccount, _defaultCurve());
        pool.setReserves(_SWAPPED_RESERVE0, _SWAPPED_RESERVE1);

        bytes32[] memory substrates = new bytes32[](4);
        substrates[0] = _substrate(_eulerVaultUsdc, false, false, _POOL_SUB_ACCOUNT);
        substrates[1] = _substrate(_eulerVaultUsdt, false, false, _POOL_SUB_ACCOUNT);
        substrates[2] = _poolEntry(address(pool), _POOL_SUB_ACCOUNT);
        substrates[3] = _substrate(_eulerVaultUsdt, false, false, _OTHER_SUB_ACCOUNT);
        _grantSubstrates(substrates);

        _mockPosition(_eulerVaultUsdc, _poolAccount, 100e6, 100e6, 0);
        _mockPosition(_eulerVaultUsdt, _poolAccount, 0, 0, 0);
        _mockPosition(_eulerVaultUsdt, _otherAccount, 5_000e6, 5_000e6, 0);

        // when
        uint256 balance = _plasmaVault.balanceOf();

        // then
        assertEq(balance, 5_000e18, "pool sub-account floored at 0, other sub-account in full");
    }

    /// @notice Only the pool sub-account, d above v: the market is 0 and does not revert.
    function testShouldReturnZeroWithoutRevertWhenOnlySubAccountIsBelowDisplacement() external {
        // given
        MockEulerV2SwapPoolState pool = _newPool(_usdc, _usdt, _poolAccount, _defaultCurve());
        pool.setReserves(_SWAPPED_RESERVE0, _SWAPPED_RESERVE1);
        _grantSubstrates(_poolSubAccountSubstrates(address(pool)));
        _mockPosition(_eulerVaultUsdc, _poolAccount, 100e6, 100e6, 0);
        _mockPosition(_eulerVaultUsdt, _poolAccount, 0, 0, 0);

        // when
        uint256 balance = _plasmaVault.balanceOf();

        // then
        assertEq(balance, 0, "max(0, 100 - 250)");
    }

    //******************************************************************************************************************
    //********************                    POOL ENTRIES THAT DO NOT COUNT                        ********************
    //******************************************************************************************************************

    /// @notice A pool entry granted before the deploy (no code at the address) is skipped without a call.
    function testShouldSkipPoolEntryWithoutCode() external {
        // given
        address undeployedPool = makeAddr("undeployedPool");
        _grantSubstrates(_poolSubAccountSubstrates(undeployedPool));
        _mockPosition(_eulerVaultUsdc, _poolAccount, 1_000e6, 1_000e6, 0);
        _mockPosition(_eulerVaultUsdt, _poolAccount, 500e6, 500e6, 0);

        // when
        uint256 balance = _plasmaVault.balanceOf();

        // then
        assertEq(balance, 1_500e18, "no code: no term");
    }

    /// @notice A pool that is not an EVC operator of the sub-account (uninstalled, e.g. after the deploy fuse exit) is
    ///         skipped and its reserves are not read.
    function testShouldSkipPoolThatIsNotOperatorOfSubAccount() external {
        // given
        MockEulerV2SwapPoolState pool = _newPool(_usdc, _usdt, _poolAccount, _defaultCurve());
        pool.setReserves(_SWAPPED_RESERVE0, _SWAPPED_RESERVE1);
        _mockOperator(_poolAccount, address(pool), false);
        _grantSubstrates(_poolSubAccountSubstrates(address(pool)));
        _mockPosition(_eulerVaultUsdc, _poolAccount, 500e6, 500e6, 0);
        _mockPosition(_eulerVaultUsdt, _poolAccount, 1_750e6, 1_750e6, 0);

        // then
        vm.expectCall(address(pool), abi.encodeWithSelector(IEulerV2Swap.getReserves.selector), 0);

        // when
        uint256 balance = _plasmaVault.balanceOf();

        // then
        assertEq(balance, 2_250e18, "not an operator: no term");
    }

    /// @notice A pool with a finite expiration counts until the expiration and is skipped from the expiration on (an
    ///         expired pool cannot swap; same boundary as the deploy fuse: expiration <= block.timestamp).
    function testShouldSkipExpiredPool() external {
        // given
        uint256 expiration = vm.getBlockTimestamp() + 1 days;
        IEulerV2Swap.DynamicParams memory params = _defaultCurve();
        params.expiration = uint40(expiration);
        MockEulerV2SwapPoolState pool = _newPool(_usdc, _usdt, _poolAccount, params);
        pool.setReserves(_SWAPPED_RESERVE0, _SWAPPED_RESERVE1);
        _grantSubstrates(_poolSubAccountSubstrates(address(pool)));
        _mockPosition(_eulerVaultUsdc, _poolAccount, 500e6, 500e6, 0);
        _mockPosition(_eulerVaultUsdt, _poolAccount, 1_750e6, 1_750e6, 0);

        assertEq(_plasmaVault.balanceOf(), 2_000e18, "live: 2 250 - 250");

        vm.warp(expiration - 1);
        assertEq(_plasmaVault.balanceOf(), 2_000e18, "one second before the expiration: still live");

        // when
        vm.warp(expiration);

        // then
        assertEq(_plasmaVault.balanceOf(), 2_250e18, "expired: no term");
    }

    /// @notice A pool entry whose pool runs on another account (`eulerAccount` is not the sub-account of the entry) is
    ///         skipped, even if the pool is also an operator of the entry's sub-account.
    function testShouldSkipPoolOfAnotherAccount() external {
        // given
        MockEulerV2SwapPoolState pool = _newPool(_usdc, _usdt, _otherAccount, _defaultCurve());
        pool.setReserves(_SWAPPED_RESERVE0, _SWAPPED_RESERVE1);
        _mockOperator(_poolAccount, address(pool), true);
        _grantSubstrates(_poolSubAccountSubstrates(address(pool)));
        _mockPosition(_eulerVaultUsdc, _poolAccount, 500e6, 500e6, 0);
        _mockPosition(_eulerVaultUsdt, _poolAccount, 1_750e6, 1_750e6, 0);

        // then
        vm.expectCall(address(pool), abi.encodeWithSelector(IEulerV2Swap.getReserves.selector), 0);

        // when
        uint256 balance = _plasmaVault.balanceOf();

        // then
        assertEq(balance, 2_250e18, "foreign pool: no term");
    }

    /// @notice A pool entry of a sub-account without any eVault row creates no sub-account and the pool is not called
    ///         at all (no ERC-4626 call on a pool entry): the market is the value of the other sub-account.
    function testShouldNotReadPoolEntryOfSubAccountWithoutRows() external {
        // given
        MockEulerV2SwapPoolState pool = _newPool(
            _usdc,
            _usdt,
            EulerFuseLib.generateSubAccountAddress(address(_plasmaVault), _EMPTY_SUB_ACCOUNT),
            _defaultCurve()
        );
        pool.setReserves(_SWAPPED_RESERVE0, _SWAPPED_RESERVE1);

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = _poolEntry(address(pool), _EMPTY_SUB_ACCOUNT);
        substrates[1] = _substrate(_eulerVaultUsdt, false, false, _OTHER_SUB_ACCOUNT);
        _grantSubstrates(substrates);
        _mockPosition(_eulerVaultUsdt, _otherAccount, 1_000e6, 1_000e6, 0);

        // then
        vm.expectCall(address(pool), bytes(""), 0);

        // when
        uint256 balance = _plasmaVault.balanceOf();

        // then
        assertEq(balance, 1_000e18, "pool entry alone is no position");
    }

    //******************************************************************************************************************
    //********************                    SEVERAL ENTRIES AND POOLS                             ********************
    //******************************************************************************************************************

    /// @notice The same pool and sub-account granted three times (plain, with flag bytes, with padding bits; all pool
    ///         entries) is counted once.
    function testShouldCountPoolGrantedSeveralTimesOnce() external {
        // given
        MockEulerV2SwapPoolState pool = _newPool(_usdc, _usdt, _poolAccount, _defaultCurve());
        pool.setReserves(_SWAPPED_RESERVE0, _SWAPPED_RESERVE1);

        bytes32 entry = _poolEntry(address(pool), _POOL_SUB_ACCOUNT);
        bytes32[] memory substrates = new bytes32[](5);
        substrates[0] = _substrate(_eulerVaultUsdc, false, false, _POOL_SUB_ACCOUNT);
        substrates[1] = _substrate(_eulerVaultUsdt, false, false, _POOL_SUB_ACCOUNT);
        substrates[2] = entry;
        substrates[3] = entry | bytes32((uint256(1) << 88) | (uint256(1) << 80));
        substrates[4] = entry | bytes32(uint256(0xff));
        _grantSubstrates(substrates);

        _mockPosition(_eulerVaultUsdc, _poolAccount, 4_000e6, 4_000e6, 0);
        _mockPosition(_eulerVaultUsdt, _poolAccount, 2_000e6, 2_000e6, 0);

        // when
        uint256 balance = _plasmaVault.balanceOf();

        // then
        assertEq(balance, 6_000e18 - _SWAPPED_DISPLACEMENT, "one pool, one term");
    }

    /// @notice Two live pools on one sub-account: both terms are taken off (250 for the swapped pool, 100 for a pool
    ///         with a 100 USDC donation above its equilibrium).
    function testShouldSumDisplacementOfTwoPoolsOnOneSubAccount() external {
        // given
        MockEulerV2SwapPoolState swappedPool = _newPool(_usdc, _usdt, _poolAccount, _defaultCurve());
        swappedPool.setReserves(_SWAPPED_RESERVE0, _SWAPPED_RESERVE1);
        MockEulerV2SwapPoolState donatedPool = _newPool(_usdc, _usdt, _poolAccount, _defaultCurve());
        donatedPool.setReserves(uint112(_EQUILIBRIUM + 100e6), uint112(_EQUILIBRIUM));

        bytes32[] memory substrates = new bytes32[](4);
        substrates[0] = _substrate(_eulerVaultUsdc, false, false, _POOL_SUB_ACCOUNT);
        substrates[1] = _poolEntry(address(swappedPool), _POOL_SUB_ACCOUNT);
        substrates[2] = _substrate(_eulerVaultUsdt, false, false, _POOL_SUB_ACCOUNT);
        substrates[3] = _poolEntry(address(donatedPool), _POOL_SUB_ACCOUNT);
        _grantSubstrates(substrates);

        _mockPosition(_eulerVaultUsdc, _poolAccount, 5_000e6, 5_000e6, 0);
        _mockPosition(_eulerVaultUsdt, _poolAccount, 0, 0, 0);

        // when
        uint256 balance = _plasmaVault.balanceOf();

        // then
        assertEq(balance, 5_000e18 - _SWAPPED_DISPLACEMENT - 100e18, "5 000 - 250 - 100");
    }

    //******************************************************************************************************************
    //********************                    REVERTS                                               ********************
    //******************************************************************************************************************

    /// @notice A refresh in the middle of a swap (pool `getReserves` reverts `Locked()`) reverts with that selector:
    ///         the fuse does not catch it.
    function testShouldRevertWithLockedWhenPoolIsInTheMiddleOfSwap() external {
        // given
        MockEulerV2SwapPoolState pool = _newPool(_usdc, _usdt, _poolAccount, _defaultCurve());
        pool.setReserves(_SWAPPED_RESERVE0, _SWAPPED_RESERVE1);
        pool.setLocked(true);
        _grantSubstrates(_poolSubAccountSubstrates(address(pool)));
        _mockPosition(_eulerVaultUsdc, _poolAccount, 500e6, 500e6, 0);
        _mockPosition(_eulerVaultUsdt, _poolAccount, 1_750e6, 1_750e6, 0);

        // then
        vm.expectRevert(MockEulerV2SwapPoolState.Locked.selector);

        // when
        _plasmaVault.balanceOf();
    }

    /// @notice A zero oracle price of a pool asset reverts UnsupportedQuoteCurrencyFromOracle. The sub-account holds
    ///         nothing in the USDT eVault, so the revert can only come from the pool valuation.
    function testShouldRevertWhenOraclePriceOfPoolAssetIsZero() external {
        // given
        _mockToken(_usdt, 6, 0);
        MockEulerV2SwapPoolState pool = _newPool(_usdc, _usdt, _poolAccount, _defaultCurve());
        pool.setReserves(_SWAPPED_RESERVE0, _SWAPPED_RESERVE1);
        _grantSubstrates(_poolSubAccountSubstrates(address(pool)));
        _mockPosition(_eulerVaultUsdc, _poolAccount, 500e6, 500e6, 0);
        _mockPosition(_eulerVaultUsdt, _poolAccount, 0, 0, 0);

        // then
        vm.expectRevert(Errors.UnsupportedQuoteCurrencyFromOracle.selector);

        // when
        _plasmaVault.balanceOf();
    }

    //******************************************************************************************************************
    //********************                    WITH IL-9707 AND WITHOUT A POOL ENTRY                 ********************
    //******************************************************************************************************************

    /// @notice Pool on sub-account 0x00 next to the row (asset(), 0x00) of IL-9707: the vault's underlying is the WETH
    ///         eVault. Sub-account 0x00 holds 1 WETH (2 000, idle), 500 USDC and 1 750 USDT, the pool is swapped
    ///         (d = 250): 4 250 - 2 000 - 250 = 2 000 USD.
    function testShouldTakeIdleUnderlyingAndPoolDisplacementOffSubAccountZero() external {
        // given
        vm.mockCall(address(_plasmaVault), abi.encodeWithSelector(ERC4626.asset.selector), abi.encode(_eulerVaultWeth));
        MockEulerV2SwapPoolState pool = _newPool(_usdc, _usdt, address(_plasmaVault), _defaultCurve());
        pool.setReserves(_SWAPPED_RESERVE0, _SWAPPED_RESERVE1);

        bytes32[] memory substrates = new bytes32[](4);
        substrates[0] = _substrate(_eulerVaultWeth, false, false, _VAULT_SUB_ACCOUNT);
        substrates[1] = _substrate(_eulerVaultUsdc, false, false, _VAULT_SUB_ACCOUNT);
        substrates[2] = _substrate(_eulerVaultUsdt, false, false, _VAULT_SUB_ACCOUNT);
        substrates[3] = _poolEntry(address(pool), _VAULT_SUB_ACCOUNT);
        _grantSubstrates(substrates);

        _mockPosition(_eulerVaultWeth, address(_plasmaVault), 1e18, 1e18, 0);
        _mockPosition(_eulerVaultUsdc, address(_plasmaVault), 500e6, 500e6, 0);
        _mockPosition(_eulerVaultUsdt, address(_plasmaVault), 1_750e6, 1_750e6, 0);

        // when
        uint256 balance = _plasmaVault.balanceOf();

        // then
        assertEq(balance, 4_250e18 - 2_000e18 - _SWAPPED_DISPLACEMENT, "v - idle underlying - d");
    }

    /// @notice A market without a pool entry keeps the base numbers (control, passes on the base commit): plain supply
    ///         of 5 000 USDC on one sub-account, 1 WETH of collateral (2 000) and 500 USDC of debt on another:
    ///         5 000 + 1 500. No pool view and no EVC operator view is read.
    function testShouldKeepBaseValuationWithoutPoolEntry() external {
        // given
        bytes32[] memory substrates = new bytes32[](3);
        substrates[0] = _substrate(_eulerVaultUsdc, false, false, _POOL_SUB_ACCOUNT);
        substrates[1] = _substrate(_eulerVaultWeth, true, false, _OTHER_SUB_ACCOUNT);
        substrates[2] = _substrate(_eulerVaultUsdc, false, true, _OTHER_SUB_ACCOUNT);
        _grantSubstrates(substrates);

        _mockCollaterals(_otherAccount, _one(_eulerVaultWeth));
        _mockRecognized(_eulerVaultUsdc, _eulerVaultWeth, true);
        _mockPosition(_eulerVaultUsdc, _poolAccount, 5_000e6, 5_000e6, 0);
        _mockPosition(_eulerVaultWeth, _otherAccount, 1e18, 1e18, 0);
        _mockPosition(_eulerVaultUsdc, _otherAccount, 0, 0, 500e6);

        // then
        vm.expectCall(_evc, abi.encodeWithSelector(IEVC.isAccountOperatorAuthorized.selector), 0);

        // when
        uint256 balance = _plasmaVault.balanceOf();

        // then
        assertEq(balance, 6_500e18, "base valuation");
    }

    //******************************************************************************************************************
    //********************     LIMITATION: POOL LEG ON THE VAULT'S OWN UNDERLYING (0x00, CR #1)     ********************
    //******************************************************************************************************************

    /// @notice Pinned limitation (IL-9706 CR #1), NOT an invariance. The vault's `asset()` is the USDT eVault; the pool
    ///         on sub-account 0x00 (the vault address) has it as supply vault, so the USDT leg of the pool is the vault's
    ///         idle balance, which `totalAssets` counts outside market 11. Equilibrium: idle 1 000 USDT, 1 000 USDC
    ///         supplied, reserves 1 000 / 1 000. A donation of 300 USDT raises idle to 1 300 and the reserve to 1 300 (d =
    ///         300): v = 2 300 - 1 300 (IL-9707) = 1 000, v - d = 700, and idle + market = 2 000 as before. The pool term
    ///         offsets the idle rise only while d <= v.
    function testShouldOffsetIdleUnderlyingRiseOnSubAccountZeroWhileDisplacementIsBelowValue() external {
        // given
        MockEulerV2SwapPoolState pool = _newVaultUnderlyingPool();
        pool.setReserves(uint112(_EQUILIBRIUM), uint112(_EQUILIBRIUM));
        _mockPosition(_eulerVaultUsdc, address(_plasmaVault), 1_000e6, 1_000e6, 0);
        _mockPosition(_eulerVaultUsdt, address(_plasmaVault), 1_000e6, 1_000e6, 0);
        uint256 balanceBefore = _plasmaVault.balanceOf();
        assertEq(balanceBefore, 1_000e18, "equilibrium: 2 000 - 1 000 idle - 0");

        // when: a donation of 300 USDT is booked as input, the vault holds 1 300 USDT
        pool.setReserves(uint112(_EQUILIBRIUM), uint112(1_300e6));
        _mockPosition(_eulerVaultUsdt, address(_plasmaVault), 1_300e6, 1_300e6, 0);
        uint256 balanceAfter = _plasmaVault.balanceOf();

        // then
        assertEq(balanceAfter, 700e18, "2 300 - 1 300 - 300");
        assertEq(1_300e18 + balanceAfter, 1_000e18 + balanceBefore, "idle + market unchanged: offset while d <= v");
    }

    /// @notice The same pool and a donation of 1 500 USDT: idle 2 500, reserve 2 500, d = 1 500 above v = 2 500 - 2 500 +
    ///         1 000 = 1 000. `max(0, v - d)` floors the market at zero, the 500 of d the floor cannot take stays in
    ///         `totalAssets`: idle + market = 2 500 against 2 000 before. The reserve rise of the vault's own
    ///         underlying is not offset.
    function testShouldLeaveIdleUnderlyingRiseUnoffsetOnSubAccountZeroWhenDisplacementExceedsValue() external {
        // given
        MockEulerV2SwapPoolState pool = _newVaultUnderlyingPool();
        pool.setReserves(uint112(_EQUILIBRIUM), uint112(_EQUILIBRIUM));
        _mockPosition(_eulerVaultUsdc, address(_plasmaVault), 1_000e6, 1_000e6, 0);
        _mockPosition(_eulerVaultUsdt, address(_plasmaVault), 1_000e6, 1_000e6, 0);
        uint256 navBefore = 1_000e18 + _plasmaVault.balanceOf();
        assertEq(navBefore, 2_000e18, "idle 1 000 + market 1 000");

        // when
        pool.setReserves(uint112(_EQUILIBRIUM), uint112(2_500e6));
        _mockPosition(_eulerVaultUsdt, address(_plasmaVault), 2_500e6, 2_500e6, 0);
        uint256 balanceAfter = _plasmaVault.balanceOf();

        // then
        assertEq(balanceAfter, 0, "max(0, 1 000 - 1 500)");
        assertEq(2_500e18 + balanceAfter - navBefore, 500e18, "500 of the donation stays in NAV, not compensated");
    }

    /// @notice Boundary: the same pool and the same donation of 1 500 USDT on sub-account 0x01, where the USDT eVault is
    ///         an ordinary position and not the idle underlying: v = 1 000 + 2 500, d = 1 500, the market stays 2 000.
    function testShouldKeepValueWhenSamePoolRunsOnNonZeroSubAccountWithSameDonation() external {
        // given
        MockEulerV2SwapPoolState pool = _newPool(_usdc, _usdt, _poolAccount, _defaultCurve());
        pool.setReserves(uint112(_EQUILIBRIUM), uint112(_EQUILIBRIUM));
        vm.mockCall(address(_plasmaVault), abi.encodeWithSelector(ERC4626.asset.selector), abi.encode(_eulerVaultUsdt));
        _grantSubstrates(_poolSubAccountSubstrates(address(pool)));
        _mockPosition(_eulerVaultUsdc, _poolAccount, 1_000e6, 1_000e6, 0);
        _mockPosition(_eulerVaultUsdt, _poolAccount, 1_000e6, 1_000e6, 0);
        assertEq(_plasmaVault.balanceOf(), 2_000e18, "equilibrium");

        // when
        pool.setReserves(uint112(_EQUILIBRIUM), uint112(2_500e6));
        _mockPosition(_eulerVaultUsdt, _poolAccount, 2_500e6, 2_500e6, 0);

        // then
        assertEq(_plasmaVault.balanceOf(), 2_000e18, "v + 1 500, d + 1 500: unchanged");
    }

    /// @dev A live pool on sub-account 0x00 (the vault address, curve 1 000 / 1 000, prices 1:1, USDC / USDT) with the
    ///      vault's `asset()` mocked to the USDT eVault and rows (USDT eVault, 0x00), (USDC eVault, 0x00)
    function _newVaultUnderlyingPool() private returns (MockEulerV2SwapPoolState pool) {
        vm.mockCall(address(_plasmaVault), abi.encodeWithSelector(ERC4626.asset.selector), abi.encode(_eulerVaultUsdt));
        pool = _newPool(_usdc, _usdt, address(_plasmaVault), _defaultCurve());
        bytes32[] memory substrates = new bytes32[](3);
        substrates[0] = _substrate(_eulerVaultUsdt, false, false, _VAULT_SUB_ACCOUNT);
        substrates[1] = _substrate(_eulerVaultUsdc, false, false, _VAULT_SUB_ACCOUNT);
        substrates[2] = _poolEntry(address(pool), _VAULT_SUB_ACCOUNT);
        _grantSubstrates(substrates);
    }

    //******************************************************************************************************************
    //********************     LIMITATION: VIRTUAL RESERVES FAR ABOVE THE HOLDINGS (CR #2)           ********************
    //******************************************************************************************************************

    /// @notice Pinned limitation (IL-9706 CR #2). `d` comes from the virtual reserves and the curve parameters only, it
    ///         is not capped by what the sub-account can deliver. GOLD (4 USD at the oracle, 1 USDT on the curve, c = 0):
    ///         equilibrium reserves 1 000 / 1 000 are worth 5 000, the fair point (500, 2 000) 4 000, d = 1 000, although
    ///         the sub-account holds 5 000 USDC and no GOLD at all: the value is 4 000. When the operator is removed
    ///         (`exit` of the deploy fuse) the term is dropped and the value steps up by d to 5 000.
    function testShouldUnderstateValueByDisplacementOfVirtualReservesAndStepUpWhenOperatorIsRemoved() external {
        // given
        IEulerV2Swap.DynamicParams memory params = _curve(_EQUILIBRIUM, _EQUILIBRIUM, _CURVE_PRICE, _CURVE_PRICE, 0);
        MockEulerV2SwapPoolState pool = _newPool(_gold, _usdt, _poolAccount, params);
        pool.setReserves(uint112(_EQUILIBRIUM), uint112(_EQUILIBRIUM));
        _grantSubstrates(_poolSubAccountSubstrates(address(pool)));
        _mockPosition(_eulerVaultUsdc, _poolAccount, 5_000e6, 5_000e6, 0);
        _mockPosition(_eulerVaultUsdt, _poolAccount, 0, 0, 0);

        // when
        uint256 understated = _plasmaVault.balanceOf();
        _mockOperator(_poolAccount, address(pool), false);
        uint256 afterExit = _plasmaVault.balanceOf();

        // then
        assertEq(understated, 4_000e18, "5 000 USDC held, d = 1 000 of undelivered virtual GOLD reserve");
        assertEq(afterExit, 5_000e18, "operator removed: the term is dropped");
        assertEq(afterExit - understated, 1_000e18, "the value steps up by d at once");
    }

    //******************************************************************************************************************
    //********************     LIMITATION: SOCIALIZATION CHARGE OF ANOTHER UNDERWATER SUB-ACCOUNT    ********************
    //******************************************************************************************************************

    /// @notice Pinned limitation (plan criterion 6i, Codex review point 3), NOT an invariance. Sub-account 0x02 is
    ///         underwater (0.025 WETH = 50 USD of seizable collateral, 100 USDC of socializable debt in the USDC eVault
    ///         X); the healthy pool sub-account 0x01 supplies X (100 of 1 000 shares) and 900 USDT. A donation of
    ///         1 000 USDC to the pool raises the vault's shares in X to 1 100 and X's supply to 2 000, and the pool
    ///         reserves by 1 000: v - d of the pool sub-account stays 1 000, but the socialization charge of 0x02 moves
    ///         from 100 * 100 / 1 000 = 10 to 100 * 1 100 / 2 000 = 55, so the market drops by 45 (990 -> 945); taking
    ///         the donation back out restores 990. The charge belongs to the IL-9528 valuation and its denominator also
    ///         moves with third-party deposits in X; it is documented and left to an operational rule, not resolved.
    function testShouldPinSocializationChargeMoveWhenPoolSuppliesControllerOfUnderwaterSubAccount() external {
        // given
        MockEulerV2SwapPoolState pool = _newPool(_usdc, _usdt, _poolAccount, _defaultCurve());
        pool.setReserves(uint112(_EQUILIBRIUM), uint112(_EQUILIBRIUM));

        bytes32[] memory poolOnly = _poolSubAccountSubstrates(address(pool));
        bytes32[] memory substrates = new bytes32[](5);
        substrates[0] = poolOnly[0];
        substrates[1] = poolOnly[1];
        substrates[2] = poolOnly[2];
        substrates[3] = _substrate(_eulerVaultWeth, true, false, _OTHER_SUB_ACCOUNT);
        substrates[4] = _substrate(_eulerVaultUsdc, false, true, _OTHER_SUB_ACCOUNT);
        _grantSubstrates(substrates);

        _mockCollaterals(_otherAccount, _one(_eulerVaultWeth));
        _mockRecognized(_eulerVaultUsdc, _eulerVaultWeth, true);
        _mockPosition(_eulerVaultWeth, _otherAccount, 0.025e18, 0.025e18, 0);
        _mockPosition(_eulerVaultUsdc, _otherAccount, 0, 0, 100e6);
        _mockPosition(_eulerVaultUsdc, _poolAccount, 100e6, 100e6, 0);
        _mockPosition(_eulerVaultUsdt, _poolAccount, 900e6, 900e6, 0);
        _mockTotalSupply(_eulerVaultUsdc, 1_000e6);

        assertEq(_plasmaVault.balanceOf(), 990e18, "before: pool sub-account 1 000, charge 10");

        // when: donation of 1 000 USDC to the pool, deposited into X on the pool sub-account
        pool.setReserves(uint112(_EQUILIBRIUM + 1_000e6), uint112(_EQUILIBRIUM));
        _mockPosition(_eulerVaultUsdc, _poolAccount, 1_100e6, 1_100e6, 0);
        _mockTotalSupply(_eulerVaultUsdc, 2_000e6);

        // then
        assertEq(_plasmaVault.balanceOf(), 945e18, "after the donation: pool sub-account 1 000, charge 55");

        _grantSubstrates(poolOnly);
        assertEq(_plasmaVault.balanceOf(), 1_000e18, "pool sub-account alone after the donation: v - d unchanged");
        _grantSubstrates(substrates);

        // when: the surplus is taken back out
        pool.setReserves(uint112(_EQUILIBRIUM), uint112(_EQUILIBRIUM));
        _mockPosition(_eulerVaultUsdc, _poolAccount, 100e6, 100e6, 0);
        _mockTotalSupply(_eulerVaultUsdc, 1_000e6);

        // then
        assertEq(_plasmaVault.balanceOf(), 990e18, "after the reversal: back to 990");

        _grantSubstrates(poolOnly);
        assertEq(_plasmaVault.balanceOf(), 1_000e18, "pool sub-account alone after the reversal");
    }

    //******************************************************************************************************************
    //********************                              HELPERS                                     ********************
    //******************************************************************************************************************

    /// @dev Equilibrium 1 000 / 1 000, curve prices 1:1, concentration 0.5, no fee, no expiration
    function _defaultCurve() private pure returns (IEulerV2Swap.DynamicParams memory) {
        return _curve(_EQUILIBRIUM, _EQUILIBRIUM, _CURVE_PRICE, _CURVE_PRICE, _HALF_CONCENTRATION);
    }

    function _curve(
        uint256 equilibrium0_,
        uint256 equilibrium1_,
        uint256 priceX_,
        uint256 priceY_,
        uint256 concentration_
    ) private pure returns (IEulerV2Swap.DynamicParams memory params) {
        params.equilibriumReserve0 = uint112(equilibrium0_);
        params.equilibriumReserve1 = uint112(equilibrium1_);
        params.priceX = uint80(priceX_);
        params.priceY = uint80(priceY_);
        params.concentrationX = uint64(concentration_);
        params.concentrationY = uint64(concentration_);
    }

    /// @dev A live pool: deployed, `eulerAccount_` as its account, an EVC operator of `eulerAccount_`
    function _newPool(
        address asset0_,
        address asset1_,
        address eulerAccount_,
        IEulerV2Swap.DynamicParams memory params_
    ) private returns (MockEulerV2SwapPoolState pool) {
        pool = new MockEulerV2SwapPoolState(asset0_, asset1_, eulerAccount_);
        pool.setDynamicParams(params_);
        _mockOperator(eulerAccount_, address(pool), true);
    }

    /// @dev Pool entry encoded by hand (bit 64 = pool entry, sub-account byte at bit 72), so the file compiles on the
    ///      base commit, which has no pool encoder
    function _poolEntry(address pool_, bytes1 subAccount_) private pure returns (bytes32) {
        return bytes32((uint256(uint160(pool_)) << 96) | (uint256(uint8(subAccount_)) << 72) | (uint256(1) << 64));
    }

    /// @dev Pool sub-account: plain supply rows in the USDC and USDT eVaults and the pool entry
    function _poolSubAccountSubstrates(address pool_) private view returns (bytes32[] memory substrates) {
        substrates = new bytes32[](3);
        substrates[0] = _substrate(_eulerVaultUsdc, false, false, _POOL_SUB_ACCOUNT);
        substrates[1] = _substrate(_eulerVaultUsdt, false, false, _POOL_SUB_ACCOUNT);
        substrates[2] = _poolEntry(pool_, _POOL_SUB_ACCOUNT);
    }

    function _poolSubAccountRows() private view returns (bytes32[] memory substrates) {
        substrates = new bytes32[](2);
        substrates[0] = _substrate(_eulerVaultUsdc, false, false, _POOL_SUB_ACCOUNT);
        substrates[1] = _substrate(_eulerVaultUsdt, false, false, _POOL_SUB_ACCOUNT);
    }

    function _substrate(
        address eulerVault_,
        bool isCollateral_,
        bool canBorrow_,
        bytes1 subAccount_
    ) private pure returns (bytes32) {
        return
            EulerFuseLib.substrateToBytes32(
                EulerSubstrate({
                    eulerVault: eulerVault_,
                    isCollateral: isCollateral_,
                    canBorrow: canBorrow_,
                    subAccounts: subAccount_
                })
            );
    }

    function _grantSubstrates(bytes32[] memory substrates_) private {
        _plasmaVault.grantMarketSubstrates(_MARKET_ID, substrates_);
    }

    /// @dev (r0, r1) is on the curve: accepted by the reference `verify`, one unit less of asset1 is not
    function _assertOnCurve(
        IEulerV2Swap.DynamicParams memory params_,
        uint256 reserve0_,
        uint256 reserve1_
    ) private pure {
        assertTrue(EulerSwapCurveReference.verify(params_, reserve0_, reserve1_), "point accepted by verify");
        assertFalse(EulerSwapCurveReference.verify(params_, reserve0_, reserve1_ - 1), "point is on the curve");
    }

    /// @dev Both integer neighbours of `fair0_` on the asset0 side of the reference curve are more expensive at the
    ///      oracle prices (in units of one base unit of asset1: asset0 costs `price0_`, asset1 `price1_`)
    function _assertCheapestOnAssetZeroSide(
        IEulerV2Swap.DynamicParams memory params_,
        uint256 fair0_,
        uint256 price0_,
        uint256 price1_
    ) private pure {
        uint256 fairValue = fair0_ * price0_ + _referenceCurve0(params_, fair0_) * price1_;
        assertGt((fair0_ - 1) * price0_ + _referenceCurve0(params_, fair0_ - 1) * price1_, fairValue, "x - 1");
        assertGt((fair0_ + 1) * price0_ + _referenceCurve0(params_, fair0_ + 1) * price1_, fairValue, "x + 1");
    }

    /// @dev Both integer neighbours of `fair1_` on the asset1 side (USDC 6 / WETH 18 at 1 / 2 000 USD) are more
    ///      expensive, in units of 1e-18 USD
    function _assertCheapestOnAssetOneSide(IEulerV2Swap.DynamicParams memory params_, uint256 fair1_) private pure {
        uint256 fairValue = _referenceCurve1(params_, fair1_) * 1e12 + fair1_ * 2_000;
        assertGt(_referenceCurve1(params_, fair1_ - 1) * 1e12 + (fair1_ - 1) * 2_000, fairValue, "y - 1");
        assertGt(_referenceCurve1(params_, fair1_ + 1) * 1e12 + (fair1_ + 1) * 2_000, fairValue, "y + 1");
    }

    function _referenceCurve0(IEulerV2Swap.DynamicParams memory params_, uint256 x_) private pure returns (uint256) {
        return
            EulerSwapCurveReference.f(
                x_,
                params_.priceX,
                params_.priceY,
                params_.equilibriumReserve0,
                params_.equilibriumReserve1,
                params_.concentrationX
            );
    }

    function _referenceCurve1(IEulerV2Swap.DynamicParams memory params_, uint256 y_) private pure returns (uint256) {
        return
            EulerSwapCurveReference.f(
                y_,
                params_.priceY,
                params_.priceX,
                params_.equilibriumReserve1,
                params_.equilibriumReserve0,
                params_.concentrationY
            );
    }

    function _codeAddress(string memory name_) private returns (address account) {
        account = makeAddr(name_);
        vm.etch(account, hex"00");
    }

    function _mockToken(address token_, uint8 decimals_, uint256 priceUsd_) private {
        vm.mockCall(token_, abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(decimals_));
        vm.mockCall(
            _middleware,
            abi.encodeWithSelector(IPriceOracleMiddleware.getAssetPrice.selector, token_),
            abi.encode(priceUsd_, _PRICE_DECIMALS)
        );
    }

    function _mockEulerVaultAsset(address eulerVault_, address asset_) private {
        vm.mockCall(eulerVault_, abi.encodeWithSelector(ERC4626.asset.selector), abi.encode(asset_));
    }

    function _mockPosition(
        address eulerVault_,
        address account_,
        uint256 shares_,
        uint256 assets_,
        uint256 debt_
    ) private {
        vm.mockCall(eulerVault_, abi.encodeWithSelector(IERC20.balanceOf.selector, account_), abi.encode(shares_));
        if (shares_ > 0) {
            vm.mockCall(
                eulerVault_,
                abi.encodeWithSelector(ERC4626.convertToAssets.selector, shares_),
                abi.encode(assets_)
            );
        }
        vm.mockCall(eulerVault_, abi.encodeWithSelector(IBorrowing.debtOf.selector, account_), abi.encode(debt_));
    }

    function _mockOperator(address account_, address operator_, bool authorized_) private {
        vm.mockCall(
            _evc,
            abi.encodeWithSelector(IEVC.isAccountOperatorAuthorized.selector, account_, operator_),
            abi.encode(authorized_)
        );
    }

    function _mockCollaterals(address account_, address[] memory collaterals_) private {
        vm.mockCall(_evc, abi.encodeWithSelector(IEVC.getCollaterals.selector, account_), abi.encode(collaterals_));
    }

    /// @dev Whether `controller_` recognizes `collateral_` (EVK: LTV configured, targetTimestamp != 0)
    function _mockRecognized(address controller_, address collateral_, bool recognized_) private {
        vm.mockCall(
            controller_,
            abi.encodeWithSelector(IEulerV2VaultGovernance.LTVFull.selector, collateral_),
            abi.encode(uint16(8_500), uint16(9_000), uint16(9_000), uint48(recognized_ ? 1 : 0), uint32(0))
        );
    }

    function _mockConfigFlags(address eulerVault_, uint32 flags_) private {
        vm.mockCall(
            eulerVault_,
            abi.encodeWithSelector(IEulerV2VaultGovernance.configFlags.selector),
            abi.encode(flags_)
        );
    }

    function _mockTotalSupply(address eulerVault_, uint256 totalSupply_) private {
        vm.mockCall(eulerVault_, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(totalSupply_));
    }

    function _one(address a_) private pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a_;
    }
}
