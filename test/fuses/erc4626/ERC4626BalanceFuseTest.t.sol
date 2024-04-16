// Tests for ERC4646BalanceFuse
// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {console} from "./../../../lib/forge-std/src/console.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IApproveERC20} from "../../../contracts/fuses/IApproveERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC4626BalanceFuseMock} from "./ERC4626BalanceFuseMock.sol";
import {Erc4626SupplyFuse} from "./../../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {ERC4626SupplyFuseMock} from "./ERC4626SupplyFuseMock.sol";
// TODO check import below
import {VaultERC4626Mock} from "./VaultERC4626Mock.sol";
import {IporPriceOracle} from "./../../../contracts/priceOracle/IporPriceOracle.sol";
import {MarketConfigurationLib} from "./../../../contracts/libraries/MarketConfigurationLib.sol";

contract ERC4646BalanceFuseTest is Test {
    struct SupportedToken {
        address vault;
        string name;
    }

    IporPriceOracle private iporPriceOracleProxy;

    IERC4626 public constant sDAI = IERC4626(0x83F20F44975D03b1b09e64809B757c47f942BEeA);

    Erc4626SupplyFuse private marketSupply;
    ERC4626SupplyFuseMock private marketSupplyMock;
    ERC4626BalanceFuseMock private marketBalance;
    VaultERC4626Mock private vault;

    SupportedToken private activeTokens;

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
        marketSupply = new Erc4626SupplyFuse(1);
        marketSupplyMock = new ERC4626SupplyFuseMock(address(marketSupply));
        marketBalance = new ERC4626BalanceFuseMock(1, address(iporPriceOracleProxy));
        // vault = new VaultERC4626Mock(address(marketSupply));
        // activeTokens = SupportedToken({vault: address(vault), name: "mockVault"});
        activeTokens = SupportedToken({vault: address(sDAI), name: "sDAI"});
    }

    function testShouldBeAbleToSupplyAndCalculateBalance() external {
        // given
        address user = vm.rememberKey(123);
        uint256 decimals = sDAI.decimals();
        uint256 amount = 100 * 10 ** decimals;

        deal(activeTokens.vault, user, 1_000 * 10 ** decimals);

        address[] memory assets = new address[](1);
        assets[0] = activeTokens.vault;
        // TODO
        // vault.grantAssetsToMarket(marketSupply.MARKET_ID(), assets);
        // vault.grantAssetsToMarket(marketSupply.MARKET_ID(), assets);
        marketSupplyMock.grantAssetsToMarket(marketSupply.MARKET_ID(), assets);
        marketBalance.updateMarketConfiguration(assets);

        uint256 balanceBefore = marketBalance.balanceOf(user);

        // when
        vm.startPrank(user);
        IApproveERC20(activeTokens.vault).approve(address(marketSupply), amount);
        marketSupply.enter(Erc4626SupplyFuse.Erc4626SupplyFuseData({vault: activeTokens.vault, amount: amount}));
        vm.stopPrank();

        // uint256 balanceAfter = marketBalance.balanceOf(user);

        // // then
        // assertTrue(balanceAfter > balanceBefore, "Balance should be greater after supply");
        // assertEq(balanceBefore, 0, "Balance before should be 0");
    }
}
