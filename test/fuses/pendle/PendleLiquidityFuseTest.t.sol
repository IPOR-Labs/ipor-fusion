// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPMarket} from "@pendle/core-v2/contracts/interfaces/IPMarket.sol";
import {IStandardizedYield} from "@pendle/core-v2/contracts/interfaces/IStandardizedYield.sol";
import {IPPrincipalToken} from "@pendle/core-v2/contracts/interfaces/IPPrincipalToken.sol";
import {IPYieldToken} from "@pendle/core-v2/contracts/interfaces/IPYieldToken.sol";
import {ApproxParams, TokenInput, SwapData, TokenOutput} from "@pendle/core-v2/contracts/interfaces/IPAllActionV3.sol";
import {PlasmaVault, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultHelper, DeployMinimalPlasmaVaultParams} from "../../test_helpers/PlasmaVaultHelper.sol";
import {TestAddresses} from "../../test_helpers/TestAddresses.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {PriceOracleMiddlewareHelper} from "../../test_helpers/PriceOracleMiddlewareHelper.sol";
import {IporFusionAccessManagerHelper} from "../../test_helpers/IporFusionAccessManagerHelper.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {PendleHelper, PendleAddresses} from "../../test_helpers/PendleHelper.sol";

import {PendleLiquidityFuse, PendleLiquidityFuseEnterData, PendleLiquidityFuseExitData} from "../../../contracts/fuses/pendle/PendleLiquidityFuse.sol";

