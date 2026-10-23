// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IPriceOracleMiddleware} from "../../../contracts/price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVault, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {RewardsClaimManager} from "../../../contracts/managers/rewards/RewardsClaimManager.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {AssetDistributionProtectionLib, MarketLimit} from "../../../contracts/libraries/AssetDistributionProtectionLib.sol";

import {
    HyperCoreDepositFuse,
    HyperCoreDepositFuseEnterData
} from "../../../contracts/fuses/hypercore/HyperCoreDepositFuse.sol";
import {HyperCoreBalanceFuse} from "../../../contracts/fuses/hypercore/HyperCoreBalanceFuse.sol";
import {HyperCoreLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreLib.sol";
import {HyperCoreSubstrateLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreSubstrateLib.sol";
import {HyperCorePendingLib} from "../../../contracts/fuses/hypercore/lib/HyperCorePendingLib.sol";

import {HyperCoreTestHelper, HyperCoreMockUsdc} from "./HyperCoreTestHelper.sol";
import {HyperCoreMockState} from "./mocks/MockHyperCorePrecompiles.sol";
import {MockCoreDepositWallet} from "./mocks/MockCoreDepositWallet.sol";

import {PlasmaVaultHelper, DeployMinimalPlasmaVaultParams} from "../../test_helpers/PlasmaVaultHelper.sol";
import {IporFusionAccessManagerHelper} from "../../test_helpers/IporFusionAccessManagerHelper.sol";
import {TestAddresses} from "../../test_helpers/TestAddresses.sol";

/// @title HyperCoreTestPriceOracle
/// @notice Minimal `IPriceOracleMiddleware` test double whose `QUOTE_CURRENCY` matches the real
///         `PriceOracleMiddleware` (`0x...0348`, the Chainlink USD quote sentinel) so
///         `PlasmaVaultGovernance.setPriceOracleMiddleware` (which enforces a matching quote
///         currency) accepts it as a drop-in replacement for the vault's deployed middleware.
contract HyperCoreTestPriceOracle is IPriceOracleMiddleware {
    mapping(address => uint256) public prices;
    mapping(address => uint256) public priceDecimals;

    function setAssetPriceWithDecimals(address asset_, uint256 price_, uint256 decimals_) external {
        prices[asset_] = price_;
        priceDecimals[asset_] = decimals_;
    }

    function getAssetPrice(address asset_) external view returns (uint256 assetPrice, uint256 decimals) {
        assetPrice = prices[asset_];
        decimals = priceDecimals[asset_];
    }

    function getAssetsPrices(
        address[] calldata assets_
    ) external view returns (uint256[] memory assetPrices, uint256[] memory decimalsList) {
        assetPrices = new uint256[](assets_.length);
        decimalsList = new uint256[](assets_.length);
        for (uint256 i; i < assets_.length; ++i) {
            assetPrices[i] = prices[assets_[i]];
            decimalsList[i] = priceDecimals[assets_[i]];
        }
    }

    function getSourceOfAssetPrice(address) external pure returns (address) {
        return address(0);
    }

    function setAssetsPricesSources(address[] calldata, address[] calldata) external {}

    // solhint-disable-next-line func-name-mixedcase
    function QUOTE_CURRENCY() external pure returns (address) {
        return address(0x0000000000000000000000000000000000000348);
    }

    // solhint-disable-next-line func-name-mixedcase
    function QUOTE_CURRENCY_DECIMALS() external pure returns (uint256) {
        return 18;
    }
}

/// @dev Unit tests for HyperCoreDepositFuse, wired against a real minimal PlasmaVault (not
///      PlasmaVaultMock) since the fuse reads/writes namespaced vault storage libraries
///      (HyperCorePendingLib, HyperCoreSubstrateLib) that only behave correctly in a genuine
///      delegatecall context reachable through PlasmaVault.execute().
contract HyperCoreDepositFuseTest is Test {
    uint256 private constant MARKET_ID = 55;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.hypercore.pending")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PENDING_SLOT = 0xff3841d45e92b4b113213ebf16e5e18527d87d1b739008d460c4a8565edaf200;

    HyperCoreMockState private core;
    PlasmaVault private vault;
    HyperCoreMockUsdc private usdc;
    HyperCoreTestPriceOracle private oracle;
    HyperCoreDepositFuse private depositFuse;
    HyperCoreBalanceFuse private balanceFuse;
    MockCoreDepositWallet private depositWallet;

    function setUp() public {
        core = HyperCoreTestHelper.etchPrecompiles(vm);

        vm.startPrank(TestAddresses.ATOMIST);
        address withdrawManager;
        (vault, withdrawManager, usdc, ) = HyperCoreTestHelper.deployVaultWithHyperCoreMarket(TestAddresses.ATOMIST);
        IporFusionAccessManager accessManager = PlasmaVaultHelper.accessManagerOf(vault);
        IporFusionAccessManagerHelper.setupInitRoles(
            accessManager,
            vault,
            withdrawManager,
            address(new RewardsClaimManager(address(accessManager), address(vault)))
        );
        vm.stopPrank();

        oracle = new HyperCoreTestPriceOracle();
        vm.prank(TestAddresses.ATOMIST);
        PlasmaVaultGovernance(address(vault)).setPriceOracleMiddleware(address(oracle));
        oracle.setAssetPriceWithDecimals(address(usdc), 1e8, 8);

        depositFuse = new HyperCoreDepositFuse(MARKET_ID);
        balanceFuse = new HyperCoreBalanceFuse(MARKET_ID);

        vm.startPrank(TestAddresses.FUSE_MANAGER);
        address[] memory fuses = new address[](1);
        fuses[0] = address(depositFuse);
        PlasmaVaultHelper.addFusesToVault(vault, fuses);
        PlasmaVaultHelper.addBalanceFusesToVault(vault, MARKET_ID, address(balanceFuse));
        vm.stopPrank();

        // Token 0 (USDC) is routed through the CoreDepositWallet on Hyperliquid mainnet: its
        // `tokenInfo(0).evmContract` is the wallet's proxy address, not the USDC ERC20 itself.
        // `wallet.token()` resolves to the granted evmAsset (the test USDC).
        depositWallet = new MockCoreDepositWallet(address(usdc));
        core.setTokenInfo(
            HyperCoreLib.USDC_TOKEN,
            HyperCoreMockState.TokenInfo({
                name: "USDC",
                spots: new uint64[](0),
                deployerTradingFeeShare: 0,
                deployer: address(0),
                evmContract: address(depositWallet),
                szDecimals: 8,
                weiDecimals: 8,
                evmExtraWeiDecimals: -2
            })
        );

        _grantSpotToken(HyperCoreLib.USDC_TOKEN, address(usdc));

        usdc.mint(address(vault), 1_000_000e6);
    }

    function testEnterTransfersRoundedAmountAndEnqueuesInTransitCredit() public {
        // Unactivated account: live value S = 0.
        assertFalse(core.getCoreUserExists(address(vault)));

        uint256 depositAmount = 1_000e6; // 1000 USDC, 6 decimals
        uint256 vaultBalanceBefore = usdc.balanceOf(address(vault));
        uint256 walletBalanceBefore = usdc.balanceOf(address(depositWallet));

        // Events emitted during a delegatecall are attributed to the calling contract (the vault),
        // not to the fuse's own address, since `address(this)` and the log's emitter both stay the
        // caller's throughout a delegatecall.
        vm.expectEmit(true, true, true, true, address(vault));
        emit HyperCoreDepositFuse.HyperCoreDepositFuseEnter(
            address(depositFuse), HyperCoreLib.USDC_TOKEN, address(usdc), depositAmount, uint64(depositAmount * 100)
        );
        _execute(depositAmount);

        assertEq(vaultBalanceBefore - usdc.balanceOf(address(vault)), depositAmount, "USDC left the vault");
        assertEq(
            usdc.balanceOf(address(depositWallet)) - walletBalanceBefore,
            depositAmount,
            "USDC landed at the CoreDepositWallet"
        );
        assertEq(usdc.allowance(address(vault), address(depositWallet)), 0, "approval reset to 0 after deposit");
        assertEq(depositWallet.depositForCallCount(), 1, "depositFor called exactly once");
        assertEq(depositWallet.lastRecipient(), address(vault), "deposit credited to the vault");
        assertEq(depositWallet.lastAmount(), depositAmount, "depositFor amount");
        assertEq(depositWallet.lastDestinationDex(), HyperCoreLib.SPOT_DEX, "depositFor routes to the spot dex");

        (uint64 pendingUntil, , , uint8 actionClass, , , bytes32 payloadHash, uint256 cachedValueWad) = _readPending();
        assertTrue(pendingUntil > 0, "pending set");
        assertEq(actionClass, uint8(HyperCorePendingLib.ActionClass.Transfer));
        assertEq(payloadHash, keccak256(abi.encode(HyperCoreLib.USDC_TOKEN, depositAmount)));
        // S = 0 (unactivated), A = $1000 in WAD.
        assertEq(cachedValueWad, 1_000e18, "cached value is S + A with S = 0");
    }

    /// @dev A token other than USDC (index 9 here) still uses the generic transfer path: no wallet
    ///      involved, funds land directly at the token's derived Core system address.
    function testEnterGenericTokenStillTransfersToSystemAddress() public {
        core.setTokenInfo(
            9,
            HyperCoreMockState.TokenInfo({
                name: "OTHER",
                spots: new uint64[](0),
                deployerTradingFeeShare: 0,
                deployer: address(0),
                evmContract: address(usdc),
                szDecimals: 8,
                weiDecimals: 6,
                evmExtraWeiDecimals: 0
            })
        );
        _grantSpotToken(9, address(usdc));
        // IL-8890: a non-USDC deposit requires an existing Core account.
        core.setCoreUserExists(address(vault), true);

        uint256 vaultBalanceBefore = usdc.balanceOf(address(vault));
        uint256 systemAddressBalanceBefore = usdc.balanceOf(HyperCoreLib.systemAddress(9));

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(depositFuse),
            data: abi.encodeWithSignature("enter((uint64,uint256))", HyperCoreDepositFuseEnterData({tokenIndex: 9, amount: 1_000e6}))
        });
        vm.prank(TestAddresses.ALPHA);
        vault.execute(actions);

        assertEq(vaultBalanceBefore - usdc.balanceOf(address(vault)), 1_000e6, "USDC left the vault");
        assertEq(
            usdc.balanceOf(HyperCoreLib.systemAddress(9)) - systemAddressBalanceBefore,
            1_000e6,
            "USDC landed at the token's system address, not the wallet"
        );
    }

    function testEnterRevertsWhenDepositWalletTokenMismatch() public {
        // Wallet reports a different underlying token than the granted evmAsset.
        MockCoreDepositWallet wrongWallet = new MockCoreDepositWallet(makeAddr("differentEvmAsset"));
        core.setTokenInfo(
            HyperCoreLib.USDC_TOKEN,
            HyperCoreMockState.TokenInfo({
                name: "USDC",
                spots: new uint64[](0),
                deployerTradingFeeShare: 0,
                deployer: address(0),
                evmContract: address(wrongWallet),
                szDecimals: 8,
                weiDecimals: 8,
                evmExtraWeiDecimals: -2
            })
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                HyperCoreDepositFuse.HyperCoreDepositFuseDepositWalletTokenMismatch.selector,
                address(wrongWallet),
                makeAddr("differentEvmAsset"),
                address(usdc)
            )
        );
        _execute(1e6);
    }

    function testEnterRevertsWhenDepositWalletPaused() public {
        depositWallet.setPaused(true);

        vm.expectRevert(HyperCoreDepositFuse.HyperCoreDepositFuseDepositWalletUnavailable.selector);
        _execute(1e6);
    }

    function testEnterRevertsWhenDepositWalletTokenReadReverts() public {
        vm.mockCallRevert(address(depositWallet), abi.encodeWithSelector(depositWallet.token.selector), "");

        vm.expectRevert(HyperCoreDepositFuse.HyperCoreDepositFuseDepositWalletUnavailable.selector);
        _execute(1e6);
    }

    function testEnterRevertsWhenDepositWalletPausedReadReverts() public {
        vm.mockCallRevert(address(depositWallet), abi.encodeWithSelector(depositWallet.paused.selector), "");

        vm.expectRevert(HyperCoreDepositFuse.HyperCoreDepositFuseDepositWalletUnavailable.selector);
        _execute(1e6);
    }

    function testEnterRevertsWhenTokenNotGranted() public {
        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreDepositFuse.HyperCoreDepositFuseUnsupportedToken.selector, uint64(7))
        );
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(depositFuse),
            data: abi.encodeWithSignature(
                "enter((uint64,uint256))", HyperCoreDepositFuseEnterData({tokenIndex: 7, amount: 1e6})
            )
        });
        vm.prank(TestAddresses.ALPHA);
        vault.execute(actions);
    }

    function testEnterRevertsWhenEvmAssetMismatch() public {
        // Grant a different token index whose Core-registered evmContract does not match the grant.
        core.setTokenInfo(
            5,
            HyperCoreMockState.TokenInfo({
                name: "OTHER",
                spots: new uint64[](0),
                deployerTradingFeeShare: 0,
                deployer: address(0),
                evmContract: makeAddr("differentEvmAsset"),
                szDecimals: 8,
                weiDecimals: 8,
                evmExtraWeiDecimals: 0
            })
        );
        _grantSpotToken(5, address(usdc));

        vm.expectRevert(HyperCoreDepositFuse.HyperCoreDepositFuseTokenMismatch.selector);
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(depositFuse),
            data: abi.encodeWithSignature(
                "enter((uint64,uint256))", HyperCoreDepositFuseEnterData({tokenIndex: 5, amount: 1e6})
            )
        });
        vm.prank(TestAddresses.ALPHA);
        vault.execute(actions);
    }

    function testEnterRevertsForNativeTokenWithNoEvmContract() public {
        // Token 150 (HYPE) has evmContract == address(0) by mock default.
        _grantSpotToken(150, address(0));

        vm.expectRevert(HyperCoreDepositFuse.HyperCoreDepositFuseTokenMismatch.selector);
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(depositFuse),
            data: abi.encodeWithSignature(
                "enter((uint64,uint256))", HyperCoreDepositFuseEnterData({tokenIndex: 150, amount: 1e6})
            )
        });
        vm.prank(TestAddresses.ALPHA);
        vault.execute(actions);
    }

    function testSecondDepositInSameExecuteReverts() public {
        FuseAction[] memory actions = new FuseAction[](2);
        actions[0] = FuseAction({
            fuse: address(depositFuse),
            data: abi.encodeWithSignature(
                "enter((uint64,uint256))",
                HyperCoreDepositFuseEnterData({tokenIndex: HyperCoreLib.USDC_TOKEN, amount: 1e6})
            )
        });
        actions[1] = FuseAction({
            fuse: address(depositFuse),
            data: abi.encodeWithSignature(
                "enter((uint64,uint256))",
                HyperCoreDepositFuseEnterData({tokenIndex: HyperCoreLib.USDC_TOKEN, amount: 1e6})
            )
        });

        // The first deposit enqueues the window (default 2 seconds), so the second one reverts with that deadline.
        vm.expectRevert(
            abi.encodeWithSelector(HyperCorePendingLib.HyperCoreActionPending.selector, uint64(block.timestamp + 2))
        );
        vm.prank(TestAddresses.ALPHA);
        vault.execute(actions);
    }

    function testEnterIsNoOpWhenAmountBelowCoreRepresentableUnit() public {
        // Grant a token whose Core wei is coarser than the EVM asset: evmExtraWeiDecimals = 2 means
        // dividing by 100 to reach Core precision, so any amount < 100 rounds to zero Core wei.
        // The mock asset has 6 decimals, so the Hyperliquid relation EVM = wei + extra gives weiDecimals = 4.
        core.setTokenInfo(
            9,
            HyperCoreMockState.TokenInfo({
                name: "COARSE",
                spots: new uint64[](0),
                deployerTradingFeeShare: 0,
                deployer: address(0),
                evmContract: address(usdc),
                szDecimals: 8,
                weiDecimals: 4,
                evmExtraWeiDecimals: 2
            })
        );
        _grantSpotToken(9, address(usdc));

        uint256 vaultBalanceBefore = usdc.balanceOf(address(vault));

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(depositFuse),
            data: abi.encodeWithSignature("enter((uint64,uint256))", HyperCoreDepositFuseEnterData({tokenIndex: 9, amount: 50}))
        });
        vm.prank(TestAddresses.ALPHA);
        vault.execute(actions);

        assertEq(usdc.balanceOf(address(vault)), vaultBalanceBefore, "no transfer happened");
        (uint64 pendingUntil, , , , , , , ) = _readPending();
        assertEq(pendingUntil, 0, "no pending action enqueued");
    }

    function testEnterRoundsDownNonRepresentableAmountAndKeepsRemainder() public {
        // The mock asset has 6 decimals, so the Hyperliquid relation EVM = wei + extra gives weiDecimals = 4.
        core.setTokenInfo(
            9,
            HyperCoreMockState.TokenInfo({
                name: "COARSE",
                spots: new uint64[](0),
                deployerTradingFeeShare: 0,
                deployer: address(0),
                evmContract: address(usdc),
                szDecimals: 8,
                weiDecimals: 4,
                evmExtraWeiDecimals: 2
            })
        );
        _grantSpotToken(9, address(usdc));
        // IL-8890: a non-USDC deposit requires an existing Core account.
        core.setCoreUserExists(address(vault), true);
        oracle.setAssetPriceWithDecimals(address(usdc), 1e8, 8);

        uint256 vaultBalanceBefore = usdc.balanceOf(address(vault));
        uint256 requestedAmount = 12_345; // rounds down to 12_300 (factor 100)

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(depositFuse),
            data: abi.encodeWithSignature(
                "enter((uint64,uint256))", HyperCoreDepositFuseEnterData({tokenIndex: 9, amount: requestedAmount})
            )
        });
        vm.prank(TestAddresses.ALPHA);
        vault.execute(actions);

        uint256 transferred = vaultBalanceBefore - usdc.balanceOf(address(vault));
        assertEq(transferred, 12_300, "transferred amount rounded down to the Core-representable unit");

        // The in-transit credit is priced on the rounded amount (12_300 units = 0.0123 USD), not on the requested one.
        (, , , , , , , uint256 cachedValueWad) = _readPending();
        assertEq(cachedValueWad, 1.23e16, "cached value is S + the rounded credit with S = 0");
        // Existing account without a balance: expected balance is baseline 0 + 123 Core wei, no activation allowance.
        (, uint64 tokenIndex, , , uint256 expectedBalance) = _readEffect();
        assertEq(tokenIndex, 9);
        assertEq(expectedBalance, 123, "expected Core balance is the rounded amount in Core wei");

        // Once the 123 Core wei land, the live value equals the cached credit: no valuation jump at settlement.
        core.setSpotBalance(address(vault), 9, _spot(123));
        _openTimeAndL1Gates();
        // `_isBlocked` probes a USDC deposit, and the grants replace the substrate list: keep token 9 for the valuation.
        vm.prank(TestAddresses.FUSE_MANAGER);
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = HyperCoreSubstrateLib.encodeSpotToken(HyperCoreLib.USDC_TOKEN, address(usdc));
        substrates[1] = HyperCoreSubstrateLib.encodeSpotToken(9, address(usdc));
        PlasmaVaultHelper.addSubstratesToMarket(vault, MARKET_ID, substrates);
        assertFalse(_isBlocked(), "credit landed and the pending window is over");
        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = MARKET_ID;
        vm.prank(TestAddresses.ATOMIST);
        vault.updateMarketsBalances(marketIds);
        assertEq(vault.totalAssetsInMarket(MARKET_ID), 12_300, "stored market value equals the cached credit");
    }

    function testEnterRevertsOnZeroWindowConfig() public {
        // grantMarketSubstrates replaces the whole array, so re-grant the USDC SpotToken alongside
        // the window config in the same call.
        vm.prank(TestAddresses.FUSE_MANAGER);
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = HyperCoreSubstrateLib.encodeSpotToken(HyperCoreLib.USDC_TOKEN, address(usdc));
        substrates[1] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.WindowTransferSeconds, 0);
        PlasmaVaultHelper.addSubstratesToMarket(vault, MARKET_ID, substrates);

        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreDepositFuse.HyperCoreDepositFuseInvalidWindow.selector, uint240(0))
        );
        _execute(1e6);
    }

    function testEnterRevertsOnWindowOverflowingUint64() public {
        uint240 overflowingWindow = uint240(type(uint64).max) + 1;
        vm.prank(TestAddresses.FUSE_MANAGER);
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = HyperCoreSubstrateLib.encodeSpotToken(HyperCoreLib.USDC_TOKEN, address(usdc));
        substrates[1] = HyperCoreSubstrateLib.encodeConfig(
            HyperCoreSubstrateLib.ConfigKey.WindowTransferSeconds, overflowingWindow
        );
        PlasmaVaultHelper.addSubstratesToMarket(vault, MARKET_ID, substrates);

        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreDepositFuse.HyperCoreDepositFuseInvalidWindow.selector, overflowingWindow)
        );
        _execute(1e6);
    }

    /// @dev C = S + A here (S = 0, A = the in-transit deposit value), which exactly offsets the live
    ///      underlying balance leaving the vault, so totalAssets() must be unchanged (within
    ///      1-wei rounding) across the execute() that performs the deposit and refreshes market 55.
    function testDepositIsNavNeutralAcrossExecute() public {
        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 totalSupplyBefore = vault.totalSupply();

        _execute(1_000e6);

        assertApproxEqAbs(vault.totalAssets(), totalAssetsBefore, 1, "deposit must be NAV-neutral");
        assertEq(vault.totalSupply(), totalSupplyBefore, "no shares minted by execute()");
    }

    /// @dev AssetDistributionProtectionLib.checkLimits() runs on the *cached* market value C written by
    ///      the post-execute balance refresh, not some other number: a 0% cap on market 55 must reject
    ///      any deposit that leaves a nonzero C behind.
    function testMarketLimitIsEvaluatedAgainstCachedValue() public {
        MarketLimit[] memory limits = new MarketLimit[](1);
        limits[0] = MarketLimit({marketId: MARKET_ID, limitInPercentage: 0});
        vm.startPrank(TestAddresses.ATOMIST);
        PlasmaVaultGovernance(address(vault)).setupMarketsLimits(limits);
        PlasmaVaultGovernance(address(vault)).activateMarketsLimits();
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(AssetDistributionProtectionLib.MarketLimitExceeded.selector, MARKET_ID, 1_000e6, 0)
        );
        _execute(1_000e6);
    }

    // ------------------------------------------------------------------
    // Effect-based settlement (IL-8526)
    // ------------------------------------------------------------------

    function testFirstUsdcDepositExpectsCreditNetOfDefaultActivationAllowance() public {
        _execute(1_000e6);
        (uint8 kind, uint64 tokenIndex, , uint64 timeoutAt, uint256 expected) = _readEffect();
        (uint64 pendingUntil, , , , , , , ) = _readPending();
        assertEq(kind, HyperCorePendingLib.EFFECT_CORE_SPOT);
        assertEq(tokenIndex, HyperCoreLib.USDC_TOKEN);
        assertEq(expected, 1_000e8 - 1e8, "baseline 0 + coreWei - 1 USDC default allowance");
        assertEq(timeoutAt, pendingUntil + 600, "default timeout is 600 seconds after the window");

        _openTimeAndL1Gates();
        assertTrue(_isBlocked(), "no credit yet");

        // A dust donation that merely activates the account must not settle the deposit.
        core.setCoreUserExists(address(vault), true);
        core.setSpotBalance(address(vault), HyperCoreLib.USDC_TOKEN, _spot(0.5e8));
        assertTrue(_isBlocked(), "dust donation does not settle");

        core.setSpotBalance(address(vault), HyperCoreLib.USDC_TOKEN, _spot(1_000e8 - 1e8 - 1));
        assertTrue(_isBlocked(), "one wei short of the net credit");

        core.setSpotBalance(address(vault), HyperCoreLib.USDC_TOKEN, _spot(1_000e8 - 1e8));
        assertFalse(_isBlocked(), "net credit landed");
    }

    function testDepositSettlesOnTimeoutWithoutCredit() public {
        // The never-credited deposit leaves the cached value far above the live Core value; raise the
        // NAV jump breaker (IL-8533) so this test keeps isolating the gate timeout.
        _grantUsdcWithConfig(HyperCoreSubstrateLib.ConfigKey.MaxNavJumpBps, 1_000_000);
        _execute(1_000e6);
        (uint64 pendingUntil, , , , , , , ) = _readPending();
        core.setL1BlockNumber(core.getL1BlockNumber() + 1);
        vm.warp(pendingUntil + 599);
        assertTrue(_isBlocked());
        vm.warp(pendingUntil + 600);
        assertFalse(_isBlocked(), "timeout waives the effect requirement");
    }

    function testDepositIntoExistingAccountExpectsBaselinePlusFullCredit() public {
        core.setCoreUserExists(address(vault), true);
        core.setSpotBalance(address(vault), HyperCoreLib.USDC_TOKEN, _spot(200e8));
        _execute(1_000e6);
        (uint8 kind, , , , uint256 expected) = _readEffect();
        assertEq(kind, HyperCorePendingLib.EFFECT_CORE_SPOT);
        assertEq(expected, 1_200e8, "no activation allowance for an existing account");

        _openTimeAndL1Gates();
        core.setSpotBalance(address(vault), HyperCoreLib.USDC_TOKEN, _spot(1_199e8));
        assertTrue(_isBlocked());
        core.setSpotBalance(address(vault), HyperCoreLib.USDC_TOKEN, _spot(1_200e8));
        assertFalse(_isBlocked());
    }

    function testCustomActivationAllowanceConfig() public {
        _grantUsdcWithConfig(HyperCoreSubstrateLib.ConfigKey.ActivationFeeAllowanceUsdcWei, 5e8);
        _execute(1_000e6);
        (, , , , uint256 expected) = _readEffect();
        assertEq(expected, 995e8);
    }

    function testActivationAllowanceCappedAtDepositAmount() public {
        _grantUsdcWithConfig(HyperCoreSubstrateLib.ConfigKey.ActivationFeeAllowanceUsdcWei, 5_000e8);
        _execute(1_000e6);
        (, , , , uint256 expected) = _readEffect();
        assertEq(expected, 0, "allowance never exceeds the credit itself");
    }

    function testZeroActivationAllowanceExpectsFullCredit() public {
        _grantUsdcWithConfig(HyperCoreSubstrateLib.ConfigKey.ActivationFeeAllowanceUsdcWei, 0);
        _execute(1_000e6);
        (, , , , uint256 expected) = _readEffect();
        assertEq(expected, 1_000e8);
    }

    function testEnterRevertsWhenActivationAllowanceDoesNotFitUint64() public {
        uint240 tooBig = uint240(type(uint64).max) + 1;
        _grantUsdcWithConfig(HyperCoreSubstrateLib.ConfigKey.ActivationFeeAllowanceUsdcWei, tooBig);
        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreDepositFuse.HyperCoreDepositFuseInvalidActivationFeeAllowance.selector, tooBig)
        );
        _execute(1e6);
    }

    function testCustomTransferTimeout() public {
        _grantUsdcWithConfig(HyperCoreSubstrateLib.ConfigKey.TransferTimeoutSeconds, 60);
        _execute(1_000e6);
        (, , , uint64 timeoutAt, ) = _readEffect();
        (uint64 pendingUntil, , , , , , , ) = _readPending();
        assertEq(timeoutAt, pendingUntil + 60);
    }

    function testEnterRevertsOnZeroTimeoutConfig() public {
        _grantUsdcWithConfig(HyperCoreSubstrateLib.ConfigKey.TransferTimeoutSeconds, 0);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreDepositFuse.HyperCoreDepositFuseInvalidTimeout.selector, uint240(0)));
        _execute(1e6);
    }

    function testEnterRevertsOnTimeoutBelowMinimum() public {
        _grantUsdcWithConfig(HyperCoreSubstrateLib.ConfigKey.TransferTimeoutSeconds, 59);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreDepositFuse.HyperCoreDepositFuseInvalidTimeout.selector, uint240(59)));
        _execute(1e6);
    }

    function testEnterRevertsOnTimeoutOverflowingUint64() public {
        uint240 tooBig = uint240(type(uint64).max) + 1;
        _grantUsdcWithConfig(HyperCoreSubstrateLib.ConfigKey.TransferTimeoutSeconds, tooBig);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreDepositFuse.HyperCoreDepositFuseInvalidTimeout.selector, tooBig));
        _execute(1e6);
    }

    /// @dev IL-8890: a non-USDC token into a missing Core account reverts before any transfer.
    function testNonUsdcDepositRevertsWhileCoreAccountMissing() public {
        _setGenericToken9();
        // Sentinel: any ERC20 transfer of the token-9 asset (the generic system-address path) reverts with
        // TRANSFER_CALLED, so the expected error below proves the guard fires before `_transferToCore`.
        vm.mockCallRevert(address(usdc), abi.encodeWithSelector(usdc.transfer.selector), bytes("TRANSFER_CALLED"));
        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreDepositFuse.HyperCoreDepositFuseCoreAccountNotActivated.selector, uint64(9))
        );
        _executeToken9(1_000e6);
    }

    /// @dev IL-8890: with an existing account a non-USDC deposit expects baseline + full credit (no allowance).
    function testNonUsdcDepositIntoExistingAccountExpectsBaselinePlusFullCredit() public {
        _setGenericToken9();
        core.setCoreUserExists(address(vault), true);
        core.setSpotBalance(address(vault), 9, _spot(50e6));
        _executeToken9(1_000e6);
        (uint8 kind, uint64 tokenIndex, , , uint256 expected) = _readEffect();
        assertEq(kind, HyperCorePendingLib.EFFECT_CORE_SPOT);
        assertEq(tokenIndex, 9);
        assertEq(expected, 1_050e6, "baseline + full credit, no activation allowance");
    }

    function _setGenericToken9() private {
        core.setTokenInfo(
            9,
            HyperCoreMockState.TokenInfo({
                name: "OTHER",
                spots: new uint64[](0),
                deployerTradingFeeShare: 0,
                deployer: address(0),
                evmContract: address(usdc),
                szDecimals: 8,
                weiDecimals: 6,
                evmExtraWeiDecimals: 0
            })
        );
        _grantSpotToken(9, address(usdc));
    }

    function _executeToken9(uint256 amount_) private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(depositFuse),
            data: abi.encodeWithSignature(
                "enter((uint64,uint256))",
                HyperCoreDepositFuseEnterData({tokenIndex: 9, amount: amount_})
            )
        });
        vm.prank(TestAddresses.ALPHA);
        vault.execute(actions);
    }

    function _spot(uint64 total_) private pure returns (HyperCoreMockState.SpotBalance memory) {
        return HyperCoreMockState.SpotBalance({total: total_, hold: 0, entryNtl: 0});
    }

    function _openTimeAndL1Gates() private {
        (uint64 pendingUntil, , , , , , , ) = _readPending();
        vm.warp(pendingUntil);
        core.setL1BlockNumber(core.getL1BlockNumber() + 1);
    }

    /// @dev A second deposit is rejected by `requireNotPendingAction` exactly while the first is pending.
    function _isBlocked() private returns (bool) {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(depositFuse),
            data: abi.encodeWithSignature(
                "enter((uint64,uint256))",
                HyperCoreDepositFuseEnterData({tokenIndex: HyperCoreLib.USDC_TOKEN, amount: 1e6})
            )
        });
        uint256 snapshot = vm.snapshotState();
        vm.prank(TestAddresses.ALPHA);
        try vault.execute(actions) {
            vm.revertToState(snapshot);
            return false;
        } catch (bytes memory reason) {
            vm.revertToState(snapshot);
            assertEq(
                bytes4(reason),
                HyperCorePendingLib.HyperCoreActionPending.selector,
                "deposit must be blocked only by the pending-action gate"
            );
            return true;
        }
    }

    function _grantUsdcWithConfig(HyperCoreSubstrateLib.ConfigKey key_, uint240 value_) private {
        vm.prank(TestAddresses.FUSE_MANAGER);
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = HyperCoreSubstrateLib.encodeSpotToken(HyperCoreLib.USDC_TOKEN, address(usdc));
        substrates[1] = HyperCoreSubstrateLib.encodeConfig(key_, value_);
        PlasmaVaultHelper.addSubstratesToMarket(vault, MARKET_ID, substrates);
    }

    function _readEffect()
        private
        view
        returns (uint8 kind, uint64 tokenIndex, address evmAsset, uint64 timeoutAt, uint256 expectedBalance)
    {
        uint256 slot6 = uint256(vm.load(address(vault), bytes32(uint256(PENDING_SLOT) + 6)));
        kind = uint8(slot6);
        tokenIndex = uint64(slot6 >> 8);
        evmAsset = address(uint160(slot6 >> 72));
        timeoutAt = uint64(uint256(vm.load(address(vault), bytes32(uint256(PENDING_SLOT) + 7))));
        expectedBalance = uint256(vm.load(address(vault), bytes32(uint256(PENDING_SLOT) + 8)));
    }

    function _execute(uint256 amount_) private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(depositFuse),
            data: abi.encodeWithSignature(
                "enter((uint64,uint256))",
                HyperCoreDepositFuseEnterData({tokenIndex: HyperCoreLib.USDC_TOKEN, amount: amount_})
            )
        });
        vm.prank(TestAddresses.ALPHA);
        vault.execute(actions);
    }

    function _grantSpotToken(uint64 tokenIndex_, address evmAsset_) private {
        vm.prank(TestAddresses.FUSE_MANAGER);
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = HyperCoreSubstrateLib.encodeSpotToken(tokenIndex_, evmAsset_);
        PlasmaVaultHelper.addSubstratesToMarket(vault, MARKET_ID, substrates);
    }

    /// @dev Reads HyperCorePendingLib.PendingAction directly out of the vault's storage via the fixed
    ///      ERC-7201 slot (mirrors the constant declared in HyperCorePendingLib.sol), since the vault's
    ///      own ABI has no getter for this namespaced state.
    function _readPending()
        private
        view
        returns (
            uint64 pendingUntil,
            uint64 enqueuedL1Block,
            uint64 enqueuedEvmBlock,
            uint8 actionClass,
            uint8 settlementMode,
            uint24 actionId,
            bytes32 payloadHash,
            uint256 cachedValueWad
        )
    {
        bytes32 slot0 = vm.load(address(vault), PENDING_SLOT);
        pendingUntil = uint64(uint256(slot0));
        enqueuedL1Block = uint64(uint256(slot0) >> 64);
        enqueuedEvmBlock = uint64(uint256(slot0) >> 128);
        actionClass = uint8(uint256(slot0) >> 192);
        settlementMode = uint8(uint256(slot0) >> 200);

        bytes32 slot1 = vm.load(address(vault), bytes32(uint256(PENDING_SLOT) + 1));
        actionId = uint24(uint256(slot1) >> 64);

        payloadHash = vm.load(address(vault), bytes32(uint256(PENDING_SLOT) + 2));

        cachedValueWad = uint256(vm.load(address(vault), bytes32(uint256(PENDING_SLOT) + 4)));
    }
}
