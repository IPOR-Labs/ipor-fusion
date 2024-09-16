// Tests for ERC4646BalanceFuse
// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Erc4626SupplyFuse, Erc4626SupplyFuseEnterData, Erc4626SupplyFuseExitData} from "./../../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {ERC4626BalanceFuse} from "./../../../contracts/fuses/erc4626/Erc4626BalanceFuse.sol";

import {PriceOracleMiddleware} from "./../../../contracts/price_oracle/PriceOracleMiddleware.sol";

import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";

contract ERC4646BalanceFuseTest is Test {
    address private constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address private constant SDAI = 0x83F20F44975D03b1b09e64809B757c47f942BEeA;

    PriceOracleMiddleware private priceOracleMiddlewareProxy;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19538857);
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf);
        priceOracleMiddlewareProxy = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );
        address[] memory assets = new address[](1);
        assets[0] = DAI;
    }

    function testShouldBeAbleToSupplyAndCalculateBalance() external {
        // given
        Erc4626SupplyFuse supplyFuse = new Erc4626SupplyFuse(1);
        ERC4626BalanceFuse balanceFuse = new ERC4626BalanceFuse(1);
        PlasmaVaultMock vault = new PlasmaVaultMock(address(supplyFuse), address(balanceFuse));
        vault.setPriceOracleMiddleware(address(priceOracleMiddlewareProxy));

        address[] memory assets = new address[](1);
        assets[0] = SDAI;
        vault.grantAssetsToMarket(supplyFuse.MARKET_ID(), assets);
        uint256 amount = 100e18;

        deal(DAI, address(vault), 1_000e18);

        uint256 balanceBefore = IERC4626(SDAI).balanceOf(address(vault));
        uint256 balanceFromFuseBefore = vault.balanceOf();

        // when
        vault.enterErc4626Supply(Erc4626SupplyFuseEnterData({vault: SDAI, vaultAssetAmount: amount}));

        //then
        uint256 balanceAfter = IERC4626(SDAI).balanceOf(address(vault));
        uint256 balanceFromFuseAfter = vault.balanceOf();

        assertEq(balanceBefore, 0, "Balance before should be 0");
        assertEq(balanceFromFuseBefore, 0, "Balance from fuse before should be 0");
        assertGt(balanceAfter, balanceBefore, "Balance should be greater after supply");
        assertGt(balanceFromFuseAfter, balanceFromFuseBefore, "Balance from fuse should be greater after supply");
        assertEq(balanceAfter, 93731561573799055444, "SDAI balance should be 93731561573799055444 after supply");
        assertEq(
            balanceFromFuseAfter,
            100042570999999999998,
            "Balance from fuse balance should be 100042570999999999999 after supply"
        );
    }

    function testShouldBeAbleToWithdrawAndCalculateBalance() external {
        // given
        Erc4626SupplyFuse supplyFuse = new Erc4626SupplyFuse(1);
        ERC4626BalanceFuse balanceFuse = new ERC4626BalanceFuse(1);
        PlasmaVaultMock vault = new PlasmaVaultMock(address(supplyFuse), address(balanceFuse));
        vault.setPriceOracleMiddleware(address(priceOracleMiddlewareProxy));

        address[] memory assets = new address[](1);
        assets[0] = SDAI;
        vault.grantAssetsToMarket(supplyFuse.MARKET_ID(), assets);
        uint256 amount = 100e18;

        deal(DAI, address(vault), 1_000e18);

        vault.enterErc4626Supply(Erc4626SupplyFuseEnterData({vault: SDAI, vaultAssetAmount: amount}));

        uint256 balanceBeforeWithdraw = IERC4626(SDAI).balanceOf(address(vault));
        uint256 balanceFromFuseBeforeWithdraw = vault.balanceOf();

        // when
        vault.exitErc4626Supply(
            Erc4626SupplyFuseExitData({
                vault: SDAI,
                vaultAssetAmount: IERC4626(SDAI).convertToAssets(balanceBeforeWithdraw)
            })
        );

        // then
        uint256 balanceAfterWithdraw = IERC4626(SDAI).balanceOf(address(vault));
        uint256 balanceFromFuseAfterWithdraw = vault.balanceOf();

        assertEq(
            balanceBeforeWithdraw,
            93731561573799055444,
            "SDAI balance should be 93731561573799055444 before withdraw"
        );
        assertEq(
            balanceFromFuseBeforeWithdraw,
            100042570999999999998,
            "Balance from fuse balance should be 100042570999999999999 before withdraw"
        );
        assertEq(balanceAfterWithdraw, 0, "SDAI balance should be 0 after withdraw");
        assertEq(balanceFromFuseAfterWithdraw, 0, "Balance from fuse balance should be 0 after withdraw");
    }
}
