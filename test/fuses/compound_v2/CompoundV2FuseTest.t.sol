// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {VaultCompoundV2Mock} from "./VaultCompoundV2Mock.sol";
import {PriceOracleMiddleware} from "../../../contracts/priceOracle/PriceOracleMiddleware.sol";
import {CompoundV2BalanceFuse} from "../../../contracts/fuses/compound_v2/CompoundV2BalanceFuse.sol";
import {CompoundV2SupplyFuse, CompoundV2SupplyFuseExitData, CompoundV2SupplyFuseEnterData} from "../../../contracts/fuses/compound_v2/CompoundV2SupplyFuse.sol";

contract SparkSupplyFuseTest is Test {
    address private constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address private constant CDAI = 0x5d3a536E4D6DbD6114cc1Ead35777bAB948E3643;
    address public constant OWNER = 0xD92E9F039E4189c342b4067CC61f5d063960D248;

    PriceOracleMiddleware private priceOracleMiddlewareProxy;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19538857);
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(
            0x0000000000000000000000000000000000000348,
            8,
            0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf
        );

        priceOracleMiddlewareProxy = PriceOracleMiddleware(
            address(new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", OWNER)))
        );
    }

    function testShouldBeAbleToSupplyDai() external {
        // given
        // sDAI/DAI

        CompoundV2BalanceFuse balanceFuse = new CompoundV2BalanceFuse(1, address(priceOracleMiddlewareProxy));
        CompoundV2SupplyFuse fuse = new CompoundV2SupplyFuse(1);
        VaultCompoundV2Mock vaultMock = new VaultCompoundV2Mock(address(fuse), address(balanceFuse));

        address[] memory assets = new address[](1);
        assets[0] = CDAI;

        vaultMock.grantAssetsToMarket(1, assets);

        uint256 amount = 100e18;

        deal(DAI, address(vaultMock), 1_000e18);

        uint256 balanceBefore = ERC20(DAI).balanceOf(address(vaultMock));
        uint256 balanceCDAIBefore = ERC20(CDAI).balanceOf(address(vaultMock));
        uint256 balanceFromBalanceFuseBefore = vaultMock.balanceOf(address(vaultMock));

        // when
        vaultMock.enter(CompoundV2SupplyFuseEnterData({asset: DAI, amount: amount}));

        // then
        uint256 balanceAfter = ERC20(DAI).balanceOf(address(vaultMock));
        uint256 balanceCDAIAfter = ERC20(CDAI).balanceOf(address(vaultMock));
        uint256 balanceFromBalanceFuseAfter = vaultMock.balanceOf(address(vaultMock));

        assertEq(balanceBefore, 1_000e18, "vault balance should be 1_000e18");
        assertEq(balanceAfter, 900e18, "vault balance should be 900e18");
        assertEq(balanceCDAIBefore, 0, "cDAI balance should be 0");
        assertEq(balanceCDAIAfter, 433859673319, "cDAI balance should be 433859673319");
        assertEq(balanceFromBalanceFuseBefore, 0, "balance should be 0");
        assertEq(balanceFromBalanceFuseAfter, 100042570999782587684, "balance should be 100042570414709200292");
    }

    function testShouldBeAbleToWithdrawDai() external {
        // given

        CompoundV2BalanceFuse balanceFuse = new CompoundV2BalanceFuse(1, address(priceOracleMiddlewareProxy));
        CompoundV2SupplyFuse fuse = new CompoundV2SupplyFuse(1);
        VaultCompoundV2Mock vaultMock = new VaultCompoundV2Mock(address(fuse), address(balanceFuse));

        address[] memory assets = new address[](1);
        assets[0] = CDAI;

        vaultMock.grantAssetsToMarket(1, assets);

        uint256 amount = 100e18;

        deal(DAI, address(vaultMock), 1_000e18);

        vaultMock.enter(CompoundV2SupplyFuseEnterData({asset: DAI, amount: amount}));

        uint256 balanceBefore = ERC20(DAI).balanceOf(address(vaultMock));
        uint256 balanceCDAIBefore = ERC20(CDAI).balanceOf(address(vaultMock));
        uint256 balanceFromBalanceFuseBefore = vaultMock.balanceOf(address(vaultMock));

        // when
        vaultMock.exit(CompoundV2SupplyFuseExitData({asset: DAI, amount: amount}));

        // then
        uint256 balanceAfter = ERC20(DAI).balanceOf(address(vaultMock));
        uint256 balanceCDAIAfter = ERC20(CDAI).balanceOf(address(vaultMock));
        uint256 balanceFromBalanceFuseAfter = vaultMock.balanceOf(address(vaultMock));

        assertEq(balanceBefore, 900e18, "vault balance should be 900e18");
        assertEq(balanceAfter, 999999999999782680199, "vault balance should be 999999999999782680199");
        assertEq(balanceCDAIBefore, 433859673319, "sDAI balance should be 433859673319");
        assertEq(balanceCDAIAfter, 1, "sDAI balance should be 1");
        assertEq(balanceFromBalanceFuseBefore, 100042570999782587684, "balance should be 100042570999782587684");
        assertEq(balanceFromBalanceFuseAfter, 230587393, "balance should be 230587393");
    }
}
