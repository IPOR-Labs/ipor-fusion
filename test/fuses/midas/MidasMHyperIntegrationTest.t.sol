// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {PlasmaVault, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {RewardsClaimManager} from "../../../contracts/managers/rewards/RewardsClaimManager.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";

import {MidasSupplyFuse, MidasSupplyFuseEnterData, MidasSupplyFuseExitData} from "../../../contracts/fuses/midas/MidasSupplyFuse.sol";
import {MidasRequestSupplyFuse, MidasRequestSupplyFuseEnterData, MidasRequestSupplyFuseExitData} from "../../../contracts/fuses/midas/MidasRequestSupplyFuse.sol";
import {MidasBalanceFuse} from "../../../contracts/fuses/midas/MidasBalanceFuse.sol";
import {MidasSubstrateLib, MidasSubstrate, MidasSubstrateType} from "../../../contracts/fuses/midas/lib/MidasSubstrateLib.sol";

import {PlasmaVaultHelper, DeployMinimalPlasmaVaultParams} from "../../test_helpers/PlasmaVaultHelper.sol";
import {PriceOracleMiddlewareHelper} from "../../test_helpers/PriceOracleMiddlewareHelper.sol";
import {IporFusionAccessManagerHelper} from "../../test_helpers/IporFusionAccessManagerHelper.sol";
import {TestAddresses} from "../../test_helpers/TestAddresses.sol";

