// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ICurveStableswapNG} from "./../../../contracts/fuses/curve_stableswap_ng/ext/ICurveStableswapNG.sol";
import {CurveStableswapNGSupplyFuse, CurveStableswapNGSupplyFuseEnterData, CurveStableswapNGSupplyFuseExitData, CurveStableswapNGSupplyFuseExitOneCoinData} from "./../../../contracts/fuses/curve_stableswap_ng/CurveStableswapNGSupplyFuse.sol";
import {CurveStableswapNGSupplyFuseMock} from "./CurveStableswapNGSupplyFuseMock.t.sol";

contract CurveStableswapNGSupplyFuseTest is Test {
    struct SupportedToken {
        address asset;
        string name;
    }

    // Address USDC/USDM pool on Ethereum mainnet
    // 0x4bD135524897333bec344e50ddD85126554E58B4
    // index 0 - USDC
    // index 1 - USDM

    address public constant CURVE_STABLESWAP_NG_POOL = 0x4bD135524897333bec344e50ddD85126554E58B4;

    address public constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address public constant USDM = 0x59D9356E565Ab3A36dD77763Fc0d87fEaf85508C;

    ICurveStableswapNG public constant CURVE_STABLESWAP_NG = ICurveStableswapNG(CURVE_STABLESWAP_NG_POOL);

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 202220653);
    }

    function testShouldBeAbleToSupplyOneCoinAtIndexOne() external {
        // given
        SupportedToken memory activeToken = SupportedToken({asset: USDM, name: "USDM"});

        CurveStableswapNGSupplyFuse fuse = new CurveStableswapNGSupplyFuse(1, address(CURVE_STABLESWAP_NG));
        CurveStableswapNGSupplyFuseMock fuseMock = new CurveStableswapNGSupplyFuseMock(address(fuse));

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0;
        amounts[1] = 100 * 10 ** ERC20(USDM).decimals();

        uint256 decimals = ERC20(activeToken.asset).decimals();

        _supplyTokensToMockVault(activeToken.asset, address(fuseMock), 1_000 * 10 ** decimals);

        uint256 balanceBefore = ERC20(USDM).balanceOf(address(fuseMock));

        address[] memory assets = new address[](1);
        assets[0] = CURVE_STABLESWAP_NG_POOL;
        fuseMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);

        // when
        fuseMock.enter(
            CurveStableswapNGSupplyFuseEnterData({amounts: amounts, minMintAmount: 0, receiver: address(fuseMock)})
        );

        // then
        uint256 balanceAfter = ERC20(USDM).balanceOf(address(fuseMock));
        uint256 lpTokenBalance = ERC20(CURVE_STABLESWAP_NG_POOL).balanceOf(address(fuseMock));
        assertApproxEqAbs(balanceAfter + amounts[1], balanceBefore, 100, "vault balance should be decreased by amount");
        assertGt(lpTokenBalance, 0);
    }

    function _supplyTokensToMockVault(address asset, address to, uint256 amount) private {
        if (asset == USDC) {
            vm.prank(0x05e3a758FdD29d28435019ac453297eA37b61b62); // holder
            ERC20(asset).transfer(to, amount);
        } else if (asset == USDM) {
            vm.prank(0x426c4966fC76Bf782A663203c023578B744e4C5E); // holder
            ERC20(asset).transfer(to, amount);
        } else {
            deal(asset, to, amount);
        }

        uint256 balanceAfterTransfer = ERC20(asset).balanceOf(to);
    }
}
