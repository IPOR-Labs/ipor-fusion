// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IMidasDepositVault} from "./ext/IMidasDepositVault.sol";
import {IMidasRedemptionVault} from "./ext/IMidasRedemptionVault.sol";
import {MidasSubstrateLib} from "./lib/MidasSubstrateLib.sol";
import {MidasPendingRequestsStorageLib} from "./lib/MidasPendingRequestsStorageLib.sol";
import {Errors} from "../../libraries/errors/Errors.sol";

/// @notice Data structure for entering MidasRequestSupplyFuse (async deposit request)
struct MidasRequestSupplyFuseEnterData {
    /// @dev mToken to receive after admin approval (mTBILL or mBASIS)
    address mToken;
    /// @dev underlying token to deposit (e.g., USDC)
    address tokenIn;
    /// @dev amount of tokenIn to deposit (in tokenIn decimals)
    uint256 amount;
    /// @dev Midas Deposit Vault address
    address depositVault;
}

/// @notice Data structure for exiting MidasRequestSupplyFuse (async redemption request)
struct MidasRequestSupplyFuseExitData {
    /// @dev mToken to redeem
    address mToken;
    /// @dev amount of mTokens to redeem
    uint256 amount;
    /// @dev output token address (e.g., USDC)
    address tokenOut;
    /// @dev Midas Standard Redemption Vault address
    address standardRedemptionVault;
}

/// @dev Midas request status constants
uint8 constant MIDAS_REQUEST_STATUS_PENDING = 0;

