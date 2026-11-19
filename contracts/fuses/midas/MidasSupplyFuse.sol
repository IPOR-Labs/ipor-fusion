// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IFuseInstantWithdraw} from "../IFuseInstantWithdraw.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IMidasDepositVault} from "./ext/IMidasDepositVault.sol";
import {IMidasRedemptionVault} from "./ext/IMidasRedemptionVault.sol";
import {IMidasRedemptionVaultLimits} from "./ext/IMidasRedemptionVaultLimits.sol";
import {IMidasDataFeed} from "./ext/IMidasDataFeed.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MidasSubstrateLib} from "./lib/MidasSubstrateLib.sol";
import {Errors} from "../../libraries/errors/Errors.sol";

/// @notice Data structure for entering MidasSupplyFuse (instant mToken minting)
struct MidasSupplyFuseEnterData {
    /// @dev mToken to receive (mTBILL or mBASIS)
    address mToken;
    /// @dev underlying token to deposit (e.g., USDC)
    address tokenIn;
    /// @dev amount of tokenIn to deposit (in tokenIn decimals)
    uint256 amount;
    /// @dev minimum mTokens to receive (slippage protection)
    uint256 minMTokenAmountOut;
    /// @dev Midas Deposit Vault address
    address depositVault;
}

/// @notice Data structure for exiting MidasSupplyFuse (instant mToken redemption)
struct MidasSupplyFuseExitData {
    /// @dev mToken to redeem
    address mToken;
    /// @dev amount of mTokens to redeem; on the instant withdraw path the missing amount of tokenOut (tokenOut
    ///      decimals), converted to mTokens by the fuse
    uint256 amount;
    /// @dev minimum output tokens (slippage protection)
    uint256 minTokenOutAmount;
    /// @dev output token address (e.g., USDC)
    address tokenOut;
    /// @dev Midas Instant Redemption Vault address
    address instantRedemptionVault;
}

