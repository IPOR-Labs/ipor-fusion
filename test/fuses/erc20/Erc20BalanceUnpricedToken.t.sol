// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {IPriceOracleMiddleware} from "../../../contracts/price_oracle/IPriceOracleMiddleware.sol";
import {Erc20BalanceArbitrumTest} from "./Erc20BalanceArbitrum.t.sol";

/// @dev Same vault setup as Erc20BalanceArbitrumTest (granted: USDC = underlying, DAI, USDT), on its own fork block.
///      DAI plays the granted token without a price: its middleware price read is made to revert.
contract Erc20BalanceUnpricedTokenTest is Erc20BalanceArbitrumTest {
    address private constant TOKEN_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant TOKEN_USDT = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
    address private constant TOKEN_DAI = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;

    function setUp() public override {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 226213815);
        init();
    }

    function _mockDaiPriceReverts() private {
        vm.mockCallRevert(
            priceOracle,
            abi.encodeWithSelector(IPriceOracleMiddleware.getAssetPrice.selector, TOKEN_DAI),
            abi.encodeWithSignature("UnsupportedAsset()")
        );
    }

    function _refreshErc20Market() private returns (uint256) {
        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.ERC20_VAULT_BALANCE;
        vm.mockCall(
            accessManager,
            abi.encodeWithSignature(
                "canCall(address,address,bytes4)",
                alpha,
                plasmaVault,
                PlasmaVault.updateMarketsBalances.selector
            ),
            abi.encode(true, uint32(0))
        );
        vm.prank(alpha);
        PlasmaVault(plasmaVault).updateMarketsBalances(marketIds);
        return PlasmaVault(plasmaVault).totalAssetsInMarket(IporFusionMarkets.ERC20_VAULT_BALANCE);
    }

    function testShouldRefreshErc20MarketWhenUnpricedTokenHasZeroBalance() external {
        // given
        deal(TOKEN_USDT, plasmaVault, 100e6);
        _mockDaiPriceReverts();

        // when
        uint256 assetsInErc20 = _refreshErc20Market();

        // then
        assertApproxEqAbs(assetsInErc20, 100e6, 1e5, "only the priced USDT balance is counted");
    }

    function testShouldRevertWhenUnpricedTokenIsHeld() external {
        // given
        deal(TOKEN_USDT, plasmaVault, 100e6);
        deal(TOKEN_DAI, plasmaVault, 1);
        _mockDaiPriceReverts();

        // when / then
        vm.expectRevert(abi.encodeWithSignature("UnsupportedAsset()"));
        _refreshErc20Market();
    }

    function testShouldSkipUnderlyingWhenCountingErc20Market() external {
        // given
        deal(TOKEN_USDC, plasmaVault, 1_000e6);
        deal(TOKEN_DAI, plasmaVault, 100e18);

        // when
        uint256 assetsInErc20 = _refreshErc20Market();

        // then
        assertApproxEqAbs(assetsInErc20, 100e6, 1e5, "underlying is not counted, only DAI is");
    }
}
