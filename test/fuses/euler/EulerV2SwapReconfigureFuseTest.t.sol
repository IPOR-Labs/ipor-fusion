// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {
    EulerV2SwapReconfigureFuse,
    EulerV2SwapReconfigureFuseEnterData
} from "../../../contracts/fuses/euler/EulerV2SwapReconfigureFuse.sol";
import {EulerFuseLib, EulerSubstrate} from "../../../contracts/fuses/euler/EulerFuseLib.sol";
import {IEulerV2Swap} from "../../../contracts/fuses/euler/ext/IEulerV2Swap.sol";
import {Errors} from "../../../contracts/libraries/errors/Errors.sol";

import {EulerV2SwapCurveLib} from "../../../contracts/fuses/euler/EulerV2SwapCurveLib.sol";

import {EulerV2SwapTestVault} from "./mocks/EulerV2SwapTestVault.sol";
import {MockEVC} from "./mocks/MockEVC.sol";
import {MockEulerV2SwapFactory} from "./mocks/MockEulerV2SwapFactory.sol";
import {MockEulerV2SwapPool} from "./mocks/MockEulerV2SwapPool.sol";
import {MockPriceOracleMiddlewareForEulerSwap} from "./mocks/MockPriceOracleMiddlewareForEulerSwap.sol";

