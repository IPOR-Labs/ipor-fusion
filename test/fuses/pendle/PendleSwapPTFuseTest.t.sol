// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPMarket} from "@pendle/core-v2/contracts/interfaces/IPMarket.sol";
import {IPPrincipalToken} from "@pendle/core-v2/contracts/interfaces/IPPrincipalToken.sol";
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

import {PendleSwapPTFuse, PendleSwapPTFuseEnterData, PendleSwapPTFuseExitData} from "../../../contracts/fuses/pendle/PendleSwapPTFuse.sol";
import {PendleRedeemPTAfterMaturityFuse, PendleRedeemPTAfterMaturityFuseEnterData} from "../../../contracts/fuses/pendle/PendleRedeemPTAfterMaturityFuse.sol";

import {RewardsClaimManager} from "../../../contracts/managers/rewards/RewardsClaimManager.sol";

contract PendleSwapPTFuseTest is Test {
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

    // Pendle Market wstEth
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
        (_plasmaVault, ) = PlasmaVaultHelper.deployMinimalPlasmaVault(params);

        _accessManager = _plasmaVault.accessManagerOf();
        _accessManager.setupInitRoles(
            _plasmaVault,
            address(0x123),
            address(new RewardsClaimManager(address(_accessManager), address(_plasmaVault)))
        );
        vm.stopPrank();

        address[] memory markets = new address[](1);
        markets[0] = _MARKET;

        uint256[] memory usePendleOracleMethod = new uint256[](1);
        usePendleOracleMethod[0] = 0;

        _pendleAddresses = PendleHelper.addFullMarket(_plasmaVault, markets, usePendleOracleMethod, vm);

        // Fund user with wstETH
        deal(_UNDERLYING_TOKEN, _USER, 100 ether);

        // User deposits wstETH to plasma vault
        vm.startPrank(_USER);
        IERC20(_UNDERLYING_TOKEN).approve(address(_plasmaVault), 100 ether);
        _plasmaVault.deposit(10 ether, _USER);
        vm.stopPrank();
    }

    // solhint-disable-next-line no-empty-blocks
    function _createSwapTypeNoAggregator() private pure returns (SwapData memory swap) {}

    function testSwapTokenForPT() public {
        // Given
        uint256 swapAmount = 10 ether; // 1 wstETH

        PendleSwapPTFuseEnterData memory enterData = PendleSwapPTFuseEnterData({
            market: _MARKET,
            minPtOut: 0, // For test purposes
            input: TokenInput({
                tokenIn: _UNDERLYING_TOKEN,
                netTokenIn: swapAmount,
                tokenMintSy: _UNDERLYING_TOKEN,
                pendleSwap: address(0),
                swapData: _createSwapTypeNoAggregator()
            }),
            guessPtOut: ApproxParams({
                guessMin: 0,
                guessMax: type(uint256).max,
                guessOffchain: 0,
                maxIteration: 256,
                eps: 1e15
            })
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: _pendleAddresses.swapPTFuse,
            data: abi.encodeWithSignature(
                "enter((address,uint256,(uint256,uint256,uint256,uint256,uint256),(address,uint256,address,address,(uint8,address,bytes,bool))))",
                enterData
            )
        });

        IPMarket market = IPMarket(_MARKET);
        (, IPPrincipalToken pt, ) = market.readTokens();

        uint256 ptBalanceBefore = pt.balanceOf(address(_plasmaVault));
        uint256 erc20MarketBefore = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.ERC20_VAULT_BALANCE);

        // When
        vm.prank(TestAddresses.ALPHA);
        _plasmaVault.execute(actions);

        // Then

        uint256 totalAssetsAfter = _plasmaVault.totalAssets();
        uint256 erc20MarketAfter = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.ERC20_VAULT_BALANCE);

        assertApproxEqAbs(ptBalanceBefore, 0, ERROR_DELTA, "PT balance should be 0");
        assertApproxEqAbs(
            totalAssetsAfter,
            8434352772450140063,
            ERROR_DELTA,
            "Total assets should be 8434352772450140063"
        );
        assertApproxEqAbs(erc20MarketBefore, 0, ERROR_DELTA, "ERC20 market balance should be 0");
        assertApproxEqAbs(
            erc20MarketAfter,
            8434352772450140063,
            ERROR_DELTA,
            "ERC20 market balance should be 8434352772450140063"
        );
        assertApproxEqAbs(erc20MarketBefore, 0, ERROR_DELTA, "ERC20 market balance should be 0");
        assertApproxEqAbs(
            erc20MarketAfter,
            8434352772450140063,
            ERROR_DELTA,
            "ERC20 market balance should be 8434352772450140063"
        );
    }

    function testRedeemPTForToken() public {
        // First swap tokens for PT
        testSwapTokenForPT();

        vm.warp(block.timestamp + 356 days);

        // Given
        IPMarket market = IPMarket(_MARKET);
        (, IPPrincipalToken pt, ) = market.readTokens();
        uint256 ptBalanceBefore = pt.balanceOf(address(_plasmaVault));
        uint256 totalAssetsBefore = _plasmaVault.totalAssets();

        PendleRedeemPTAfterMaturityFuseEnterData memory enterData = PendleRedeemPTAfterMaturityFuseEnterData({
            market: _MARKET,
            netPyIn: ptBalanceBefore,
            output: TokenOutput({
                tokenOut: _UNDERLYING_TOKEN,
                minTokenOut: 0, // For test purposes
                tokenRedeemSy: _UNDERLYING_TOKEN,
                pendleSwap: address(0),
                swapData: _createSwapTypeNoAggregator()
            })
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: _pendleAddresses.redeemPTAfterMaturityFuse,
            data: abi.encodeWithSignature(
                "enter((address,uint256,(address,uint256,address,address,(uint8,address,bytes,bool))))",
                enterData
            )
        });

        // When
        vm.prank(TestAddresses.ALPHA);
        _plasmaVault.execute(actions);

        // Then
        uint256 ptBalanceAfter = pt.balanceOf(address(_plasmaVault));
        uint256 totalAssetsAfter = _plasmaVault.totalAssets();
        uint256 erc20MarketAfter = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.ERC20_VAULT_BALANCE);

        assertApproxEqAbs(ptBalanceBefore, 12117435159760642058, 0, "PT balance should be 12117435159760642058");
        assertApproxEqAbs(ptBalanceAfter, 0, ERROR_DELTA, "PT balance should be 0");

        assertApproxEqAbs(totalAssetsBefore, 8434352772450140063, 0, "Total assets should be 8434352772450140063");
        assertApproxEqAbs(
            totalAssetsAfter,
            10222875153389507980,
            ERROR_DELTA,
            "Total assets should be 10222875153389507980"
        );
        assertApproxEqAbs(erc20MarketAfter, 0, ERROR_DELTA, "ERC20 market balance should be 0");
    }

    function testSouldNotRedeemPTForTokenWhenNotMature() public {
        // First swap tokens for PT
        testSwapTokenForPT();

        // Given
        IPMarket market = IPMarket(_MARKET);
        (, IPPrincipalToken pt, ) = market.readTokens();
        uint256 ptBalanceBefore = pt.balanceOf(address(_plasmaVault));

        PendleRedeemPTAfterMaturityFuseEnterData memory enterData = PendleRedeemPTAfterMaturityFuseEnterData({
            market: _MARKET,
            netPyIn: ptBalanceBefore,
            output: TokenOutput({
                tokenOut: _UNDERLYING_TOKEN,
                minTokenOut: 0, // For test purposes
                tokenRedeemSy: _UNDERLYING_TOKEN,
                pendleSwap: address(0),
                swapData: _createSwapTypeNoAggregator()
            })
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: _pendleAddresses.redeemPTAfterMaturityFuse,
            data: abi.encodeWithSignature(
                "enter((address,uint256,(address,uint256,address,address,(uint8,address,bytes,bool))))",
                enterData
            )
        });

        // When
        vm.prank(TestAddresses.ALPHA);
        vm.expectRevert(PendleRedeemPTAfterMaturityFuse.PendleRedeemPTAfterMaturityFusePTNotExpired.selector);
        _plasmaVault.execute(actions);
    }

    function testSwapPTForToken() public {
        // First swap tokens for PT
        testSwapTokenForPT();

        // Given
        IPMarket market = IPMarket(_MARKET);
        (, IPPrincipalToken pt, ) = market.readTokens();
        uint256 ptBalanceBefore = pt.balanceOf(address(_plasmaVault));

        PendleSwapPTFuseExitData memory exitData = PendleSwapPTFuseExitData({
            market: _MARKET,
            exactPtIn: ptBalanceBefore,
            output: TokenOutput({
                tokenOut: _UNDERLYING_TOKEN,
                minTokenOut: 0, // For test purposes
                tokenRedeemSy: _UNDERLYING_TOKEN,
                pendleSwap: address(0),
                swapData: _createSwapTypeNoAggregator()
            })
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: _pendleAddresses.swapPTFuse,
            data: abi.encodeWithSignature(
                "exit((address,uint256,(address,uint256,address,address,(uint8,address,bytes,bool))))",
                exitData
            )
        });

        // When
        vm.prank(TestAddresses.ALPHA);
        _plasmaVault.execute(actions);

        // Then

        uint256 ptBalanceAfter = pt.balanceOf(address(_plasmaVault));
        uint256 totalAssetsAfter = _plasmaVault.totalAssets();
        uint256 erc20MarketAfter = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.ERC20_VAULT_BALANCE);
        assertApproxEqAbs(ptBalanceAfter, 0, ERROR_DELTA, "PT balance should be 0");
        assertApproxEqAbs(
            totalAssetsAfter,
            9982281542264038692,
            ERROR_DELTA,
            "Total assets should be 9982281542264038692"
        );
        assertApproxEqAbs(erc20MarketAfter, 0, ERROR_DELTA, "ERC20 market balance should be 0");
    }

    function testSwapInvalidMarket() public {
        // Given
        address invalidMarket = address(0x123);
        uint256 swapAmount = 1 ether;

        PendleSwapPTFuseEnterData memory enterData = PendleSwapPTFuseEnterData({
            market: invalidMarket,
            minPtOut: 0,
            input: TokenInput({
                tokenIn: _UNDERLYING_TOKEN,
                netTokenIn: swapAmount,
                tokenMintSy: _UNDERLYING_TOKEN,
                pendleSwap: address(0),
                swapData: _createSwapTypeNoAggregator()
            }),
            guessPtOut: ApproxParams({
                guessMin: 0,
                guessMax: type(uint256).max,
                guessOffchain: 0,
                maxIteration: 256,
                eps: 1e15
            })
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: _pendleAddresses.swapPTFuse,
            data: abi.encodeWithSignature(
                "enter((address,uint256,(uint256,uint256,uint256,uint256,uint256),(address,uint256,address,address,(uint8,address,bytes,bool))))",
                enterData
            )
        });

        // When/Then
        vm.prank(TestAddresses.ALPHA);
        vm.expectRevert(PendleSwapPTFuse.PendleSwapPTFuseInvalidMarketId.selector);
        _plasmaVault.execute(actions);
    }
}
