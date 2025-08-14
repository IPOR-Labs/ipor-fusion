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

        uint256 lpTokenUnderlyingPrice;
        uint256 lpTokenUnderlyingPriceDecimals;

        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();
        address plasmaVault = address(this);

        for (uint256 i; i < len; ++i) {
            rewardVaultAddress = IERC4626(PlasmaVaultConfigLib.bytes32ToAddress(rewardVaults[i]));

            /// @dev Notice! In StakeDaoV2 deposited assets are 1:1 shares of the reward vault, so amount of underlying assets is equal to amount of shares
            /// @dev there is no need to convert to assets [ rewardVaultAddress.convertToAssets(rewardVaultAddress.balanceOf(plasmaVault)); ]
            rewardVaultAssets = rewardVaultAddress.balanceOf(plasmaVault);

            /// @dev Underlying asset of the reward vault is the lp token vault which compatible with ERC4626
            lpTokenAddress = rewardVaultAddress.asset();

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
}
