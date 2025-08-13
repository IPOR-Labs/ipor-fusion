// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";

contract StakeDaoV2BalanceFuse is IMarketBalanceFuse {
    using SafeCast for uint256;

    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        MARKET_ID = marketId_;
    }

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
        uint256 lpTokenUnderlyingAssets;

        uint256 lpTokenUnderlyingPrice;
        uint256 lpTokenUnderlyingPriceDecimals;

        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();
        address plasmaVault = address(this);

        for (uint256 i; i < len; ++i) {
            rewardVaultAddress = IERC4626(PlasmaVaultConfigLib.bytes32ToAddress(rewardVaults[i]));

            /// @dev Notice! In StakeDaoV2 deposited assets are 1:1 shares of the reward vault,
            /// @dev so we don't need to convert to assets [ rewardVaultAddress.convertToAssets(rewardVaultAddress.balanceOf(plasmaVault)); ]
            rewardVaultAssets = rewardVaultAddress.balanceOf(plasmaVault);

            /// @dev Underlying asset of the reward vault is the lp token vault which compatible with ERC4626
            lpTokenAddress = rewardVaultAddress.asset();

            lpTokenAssets = IERC4626(lpTokenAddress).convertToAssets(rewardVaultAssets);

            /// @dev Get the lp token underlying asset of the lp token
            lpTokenUnderlyingAddress = IERC4626(lpTokenAddress).asset();

            /// @dev Convert lp token assets to lp token underlying assets
            lpTokenUnderlyingAssets = IERC4626(lpTokenAddress).convertToAssets(lpTokenAssets);

            /// @dev Get the price of the lp token underlying asset from price oracle
            (lpTokenUnderlyingPrice, lpTokenUnderlyingPriceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware)
                .getAssetPrice(lpTokenUnderlyingAddress);

            /// @dev Calculate balance in USD (WAD decimals)
            /// @dev The LP token vault returns underlying assets in the token's natural decimals
            /// @dev No need for additional decimal conversion since the vault handles this internally
            balance += IporMath.convertToWad(
                lpTokenUnderlyingAssets * lpTokenUnderlyingPrice,
                IERC20Metadata(lpTokenUnderlyingAddress).decimals() + lpTokenUnderlyingPriceDecimals
            );
        }

        return balance;
    }
}
