// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IWETH9} from "../../interfaces/ext/IWETH9.sol";

/// @title EnsoExecutorData
/// @notice Data structure containing all necessary information for executing an Enso shortcut
/// @param accountId The bytes32 value representing an API user
/// @param requestId The bytes32 value representing an API request
/// @param commands An array of bytes32 values that encode calls
/// @param state An array of bytes that are used to generate call data for each command
/// @param tokensToReturn Array of token addresses to return to sender after execution. A
///        non-empty array declares that the route's outputs are delivered to PLASMA_VAULT in
///        this transaction: every listed token's full executor balance is swept and no pending
///        balance is recorded (`_balance.assetBalance = 0`). Leave empty for cross-chain or
///        delayed legs, where the pending-balance placeholder must be kept.
/// @param wEthAmount Amount of WETH to handle
/// @param tokenOut Token address to transfer out
/// @param amountOut Amount to transfer out
/// @param tokensToRevoke Array of token addresses whose allowance to the paired spender in
///        `spendersToRevoke` must be revoked (set to 0) after the shortcut executes. Pair i is
///        (tokensToRevoke[i], spendersToRevoke[i]). Declared by the caller (the alpha), who
///        builds the shortcut and therefore knows every approval it makes; revocation is
///        unconditional and not substrate-validated, since revoking to zero is strictly
///        risk-reducing. Any approval whose (token, spender) pair is not declared here persists
///        on the executor indefinitely - see contracts/fuses/enso/README.md.
/// @param spendersToRevoke Array of spender addresses paired with `tokensToRevoke` (see above)
struct EnsoExecutorData {
    bytes32 accountId;
    bytes32 requestId;
    bytes32[] commands;
    bytes[] state;
    address[] tokensToReturn;
    uint256 wEthAmount;
    address tokenOut;
    uint256 amountOut;
    address[] tokensToRevoke;
    address[] spendersToRevoke;
}

/// @title EnsoExecutorBalance
/// @notice Optimized balance structure that fits in a single storage slot (32 bytes)
/// @param assetAddress Token address (20 bytes)
/// @param assetBalance Token balance (12 bytes, max ~79 billion tokens with 18 decimals)
/// @dev Total size: 32 bytes (256 bits) - fits in 1 storage slot
struct EnsoExecutorBalance {
    address assetAddress; // 20 bytes (160 bits)
    uint96 assetBalance; // 12 bytes (96 bits) - max value: 79,228,162,514 * 10^18
}

