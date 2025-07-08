// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ERC4626ZapInAllowance} from "./ERC4626ZapInAllowance.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Structure representing a single function call in the zap-in process
/// @dev Used to execute multiple operations in a single transaction
struct Call {
    /// @notice Target contract address to call
    address target;
    /// @notice Encoded function call data
    bytes data;
    uint256 nativeTokenAmount;
}

/// @notice Input data structure for the zapIn function
/// @dev Contains all necessary parameters for executing a zap-in operation
struct ZapInData {
    /// @notice Address of the target ERC4626 vault to deposit into
    address vault;
    /// @notice Address that will receive the vault shares
    address receiver;
    /// @notice Minimum amount of tokens that must be deposited
    uint256 minAmountToDeposit;
    /// @notice List of token addresses that should be refunded to the sender if any remain after the operation
    address[] assetsToRefundToSender;
    /// @notice Array of calls to be executed as part of the zap-in process
    Call[] calls;
}

/// @title ERC4626ZapInWithNativeToken
/// @notice Facilitates complex zap-in operations for ERC4626 vault deposits
/// @dev Handles token approvals, multiple contract interactions, and deposits in a single transaction
contract ERC4626ZapInWithNativeToken is ReentrancyGuard {
    using Address for address;
    using SafeERC20 for IERC4626;

    /// @notice Thrown when minAmountToDeposit is zero
    error MinAmountToDepositIsZero();
    /// @notice Thrown when ERC4626 address is zero
    error ERC4626VaultIsZero();
    /// @notice Thrown when no calls are provided in the zap-in data
    error NoCalls();
    /// @notice Thrown when the resulting deposit asset balance is less than minAmountToDeposit
    error InsufficientDepositAssetBalance();
    /// @notice Thrown when receiver address is zero
    error ReceiverIsZero();

    /// @notice Address of the ZapInAllowance contract that handles token transfers
    /// @dev Immutable contract address created in constructor
    address public immutable ZAP_IN_ALLOWANCE_CONTRACT;

    /// @notice Address of the current user performing a zap-in operation
    /// @dev This is set during the zapIn function execution and cleared afterwards
    address public currentZapSender;

    constructor() {
        ZAP_IN_ALLOWANCE_CONTRACT = address(new ERC4626ZapInAllowance(address(this)));
    }

    /// @notice Executes a complex zap-in operation with multiple steps
    /// @dev Performs a series of calls, then deposits resulting tokens into a ERC4626
    /// @param zapInData_ Struct containing all necessary parameters for the zap-in operation
    /// @return results Array of bytes containing the results of each call
    function zapIn(
        ZapInData calldata zapInData_
    ) external payable nonReentrant trackZapSender returns (bytes[] memory results) {
        if (zapInData_.minAmountToDeposit == 0) {
            revert MinAmountToDepositIsZero();
        }

        if (zapInData_.vault == address(0)) {
            revert ERC4626VaultIsZero();
        }

        uint256 callsLength = zapInData_.calls.length;

        if (callsLength == 0) {
            revert NoCalls();
        }

        if (zapInData_.receiver == address(0)) {
            revert ReceiverIsZero();
        }

        results = new bytes[](callsLength);
        for (uint256 i; i < callsLength; i++) {
            if (zapInData_.calls[i].nativeTokenAmount > 0) {
                results[i] = zapInData_.calls[i].target.functionCallWithValue(
                    zapInData_.calls[i].data,
                    zapInData_.calls[i].nativeTokenAmount
                );
            } else {
                results[i] = zapInData_.calls[i].target.functionCall(zapInData_.calls[i].data);
            }
        }

        IERC4626 vault = IERC4626(zapInData_.vault);
        uint256 depositAssetBalance = IERC4626(vault.asset()).balanceOf(address(this));

        if (depositAssetBalance < zapInData_.minAmountToDeposit) {
            revert InsufficientDepositAssetBalance();
        }

        vault.deposit(depositAssetBalance, zapInData_.receiver);

        uint256 assetsToRefundToSenderLength = zapInData_.assetsToRefundToSender.length;
        address asset;
        uint256 balance;

        for (uint256 i; i < assetsToRefundToSenderLength; ++i) {
            asset = zapInData_.assetsToRefundToSender[i];
            balance = IERC4626(asset).balanceOf(address(this));
            if (balance > 0) {
                IERC4626(asset).safeTransfer(currentZapSender, balance);
            }
        }

        uint256 nativeTokenBalance = address(this).balance;

        if (nativeTokenBalance > 0) {
            Address.sendValue(payable(currentZapSender), nativeTokenBalance);
        }

        return results;
    }

    /// @notice Tracks the sender of the current zap-in operation
    /// @dev Sets currentZapSender at the start of operation and clears it afterwards
    /// @custom:security This modifier ensures proper tracking of the operation initiator
    modifier trackZapSender() {
        currentZapSender = msg.sender;
        _;
        currentZapSender = address(0);
    }
}
