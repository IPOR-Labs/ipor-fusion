// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {FuseStorageLib} from "../../libraries/FuseStorageLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {OracleSqrtPriceX96Lib} from "../../libraries/math/OracleSqrtPriceX96Lib.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {
    AreodromeSlipstreamSubstrateLib,
    AreodromeSlipstreamSubstrateType,
    AreodromeSlipstreamSubstrate
} from "./AreodromeSlipstreamLib.sol";
import {INonfungiblePositionManager} from "./ext/INonfungiblePositionManager.sol";
import {ICLPool} from "./ext/ICLPool.sol";
import {ISlipstreamSugar} from "./ext/ISlipstreamSugar.sol";
import {ICLGauge} from "./ext/ICLGauge.sol";

/// @title AreodromeSlipstreamBalanceFuse
/// @notice Contract responsible for managing Aerodrome Slipstream balance calculations
/// @dev This contract handles balance tracking for Plasma Vault positions in Aerodrome Slipstream pools and gauges.
///      Uses a curated storage-based list of position IDs to prevent DoS attacks via unbounded NFT enumeration.
///      Only positions that were legitimately created by the vault (tracked in FuseStorageLib) are included
///      in the balance calculation, preventing malicious actors from inflating gas costs by transferring
///      arbitrary NFTs to the vault.
///      Security: the token0/token1 composition of every position is derived from an oracle-implied
///      `sqrtPriceX96` (computed from `PriceOracleMiddleware` prices), never from the pool's live
///      `slot0().sqrtPriceX96`. The pool spot price is single-block manipulable (e.g. via a flash-loan
///      swap that pushes the price to a position's range edge); pricing the composition with it while
///      valuing the resulting legs with an independent oracle would let an attacker inflate or deflate
///      the reported market NAV within one transaction. Deriving the composition price from the same
///      oracle that prices the legs makes the two mutually consistent, so a same-transaction pool swap
///      cannot move NAV.
contract AreodromeSlipstreamBalanceFuse is IMarketBalanceFuse {
    using Address for address;

    error InvalidAddress();
    error InvalidReturnData();

    uint256 public immutable MARKET_ID;
    address public immutable NONFUNGIBLE_POSITION_MANAGER;
    address public immutable SLIPSTREAM_SUPERCHAIN_SUGAR;
    address public immutable FACTORY;

    constructor(uint256 marketId_, address nonfungiblePositionManager_, address slipstreamSuperchainSugar_) {
        if (nonfungiblePositionManager_ == address(0)) {
            revert InvalidAddress();
        }

        if (slipstreamSuperchainSugar_ == address(0)) {
            revert InvalidAddress();
        }

        MARKET_ID = marketId_;
        NONFUNGIBLE_POSITION_MANAGER = nonfungiblePositionManager_;
        SLIPSTREAM_SUPERCHAIN_SUGAR = slipstreamSuperchainSugar_;
        FACTORY = INonfungiblePositionManager(nonfungiblePositionManager_).factory();

        if (FACTORY == address(0)) {
            revert InvalidAddress();
        }
    }

    /// @notice Calculates the total balance of the Plasma Vault in Aerodrome Slipstream protocol
    /// @dev This function:
    ///      1. Retrieves all substrates (pool and gauge addresses) configured for the market
    ///      2. For Pool substrates: uses curated storage list, filters by pool, and counts only
    ///         positions still custodied by the vault (ownerOf == address(this)) to prevent DoS
    ///         attacks and to avoid double-counting gauge-staked positions
    ///      3. For Gauge substrates: uses stakedValues which is already filtered by gauge
    ///      4. Converts token amounts to USD using price oracle middleware
    ///      Each tokenId is valued by exactly one branch: Pool if the vault owns the NFT, Gauge if
    ///      the gauge does. Once a position is staked, its NFT is transferred to the gauge, so the
    ///      Pool branch skips it (via the ownerOf check) and only the Gauge branch (principal-only,
    ///      since staked positions no longer accrue collectable LP fees) values it.
    ///      The token0/token1 split used for both branches (`sqrtPriceX96`) is NOT read from the pool's
    ///      live `slot0()` - it is derived from `PriceOracleMiddleware` prices via `_oracleSqrtPriceX96`,
    ///      so it cannot be moved by a same-transaction pool swap.
    /// @return The total balance of the Plasma Vault in USD, normalized to WAD (18 decimals)
    function balanceOf() external view override returns (uint256) {
        bytes32[] memory grantedSubstrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);
        uint256 len = grantedSubstrates.length;

        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();

        uint256 balance;
        address token0;
        address token1;
        uint256 amount0;
        uint256 amount1;
        uint256[] memory tokenIds;
        uint256 tokenIdsLen;
        uint160 sqrtPriceX96;

        if (len == 0) {
            return 0;
        }

        AreodromeSlipstreamSubstrate memory substrate;

        for (uint256 i; i < len; i++) {
            substrate = AreodromeSlipstreamSubstrateLib.bytes32ToSubstrate(grantedSubstrates[i]);
            amount0 = 0;
            amount1 = 0;

            if (substrate.substrateType == AreodromeSlipstreamSubstrateType.Pool) {
                // Use curated storage list instead of unbounded ERC721 enumeration
                // This prevents DoS attacks where malicious actors transfer arbitrary NFTs to the vault
                uint256[] memory storedTokenIds = FuseStorageLib.getAerodromeSlipstreamTokenIds().tokenIds;
                tokenIdsLen = storedTokenIds.length;

                token0 = ICLPool(substrate.substrateAddress).token0();
                token1 = ICLPool(substrate.substrateAddress).token1();
                sqrtPriceX96 = _oracleSqrtPriceX96(token0, token1, priceOracleMiddleware);

                for (uint256 j; j < tokenIdsLen; j++) {
                    // Filter: skip positions no longer custodied by the vault (e.g. staked in a
                    // gauge, where the NFT has been transferred out) before the more expensive
                    // pool-membership check, then only include positions that belong to the
                    // current substrate pool
                    if (
                        _isOwnedByVault(storedTokenIds[j]) &&
                        _isPositionForPool(storedTokenIds[j], substrate.substrateAddress)
                    ) {
                        (amount0, amount1) = _addPrincipal(amount0, amount1, storedTokenIds[j], sqrtPriceX96);
                        (amount0, amount1) = _addFees(amount0, amount1, storedTokenIds[j]);
                    }
                }

                balance += _convertToUsd(amount0, token0, priceOracleMiddleware);
                balance += _convertToUsd(amount1, token1, priceOracleMiddleware);
            } else if (substrate.substrateType == AreodromeSlipstreamSubstrateType.Gauge) {
                // Gauge's stakedValues is already filtered - returns only positions staked in this gauge
                tokenIds = ICLGauge(substrate.substrateAddress).stakedValues(address(this));
                tokenIdsLen = tokenIds.length;
                token0 = ICLGauge(substrate.substrateAddress).token0();
                token1 = ICLGauge(substrate.substrateAddress).token1();
                sqrtPriceX96 = _oracleSqrtPriceX96(token0, token1, priceOracleMiddleware);

                for (uint256 j; j < tokenIdsLen; j++) {
                    (amount0, amount1) = _addPrincipal(amount0, amount1, tokenIds[j], sqrtPriceX96);
                }

                balance += _convertToUsd(amount0, token0, priceOracleMiddleware);
                balance += _convertToUsd(amount1, token1, priceOracleMiddleware);
            }
        }
        return balance;
    }

    /// @notice Checks if the vault (this contract, via delegatecall) still custodies the position NFT
    /// @dev Positions that have been staked in a gauge have their NFT transferred out of the vault,
    ///      so this check excludes them from the Pool branch, leaving them to be valued exactly once
    ///      by the Gauge branch. Checked before `_isPositionForPool` because it is cheaper (one
    ///      staticcall returning a single word vs. `positions()` plus a pool-address computation),
    ///      so positions that fail this check are filtered out at the lowest possible cost.
    /// @param tokenId_ The NFT token ID to check
    /// @return True if the vault currently owns the NFT, false otherwise
    function _isOwnedByVault(uint256 tokenId_) internal view returns (bool) {
        return INonfungiblePositionManager(NONFUNGIBLE_POSITION_MANAGER).ownerOf(tokenId_) == address(this);
    }

    /// @notice Checks if a position NFT belongs to a specific pool
    /// @param tokenId_ The NFT token ID to check
    /// @param poolAddress_ The pool address to match against
    /// @return True if the position belongs to the pool, false otherwise
    function _isPositionForPool(uint256 tokenId_, address poolAddress_) internal view returns (bool) {
        // Why functionStaticCall instead of direct INonfungiblePositionManager(NONFUNGIBLE_POSITION_MANAGER).positions(tokenId_)?
        //
        // 1. STATICCALL guarantees read-only execution - when calling an external contract, staticcall
        //    ensures the target cannot modify state, providing an additional security layer even though
        //    positions() is declared as view. This is enforced at EVM level, not just Solidity compiler level.
        //
        // 2. Selective field extraction - positions() returns 12 fields (nonce, operator, token0, token1,
        //    tickSpacing, tickLower, tickUpper, liquidity, feeGrowthInside0LastX128, feeGrowthInside1LastX128,
        //    tokensOwed0, tokensOwed1), but we only need 3 (token0, token1, tickSpacing). A direct call would
        //    require declaring all 12 return variables and ABI-decoding the entire response.
        //
        // 3. Gas efficiency - raw bytes + assembly allows reading only the needed fields at specific memory
        //    offsets (96, 128, 160 bytes) without decoding unused fields.
        //
        // 4. Stack depth compatibility - a direct call with 12 return values can cause "stack too deep" errors
        //    when compiling without the optimizer. This approach avoids that limitation by using memory instead
        //    of stack variables.
        bytes memory returnData = NONFUNGIBLE_POSITION_MANAGER.functionStaticCall(
            abi.encodeWithSelector(INonfungiblePositionManager.positions.selector, tokenId_)
        );

        if (returnData.length < 160) revert InvalidReturnData();

        address posToken0;
        address posToken1;
        int24 tickSpacing;

        assembly {
            posToken0 := mload(add(returnData, 96))
            posToken1 := mload(add(returnData, 128))
            tickSpacing := mload(add(returnData, 160))
        }

        // Compute the pool address for this position
        address computedPool = AreodromeSlipstreamSubstrateLib.getPoolAddress(
            FACTORY,
            posToken0,
            posToken1,
            tickSpacing
        );

        return computedPool == poolAddress_;
    }

    function _addPrincipal(
        uint256 amount0_,
        uint256 amount1_,
        uint256 tokenId_,
        uint160 sqrtPriceX96_
    ) internal view returns (uint256 newAmount0, uint256 newAmount1) {
        (uint256 principal0, uint256 principal1) = ISlipstreamSugar(SLIPSTREAM_SUPERCHAIN_SUGAR).principal(
            INonfungiblePositionManager(NONFUNGIBLE_POSITION_MANAGER),
            tokenId_,
            sqrtPriceX96_
        );

        newAmount0 = principal0 + amount0_;
        newAmount1 = principal1 + amount1_;

        return (newAmount0, newAmount1);
    }

    function _addFees(
        uint256 amount0_,
        uint256 amount1_,
        uint256 tokenId_
    ) internal view returns (uint256 newAmount0, uint256 newAmount1) {
        (uint256 fees0, uint256 fees1) = ISlipstreamSugar(SLIPSTREAM_SUPERCHAIN_SUGAR).fees(
            INonfungiblePositionManager(NONFUNGIBLE_POSITION_MANAGER),
            tokenId_
        );

        newAmount0 = fees0 + amount0_;
        newAmount1 = fees1 + amount1_;

        return (newAmount0, newAmount1);
    }

    function _convertToUsd(
        uint256 amount_,
        address token_,
        address priceOracleMiddleware_
    ) internal view returns (uint256) {
        (uint256 priceToken, uint256 priceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware_).getAssetPrice(
            token_
        );

        return IporMath.convertToWad((amount_) * priceToken, IERC20Metadata(token_).decimals() + priceDecimals);
    }

    /// @notice Derives the sqrt price (Q64.96) that would make the pool's raw token1/token0 price
    /// consistent with the independent `PriceOracleMiddleware` prices of token0 and token1
    /// @dev This replaces reading the pool's live `slot0().sqrtPriceX96`, which is manipulable within
    ///      a single transaction (e.g. a flash-loan swap that pushes the price to a position's range
    ///      edge). Using an oracle-implied price for the composition split, while the resulting legs
    ///      are also priced by the oracle in `_convertToUsd`, means both the composition and the legs
    ///      come from the same manipulation-resistant source, so a same-transaction pool swap cannot
    ///      change the reported NAV.
    ///      `getAssetPrice` returns `(price, priceDecimals)` = USD value of one WHOLE token scaled by
    ///      `10^priceDecimals`. Given `p0`/`d0` for token0 and `p1`/`d1` for token1, and raw-unit
    ///      decimals `t0`/`t1`, the raw token1-per-token0 price is:
    ///        P = (p0 * 10^(d1+t1)) / (p1 * 10^(d0+t0))
    ///      and `sqrtPriceX96 = floor(sqrt(P) * 2^96) = floor(sqrt(P * 2^192))` for P < 2^64; above that it is rounded down
    ///      by at most 2^32 units (relative error <= 2^-96, see OracleSqrtPriceX96Lib.fromRatio).
    ///      The computation is delegated to `OracleSqrtPriceX96Lib.fromOracle` (single 512-bit `mulDiv`, decimal
    ///      scale applied before it) and supports the full Q64.96 range; for realistic prices and decimals it reverts
    ///      only when the oracle-implied P >= 2^128.
    /// @param token0_ The pool's token0 address
    /// @param token1_ The pool's token1 address
    /// @param priceOracleMiddleware_ The address of the price oracle middleware
    /// @return The oracle-implied sqrt price of the pool, in Q64.96 format
    function _oracleSqrtPriceX96(
        address token0_,
        address token1_,
        address priceOracleMiddleware_
    ) internal view returns (uint160) {
        return OracleSqrtPriceX96Lib.fromOracle(token0_, token1_, priceOracleMiddleware_);
    }
}
