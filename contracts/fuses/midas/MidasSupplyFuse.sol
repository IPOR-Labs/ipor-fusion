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
    /// @dev amount of mTokens to redeem
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

        IMidasDepositVault(data_.depositVault).depositInstant(
            data_.tokenIn, finalAmount, data_.minMTokenAmountOut, bytes32(0)
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
    /// @param params_ params[0] - amount of mTokens, params[1] - mToken address, params[2] - tokenOut address,
    ///                params[3] - instantRedemptionVault address, params[4] - minTokenOutAmount
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

    function _exit(MidasSupplyFuseExitData memory data_, bool catchExceptions_) internal {
        if (data_.amount == 0) {
            return;
        }

        MidasSubstrateLib.validateMTokenGranted(MARKET_ID, data_.mToken);
        MidasSubstrateLib.validateInstantRedemptionVaultGranted(MARKET_ID, data_.instantRedemptionVault);
        MidasSubstrateLib.validateAssetGranted(MARKET_ID, data_.tokenOut);

        uint256 finalAmount = IporMath.min(ERC20(data_.mToken).balanceOf(address(this)), data_.amount);

        if (finalAmount == 0) {
            return;
        }

        uint256 tokenOutBefore = ERC20(data_.tokenOut).balanceOf(address(this));

        ERC20(data_.mToken).forceApprove(data_.instantRedemptionVault, finalAmount);

        if (catchExceptions_) {
            try IMidasRedemptionVault(data_.instantRedemptionVault).redeemInstant(
                data_.tokenOut, finalAmount, data_.minTokenOutAmount
            ) {
                uint256 tokenOutReceived = ERC20(data_.tokenOut).balanceOf(address(this)) - tokenOutBefore;

                if (tokenOutReceived < data_.minTokenOutAmount) {
                    revert MidasSupplyFuseInsufficientTokenOutReceived(data_.minTokenOutAmount, tokenOutReceived);
                }

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
