// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IPriceOracleMiddleware} from "../../../contracts/price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVault, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {RewardsClaimManager} from "../../../contracts/managers/rewards/RewardsClaimManager.sol";

import {
    HyperCoreSendFuse,
    HyperCoreSendFuseSpotSendData,
    HyperCoreSendFuseSendAssetData
} from "../../../contracts/fuses/hypercore/HyperCoreSendFuse.sol";
import {HyperCoreBalanceFuse} from "../../../contracts/fuses/hypercore/HyperCoreBalanceFuse.sol";
import {HyperCoreLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreLib.sol";
import {HyperCoreSubstrateLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreSubstrateLib.sol";
import {HyperCorePendingLib} from "../../../contracts/fuses/hypercore/lib/HyperCorePendingLib.sol";

import {HyperCoreTestHelper, HyperCoreMockUsdc} from "./HyperCoreTestHelper.sol";
import {HyperCoreMockState} from "./mocks/MockHyperCorePrecompiles.sol";
import {MockCoreWriter} from "./mocks/MockCoreWriter.sol";
import {MockCoreDepositWallet} from "./mocks/MockCoreDepositWallet.sol";

import {PlasmaVaultHelper} from "../../test_helpers/PlasmaVaultHelper.sol";
import {IporFusionAccessManagerHelper} from "../../test_helpers/IporFusionAccessManagerHelper.sol";
import {TestAddresses} from "../../test_helpers/TestAddresses.sol";

/// @dev Minimal IPriceOracleMiddleware test double whose QUOTE_CURRENCY matches the real deployed
///      PriceOracleMiddleware (0x...0348) so it is accepted as a drop-in replacement.
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

contract HyperCoreSendFuseTest is Test {
    uint256 private constant MARKET_ID = 55;
    bytes32 private constant PENDING_SLOT = 0xff3841d45e92b4b113213ebf16e5e18527d87d1b739008d460c4a8565edaf200;

    HyperCoreMockState private core;
    MockCoreWriter private coreWriter;
    PlasmaVault private vault;
    HyperCoreMockUsdc private usdc;
    HyperCoreTestPriceOracle private oracle;
    HyperCoreSendFuse private sendFuse;
    HyperCoreBalanceFuse private balanceFuse;
    address private usdcSystemAddress;

    function setUp() public {
        core = HyperCoreTestHelper.etchPrecompiles(vm);
        coreWriter = HyperCoreTestHelper.etchCoreWriter(vm);

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

        sendFuse = new HyperCoreSendFuse(MARKET_ID);
        balanceFuse = new HyperCoreBalanceFuse(MARKET_ID);

        vm.startPrank(TestAddresses.FUSE_MANAGER);
        address[] memory fuses = new address[](1);
        fuses[0] = address(sendFuse);
        PlasmaVaultHelper.addFusesToVault(vault, fuses);
        PlasmaVaultHelper.addBalanceFusesToVault(vault, MARKET_ID, address(balanceFuse));
        vm.stopPrank();

        core.setTokenInfo(
            HyperCoreLib.USDC_TOKEN,
            HyperCoreMockState.TokenInfo({
                name: "USDC",
                spots: new uint64[](0),
                deployerTradingFeeShare: 0,
                deployer: address(0),
                evmContract: address(usdc),
                szDecimals: 8,
                weiDecimals: 8,
                evmExtraWeiDecimals: -2
            })
        );

        core.setCoreUserExists(address(vault), true);
        usdcSystemAddress = HyperCoreLib.systemAddress(HyperCoreLib.USDC_TOKEN);

        // Grant USDC (spot token, destination = its system address, send cap, spot-send bridge enabled)
        // so every happy-path test can just set a sufficient balance and go.
        vm.startPrank(TestAddresses.FUSE_MANAGER);
        bytes32[] memory substrates = new bytes32[](5);
        substrates[0] = HyperCoreSubstrateLib.encodeSpotToken(HyperCoreLib.USDC_TOKEN, address(usdc));
        substrates[1] = HyperCoreSubstrateLib.encodeDestination(usdcSystemAddress);
        substrates[2] = HyperCoreSubstrateLib.encodeDestination(address(vault));
        substrates[3] = HyperCoreSubstrateLib.encodeSendCap(HyperCoreLib.USDC_TOKEN, 1_000_000e8);
        substrates[4] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.SpotSendBridgeEnabled, 1);
        PlasmaVaultHelper.addSubstratesToMarket(vault, MARKET_ID, substrates);
        vm.stopPrank();
    }

    function testEnterSpotSendToSystemAddressSendsExactPayloadAndEnqueuesDebitedValue() public {
        core.setSpotBalance(
            address(vault), HyperCoreLib.USDC_TOKEN, HyperCoreMockState.SpotBalance({total: 1_000e8, hold: 0, entryNtl: 0})
        );

        vm.expectEmit(true, true, true, true, address(vault));
        emit HyperCoreSendFuse.HyperCoreSendFuseSpotSend(address(sendFuse), usdcSystemAddress, HyperCoreLib.USDC_TOKEN, 200e8);
        _executeSpotSend(usdcSystemAddress, HyperCoreLib.USDC_TOKEN, 200e8);

        bytes memory expected = _expectPayload(
            HyperCoreLib.ACTION_SPOT_SEND, abi.encode(usdcSystemAddress, HyperCoreLib.USDC_TOKEN, uint64(200e8))
        );
        assertEq(coreWriter.lastAction(), expected);

        (uint64 pendingUntil, , , uint8 actionClass, , , bytes32 payloadHash, uint256 cachedValueWad) = _readPending();
        assertTrue(pendingUntil > 0);
        assertEq(actionClass, uint8(HyperCorePendingLib.ActionClass.Transfer));
        assertEq(
            payloadHash,
            keccak256(HyperCoreLib.encodeSpotSend(usdcSystemAddress, HyperCoreLib.USDC_TOKEN, 200e8))
        );
        // S = $1000, A = $200 => C = $800.
        assertEq(cachedValueWad, 800e18);
    }

    /// @dev Hyperliquid routes HyperCore token 0 (USDC) through a CoreDepositWallet on mainnet, so
    ///      `tokenInfo(0).evmContract` may be that wallet's proxy address rather than the USDC ERC20
    ///      itself. The Core -> EVM withdrawal path (spot send to the token's system address) never
    ///      compares `evmContract` against the granted asset -- only against zero, and for the EVM
    ///      decimals used in the representability check -- so it is unaffected by the wallet and needs
    ///      no fuse change; this proves that equivalence holds.
    function testEnterSpotSendToSystemAddressUnaffectedByDepositWalletEvmContract() public {
        MockCoreDepositWallet wallet = new MockCoreDepositWallet(address(usdc));
        core.setTokenInfo(
            HyperCoreLib.USDC_TOKEN,
            HyperCoreMockState.TokenInfo({
                name: "USDC",
                spots: new uint64[](0),
                deployerTradingFeeShare: 0,
                deployer: address(0),
                evmContract: address(wallet),
                szDecimals: 8,
                weiDecimals: 8,
                evmExtraWeiDecimals: -2
            })
        );

        core.setSpotBalance(
            address(vault), HyperCoreLib.USDC_TOKEN, HyperCoreMockState.SpotBalance({total: 1_000e8, hold: 0, entryNtl: 0})
        );

        _executeSpotSend(usdcSystemAddress, HyperCoreLib.USDC_TOKEN, 200e8);

        bytes memory expected = _expectPayload(
            HyperCoreLib.ACTION_SPOT_SEND, abi.encode(usdcSystemAddress, HyperCoreLib.USDC_TOKEN, uint64(200e8))
        );
        assertEq(coreWriter.lastAction(), expected, "withdrawal still proceeds with the wallet as evmContract");
    }

    /// @dev The spot-send-to-system-address bridge fails closed: without an explicit
    ///      `Config{SpotSendBridgeEnabled}` == 1 grant, even an otherwise-fully-granted spot send to
    ///      the token's system address is rejected before any other validation runs.
    function testEnterSpotSendRevertsWhenBridgeNotExplicitlyEnabled() public {
        core.setSpotBalance(
            address(vault), HyperCoreLib.USDC_TOKEN, HyperCoreMockState.SpotBalance({total: 1_000e8, hold: 0, entryNtl: 0})
        );
        // Re-grant everything from setUp except SpotSendBridgeEnabled.
        vm.prank(TestAddresses.FUSE_MANAGER);
        bytes32[] memory substrates = new bytes32[](4);
        substrates[0] = HyperCoreSubstrateLib.encodeSpotToken(HyperCoreLib.USDC_TOKEN, address(usdc));
        substrates[1] = HyperCoreSubstrateLib.encodeDestination(usdcSystemAddress);
        substrates[2] = HyperCoreSubstrateLib.encodeDestination(address(vault));
        substrates[3] = HyperCoreSubstrateLib.encodeSendCap(HyperCoreLib.USDC_TOKEN, 1_000_000e8);
        PlasmaVaultHelper.addSubstratesToMarket(vault, MARKET_ID, substrates);

        vm.expectRevert(HyperCoreSendFuse.HyperCoreSendFuseSpotSendBridgeDisabled.selector);
        _executeSpotSend(usdcSystemAddress, HyperCoreLib.USDC_TOKEN, 200e8);
    }

    /// @dev A same-dex, cross-dex-free self send (destination = address(this)) never needs the bridge
    ///      gate, since it never leaves Core; it must succeed even with the gate config unset. Since
    ///      enterSpotSend forces sourceDex == destinationDex, self-destination is rejected by SelfSend
    ///      regardless of the bridge gate, which is exercised separately above.
    function testEnterSpotSendWithBridgeEnabledProceedsToSystemAddress() public {
        core.setSpotBalance(
            address(vault), HyperCoreLib.USDC_TOKEN, HyperCoreMockState.SpotBalance({total: 1_000e8, hold: 0, entryNtl: 0})
        );
        // setUp already grants SpotSendBridgeEnabled = 1; this proves the happy path is reachable only
        // because of that grant (see testEnterSpotSendRevertsWhenBridgeNotExplicitlyEnabled for the
        // negative case with everything else identical).
        _executeSpotSend(usdcSystemAddress, HyperCoreLib.USDC_TOKEN, 200e8);

        (uint64 pendingUntil, , , , , , , ) = _readPending();
        assertTrue(pendingUntil > 0, "spot send proceeded once the bridge gate was granted");
    }

    function testEnterSpotSendRevertsOnSelfSend() public {
        core.setSpotBalance(
            address(vault), HyperCoreLib.USDC_TOKEN, HyperCoreMockState.SpotBalance({total: 1_000e8, hold: 0, entryNtl: 0})
        );
        vm.prank(TestAddresses.FUSE_MANAGER);
        bytes32[] memory substrates = new bytes32[](4);
        substrates[0] = HyperCoreSubstrateLib.encodeSpotToken(HyperCoreLib.USDC_TOKEN, address(usdc));
        substrates[1] = HyperCoreSubstrateLib.encodeDestination(usdcSystemAddress);
        substrates[2] = HyperCoreSubstrateLib.encodeDestination(address(vault));
        substrates[3] = HyperCoreSubstrateLib.encodeSendCap(HyperCoreLib.USDC_TOKEN, 1_000_000e8);
        PlasmaVaultHelper.addSubstratesToMarket(vault, MARKET_ID, substrates);

        vm.expectRevert(HyperCoreSendFuse.HyperCoreSendFuseSelfSend.selector);
        _executeSpotSend(address(vault), HyperCoreLib.USDC_TOKEN, 1e8);
    }

    function testEnterSpotSendRevertsWhenDestinationNotGranted() public {
        core.setSpotBalance(
            address(vault), HyperCoreLib.USDC_TOKEN, HyperCoreMockState.SpotBalance({total: 1_000e8, hold: 0, entryNtl: 0})
        );
        address ungranted = makeAddr("ungranted");
        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreSendFuse.HyperCoreSendFuseDestinationNotGranted.selector, ungranted)
        );
        _executeSpotSend(ungranted, HyperCoreLib.USDC_TOKEN, 1e8);
    }

    function testEnterSpotSendRevertsWhenGrantedDestinationIsNotTheDerivedSystemAddress() public {
        core.setSpotBalance(
            address(vault), HyperCoreLib.USDC_TOKEN, HyperCoreMockState.SpotBalance({total: 1_000e8, hold: 0, entryNtl: 0})
        );
        // Grant an arbitrary third-party address as a Destination; it must still be rejected because
        // it is neither address(this) nor the token's derived system address.
        address thirdParty = makeAddr("thirdParty");
        vm.prank(TestAddresses.FUSE_MANAGER);
        bytes32[] memory substrates = new bytes32[](5);
        substrates[0] = HyperCoreSubstrateLib.encodeSpotToken(HyperCoreLib.USDC_TOKEN, address(usdc));
        substrates[1] = HyperCoreSubstrateLib.encodeDestination(usdcSystemAddress);
        substrates[2] = HyperCoreSubstrateLib.encodeDestination(thirdParty);
        substrates[3] = HyperCoreSubstrateLib.encodeSendCap(HyperCoreLib.USDC_TOKEN, 1_000_000e8);
        substrates[4] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.SpotSendBridgeEnabled, 1);
        PlasmaVaultHelper.addSubstratesToMarket(vault, MARKET_ID, substrates);

        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreSendFuse.HyperCoreSendFuseDestinationNotAllowed.selector, thirdParty)
        );
        _executeSpotSend(thirdParty, HyperCoreLib.USDC_TOKEN, 1e8);
    }

    function testEnterSpotSendRevertsWhenAmountExceedsSendCap() public {
        core.setSpotBalance(
            address(vault), HyperCoreLib.USDC_TOKEN, HyperCoreMockState.SpotBalance({total: 1_000_000e8, hold: 0, entryNtl: 0})
        );
        vm.prank(TestAddresses.FUSE_MANAGER);
        bytes32[] memory substrates = new bytes32[](4);
        substrates[0] = HyperCoreSubstrateLib.encodeSpotToken(HyperCoreLib.USDC_TOKEN, address(usdc));
        substrates[1] = HyperCoreSubstrateLib.encodeDestination(usdcSystemAddress);
        substrates[2] = HyperCoreSubstrateLib.encodeSendCap(HyperCoreLib.USDC_TOKEN, 100e8);
        substrates[3] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.SpotSendBridgeEnabled, 1);
        PlasmaVaultHelper.addSubstratesToMarket(vault, MARKET_ID, substrates);

        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreSendFuse.HyperCoreSendFuseExceedsSendCap.selector, uint64(200e8), uint128(100e8))
        );
        _executeSpotSend(usdcSystemAddress, HyperCoreLib.USDC_TOKEN, 200e8);
    }

    function testEnterSpotSendRevertsWhenSpotBalanceInsufficient() public {
        core.setSpotBalance(
            address(vault), HyperCoreLib.USDC_TOKEN, HyperCoreMockState.SpotBalance({total: 10e8, hold: 0, entryNtl: 0})
        );
        vm.expectRevert(abi.encodeWithSelector(HyperCoreSendFuse.HyperCoreSendFuseInsufficientBalance.selector, 10e8, 200e8));
        _executeSpotSend(usdcSystemAddress, HyperCoreLib.USDC_TOKEN, 200e8);
    }

    function testEnterSpotSendRevertsWhenAmountNotRepresentableAtEvmPrecision() public {
        // Like real USDC, evmExtraWeiDecimals = -2 means Core has 2 more decimals than the EVM asset:
        // a Core-wei amount that is not a multiple of 100 cannot round-trip to EVM units and back.
        core.setTokenInfo(
            9,
            HyperCoreMockState.TokenInfo({
                name: "COARSE",
                spots: new uint64[](0),
                deployerTradingFeeShare: 0,
                deployer: address(0),
                evmContract: address(usdc),
                szDecimals: 8,
                weiDecimals: 8,
                evmExtraWeiDecimals: -2
            })
        );
        vm.prank(TestAddresses.FUSE_MANAGER);
        bytes32[] memory substrates = new bytes32[](4);
        substrates[0] = HyperCoreSubstrateLib.encodeSpotToken(9, address(usdc));
        substrates[1] = HyperCoreSubstrateLib.encodeDestination(HyperCoreLib.systemAddress(9));
        substrates[2] = HyperCoreSubstrateLib.encodeSendCap(9, 1_000_000e8);
        substrates[3] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.SpotSendBridgeEnabled, 1);
        PlasmaVaultHelper.addSubstratesToMarket(vault, MARKET_ID, substrates);
        core.setSpotBalance(address(vault), 9, HyperCoreMockState.SpotBalance({total: 1_000e8, hold: 0, entryNtl: 0}));
        oracle.setAssetPriceWithDecimals(address(usdc), 1e8, 8);

        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreSendFuse.HyperCoreSendFuseAmountNotRepresentable.selector, uint64(101))
        );
        _executeSpotSend(HyperCoreLib.systemAddress(9), 9, 101);
    }

    function testEnterSpotSendRevertsWhenTransitValueExceedsLiveSnapshot() public {
        // Spot leg = $100 (100e8 @ $1), perp leg = -$10 (accountValue = -10e6 usd6) => S = $90.
        core.setSpotBalance(
            address(vault), HyperCoreLib.USDC_TOKEN, HyperCoreMockState.SpotBalance({total: 100e8, hold: 0, entryNtl: 0})
        );
        core.setAccountMarginSummary(
            0,
            address(vault),
            HyperCoreMockState.AccountMarginSummary({accountValue: -10_000_000, marginUsed: 0, ntlPos: 0, rawUsd: -10_000_000})
        );

        // Sending the full $100 spot balance would debit more than the $90 live snapshot.
        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreSendFuse.HyperCoreSendFuseTransitExceedsValue.selector, 90e18, 100e18)
        );
        _executeSpotSend(usdcSystemAddress, HyperCoreLib.USDC_TOKEN, 100e8);
    }

    /// @dev The granted SpotToken's `evmAsset` prices the in-transit debit `A`, matching
    ///      HyperCoreValuationLib.liveValueWad's basis, even when it differs from the token's real
    ///      Core-registered `evmContract` (which is used only for the transfer/representability checks).
    function testCachedValuePricesTransitAmountUsingGrantedEvmAssetNotRealEvmContract() public {
        address grantedPricingAsset = address(new HyperCoreMockUsdc()); // priced at $2; needs an ERC20 balanceOf
        address realCoreEvmContract = makeAddr("realCoreEvmContract"); // priced at $5 (must NOT be used)

        core.setTokenInfo(
            5,
            HyperCoreMockState.TokenInfo({
                name: "TEST5",
                spots: new uint64[](0),
                deployerTradingFeeShare: 0,
                deployer: address(0),
                evmContract: realCoreEvmContract,
                szDecimals: 8,
                weiDecimals: 8,
                evmExtraWeiDecimals: 0
            })
        );
        oracle.setAssetPriceWithDecimals(grantedPricingAsset, 2e8, 8);
        oracle.setAssetPriceWithDecimals(realCoreEvmContract, 5e8, 8);

        vm.prank(TestAddresses.FUSE_MANAGER);
        bytes32[] memory substrates = new bytes32[](5);
        substrates[0] = HyperCoreSubstrateLib.encodeSpotToken(HyperCoreLib.USDC_TOKEN, address(usdc)); // $500 anchor
        substrates[1] = HyperCoreSubstrateLib.encodeSpotToken(5, grantedPricingAsset); // $20 anchor
        substrates[2] = HyperCoreSubstrateLib.encodeDestination(HyperCoreLib.systemAddress(5));
        substrates[3] = HyperCoreSubstrateLib.encodeSendCap(5, 1_000_000e8);
        substrates[4] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.SpotSendBridgeEnabled, 1);
        PlasmaVaultHelper.addSubstratesToMarket(vault, MARKET_ID, substrates);

        core.setSpotBalance(address(vault), HyperCoreLib.USDC_TOKEN, HyperCoreMockState.SpotBalance({total: 500e8, hold: 0, entryNtl: 0}));
        core.setSpotBalance(address(vault), 5, HyperCoreMockState.SpotBalance({total: 10e8, hold: 0, entryNtl: 0}));

        // S = $500 (USDC) + $20 (5 units @ $2) = $520.
        // Sending 5 units of token 5: correct A = 5 * $2 = $10 (grantedPricingAsset); wrong A (real
        // evmContract @ $5) would be $25.
        _executeSpotSend(HyperCoreLib.systemAddress(5), 5, 5e8);

        (, , , , , , , uint256 cachedValueWad) = _readPending();
        assertEq(cachedValueWad, 510e18, "A must be priced with the granted evmAsset, not the real evmContract");
    }

    function testEnterSendAssetSelfCrossDexMoveStaysOnCoreWithLiveValueCached() public {
        core.setSpotBalance(
            address(vault), HyperCoreLib.USDC_TOKEN, HyperCoreMockState.SpotBalance({total: 1_000e8, hold: 0, entryNtl: 0})
        );

        vm.expectEmit(true, true, true, true, address(vault));
        emit HyperCoreSendFuse.HyperCoreSendFuseSendAsset(
            address(sendFuse), address(vault), HyperCoreLib.SPOT_DEX, HyperCoreLib.NATIVE_PERP_DEX, HyperCoreLib.USDC_TOKEN, 200e8
        );
        _executeSendAsset(address(vault), HyperCoreLib.SPOT_DEX, HyperCoreLib.NATIVE_PERP_DEX, HyperCoreLib.USDC_TOKEN, 200e8);

        bytes memory expected = _expectPayload(
            HyperCoreLib.ACTION_SEND_ASSET,
            abi.encode(address(vault), address(0), HyperCoreLib.SPOT_DEX, HyperCoreLib.NATIVE_PERP_DEX, HyperCoreLib.USDC_TOKEN, uint64(200e8))
        );
        assertEq(coreWriter.lastAction(), expected);

        (, , , , , , , uint256 cachedValueWad) = _readPending();
        assertEq(cachedValueWad, 1_000e18, "self cross-dex move keeps C = S");
    }

    function testEnterSendAssetRevertsOnSameDexSelfSend() public {
        core.setSpotBalance(
            address(vault), HyperCoreLib.USDC_TOKEN, HyperCoreMockState.SpotBalance({total: 1_000e8, hold: 0, entryNtl: 0})
        );
        vm.expectRevert(HyperCoreSendFuse.HyperCoreSendFuseSelfSend.selector);
        _executeSendAsset(address(vault), HyperCoreLib.SPOT_DEX, HyperCoreLib.SPOT_DEX, HyperCoreLib.USDC_TOKEN, 1e8);
    }

    function testEnterSendAssetRevertsOnUnsupportedDestinationDex() public {
        vm.expectRevert(abi.encodeWithSelector(HyperCoreSendFuse.HyperCoreSendFuseUnsupportedDex.selector, uint32(7)));
        _executeSendAsset(address(vault), HyperCoreLib.SPOT_DEX, 7, HyperCoreLib.USDC_TOKEN, 1e8);
    }

    /// @dev Core -> EVM bridge is only reachable via a spot -> spot route; perp collateral must first
    ///      move to spot through the margin fuse (action 7).
    function testEnterSendAssetRevertsOnPerpSourcedBridgeRoute() public {
        core.setWithdrawable(address(vault), 1_000e6);
        vm.expectRevert(
            abi.encodeWithSelector(
                HyperCoreSendFuse.HyperCoreSendFuseUnsupportedBridgeRoute.selector,
                HyperCoreLib.NATIVE_PERP_DEX,
                HyperCoreLib.SPOT_DEX
            )
        );
        _executeSendAsset(usdcSystemAddress, HyperCoreLib.NATIVE_PERP_DEX, HyperCoreLib.SPOT_DEX, HyperCoreLib.USDC_TOKEN, 100e8);
    }

    function testEnterSendAssetPerpSourceUsesCeilingDivisionOnWithdrawable() public {
        // 101 Core wei of USDC = $1.01 -> ceil-divides to 2 usd6 units required.
        core.setWithdrawable(address(vault), 1);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreSendFuse.HyperCoreSendFuseInsufficientBalance.selector, 1, 2));
        _executeSendAsset(address(vault), HyperCoreLib.NATIVE_PERP_DEX, HyperCoreLib.SPOT_DEX, HyperCoreLib.USDC_TOKEN, 101);
    }

    function testEnterRevertsWhenAccountNotActivated() public {
        core.setCoreUserExists(address(vault), false);
        vm.expectRevert(HyperCoreSendFuse.HyperCoreSendFuseAccountNotActivated.selector);
        _executeSpotSend(usdcSystemAddress, HyperCoreLib.USDC_TOKEN, 1e8);
    }

    function testEnterRevertsOnZeroWindowConfig() public {
        core.setSpotBalance(
            address(vault), HyperCoreLib.USDC_TOKEN, HyperCoreMockState.SpotBalance({total: 1_000e8, hold: 0, entryNtl: 0})
        );
        vm.prank(TestAddresses.FUSE_MANAGER);
        bytes32[] memory substrates = new bytes32[](5);
        substrates[0] = HyperCoreSubstrateLib.encodeSpotToken(HyperCoreLib.USDC_TOKEN, address(usdc));
        substrates[1] = HyperCoreSubstrateLib.encodeDestination(usdcSystemAddress);
        substrates[2] = HyperCoreSubstrateLib.encodeSendCap(HyperCoreLib.USDC_TOKEN, 1_000_000e8);
        substrates[3] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.WindowTransferSeconds, 0);
        substrates[4] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.SpotSendBridgeEnabled, 1);
        PlasmaVaultHelper.addSubstratesToMarket(vault, MARKET_ID, substrates);

        vm.expectRevert(abi.encodeWithSelector(HyperCoreSendFuse.HyperCoreSendFuseInvalidWindow.selector, uint240(0)));
        _executeSpotSend(usdcSystemAddress, HyperCoreLib.USDC_TOKEN, 1e8);
    }

    function testSecondSendActionInSameExecuteReverts() public {
        core.setSpotBalance(
            address(vault), HyperCoreLib.USDC_TOKEN, HyperCoreMockState.SpotBalance({total: 1_000e8, hold: 0, entryNtl: 0})
        );
        FuseAction[] memory actions = new FuseAction[](2);
        actions[0] = FuseAction({
            fuse: address(sendFuse),
            data: abi.encodeWithSignature(
                "enterSpotSend((address,uint64,uint64))",
                HyperCoreSendFuseSpotSendData({destination: usdcSystemAddress, tokenIndex: HyperCoreLib.USDC_TOKEN, amountWei: 1e8})
            )
        });
        actions[1] = FuseAction({
            fuse: address(sendFuse),
            data: abi.encodeWithSignature(
                "enterSpotSend((address,uint64,uint64))",
                HyperCoreSendFuseSpotSendData({destination: usdcSystemAddress, tokenIndex: HyperCoreLib.USDC_TOKEN, amountWei: 1e8})
            )
        });

        vm.expectRevert();
        vm.prank(TestAddresses.ALPHA);
        vault.execute(actions);
    }

    // ------------------------------------------------------------------
    // Effect-based settlement (IL-8526)
    // ------------------------------------------------------------------

    function testSpotSendBridgeWaitsForEvmCreditThenSettles() public {
        core.setSpotBalance(address(vault), HyperCoreLib.USDC_TOKEN, _spot(1_000e8));
        usdc.mint(address(vault), 50e6);

        _executeSpotSend(usdcSystemAddress, HyperCoreLib.USDC_TOKEN, 200e8);

        (uint8 kind, , address evmAsset, uint64 timeoutAt, uint256 expected) = _readEffect();
        (uint64 pendingUntil, , , , , , , ) = _readPending();
        assertEq(kind, HyperCorePendingLib.EFFECT_EVM_BALANCE);
        assertEq(evmAsset, address(usdc), "granted ERC20, not tokenInfo.evmContract");
        assertEq(expected, 50e6 + 200e6, "baseline + exact EVM amount (200e8 core wei = 200e6)");
        assertEq(timeoutAt, pendingUntil + 600);

        _openTimeAndL1Gates();
        assertTrue(_isBlocked(), "EVM credit has not landed");
        usdc.mint(address(vault), 200e6 - 1);
        assertTrue(_isBlocked(), "one wei short");
        usdc.mint(address(vault), 1);
        assertFalse(_isBlocked(), "EVM credit landed");
    }

    function testSendAssetBridgeWaitsForEvmCreditAndTimesOut() public {
        core.setSpotBalance(address(vault), HyperCoreLib.USDC_TOKEN, _spot(1_000e8));
        _executeSendAsset(usdcSystemAddress, HyperCoreLib.SPOT_DEX, HyperCoreLib.SPOT_DEX, HyperCoreLib.USDC_TOKEN, 100e8);

        (uint8 kind, , , , uint256 expected) = _readEffect();
        assertEq(kind, HyperCorePendingLib.EFFECT_EVM_BALANCE);
        assertEq(expected, usdc.balanceOf(address(vault)) + 100e6);

        (uint64 pendingUntil, , , , , , , ) = _readPending();
        core.setL1BlockNumber(core.getL1BlockNumber() + 1);
        vm.warp(pendingUntil + 599);
        assertTrue(_isBlocked());
        vm.warp(pendingUntil + 600);
        assertFalse(_isBlocked(), "timeout waives the effect requirement");
    }

    function testSelfSendStaysTimeBased() public {
        core.setSpotBalance(address(vault), HyperCoreLib.USDC_TOKEN, _spot(1_000e8));
        _executeSendAsset(address(vault), HyperCoreLib.SPOT_DEX, HyperCoreLib.NATIVE_PERP_DEX, HyperCoreLib.USDC_TOKEN, 200e8);

        (uint8 kind, , address evmAsset, uint64 timeoutAt, uint256 expected) = _readEffect();
        assertEq(kind, HyperCorePendingLib.EFFECT_NONE);
        assertEq(evmAsset, address(0));
        assertEq(timeoutAt, 0);
        assertEq(expected, 0);

        assertTrue(_isBlocked());
        _openTimeAndL1Gates();
        assertFalse(_isBlocked(), "time + L1 block alone settle a self-send");
    }

    function testCustomTransferTimeoutConfig() public {
        _grantWithConfig(HyperCoreSubstrateLib.ConfigKey.TransferTimeoutSeconds, 60);
        core.setSpotBalance(address(vault), HyperCoreLib.USDC_TOKEN, _spot(1_000e8));
        _executeSpotSend(usdcSystemAddress, HyperCoreLib.USDC_TOKEN, 1e8);
        (, , , uint64 timeoutAt, ) = _readEffect();
        (uint64 pendingUntil, , , , , , , ) = _readPending();
        assertEq(timeoutAt, pendingUntil + 60);
    }

    function testBridgeRevertsOnInvalidTimeoutConfig() public {
        core.setSpotBalance(address(vault), HyperCoreLib.USDC_TOKEN, _spot(1_000e8));
        _grantWithConfig(HyperCoreSubstrateLib.ConfigKey.TransferTimeoutSeconds, 0);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreSendFuse.HyperCoreSendFuseInvalidTimeout.selector, uint240(0)));
        _executeSpotSend(usdcSystemAddress, HyperCoreLib.USDC_TOKEN, 1e8);

        _grantWithConfig(HyperCoreSubstrateLib.ConfigKey.TransferTimeoutSeconds, 59);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreSendFuse.HyperCoreSendFuseInvalidTimeout.selector, uint240(59)));
        _executeSpotSend(usdcSystemAddress, HyperCoreLib.USDC_TOKEN, 1e8);

        uint240 tooBig = uint240(type(uint64).max) + 1;
        _grantWithConfig(HyperCoreSubstrateLib.ConfigKey.TransferTimeoutSeconds, tooBig);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreSendFuse.HyperCoreSendFuseInvalidTimeout.selector, tooBig));
        _executeSpotSend(usdcSystemAddress, HyperCoreLib.USDC_TOKEN, 1e8);
    }

    function _spot(uint64 total_) private pure returns (HyperCoreMockState.SpotBalance memory) {
        return HyperCoreMockState.SpotBalance({total: total_, hold: 0, entryNtl: 0});
    }

    function _openTimeAndL1Gates() private {
        (uint64 pendingUntil, , , , , , , ) = _readPending();
        vm.warp(pendingUntil);
        core.setL1BlockNumber(core.getL1BlockNumber() + 1);
    }

    /// @dev Another send is rejected by `requireNotPendingAction` exactly while the first action is pending.
    function _isBlocked() private returns (bool) {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(sendFuse),
            data: abi.encodeWithSignature(
                "enterSpotSend((address,uint64,uint64))",
                HyperCoreSendFuseSpotSendData({destination: usdcSystemAddress, tokenIndex: HyperCoreLib.USDC_TOKEN, amountWei: 1e8})
            )
        });
        uint256 snapshot = vm.snapshotState();
        vm.prank(TestAddresses.ALPHA);
        try vault.execute(actions) {
            vm.revertToState(snapshot);
            return false;
        } catch {
            vm.revertToState(snapshot);
            return true;
        }
    }

    function _grantWithConfig(HyperCoreSubstrateLib.ConfigKey key_, uint240 value_) private {
        vm.prank(TestAddresses.FUSE_MANAGER);
        bytes32[] memory substrates = new bytes32[](6);
        substrates[0] = HyperCoreSubstrateLib.encodeSpotToken(HyperCoreLib.USDC_TOKEN, address(usdc));
        substrates[1] = HyperCoreSubstrateLib.encodeDestination(usdcSystemAddress);
        substrates[2] = HyperCoreSubstrateLib.encodeDestination(address(vault));
        substrates[3] = HyperCoreSubstrateLib.encodeSendCap(HyperCoreLib.USDC_TOKEN, 1_000_000e8);
        substrates[4] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.SpotSendBridgeEnabled, 1);
        substrates[5] = HyperCoreSubstrateLib.encodeConfig(key_, value_);
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

    function _executeSpotSend(address destination_, uint64 tokenIndex_, uint64 amountWei_) private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(sendFuse),
            data: abi.encodeWithSignature(
                "enterSpotSend((address,uint64,uint64))",
                HyperCoreSendFuseSpotSendData({destination: destination_, tokenIndex: tokenIndex_, amountWei: amountWei_})
            )
        });
        vm.prank(TestAddresses.ALPHA);
        vault.execute(actions);
    }

    function _executeSendAsset(
        address destination_,
        uint32 sourceDex_,
        uint32 destinationDex_,
        uint64 tokenIndex_,
        uint64 amountWei_
    ) private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(sendFuse),
            data: abi.encodeWithSignature(
                "enterSendAsset((address,uint32,uint32,uint64,uint64))",
                HyperCoreSendFuseSendAssetData({
                    destination: destination_,
                    sourceDex: sourceDex_,
                    destinationDex: destinationDex_,
                    tokenIndex: tokenIndex_,
                    amountWei: amountWei_
                })
            )
        });
        vm.prank(TestAddresses.ALPHA);
        vault.execute(actions);
    }

    function _expectPayload(uint24 actionId_, bytes memory fields_) private pure returns (bytes memory) {
        return abi.encodePacked(bytes1(uint8(1)), bytes3(actionId_), fields_);
    }

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
