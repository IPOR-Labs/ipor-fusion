// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PlasmaVaultStorageLib} from "../libraries/PlasmaVaultStorageLib.sol";
import {PlasmaVaultLib} from "../libraries/PlasmaVaultLib.sol";
import {PlasmaVaultFeesLib} from "./lib/PlasmaVaultFeesLib.sol";
import {WithdrawManager} from "../managers/withdraw/WithdrawManager.sol";

/**
 * @title PlasmaVaultErc4626View
 * @notice ERC4626 compliant view functions delegated from PlasmaVault
 * @dev This contract is called via delegatecall from PlasmaVault to reduce main contract size.
 *      The "View" suffix indicates this contract contains only view functions for reading
 *      ERC4626 state. It acts as a "lens" into the vault's ERC4626 interface.
 *
 * Contains:
 * - previewDeposit, previewMint, previewRedeem, previewWithdraw
 * - maxDeposit, maxMint, maxWithdraw, maxRedeem
 * - getDepositFeeShares
 * - getMarketBalanceLastUpdateTimestamp, isMarketBalanceStale
 *
 * ERC4626 Compliance:
 * - All preview/max functions wrapped in try/catch to ensure MUST NOT revert requirement
 * - Proper fee inclusion in all calculations
 */
contract PlasmaVaultErc4626View {
    using Math for uint256;

    /// @notice Simulates deposit at current block given current on-chain conditions
    /// @dev ERC4626 compliant - MUST NOT revert. Wrapped in try/catch for external calls.
    /// @param assets_ Amount of underlying assets to deposit
    /// @return shares Amount of shares that would be minted
    function previewDeposit(uint256 assets_) external view returns (uint256) {
        uint256 shares = _previewDeposit(assets_);
        try this.getDepositFeeSharesExternal(shares) returns (uint256 feeShares) {
            return feeShares > 0 ? shares - feeShares : shares;
        } catch {
            // ERC4626: MUST NOT revert - return shares without fee deduction as fallback
            return shares;
        }
    }

    /// @notice Simulates mint at current block given current on-chain conditions
    /// @dev ERC4626 compliant - MUST NOT revert. Wrapped in try/catch for external calls.
    /// @param shares_ Amount of shares to mint
    /// @return assets Amount of underlying assets required
    function previewMint(uint256 shares_) external view returns (uint256) {
        try this.getDepositFeeSharesExternal(shares_) returns (uint256 feeShares) {
            return _previewMint(shares_ + feeShares);
        } catch {
            // ERC4626: MUST NOT revert - return preview without fee as fallback
            return _previewMint(shares_);
        }
    }

    /// @notice Simulates redemption at current block given current on-chain conditions
    /// @dev ERC4626 compliant - MUST NOT revert. Wrapped in try/catch for external calls.
    /// @param shares_ Amount of shares to redeem
    /// @return assets Amount of underlying assets that would be received
    function previewRedeem(uint256 shares_) external view returns (uint256) {
        address withdrawManager = PlasmaVaultStorageLib.getWithdrawManager().manager;

        if (withdrawManager != address(0)) {
            try WithdrawManager(withdrawManager).getWithdrawFee() returns (uint256 withdrawFee) {
                if (withdrawFee > 0) {
                    return _previewRedeem(Math.mulDiv(shares_, 1e18 - withdrawFee, 1e18));
                }
            } catch {
                // ERC4626: MUST NOT revert - return preview without fee as fallback
            }
        }

        return _previewRedeem(shares_);
    }

    /// @notice Simulates withdrawal at current block given current on-chain conditions
    /// @dev ERC4626 compliant - MUST NOT revert. Wrapped in try/catch for external calls.
    /// @param assets_ Amount of underlying assets to withdraw
    /// @return shares Amount of shares that would be burned (including fee shares)
    function previewWithdraw(uint256 assets_) external view returns (uint256) {
        address withdrawManager = PlasmaVaultStorageLib.getWithdrawManager().manager;

        if (withdrawManager != address(0)) {
            try WithdrawManager(withdrawManager).getWithdrawFee() returns (uint256 withdrawFee) {
                if (withdrawFee > 0) {
                    // Calculate total shares needed: sharesForAssets + feeShares
                    // where feeShares = sharesForAssets * withdrawFee / 1e18
                    // So totalShares = sharesForAssets * (1e18 + withdrawFee) / 1e18
                    // Round up since we're computing required shares
                    return Math.mulDiv(_previewWithdraw(assets_), 1e18 + withdrawFee, 1e18, Math.Rounding.Ceil);
                }
            } catch {
                // ERC4626: MUST NOT revert - return preview without fee as fallback
            }
        }
        return _previewWithdraw(assets_);
    }

    /// @notice Calculates maximum deposit amount allowed for an address
    /// @dev ERC4626 compliant - MUST NOT revert. Wrapped in try/catch for external calls.
    /// @return Maximum amount of assets that can be deposited
    function maxDeposit(address) external view returns (uint256) {
        uint256 totalSupplyCap = PlasmaVaultLib.getTotalSupplyCap();
        uint256 totalSupply_ = _totalSupply();

        if (totalSupply_ >= totalSupplyCap) {
            return 0;
        }

        uint256 exchangeRate = _convertToAssets(10 ** uint256(_decimals()));
        uint256 remainingShares = totalSupplyCap - totalSupply_;

        // ERC4626: MUST NOT revert - use try/catch for external call
        try this.getDepositFeeSharesExternal(remainingShares) returns (uint256 feeShares) {
            uint256 sharesToMint = remainingShares - feeShares;
            if (type(uint256).max / exchangeRate < sharesToMint) {
                return type(uint256).max;
            }
            return _convertToAssets(sharesToMint);
        } catch {
            // Fallback without fee calculation
            if (type(uint256).max / exchangeRate < remainingShares) {
                return type(uint256).max;
            }
            return _convertToAssets(remainingShares);
        }
    }

    /// @notice Calculates maximum number of shares that can be minted
    /// @dev ERC4626 compliant - MUST NOT revert. Wrapped in try/catch for external calls.
    /// @return Maximum number of shares that can be minted
    function maxMint(address) external view returns (uint256) {
        uint256 totalSupplyCap = PlasmaVaultLib.getTotalSupplyCap();
        uint256 totalSupply_ = _totalSupply();

        if (totalSupply_ >= totalSupplyCap) {
            return 0;
        }

        uint256 remainingShares = totalSupplyCap - totalSupply_;

        // ERC4626: MUST NOT revert - use try/catch for external call
        try this.getDepositFeeSharesExternal(remainingShares) returns (uint256 feeShares) {
            return remainingShares - feeShares;
        } catch {
            // Fallback without fee calculation
            return remainingShares;
        }
    }

    /// @notice Calculates maximum withdrawal amount considering withdrawal fees
    /// @dev ERC4626 compliant - MUST NOT revert. Wrapped in try/catch for external calls.
    /// @param owner_ The address to calculate max withdrawal for
    /// @return Maximum amount of assets that can be withdrawn
    function maxWithdraw(address owner_) external view returns (uint256) {
        address withdrawManager = PlasmaVaultStorageLib.getWithdrawManager().manager;
        uint256 ownerShares = _balanceOf(owner_);

        if (withdrawManager != address(0)) {
            // ERC4626: MUST NOT revert - use try/catch for external call
            try WithdrawManager(withdrawManager).getWithdrawFee() returns (uint256 withdrawFee) {
                if (withdrawFee > 0) {
                    // With a fee, effective shares = ownerShares / (1 + feeRate)
                    uint256 effectiveShares = Math.mulDiv(ownerShares, 1e18, 1e18 + withdrawFee, Math.Rounding.Floor);
                    return _convertToAssets(effectiveShares);
                }
            } catch {
                // ERC4626: MUST NOT revert - fall through to default behavior
            }
        }

        return _convertToAssets(ownerShares);
    }

    /// @notice Calculates maximum number of shares that can be redeemed
    /// @dev ERC4626 compliant - MUST NOT revert. Returns balanceOf(owner).
    /// @param owner_ The address to calculate max redemption for
    /// @return Maximum number of shares that can be redeemed
    function maxRedeem(address owner_) external view returns (uint256) {
        return _balanceOf(owner_);
    }

    /// @notice External helper to get deposit fee shares (used for try/catch pattern)
    /// @dev This is external to allow try/catch in view functions
    /// @param shares_ Amount of shares to calculate fee for
    /// @return feeShares Amount of shares that would be taken as fee
    function getDepositFeeSharesExternal(uint256 shares_) external view returns (uint256 feeShares) {
        (, feeShares) = PlasmaVaultFeesLib.prepareForRealizeDepositFee(shares_);
    }

    /// @notice Returns the timestamp of the last market balance update
    /// @dev Useful for integrators to determine staleness of totalAssets() value
    /// @return timestamp Unix timestamp of the last balance update (0 if never updated)
    function getMarketBalanceLastUpdateTimestamp() external view returns (uint32) {
        return PlasmaVaultStorageLib.getMarketBalanceLastUpdateTimestamp();
    }

    /// @notice Checks if market balances are considered stale based on a threshold
    /// @dev Helper function for integrators to validate data freshness
    /// @param maxStalenessSeconds_ Maximum acceptable age of balance data in seconds
    /// @return isStale True if balances haven't been updated within the threshold
    function isMarketBalanceStale(uint256 maxStalenessSeconds_) external view returns (bool isStale) {
        uint32 lastUpdate = PlasmaVaultStorageLib.getMarketBalanceLastUpdateTimestamp();
        if (lastUpdate == 0) {
            return true; // Never updated
        }
        return block.timestamp > lastUpdate + maxStalenessSeconds_;
    }

    // ============ Internal Helper Functions ============
    // These mirror the ERC4626 base implementation to work in delegatecall context

    function _previewDeposit(uint256 assets_) internal view returns (uint256) {
        return _convertToShares(assets_, Math.Rounding.Floor);
    }

    function _previewMint(uint256 shares_) internal view returns (uint256) {
        return _convertToAssets(shares_, Math.Rounding.Ceil);
    }

    function _previewRedeem(uint256 shares_) internal view returns (uint256) {
        return _convertToAssets(shares_, Math.Rounding.Floor);
    }

    function _previewWithdraw(uint256 assets_) internal view returns (uint256) {
        return _convertToShares(assets_, Math.Rounding.Ceil);
    }

    function _convertToShares(uint256 assets_, Math.Rounding rounding_) internal view returns (uint256) {
        return assets_.mulDiv(_totalSupply() + 10 ** _decimalsOffset(), _totalAssets() + 1, rounding_);
    }

    function _convertToShares(uint256 assets_) internal view returns (uint256) {
        return _convertToShares(assets_, Math.Rounding.Floor);
    }

    function _convertToAssets(uint256 shares_, Math.Rounding rounding_) internal view returns (uint256) {
        return shares_.mulDiv(_totalAssets() + 1, _totalSupply() + 10 ** _decimalsOffset(), rounding_);
    }

    function _convertToAssets(uint256 shares_) internal view returns (uint256) {
        return _convertToAssets(shares_, Math.Rounding.Floor);
    }

    function _totalSupply() internal view returns (uint256) {
        // Access ERC20 storage directly - this works because we're in delegatecall context
        // ERC20Upgradeable uses slot: keccak256("openzeppelin.storage.ERC20")
        PlasmaVaultStorageLib.ERC4626Storage storage erc4626 = PlasmaVaultStorageLib.getERC4626Storage();
        // We need to read totalSupply from ERC20 storage
        // Since we're in delegatecall, we can access the caller's storage
        // The totalSupply is stored in the standard ERC20 slot
        return _readTotalSupply();
    }

    function _readTotalSupply() internal view returns (uint256 supply) {
        // ERC20Upgradeable storage slot for _totalSupply
        // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ERC20")) - 1)) & ~bytes32(uint256(0xff))
        // = 0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00
        // _totalSupply is at offset 2 in this struct
        bytes32 slot = 0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace02;
        assembly {
            supply := sload(slot)
        }
    }

    function _balanceOf(address account_) internal view returns (uint256 bal) {
        // ERC20 balances mapping is at slot 0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00
        bytes32 baseSlot = 0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00;
        bytes32 slot = keccak256(abi.encode(account_, baseSlot));
        assembly {
            bal := sload(slot)
        }
    }

    function _totalAssets() internal view returns (uint256) {
        uint256 grossTotalAssets = _getGrossTotalAssets();
        uint256 unrealizedManagementFee = PlasmaVaultFeesLib.getUnrealizedManagementFee(grossTotalAssets);

        if (unrealizedManagementFee >= grossTotalAssets) {
            return 0;
        } else {
            return grossTotalAssets - unrealizedManagementFee;
        }
    }

    function _getGrossTotalAssets() internal view returns (uint256) {
        address asset_ = _asset();
        address rewardsClaimManagerAddress = PlasmaVaultLib.getRewardsClaimManagerAddress();

        uint256 baseAssets = IERC20(asset_).balanceOf(address(this)) + PlasmaVaultLib.getTotalAssetsInAllMarkets();

        if (rewardsClaimManagerAddress != address(0)) {
            // Try to get rewards balance, fallback to 0 if it fails
            try IRewardsClaimManager(rewardsClaimManagerAddress).balanceOf() returns (uint256 rewardsBalance) {
                return baseAssets + rewardsBalance;
            } catch {
                return baseAssets;
            }
        }
        return baseAssets;
    }

    function _asset() internal view returns (address) {
        return PlasmaVaultStorageLib.getERC4626Storage().asset;
    }

    function _decimals() internal view returns (uint8) {
        return PlasmaVaultStorageLib.getERC4626Storage().underlyingDecimals + _decimalsOffset();
    }

    function _decimalsOffset() internal view returns (uint8) {
        return 3; // Standard offset used in PlasmaVault
    }
}

interface IRewardsClaimManager {
    function balanceOf() external view returns (uint256);
}
