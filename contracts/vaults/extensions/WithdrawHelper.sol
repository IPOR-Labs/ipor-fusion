// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title WithdrawHelper
 * @notice Helper contract for executing maxWithdraw + withdraw with Multicall3
 * @dev This contract can be called via Multicall3 to handle the withdrawal flow
 */
contract WithdrawHelper {
    error InvalidVaultAddress();
    error WithdrawalFailed();

    /**
     * @notice Executes maxWithdraw and withdraw for a specific vault
     * @dev This function can be called via Multicall3 to get maxWithdraw and withdraw atomically
     * @param vault_ Address of the vault contract
     * @param receiver_ Address to receive the withdrawn assets
     * @param owner_ Owner of the shares to burn
     * @return maxWithdrawAmount The amount that was withdrawn
     * @return sharesBurned Amount of shares burned
     */
    function executeMaxWithdrawAndWithdraw(
        address vault_,
        address receiver_,
        address owner_
    ) external returns (uint256 maxWithdrawAmount, uint256 sharesBurned) {
        if (vault_ == address(0)) {
            revert InvalidVaultAddress();
        }

        // Get maxWithdraw amount
        (bool success1, bytes memory data1) = vault_.call(abi.encodeWithSignature("maxWithdraw(address)", owner_));

        if (!success1) {
            revert WithdrawalFailed();
        }

        maxWithdrawAmount = abi.decode(data1, (uint256));

        if (maxWithdrawAmount == 0) {
            revert WithdrawalFailed();
        }

        // Execute withdrawal
        (bool success2, bytes memory data2) = vault_.call(
            abi.encodeWithSignature("withdraw(uint256,address,address)", maxWithdrawAmount, receiver_, owner_)
        );

        if (!success2) {
            revert WithdrawalFailed();
        }

        sharesBurned = abi.decode(data2, (uint256));

        return (maxWithdrawAmount, sharesBurned);
    }

    /**
     * @notice Executes withdrawal with validation against maxWithdraw
     * @dev This function validates the withdrawal amount against current maxWithdraw
     * @param vault_ Address of the vault contract
     * @param assets_ Amount to withdraw
     * @param receiver_ Address to receive the withdrawn assets
     * @param owner_ Owner of the shares to burn
     * @return actualWithdrawn The amount actually withdrawn
     * @return sharesBurned Amount of shares burned
     */
    function executeWithdrawWithValidation(
        address vault_,
        uint256 assets_,
        address receiver_,
        address owner_
    ) external returns (uint256 actualWithdrawn, uint256 sharesBurned) {
        if (vault_ == address(0)) {
            revert InvalidVaultAddress();
        }

        // Get maxWithdraw amount
        (bool success1, bytes memory data1) = vault_.call(abi.encodeWithSignature("maxWithdraw(address)", owner_));

        if (!success1) {
            revert WithdrawalFailed();
        }

        uint256 maxWithdrawAmount = abi.decode(data1, (uint256));

        // Validate withdrawal amount
        if (assets_ > maxWithdrawAmount || assets_ == 0) {
            revert WithdrawalFailed();
        }

        // Execute withdrawal
        (bool success2, bytes memory data2) = vault_.call(
            abi.encodeWithSignature("withdraw(uint256,address,address)", assets_, receiver_, owner_)
        );

        if (!success2) {
            revert WithdrawalFailed();
        }

        sharesBurned = abi.decode(data2, (uint256));
        actualWithdrawn = assets_;

        return (actualWithdrawn, sharesBurned);
    }

    /**
     * @notice Gets maxWithdraw amount for a vault
     * @dev This can be used as a view call or as part of a multicall
     * @param vault_ Address of the vault contract
     * @param owner_ Owner to check maxWithdraw for
     * @return maxWithdrawAmount The maximum amount that can be withdrawn
     */
    function getMaxWithdraw(address vault_, address owner_) external view returns (uint256 maxWithdrawAmount) {
        if (vault_ == address(0)) {
            revert InvalidVaultAddress();
        }

        (bool success, bytes memory data) = vault_.staticcall(abi.encodeWithSignature("maxWithdraw(address)", owner_));

        if (!success) {
            revert WithdrawalFailed();
        }

        maxWithdrawAmount = abi.decode(data, (uint256));
    }
}
