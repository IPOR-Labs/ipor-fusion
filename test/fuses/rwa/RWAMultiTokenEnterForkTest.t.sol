// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {RWAForkTestBase} from "./RWAForkTestBase.t.sol";
import {RWAErrors} from "../../../contracts/fuses/rwa/errors/RWAErrors.sol";
import {RWASubstrateLib, RWASubstrateType} from "../../../contracts/fuses/rwa/lib/RWASubstrateLib.sol";
import {IRWAExecutor} from "../../../contracts/fuses/rwa/IRWAExecutor.sol";

/// @dev Mainnet USDT does not return a bool from `transfer` — declare a non-standard interface
///      so the whale-funding helper compiles.
interface INonStandardERC20Transfer {
    function transfer(address to_, uint256 amount_) external;
}

/// @title RWAMultiTokenEnterForkTest
/// @notice Fork coverage for enter flows that mix multiple allowed assets, including decimals
///         differences (USDC 6d, DAI 18d) and oracle-driven underlying conversion.
contract RWAMultiTokenEnterForkTest is RWAForkTestBase {
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

        (uint256 total,,) = IRWAExecutor(_executorAddress()).getBalanceFuseSnapshot();
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

        (uint256 total,,) = IRWAExecutor(_executorAddress()).getBalanceFuseSnapshot();
        assertEq(total, 100e6, "DAI -> USDC underlying converted");
    }

    /// @notice Both assets' prices are consulted on the oracle. If we bump DAI to $1.10, the
    ///         resulting underlying credit must scale accordingly.
    function test_fork_multipleAssets_priceOracleUsedForBoth() public {
        _grantWithDai();

        // DAI at $1.10, USDC at $1. 100 DAI (18d) @ $1.10 -> 110 USDC-worth (6d).
        oracle.setPrice(DAI, 110e6, 8);
        deal(DAI, address(vault), 100e18);
        _enter(DAI, 100e18, balanceAccountA);

        (uint256 total,,) = IRWAExecutor(_executorAddress()).getBalanceFuseSnapshot();
        assertEq(total, 110e6, "oracle price applied to DAI -> USDC conversion");
    }

    /// @notice An asset not granted to the market must revert with the dedicated substrate error.
    function test_fork_unsupportedAssetReverts() public {
        // DAI is NOT in the default grant set.
        oracle.setPrice(DAI, 1e8, 8);
        deal(DAI, address(vault), 100e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                RWAErrors.RWAUnsupportedSubstrate.selector,
                uint8(RWASubstrateType.ASSET),
                RWASubstrateLib.encodeAssetSubstrate(DAI)
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
        subs[0] = RWASubstrateLib.encodeAssetSubstrate(USDC);
        subs[1] = RWASubstrateLib.encodeAssetSubstrate(USDT);
        subs[2] = RWASubstrateLib.encodeAssetSubstrate(DAI);
        subs[3] = RWASubstrateLib.encodeBalanceAccountSubstrate(balanceAccountA);
        subs[4] = RWASubstrateLib.encodeBalanceAccountSubstrate(balanceAccountB);
        subs[5] = RWASubstrateLib.encodeCustodianSubstrate(custodianA);
        subs[6] = RWASubstrateLib.encodeCustodianSubstrate(custodianB);
        subs[7] =
            RWASubstrateLib.encodeTargetSubstrate(address(rwaProtocol), bytes4(keccak256("deposit(address,uint256)")));
        subs[8] = RWASubstrateLib.encodeStalenessMaxSubstrate(STALENESS_MAX_S);
        subs[9] = RWASubstrateLib.encodeBigChangeBpsSubstrate(BIG_CHANGE_BPS);
        subs[10] = RWASubstrateLib.encodeDustThresholdSubstrate(DUST_THRESHOLD);
        subs[11] = RWASubstrateLib.encodeMinUpdateIntervalSubstrate(MIN_UPDATE_INTERVAL_S);
        _grantSubstrates(subs);
        _syncExecutorSubstrates();
    }
}
