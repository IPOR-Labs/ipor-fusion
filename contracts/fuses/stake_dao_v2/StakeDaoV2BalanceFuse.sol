// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";

/// @title StakeDaoV2BalanceFuse
/// @notice Fuse for calculating the balance of assets in StakeDAO V2 protocol
/// @dev This fuse calculates the total balance of assets held in StakeDAO V2 reward vaults by the PlasmaVault.
///      It accounts for the nested structure: Reward Vault -> LP Token Vault -> Underlying Asset.
contract StakeDaoV2BalanceFuse is IMarketBalanceFuse {
    using SafeCast for uint256;

    /// @dev The version of the contract.
    address public immutable VERSION;
    /// @dev The unique identifier for IporFusionMarkets.
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Calculates the total balance of assets in StakeDAO V2 reward vaults
    /// @dev Iterates through all configured reward vaults and calculates the total balance in USD (WAD decimals).
    ///      The calculation follows the chain: Reward Vault shares -> LP Token shares -> Underlying Asset value.
    /// @return balance The total balance of assets in USD (WAD decimals)
    function balanceOf() external view override returns (uint256 balance) {
        bytes32[] memory rewardVaults = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = rewardVaults.length;

        if (len == 0) {
            return 0;
        }

        IERC4626 rewardVaultAddress;
        uint256 rewardVaultAssets;

        address lpTokenAddress;
        uint256 lpTokenAssets;

        address lpTokenUnderlyingAddress;

        uint256 lpTokenUnderlyingPrice;
        uint256 lpTokenUnderlyingPriceDecimals;

        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();
        /// @dev If a granted reward vault's LP token is the PlasmaVault's own underlying asset,
        /// @dev any loose (unstaked) balance of it is already counted as idle by
        /// @dev `PlasmaVault._getGrossTotalAssets()` (`IERC20(asset()).balanceOf(address(this))`).
        /// @dev Adding it again here would double-count it. This is vault identity (the immutable
        /// @dev `asset()`), not a substrate grant, so reading it here does not police grants.
        address plasmaVaultAsset = IERC4626(address(this)).asset();

        /// @dev Tracks LP tokens already priced in this call so loose LP-vault shares are counted
        /// @dev exactly once, even when multiple granted reward vaults share the same LP token.
        address[] memory seenLpTokens = new address[](len);
        uint256 seenLpTokensCount;

        for (uint256 i; i < len; ++i) {
            rewardVaultAddress = IERC4626(PlasmaVaultConfigLib.bytes32ToAddress(rewardVaults[i]));

            /// @dev Notice! In StakeDaoV2 deposited assets are 1:1 shares of the reward vault, so amount of underlying assets is equal to amount of shares
            /// @dev there is no need to convert to assets [ rewardVaultAddress.convertToAssets(rewardVaultAddress.balanceOf(address(this))); ]
            rewardVaultAssets = rewardVaultAddress.balanceOf(address(this));

            /// @dev Underlying asset of the reward vault is the lp token vault which compatible with ERC4626
            lpTokenAddress = rewardVaultAddress.asset();

            /// @dev The supply fuse's instant withdraw can strand LP-vault shares in the PlasmaVault
            /// @dev when the outer reward-vault redeem succeeds but the inner LP-vault redeem fails
            /// @dev and is swallowed. Value any such loose LP-vault shares here too, so the position
            /// @dev is never invisible to totalAssets(). Reward-vault shares are 1:1 LP-vault shares
            /// @dev (see note above), so the loose LP-vault balance can be summed directly with the
            /// @dev staked amount before the single convertToAssets() call below. Dedup per LP token
            /// @dev so two granted reward vaults sharing one LP token never double-count it. Skip
            /// @dev entirely when the LP token is the PlasmaVault's own underlying asset -- that
            /// @dev balance is already counted as idle by `PlasmaVault._getGrossTotalAssets()`.
            if (
                lpTokenAddress != plasmaVaultAsset && _markLpTokenSeen(seenLpTokens, seenLpTokensCount, lpTokenAddress)
            ) {
                ++seenLpTokensCount;
                rewardVaultAssets += IERC4626(lpTokenAddress).balanceOf(address(this));
            }

            /// @dev Reward Vault shares are 1:1 Reward Vault assets
            /// @dev Reward Vault assets are LP Token shares
            lpTokenAssets = IERC4626(lpTokenAddress).convertToAssets(rewardVaultAssets);

            /// @dev Get the LP Token underlying asset address of the LP Token (ERC4626),
            /// @dev LP Token Underlying contract don't have to be ERC4626 compatible, should be ERC20 compatible
            lpTokenUnderlyingAddress = IERC4626(lpTokenAddress).asset();

            /// @dev Get the price of the LP Token underlying asset from price oracle
            (lpTokenUnderlyingPrice, lpTokenUnderlyingPriceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware)
                .getAssetPrice(lpTokenUnderlyingAddress);

            /// @dev Calculate balance in USD (WAD decimals)
            balance += IporMath.convertToWad(
                lpTokenAssets * lpTokenUnderlyingPrice,
                IERC20Metadata(lpTokenUnderlyingAddress).decimals() + lpTokenUnderlyingPriceDecimals
            );
        }

        return balance;
    }

    /// @dev Records `lpTokenAddress_` as seen if it is not already present in the first
    /// @dev `seenLpTokensCount_` entries of `seenLpTokens_`. Mutates `seenLpTokens_` in place
    /// @dev (memory arrays are passed by reference). Returns true if the token is new (and was
    /// @dev just recorded), false if it was already present.
    /// @dev Extracted out of `balanceOf()` to keep that function's stack shallow enough to compile
    /// @dev without `via-ir` (forbidden in this repo).
    function _markLpTokenSeen(
        address[] memory seenLpTokens_,
        uint256 seenLpTokensCount_,
        address lpTokenAddress_
    ) private pure returns (bool isNew) {
        for (uint256 j; j < seenLpTokensCount_; ++j) {
            if (seenLpTokens_[j] == lpTokenAddress_) {
                return false;
            }
        }
        seenLpTokens_[seenLpTokensCount_] = lpTokenAddress_;
        return true;
    }
}
