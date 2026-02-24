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

/// @title MidasDecimalsIntegrationTest
/// @notice Fork integration tests that demonstrate decimal mismatch bugs in Midas fuses.
///         Midas vault functions expect all amounts in 18 decimals, but IPOR fuses pass
///         amounts in native token decimals (e.g. 6 for USDC). This causes incorrect
///         deposit amounts on-chain.
contract MidasDecimalsIntegrationTest is Test {
    using PriceOracleMiddlewareHelper for PriceOracleMiddleware;
    using PlasmaVaultHelper for PlasmaVault;
    using IporFusionAccessManagerHelper for IporFusionAccessManager;

    // ============ Mainnet Addresses ============
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant MTBILL_TOKEN = 0xDD629E5241CbC5919847783e6C96B2De4754e438;
    address public constant MTBILL_DEPOSIT_VAULT = 0x99361435420711723aF805F08187c9E6bF796683;
    address public constant MTBILL_INSTANT_REDEMPTION_VAULT = 0x569D7dccBF6923350521ecBC28A555A500c4f0Ec;
    address public constant MTBILL_REDEMPTION_VAULT = 0xF6e51d24F4793Ac5e71e0502213a9BBE3A6d4517;
    // Chainlink USDC/USD feed on Ethereum
    address public constant CHAINLINK_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;

    uint256 public constant MARKET_ID = IporFusionMarkets.MIDAS;
    uint256 public constant FORK_BLOCK = 21800000;

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
        bytes32[] memory substrates = new bytes32[](6);
        substrates[0] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.M_TOKEN, substrateAddress: MTBILL_TOKEN})
        );
        substrates[1] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.DEPOSIT_VAULT, substrateAddress: MTBILL_DEPOSIT_VAULT})
        );
        substrates[2] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.ASSET, substrateAddress: USDC})
        );
        substrates[3] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({
                substrateType: MidasSubstrateType.INSTANT_REDEMPTION_VAULT,
                substrateAddress: MTBILL_INSTANT_REDEMPTION_VAULT
            })
        );
        substrates[4] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({
                substrateType: MidasSubstrateType.REDEMPTION_VAULT,
                substrateAddress: MTBILL_REDEMPTION_VAULT
            })
        );
        substrates[5] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.M_TOKEN, substrateAddress: MTBILL_TOKEN})
        );
        plasmaVault.addSubstratesToMarket(MARKET_ID, substrates);

        vm.stopPrank();

        // Fund vault with USDC via user deposit
        deal(USDC, TestAddresses.USER, 200_000e6);
        vm.startPrank(TestAddresses.USER);
        IERC20(USDC).approve(address(plasmaVault), 200_000e6);
        plasmaVault.deposit(200_000e6, TestAddresses.USER);
        vm.stopPrank();

        // Label addresses for traces
        vm.label(address(plasmaVault), "PlasmaVault");
        vm.label(address(supplyFuse), "MidasSupplyFuse");
        vm.label(address(requestSupplyFuse), "MidasRequestSupplyFuse");
        vm.label(address(balanceFuse), "MidasBalanceFuse");
        vm.label(USDC, "USDC");
        vm.label(MTBILL_TOKEN, "mTBILL");
        vm.label(MTBILL_DEPOSIT_VAULT, "MidasDepositVault");
        vm.label(MTBILL_INSTANT_REDEMPTION_VAULT, "MidasInstantRedemptionVault");
        vm.label(MTBILL_REDEMPTION_VAULT, "MidasRedemptionVault");
    }

    // ============ BUG 1: MidasSupplyFuse.enter() passes USDC amount in 6 decimals ============
    // Midas depositInstant expects amountToken in 18 decimals.
    // The fuse passes ERC20.balanceOf() result (6 decimals) directly.
    // Midas internally does: transferAmount = amountToken.convertFromBase18(6) = amountToken / 1e12
    // So 100_000e6 (100k USDC in 6 dec) becomes 100_000e6 / 1e12 = 0.0001 USDC transferred.
    // The deposit either reverts or mints near-zero mTokens.

    function testDepositInstant_ShouldMintCorrectMTbillAmount() public {
        uint256 depositAmount = 100_000e6; // 100,000 USDC

        uint256 usdcBefore = IERC20(USDC).balanceOf(address(plasmaVault));
        uint256 mTbillBefore = IERC20(MTBILL_TOKEN).balanceOf(address(plasmaVault));
        uint256 totalAssetsBefore = plasmaVault.totalAssets();
        uint256 exchangeRateBefore = plasmaVault.convertToAssets(1e6);

        // At block 21800000: mTBILL rate ~1.01733784, USDC/USD ~0.99992427
        // Exact output: 98_295.763774991403052500 mTBILL
        uint256 minMTokenOut = 98_000e18;

        // Build fuse action for instant deposit
        MidasSupplyFuseEnterData memory enterData = MidasSupplyFuseEnterData({
            mToken: MTBILL_TOKEN,
            tokenIn: USDC,
            amount: depositAmount,
            minMTokenAmountOut: minMTokenOut,
            depositVault: MTBILL_DEPOSIT_VAULT
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(supplyFuse),
            data: abi.encodeWithSignature("enter((address,address,uint256,uint256,address))", enterData)
        });

        // Execute deposit via alpha
        vm.prank(TestAddresses.ALPHA);
        plasmaVault.execute(actions);

        uint256 usdcAfter = IERC20(USDC).balanceOf(address(plasmaVault));
        uint256 mTbillAfter = IERC20(MTBILL_TOKEN).balanceOf(address(plasmaVault));
        uint256 totalAssetsAfter = plasmaVault.totalAssets();
        uint256 exchangeRateAfter = plasmaVault.convertToAssets(1e6);
        uint256 totalAssetsInMarketAfter = plasmaVault.totalAssetsInMarket(MARKET_ID);

        // Verify USDC was spent (exact: 100_000 USDC)
        assertEq(usdcBefore - usdcAfter, depositAmount, "Should spend exactly depositAmount USDC");

        // Verify mTBILL received (exact: 98_295.763774991403052500 mTBILL)
        assertEq(mTbillAfter - mTbillBefore, 98_295763774991403052500, "Should receive exact mTBILL amount");

        // Verify PlasmaVault state consistency
        assertApproxEqRel(totalAssetsAfter, totalAssetsBefore, 0.0001e18, "totalAssets stable after deposit");
        assertEq(exchangeRateAfter, exchangeRateBefore, "exchangeRate stable after deposit");
        assertGt(totalAssetsInMarketAfter, 0, "totalAssetsInMarket should reflect mTBILL holdings");
        assertApproxEqRel(totalAssetsInMarketAfter, depositAmount, 0.0001e18, "totalAssetsInMarket ~= deposited amount");
    }

    // ============ BUG 2: MidasRequestSupplyFuse.enter() same decimal issue ============

    function testDepositRequest_ShouldTransferCorrectUsdcAmount() public {
        uint256 depositAmount = 100_000e6; // 100,000 USDC

        uint256 usdcBefore = IERC20(USDC).balanceOf(address(plasmaVault));
        uint256 totalAssetsBefore = plasmaVault.totalAssets();
        uint256 exchangeRateBefore = plasmaVault.convertToAssets(1e6);

        // Build fuse action for deposit request
        MidasRequestSupplyFuseEnterData memory enterData = MidasRequestSupplyFuseEnterData({
            mToken: MTBILL_TOKEN,
            tokenIn: USDC,
            amount: depositAmount,
            depositVault: MTBILL_DEPOSIT_VAULT
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(requestSupplyFuse),
            data: abi.encodeWithSignature("enter((address,address,uint256,address))", enterData)
        });

        // Execute deposit request via alpha
        vm.prank(TestAddresses.ALPHA);
        plasmaVault.execute(actions);

        uint256 usdcAfter = IERC20(USDC).balanceOf(address(plasmaVault));
        uint256 totalAssetsAfter = plasmaVault.totalAssets();
        uint256 exchangeRateAfter = plasmaVault.convertToAssets(1e6);
        uint256 totalAssetsInMarketAfter = plasmaVault.totalAssetsInMarket(MARKET_ID);

        // Verify exact USDC transferred
        assertEq(usdcBefore - usdcAfter, depositAmount, "Should transfer exactly depositAmount USDC");

        // No mTBILL yet (async request, pending admin approval)
        assertEq(IERC20(MTBILL_TOKEN).balanceOf(address(plasmaVault)), 0, "No mTBILL yet (pending request)");

        // totalAssetsInMarket should reflect pending deposit value
        assertGt(totalAssetsInMarketAfter, 0, "totalAssetsInMarket should include pending deposit");

        // totalAssets should be stable (USDC left vault, pending deposit tracked in market)
        assertApproxEqRel(totalAssetsAfter, totalAssetsBefore, 0.0001e18, "totalAssets stable after deposit request");
        assertEq(exchangeRateAfter, exchangeRateBefore, "exchangeRate stable after deposit request");
    }

    // ============ BUG 3: Small amounts get rounded to zero ============
    // When depositing a small USDC amount (e.g. 1000 USDC = 1000e6),
    // Midas sees 1000e6 as a value in 18 decimals = 0.000000001 tokens.
    // convertFromBase18(6) => 1000e6 / 1e12 = 0, transfer fails or is zero.

    function testDepositInstant_SmallAmount_ShouldNotLoseFunds() public {
        uint256 depositAmount = 1_000e6; // 1,000 USDC

        uint256 usdcBefore = IERC20(USDC).balanceOf(address(plasmaVault));
        uint256 totalAssetsBefore = plasmaVault.totalAssets();
        uint256 exchangeRateBefore = plasmaVault.convertToAssets(1e6);

        // At block 21800000: exact output 982.957637749914030525 mTBILL
        uint256 minMTokenOut = 980e18;

        MidasSupplyFuseEnterData memory enterData = MidasSupplyFuseEnterData({
            mToken: MTBILL_TOKEN,
            tokenIn: USDC,
            amount: depositAmount,
            minMTokenAmountOut: minMTokenOut,
            depositVault: MTBILL_DEPOSIT_VAULT
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(supplyFuse),
            data: abi.encodeWithSignature("enter((address,address,uint256,uint256,address))", enterData)
        });

        vm.prank(TestAddresses.ALPHA);
        plasmaVault.execute(actions);

        uint256 usdcAfter = IERC20(USDC).balanceOf(address(plasmaVault));
        uint256 mTbillAfter = IERC20(MTBILL_TOKEN).balanceOf(address(plasmaVault));
        uint256 totalAssetsAfter = plasmaVault.totalAssets();
        uint256 exchangeRateAfter = plasmaVault.convertToAssets(1e6);
        uint256 totalAssetsInMarketAfter = plasmaVault.totalAssetsInMarket(MARKET_ID);

        // Verify exact amounts (exact: 982.957637749914030525 mTBILL)
        assertEq(usdcBefore - usdcAfter, depositAmount, "Should spend exactly depositAmount USDC");
        assertEq(mTbillAfter, 982957637749914030525, "Should receive exact mTBILL amount");

        // Verify PlasmaVault state consistency
        assertApproxEqRel(totalAssetsAfter, totalAssetsBefore, 0.0001e18, "totalAssets stable after small deposit");
        assertEq(exchangeRateAfter, exchangeRateBefore, "exchangeRate stable after small deposit");
        assertApproxEqRel(totalAssetsInMarketAfter, depositAmount, 0.001e18, "totalAssetsInMarket ~= deposited amount");
    }

    // ============ BUG 4: Approval mismatch ============
    // The fuse approves `finalAmount` in native decimals (e.g. 100_000e6) to Midas vault.
    // Midas internally converts amountToken (which it receives in 6 dec instead of 18 dec)
    // from base18 to native decimals: 100_000e6 / 1e12 = 0.0001 USDC.
    // So Midas tries to transferFrom 0.0001 USDC but approval is 100_000e6.
    // The approval is left dirty (not fully consumed), wasting gas on cleanup.
    // This test verifies the full amount should be consumed.

    function testDepositInstant_ApprovalShouldBeFullyConsumed() public {
        uint256 depositAmount = 100_000e6;

        uint256 totalAssetsBefore = plasmaVault.totalAssets();
        uint256 exchangeRateBefore = plasmaVault.convertToAssets(1e6);

        MidasSupplyFuseEnterData memory enterData = MidasSupplyFuseEnterData({
            mToken: MTBILL_TOKEN,
            tokenIn: USDC,
            amount: depositAmount,
            minMTokenAmountOut: 98_000e18,
            depositVault: MTBILL_DEPOSIT_VAULT
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(supplyFuse),
            data: abi.encodeWithSignature("enter((address,address,uint256,uint256,address))", enterData)
        });

        vm.prank(TestAddresses.ALPHA);
        plasmaVault.execute(actions);

        uint256 vaultUsdcBalance = IERC20(USDC).balanceOf(address(plasmaVault));
        uint256 totalAssetsAfter = plasmaVault.totalAssets();
        uint256 exchangeRateAfter = plasmaVault.convertToAssets(1e6);

        // Verify USDC was fully consumed: 200k - 100k = 100k remaining
        assertEq(vaultUsdcBalance, 100_000e6, "Vault should have exactly 100k USDC remaining");

        // Verify mTBILL was received
        assertGt(IERC20(MTBILL_TOKEN).balanceOf(address(plasmaVault)), 98_000e18, "Should receive mTBILL");

        // Verify PlasmaVault state consistency
        assertApproxEqRel(totalAssetsAfter, totalAssetsBefore, 0.0001e18, "totalAssets stable after deposit");
        assertEq(exchangeRateAfter, exchangeRateBefore, "exchangeRate stable after deposit");
    }
}
