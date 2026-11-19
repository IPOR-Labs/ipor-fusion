// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {HyperCoreEffectSettlementBase, MockEffectSettlementChainlinkFeed} from "./HyperCoreEffectSettlementBase.sol";
import {FuseAction} from "../../../contracts/interfaces/IPlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {
    HyperCoreSendFuse,
    HyperCoreSendFuseSendAssetData
} from "../../../contracts/fuses/hypercore/HyperCoreSendFuse.sol";
import {HyperCoreLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreLib.sol";
import {HyperCoreSubstrateLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreSubstrateLib.sol";
import {NavJumpFloorFixture} from "./HyperCoreNavJumpFloorFixture.sol";
import {CoreSimulatorLib} from "./simulation/CoreSimulatorLib.sol";
import {PrecompileLib} from "./simulation/src/PrecompileLib.sol";

/// @dev 8-decimal ERC20 standing in for a Core-linked or a wrongly granted token.
contract HyperCoreSendFuseBindingToken is ERC20 {
    constructor(string memory symbol_) ERC20(symbol_, symbol_) {}

    function decimals() public pure override returns (uint8) {
        return 8;
    }
}

/// @title HyperCoreSendFuseEvmAssetBindingTest
/// @notice IL-9639 (L08): a Core -> EVM bridge through `HyperCoreSendFuse` reverts when the ERC-20 granted for the
///         token is not the one HyperCore links to it. This mirrors the Core-link check of `HyperCoreDepositFuse`
///         and `HyperCoreMarginFuse`; it is not a grant policy. Self-sends carry no cross-domain effect and are
///         not checked. Fails on the base: the bridge is accepted and waits for a credit of the wrong token.
/// @dev Must run single-threaded with the rest of the HyperCore suite (`-j 1`).
contract HyperCoreSendFuseEvmAssetBindingTest is HyperCoreEffectSettlementBase {
    uint64 internal constant LINKED_TOKEN = 9;
    uint64 internal constant LINKED_CORE_WEI = 100e8;
    uint64 internal constant BRIDGE_WEI = 20e8;

    HyperCoreSendFuseBindingToken internal _linked;
    HyperCoreSendFuseBindingToken internal _other;

    function setUp() public override {
        super.setUp();
        _linked = new HyperCoreSendFuseBindingToken("LNK");
        _other = new HyperCoreSendFuseBindingToken("OTH");
        _hyperCore.registerTokenInfo(
            LINKED_TOKEN,
            PrecompileLib.TokenInfo({
                name: "LNK",
                spots: new uint64[](0),
                deployerTradingFeeShare: 0,
                deployer: address(0),
                evmContract: address(_linked),
                szDecimals: 8,
                weiDecimals: 8,
                evmExtraWeiDecimals: 0
            })
        );
        address[] memory assets = new address[](2);
        assets[0] = address(_linked);
        assets[1] = address(_other);
        address[] memory sources = new address[](2);
        sources[0] = address(new MockEffectSettlementChainlinkFeed(2e8, 8));
        sources[1] = address(new MockEffectSettlementChainlinkFeed(2e8, 8));
        vm.prank(_atomist);
        _priceManager.setAssetsPriceSources(assets, sources);
    }

    function testBridgeRevertsWhenGrantedTokenIsNotTheCoreLinkedOne() public {
        _grant(address(_usdc), address(_other));
        CoreSimulatorLib.forceSpotBalance(address(_vault), LINKED_TOKEN, LINKED_CORE_WEI);
        _refreshAndTotalAssets();

        vm.expectRevert(
            abi.encodeWithSignature(
                "HyperCoreSendFuseBridgeTokenMismatch(uint64,address)",
                LINKED_TOKEN,
                address(_other)
            )
        );
        _send(HyperCoreLib.systemAddress(LINKED_TOKEN), LINKED_TOKEN);
        assertFalse(_isPending(), "nothing enqueued");
    }

    function testBridgeWithTheCoreLinkedGrantIsAccepted() public {
        _grant(address(_usdc), address(_linked));
        CoreSimulatorLib.forceSpotBalance(address(_vault), LINKED_TOKEN, LINKED_CORE_WEI);
        _refreshAndTotalAssets();

        _send(HyperCoreLib.systemAddress(LINKED_TOKEN), LINKED_TOKEN);
        assertTrue(_isPending(), "bridge enqueued");
    }

    /// @dev Token 0: `tokenInfo(0).evmContract` is the CoreDepositWallet; its `token()` is the granted USDC.
    function testUsdcBridgeAcceptsTheDepositWalletToken() public {
        _grant(address(_usdc), address(_linked));
        CoreSimulatorLib.forceSpotBalance(address(_vault), USDC_TOKEN, 1_000e8);
        _refreshAndTotalAssets();

        _send(HyperCoreLib.systemAddress(USDC_TOKEN), USDC_TOKEN);
        assertTrue(_isPending(), "USDC bridge enqueued");
    }

    function testUsdcBridgeRevertsWhenGrantedIsNotTheWalletToken() public {
        _grant(address(_other), address(_linked));
        CoreSimulatorLib.forceSpotBalance(address(_vault), USDC_TOKEN, 1_000e8);
        _refreshAndTotalAssets();

        vm.expectRevert(
            abi.encodeWithSignature("HyperCoreSendFuseBridgeTokenMismatch(uint64,address)", USDC_TOKEN, address(_other))
        );
        _send(HyperCoreLib.systemAddress(USDC_TOKEN), USDC_TOKEN);
    }

    /// @dev A self-send (spot -> native perp of the vault itself) has no EVM effect, so a mismatching grant does not
    ///      matter there.
    function testSelfSendIsNotChecked() public {
        _grant(address(_other), address(_linked));
        CoreSimulatorLib.forceSpotBalance(address(_vault), USDC_TOKEN, 1_000e8);
        _refreshAndTotalAssets();

        _send(address(_vault), HyperCoreLib.SPOT_DEX, HyperCoreLib.NATIVE_PERP_DEX, USDC_TOKEN);
        assertTrue(_isPending(), "self-send enqueued");
    }

    /// @dev Replaces the whole market 55 substrate list: base set, `LINKED_TOKEN` granted as `linkedGranted_`.
    function _grant(address usdcGranted_, address linkedGranted_) internal {
        bytes32[] memory substrates = new bytes32[](11);
        substrates[0] = HyperCoreSubstrateLib.encodeSpotToken(USDC_TOKEN, usdcGranted_);
        substrates[1] = HyperCoreSubstrateLib.encodePerpMarket(HYPE_PERP, 1_000_000e6, false);
        substrates[2] = HyperCoreSubstrateLib.encodeDestination(HyperCoreLib.systemAddress(USDC_TOKEN));
        substrates[3] = HyperCoreSubstrateLib.encodeDestination(address(_vault));
        substrates[4] = HyperCoreSubstrateLib.encodeBuilder(_builder, 100);
        substrates[5] = HyperCoreSubstrateLib.encodeSendCap(USDC_TOKEN, type(uint128).max);
        substrates[6] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.WindowTransferSeconds, 2);
        substrates[7] = HyperCoreSubstrateLib.encodeConfig(
            HyperCoreSubstrateLib.ConfigKey.MaxUsdClassTransferUsd6,
            1_000_000e6
        );
        substrates[8] = HyperCoreSubstrateLib.encodeSpotToken(LINKED_TOKEN, linkedGranted_);
        substrates[9] = HyperCoreSubstrateLib.encodeSendCap(LINKED_TOKEN, type(uint128).max);
        substrates[10] = HyperCoreSubstrateLib.encodeDestination(HyperCoreLib.systemAddress(LINKED_TOKEN));
        vm.prank(_fuseManager);
        PlasmaVaultGovernance(address(_vault)).grantMarketSubstrates(
            MARKET_ID,
            NavJumpFloorFixture.withFloor(substrates)
        );
    }

    function _send(address destination_, uint64 tokenIndex_) internal {
        _send(destination_, HyperCoreLib.SPOT_DEX, HyperCoreLib.SPOT_DEX, tokenIndex_);
    }

    function _send(address destination_, uint32 sourceDex_, uint32 destinationDex_, uint64 tokenIndex_) internal {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_sendFuse),
            abi.encodeWithSelector(
                HyperCoreSendFuse.enterSendAsset.selector,
                HyperCoreSendFuseSendAssetData({
                    destination: destination_,
                    sourceDex: sourceDex_,
                    destinationDex: destinationDex_,
                    tokenIndex: tokenIndex_,
                    amountWei: tokenIndex_ == USDC_TOKEN ? 10e8 : BRIDGE_WEI
                })
            )
        );
        _vault.execute(actions);
    }
}
