// Tests for ERC4646BalanceFuse
// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Erc4626SupplyFuse} from "./../../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {ERC4626BalanceFuse} from "./../../../contracts/fuses/erc4626/Erc4626BalanceFuse.sol";
import {VaultERC4626Mock} from "./VaultERC4626Mock.sol";

import {IporPriceOracle} from "./../../../contracts/priceOracle/IporPriceOracle.sol";

contract ERC4646BalanceFuseTest is Test {
    address private constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address private constant SDAI = 0x83F20F44975D03b1b09e64809B757c47f942BEeA;

    IporPriceOracle private iporPriceOracleProxy;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19538857);
        IporPriceOracle implementation = new IporPriceOracle(
            0x0000000000000000000000000000000000000348,
            8,
            0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf
        );
        iporPriceOracleProxy = IporPriceOracle(
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
        ERC4626BalanceFuse balanceFuse = new ERC4626BalanceFuse(1, address(iporPriceOracleProxy));
        VaultERC4626Mock vault = new VaultERC4626Mock(address(supplyFuse), address(balanceFuse));

        address[] memory assets = new address[](1);
        assets[0] = SDAI;
        vault.grantAssetsToMarket(supplyFuse.MARKET_ID(), assets);
        uint256 amount = 100e18;

        deal(DAI, address(vault), 1_000e18);

        uint256 balanceBefore = IERC4626(SDAI).balanceOf(address(vault));
        uint256 balanceFromFuseBefore = vault.balanceOf(address(vault));

        // when
        vault.enter(Erc4626SupplyFuse.Erc4626SupplyFuseData({vault: SDAI, amount: amount}));

        //then
        uint256 balanceAfter = IERC4626(SDAI).balanceOf(address(vault));
        uint256 balanceFromFuseAfter = vault.balanceOf(address(vault));

        assertEq(balanceBefore, 0, "Balance before should be 0");
        assertEq(balanceFromFuseBefore, 0, "Balance from fuse before should be 0");
        assertGt(balanceAfter, balanceBefore, "Balance should be greater after supply");
        assertGt(balanceFromFuseAfter, balanceFromFuseBefore, "Balance from fuse should be greater after supply");
        assertEq(balanceAfter, 93731561573799055444, "SDAI balance should be 93731561573799055444 after supply");
        assertEq(
            balanceFromFuseAfter,
            100042570999999999999,
            "Balance from fuse balance should be 100042570999999999999 after supply"
        );
    }

    function testShouldBeAbleToWithdrawAndCalculateBalance() external {
        // given
        Erc4626SupplyFuse supplyFuse = new Erc4626SupplyFuse(1);
        ERC4626BalanceFuse balanceFuse = new ERC4626BalanceFuse(1, address(iporPriceOracleProxy));
        VaultERC4626Mock vault = new VaultERC4626Mock(address(supplyFuse), address(balanceFuse));

        address[] memory assets = new address[](1);
        assets[0] = SDAI;
        vault.grantAssetsToMarket(supplyFuse.MARKET_ID(), assets);
        uint256 amount = 100e18;

        deal(DAI, address(vault), 1_000e18);

        vault.enter(Erc4626SupplyFuse.Erc4626SupplyFuseData({vault: SDAI, amount: amount}));

        uint256 balanceBeforeWithdraw = IERC4626(SDAI).balanceOf(address(vault));
        uint256 balanceFromFuseBeforeWithdraw = vault.balanceOf(address(vault));

        // when
        vault.exit(
            Erc4626SupplyFuse.Erc4626SupplyFuseData({
                vault: SDAI,
                amount: IERC4626(SDAI).convertToAssets(balanceBeforeWithdraw)
            })
        );

        // then
        uint256 balanceAfterWithdraw = IERC4626(SDAI).balanceOf(address(vault));
        uint256 balanceFromFuseAfterWithdraw = vault.balanceOf(address(vault));

        assertEq(
            balanceBeforeWithdraw,
            93731561573799055444,
            "SDAI balance should be 93731561573799055444 before withdraw"
        );
        assertEq(
            balanceFromFuseBeforeWithdraw,
            100042570999999999999,
            "Balance from fuse balance should be 100042570999999999999 before withdraw"
        );
        assertEq(balanceAfterWithdraw, 0, "SDAI balance should be 0 after withdraw");
        assertEq(balanceFromFuseAfterWithdraw, 0, "Balance from fuse balance should be 0 after withdraw");
    }
}