contract PendleLiquidityFuseTest is Test {
    using PriceOracleMiddlewareHelper for PriceOracleMiddleware;
    using PlasmaVaultHelper for PlasmaVault;
    using IporFusionAccessManagerHelper for IporFusionAccessManager;

    address private constant _UNDERLYING_TOKEN = TestAddresses.ARB_WST_ETH;
    string private constant _UNDERLYING_TOKEN_NAME = "WstETH";
    address private constant _USER = TestAddresses.USER;
    uint256 private constant ERROR_DELTA = 100;

    PlasmaVault private _plasmaVault;
    PriceOracleMiddleware private _priceOracleMiddleware;
    IporFusionAccessManager private _accessManager;

    // Pendle Market  wstEth - https://app.pendle.finance/trade/markets/0x08a152834de126d2ef83d612ff36e4523fd0017f/swap?view=pt&chain=arbitrum&tab=info&page=1
    address private constant _MARKET = 0x08a152834de126d2ef83D612ff36e4523FD0017F;

    PendleAddresses private _pendleAddresses;

    function setUp() public {
        // Fork Arbitrum network
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 276241475);

        // Deploy price oracle middleware
        vm.startPrank(TestAddresses.ATOMIST);
        _priceOracleMiddleware = PriceOracleMiddlewareHelper.getArbitrumPriceOracleMiddleware();
        vm.stopPrank();

        // Deploy minimal plasma vault
        DeployMinimalPlasmaVaultParams memory params = DeployMinimalPlasmaVaultParams({
            underlyingToken: _UNDERLYING_TOKEN,
            underlyingTokenName: _UNDERLYING_TOKEN_NAME,
            priceOracleMiddleware: _priceOracleMiddleware.addressOf(),
            atomist: TestAddresses.ATOMIST
        });

        vm.startPrank(TestAddresses.ATOMIST);
        _plasmaVault = PlasmaVaultHelper.deployMinimalPlasmaVault(params);

        _accessManager = _plasmaVault.accessManagerOf();
        _accessManager.setupInitRoles(_plasmaVault);
        vm.stopPrank();

        address[] memory markets = new address[](1);
        markets[0] = _MARKET;

        _pendleAddresses = PendleHelper.addFullMarket(_plasmaVault, markets, vm);

        // Fund user with wstETH
        deal(_UNDERLYING_TOKEN, _USER, 10 ether); // Fund with 10 wstETH

        // User deposits wstETH to plasma vault
        vm.startPrank(_USER);
        IERC20(_UNDERLYING_TOKEN).approve(address(_plasmaVault), 10 ether);
        _plasmaVault.deposit(10 ether, _USER);
        vm.stopPrank();
    }

    function test_empty() public {
        uint256 balance = IERC20(_UNDERLYING_TOKEN).balanceOf(address(_plasmaVault));
        console2.log("balance", balance);
    }

    function testAddLiquidity5WstEth() public {
        // Given
        uint256 addAmount = 1 ether; // 1 wstETH

        // Prepare liquidity action
        PendleLiquidityFuseEnterData memory enterData = PendleLiquidityFuseEnterData({
            market: _MARKET,
            minLpOut: 0, // For test purposes, we set minimum LP output to 0
            input: TokenInput({
                tokenIn: _UNDERLYING_TOKEN,
                netTokenIn: addAmount,
                tokenMintSy: _UNDERLYING_TOKEN,
                pendleSwap: address(0),
                swapData: _createSwapTypeNoAggregator()
            }),
            guessPtReceivedFromSy: ApproxParams({
                guessMin: 0,
                guessMax: type(uint256).max,
                guessOffchain: 0,
                maxIteration: 256,
                eps: 1e15
            })
        });

        // Create FuseAction for adding liquidity
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: _pendleAddresses.liquidityFuse,
            data: abi.encodeWithSignature(
                "enter((address,uint256,(address,uint256,address,address,(uint8,address,bytes,bool)),(uint256,uint256,uint256,uint256,uint256)))",
                enterData
            )
        });

        // uint256 totalAssetBefore = _plasmaVault.totalAssets(); // TODO: check after implement balanceFuse
        // uint256 balanceInMarketBefore = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.PENDLE); // TODO: check after implement balanceFuse

        // When
        vm.prank(TestAddresses.ALPHA);
        _plasmaVault.execute(actions);

        IPMarket market = IPMarket(_MARKET);
        (IStandardizedYield sy, IPPrincipalToken pt, IPYieldToken yt) = market.readTokens();

        console2.log("plasmaVault", address(_plasmaVault));

        // Then
        uint256 ptBalanceAfter = pt.balanceOf(address(_plasmaVault));
        console2.log("pt", address(pt));
        console2.log("ptBalanceAfter", ptBalanceAfter);

        uint256 syBalanceAfter = sy.balanceOf(address(_plasmaVault));
        console2.log("sy", address(sy));
        console2.log("syBalanceAfter", syBalanceAfter);

        uint256 totalAssetAfter = _plasmaVault.totalAssets();
        console2.log("totalAssetAfter", totalAssetAfter);

        console2.log("market: ", market.balanceOf(address(_plasmaVault)));
    }
    // 0x80c12D5b6Cc494632Bf11b03F09436c8B61Cc5Df

    function _createSwapTypeNoAggregator() private pure returns (SwapData memory) {}

    function testEnterAndExitPendle() public {
        // Given - First enter Pendle with 1 wstETH
        uint256 addAmount = 1 ether;

        PendleLiquidityFuseEnterData memory enterData = PendleLiquidityFuseEnterData({
            market: _MARKET,
            minLpOut: 0,
            input: TokenInput({
                tokenIn: _UNDERLYING_TOKEN,
                netTokenIn: addAmount,
                tokenMintSy: _UNDERLYING_TOKEN,
                pendleSwap: address(0),
                swapData: _createSwapTypeNoAggregator()
            }),
            guessPtReceivedFromSy: ApproxParams({
                guessMin: 0,
                guessMax: type(uint256).max,
                guessOffchain: 0,
                maxIteration: 256,
                eps: 1e15
            })
        });

        FuseAction[] memory enterActions = new FuseAction[](1);
        enterActions[0] = FuseAction({
            fuse: _pendleAddresses.liquidityFuse,
            data: abi.encodeWithSignature(
                "enter((address,uint256,(address,uint256,address,address,(uint8,address,bytes,bool)),(uint256,uint256,uint256,uint256,uint256)))",
                enterData
            )
        });

        // When - Execute enter
        vm.prank(TestAddresses.ALPHA);
        _plasmaVault.execute(enterActions);

        // Get market info after enter
        IPMarket market = IPMarket(_MARKET);
        (IStandardizedYield sy, IPPrincipalToken pt, IPYieldToken yt) = market.readTokens();

        uint256 lpBalanceAfterEnter = market.balanceOf(address(_plasmaVault));
        uint256 ptBalanceAfterEnter = pt.balanceOf(address(_plasmaVault));
        uint256 syBalanceAfterEnter = sy.balanceOf(address(_plasmaVault));

        console2.log("=== After Enter ===");
        console2.log("LP Balance", lpBalanceAfterEnter);
        console2.log("PT Balance", ptBalanceAfterEnter);
        console2.log("SY Balance", syBalanceAfterEnter);
        console2.log("market: ", market.balanceOf(address(_plasmaVault)));
        console2.log("vaultBalance wstEth", IERC20(_UNDERLYING_TOKEN).balanceOf(address(_plasmaVault)));

        // Then prepare exit - remove all liquidity
        PendleLiquidityFuseExitData memory exitData = PendleLiquidityFuseExitData({
            market: _MARKET,
            netLpToRemove: lpBalanceAfterEnter, // Remove all LP tokens
            output: TokenOutput({
                tokenOut: _UNDERLYING_TOKEN,
                minTokenOut: 0, // For test purposes
                tokenRedeemSy: _UNDERLYING_TOKEN,
                pendleSwap: address(0),
                swapData: _createSwapTypeNoAggregator()
            })
        });

        FuseAction[] memory exitActions = new FuseAction[](1);
        exitActions[0] = FuseAction({
            fuse: _pendleAddresses.liquidityFuse,
            data: abi.encodeWithSignature(
                "exit((address,uint256,(address,uint256,address,address,(uint8,address,bytes,bool))))",
                exitData
            )
        });

        // When - Execute exit
        vm.prank(TestAddresses.ALPHA);
        _plasmaVault.execute(exitActions);

        // Then - Verify balances after exit
        uint256 lpBalanceAfterExit = market.balanceOf(address(_plasmaVault));
        uint256 ptBalanceAfterExit = pt.balanceOf(address(_plasmaVault));
        uint256 syBalanceAfterExit = sy.balanceOf(address(_plasmaVault));

        console2.log("=== After Exit ===");
        console2.log("LP Balance", lpBalanceAfterExit);
        console2.log("PT Balance", ptBalanceAfterExit);
        console2.log("SY Balance", syBalanceAfterExit);
        console2.log("market: ", market.balanceOf(address(_plasmaVault)));
        console2.log(
            "vaultBalance wstEth",
            IERC20(_UNDERLYING_TOKEN).balanceOf(address(_plasmaVault)) - 9000000000000000000
        );

        // Assert all balances are 0 after exit
        assertEq(lpBalanceAfterExit, 0, "LP balance should be 0 after exit");
        assertEq(ptBalanceAfterExit, 0, "PT balance should be 0 after exit");
        assertEq(syBalanceAfterExit, 0, "SY balance should be 0 after exit");
    }
}

// function removeLiquidityCore(MarketState memory market, int256 lpToRemove)
//     internal
//     pure
//     returns (int256 netSyToAccount, int256 netPtToAccount)
// {
//     /// ------------------------------------------------------------
//     /// CHECKS
//     /// ------------------------------------------------------------
//     if (lpToRemove == 0) revert Errors.MarketZeroAmountsInput();

//     /// ------------------------------------------------------------
//     /// MATH
//     /// ------------------------------------------------------------
//     netSyToAccount = (lpToRemove * market.totalSy) / market.totalLp;
//     netPtToAccount = (lpToRemove * market.totalPt) / market.totalLp;

//     if (netSyToAccount == 0 && netPtToAccount == 0) revert Errors.MarketZeroAmountsOutput();

//     /// ------------------------------------------------------------
//     /// WRITE
//     /// ------------------------------------------------------------
//     market.totalLp = market.totalLp.subNoNeg(lpToRemove);
//     market.totalPt = market.totalPt.subNoNeg(netPtToAccount);
//     market.totalSy = market.totalSy.subNoNeg(netSyToAccount);
// }
