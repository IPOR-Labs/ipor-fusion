// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ExternalStateForkTestBase} from "./ExternalStateForkTestBase.t.sol";
import {ExternalStateErrors} from "../../../contracts/fuses/external_state/errors/ExternalStateErrors.sol";
import {ExternalStateSubstrateLib, ExternalStateSubstrateType} from "../../../contracts/fuses/external_state/lib/ExternalStateSubstrateLib.sol";
import {IExternalStateExecutor} from "../../../contracts/fuses/external_state/IExternalStateExecutor.sol";

/// @dev Mainnet USDT does not return a bool from `transfer` — declare a non-standard interface
///      so the whale-funding helper compiles.
interface INonStandardERC20Transfer {
    function transfer(address to_, uint256 amount_) external;
}

/// @title ExternalStateMultiTokenEnterForkTest
/// @notice Fork coverage for enter flows that mix multiple allowed assets, including decimals
///         differences (USDC 6d, DAI 18d) and oracle-driven underlying conversion.
contract ExternalStateMultiTokenEnterForkTest is ExternalStateForkTestBase {
    /// @dev Binance hot wallet — USDT whale used because `deal()` cannot probe the storage slot
    ///      of the mainnet USDT proxy.
    address private constant _USDT_WHALE = 0xF977814e90dA44bFA03b6295A0616a897441aceC;

    /// @notice Enter with both allowed assets (USDC, USDT) succeeds and each enter credits the
    ///         balance account independently. USDT also has 6 decimals, matching USDC, so we
    ///         expect simple sum accounting.
    function test_fork_multipleAssets_bothAllowed_enterSuccess() public {
        deal(USDC, address(vault), 100e6);
        // `deal()` doesn't work on mainnet USDT (proxy storage layout) — fund via whale transfer.
        vm.prank(_USDT_WHALE);
        INonStandardERC20Transfer(USDT).transfer(address(vault), 50e6);

        _enter(USDC, 100e6, balanceAccountA);
        _enter(USDT, 50e6, balanceAccountA);

        (uint256 total,,) = IExternalStateExecutor(_executorAddress()).getBalanceFuseSnapshot();
        assertEq(total, 150e6, "both assets credited");
    }

    /// @notice Underlying is USDC (6d). Entering with DAI (18d) — after re-granting DAI as an
    ///         allowed asset — must convert via the oracle to the 6-decimal underlying amount.
    function test_fork_multipleAssets_underlyingIsUSDC_valueConvertedCorrectly() public {
        // Extend substrates to include DAI.
        _grantWithDai();

        // 100 DAI (18d) @ $1 -> 100 USDC-worth (6d).
        deal(DAI, address(vault), 100e18);
        _enter(DAI, 100e18, balanceAccountA);

        (uint256 total,,) = IExternalStateExecutor(_executorAddress()).getBalanceFuseSnapshot();
        assertEq(total, 100e6, "DAI -> USDC underlying converted");
    }

    /// @notice Both assets' prices are consulted on the oracle. If we bump DAI to $1.10, the
    ///         resulting underlying credit must scale accordingly.
    function test_fork_multipleAssets_priceOracleUsedForBoth() public {
        _grantWithDai();

        // DAI at $1.10, USDC at $1. 100 DAI (18d) @ $1.10 -> 110 USDC-worth (6d).
        _setPrice(DAI, 1.1e18);
        deal(DAI, address(vault), 100e18);
        _enter(DAI, 100e18, balanceAccountA);

        (uint256 total,,) = IExternalStateExecutor(_executorAddress()).getBalanceFuseSnapshot();
        assertEq(total, 110e6, "oracle price applied to DAI -> USDC conversion");
    }

    /// @notice An asset not granted to the market must revert with the dedicated substrate error.
    function test_fork_unsupportedAssetReverts() public {
        // DAI is NOT in the default grant set.
        _setPrice(DAI, 1e18);
        deal(DAI, address(vault), 100e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                ExternalStateErrors.ExternalStateUnsupportedSubstrate.selector,
                uint8(ExternalStateSubstrateType.ASSET),
                ExternalStateSubstrateLib.encodeAssetSubstrate(DAI)
            )
        );
        _enter(DAI, 100e18, balanceAccountA);
    }

    // ============================================================
    // Helpers
    // ============================================================

    /// @dev Extend the default substrate grant set to include DAI as an allowed asset, then
    ///      re-sync the executor cache (substrate grants on the vault are read on every enter).
    function _grantWithDai() internal {
        bytes32[] memory subs = new bytes32[](12);
        subs[0] = ExternalStateSubstrateLib.encodeAssetSubstrate(USDC);
        subs[1] = ExternalStateSubstrateLib.encodeAssetSubstrate(USDT);
        subs[2] = ExternalStateSubstrateLib.encodeAssetSubstrate(DAI);
        subs[3] = ExternalStateSubstrateLib.encodeBalanceAccountSubstrate(balanceAccountA);
        subs[4] = ExternalStateSubstrateLib.encodeBalanceAccountSubstrate(balanceAccountB);
        subs[5] = ExternalStateSubstrateLib.encodeCustodianSubstrate(custodianA);
        subs[6] = ExternalStateSubstrateLib.encodeCustodianSubstrate(custodianB);
        subs[7] =
            ExternalStateSubstrateLib.encodeTargetSubstrate(address(externalStateProtocol), bytes4(keccak256("deposit(address,uint256)")));
        subs[8] = ExternalStateSubstrateLib.encodeStalenessMaxSubstrate(STALENESS_MAX_S);
        subs[9] = ExternalStateSubstrateLib.encodeBigChangeBpsSubstrate(BIG_CHANGE_BPS);
        subs[10] = ExternalStateSubstrateLib.encodeDustThresholdSubstrate(DUST_THRESHOLD);
        subs[11] = ExternalStateSubstrateLib.encodeMinUpdateIntervalSubstrate(MIN_UPDATE_INTERVAL_S);
        _grantSubstrates(subs);
        _syncExecutorSubstrates();
    }
}
