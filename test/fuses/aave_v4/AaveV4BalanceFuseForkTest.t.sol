// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {AaveV4SubstrateLib} from "../../../contracts/fuses/aave_v4/AaveV4SubstrateLib.sol";
import {AaveV4ForkTestBase} from "./AaveV4ForkTestBase.sol";

/// @title AaveV4BalanceFuseForkTest
/// @notice AaveV4BalanceFuse against the live Bluechip spoke: valuation of supply-only and leveraged
///         positions with the Fusion mainnet PriceOracleMiddleware, duplicate-grant de-duplication and the
///         documented behaviour for revoked grants.
contract AaveV4BalanceFuseForkTest is AaveV4ForkTestBase {
    uint256 private constant WETH_SUPPLY = 10e18;
    uint256 private constant USDC_BORROW = 10_000e6;

    function testShouldValueSupplyOnlyPositionAtOraclePrice() public {
        // given
        uint256 erc20Before = _erc20MarketBalance();
        assertEq(_aaveMarketBalance(), 0);

        // when
        _executeOne(_supplyAction(BLUECHIP_SPOKE, WETH, BLUECHIP_WETH, WETH_SUPPLY, 0));

        // then - value moved from the ERC20 market to the AAVE_V4 market at the same oracle price
        uint256 aaveAfter = _aaveMarketBalance();
        assertApproxEqAbs(aaveAfter, erc20Before - _erc20MarketBalance(), 1e4, "market transfer");

        uint256 expectedUsdc = _usdWadToUsdc(_usdValueWad(WETH, _supplied(BLUECHIP_SPOKE, BLUECHIP_WETH)));
        assertApproxEqRel(aaveAfter, expectedUsdc, NAV_TOLERANCE, "valued at oracle price");
    }

    function testShouldValueNetPositionWithDebt() public {
        // when
        _openPosition(WETH_SUPPLY, USDC_BORROW);

        // then - supplied WETH minus USDC debt
        uint256 expectedUsd = _usdValueWad(WETH, _supplied(BLUECHIP_SPOKE, BLUECHIP_WETH)) -
            _usdValueWad(USDC, _debt(BLUECHIP_SPOKE, BLUECHIP_USDC_PRIME));
        assertApproxEqRel(_aaveMarketBalance(), _usdWadToUsdc(expectedUsd), NAV_TOLERANCE, "net value");
    }

    function testShouldNotDoubleCountDuplicateGrantVariants() public {
        // given
        _executeOne(_supplyAction(BLUECHIP_SPOKE, WETH, BLUECHIP_WETH, WETH_SUPPLY, 0));
        uint256 before = _aaveMarketBalance();

        // when - the same reserve granted with three flag variants
        bytes32[] memory grants = new bytes32[](4);
        grants[0] = AaveV4SubstrateLib.encodeReserve(BLUECHIP_SPOKE, BLUECHIP_WETH, true, false);
        grants[1] = AaveV4SubstrateLib.encodeReserve(BLUECHIP_SPOKE, BLUECHIP_WETH, true, true);
        grants[2] = AaveV4SubstrateLib.encodeReserve(BLUECHIP_SPOKE, BLUECHIP_WETH, false, false);
        grants[3] = AaveV4SubstrateLib.encodeReserve(BLUECHIP_SPOKE, BLUECHIP_USDC_PRIME, false, true);
        _grantReserves(grants);
        _updateBalances();

        // then
        assertApproxEqAbs(_aaveMarketBalance(), before, 1, "counted once");
    }

    function testShouldCountDebtOnReserveGrantedWithoutCanBorrow() public {
        // given
        _openPosition(WETH_SUPPLY, USDC_BORROW);
        uint256 before = _aaveMarketBalance();

        // when - USDC downgraded to plain grant
        bytes32[] memory grants = new bytes32[](2);
        grants[0] = AaveV4SubstrateLib.encodeReserve(BLUECHIP_SPOKE, BLUECHIP_WETH, true, false);
        grants[1] = AaveV4SubstrateLib.encodeReserve(BLUECHIP_SPOKE, BLUECHIP_USDC_PRIME, false, false);
        _grantReserves(grants);
        _updateBalances();

        // then - debt still subtracted
        assertApproxEqAbs(_aaveMarketBalance(), before, 1e4, "debt counted regardless of canBorrow");
    }

    function testShouldTolerateGrantOfReserveIdNotListedYet() public {
        // given - Bluechip lists 11 reserves; the atomist pre-grants reserve 11
        _executeOne(_supplyAction(BLUECHIP_SPOKE, WETH, BLUECHIP_WETH, WETH_SUPPLY, 0));
        uint256 before = _aaveMarketBalance();

        bytes32[] memory grants = new bytes32[](2);
        grants[0] = AaveV4SubstrateLib.encodeReserve(BLUECHIP_SPOKE, BLUECHIP_WETH, true, false);
        grants[1] = AaveV4SubstrateLib.encodeReserve(BLUECHIP_SPOKE, 11, false, true);
        _grantReserves(grants);

        // when - balance update must not revert
        _updateBalances();

        // then
        assertApproxEqAbs(_aaveMarketBalance(), before, 1);
    }

    function testShouldHideRevokedReservePositionUntilRegranted() public {
        // given
        _executeOne(_supplyAction(BLUECHIP_SPOKE, WETH, BLUECHIP_WETH, WETH_SUPPLY, 0));
        uint256 totalAssetsBefore = plasmaVault.totalAssets();
        uint256 marketBefore = _aaveMarketBalance();

        // when - WETH grant removed entirely
        bytes32[] memory grants = new bytes32[](1);
        grants[0] = AaveV4SubstrateLib.encodeReserve(BLUECHIP_SPOKE, BLUECHIP_USDC_PRIME, false, true);
        _grantReserves(grants);
        _updateBalances();

        // then - documented: position invisible to NAV
        assertEq(_aaveMarketBalance(), 0, "revoked reserve not counted");
        assertApproxEqAbs(plasmaVault.totalAssets(), totalAssetsBefore - marketBefore, 1e4);

        // and restored after re-grant
        _grantReserves(_defaultGrants());
        _updateBalances();
        assertApproxEqAbs(_aaveMarketBalance(), marketBefore, 1e4, "restored");
        assertApproxEqRel(plasmaVault.totalAssets(), totalAssetsBefore, NAV_TOLERANCE);
    }
}
