// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {AaveV4SubstrateLib} from "../../../contracts/fuses/aave_v4/AaveV4SubstrateLib.sol";
import {AaveV4ForkTestBase} from "./AaveV4ForkTestBase.sol";

/// @title AaveV4BalanceFuseSpokeFloorForkTest
/// @notice IL-9552: the live Bluechip spoke with an underwater account. WETH is the collateral, USDC the debt and
///         wstETH a supply that is not enabled as collateral; a healthy Main spoke position sits next to it.
///         After a WETH price fall the Bluechip spoke is valued at its non-collateral supply only (F), the
///         non-collateral supply is still withdrawable below health factor 1, and a real liquidation does not lift
///         the market value above rounding.
/// @dev Both price sources are repriced with `vm.mockCall` (the Spoke feed of the WETH reserve and the vault's
///      PriceOracleMiddleware). `liquidationCall` is called by signature, there is no interface for it in the repo.
///      No `vm.warp`: the fork base shares one block, so the Spoke interest index does not move.
contract AaveV4BalanceFuseSpokeFloorForkTest is AaveV4ForkTestBase {
    /// @dev Chainlink-style feed behind the Bluechip WETH reserve (`ORACLE().getReserveSource(0)`)
    address private constant SPOKE_WETH_FEED = 0x5424384B256154046E9667dDFaaa5e550145215e;

    uint256 private constant BLUECHIP_WETH_SUPPLY = 10e18;
    uint256 private constant BLUECHIP_USDC_DEBT = 15_000e6;
    uint256 private constant BLUECHIP_WSTETH_SUPPLY = 5e18;
    uint256 private constant MAIN_WETH_SUPPLY = 5e18;

    /// @dev WETH falls to 25% of its price: collateral (about 5.8k USD) is far below the 15k USD debt
    uint256 private constant PRICE_PERCENT_AFTER_FALL = 25;

    address private liquidator = address(0x4141);

    function setUp() public override {
        super.setUp();

        deal(WSTETH, address(plasmaVault), BLUECHIP_WSTETH_SUPPLY);

        bytes32[] memory grants = new bytes32[](4);
        grants[0] = AaveV4SubstrateLib.encodeReserve(BLUECHIP_SPOKE, BLUECHIP_WETH, true, false);
        grants[1] = AaveV4SubstrateLib.encodeReserve(BLUECHIP_SPOKE, BLUECHIP_WSTETH, true, false);
        grants[2] = AaveV4SubstrateLib.encodeReserve(BLUECHIP_SPOKE, BLUECHIP_USDC_PRIME, false, true);
        grants[3] = AaveV4SubstrateLib.encodeReserve(MAIN_SPOKE, MAIN_WETH, true, false);
        _grantReserves(grants);

        // Bluechip: WETH collateral + USDC debt, then wstETH supplied and left out of the collateral set; Main: plain supply
        FuseAction[] memory actions = new FuseAction[](5);
        actions[0] = _supplyAction(BLUECHIP_SPOKE, WETH, BLUECHIP_WETH, BLUECHIP_WETH_SUPPLY, 0);
        actions[1] = _enableCollateralAction(BLUECHIP_SPOKE, BLUECHIP_WETH);
        actions[2] = _borrowAction(BLUECHIP_SPOKE, USDC, BLUECHIP_USDC_PRIME, BLUECHIP_USDC_DEBT, 0);
        actions[3] = _supplyAction(BLUECHIP_SPOKE, WSTETH, BLUECHIP_WSTETH, BLUECHIP_WSTETH_SUPPLY, 0);
        actions[4] = _supplyAction(MAIN_SPOKE, WETH, MAIN_WETH, MAIN_WETH_SUPPLY, 0);
        _execute(actions);
        _updateBalances();
    }

    function testShouldValueHealthySpokesAsNetBeforeTheFall() public view {
        // given - the fixture is what the scenario assumes
        (bool wethCollateral, ) = _status(BLUECHIP_SPOKE, BLUECHIP_WETH);
        (bool wstEthCollateral, ) = _status(BLUECHIP_SPOKE, BLUECHIP_WSTETH);
        assertTrue(wethCollateral, "WETH enabled as collateral");
        assertFalse(wstEthCollateral, "wstETH not enabled as collateral");
        assertGt(_healthFactor(BLUECHIP_SPOKE), 1e18, "healthy before the fall");

        // then - Bluechip: F + (C - D); Main: its supply
        assertApproxEqRel(_aaveMarketBalance(), _usdWadToUsdc(_bluechipValueWad() + _mainValueWad()), NAV_TOLERANCE);
    }

    function testShouldValueUnderwaterSpokeAtNonCollateralSupplyAfterPriceFall() public {
        // given
        uint256 navBefore = _aaveMarketBalance();

        // when
        _repriceWeth(PRICE_PERCENT_AFTER_FALL);
        assertLt(_healthFactor(BLUECHIP_SPOKE), 1e18, "Bluechip underwater");
        _updateBalances();

        // then - the underwater collateral contributes nothing: F (wstETH) + the healthy Main spoke
        uint256 expectedWad = _usdValueWad(WSTETH, _supplied(BLUECHIP_SPOKE, BLUECHIP_WSTETH)) + _mainValueWad();
        uint256 navAfter = _aaveMarketBalance();
        assertApproxEqRel(navAfter, _usdWadToUsdc(expectedWad), NAV_TOLERANCE, "F + Main");
        assertLt(navAfter, navBefore, "NAV fell with the collateral");
        // the old netted sum would have been lower still by the shortfall D - C
        uint256 shortfallUsdc = _usdWadToUsdc(
            _usdValueWad(USDC, _debt(BLUECHIP_SPOKE, BLUECHIP_USDC_PRIME)) -
                _usdValueWad(WETH, _supplied(BLUECHIP_SPOKE, BLUECHIP_WETH))
        );
        assertGt(shortfallUsdc, 1_000e6, "shortfall is material");
    }

    function testShouldExitNonCollateralSupplyBelowHealthFactorOne() public {
        // given
        _repriceWeth(PRICE_PERCENT_AFTER_FALL);
        assertLt(_healthFactor(BLUECHIP_SPOKE), 1e18, "Bluechip underwater");
        uint256 wstEthBefore = IERC20(WSTETH).balanceOf(address(plasmaVault));

        // when - ALPHA withdraws the supply that is not collateral
        _executeOne(_withdrawAction(BLUECHIP_SPOKE, WSTETH, BLUECHIP_WSTETH, BLUECHIP_WSTETH_SUPPLY / 2, 0));

        // then
        assertGt(IERC20(WSTETH).balanceOf(address(plasmaVault)), wstEthBefore, "wstETH withdrawn");
        assertApproxEqAbs(
            _supplied(BLUECHIP_SPOKE, BLUECHIP_WSTETH),
            BLUECHIP_WSTETH_SUPPLY / 2,
            2,
            "half of the supply left"
        );
    }

    function testShouldNotRaiseNavAfterLiquidationOfUnderwaterSpoke() public {
        // given
        _repriceWeth(PRICE_PERCENT_AFTER_FALL);
        _updateBalances();
        uint256 navBefore = _aaveMarketBalance();
        uint256 wstEthSupplyBefore = _supplied(BLUECHIP_SPOKE, BLUECHIP_WSTETH);
        uint256 debtBefore = _debt(BLUECHIP_SPOKE, BLUECHIP_USDC_PRIME);

        // when - a real liquidation: the liquidator repays the debt and seizes the WETH collateral
        deal(USDC, liquidator, 100_000e6);
        vm.startPrank(liquidator);
        IERC20(USDC).approve(BLUECHIP_SPOKE, type(uint256).max);
        IERC20(USDC).approve(PRIME_HUB, type(uint256).max);
        (bool ok, ) = BLUECHIP_SPOKE.call(
            abi.encodeWithSignature(
                "liquidationCall(uint256,uint256,address,uint256,bool)",
                BLUECHIP_WETH,
                BLUECHIP_USDC_PRIME,
                address(plasmaVault),
                type(uint256).max,
                false
            )
        );
        vm.stopPrank();
        assertTrue(ok, "liquidationCall succeeded");

        // then - the liquidation really changed the position
        assertLt(_supplied(BLUECHIP_SPOKE, BLUECHIP_WETH), BLUECHIP_WETH_SUPPLY / 2, "collateral seized");
        assertLt(_debt(BLUECHIP_SPOKE, BLUECHIP_USDC_PRIME), debtBefore, "debt repaid");

        // and - the refreshed market value does not step up beyond rounding
        _updateBalances();
        uint256 navAfter = _aaveMarketBalance();
        assertLe(navAfter, navBefore + 10, "no NAV step-up from the liquidation");
        uint256 expectedWad = _usdValueWad(WSTETH, _supplied(BLUECHIP_SPOKE, BLUECHIP_WSTETH)) + _mainValueWad();
        assertApproxEqRel(navAfter, _usdWadToUsdc(expectedWad), NAV_TOLERANCE, "still F + Main");

        // the non-collateral supply was not seized (Hub deficit handling is observed in the IL-9552 notes)
        assertGe(_supplied(BLUECHIP_SPOKE, BLUECHIP_WSTETH), wstEthSupplyBefore - 2, "wstETH supply kept");
    }

    // ============ Helpers ============

    /// @dev Bluechip spoke value (WAD, middleware prices): wstETH supply + WETH supply - USDC debt, floored at zero
    ///      for the collateral part
    function _bluechipValueWad() private view returns (uint256) {
        uint256 free = _usdValueWad(WSTETH, _supplied(BLUECHIP_SPOKE, BLUECHIP_WSTETH));
        uint256 collateral = _usdValueWad(WETH, _supplied(BLUECHIP_SPOKE, BLUECHIP_WETH));
        uint256 debt = _usdValueWad(USDC, _debt(BLUECHIP_SPOKE, BLUECHIP_USDC_PRIME));
        return free + (collateral > debt ? collateral - debt : 0);
    }

    function _mainValueWad() private view returns (uint256) {
        return _usdValueWad(WETH, _supplied(MAIN_SPOKE, MAIN_WETH));
    }

    /// @dev Reprices WETH to `percent_` of the current price in the Spoke feed and in the vault's middleware
    function _repriceWeth(uint256 percent_) private {
        (bool ok, bytes memory answer) = SPOKE_WETH_FEED.staticcall(abi.encodeWithSignature("latestAnswer()"));
        assertTrue(ok, "feed readable");
        int256 spokePrice = abi.decode(answer, (int256));
        vm.mockCall(
            SPOKE_WETH_FEED,
            abi.encodeWithSignature("latestAnswer()"),
            abi.encode((spokePrice * int256(percent_)) / 100)
        );

        (uint256 price, uint256 priceDecimals) = _middlewareWethPrice();
        vm.mockCall(
            PRICE_ORACLE_MIDDLEWARE,
            abi.encodeWithSignature("getAssetPrice(address)", WETH),
            abi.encode((price * percent_) / 100, priceDecimals)
        );
    }

    function _middlewareWethPrice() private view returns (uint256 price, uint256 priceDecimals) {
        (bool ok, bytes memory answer) = PRICE_ORACLE_MIDDLEWARE.staticcall(
            abi.encodeWithSignature("getAssetPrice(address)", WETH)
        );
        require(ok, "middleware price");
        (price, priceDecimals) = abi.decode(answer, (uint256, uint256));
    }
}