/// @title EnsoExecutor
/// @notice Contract responsible for executing Enso shortcuts via delegatecall
/// @dev This contract manages the execution of Enso operations using delegatecall pattern
contract EnsoExecutor {
    using Address for address;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @notice Error thrown when an invalid DelegateEnsoShortcuts address is provided
    error EnsoExecutorInvalidDelegateAddress();

    /// @notice Error thrown when delegatecall fails
    error EnsoExecutorInvalidWethAddress();
    error EnsoExecutorInvalidPlasmaVaultAddress();
    error EnsoExecutorUnauthorizedCaller();
    error EnsoExecutorBalanceAlreadySet();
    error EnsoExecutorBalanceNotEmpty();
    error EnsoExecutorInvalidTargetAddress();
    error EnsoExecutorInvalidData();

    /// @notice Error thrown when tokensToRevoke and spendersToRevoke arrays have different lengths
    error EnsoExecutorRevokeArrayLengthMismatch();

    /// @notice Event emitted when an Enso shortcut execution is completed
    /// @param sender Address that initiated the execution
    /// @param accountId The bytes32 value representing an API user
    /// @param requestId The bytes32 value representing an API request
    event EnsoExecutorExecuted(address indexed sender, bytes32 accountId, bytes32 requestId);

    /// @notice Event emitted when tokens are withdrawn to PlasmaVault
    /// @param tokens Array of token addresses that were withdrawn
    /// @param amounts Array of amounts that were withdrawn for each token
    event EnsoExecutorTokensWithdrawn(address[] tokens, uint256[] amounts);

    /// @notice Event emitted when recovery function is called
    /// @param target The target address for the delegatecall
    /// @param data The calldata used
    event EnsoExecutorRecovery(address indexed target, bytes data);

    /// @notice Address of the DelegateEnsoShortcuts contract
    address public immutable DELEGATE_ENSO_SHORTCUTS;
    address public immutable WETH_ADDRESS;
    address public immutable PLASMA_VAULT;

    EnsoExecutorBalance private _balance;

    /// @notice Constructs the EnsoExecutor contract
    /// @param delegateEnsoShortcuts_ Address of the DelegateEnsoShortcuts contract
    /// @param wethAddress_ Address of the WETH token
    /// @param plasmaVault_ Address of the PlasmaVault contract
    /// @dev Reverts if any address parameter is the zero address
    constructor(address delegateEnsoShortcuts_, address wethAddress_, address plasmaVault_) {
        if (wethAddress_ == address(0)) {
            revert EnsoExecutorInvalidWethAddress();
        }
        if (delegateEnsoShortcuts_ == address(0)) {
            revert EnsoExecutorInvalidDelegateAddress();
        }
        if (plasmaVault_ == address(0)) {
            revert EnsoExecutorInvalidPlasmaVaultAddress();
        }
        DELEGATE_ENSO_SHORTCUTS = delegateEnsoShortcuts_;
        WETH_ADDRESS = wethAddress_;
        PLASMA_VAULT = plasmaVault_;
    }

    /// @notice Modifier to restrict function access to only the PlasmaVault
    /// @dev Reverts if msg.sender is not the PlasmaVault address
    modifier onlyPlasmaVault() {
        if (msg.sender != PLASMA_VAULT) {
            revert EnsoExecutorUnauthorizedCaller();
        }
        _;
    }

    /// @notice Executes an Enso shortcut via delegatecall
    /// @param data_ EnsoExecutorData containing all necessary information for the shortcut execution
    /// @dev This function:
    ///      - Delegatecalls into DelegateEnsoShortcuts.executeShortcut()
    ///      - Transfers all specified tokens back to the sender, in order: re-wrapped ETH,
    ///        the residual `tokenOut`, then every entry of `tokensToReturn`
    ///      - If `tokensToReturn` is non-empty, records no pending balance
    ///        (`_balance.assetBalance = 0`) - the caller declared the outputs are delivered in
    ///        this transaction. If `tokensToReturn` is empty, the residual `tokenOut` pending
    ///        balance is tracked as before, for cross-chain / delayed legs.
    /// @dev Only callable by the PlasmaVault contract
    function execute(EnsoExecutorData memory data_) external payable onlyPlasmaVault {
        if (_balance.assetAddress != address(0)) {
            revert EnsoExecutorBalanceAlreadySet();
        }

        if (data_.tokensToRevoke.length != data_.spendersToRevoke.length) {
            revert EnsoExecutorRevokeArrayLengthMismatch();
        }

        // Delegatecall to DelegateEnsoShortcuts.executeShortcut
        bytes memory delegateCallData = abi.encodeWithSignature(
            "executeShortcut(bytes32,bytes32,bytes32[],bytes[])",
            data_.accountId,
            data_.requestId,
            data_.commands,
            data_.state
        );

        if (data_.wEthAmount > 0) {
            IWETH9(WETH_ADDRESS).withdraw(data_.wEthAmount);
        }

        Address.functionDelegateCall(DELEGATE_ENSO_SHORTCUTS, delegateCallData);

        // @dev Revoke every caller-declared (token, spender) allowance pair created by the
        // shortcut. The alpha builds the shortcut and knows every approval it contains; this is
        // an unconditional, best-effort cleanup and is not substrate-validated because revoking
        // to zero is strictly risk-reducing. Undeclared pairs are not detected and persist - see
        // contracts/fuses/enso/README.md.
        uint256 revokeLength = data_.tokensToRevoke.length;
        for (uint256 i; i < revokeLength; ++i) {
            IERC20(data_.tokensToRevoke[i]).forceApprove(data_.spendersToRevoke[i], 0);
        }

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            IWETH9(WETH_ADDRESS).deposit{value: ethBalance}();
            IERC20(WETH_ADDRESS).safeTransfer(PLASMA_VAULT, ethBalance);
        }

        uint256 tokenOutBalance = IERC20(data_.tokenOut).balanceOf(address(this));
        _balance.assetAddress = data_.tokenOut;

        if (tokenOutBalance > 0) {
            IERC20(data_.tokenOut).safeTransfer(PLASMA_VAULT, tokenOutBalance);
        }

        // @dev Sweep every declared route output back to PLASMA_VAULT. Zero balances (already
        // swept as tokenOut/WETH above, duplicates, or tokens the route did not produce) are
        // skipped - harmless, no dedup needed.
        uint256 tokensToReturnLength = data_.tokensToReturn.length;
        address tokenToReturn;
        uint256 tokenToReturnBalance;
        for (uint256 i; i < tokensToReturnLength; ++i) {
            tokenToReturn = data_.tokensToReturn[i];
            tokenToReturnBalance = IERC20(tokenToReturn).balanceOf(address(this));
            if (tokenToReturnBalance > 0) {
                IERC20(tokenToReturn).safeTransfer(PLASMA_VAULT, tokenToReturnBalance);
            }
        }

        if (tokensToReturnLength > 0) {
            // @dev The caller declared that the route's outputs are delivered to PLASMA_VAULT in
            // this transaction (swept above); nothing is pending.
            _balance.assetBalance = 0;
        } else if (tokenOutBalance > 0) {
            if (data_.amountOut > tokenOutBalance) {
                // @dev In cross-chain or other scenarios, the executor might not have all tokens yet,
                // @devbut we still track the remaining expected balance for future reconciliation
                _balance.assetBalance = (data_.amountOut - tokenOutBalance).toUint96();
            } else {
                _balance.assetBalance = 0;
            }
        } else {
            // @dev In cross-chain or other scenarios, the executor might not have the tokens yet,
            // @dev but we still track the expected balance for future reconciliation
            _balance.assetBalance = data_.amountOut.toUint96();
        }

        emit EnsoExecutorExecuted(PLASMA_VAULT, data_.accountId, data_.requestId);
    }

    /// @notice Get balance from EnsoExecutorBalance structure with uint256 conversion
    /// @return assetAddress The address of the asset
    /// @return assetBalance The balance amount converted to uint256
    function getBalance() external view returns (address assetAddress, uint256 assetBalance) {
        assetAddress = _balance.assetAddress;
        assetBalance = uint256(_balance.assetBalance);
    }

    /// @notice Withdraw specified tokens from executor to PlasmaVault
    /// @param tokens_ Array of token addresses to withdraw
    /// @dev Only callable by the PlasmaVault contract
    /// @dev Transfers the full balance of each token to PlasmaVault (msg.sender)
    function withdrawAll(address[] calldata tokens_) external onlyPlasmaVault {
        uint256 tokensLength = tokens_.length;
        if (tokensLength == 0) {
            return;
        }

        uint256[] memory amounts = new uint256[](tokensLength);
        uint256 balance;

        for (uint256 i; i < tokensLength; ++i) {
            balance = IERC20(tokens_[i]).balanceOf(address(this));
            if (balance > 0) {
                IERC20(tokens_[i]).safeTransfer(PLASMA_VAULT, balance);
                amounts[i] = balance;
            }
        }

        _balance.assetAddress = address(0);
        _balance.assetBalance = 0;

        emit EnsoExecutorTokensWithdrawn(tokens_, amounts);
    }

    function recovery(address target_, bytes calldata data_) external onlyPlasmaVault {
        if (_balance.assetAddress != address(0)) {
            revert EnsoExecutorBalanceNotEmpty();
        }

        if (target_ == address(0)) {
            revert EnsoExecutorInvalidTargetAddress();
        }
        if (data_.length == 0) {
            revert EnsoExecutorInvalidData();
        }

        Address.functionDelegateCall(target_, data_);

        emit EnsoExecutorRecovery(target_, data_);
    }

    /// @dev Allows the contract to receive ETH
    receive() external payable {}
}