/// @title MidasMHyperIntegrationTest
/// @notice Fork integration tests for Midas mHYPER fuses on Ethereum mainnet.
///         Verifies deposit, redeem, balance reporting, totalAssets, totalAssetsInMarket,
///         and exchangeRate consistency with production Midas mHYPER contracts.
contract MidasMHyperIntegrationTest is Test {
    using PriceOracleMiddlewareHelper for PriceOracleMiddleware;
    using PlasmaVaultHelper for PlasmaVault;
    using IporFusionAccessManagerHelper for IporFusionAccessManager;

    // ============ Mainnet Addresses ============
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant MHYPER_TOKEN = 0x9b5528528656DBC094765E2abB79F293c21191B9;
    address public constant MHYPER_DEPOSIT_VAULT = 0xbA9FD2850965053Ffab368Df8AA7eD2486f11024;
    address public constant MHYPER_REDEMPTION_VAULT = 0x6Be2f55816efd0d91f52720f096006d63c366e98;
    // Chainlink-compatible mHYPER/USD oracle (8 decimals)
    address public constant MHYPER_USD_ORACLE = 0x43881B05C3BE68B2d33eb70aDdF9F666C5005f68;
    // Chainlink USDC/USD feed on Ethereum
    address public constant CHAINLINK_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;

    uint256 public constant MARKET_ID = IporFusionMarkets.MIDAS;
    // mHYPER contracts deployed after block 22924500; use block 24500000
    uint256 public constant FORK_BLOCK = 24_500_000;

    PlasmaVault public plasmaVault;
    IporFusionAccessManager public accessManager;
    PriceOracleMiddleware public priceOracleMiddleware;

    MidasSupplyFuse public supplyFuse;
    MidasRequestSupplyFuse public requestSupplyFuse;
    MidasBalanceFuse public balanceFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), FORK_BLOCK);

        // Deploy price oracle middleware
        vm.startPrank(TestAddresses.ATOMIST);
        priceOracleMiddleware = PriceOracleMiddlewareHelper.deployPriceOracleMiddleware(
            TestAddresses.ATOMIST,
            address(0)
        );
        priceOracleMiddleware.addSource(USDC, CHAINLINK_USDC_USD);
        priceOracleMiddleware.addSource(MHYPER_TOKEN, MHYPER_USD_ORACLE);
        vm.stopPrank();

        // Deploy PlasmaVault with USDC as underlying
        DeployMinimalPlasmaVaultParams memory params = DeployMinimalPlasmaVaultParams({
            underlyingToken: USDC,
            underlyingTokenName: "USDC",
            priceOracleMiddleware: address(priceOracleMiddleware),
            atomist: TestAddresses.ATOMIST
        });

        vm.startPrank(TestAddresses.ATOMIST);
        address withdrawManager;
        (plasmaVault, withdrawManager) = PlasmaVaultHelper.deployMinimalPlasmaVault(params);

        accessManager = plasmaVault.accessManagerOf();
        accessManager.setupInitRoles(
            plasmaVault,
            withdrawManager,
            address(new RewardsClaimManager(address(accessManager), address(plasmaVault)))
        );
        vm.stopPrank();

        // Deploy Midas fuses
        supplyFuse = new MidasSupplyFuse(MARKET_ID);
        requestSupplyFuse = new MidasRequestSupplyFuse(MARKET_ID);
        balanceFuse = new MidasBalanceFuse(MARKET_ID);

        // Add fuses, balance fuse, and substrates (all require FUSE_MANAGER_ROLE)
        vm.startPrank(TestAddresses.FUSE_MANAGER);

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuse);
        fuses[1] = address(requestSupplyFuse);
        plasmaVault.addFusesToVault(fuses);

        plasmaVault.addBalanceFusesToVault(MARKET_ID, address(balanceFuse));

        // Configure market substrates
        // mHYPER uses one redemption vault for both instant and standard redemption
        bytes32[] memory substrates = new bytes32[](5);
        substrates[0] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.M_TOKEN, substrateAddress: MHYPER_TOKEN})
        );
        substrates[1] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.DEPOSIT_VAULT, substrateAddress: MHYPER_DEPOSIT_VAULT})
        );
        substrates[2] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.ASSET, substrateAddress: USDC})
        );
        substrates[3] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({
                substrateType: MidasSubstrateType.INSTANT_REDEMPTION_VAULT,
                substrateAddress: MHYPER_REDEMPTION_VAULT
            })
        );
        substrates[4] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({
                substrateType: MidasSubstrateType.REDEMPTION_VAULT,
                substrateAddress: MHYPER_REDEMPTION_VAULT
            })
        );
        plasmaVault.addSubstratesToMarket(MARKET_ID, substrates);

        vm.stopPrank();

        // Fund vault with USDC via user deposit
        deal(USDC, TestAddresses.USER, 500_000e6);
        vm.startPrank(TestAddresses.USER);
        IERC20(USDC).approve(address(plasmaVault), 500_000e6);
        plasmaVault.deposit(500_000e6, TestAddresses.USER);
        vm.stopPrank();

        // Label addresses for traces
        vm.label(address(plasmaVault), "PlasmaVault");
        vm.label(address(supplyFuse), "MidasSupplyFuse");
        vm.label(address(requestSupplyFuse), "MidasRequestSupplyFuse");
        vm.label(address(balanceFuse), "MidasBalanceFuse");
        vm.label(USDC, "USDC");
        vm.label(MHYPER_TOKEN, "mHYPER");
        vm.label(MHYPER_DEPOSIT_VAULT, "MidasDepositVault");
        vm.label(MHYPER_REDEMPTION_VAULT, "MidasRedemptionVault");
    }

    // ============ Deposit Instant ============

    function testDepositInstant_ShouldMintMHyper() public {
        uint256 depositAmount = 100_000e6; // 100,000 USDC

        uint256 totalAssetsBefore = plasmaVault.totalAssets();
        uint256 totalAssetsInMarketBefore = plasmaVault.totalAssetsInMarket(MARKET_ID);
        uint256 exchangeRateBefore = plasmaVault.convertToAssets(1e6);

        uint256 usdcBefore = IERC20(USDC).balanceOf(address(plasmaVault));
        uint256 mHyperBefore = IERC20(MHYPER_TOKEN).balanceOf(address(plasmaVault));

        // mHYPER price ~$1.0794, fee=0 => 100k USDC => ~92,644 mHYPER
        uint256 minMTokenOut = 90_000e18;

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(supplyFuse),
            data: abi.encodeWithSignature(
                "enter((address,address,uint256,uint256,address))",
                MidasSupplyFuseEnterData({
                    mToken: MHYPER_TOKEN,
                    tokenIn: USDC,
                    amount: depositAmount,
                    minMTokenAmountOut: minMTokenOut,
                    depositVault: MHYPER_DEPOSIT_VAULT
                })
            )
        });

        vm.prank(TestAddresses.ALPHA);
        plasmaVault.execute(actions);

        uint256 usdcAfter = IERC20(USDC).balanceOf(address(plasmaVault));
        uint256 mHyperAfter = IERC20(MHYPER_TOKEN).balanceOf(address(plasmaVault));

        // Verify USDC was spent
        assertEq(usdcBefore - usdcAfter, depositAmount, "Should spend exactly depositAmount USDC");

        // Verify mHYPER was received
        uint256 mHyperReceived = mHyperAfter - mHyperBefore;
        assertGt(mHyperReceived, minMTokenOut, "Should receive significant mHYPER");

        // Verify totalAssets did not change significantly (USDC left vault, mHYPER value entered market)
        uint256 totalAssetsAfter = plasmaVault.totalAssets();
        assertApproxEqRel(totalAssetsAfter, totalAssetsBefore, 0.0001e18, "totalAssets should be stable after deposit");

        // Verify totalAssetsInMarket increased
        uint256 totalAssetsInMarketAfter = plasmaVault.totalAssetsInMarket(MARKET_ID);
        assertGt(totalAssetsInMarketAfter, totalAssetsInMarketBefore, "totalAssetsInMarket should increase");
        assertApproxEqRel(
            totalAssetsInMarketAfter,
            depositAmount,
            0.0001e18,
            "totalAssetsInMarket should reflect deposited amount"
        );

        // Verify exchange rate did not change
        uint256 exchangeRateAfter = plasmaVault.convertToAssets(1e6);
        assertEq(exchangeRateAfter, exchangeRateBefore, "exchangeRate should be stable");
    }

    function testDepositInstant_MultipleDeposits_ShouldAccumulate() public {
        uint256 firstDeposit = 50_000e6;
        uint256 secondDeposit = 100_000e6;

        uint256 totalAssetsBefore = plasmaVault.totalAssets();
        uint256 exchangeRateBefore = plasmaVault.convertToAssets(1e6);
        uint256 mHyperAfterFirst;
        uint256 totalAssetsInMarketAfterFirst;

        // --- First deposit ---
        {
            uint256 usdcBefore = IERC20(USDC).balanceOf(address(plasmaVault));

            _executeDepositInstant(firstDeposit, 45_000e18);

            uint256 usdcAfter = IERC20(USDC).balanceOf(address(plasmaVault));
            mHyperAfterFirst = IERC20(MHYPER_TOKEN).balanceOf(address(plasmaVault));
            totalAssetsInMarketAfterFirst = plasmaVault.totalAssetsInMarket(MARKET_ID);

            assertEq(usdcBefore - usdcAfter, firstDeposit, "First deposit should spend exact USDC");
            assertGt(mHyperAfterFirst, 0, "Should hold mHYPER after first deposit");
            assertApproxEqRel(plasmaVault.totalAssets(), totalAssetsBefore, 0.0001e18, "totalAssets stable after first deposit");
            assertEq(plasmaVault.convertToAssets(1e6), exchangeRateBefore, "exchangeRate stable after first deposit");
        }

        // --- Second deposit ---
        {
            uint256 usdcBefore = IERC20(USDC).balanceOf(address(plasmaVault));

            _executeDepositInstant(secondDeposit, 90_000e18);

            uint256 usdcAfter = IERC20(USDC).balanceOf(address(plasmaVault));

            assertEq(usdcBefore - usdcAfter, secondDeposit, "Second deposit should spend exact USDC");
            assertGt(IERC20(MHYPER_TOKEN).balanceOf(address(plasmaVault)), mHyperAfterFirst, "mHYPER should increase");
            assertGt(plasmaVault.totalAssetsInMarket(MARKET_ID), totalAssetsInMarketAfterFirst, "totalAssetsInMarket should increase");
            assertApproxEqRel(plasmaVault.totalAssets(), totalAssetsBefore, 0.0001e18, "totalAssets stable after both deposits");
            assertEq(plasmaVault.convertToAssets(1e6), exchangeRateBefore, "exchangeRate stable after both deposits");
            assertApproxEqRel(
                plasmaVault.totalAssetsInMarket(MARKET_ID),
                firstDeposit + secondDeposit,
                0.0001e18,
                "totalAssetsInMarket should reflect total deposited"
            );
            assertEq(usdcAfter, 350_000e6, "Should have 350k USDC remaining");
        }
    }

    // ============ Redeem Instant ============

    function testRedeemInstant_ShouldReturnUsdc() public {
        // First deposit 100k USDC to get mHYPER
        _executeDepositInstant(100_000e6, 90_000e18);

        uint256 mHyperBalance = IERC20(MHYPER_TOKEN).balanceOf(address(plasmaVault));
        assertGt(mHyperBalance, 0, "Should hold mHYPER");

        uint256 totalAssetsBefore = plasmaVault.totalAssets();
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(plasmaVault));
        uint256 exchangeRateBefore = plasmaVault.convertToAssets(1e6);

        // Redeem all mHYPER
        // RedemptionVault has instantFee=50 (0.5%), so expect ~99.5k USDC back
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(supplyFuse),
            data: abi.encodeWithSignature(
                "exit((address,uint256,uint256,address,address))",
                MidasSupplyFuseExitData({
                    mToken: MHYPER_TOKEN,
                    amount: mHyperBalance,
                    minTokenOutAmount: 95_000e6, // allow for 0.5% fee + price impact
                    tokenOut: USDC,
                    instantRedemptionVault: MHYPER_REDEMPTION_VAULT
                })
            )
        });

        vm.prank(TestAddresses.ALPHA);
        plasmaVault.execute(actions);

        uint256 mHyperAfter = IERC20(MHYPER_TOKEN).balanceOf(address(plasmaVault));
        uint256 usdcAfter = IERC20(USDC).balanceOf(address(plasmaVault));

        // All mHYPER should be redeemed
        assertEq(mHyperAfter, 0, "All mHYPER should be redeemed");

        // USDC should increase
        uint256 usdcReceived = usdcAfter - usdcBefore;
        assertGt(usdcReceived, 95_000e6, "Should receive at least 95k USDC (after 0.5% fee)");

        // totalAssetsInMarket should be 0 after full redemption
        uint256 totalAssetsInMarketAfter = plasmaVault.totalAssetsInMarket(MARKET_ID);
        assertEq(totalAssetsInMarketAfter, 0, "totalAssetsInMarket should be 0 after full redemption");

        // totalAssets should be close to before (minus 0.5% fee on 100k out of 500k = ~0.1% loss)
        uint256 totalAssetsAfter = plasmaVault.totalAssets();
        assertApproxEqRel(totalAssetsAfter, totalAssetsBefore, 0.002e18, "totalAssets should be close after round-trip");

        // Exchange rate should be stable (small loss from 0.5% redemption fee on 100k/500k = ~0.1%)
        uint256 exchangeRateAfter = plasmaVault.convertToAssets(1e6);
        assertApproxEqRel(exchangeRateAfter, exchangeRateBefore, 0.002e18, "exchangeRate should be stable");
    }

    function testRedeemInstant_PartialRedeem() public {
        // Deposit 200k USDC
        _executeDepositInstant(200_000e6, 180_000e18);

        uint256 mHyperBalance = IERC20(MHYPER_TOKEN).balanceOf(address(plasmaVault));
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(plasmaVault));
        uint256 totalAssetsBefore = plasmaVault.totalAssets();
        uint256 exchangeRateBefore = plasmaVault.convertToAssets(1e6);

        // Redeem half
        uint256 redeemAmount = mHyperBalance / 2;

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(supplyFuse),
            data: abi.encodeWithSignature(
                "exit((address,uint256,uint256,address,address))",
                MidasSupplyFuseExitData({
                    mToken: MHYPER_TOKEN,
                    amount: redeemAmount,
                    minTokenOutAmount: 95_000e6,
                    tokenOut: USDC,
                    instantRedemptionVault: MHYPER_REDEMPTION_VAULT
                })
            )
        });

        vm.prank(TestAddresses.ALPHA);
        plasmaVault.execute(actions);

        uint256 mHyperAfter = IERC20(MHYPER_TOKEN).balanceOf(address(plasmaVault));
        uint256 usdcAfter = IERC20(USDC).balanceOf(address(plasmaVault));
        uint256 totalAssetsAfter = plasmaVault.totalAssets();
        uint256 exchangeRateAfter = plasmaVault.convertToAssets(1e6);
        uint256 totalAssetsInMarketAfter = plasmaVault.totalAssetsInMarket(MARKET_ID);

        // mHYPER: should have roughly half remaining
        assertApproxEqRel(mHyperAfter, mHyperBalance / 2, 0.001e18, "Should have ~half mHYPER remaining");

        // USDC: should increase (received ~99.5k USDC minus 0.5% fee)
        uint256 usdcReceived = usdcAfter - usdcBefore;
        assertGt(usdcReceived, 95_000e6, "Should receive USDC from partial redeem");

        // totalAssetsInMarket should be roughly halved
        assertGt(totalAssetsInMarketAfter, 0, "Should still have assets in market");
        assertApproxEqRel(totalAssetsInMarketAfter, 100_000e6, 0.0001e18, "Market balance should reflect ~half");

        // totalAssets: small loss from 0.5% fee on ~100k out of 500k = ~0.1%
        assertApproxEqRel(totalAssetsAfter, totalAssetsBefore, 0.002e18, "totalAssets stable after partial redeem");

        // exchangeRate: small drop from redemption fee
        assertApproxEqRel(exchangeRateAfter, exchangeRateBefore, 0.002e18, "exchangeRate stable after partial redeem");
    }

    // ============ Redemption Request ============

    function testRedemptionRequest_ShouldCreateRequest() public {
        // Deposit first
        _executeDepositInstant(100_000e6, 90_000e18);

        uint256 mHyperBalance = IERC20(MHYPER_TOKEN).balanceOf(address(plasmaVault));
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(plasmaVault));
        uint256 totalAssetsBefore = plasmaVault.totalAssets();
        uint256 exchangeRateBefore = plasmaVault.convertToAssets(1e6);

        // Submit redemption request for all mHYPER
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(requestSupplyFuse),
            data: abi.encodeWithSignature(
                "exit((address,uint256,address,address))",
                MidasRequestSupplyFuseExitData({
                    mToken: MHYPER_TOKEN,
                    amount: mHyperBalance,
                    tokenOut: USDC,
                    standardRedemptionVault: MHYPER_REDEMPTION_VAULT
                })
            )
        });

        vm.prank(TestAddresses.ALPHA);
        plasmaVault.execute(actions);

        uint256 mHyperAfter = IERC20(MHYPER_TOKEN).balanceOf(address(plasmaVault));
        uint256 usdcAfter = IERC20(USDC).balanceOf(address(plasmaVault));
        uint256 totalAssetsAfter = plasmaVault.totalAssets();
        uint256 exchangeRateAfter = plasmaVault.convertToAssets(1e6);
        uint256 totalAssetsInMarketAfter = plasmaVault.totalAssetsInMarket(MARKET_ID);

        // mHYPER should have left the vault (transferred to Midas redemption vault)
        assertEq(mHyperAfter, 0, "All mHYPER should be sent to redemption vault");

        // USDC should not change (redemption request doesn't return USDC immediately)
        assertEq(usdcAfter, usdcBefore, "USDC should not change during redemption request");

        // totalAssetsInMarket should still reflect pending redemption value
        assertGt(totalAssetsInMarketAfter, 0, "totalAssetsInMarket should include pending redemption");

        // totalAssets should still account for pending redemption
        assertApproxEqRel(
            totalAssetsAfter,
            totalAssetsBefore,
            0.0001e18,
            "totalAssets should include pending redemption value"
        );

        // exchangeRate should be stable (no value lost, just moved to pending)
        assertEq(exchangeRateAfter, exchangeRateBefore, "exchangeRate stable during redemption request");
    }

    // ============ Balance Fuse Consistency ============

    function testBalanceFuse_ShouldReflectMHyperHoldings() public {
        // Before deposit: all values baseline
        uint256 marketBalanceBefore = plasmaVault.totalAssetsInMarket(MARKET_ID);
        uint256 totalAssetsBefore = plasmaVault.totalAssets();
        uint256 exchangeRateBefore = plasmaVault.convertToAssets(1e6);
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(plasmaVault));
        uint256 mHyperBefore = IERC20(MHYPER_TOKEN).balanceOf(address(plasmaVault));

        assertEq(marketBalanceBefore, 0, "Market should have 0 balance before deposit");
        assertEq(mHyperBefore, 0, "Should hold 0 mHYPER before deposit");

        // Deposit 100k USDC
        _executeDepositInstant(100_000e6, 90_000e18);

        uint256 usdcAfter = IERC20(USDC).balanceOf(address(plasmaVault));
        uint256 mHyperAfter = IERC20(MHYPER_TOKEN).balanceOf(address(plasmaVault));
        uint256 marketBalanceAfter = plasmaVault.totalAssetsInMarket(MARKET_ID);
        uint256 totalAssetsAfter = plasmaVault.totalAssets();
        uint256 exchangeRateAfter = plasmaVault.convertToAssets(1e6);

        // Token balances
        assertEq(usdcBefore - usdcAfter, 100_000e6, "Should spend exactly 100k USDC");
        assertGt(mHyperAfter, 90_000e18, "Should receive meaningful mHYPER");

        // Market balance should now reflect the mHYPER holdings in USDC terms
        assertGt(marketBalanceAfter, 0, "Market should have positive balance");
        assertApproxEqRel(marketBalanceAfter, 100_000e6, 0.0001e18, "Market balance should be ~100k USDC");

        // totalAssets and exchangeRate should be stable
        assertApproxEqRel(totalAssetsAfter, totalAssetsBefore, 0.0001e18, "totalAssets stable after deposit");
        assertEq(exchangeRateAfter, exchangeRateBefore, "exchangeRate stable after deposit");
    }

    // ============ Exchange Rate Stability ============

    function testExchangeRate_ShouldBeStableAcrossDepositAndRedeem() public {
        uint256 exchangeRateInitial = plasmaVault.convertToAssets(1e6);
        uint256 totalAssetsInitial = plasmaVault.totalAssets();

        // --- Deposit 200k USDC ---
        {
            uint256 usdcBefore = IERC20(USDC).balanceOf(address(plasmaVault));

            _executeDepositInstant(200_000e6, 180_000e18);

            uint256 usdcAfter = IERC20(USDC).balanceOf(address(plasmaVault));
            assertEq(usdcBefore - usdcAfter, 200_000e6, "Should spend exactly 200k USDC");
            assertGt(IERC20(MHYPER_TOKEN).balanceOf(address(plasmaVault)), 180_000e18, "Should receive meaningful mHYPER");
            assertEq(plasmaVault.convertToAssets(1e6), exchangeRateInitial, "exchangeRate stable after deposit");
            assertApproxEqRel(plasmaVault.totalAssets(), totalAssetsInitial, 0.0001e18, "totalAssets stable after deposit");
        }

        // --- Redeem all mHYPER ---
        {
            uint256 mHyperBalance = IERC20(MHYPER_TOKEN).balanceOf(address(plasmaVault));
            uint256 usdcBefore = IERC20(USDC).balanceOf(address(plasmaVault));

            FuseAction[] memory actions = new FuseAction[](1);
            actions[0] = FuseAction({
                fuse: address(supplyFuse),
                data: abi.encodeWithSignature(
                    "exit((address,uint256,uint256,address,address))",
                    MidasSupplyFuseExitData({
                        mToken: MHYPER_TOKEN,
                        amount: mHyperBalance,
                        minTokenOutAmount: 190_000e6,
                        tokenOut: USDC,
                        instantRedemptionVault: MHYPER_REDEMPTION_VAULT
                    })
                )
            });

            vm.prank(TestAddresses.ALPHA);
            plasmaVault.execute(actions);

            uint256 usdcAfter = IERC20(USDC).balanceOf(address(plasmaVault));

            assertEq(IERC20(MHYPER_TOKEN).balanceOf(address(plasmaVault)), 0, "All mHYPER should be redeemed");
            assertEq(plasmaVault.totalAssetsInMarket(MARKET_ID), 0, "No assets should remain in market");
            assertGt(usdcAfter - usdcBefore, 190_000e6, "Should receive at least 190k USDC (after 0.5% fee)");

            // After full round-trip, exchange rate drops by ~0.2% (0.5% fee on 200k out of 500k)
            assertApproxEqRel(plasmaVault.convertToAssets(1e6), exchangeRateInitial, 0.003e18, "exchangeRate close after round-trip");
            assertApproxEqRel(plasmaVault.totalAssets(), totalAssetsInitial, 0.003e18, "totalAssets close after round-trip");
        }
    }

    // ============ TotalAssets Consistency ============

    function testTotalAssets_ShouldEqualVaultUsdcPlusMarketBalance() public {
        uint256 totalAssetsBefore = plasmaVault.totalAssets();
        uint256 exchangeRateBefore = plasmaVault.convertToAssets(1e6);
        assertEq(totalAssetsBefore, 500_000e6, "Initial totalAssets should be 500k USDC");

        // Deposit 200k USDC into Midas
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(plasmaVault));

        _executeDepositInstant(200_000e6, 180_000e18);

        uint256 vaultUsdc = IERC20(USDC).balanceOf(address(plasmaVault));
        uint256 mHyperBalance = IERC20(MHYPER_TOKEN).balanceOf(address(plasmaVault));
        uint256 marketBalance = plasmaVault.totalAssetsInMarket(MARKET_ID);
        uint256 totalAssetsAfter = plasmaVault.totalAssets();
        uint256 exchangeRateAfter = plasmaVault.convertToAssets(1e6);

        // Token balances
        assertEq(usdcBefore - vaultUsdc, 200_000e6, "Should spend exactly 200k USDC");
        assertEq(vaultUsdc, 300_000e6, "Vault should have 300k USDC");
        assertGt(mHyperBalance, 180_000e18, "Should hold meaningful mHYPER");

        // totalAssets = vault USDC + market balance (in USDC terms)
        assertApproxEqRel(marketBalance, 200_000e6, 0.0001e18, "Market balance should be ~200k USDC");
        assertApproxEqRel(
            totalAssetsAfter,
            vaultUsdc + marketBalance,
            0.001e18,
            "totalAssets should equal vault USDC + market balance"
        );
        assertApproxEqRel(totalAssetsAfter, totalAssetsBefore, 0.0001e18, "totalAssets stable after deposit");
        assertEq(exchangeRateAfter, exchangeRateBefore, "exchangeRate stable after deposit");
    }

    // ============ Small Amount Deposit ============

    function testDepositInstant_SmallAmount_ShouldWork() public {
        uint256 depositAmount = 500e6; // 500 USDC

        uint256 totalAssetsBefore = plasmaVault.totalAssets();
        uint256 exchangeRateBefore = plasmaVault.convertToAssets(1e6);
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(plasmaVault));

        // mHYPER price ~$1.0794, 500 USDC => ~463 mHYPER
        _executeDepositInstant(depositAmount, 450e18);

        uint256 usdcAfter = IERC20(USDC).balanceOf(address(plasmaVault));
        uint256 mHyperBalance = IERC20(MHYPER_TOKEN).balanceOf(address(plasmaVault));
        uint256 totalAssetsAfter = plasmaVault.totalAssets();
        uint256 exchangeRateAfter = plasmaVault.convertToAssets(1e6);
        uint256 totalAssetsInMarketAfter = plasmaVault.totalAssetsInMarket(MARKET_ID);

        // Token balances
        assertEq(usdcBefore - usdcAfter, depositAmount, "Should spend exactly 500 USDC");
        assertGt(mHyperBalance, 450e18, "Should receive meaningful mHYPER for 500 USDC");

        // PlasmaVault state
        assertApproxEqRel(totalAssetsAfter, totalAssetsBefore, 0.0001e18, "totalAssets stable");
        assertEq(exchangeRateAfter, exchangeRateBefore, "exchangeRate stable");
        assertApproxEqRel(totalAssetsInMarketAfter, depositAmount, 0.0001e18, "totalAssetsInMarket reflects deposit");
    }

    // ============ Helper ============

    function _executeDepositInstant(uint256 amount_, uint256 minMTokenOut_) internal {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(supplyFuse),
            data: abi.encodeWithSignature(
                "enter((address,address,uint256,uint256,address))",
                MidasSupplyFuseEnterData({
                    mToken: MHYPER_TOKEN,
                    tokenIn: USDC,
                    amount: amount_,
                    minMTokenAmountOut: minMTokenOut_,
                    depositVault: MHYPER_DEPOSIT_VAULT
                })
            )
        });

        vm.prank(TestAddresses.ALPHA);
        plasmaVault.execute(actions);
    }
}
