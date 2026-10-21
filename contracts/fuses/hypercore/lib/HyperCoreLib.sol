// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title HyperCoreLib
/// @notice Typed encoders and bounded readers for the HyperCore EVM precompiles.
/// @dev Precompile calldata/return layouts are based on the Hyperliquid HyperEVM
///      documentation and still require the live M0 fixtures before release.
library HyperCoreLib {
    // ---- HyperEVM system contracts ----
    /// @dev CoreWriter system contract; `sendRawAction` forwards an encoded action to HyperCore,
    ///      where it is applied asynchronously in a later L1 block
    address internal constant CORE_WRITER = 0x3333333333333333333333333333333333333333;

    // ---- HyperCore read precompiles ----
    /// @dev Read precompile: perp position of a user for a read index up to 65535
    ///      (szi, entryNtl, isolatedRawUsd, leverage, isIsolated)
    address internal constant POSITION_PRECOMPILE = address(0x800);
    /// @dev Read precompile: same layout as POSITION_PRECOMPILE, but accepts read indices above 65535 (HIP-3 markets)
    address internal constant POSITION2_PRECOMPILE = address(0x813);
    /// @dev Read precompile: spot balance of a user for a token index (total, hold, entryNtl) in Core wei
    address internal constant SPOT_BALANCE_PRECOMPILE = address(0x801);
    /// @dev Read precompile: USDC (6 decimals) withdrawable from the user's native perp account; native dex only
    address internal constant WITHDRAWABLE_PRECOMPILE = address(0x803);
    /// @dev Read precompile: perp market metadata for a read index
    ///      (coin, marginTableId, szDecimals, maxLeverage, onlyIsolated)
    address internal constant PERP_ASSET_INFO_PRECOMPILE = address(0x80A);
    /// @dev Read precompile: spot token metadata for a token index, including EVM contract and decimal offsets
    address internal constant TOKEN_INFO_PRECOMPILE = address(0x80C);
    /// @dev Read precompile: margin summary of a user on a perp dex (accountValue, marginUsed, ntlPos, rawUsd)
    address internal constant ACCOUNT_MARGIN_SUMMARY_PRECOMPILE = address(0x80F);
    /// @dev Read precompile: whether an address already exists as a HyperCore user
    address internal constant CORE_USER_EXISTS_PRECOMPILE = address(0x810);
    /// @dev Read precompile: oracle price of a perp market for a read index. Raw perp prices carry
    ///      `6 - szDecimals` decimals (human = raw / 10^(6 - szDecimals)); see `perpPxToPx1e8`.
    address internal constant ORACLE_PX_PRECOMPILE = address(0x807);
    /// @dev Read precompile: mark price of a perp market for a read index. Raw perp prices carry
    ///      `6 - szDecimals` decimals (human = raw / 10^(6 - szDecimals)); see `perpPxToPx1e8`.
    address internal constant MARK_PX_PRECOMPILE = address(0x806);
    /// @dev Read precompile: current HyperCore (L1) block number
    address internal constant L1_BLOCK_NUMBER_PRECOMPILE = address(0x809);
    /// @dev Gas forwarded to every precompile staticcall; bounds the cost of a single read
    uint256 internal constant PRECOMPILE_GAS = 100_000;

    // ---- Dex and token ids ----
    /// @dev Dex id that denotes the spot balance in `sendAsset` and CoreDepositWallet deposits
    uint32 internal constant SPOT_DEX = type(uint32).max;
    /// @dev Dex id of the native (non HIP-3) perp dex
    uint32 internal constant NATIVE_PERP_DEX = 0;
    /// @dev HyperCore token index of USDC
    uint64 internal constant USDC_TOKEN = 0;

    // ---- CoreWriter action encoding ----
    /// @dev Encoding version byte prefixed to every CoreWriter action:
    ///      bytes1(version) ++ bytes3(actionId) ++ abi.encode(fields)
    uint8 internal constant ACTION_VERSION = 1;
    /// @dev CoreWriter action: limit order (asset, isBuy, limitPx, sz, reduceOnly, tif, cloid)
    uint24 internal constant ACTION_LIMIT_ORDER = 1;
    /// @dev CoreWriter action: spot send (destination, token, amount)
    uint24 internal constant ACTION_SPOT_SEND = 6;
    /// @dev CoreWriter action: USD class transfer between spot and native perp (amount, toPerp)
    uint24 internal constant ACTION_USD_CLASS_TRANSFER = 7;
    /// @dev CoreWriter action: cancel order by order id (asset, oid)
    uint24 internal constant ACTION_CANCEL_BY_OID = 10;
    /// @dev CoreWriter action: cancel order by client order id (asset, cloid)
    uint24 internal constant ACTION_CANCEL_BY_CLOID = 11;
    /// @dev CoreWriter action: approve a maximum builder fee rate (maxFeeRateDecibps, builder)
    uint24 internal constant ACTION_APPROVE_BUILDER_FEE = 12;
    /// @dev CoreWriter action: send asset between users and dexes
    ///      (destination, subAccount, sourceDex, destinationDex, token, amount)
    uint24 internal constant ACTION_SEND_ASSET = 13;

    // ---- Order parameters and units ----
    /// @dev Scale factor from a 6-decimal USD amount to 18 decimals (WAD)
    uint256 internal constant USD6_TO_WAD = 1e12;
    /// @dev Raw perp prices from the mark/oracle precompiles have `6 - szDecimals` decimals; CoreWriter
    ///      `limitPx` has 8. Converting raw -> 1e8 therefore multiplies by 10^(2 + szDecimals).
    uint8 internal constant PERP_PX_RAW_TO_1E8_BASE_EXPONENT = 2;
    /// @dev Time in force: Add Liquidity Only (post-only; rejected if it would cross the book)
    uint8 internal constant TIF_ALO = 1;
    /// @dev Time in force: Good Til Cancelled (rests on the book until filled or cancelled)
    uint8 internal constant TIF_GTC = 2;
    /// @dev Time in force: Immediate Or Cancel (unfilled remainder is cancelled)
    uint8 internal constant TIF_IOC = 3;

    error HyperCorePrecompileFailed(address precompile);
    error HyperCoreDecimalConversionOverflow();
    error HyperCoreAmountNotRepresentable();

    /// @notice Spot balance of one token for one Core account (spot balance precompile 0x801).
    /// @dev All three fields are raw precompile values and are never rescaled here.
    struct SpotBalance {
        /// @dev Total balance INCLUDING the part on hold (open spot orders, pending sends), in Core wei of the
        ///      token, i.e. with `TokenInfo.weiDecimals` decimals. NAV uses this field.
        uint64 total;
        /// @dev Part of `total` currently on hold and not freely spendable, same units as `total`.
        uint64 hold;
        /// @dev Entry notional of the balance as reported by Core (USD-denominated). Informational only, not used
        ///      for NAV (spot tokens are priced through the vault's price oracle middleware).
        uint64 entryNtl;
    }

    /// @notice Margin summary of one Core account on one perp dex (account margin summary precompile 0x80F).
    /// @dev All amounts are USD with 6 decimals. The summary is per dex: native dex 0 or one HIP-3 dex, selected
    ///      by the `perpDex_` argument of `accountMarginSummary`. NAV relies only on `accountValue`; the other
    ///      fields are raw precompile values that the code does not interpret further.
    struct AccountMarginSummary {
        /// @dev Signed total equity of the account on this dex, in USD with 6 decimals: collateral (USD balance)
        ///      plus unrealized PnL of cross and isolated positions at the Core mark price, plus accrued funding,
        ///      minus fees. For a HIP-3 dex it is that dex's full equity. Positions must never be added on top of
        ///      it again. May be negative.
        int64 accountValue;
        /// @dev Margin currently locked by open positions and orders on this dex (USD, 6 decimals), as reported
        ///      by Core. Not used for NAV.
        uint64 marginUsed;
        /// @dev Total absolute notional of the open positions on this dex (USD, 6 decimals), as reported by
        ///      Core. Not used for NAV.
        uint64 ntlPos;
        /// @dev Signed raw USD balance of the account on this dex (USD, 6 decimals) before the mark-to-market
        ///      value of positions is added, i.e. `accountValue` is expected to equal `rawUsd` plus the signed
        ///      position values at mark price (see README, equity identity check). Not used for NAV.
        int64 rawUsd;
    }

    /// @notice Static data of a Core spot token (token info precompile 0x80C).
    struct TokenInfo {
        /// @dev Token symbol on Core
        string name;
        /// @dev Indices of the spot markets that trade this token
        uint64[] spots;
        /// @dev Share of trading fees paid to the deployer, as reported by Core
        uint64 deployerTradingFeeShare;
        /// @dev Core deployer address of the token
        address deployer;
        /// @dev Linked HyperEVM ERC-20 contract, zero when none is linked
        address evmContract;
        /// @dev Decimals of order sizes for this token
        uint8 szDecimals;
        /// @dev Decimals of the Core wei unit; the unit of `SpotBalance.total` and `SpotBalance.hold`
        uint8 weiDecimals;
        /// @dev Decimals of the linked EVM token minus `weiDecimals` (can be negative)
        int8 evmExtraWeiDecimals;
    }

    /// @notice Static data of a perp market (perp asset info precompile 0x80A).
    struct PerpAssetInfo {
        /// @dev Market name on Core, for HIP-3 markets prefixed with the dex name (for example `xyz:NVDA`)
        string coin;
        /// @dev Id of the margin table that defines margin requirements by notional
        uint32 marginTableId;
        /// @dev Decimals of order sizes for this market; raw prices carry `6 - szDecimals` decimals
        uint8 szDecimals;
        /// @dev Maximum leverage allowed on this market
        uint8 maxLeverage;
        /// @dev True when only isolated margin is allowed on this market
        bool onlyIsolated;
    }

    /// @notice Open position of a Core account in one perp market (position precompiles 0x800 and 0x813).
    struct Position {
        /// @dev Signed position size (positive long, negative short) with `PerpAssetInfo.szDecimals` decimals
        int64 szi;
        /// @dev Entry notional of the position in USD with 6 decimals
        uint64 entryNtl;
        /// @dev Raw USD margin held by the position when it is isolated (USD, 6 decimals, signed)
        int64 isolatedRawUsd;
        /// @dev Leverage of the position
        uint32 leverage;
        /// @dev True when the position uses isolated margin
        bool isIsolated;
    }

    function encodeLimitOrder(
        uint32 asset_,
        bool isBuy_,
        uint64 limitPx1e8_,
        uint64 sz1e8_,
        bool reduceOnly_,
        uint8 tif_,
        uint128 cloid_
    ) internal pure returns (bytes memory) {
        return _encode(ACTION_LIMIT_ORDER, abi.encode(asset_, isBuy_, limitPx1e8_, sz1e8_, reduceOnly_, tif_, cloid_));
    }

    function encodeSpotSend(
        address destination_,
        uint64 tokenIndex_,
        uint64 amount_
    ) internal pure returns (bytes memory) {
        return _encode(ACTION_SPOT_SEND, abi.encode(destination_, tokenIndex_, amount_));
    }

    function encodeUsdClassTransfer(uint64 amountUsd6_, bool toPerp_) internal pure returns (bytes memory) {
        return _encode(ACTION_USD_CLASS_TRANSFER, abi.encode(amountUsd6_, toPerp_));
    }

    function encodeCancelByOid(uint32 asset_, uint64 oid_) internal pure returns (bytes memory) {
        return _encode(ACTION_CANCEL_BY_OID, abi.encode(asset_, oid_));
    }

    function encodeCancelByCloid(uint32 asset_, uint128 cloid_) internal pure returns (bytes memory) {
        return _encode(ACTION_CANCEL_BY_CLOID, abi.encode(asset_, cloid_));
    }

    function encodeApproveBuilderFee(uint64 maxFeeRateDecibps_, address builder_) internal pure returns (bytes memory) {
        return _encode(ACTION_APPROVE_BUILDER_FEE, abi.encode(maxFeeRateDecibps_, builder_));
    }

    function encodeSendAsset(
        address destination_,
        address subAccount_,
        uint32 sourceDex_,
        uint32 destinationDex_,
        uint64 tokenIndex_,
        uint64 amount_
    ) internal pure returns (bytes memory) {
        return
            _encode(
                ACTION_SEND_ASSET,
                abi.encode(destination_, subAccount_, sourceDex_, destinationDex_, tokenIndex_, amount_)
            );
    }

    /// @dev Kept internal: callers can only send the typed payloads above.
    function sendRawAction(bytes memory payload_) internal {
        ICoreWriter(CORE_WRITER).sendRawAction(payload_);
    }

    function spotBalance(address user_, uint64 tokenIndex_) internal view returns (SpotBalance memory balance) {
        bytes memory result = _staticRead(SPOT_BALANCE_PRECOMPILE, abi.encode(user_, tokenIndex_));
        (balance.total, balance.hold, balance.entryNtl) = abi.decode(result, (uint64, uint64, uint64));
    }

    function accountMarginSummary(
        uint32 perpDex_,
        address user_
    ) internal view returns (AccountMarginSummary memory summary) {
        bytes memory result = _staticRead(ACCOUNT_MARGIN_SUMMARY_PRECOMPILE, abi.encode(perpDex_, user_));
        (summary.accountValue, summary.marginUsed, summary.ntlPos, summary.rawUsd) = abi.decode(
            result,
            (int64, uint64, uint64, int64)
        );
    }

    function tokenInfo(uint64 tokenIndex_) internal view returns (TokenInfo memory info) {
        bytes memory result = _staticRead(TOKEN_INFO_PRECOMPILE, abi.encode(tokenIndex_));
        info = abi.decode(result, (TokenInfo));
    }

    /// @dev `asset_` is the read index (for native markets equal to the action asset); callers convert with `readIndexOf`.
    function perpAssetInfo(uint32 asset_) internal view returns (PerpAssetInfo memory info) {
        bytes memory result = _staticRead(PERP_ASSET_INFO_PRECOMPILE, abi.encode(asset_));
        info = abi.decode(result, (PerpAssetInfo));
    }

    function withdrawable(address user_) internal view returns (uint64 amountUsd6) {
        bytes memory result = _staticRead(WITHDRAWABLE_PRECOMPILE, abi.encode(user_));
        amountUsd6 = abi.decode(result, (uint64));
    }

    function coreUserExists(address user_) internal view returns (bool exists) {
        bytes memory result = _staticRead(CORE_USER_EXISTS_PRECOMPILE, abi.encode(user_));
        exists = abi.decode(result, (bool));
    }

    /// @dev `asset_` is the read index (for native markets equal to the action asset); callers convert with `readIndexOf`.
    function position(address user_, uint32 asset_) internal view returns (Position memory value) {
        bytes memory result = _staticRead(POSITION_PRECOMPILE, abi.encode(user_, asset_));
        (value.szi, value.entryNtl, value.isolatedRawUsd, value.leverage, value.isIsolated) = abi.decode(
            result,
            (int64, uint64, int64, uint32, bool)
        );
    }

    /// @dev Same as `position()` but reads the 0x813 precompile, which can address read indices above 65535.
    ///      `readIndex_` is the read index (for native markets equal to the action asset); callers convert with `readIndexOf`.
    function position2(address user_, uint32 readIndex_) internal view returns (Position memory value) {
        bytes memory result = _staticRead(POSITION2_PRECOMPILE, abi.encode(user_, readIndex_));
        (value.szi, value.entryNtl, value.isolatedRawUsd, value.leverage, value.isIsolated) = abi.decode(
            result,
            (int64, uint64, int64, uint32, bool)
        );
    }

    /// @dev `asset_` is the read index (for native markets equal to the action asset); callers convert with `readIndexOf`.
    function oraclePx(uint32 asset_) internal view returns (uint64) {
        return abi.decode(_staticRead(ORACLE_PX_PRECOMPILE, abi.encode(asset_)), (uint64));
    }

    /// @dev `asset_` is the read index (for native markets equal to the action asset); callers convert with `readIndexOf`.
    function markPx(uint32 asset_) internal view returns (uint64) {
        return abi.decode(_staticRead(MARK_PX_PRECOMPILE, abi.encode(asset_)), (uint64));
    }

    /// @dev Converts a raw mark/oracle perp price into the 1e8 fixed-point scale of CoreWriter `limitPx`.
    ///      Returns uint256 on purpose: `type(uint64).max * 1e10` does not fit in uint64.
    function perpPxToPx1e8(uint64 rawPx_, uint8 szDecimals_) internal pure returns (uint256) {
        if (szDecimals_ > 8) revert HyperCoreAmountNotRepresentable();
        return uint256(rawPx_) * (uint256(10) ** (PERP_PX_RAW_TO_1E8_BASE_EXPONENT + szDecimals_));
    }

    /// @dev Mark price of `readIndex_` in the 1e8 `limitPx` scale; `readIndex_` is the read index
    ///      (callers convert with `readIndexOf`) and `szDecimals_` the market's `perpAssetInfo().szDecimals`.
    function markPx1e8(uint32 readIndex_, uint8 szDecimals_) internal view returns (uint256) {
        return perpPxToPx1e8(markPx(readIndex_), szDecimals_);
    }

    function l1BlockNumber() internal view returns (uint64) {
        return abi.decode(_staticRead(L1_BLOCK_NUMBER_PRECOMPILE, bytes("")), (uint64));
    }

    function systemAddress(uint64 token_) internal pure returns (address) {
        if (token_ > type(uint32).max) revert HyperCoreAmountNotRepresentable();
        return address(uint160(0x2000000000000000000000000000000000000000) + uint160(token_));
    }

    function evmToCoreWei(
        uint256 amountEvm_,
        int8 evmExtraWeiDecimals_
    ) internal pure returns (uint64 amountCore_, uint256 evmAmountRounded_) {
        evmAmountRounded_ = amountEvm_;
        uint256 coreAmount;
        if (evmExtraWeiDecimals_ == 0) coreAmount = amountEvm_;
        else {
            uint256 factor = _decimalFactor(evmExtraWeiDecimals_);
            if (evmExtraWeiDecimals_ > 0) {
                coreAmount = amountEvm_ / factor;
                evmAmountRounded_ = coreAmount * factor;
            } else {
                if (amountEvm_ > type(uint256).max / factor) revert HyperCoreDecimalConversionOverflow();
                coreAmount = amountEvm_ * factor;
            }
        }
        if (coreAmount > type(uint64).max) revert HyperCoreDecimalConversionOverflow();
        amountCore_ = uint64(coreAmount);
    }

    function coreWeiToEvm(uint64 amountCore_, int8 evmExtraWeiDecimals_) internal pure returns (uint256 amountEvm_) {
        if (evmExtraWeiDecimals_ == 0) return amountCore_;
        uint256 factor = _decimalFactor(evmExtraWeiDecimals_);
        if (evmExtraWeiDecimals_ > 0) {
            if (amountCore_ > type(uint256).max / factor) revert HyperCoreDecimalConversionOverflow();
            amountEvm_ = amountCore_ * factor;
        } else {
            amountEvm_ = amountCore_ / factor;
        }
    }

    function lotOf(uint8 szDecimals_) internal pure returns (uint64) {
        if (szDecimals_ > 8) revert HyperCoreAmountNotRepresentable();
        return uint64(uint256(10) ** (8 - szDecimals_));
    }

    function usd6ToWad(uint256 amountUsd6_) internal pure returns (uint256) {
        if (amountUsd6_ > type(uint256).max / USD6_TO_WAD) revert HyperCoreDecimalConversionOverflow();
        return amountUsd6_ * USD6_TO_WAD;
    }

    /// @dev `price1e8_` is uint256 so callers may pass a mark price converted by `perpPxToPx1e8`.
    function orderNotionalUsd6(uint64 size1e8_, uint256 price1e8_) internal pure returns (uint256) {
        return _ceilDiv(uint256(size1e8_) * price1e8_, 1e10);
    }

    function notionalUsd6(uint64 size1e8_, uint64 price1e8_) internal pure returns (uint256) {
        return orderNotionalUsd6(size1e8_, price1e8_);
    }

    function _encode(uint24 actionId_, bytes memory fields_) private pure returns (bytes memory) {
        return abi.encodePacked(bytes1(ACTION_VERSION), bytes3(actionId_), fields_);
    }

    function _staticRead(address precompile_, bytes memory input_) private view returns (bytes memory result) {
        bool success;
        (success, result) = precompile_.staticcall{gas: PRECOMPILE_GAS}(input_);
        if (!success || result.length == 0) revert HyperCorePrecompileFailed(precompile_);
    }

    function _decimalFactor(int8 decimals_) private pure returns (uint256) {
        int16 signedExponent = int16(decimals_);
        uint16 exponent = uint16(signedExponent < 0 ? -signedExponent : signedExponent);
        if (exponent > 77) revert HyperCoreDecimalConversionOverflow();
        return uint256(10) ** exponent;
    }

    function _ceilDiv(uint256 numerator_, uint256 denominator_) private pure returns (uint256) {
        return numerator_ == 0 ? 0 : (numerator_ - 1) / denominator_ + 1;
    }
}

interface ICoreWriter {
    function sendRawAction(bytes calldata data) external;
}