/// @title EulerV2SwapReconfigureFuse Unit Tests
/// @notice Tests the reconfigure flow of the EulerV2SwapReconfigureFuse executed via delegatecall
///         from a PlasmaVault-like harness, routing the reconfigure call through the EVC.
contract EulerV2SwapReconfigureFuseTest is Test {
    uint256 public constant MARKET_ID = 11; // EULER_V2
    bytes1 public constant SUB_ACCOUNT = 0x01;
    uint256 public constant PRICE_DEVIATION_WAD = 1e16; // 1%

    EulerV2SwapReconfigureFuse public fuse;
    EulerV2SwapTestVault public harness;
    MockEVC public evc;
    MockEulerV2SwapFactory public factory;
    MockEulerV2SwapPool public pool;
    MockPriceOracleMiddlewareForEulerSwap public oracle;

    address public eulerAccount;

    address public supplyVault0 = address(0x5010);
    address public supplyVault1 = address(0x5011);
    address public borrowVault0 = address(0xB010);
    address public borrowVault1 = address(0xB011);

    address public asset0 = address(0xA0);
    address public asset1 = address(0xA1);

    event EulerV2SwapReconfigureFuseEnter(address version, address pool, address eulerAccount);

    function setUp() public {
        evc = new MockEVC();
        factory = new MockEulerV2SwapFactory();
        harness = new EulerV2SwapTestVault();
        fuse = new EulerV2SwapReconfigureFuse(MARKET_ID, address(evc), address(factory), PRICE_DEVIATION_WAD);

        // Under delegatecall, address(this) inside the fuse == harness.
        eulerAccount = EulerFuseLib.generateSubAccountAddress(address(harness), SUB_ACCOUNT);

        pool = new MockEulerV2SwapPool();
        _setPoolStaticParams(eulerAccount);

        _grantAllSubstrates();

        // Curve pricing guard wiring: supplyVault0/1 -> asset0/asset1 (mirrors EulerSwap.getAssets),
        // asset0/asset1 decimals, and an oracle quoting both at parity (1:1, both 18 decimals) so the
        // default fixture's priceX == priceY == 1e18 curve sits exactly at the oracle ratio.
        oracle = new MockPriceOracleMiddlewareForEulerSwap();
        harness.setPriceOracle(address(oracle));
        vm.mockCall(supplyVault0, abi.encodeWithSignature("asset()"), abi.encode(asset0));
        vm.mockCall(supplyVault1, abi.encodeWithSignature("asset()"), abi.encode(asset1));
        vm.mockCall(asset0, abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));
        vm.mockCall(asset1, abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));
        oracle.setAssetPrice(asset0, 1e18, 18);
        oracle.setAssetPrice(asset1, 1e18, 18);
    }

    // ============================================
    // Helpers
    // ============================================

    function _setPoolStaticParams(address eulerAccount_) internal {
        IEulerV2Swap.StaticParams memory sp;
        sp.supplyVault0 = supplyVault0;
        sp.supplyVault1 = supplyVault1;
        sp.borrowVault0 = borrowVault0;
        sp.borrowVault1 = borrowVault1;
        sp.eulerAccount = eulerAccount_;
        sp.feeRecipient = address(0);
        pool.setStaticParams(sp);
    }

    function _grantAllSubstrates() internal {
        bytes32[] memory substrates = new bytes32[](4);
        substrates[0] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: supplyVault0, isCollateral: true, canBorrow: false, subAccounts: SUB_ACCOUNT})
        );
        substrates[1] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: supplyVault1, isCollateral: true, canBorrow: false, subAccounts: SUB_ACCOUNT})
        );
        substrates[2] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: borrowVault0, isCollateral: false, canBorrow: true, subAccounts: SUB_ACCOUNT})
        );
        substrates[3] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: borrowVault1, isCollateral: false, canBorrow: true, subAccounts: SUB_ACCOUNT})
        );
        harness.grantMarketSubstrates(MARKET_ID, substrates);
    }

    function _grantSubstrates(bytes32[] memory substrates) internal {
        harness.grantMarketSubstrates(MARKET_ID, substrates);
    }

    function _buildDynamicParams() internal pure returns (IEulerV2Swap.DynamicParams memory dp) {
        dp.equilibriumReserve0 = 1_000;
        dp.equilibriumReserve1 = 2_000;
        dp.minReserve0 = 10;
        dp.minReserve1 = 20;
        dp.priceX = 1e18;
        dp.priceY = 1e18;
        dp.concentrationX = 5e17;
        dp.concentrationY = 5e17;
        dp.fee0 = 1e15; // 0.1%, < 1e18
        dp.fee1 = 2e15; // 0.2%, < 1e18
        dp.expiration = 0; // no expiry
        dp.swapHookedOperations = 0;
        dp.swapHook = address(0);
    }

    function _buildEnterData() internal view returns (EulerV2SwapReconfigureFuseEnterData memory data) {
        // Pinned at the equilibrium reserves from _buildDynamicParams() (curve pricing guard, IL-8039):
        // reconfigure resets the live reserves to `initialState`, so an off-equilibrium point would be
        // the same bypass as an unpinned deploy.
        IEulerV2Swap.InitialState memory init;
        init.reserve0 = 1_000;
        init.reserve1 = 2_000;

        data = EulerV2SwapReconfigureFuseEnterData({
            pool: address(pool),
            subAccount: SUB_ACCOUNT,
            dynamicParams: _buildDynamicParams(),
            initialState: init
        });
    }

    function _enter(EulerV2SwapReconfigureFuseEnterData memory data) internal {
        harness.delegateExecute(address(fuse), abi.encodeCall(EulerV2SwapReconfigureFuse.enter, (data)));
    }

    /// @dev Invokes enter via the harness without decoding the return value, so `vm.expectRevert`
    ///      cleanly wraps the single reverting external call.
    function _enterExpectRevert(EulerV2SwapReconfigureFuseEnterData memory data) internal {
        harness.delegateExecute(address(fuse), abi.encodeCall(EulerV2SwapReconfigureFuse.enter, (data)));
    }

    // ============================================
    // Constructor
    // ============================================

    function test_constructorRevertsWhenEVCIsZero() public {
        vm.expectRevert(Errors.WrongAddress.selector);
        new EulerV2SwapReconfigureFuse(MARKET_ID, address(0), address(factory), PRICE_DEVIATION_WAD);
    }

    function test_constructorRevertsWhenFactoryIsZero() public {
        vm.expectRevert(Errors.WrongAddress.selector);
        new EulerV2SwapReconfigureFuse(MARKET_ID, address(evc), address(0), PRICE_DEVIATION_WAD);
    }

    function test_constructorRevertsWhenPriceDeviationAbove100Percent() public {
        vm.expectRevert(
            abi.encodeWithSelector(EulerV2SwapCurveLib.EulerV2SwapPriceDeviationTooHigh.selector, 1e18 + 1)
        );
        new EulerV2SwapReconfigureFuse(MARKET_ID, address(evc), address(factory), 1e18 + 1);
    }

    function test_constructorSetsImmutables() public view {
        assertEq(fuse.VERSION(), address(fuse), "VERSION");
        assertEq(fuse.MARKET_ID(), MARKET_ID, "MARKET_ID");
        assertEq(address(fuse.EVC()), address(evc), "EVC");
        assertEq(address(fuse.FACTORY()), address(factory), "FACTORY");
        assertEq(fuse.PRICE_DEVIATION_WAD(), PRICE_DEVIATION_WAD, "PRICE_DEVIATION_WAD");
    }

    // ============================================
    // Enter - happy path
    // ============================================

    function test_enterHappyPath() public {
        EulerV2SwapReconfigureFuseEnterData memory data = _buildEnterData();

        vm.expectEmit(true, true, true, true);
        emit EulerV2SwapReconfigureFuseEnter(address(fuse), address(pool), eulerAccount);

        _enter(data);

        assertEq(pool.reconfigureCallCount(), 1, "reconfigure called once");
        assertTrue(pool.reconfigured(), "reconfigured flag set");

        IEulerV2Swap.DynamicParams memory dp = pool.getDynamicParams();
        assertEq(dp.fee0, data.dynamicParams.fee0, "fee0 stored");
        assertEq(dp.fee1, data.dynamicParams.fee1, "fee1 stored");

        assertEq(evc.callCount(), 1, "EVC.call invoked once");
        assertEq(evc.lastOnBehalfOfAccount(), eulerAccount, "EVC onBehalfOf eulerAccount");
        assertEq(evc.lastCallTarget(), address(pool), "EVC target is pool");
        assertEq(evc.lastCallValue(), 0, "EVC call value zero");
    }

    /// @dev A future (non-zero) expiration must be accepted, not just expiration == 0.
    function test_enterAcceptsFutureExpiration() public {
        vm.warp(1_000_000);
        EulerV2SwapReconfigureFuseEnterData memory data = _buildEnterData();
        data.dynamicParams.expiration = uint40(block.timestamp + 1 days);

        _enter(data);

        assertEq(pool.reconfigureCallCount(), 1, "reconfigure called once for future expiration");
    }

    // ============================================
    // Enter - reverts: unknown pool
    // ============================================

    function test_enterRevertsUnknownPool() public {
        factory.setDeployedPoolsResult(false);

        EulerV2SwapReconfigureFuseEnterData memory data = _buildEnterData();

        vm.expectRevert(
            abi.encodeWithSelector(
                EulerV2SwapReconfigureFuse.EulerV2SwapReconfigureFuseUnknownPool.selector,
                address(pool)
            )
        );
        _enterExpectRevert(data);
    }

    // ============================================
    // Enter - reverts: owner
    // ============================================

    function test_enterRevertsInvalidOwner() public {
        address wrong = address(0xDEAD);
        _setPoolStaticParams(wrong);

        EulerV2SwapReconfigureFuseEnterData memory data = _buildEnterData();

        vm.expectRevert(
            abi.encodeWithSelector(
                EulerV2SwapReconfigureFuse.EulerV2SwapReconfigureFuseInvalidOwner.selector,
                address(pool),
                eulerAccount
            )
        );
        _enterExpectRevert(data);
    }

    // ============================================
    // Enter - reverts: unsupported vault
    // ============================================

    function test_enterRevertsUnsupportedSupplyVault() public {
        // Grant everything except supplyVault0.
        bytes32[] memory substrates = new bytes32[](3);
        substrates[0] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: supplyVault1, isCollateral: true, canBorrow: false, subAccounts: SUB_ACCOUNT})
        );
        substrates[1] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: borrowVault0, isCollateral: false, canBorrow: true, subAccounts: SUB_ACCOUNT})
        );
        substrates[2] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: borrowVault1, isCollateral: false, canBorrow: true, subAccounts: SUB_ACCOUNT})
        );
        _grantSubstrates(substrates);

        EulerV2SwapReconfigureFuseEnterData memory data = _buildEnterData();

        vm.expectRevert(
            abi.encodeWithSelector(
                EulerV2SwapReconfigureFuse.EulerV2SwapReconfigureFuseUnsupportedVault.selector,
                supplyVault0,
                SUB_ACCOUNT
            )
        );
        _enterExpectRevert(data);
    }

    function test_enterRevertsUnsupportedBorrowVault() public {
        // Grant borrowVault0 WITHOUT the canBorrow flag, proving the borrow branch.
        bytes32[] memory substrates = new bytes32[](4);
        substrates[0] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: supplyVault0, isCollateral: true, canBorrow: false, subAccounts: SUB_ACCOUNT})
        );
        substrates[1] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: supplyVault1, isCollateral: true, canBorrow: false, subAccounts: SUB_ACCOUNT})
        );
        substrates[2] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: borrowVault0, isCollateral: false, canBorrow: false, subAccounts: SUB_ACCOUNT})
        );
        substrates[3] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: borrowVault1, isCollateral: false, canBorrow: true, subAccounts: SUB_ACCOUNT})
        );
        _grantSubstrates(substrates);

        EulerV2SwapReconfigureFuseEnterData memory data = _buildEnterData();

        vm.expectRevert(
            abi.encodeWithSelector(
                EulerV2SwapReconfigureFuse.EulerV2SwapReconfigureFuseUnsupportedVault.selector,
                borrowVault0,
                SUB_ACCOUNT
            )
        );
        _enterExpectRevert(data);
    }

    /// @dev Grants supply substrates with the given collateral flags plus both borrow substrates.
    function _grantWithCollateralFlags(bool collateral0, bool collateral1) internal {
        bytes32[] memory substrates = new bytes32[](4);
        substrates[0] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({
                eulerVault: supplyVault0,
                isCollateral: collateral0,
                canBorrow: false,
                subAccounts: SUB_ACCOUNT
            })
        );
        substrates[1] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({
                eulerVault: supplyVault1,
                isCollateral: collateral1,
                canBorrow: false,
                subAccounts: SUB_ACCOUNT
            })
        );
        substrates[2] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: borrowVault0, isCollateral: false, canBorrow: true, subAccounts: SUB_ACCOUNT})
        );
        substrates[3] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: borrowVault1, isCollateral: false, canBorrow: true, subAccounts: SUB_ACCOUNT})
        );
        _grantSubstrates(substrates);
    }

    // ============================================
    // Enter - reverts: collateral flag required where the pool enables collateral (IL-8758)
    // ============================================

    /// @dev EulerSwapManagement.activate enables supplyVault0 as collateral iff borrowVault1 != 0, which
    ///      bypasses EulerV2CollateralFuse, so isCollateral=false on supplyVault0 must be rejected.
    function test_enterRevertsSupplyVault0NotCollateralWhenBorrowVault1Set() public {
        _grantWithCollateralFlags(false, true);

        EulerV2SwapReconfigureFuseEnterData memory data = _buildEnterData();

        vm.expectRevert(
            abi.encodeWithSelector(
                EulerV2SwapReconfigureFuse.EulerV2SwapReconfigureFuseUnsupportedVault.selector,
                supplyVault0,
                SUB_ACCOUNT
            )
        );
        _enterExpectRevert(data);
    }

    /// @dev Positive: collateral flags present on both supply vaults, reconfigure passes.
    function test_enterAcceptsCollateralFlagsPresent() public {
        _grantWithCollateralFlags(true, true);

        _enter(_buildEnterData());

        assertEq(pool.reconfigureCallCount(), 1, "reconfigure called once");
    }

    /// @dev Positive one-sided pool (only borrowVault0): supplyVault0 may be a plain supply substrate.
    function test_enterAcceptsOneSidedPoolWithoutCollateralOnUnusedSide() public {
        IEulerV2Swap.StaticParams memory sp = pool.getStaticParams();
        sp.borrowVault1 = address(0);
        pool.setStaticParams(sp);
        _grantWithCollateralFlags(false, true);

        _enter(_buildEnterData());

        assertEq(pool.reconfigureCallCount(), 1, "reconfigure called once");
    }

    /// @dev Mirror: supplyVault1 is enabled as collateral iff borrowVault0 != 0.
    function test_enterRevertsSupplyVault1NotCollateralWhenBorrowVault0Set() public {
        _grantWithCollateralFlags(true, false);

        EulerV2SwapReconfigureFuseEnterData memory data = _buildEnterData();

        vm.expectRevert(
            abi.encodeWithSelector(
                EulerV2SwapReconfigureFuse.EulerV2SwapReconfigureFuseUnsupportedVault.selector,
                supplyVault1,
                SUB_ACCOUNT
            )
        );
        _enterExpectRevert(data);
    }

    // ============================================
    // Enter - reverts: invalid params
    // ============================================

    function test_enterRevertsInvalidParamsFee0TooHigh() public {
        EulerV2SwapReconfigureFuseEnterData memory data = _buildEnterData();
        data.dynamicParams.fee0 = uint64(1e18); // >= MAX_FEE

        vm.expectRevert(EulerV2SwapReconfigureFuse.EulerV2SwapReconfigureFuseInvalidParams.selector);
        _enterExpectRevert(data);
    }

    function test_enterRevertsInvalidParamsFee1TooHigh() public {
        EulerV2SwapReconfigureFuseEnterData memory data = _buildEnterData();
        data.dynamicParams.fee1 = uint64(1e18); // >= MAX_FEE

        vm.expectRevert(EulerV2SwapReconfigureFuse.EulerV2SwapReconfigureFuseInvalidParams.selector);
        _enterExpectRevert(data);
    }

    function test_enterRevertsInvalidParamsExpirationInPast() public {
        vm.warp(1_000_000); // ensure block.timestamp > 1
        EulerV2SwapReconfigureFuseEnterData memory data = _buildEnterData();
        data.dynamicParams.expiration = uint40(block.timestamp - 1);

        vm.expectRevert(EulerV2SwapReconfigureFuse.EulerV2SwapReconfigureFuseInvalidParams.selector);
        _enterExpectRevert(data);
    }

    function test_enterRevertsInvalidParamsSwapHookSet() public {
        EulerV2SwapReconfigureFuseEnterData memory data = _buildEnterData();
        data.dynamicParams.swapHook = address(0xBEEF);

        vm.expectRevert(EulerV2SwapReconfigureFuse.EulerV2SwapReconfigureFuseInvalidParams.selector);
        _enterExpectRevert(data);
    }

    function test_enterRevertsInvalidParamsSwapHookedOperationsSet() public {
        EulerV2SwapReconfigureFuseEnterData memory data = _buildEnterData();
        data.dynamicParams.swapHookedOperations = 1;

        vm.expectRevert(EulerV2SwapReconfigureFuse.EulerV2SwapReconfigureFuseInvalidParams.selector);
        _enterExpectRevert(data);
    }

    // ============================================
    // Enter - reverts: curve pricing guard (IL-8039)
    // ============================================

    function test_enterRevertsCurvePriceAboveOracleBand() public {
        EulerV2SwapReconfigureFuseEnterData memory data = _buildEnterData();
        data.dynamicParams.priceX = uint80(1.02e18); // oracle ratio is 1:1, band is 1%

        vm.expectRevert(
            abi.encodeWithSelector(
                EulerV2SwapCurveLib.EulerV2SwapCurvePriceOutOfBounds.selector,
                uint256(1.02e18),
                PRICE_DEVIATION_WAD
            )
        );
        _enterExpectRevert(data);
        assertEq(pool.reconfigureCallCount(), 0, "reconfigure must not be called");
    }

    function test_enterRevertsCurvePriceBelowOracleBand() public {
        EulerV2SwapReconfigureFuseEnterData memory data = _buildEnterData();
        data.dynamicParams.priceX = uint80(0.98e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                EulerV2SwapCurveLib.EulerV2SwapCurvePriceOutOfBounds.selector,
                uint256(0.98e18),
                PRICE_DEVIATION_WAD
            )
        );
        _enterExpectRevert(data);
        assertEq(pool.reconfigureCallCount(), 0, "reconfigure must not be called");
    }

    /// @dev Boundary/positive control: the band is inclusive at +-1%. This passes both before and after
    ///      the fix (the guard did not exist before) and merely guards against an off-by-one at the edges.
    function test_enterAcceptsCurvePriceAtBandEdges() public {
        EulerV2SwapReconfigureFuseEnterData memory dataHigh = _buildEnterData();
        dataHigh.dynamicParams.priceX = uint80(1.01e18);
        _enter(dataHigh);

        EulerV2SwapReconfigureFuseEnterData memory dataLow = _buildEnterData();
        dataLow.dynamicParams.priceX = uint80(0.99e18);
        _enter(dataLow);

        assertEq(pool.reconfigureCallCount(), 2, "reconfigure called twice");
    }

    function test_enterRevertsCurvePriceZero() public {
        EulerV2SwapReconfigureFuseEnterData memory data = _buildEnterData();
        data.dynamicParams.priceX = 0;

        vm.expectRevert(
            abi.encodeWithSelector(
                EulerV2SwapCurveLib.EulerV2SwapCurvePriceOutOfBounds.selector,
                uint256(0),
                PRICE_DEVIATION_WAD
            )
        );
        _enterExpectRevert(data);
        assertEq(pool.reconfigureCallCount(), 0, "reconfigure must not be called");
    }

    /// @dev priceX/priceY embeds 10^(dec1-dec0): a USDC(6)/WETH(18) pool at 1 WETH = 2000 USDC needs
    ///      priceX/priceY = 1e18 / (2000 * 1e6) = 5e8. The raw 1:1 ratio (which would be correct for two
    ///      18-decimal assets) must be rejected once decimals differ.
    function test_enterUsesDecimalsNormalisedRatio() public {
        vm.mockCall(asset0, abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
        vm.mockCall(asset1, abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));
        oracle.setAssetPrice(asset0, 1e18, 18); // 1 USD
        oracle.setAssetPrice(asset1, 2000e18, 18); // 2000 USD

        // priceX/priceY = 5e18 / 1e10 = 5e8, matching 1e18 / (2000 * 1e6). Scaled to keep both values
        // well within uint80's ~1.2089e24 range (the ratio, not the absolute scale, is what matters).
        EulerV2SwapReconfigureFuseEnterData memory consistent = _buildEnterData();
        consistent.dynamicParams.priceX = uint80(5e18);
        consistent.dynamicParams.priceY = uint80(1e10);
        _enter(consistent);
        assertEq(pool.reconfigureCallCount(), 1, "decimals-normalised ratio accepted");

        EulerV2SwapReconfigureFuseEnterData memory raw = _buildEnterData();
        raw.dynamicParams.priceX = uint80(1e18);
        raw.dynamicParams.priceY = uint80(1e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                EulerV2SwapCurveLib.EulerV2SwapCurvePriceOutOfBounds.selector,
                uint256(2e9),
                PRICE_DEVIATION_WAD
            )
        );
        _enterExpectRevert(raw);
    }

    function test_enterRevertsInitialStateNotAtEquilibriumReserve0() public {
        EulerV2SwapReconfigureFuseEnterData memory data = _buildEnterData();
        data.initialState.reserve0 = uint112(data.dynamicParams.equilibriumReserve0) - 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                EulerV2SwapCurveLib.EulerV2SwapInitialStateNotAtEquilibrium.selector,
                data.initialState.reserve0,
                data.initialState.reserve1,
                data.dynamicParams.equilibriumReserve0,
                data.dynamicParams.equilibriumReserve1
            )
        );
        _enterExpectRevert(data);
        assertEq(pool.reconfigureCallCount(), 0, "reconfigure must not be called");
    }

    function test_enterRevertsInitialStateNotAtEquilibriumReserve1() public {
        EulerV2SwapReconfigureFuseEnterData memory data = _buildEnterData();
        data.initialState.reserve1 = uint112(data.dynamicParams.equilibriumReserve1) - 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                EulerV2SwapCurveLib.EulerV2SwapInitialStateNotAtEquilibrium.selector,
                data.initialState.reserve0,
                data.initialState.reserve1,
                data.dynamicParams.equilibriumReserve0,
                data.dynamicParams.equilibriumReserve1
            )
        );
        _enterExpectRevert(data);
        assertEq(pool.reconfigureCallCount(), 0, "reconfigure must not be called");
    }

    function test_enterRevertsWhenOraclePriceZero() public {
        oracle.setAssetPrice(asset1, 0, 18);

        EulerV2SwapReconfigureFuseEnterData memory data = _buildEnterData();

        vm.expectRevert(abi.encodeWithSelector(EulerV2SwapCurveLib.EulerV2SwapUnsupportedOraclePrice.selector, asset1));
        _enterExpectRevert(data);
        assertEq(pool.reconfigureCallCount(), 0, "reconfigure must not be called");
    }

    function test_enterRevertsCurveGuardBeforeEvcCall() public {
        EulerV2SwapReconfigureFuseEnterData memory data = _buildEnterData();
        data.dynamicParams.priceX = uint80(1.02e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                EulerV2SwapCurveLib.EulerV2SwapCurvePriceOutOfBounds.selector,
                uint256(1.02e18),
                PRICE_DEVIATION_WAD
            )
        );
        _enterExpectRevert(data);

        assertEq(evc.callCount(), 0, "EVC.call must not run before the curve guard");
        assertEq(pool.reconfigureCallCount(), 0, "reconfigure must not run before the curve guard");
    }

    // ============================================
    // Exit
    // ============================================

    function test_exitRevertsUnsupportedOperation() public {
        vm.expectRevert(EulerV2SwapReconfigureFuse.UnsupportedOperation.selector);
        fuse.exit();
    }

    // ============================================
    // Transient entry point
    // ============================================

    /// @dev Split ABI-encoded bytes into 32-byte chunks for transient storage.
    function _toChunks(bytes memory enc) internal pure returns (bytes32[] memory chunks) {
        uint256 n = (enc.length + 31) / 32;
        chunks = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            bytes32 c;
            assembly {
                c := mload(add(enc, add(32, mul(i, 32))))
            }
            chunks[i] = c;
        }
    }

    function test_enterTransient() public {
        EulerV2SwapReconfigureFuseEnterData memory data = _buildEnterData();

        bytes32[] memory chunks = _toChunks(abi.encode(data));
        harness.setTransientInputs(address(fuse), chunks);

        vm.expectEmit(true, true, true, true);
        emit EulerV2SwapReconfigureFuseEnter(address(fuse), address(pool), eulerAccount);

        harness.delegateExecute(address(fuse), abi.encodeCall(EulerV2SwapReconfigureFuse.enterTransient, ()));

        assertEq(pool.reconfigureCallCount(), 1, "reconfigure called once");
        assertTrue(pool.reconfigured(), "reconfigured flag set");
        assertEq(evc.callCount(), 1, "EVC.call invoked once");
    }
}
