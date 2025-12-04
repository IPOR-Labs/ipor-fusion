// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IFluidLendingStakingRewards} from "./ext/IFluidLendingStakingRewards.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";

/**
 * @title Fuse Fluid Instadapp Staking protocol responsible for calculating the balance of the Plasma Vault in the Fluid Instadapp Staking protocol based on preconfigured market substrates
 * @notice Calculates the balance of staked assets in Fluid Instadapp Staking protocol, converted to underlying asset value in USD
 * @dev Substrates in this fuse are the staking pool addresses that are used in the Fluid Instadapp Staking protocol for a given MARKET_ID.
 *      This fuse retrieves the staking balance from the first configured substrate, converts staking tokens to underlying assets,
 *      and converts to USD using price oracle middleware. The result is normalized to WAD (18 decimals).
 */
contract FluidInstadappStakingBalanceFuse is IMarketBalanceFuse {
    using SafeCast for uint256;

    /// @notice Address of this fuse contract version
    /// @dev Immutable value set in constructor, used for tracking and versioning
    address public immutable VERSION;

    /// @notice Market ID this fuse operates on
    /// @dev Immutable value set in constructor, used to retrieve market substrates (staking pool addresses)
    uint256 public immutable MARKET_ID;

    /**
     * @notice Initializes the FluidInstadappStakingBalanceFuse with a specific market ID
     * @param marketId_ The market ID used to identify the Fluid Instadapp Staking pool substrates
     */
    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /**
     * @notice Calculates the balance of staked assets in Fluid Instadapp Staking protocol
     * @dev This function:
     *      1. Retrieves the first substrate (staking pool address) configured for the market
     *      2. Gets the staking token (ERC4626 vault) from the staking pool
     *      3. Gets the underlying asset from the staking token
     *      4. Retrieves the staking balance from the staking pool
     *      5. Converts staking token balance to underlying assets using convertToAssets()
     *      6. Retrieves the underlying asset price from price oracle middleware
     *      7. Converts underlying asset amount to USD value normalized to WAD (18 decimals)
     *      Note: Only the first substrate is used for balance calculation.
     * @return The balance of staked assets in USD, normalized to WAD (18 decimals)
     */
    function balanceOf() external view override returns (uint256) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = substrates.length;

        if (len == 0) {
            return 0;
        }

        address stakingPool = PlasmaVaultConfigLib.bytes32ToAddress(substrates[0]);
        address stakingToken = IFluidLendingStakingRewards(stakingPool).stakingToken();
        address asset = IERC4626(stakingToken).asset();

        uint256 balanceOfUnderlyingAssets = IERC4626(stakingToken).convertToAssets(
            IFluidLendingStakingRewards(stakingPool).balanceOf(address(this))
        );

        if (balanceOfUnderlyingAssets == 0) {
            return 0;
        }

        (uint256 price, uint256 priceDecimals) = IPriceOracleMiddleware(PlasmaVaultLib.getPriceOracleMiddleware())
            .getAssetPrice(asset);

        return
            IporMath.convertToWad(balanceOfUnderlyingAssets * price, IERC20Metadata(asset).decimals() + priceDecimals);
    }
}
