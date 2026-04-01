// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IMidasDepositVault} from "./ext/IMidasDepositVault.sol";
import {IMidasRedemptionVault} from "./ext/IMidasRedemptionVault.sol";

/// @title MidasExecutor
/// @notice Stateful executor contract that holds assets during async Midas deposit and redemption operations.
/// @dev This contract is NOT a fuse — it is called directly (not via delegatecall).
///      Only the authorized PlasmaVault can call its methods.
/// @author IPOR Labs
contract MidasExecutor {
    using SafeERC20 for ERC20;
    using SafeERC20 for IERC20;

    /// @notice Authorized PlasmaVault that can call this executor
    address public immutable PLASMA_VAULT;

    /// @notice Thrown when caller is not the authorized PlasmaVault
    error MidasExecutorUnauthorizedCaller();

    /// @notice Thrown when the provided PlasmaVault address is zero
    error MidasExecutorInvalidPlasmaVaultAddress();

    /// @notice Thrown when a zero address is passed as a parameter
    error MidasExecutorZeroAddress();

    /// @notice Restricts function access to the authorized PlasmaVault
    modifier onlyPlasmaVault() {
        if (msg.sender != PLASMA_VAULT) {
            revert MidasExecutorUnauthorizedCaller();
        }
        _;
    }

    /// @notice Initializes the MidasExecutor with the authorized PlasmaVault address
    /// @param plasmaVault_ Address of the PlasmaVault (must not be address(0))
    constructor(address plasmaVault_) {
        if (plasmaVault_ == address(0)) {
            revert MidasExecutorInvalidPlasmaVaultAddress();
        }
        PLASMA_VAULT = plasmaVault_;
    }

    /// @notice Submit an async deposit request to a Midas Deposit Vault
    /// @param tokenIn Address of the token to deposit (e.g., USDC)
    /// @param amount Amount of tokenIn to deposit (in tokenIn decimals)
    /// @param depositVault Address of the Midas Deposit Vault
    /// @return requestId Unique ID for tracking the deposit request
    function depositRequest(
        address tokenIn,
        uint256 amount,
        address depositVault
    ) external onlyPlasmaVault returns (uint256 requestId) {
        if (tokenIn == address(0) || depositVault == address(0)) revert MidasExecutorZeroAddress();
        ERC20(tokenIn).forceApprove(depositVault, amount);

        uint256 amountInWad = IporMath.convertToWad(amount, ERC20(tokenIn).decimals());

        requestId = IMidasDepositVault(depositVault).depositRequest(tokenIn, amountInWad, bytes32(0));

        ERC20(tokenIn).forceApprove(depositVault, 0);
    }

    /// @notice Submit an async redemption request to a Midas Redemption Vault
    /// @param mToken Address of the mToken to redeem
    /// @param amount Amount of mTokens to redeem
    /// @param tokenOut Address of the output token (e.g., USDC)
    /// @param redemptionVault Address of the Midas Redemption Vault
    /// @return requestId Unique ID for tracking the redemption request
    function redeemRequest(
        address mToken,
        uint256 amount,
        address tokenOut,
        address redemptionVault
    ) external onlyPlasmaVault returns (uint256 requestId) {
        if (mToken == address(0) || tokenOut == address(0) || redemptionVault == address(0)) revert MidasExecutorZeroAddress();
        ERC20(mToken).forceApprove(redemptionVault, amount);

        requestId = IMidasRedemptionVault(redemptionVault).redeemRequest(tokenOut, amount);

        ERC20(mToken).forceApprove(redemptionVault, 0);
    }

    /// @notice Claim all tokens of a given type held by this executor and transfer them to PlasmaVault
    /// @param token Address of the token to claim
    /// @return amount Amount of tokens transferred to PlasmaVault
    function claimAssets(address token) external onlyPlasmaVault returns (uint256 amount) {
        if (token == address(0)) revert MidasExecutorZeroAddress();
        amount = IERC20(token).balanceOf(address(this));
        if (amount > 0) {
            IERC20(token).safeTransfer(PLASMA_VAULT, amount);
        }
    }
}
