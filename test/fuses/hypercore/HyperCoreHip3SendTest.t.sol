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

import {HyperCoreTestHelper, HyperCoreMockUsdc} from "./HyperCoreTestHelper.sol";
import {HyperCoreMockState} from "./mocks/MockHyperCorePrecompiles.sol";
import {MockCoreWriter} from "./mocks/MockCoreWriter.sol";

import {PlasmaVaultHelper} from "../../test_helpers/PlasmaVaultHelper.sol";
import {IporFusionAccessManagerHelper} from "../../test_helpers/IporFusionAccessManagerHelper.sol";
import {TestAddresses} from "../../test_helpers/TestAddresses.sol";

/// @dev Minimal IPriceOracleMiddleware test double whose QUOTE_CURRENCY matches the real deployed
///      PriceOracleMiddleware (0x...0348) so it is accepted as a drop-in replacement.
contract HyperCoreHip3TestPriceOracle is IPriceOracleMiddleware {
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

contract HyperCoreHip3SendTest is Test {
    uint256 private constant MARKET_ID = 55;
    bytes32 private constant PENDING_SLOT = 0xff3841d45e92b4b113213ebf16e5e18527d87d1b739008d460c4a8565edaf200;

    HyperCoreMockState private core;
    MockCoreWriter private coreWriter;
    PlasmaVault private vault;
    HyperCoreMockUsdc private usdc;
    HyperCoreHip3TestPriceOracle private oracle;
    HyperCoreSendFuse private sendFuse;
    HyperCoreBalanceFuse private balanceFuse;
    address private usdcSystemAddress;
    uint240 private _configuredDexBitmap;

    function setUp() public {
        vm.chainId(999);
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

        oracle = new HyperCoreHip3TestPriceOracle();
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
        substrates[3] = HyperCoreSubstrateLib.encodeSendCap(HyperCoreLib.USDC_TOKEN, type(uint64).max);
        substrates[4] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.SpotSendBridgeEnabled, 1);
        PlasmaVaultHelper.addSubstratesToMarket(vault, MARKET_ID, substrates);
        vm.stopPrank();
    }

    function testConfiguredSpotToHip3PayloadAndSelfMoveKeepsCachedValue() public {
        _grantDexes(2);
        core.setSpotBalance(address(vault), HyperCoreLib.USDC_TOKEN, HyperCoreMockState.SpotBalance({total: 1_000e8, hold: 0, entryNtl: 0}));
        core.setAccountMarginSummary(1, address(vault), HyperCoreMockState.AccountMarginSummary({accountValue: 100e6, marginUsed: 0, ntlPos: 0, rawUsd: 100e6}));
        _executeSendAsset(address(vault), HyperCoreLib.SPOT_DEX, 1, HyperCoreLib.USDC_TOKEN, 200e8);
        assertEq(coreWriter.lastAction(), _expectPayload(HyperCoreLib.ACTION_SEND_ASSET, abi.encode(address(vault), address(0), HyperCoreLib.SPOT_DEX, uint32(1), HyperCoreLib.USDC_TOKEN, uint64(200e8))));
        assertEq(_readCachedValueWad(), 1_100e18);
    }

    function testHip3ToSpotPayload() public {
        _grantDexes(2);
        _setEquity(1, 100e6);
        _executeSendAsset(address(vault), 1, HyperCoreLib.SPOT_DEX, HyperCoreLib.USDC_TOKEN, 100e8);
        assertEq(coreWriter.lastAction(), _expectPayload(HyperCoreLib.ACTION_SEND_ASSET, abi.encode(address(vault), address(0), uint32(1), HyperCoreLib.SPOT_DEX, HyperCoreLib.USDC_TOKEN, uint64(100e8))));
        assertEq(_readCachedValueWad(), 100e18, "self transfer keeps the complete live value");
    }

    function testNativeToHip3Payload() public {
        _grantDexes(2);
        core.setWithdrawable(address(vault), 100e6);
        _executeSendAsset(address(vault), 0, 1, HyperCoreLib.USDC_TOKEN, 100e8);
        assertEq(coreWriter.lastAction(), _expectPayload(HyperCoreLib.ACTION_SEND_ASSET, abi.encode(address(vault), address(0), uint32(0), uint32(1), HyperCoreLib.USDC_TOKEN, uint64(100e8))));
    }

    function testHip3ToNativePayload() public {
        _grantDexes(2);
        _setEquity(1, 100e6);
        _executeSendAsset(address(vault), 1, HyperCoreLib.NATIVE_PERP_DEX, HyperCoreLib.USDC_TOKEN, 100e8);
        assertEq(coreWriter.lastAction(), _expectPayload(HyperCoreLib.ACTION_SEND_ASSET, abi.encode(address(vault), address(0), uint32(1), HyperCoreLib.NATIVE_PERP_DEX, HyperCoreLib.USDC_TOKEN, uint64(100e8))));
    }

    function testHip3ToHip3Payload() public {
        _grantDexes((1 << 1) | (1 << 6));
        _setEquity(1, 100e6);
        _executeSendAsset(address(vault), 1, 6, HyperCoreLib.USDC_TOKEN, 100e8);
        assertEq(coreWriter.lastAction(), _expectPayload(HyperCoreLib.ACTION_SEND_ASSET, abi.encode(address(vault), address(0), uint32(1), uint32(6), HyperCoreLib.USDC_TOKEN, uint64(100e8))));
    }

    function testHip3ToHip3ReversePayload() public {
        _grantDexes((1 << 1) | (1 << 6));
        _setEquity(6, 100e6);
        _executeSendAsset(address(vault), 6, 1, HyperCoreLib.USDC_TOKEN, 100e8);
        assertEq(coreWriter.lastAction(), _expectPayload(HyperCoreLib.ACTION_SEND_ASSET, abi.encode(address(vault), address(0), uint32(6), uint32(1), HyperCoreLib.USDC_TOKEN, uint64(100e8))));
    }

    function testHip3SourceRequiresPositiveSufficientEquityAndCeilsRequiredUsd6() public {
        _grantDexes(2);
        core.setAccountMarginSummary(1, address(vault), HyperCoreMockState.AccountMarginSummary({accountValue: 1, marginUsed: 0, ntlPos: 0, rawUsd: 1}));
        vm.expectRevert(abi.encodeWithSelector(HyperCoreSendFuse.HyperCoreSendFuseInsufficientDexEquity.selector, uint32(1), uint256(1), uint256(2)));
        _executeSendAsset(address(vault), 1, HyperCoreLib.SPOT_DEX, HyperCoreLib.USDC_TOKEN, 101);

        core.setAccountMarginSummary(1, address(vault), HyperCoreMockState.AccountMarginSummary({accountValue: 0, marginUsed: 0, ntlPos: 0, rawUsd: 0}));
        vm.expectRevert(abi.encodeWithSelector(HyperCoreSendFuse.HyperCoreSendFuseInsufficientDexEquity.selector, uint32(1), uint256(0), uint256(1)));
        _executeSendAsset(address(vault), 1, HyperCoreLib.SPOT_DEX, HyperCoreLib.USDC_TOKEN, 1);

        core.setAccountMarginSummary(1, address(vault), HyperCoreMockState.AccountMarginSummary({accountValue: 2, marginUsed: 0, ntlPos: 0, rawUsd: 2}));
        _executeSendAsset(address(vault), 1, HyperCoreLib.SPOT_DEX, HyperCoreLib.USDC_TOKEN, 101);
    }

    function testHip3EquityUsesUint256WithoutScaledUint64OverflowAndDoesNotNeedNativeWithdrawable() public {
        _grantDexes(2);
        core.setAccountMarginSummary(1, address(vault), HyperCoreMockState.AccountMarginSummary({accountValue: type(int64).max, marginUsed: 0, ntlPos: 0, rawUsd: type(int64).max}));
        core.setWithdrawable(address(vault), 0);
        _executeSendAsset(address(vault), 1, HyperCoreLib.SPOT_DEX, HyperCoreLib.USDC_TOKEN, type(uint64).max);
        assertTrue(coreWriter.lastAction().length > 0);
    }

    function testRejectsUnconfiguredUnsupportedNonSelfWrongTokenAndWrongChainHip3Routes() public {
        vm.expectRevert(abi.encodeWithSelector(HyperCoreSendFuse.HyperCoreSendFuseUnsupportedDex.selector, uint32(1)));
        _executeSendAsset(address(vault), HyperCoreLib.SPOT_DEX, 1, HyperCoreLib.USDC_TOKEN, 1);
        _grantDexes(2);
        core.setAccountMarginSummary(1, address(vault), HyperCoreMockState.AccountMarginSummary({accountValue: 10e6, marginUsed: 0, ntlPos: 0, rawUsd: 10e6}));
        vm.expectRevert(abi.encodeWithSelector(HyperCoreSendFuse.HyperCoreSendFuseUnsupportedDex.selector, uint32(7)));
        _executeSendAsset(address(vault), HyperCoreLib.SPOT_DEX, 7, HyperCoreLib.USDC_TOKEN, 1);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreSendFuse.HyperCoreSendFuseUnsupportedDex.selector, uint32(6)));
        _executeSendAsset(address(vault), 6, HyperCoreLib.SPOT_DEX, HyperCoreLib.USDC_TOKEN, 1);
        address other = makeAddr("other");
        bytes32[] memory extraDestination = new bytes32[](1);
        extraDestination[0] = HyperCoreSubstrateLib.encodeDestination(other);
        _replaceSubstrates(extraDestination);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreSendFuse.HyperCoreSendFuseUnsupportedBridgeRoute.selector, HyperCoreLib.SPOT_DEX, uint32(1)));
        _executeSendAsset(other, HyperCoreLib.SPOT_DEX, 1, HyperCoreLib.USDC_TOKEN, 1);
        _grantSpotToken(1);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreSendFuse.HyperCoreSendFuseUnsupportedToken.selector, uint64(1)));
        _executeSendAsset(address(vault), HyperCoreLib.SPOT_DEX, 1, 1, 1);
        vm.chainId(998);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreSendFuse.HyperCoreSendFuseUnsupportedDex.selector, uint32(1)));
        _executeSendAsset(address(vault), HyperCoreLib.SPOT_DEX, 1, HyperCoreLib.USDC_TOKEN, 1);
    }

    function testHip3SameDexSelfSendStillReverts() public {
        _grantDexes(2);
        vm.expectRevert(HyperCoreSendFuse.HyperCoreSendFuseSelfSend.selector);
        _executeSendAsset(address(vault), 1, 1, HyperCoreLib.USDC_TOKEN, 1);
    }

    function testConfiguredDexFundingDoesNotRequirePerpMarketGrant() public {
        _grantDexes(2);
        core.setSpotBalance(address(vault), HyperCoreLib.USDC_TOKEN, HyperCoreMockState.SpotBalance({total: 100e8, hold: 0, entryNtl: 0}));
        _executeSendAsset(address(vault), HyperCoreLib.SPOT_DEX, 1, HyperCoreLib.USDC_TOKEN, 1e8);
        assertTrue(coreWriter.lastAction().length > 0);
    }

    function testMissingTokenDestinationAndCapPermissionsReject() public {
        _grantDexes(2);
        address ungranted = makeAddr("ungranted");
        vm.expectRevert(abi.encodeWithSelector(HyperCoreSendFuse.HyperCoreSendFuseDestinationNotGranted.selector, ungranted));
        _executeSendAsset(ungranted, HyperCoreLib.SPOT_DEX, 1, HyperCoreLib.USDC_TOKEN, 1);
        // Full list replacement retains token 0's fixture while granting token 1 without its cap.
        bytes32[] memory tokenWithoutCap = new bytes32[](1);
        tokenWithoutCap[0] = HyperCoreSubstrateLib.encodeSpotToken(1, address(usdc));
        _replaceSubstrates(tokenWithoutCap);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreSendFuse.HyperCoreSendFuseExceedsSendCap.selector, uint64(1), uint128(0)));
        _executeSendAsset(address(vault), HyperCoreLib.SPOT_DEX, 1, 1, 1);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreSendFuse.HyperCoreSendFuseUnsupportedToken.selector, uint64(2)));
        _executeSendAsset(address(vault), HyperCoreLib.SPOT_DEX, 1, 2, 1);
    }

    function testSpotOnlyBridgeStillUsesAction6() public {
        core.setSpotBalance(address(vault), HyperCoreLib.USDC_TOKEN, HyperCoreMockState.SpotBalance({total: 10e8, hold: 0, entryNtl: 0}));
        _executeSpotSend(usdcSystemAddress, HyperCoreLib.USDC_TOKEN, 1e8);
        assertEq(coreWriter.lastAction(), _expectPayload(HyperCoreLib.ACTION_SPOT_SEND, abi.encode(usdcSystemAddress, HyperCoreLib.USDC_TOKEN, uint64(1e8))));
    }

    function testNativeSourceStillUsesWithdrawable() public {
        core.setWithdrawable(address(vault), 1e6);
        _executeSendAsset(address(vault), HyperCoreLib.NATIVE_PERP_DEX, HyperCoreLib.SPOT_DEX, HyperCoreLib.USDC_TOKEN, 1e8);
        assertEq(coreWriter.lastAction(), _expectPayload(HyperCoreLib.ACTION_SEND_ASSET, abi.encode(address(vault), address(0), HyperCoreLib.NATIVE_PERP_DEX, HyperCoreLib.SPOT_DEX, HyperCoreLib.USDC_TOKEN, uint64(1e8))));
    }

    function testNativeSpotChecksAndSpotOnlyBridgeRemainUnchanged() public {
        core.setWithdrawable(address(vault), 0);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreSendFuse.HyperCoreSendFuseInsufficientBalance.selector, uint64(0), uint256(1)));
        _executeSendAsset(address(vault), 0, HyperCoreLib.SPOT_DEX, HyperCoreLib.USDC_TOKEN, 1);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreSendFuse.HyperCoreSendFuseUnsupportedBridgeRoute.selector, uint32(0), HyperCoreLib.SPOT_DEX));
        _executeSendAsset(usdcSystemAddress, 0, HyperCoreLib.SPOT_DEX, HyperCoreLib.USDC_TOKEN, 1);
        core.setSpotBalance(address(vault), HyperCoreLib.USDC_TOKEN, HyperCoreMockState.SpotBalance({total: 1, hold: 1, entryNtl: 0}));
        vm.expectRevert(abi.encodeWithSelector(HyperCoreSendFuse.HyperCoreSendFuseInsufficientBalance.selector, uint256(0), uint64(1)));
        _executeSendAsset(address(vault), HyperCoreLib.SPOT_DEX, 0, HyperCoreLib.USDC_TOKEN, 1);
    }

    function _grantDexes(uint240 bitmap_) private {
        _configuredDexBitmap = bitmap_;
        bytes32[] memory extra = new bytes32[](0);
        _replaceSubstrates(extra);
    }

    function testHip3SourceRejectsInvalidUsdcDecimals() public {
        _grantDexes(2);
        _setEquity(1, 1e6);
        _setUsdcWeiDecimals(5);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreSendFuse.HyperCoreSendFuseUnexpectedUsdcScale.selector, uint8(5)));
        _executeSendAsset(address(vault), 1, HyperCoreLib.SPOT_DEX, HyperCoreLib.USDC_TOKEN, 1);

        _setUsdcWeiDecimals(19);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreSendFuse.HyperCoreSendFuseUnexpectedUsdcScale.selector, uint8(19)));
        _executeSendAsset(address(vault), 1, HyperCoreLib.SPOT_DEX, HyperCoreLib.USDC_TOKEN, 1);
    }

    function testNativeSourceRejectsInvalidUsdcDecimals() public {
        core.setWithdrawable(address(vault), 1e6);
        _setUsdcWeiDecimals(5);
        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreSendFuse.HyperCoreSendFuseUnexpectedUsdcScale.selector, uint8(5))
        );
        _executeSendAsset(
            address(vault),
            HyperCoreLib.NATIVE_PERP_DEX,
            HyperCoreLib.SPOT_DEX,
            HyperCoreLib.USDC_TOKEN,
            1
        );

        _setUsdcWeiDecimals(19);
        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreSendFuse.HyperCoreSendFuseUnexpectedUsdcScale.selector, uint8(19))
        );
        _executeSendAsset(
            address(vault),
            HyperCoreLib.NATIVE_PERP_DEX,
            HyperCoreLib.SPOT_DEX,
            HyperCoreLib.USDC_TOKEN,
            1
        );
    }

    function testHip3SourceRejectsNegativeEquity() public {
        _grantDexes(2);
        _setEquity(1, -1);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreSendFuse.HyperCoreSendFuseInsufficientDexEquity.selector, uint32(1), uint256(0), uint256(1)));
        _executeSendAsset(address(vault), 1, HyperCoreLib.SPOT_DEX, HyperCoreLib.USDC_TOKEN, 1);
    }

    function testHip3ToHip3RejectsMissingSourceBit() public {
        _grantDexes(1 << 6);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreSendFuse.HyperCoreSendFuseUnsupportedDex.selector, uint32(1)));
        _executeSendAsset(address(vault), 1, 6, HyperCoreLib.USDC_TOKEN, 1);
    }

    function testHip3ToHip3RejectsMissingDestinationBit() public {
        _grantDexes(1 << 1);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreSendFuse.HyperCoreSendFuseUnsupportedDex.selector, uint32(6)));
        _executeSendAsset(address(vault), 1, 6, HyperCoreLib.USDC_TOKEN, 1);
    }

    function _setEquity(uint32 dex_, int64 equityUsd6_) private {
        core.setAccountMarginSummary(dex_, address(vault), HyperCoreMockState.AccountMarginSummary({accountValue: equityUsd6_, marginUsed: 0, ntlPos: 0, rawUsd: equityUsd6_}));
    }

    function _setUsdcWeiDecimals(uint8 decimals_) private {
        core.setTokenInfo(HyperCoreLib.USDC_TOKEN, HyperCoreMockState.TokenInfo({
            name: "USDC", spots: new uint64[](0), deployerTradingFeeShare: 0, deployer: address(0),
            evmContract: address(usdc), szDecimals: 8, weiDecimals: decimals_, evmExtraWeiDecimals: -2
        }));
    }

    function _grantSpotToken(uint64 token_) private {
        bytes32[] memory extra = new bytes32[](2);
        extra[0] = HyperCoreSubstrateLib.encodeSpotToken(token_, address(usdc));
        extra[1] = HyperCoreSubstrateLib.encodeSendCap(token_, type(uint64).max);
        _replaceSubstrates(extra);
    }

    function _replaceSubstrates(bytes32[] memory extra_) private {
        // Leave WindowTransferSeconds unset so action 13 keeps the production default of two seconds.
        bytes32[] memory substrates = new bytes32[](6 + extra_.length);
        substrates[0] = HyperCoreSubstrateLib.encodeSpotToken(HyperCoreLib.USDC_TOKEN, address(usdc));
        substrates[1] = HyperCoreSubstrateLib.encodeDestination(usdcSystemAddress);
        substrates[2] = HyperCoreSubstrateLib.encodeDestination(address(vault));
        substrates[3] = HyperCoreSubstrateLib.encodeSendCap(HyperCoreLib.USDC_TOKEN, type(uint64).max);
        substrates[4] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.SpotSendBridgeEnabled, 1);
        substrates[5] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.PerpDexIds, _configuredDexBitmap);
        for (uint256 i; i < extra_.length; ++i) {
            substrates[6 + i] = extra_[i];
        }
        vm.prank(TestAddresses.FUSE_MANAGER);
        PlasmaVaultHelper.addSubstratesToMarket(vault, MARKET_ID, substrates);
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

    function _readCachedValueWad() private view returns (uint256) {
        return uint256(vm.load(address(vault), bytes32(uint256(PENDING_SLOT) + 4)));
    }

}
