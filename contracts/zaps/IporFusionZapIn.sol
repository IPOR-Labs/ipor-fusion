// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ZapInAllowance} from "./ZapInAllowance.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Structure representing a single function call in the zap-in process
/// @dev Used to execute multiple operations in a single transaction
struct Call {
    /// @notice Target contract address to call
    address to;
    /// @notice Encoded function call data
    bytes data;
}

/// @notice Input data structure for the zapIn function
/// @dev Contains all necessary parameters for executing a zap-in operation
struct ZapInData {
    /// @notice Address of the target PlasmaVault to deposit into
    address plasmaVault;
    /// @notice Address that will receive the vault shares
    address receiver;
    /// @notice Minimum amount of tokens that must be deposited
    uint256 minAmountToDeposit;
    /// @notice List of token addresses that should be refunded to the sender if any remain after the operation
    address[] assetsToRefundToSender;
    /// @notice Array of calls to be executed as part of the zap-in process
    Call[] calls;
}

/// @title IporFusionZapIn
/// @notice Facilitates complex zap-in operations for PlasmaVault deposits
/// @dev Handles token approvals, multiple contract interactions, and deposits in a single transaction
contract IporFusionZapIn is ReentrancyGuard {
    using Address for address;
    using SafeERC20 for IERC20;

    /// @notice Thrown when minAmountToDeposit is zero
    error MinAmountToDepositIsZero();
    /// @notice Thrown when plasmaVault address is zero
    error PlasmaVaultIsZero();
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
        ZAP_IN_ALLOWANCE_CONTRACT = address(new ZapInAllowance(address(this)));
    }

    /// @notice Executes a complex zap-in operation with multiple steps
    /// @dev Performs a series of calls, then deposits resulting tokens into a PlasmaVault
    /// @param zapInData_ Struct containing all necessary parameters for the zap-in operation
    /// @return results Array of bytes containing the results of each call
    function zapIn(
        ZapInData calldata zapInData_
    ) external nonReentrant trackZapSender returns (bytes[] memory results) {
        if (zapInData_.minAmountToDeposit == 0) {
            revert MinAmountToDepositIsZero();
        }

        if (zapInData_.plasmaVault == address(0)) {
            revert PlasmaVaultIsZero();
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
            results[i] = zapInData_.calls[i].to.functionCall(zapInData_.calls[i].data);
        }

        ERC4626 plasmaVault = ERC4626(zapInData_.plasmaVault);
        uint256 depositAssetBalance = IERC20(plasmaVault.asset()).balanceOf(address(this));

        if (depositAssetBalance < zapInData_.minAmountToDeposit) {
            revert InsufficientDepositAssetBalance();
        }

        plasmaVault.deposit(depositAssetBalance, zapInData_.receiver);

        uint256 assetsToRefundToSenderLength = zapInData_.assetsToRefundToSender.length;
        address asset;
        uint256 balance;

        for (uint256 i; i < assetsToRefundToSenderLength; ++i) {
            asset = zapInData_.assetsToRefundToSender[i];
            balance = IERC20(asset).balanceOf(address(this));
            if (balance > 0) {
                IERC20(asset).safeTransfer(currentZapSender, balance);
            }
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