/// @title MidasSupplyFuse
/// @notice Fuse for instant mToken minting via Midas Deposit Vault
/// @dev Executes in PlasmaVault storage context via delegatecall. MUST NOT contain storage variables.
contract MidasSupplyFuse is IFuseCommon, IFuseInstantWithdraw {
    using SafeERC20 for ERC20;

    event MidasSupplyFuseEnter(address version, address mToken, uint256 amount, address depositVault);

    event MidasSupplyFuseExit(
        address version, address mToken, uint256 amount, address tokenOut, address instantRedemptionVault
    );

    event MidasSupplyFuseExitFailed(
        address version, address mToken, uint256 amount, address tokenOut, address instantRedemptionVault
    );

    error MidasSupplyFuseInsufficientMTokenReceived(uint256 expected, uint256 received);
    error MidasSupplyFuseInsufficientTokenOutReceived(uint256 expected, uint256 received);

    /// @dev Midas fee base (100 %) and the rate of a stable payment token
    uint256 private constant MIDAS_ONE_HUNDRED_PERCENT = 100_00;
    uint256 private constant MIDAS_STABLECOIN_RATE = 1e18;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        if (marketId_ == 0) revert Errors.WrongValue();
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Instant deposit into Midas Deposit Vault, minting mTokens
    /// @param data_ The enter data containing mToken, tokenIn, amount, minMTokenAmountOut, and depositVault
    function enter(MidasSupplyFuseEnterData memory data_) external {
        if (data_.amount == 0) {
            return;
        }

        MidasSubstrateLib.validateMTokenGranted(MARKET_ID, data_.mToken);
        MidasSubstrateLib.validateDepositVaultGranted(MARKET_ID, data_.depositVault);
        MidasSubstrateLib.validateAssetGranted(MARKET_ID, data_.tokenIn);

        uint256 finalAmount = IporMath.min(ERC20(data_.tokenIn).balanceOf(address(this)), data_.amount);

        if (finalAmount == 0) {
            return;
        }

        ERC20(data_.tokenIn).forceApprove(data_.depositVault, finalAmount);

        uint256 mTokenBefore = ERC20(data_.mToken).balanceOf(address(this));

        uint256 amountInWad = IporMath.convertToWad(finalAmount, ERC20(data_.tokenIn).decimals());

        IMidasDepositVault(data_.depositVault).depositInstant(
            data_.tokenIn, amountInWad, data_.minMTokenAmountOut, bytes32(0)
        );

        uint256 mTokenReceived = ERC20(data_.mToken).balanceOf(address(this)) - mTokenBefore;

        if (mTokenReceived < data_.minMTokenAmountOut) {
            revert MidasSupplyFuseInsufficientMTokenReceived(data_.minMTokenAmountOut, mTokenReceived);
        }

        ERC20(data_.tokenIn).forceApprove(data_.depositVault, 0);

        emit MidasSupplyFuseEnter(VERSION, data_.mToken, finalAmount, data_.depositVault);
    }

    /// @notice Instant redeem mTokens for output token via Midas Instant Redemption Vault
    /// @param data_ The exit data containing mToken, amount, minTokenOutAmount, tokenOut, and instantRedemptionVault
    function exit(MidasSupplyFuseExitData memory data_) external {
        _exit(data_, false);
    }

    /// @notice Instant withdraw assets from the external market
    /// @dev params[0] is the amount of tokenOut the vault is missing (written by the withdraw router in the vault's
    ///      underlying), not an mToken amount: it is converted to mTokens with Midas' rates and fees and capped at the
    ///      instant redemption limits (IL-9617). An entry below Midas' minimum is skipped, a failed redemption is
    ///      caught; with no mToken balance it returns silently, every other skip (Midas read failed, limit used up,
    ///      rate 0, fee of 100 % or more, below the minimum) and a failed redemption emit MidasSupplyFuseExitFailed.
    /// @param params_ params[0] - missing amount of tokenOut (tokenOut decimals), params[1] - mToken address,
    ///                params[2] - tokenOut address, params[3] - instantRedemptionVault address,
    ///                params[4] - minTokenOutAmount (passed to Midas as minReceiveAmount)
    function instantWithdraw(bytes32[] calldata params_) external override {
        uint256 amount = uint256(params_[0]);
        address mToken = PlasmaVaultConfigLib.bytes32ToAddress(params_[1]);
        address tokenOut = PlasmaVaultConfigLib.bytes32ToAddress(params_[2]);
        address instantRedemptionVault = PlasmaVaultConfigLib.bytes32ToAddress(params_[3]);
        uint256 minTokenOutAmount = uint256(params_[4]);

        _exit(
            MidasSupplyFuseExitData(mToken, amount, minTokenOutAmount, tokenOut, instantRedemptionVault),
            true
        );
    }

    /// @notice mTokens to redeem on the instant withdraw path for `data_.amount` of tokenOut
    /// @dev Midas pays `amountMTokenIn × (1 − fee) × mTokenRate / tokenOutRate` of tokenOut (rates from its data
    ///      feeds; a stable payment token at 1e18), so the mToken amount for the missing tokenOut is grossed up by the
    ///      instant and token fees and rounded up; the router keeps any extra in the vault. The result is capped at the
    ///      remaining instant daily limit and the token allowance. Every Midas read is a guarded staticcall (target
    ///      with code, success, full return data), so a missing view or a reverting feed cannot end the user's
    ///      withdraw. Returns 0 when a read fails, a limit is used up, a rate is 0, the fee is 100 % or more, or a
    ///      non-stable tokenOut has no data feed.
    function _instantRedeemMTokenAmount(MidasSupplyFuseExitData memory data_) internal view returns (uint256) {
        (bool ok, uint256 tokenFee, uint256 allowance, uint256 tokenOutRate) = _readTokenOutConfig(data_);
        if (!ok) return 0;

        (uint256 instantFee, uint256 mTokenRate, bool ok2) = _readInstantFeeAndMTokenRate(data_.instantRedemptionVault);
        uint256 feeBps = instantFee + tokenFee;
        if (!ok2 || mTokenRate == 0 || tokenOutRate == 0 || feeBps >= MIDAS_ONE_HUNDRED_PERCENT) {
            return 0;
        }

        uint256 mTokenAmount = Math.mulDiv(
            IporMath.convertToWad(data_.amount, ERC20(data_.tokenOut).decimals()),
            tokenOutRate * MIDAS_ONE_HUNDRED_PERCENT,
            mTokenRate * (MIDAS_ONE_HUNDRED_PERCENT - feeBps),
            Math.Rounding.Ceil
        );

        if (allowance != type(uint256).max) {
            uint256 mTokenByAllowance = Math.mulDiv(allowance, tokenOutRate, mTokenRate);
            if (mTokenByAllowance < mTokenAmount) {
                mTokenAmount = mTokenByAllowance;
            }
        }

        (bool ok3, uint256 remaining) = _readRemainingDailyLimit(data_.instantRedemptionVault);
        if (!ok3) return 0;
        return mTokenAmount < remaining ? mTokenAmount : remaining;
    }

    /// @dev tokensConfig of tokenOut and its rate (1e18 for a stable token, else its data feed); `ok` is false when a
    ///      read fails or a non-stable tokenOut has no data feed
    function _readTokenOutConfig(
        MidasSupplyFuseExitData memory data_
    ) private view returns (bool ok, uint256 tokenFee, uint256 allowance, uint256 tokenOutRate) {
        bytes memory ret;
        (ok, ret) = _staticRead(
            data_.instantRedemptionVault,
            abi.encodeCall(IMidasRedemptionVaultLimits.tokensConfig, (data_.tokenOut)),
            128
        );
        if (!ok) return (false, 0, 0, 0);

        uint256 dataFeed;
        uint256 stableWord;
        (dataFeed, tokenFee, allowance, stableWord) = abi.decode(ret, (uint256, uint256, uint256, uint256));
        if (dataFeed > type(uint160).max || stableWord > 1) return (false, 0, 0, 0);

        if (stableWord == 1) {
            return (true, tokenFee, allowance, MIDAS_STABLECOIN_RATE);
        }

        /// @dev A non-stable tokenOut that Midas does not list has no feed (address(0)): nothing to price it with
        if (dataFeed == 0) return (false, 0, 0, 0);

        (ok, tokenOutRate) = _staticReadWord(
            address(uint160(dataFeed)),
            abi.encodeCall(IMidasDataFeed.getDataInBase18, ())
        );
        if (!ok) return (false, 0, 0, 0);
        return (true, tokenFee, allowance, tokenOutRate);
    }

    function _readInstantFeeAndMTokenRate(address vault_) private view returns (uint256 fee, uint256 rate, bool ok) {
        (ok, fee) = _staticReadWord(vault_, abi.encodeCall(IMidasRedemptionVaultLimits.instantFee, ()));
        if (!ok) return (0, 0, false);

        uint256 feed;
        (ok, feed) = _staticReadWord(vault_, abi.encodeCall(IMidasRedemptionVaultLimits.mTokenDataFeed, ()));
        if (!ok || feed > type(uint160).max) return (0, 0, false);

        (ok, rate) = _staticReadWord(address(uint160(feed)), abi.encodeCall(IMidasDataFeed.getDataInBase18, ()));
    }

    function _readRemainingDailyLimit(address vault_) private view returns (bool ok, uint256 remaining) {
        uint256 limit;
        (ok, limit) = _staticReadWord(vault_, abi.encodeCall(IMidasRedemptionVaultLimits.instantDailyLimit, ()));
        if (!ok) return (false, 0);

        uint256 used;
        (ok, used) = _staticReadWord(
            vault_,
            abi.encodeCall(IMidasRedemptionVaultLimits.dailyLimits, (block.timestamp / 1 days))
        );
        if (!ok) return (false, 0);
        remaining = limit > used ? limit - used : 0;
    }

    /// @dev Staticcall that never reverts: `ok` only when `target` has code, the call succeeds and returns at least
    ///      `minReturnLength_` bytes
    function _staticRead(
        address target_,
        bytes memory callData_,
        uint256 minReturnLength_
    ) private view returns (bool ok, bytes memory ret) {
        if (target_.code.length == 0) return (false, ret);
        (ok, ret) = target_.staticcall(callData_);
        if (!ok || ret.length < minReturnLength_) return (false, ret);
    }

    /// @dev `_staticRead` for a view that returns one 32-byte word
    function _staticReadWord(address target_, bytes memory callData_) private view returns (bool ok, uint256 value) {
        bytes memory ret;
        (ok, ret) = _staticRead(target_, callData_, 32);
        if (ok) value = abi.decode(ret, (uint256));
    }

    function _exit(MidasSupplyFuseExitData memory data_, bool catchExceptions_) internal {
        if (data_.amount == 0) {
            return;
        }

        MidasSubstrateLib.validateMTokenGranted(MARKET_ID, data_.mToken);
        MidasSubstrateLib.validateInstantRedemptionVaultGranted(MARKET_ID, data_.instantRedemptionVault);
        MidasSubstrateLib.validateAssetGranted(MARKET_ID, data_.tokenOut);

        uint256 mTokenBalance = ERC20(data_.mToken).balanceOf(address(this));

        if (mTokenBalance == 0) {
            return;
        }

        /// @dev Instant withdraw path: word 0 is the missing amount of tokenOut (the vault's underlying), not of
        ///      mTokens, so convert it and cap it at what the vault can redeem today. 0 = nothing to redeem (a Midas
        ///      read failed, a limit is used up, a rate is 0, the fee is 100 % or more): skip and report
        uint256 mTokenAmount = data_.amount;
        if (catchExceptions_) {
            mTokenAmount = _instantRedeemMTokenAmount(data_);
            if (mTokenAmount == 0) {
                emit MidasSupplyFuseExitFailed(
                    VERSION,
                    data_.mToken,
                    data_.amount,
                    data_.tokenOut,
                    data_.instantRedemptionVault
                );
                return;
            }
        }

        uint256 finalAmount = IporMath.min(mTokenBalance, mTokenAmount);

        /// @dev Instant withdraw path: below the vault's minimum the redemption reverts; skip the entry instead. A
        ///      failing `minAmount` view is a skip as well
        if (catchExceptions_) {
            (bool ok, uint256 minAmount) = _staticReadWord(
                data_.instantRedemptionVault,
                abi.encodeCall(IMidasRedemptionVaultLimits.minAmount, ())
            );
            if (!ok || finalAmount < minAmount) {
                emit MidasSupplyFuseExitFailed(
                    VERSION,
                    data_.mToken,
                    finalAmount,
                    data_.tokenOut,
                    data_.instantRedemptionVault
                );
                return;
            }
        }

        uint256 tokenOutBefore = ERC20(data_.tokenOut).balanceOf(address(this));

        ERC20(data_.mToken).forceApprove(data_.instantRedemptionVault, finalAmount);

        if (catchExceptions_) {
            try IMidasRedemptionVault(data_.instantRedemptionVault).redeemInstant(
                data_.tokenOut, finalAmount, data_.minTokenOutAmount
            ) {
                /// @dev No re-check of word 4 here: a revert in this branch is not caught and would end the user's
                ///      exit (PlasmaVault versions before IL-9659 bubble every revert, later ones skip only reverts
                ///      that carry data); `redeemInstant` already enforces `minReceiveAmount` inside the try
                ERC20(data_.mToken).forceApprove(data_.instantRedemptionVault, 0);

                emit MidasSupplyFuseExit(
                    VERSION, data_.mToken, finalAmount, data_.tokenOut, data_.instantRedemptionVault
                );
            } catch {
                ERC20(data_.mToken).forceApprove(data_.instantRedemptionVault, 0);
                emit MidasSupplyFuseExitFailed(
                    VERSION, data_.mToken, finalAmount, data_.tokenOut, data_.instantRedemptionVault
                );
            }
        } else {
            IMidasRedemptionVault(data_.instantRedemptionVault).redeemInstant(
                data_.tokenOut, finalAmount, data_.minTokenOutAmount
            );

            uint256 tokenOutReceived = ERC20(data_.tokenOut).balanceOf(address(this)) - tokenOutBefore;

            if (tokenOutReceived < data_.minTokenOutAmount) {
                revert MidasSupplyFuseInsufficientTokenOutReceived(data_.minTokenOutAmount, tokenOutReceived);
            }

            ERC20(data_.mToken).forceApprove(data_.instantRedemptionVault, 0);

            emit MidasSupplyFuseExit(
                VERSION, data_.mToken, finalAmount, data_.tokenOut, data_.instantRedemptionVault
            );
        }
    }
}
