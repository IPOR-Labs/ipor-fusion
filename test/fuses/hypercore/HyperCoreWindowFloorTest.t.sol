// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {HyperCoreEffectSettlementBase} from "./HyperCoreEffectSettlementBase.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {FuseAction} from "../../../contracts/interfaces/IPlasmaVault.sol";
import {
    HyperCoreDepositFuse,
    HyperCoreDepositFuseEnterData
} from "../../../contracts/fuses/hypercore/HyperCoreDepositFuse.sol";
import {
    HyperCoreMarginFuse,
    HyperCoreMarginFuseEnterData
} from "../../../contracts/fuses/hypercore/HyperCoreMarginFuse.sol";
import {
    HyperCoreSendFuse,
    HyperCoreSendFuseSendAssetData
} from "../../../contracts/fuses/hypercore/HyperCoreSendFuse.sol";
import {
    HyperCoreBuilderFeeFuse,
    HyperCoreBuilderFeeFuseEnterData
} from "../../../contracts/fuses/hypercore/HyperCoreBuilderFeeFuse.sol";
import {HyperCoreLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreLib.sol";
import {HyperCoreSubstrateLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreSubstrateLib.sol";
import {NavJumpFloorFixture} from "./HyperCoreNavJumpFloorFixture.sol";

/// @notice IL-9529 (D-004): `Config{WindowTransferSeconds}` below `HyperCorePendingLib.MIN_WINDOW_TRANSFER_SECONDS` (2)
///         is rejected by every fuse that reads it (deposit, margin, send, builder fee) with the fuse's own
///         `<Fuse>InvalidWindow(value)`; an unset key and an explicit 2 both record a 2 s window. A configured 0
///         is also invalid (the existing zero-config tests of each fuse stay as they are).
contract HyperCoreWindowFloorTest is HyperCoreEffectSettlementBase {
    uint8 private constant DEPOSIT = 0;
    uint8 private constant MARGIN = 1;
    uint8 private constant SEND = 2;
    uint8 private constant BUILDER_FEE = 3;

    // ------------------------------------------------------------------
    // window 1 reverts in every fuse
    // ------------------------------------------------------------------
    function testDepositWindowOneReverts() public {
        uint64 untilBefore = _pendingUntil();
        _grantWindow(true, 1);
        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreDepositFuse.HyperCoreDepositFuseInvalidWindow.selector, uint240(1))
        );
        _act(DEPOSIT);
        assertEq(_pendingUntil(), untilBefore, "no new record");
    }

    function testMarginWindowOneReverts() public {
        _prepareCoreFunds();
        uint64 untilBefore = _pendingUntil();
        _grantWindow(true, 1);
        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreMarginFuse.HyperCoreMarginFuseInvalidWindow.selector, uint240(1))
        );
        _act(MARGIN);
        assertEq(_pendingUntil(), untilBefore, "no new record");
    }

    function testSendWindowOneReverts() public {
        _prepareCoreFunds();
        uint64 untilBefore = _pendingUntil();
        _grantWindow(true, 1);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreSendFuse.HyperCoreSendFuseInvalidWindow.selector, uint240(1)));
        _act(SEND);
        assertEq(_pendingUntil(), untilBefore, "no new record");
    }

    function testBuilderFeeWindowOneReverts() public {
        _prepareCoreFunds();
        uint64 untilBefore = _pendingUntil();
        _grantWindow(true, 1);
        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreBuilderFeeFuse.HyperCoreBuilderFeeFuseInvalidWindow.selector, uint240(1))
        );
        _act(BUILDER_FEE);
        assertEq(_pendingUntil(), untilBefore, "no new record");
    }

    // ------------------------------------------------------------------
    // window 2 is accepted and recorded as 2 s
    // ------------------------------------------------------------------
    function testDepositWindowTwoIsAccepted() public {
        _grantWindow(true, 2);
        _actAndAssertWindowTwo(DEPOSIT);
    }

    function testMarginWindowTwoIsAccepted() public {
        _prepareCoreFunds();
        _grantWindow(true, 2);
        _actAndAssertWindowTwo(MARGIN);
    }

    function testSendWindowTwoIsAccepted() public {
        _prepareCoreFunds();
        _grantWindow(true, 2);
        _actAndAssertWindowTwo(SEND);
    }

    function testBuilderFeeWindowTwoIsAccepted() public {
        _prepareCoreFunds();
        _grantWindow(true, 2);
        _actAndAssertWindowTwo(BUILDER_FEE);
    }

    // ------------------------------------------------------------------
    // unset key defaults to 2 s
    // ------------------------------------------------------------------
    function testDepositUnsetWindowDefaultsToTwo() public {
        _grantWindow(false, 0);
        _actAndAssertWindowTwo(DEPOSIT);
    }

    function testMarginUnsetWindowDefaultsToTwo() public {
        _prepareCoreFunds();
        _grantWindow(false, 0);
        _actAndAssertWindowTwo(MARGIN);
    }

    function testSendUnsetWindowDefaultsToTwo() public {
        _prepareCoreFunds();
        _grantWindow(false, 0);
        _actAndAssertWindowTwo(SEND);
    }

    function testBuilderFeeUnsetWindowDefaultsToTwo() public {
        _prepareCoreFunds();
        _grantWindow(false, 0);
        _actAndAssertWindowTwo(BUILDER_FEE);
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------
    function _actAndAssertWindowTwo(uint8 fuse_) private {
        uint256 start = block.timestamp;
        _act(fuse_);
        assertEq(_pendingUntil(), uint64(start + 2), "pendingUntil = now + 2");
    }

    /// @dev Moves 100k USDC to Core and settles it, so the vault has a Core account and spot funds.
    function _prepareCoreFunds() private {
        _act(DEPOSIT);
        _settle(2);
    }

    /// @dev Replaces the market-55 substrate list with the base production set; the `WindowTransferSeconds` key is
    ///      included only when `set_` (an unset key must default to 2 s).
    function _grantWindow(bool set_, uint240 window_) private {
        bytes32[] memory substrates = new bytes32[](set_ ? 8 : 7);
        substrates[0] = HyperCoreSubstrateLib.encodeSpotToken(USDC_TOKEN, address(_usdc));
        substrates[1] = HyperCoreSubstrateLib.encodePerpMarket(HYPE_PERP, 1_000_000e6, false);
        substrates[2] = HyperCoreSubstrateLib.encodeDestination(HyperCoreLib.systemAddress(USDC_TOKEN));
        substrates[3] = HyperCoreSubstrateLib.encodeDestination(address(_vault));
        substrates[4] = HyperCoreSubstrateLib.encodeBuilder(_builder, 100);
        substrates[5] = HyperCoreSubstrateLib.encodeSendCap(USDC_TOKEN, type(uint128).max);
        substrates[6] = HyperCoreSubstrateLib.encodeConfig(
            HyperCoreSubstrateLib.ConfigKey.MaxUsdClassTransferUsd6,
            1_000_000e6
        );
        if (set_) {
            substrates[7] = HyperCoreSubstrateLib.encodeConfig(
                HyperCoreSubstrateLib.ConfigKey.WindowTransferSeconds,
                window_
            );
        }
        vm.prank(_fuseManager);
        PlasmaVaultGovernance(address(_vault)).grantMarketSubstrates(
            MARKET_ID,
            NavJumpFloorFixture.withFloor(substrates)
        );
    }

    function _pendingUntil() private view returns (uint64) {
        return uint64(uint256(vm.load(address(_vault), PENDING_SLOT)));
    }

    function _act(uint8 fuse_) private {
        FuseAction[] memory actions = new FuseAction[](1);
        if (fuse_ == DEPOSIT) {
            actions[0] = FuseAction(
                address(_depositFuse),
                abi.encodeWithSelector(
                    HyperCoreDepositFuse.enter.selector,
                    HyperCoreDepositFuseEnterData({tokenIndex: USDC_TOKEN, amount: 100_000e6})
                )
            );
        } else if (fuse_ == MARGIN) {
            actions[0] = FuseAction(
                address(_marginFuse),
                abi.encodeWithSelector(
                    HyperCoreMarginFuse.enter.selector,
                    HyperCoreMarginFuseEnterData({usd6: 10_000e6, toPerp: true})
                )
            );
        } else if (fuse_ == SEND) {
            actions[0] = FuseAction(
                address(_sendFuse),
                abi.encodeWithSelector(
                    HyperCoreSendFuse.enterSendAsset.selector,
                    HyperCoreSendFuseSendAssetData({
                        destination: HyperCoreLib.systemAddress(USDC_TOKEN),
                        sourceDex: HyperCoreLib.SPOT_DEX,
                        destinationDex: HyperCoreLib.SPOT_DEX,
                        tokenIndex: USDC_TOKEN,
                        amountWei: 10_000e8
                    })
                )
            );
        } else {
            actions[0] = FuseAction(
                address(_builderFeeFuse),
                abi.encodeWithSelector(
                    HyperCoreBuilderFeeFuse.enter.selector,
                    HyperCoreBuilderFeeFuseEnterData({builder: _builder, maxFeeRateDecibps: 10})
                )
            );
        }
        _vault.execute(actions);
    }
}
