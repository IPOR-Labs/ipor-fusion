// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {VaultSparkMock} from "./VaultSparkMock.sol";
import {IporPriceOracle} from "../../../contracts/priceOracle/IporPriceOracle.sol";
import {SDaiPriceFeed} from "../../../contracts/priceOracle/priceFeed/SDaiPriceFeed.sol";

import {SparkBalanceFuse} from "../../../contracts/fuses/spark/SparkBalanceFuse.sol";
import {SparkSupplyFuse, SparkSupplyFuseEnterData, SparkSupplyFuseExitData} from "../../../contracts/fuses/spark/SparkSupplyFuse.sol";
import {ISavingsDai} from "../../../contracts/fuses/spark/ext/ISavingsDai.sol";

contract SparkSupplyFuseTest is Test {
    address private constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address private constant SDAI = 0x83F20F44975D03b1b09e64809B757c47f942BEeA;
    address public constant OWNER = 0xD92E9F039E4189c342b4067CC61f5d063960D248;

    IporPriceOracle private iporPriceOracleProxy;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19538857);
        IporPriceOracle implementation = new IporPriceOracle(
            0x0000000000000000000000000000000000000348,
            8,
            0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf
        );

        iporPriceOracleProxy = IporPriceOracle(
            address(new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", OWNER)))
        );

        SDaiPriceFeed priceFeed = new SDaiPriceFeed();
        address[] memory assets = new address[](1);
        address[] memory sources = new address[](1);
        assets[0] = SDAI;
        sources[0] = address(priceFeed);

        vm.prank(OWNER);
        iporPriceOracleProxy.setAssetSources(assets, sources);
    }

    function testShouldBeAbleToSupplyDaiToSpark() external {
        // given
        // sDAI/DAI

        SparkBalanceFuse balanceFuse = new SparkBalanceFuse(1, address(iporPriceOracleProxy));
        SparkSupplyFuse fuse = new SparkSupplyFuse(1);
        VaultSparkMock vaultMock = new VaultSparkMock(address(fuse), address(balanceFuse));

        uint256 amount = 100e18;

        deal(DAI, address(vaultMock), 1_000e18);

        uint256 balanceBefore = ERC20(DAI).balanceOf(address(vaultMock));
        uint256 balanceSDAIBefore = ISavingsDai(SDAI).balanceOf(address(vaultMock));
        uint256 balanceFromBalanceFuseBefore = vaultMock.balanceOf(address(vaultMock));

        // when
        vaultMock.enter(SparkSupplyFuseEnterData({amount: amount}));

        // then
        uint256 balanceAfter = ERC20(DAI).balanceOf(address(vaultMock));
        uint256 balanceSDAIAfter = ISavingsDai(SDAI).balanceOf(address(vaultMock));
        uint256 balanceFromBalanceFuseAfter = vaultMock.balanceOf(address(vaultMock));

        assertEq(balanceBefore, 1_000e18, "vault balance should be 1_000e18");
        assertEq(balanceAfter, 900e18, "vault balance should be 900e18");
        assertEq(balanceSDAIBefore, 0, "sDAI balance should be 0");
        assertEq(balanceSDAIAfter, 93731561573799055444, "sDAI balance should be 93731561573799055444");
        assertEq(balanceFromBalanceFuseBefore, 0, "balance should be 0");
        assertEq(balanceFromBalanceFuseAfter, 100042570414709200292, "balance should be 100042570414709200292");
    }

    function testShouldBeAbleToWithdrawSDaiFormSpark() external {
        // given
        // sDAI/DAI

        SparkBalanceFuse balanceFuse = new SparkBalanceFuse(1, address(iporPriceOracleProxy));
        SparkSupplyFuse fuse = new SparkSupplyFuse(1);
        VaultSparkMock vaultMock = new VaultSparkMock(address(fuse), address(balanceFuse));

        uint256 amount = 100e18;

        deal(DAI, address(vaultMock), 1_000e18);

        vaultMock.enter(SparkSupplyFuseEnterData({amount: amount}));

        uint256 balanceBefore = ERC20(DAI).balanceOf(address(vaultMock));
        uint256 balanceSDAIBefore = ISavingsDai(SDAI).balanceOf(address(vaultMock));
        uint256 balanceFromBalanceFuseBefore = vaultMock.balanceOf(address(vaultMock));

        // when
        vaultMock.exit(SparkSupplyFuseExitData({amount: ISavingsDai(SDAI).convertToAssets(balanceSDAIBefore)}));

        // then
        uint256 balanceAfter = ERC20(DAI).balanceOf(address(vaultMock));
        uint256 balanceSDAIAfter = ISavingsDai(SDAI).balanceOf(address(vaultMock));
        uint256 balanceFromBalanceFuseAfter = vaultMock.balanceOf(address(vaultMock));

        assertEq(balanceBefore, 900e18, "vault balance should be 900e18");
        assertEq(balanceAfter, 999999999999999999999, "vault balance should be 999999999999999999999");
        assertEq(balanceSDAIBefore, 93731561573799055444, "sDAI balance should be 93731561573799055444");
        assertEq(balanceSDAIAfter, 0, "sDAI balance should be 0");
        assertEq(balanceFromBalanceFuseBefore, 100042570414709200292, "balance should be 100042570414709200292");
        assertEq(balanceFromBalanceFuseAfter, 0, "balance should be 0");
    }
}