/// @title MidasRequestSupplyFuse
/// @notice Fuse for submitting async deposit requests to Midas Deposit Vault
/// @dev Executes in PlasmaVault storage context via delegatecall. MUST NOT contain storage variables.
///      After calling depositRequest(), the USDC leaves the PlasmaVault. When the Midas admin
///      calls approveRequest(), mTokens are minted directly to the PlasmaVault (push-based model).
///      The pending request is tracked in MidasPendingRequestsStorageLib for NAV reporting.
contract MidasRequestSupplyFuse is IFuseCommon {
    using SafeERC20 for ERC20;

    event MidasRequestSupplyFuseEnter(
        address version, address mToken, uint256 amount, address tokenIn, uint256 requestId, address depositVault
    );

    event MidasRequestSupplyFuseExit(
        address version,
        address mToken,
        uint256 amount,
        address tokenOut,
        uint256 requestId,
        address standardRedemptionVault
    );

    event MidasRequestSupplyFuseCleanedDeposit(address depositVault, uint256 requestId);
    event MidasRequestSupplyFuseCleanedRedemption(address redemptionVault, uint256 requestId);

    error MidasRequestSupplyFuseInvalidRequestId();
    error MidasRequestSupplyFuseInvalidRedeemRequestId();

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        if (marketId_ == 0) revert Errors.WrongValue();
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Submit an async deposit request to Midas Deposit Vault
    /// @dev Also cleans up completed/canceled deposit requests for the same vault
    /// @param data_ The enter data containing mToken, tokenIn, amount, and depositVault
    function enter(MidasRequestSupplyFuseEnterData memory data_) external {
        _cleanUpPendingDeposits(data_.depositVault);

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

        uint256 requestId =
            IMidasDepositVault(data_.depositVault).depositRequest(data_.tokenIn, finalAmount, bytes32(0));

        if (requestId == 0) {
            revert MidasRequestSupplyFuseInvalidRequestId();
        }

        MidasPendingRequestsStorageLib.addPendingDeposit(data_.depositVault, requestId);

        ERC20(data_.tokenIn).forceApprove(data_.depositVault, 0);

        emit MidasRequestSupplyFuseEnter(
            VERSION, data_.mToken, finalAmount, data_.tokenIn, requestId, data_.depositVault
        );
    }

    /// @notice Submit an async redemption request to Midas Standard Redemption Vault
    /// @dev Also cleans up completed/canceled redemption requests for the same vault
    /// @param data_ The exit data containing mToken, amount, tokenOut, and standardRedemptionVault
    function exit(MidasRequestSupplyFuseExitData memory data_) external {
        _cleanUpPendingRedemptions(data_.standardRedemptionVault);

        if (data_.amount == 0) {
            return;
        }

        MidasSubstrateLib.validateMTokenGranted(MARKET_ID, data_.mToken);
        MidasSubstrateLib.validateRedemptionVaultGranted(MARKET_ID, data_.standardRedemptionVault);
        MidasSubstrateLib.validateAssetGranted(MARKET_ID, data_.tokenOut);

        uint256 finalAmount = IporMath.min(ERC20(data_.mToken).balanceOf(address(this)), data_.amount);

        if (finalAmount == 0) {
            return;
        }

        ERC20(data_.mToken).forceApprove(data_.standardRedemptionVault, finalAmount);

        uint256 requestId =
            IMidasRedemptionVault(data_.standardRedemptionVault).redeemRequest(data_.tokenOut, finalAmount);

        if (requestId == 0) {
            revert MidasRequestSupplyFuseInvalidRedeemRequestId();
        }

        MidasPendingRequestsStorageLib.addPendingRedemption(data_.standardRedemptionVault, requestId);

        ERC20(data_.mToken).forceApprove(data_.standardRedemptionVault, 0);

        emit MidasRequestSupplyFuseExit(
            VERSION, data_.mToken, finalAmount, data_.tokenOut, requestId, data_.standardRedemptionVault
        );
    }

    /// @notice Clean up completed/canceled deposit requests from pending storage
    /// @dev Can be called independently to clean up stale requests after long periods without supply fuse interaction
    /// @param depositVault_ The deposit vault to clean up
    /// @param maxIterations_ Maximum number of requests to process (0 = process all)
    function cleanupPendingDeposits(address depositVault_, uint256 maxIterations_) external {
        uint256[] memory requestIds = MidasPendingRequestsStorageLib.getPendingDepositsForVault(depositVault_);
        uint256 length = requestIds.length;
        uint256 iterations;
        IMidasDepositVault.Request memory req;
        for (uint256 i = length; i > 0; --i) {
            if (maxIterations_ > 0 && iterations >= maxIterations_) {
                break;
            }
            req = IMidasDepositVault(depositVault_).mintRequests(requestIds[i - 1]);
            if (req.status == MIDAS_REQUEST_STATUS_PENDING) {
                continue;
            }
            MidasPendingRequestsStorageLib.removePendingDeposit(depositVault_, requestIds[i - 1]);
            emit MidasRequestSupplyFuseCleanedDeposit(depositVault_, requestIds[i - 1]);
            ++iterations;
        }
    }

    /// @notice Clean up completed/canceled redemption requests from pending storage
    /// @dev Can be called independently to clean up stale requests after long periods without supply fuse interaction
    /// @param redemptionVault_ The redemption vault to clean up
    /// @param maxIterations_ Maximum number of requests to process (0 = process all)
    function cleanupPendingRedemptions(address redemptionVault_, uint256 maxIterations_) external {
        uint256[] memory requestIds = MidasPendingRequestsStorageLib.getPendingRedemptionsForVault(redemptionVault_);
        uint256 length = requestIds.length;
        uint256 iterations;
        IMidasRedemptionVault.Request memory req;
        for (uint256 i = length; i > 0; --i) {
            if (maxIterations_ > 0 && iterations >= maxIterations_) {
                break;
            }
            req = IMidasRedemptionVault(redemptionVault_).redeemRequests(requestIds[i - 1]);
            if (req.status == MIDAS_REQUEST_STATUS_PENDING) {
                continue;
            }
            MidasPendingRequestsStorageLib.removePendingRedemption(redemptionVault_, requestIds[i - 1]);
            emit MidasRequestSupplyFuseCleanedRedemption(redemptionVault_, requestIds[i - 1]);
            ++iterations;
        }
    }

    /// @notice Remove completed/canceled deposit requests from pending storage
    /// @param depositVault_ The deposit vault to clean up
    function _cleanUpPendingDeposits(address depositVault_) internal {
        uint256[] memory requestIds = MidasPendingRequestsStorageLib.getPendingDepositsForVault(depositVault_);
        uint256 length = requestIds.length;
        IMidasDepositVault.Request memory req;
        for (uint256 i = length; i > 0; --i) {
            req = IMidasDepositVault(depositVault_).mintRequests(requestIds[i - 1]);
            if (req.status == MIDAS_REQUEST_STATUS_PENDING) {
                continue;
            }
            MidasPendingRequestsStorageLib.removePendingDeposit(depositVault_, requestIds[i - 1]);
            emit MidasRequestSupplyFuseCleanedDeposit(depositVault_, requestIds[i - 1]);
        }
    }

    /// @notice Remove completed/canceled redemption requests from pending storage
    /// @param redemptionVault_ The redemption vault to clean up
    function _cleanUpPendingRedemptions(address redemptionVault_) internal {
        uint256[] memory requestIds = MidasPendingRequestsStorageLib.getPendingRedemptionsForVault(redemptionVault_);
        uint256 length = requestIds.length;
        IMidasRedemptionVault.Request memory req;
        for (uint256 i = length; i > 0; --i) {
            req = IMidasRedemptionVault(redemptionVault_).redeemRequests(requestIds[i - 1]);
            if (req.status == MIDAS_REQUEST_STATUS_PENDING) {
                continue;
            }
            MidasPendingRequestsStorageLib.removePendingRedemption(redemptionVault_, requestIds[i - 1]);
            emit MidasRequestSupplyFuseCleanedRedemption(redemptionVault_, requestIds[i - 1]);
        }
    }
}
