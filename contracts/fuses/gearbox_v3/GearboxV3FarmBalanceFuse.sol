// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {IFarmingPool} from "./ext/IFarmingPool.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";

/**
 * @title Fuse Gearbox V3 Farm Balance protocol responsible for calculating the balance of the Plasma Vault in the Gearbox V3 Farm protocol based on preconfigured market substrates
 * @notice Calculates the balance of staked assets in Gearbox V3 Farm protocol, converted to underlying asset value in USD
 * @dev Substrates in this fuse are the farmDToken addresses that are used in the Gearbox V3 Farm protocol for a given MARKET_ID.
 *      This fuse retrieves the staking balance from the first configured substrate, converts farmDToken to dToken (1:1 exchange rate),
 *      converts dToken to underlying assets, and converts to USD using price oracle middleware. The result is normalized to WAD (18 decimals).
 */
contract GearboxV3FarmBalanceFuse is IMarketBalanceFuse {
    using SafeCast for uint256;

    /// @notice Thrown when market ID is zero
    /// @custom:error GearboxV3FarmBalanceFuseInvalidMarketId
    error GearboxV3FarmBalanceFuseInvalidMarketId();

    /// @notice Address of this fuse contract version
    /// @dev Immutable value set in constructor, used for tracking and versioning
    address public immutable VERSION;

    /// @notice Market ID this fuse operates on
    /// @dev Immutable value set in constructor, used to retrieve market substrates (farmDToken addresses)
    uint256 public immutable MARKET_ID;

    /**
     * @notice Initializes the GearboxV3FarmBalanceFuse with a specific market ID
     * @param marketId_ The market ID used to identify the Gearbox V3 Farm farmDToken substrates
     * @dev Reverts if marketId_ is zero
     */
    constructor(uint256 marketId_) {
        if (marketId_ == 0) {
            revert GearboxV3FarmBalanceFuseInvalidMarketId();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /**
     * @notice Calculates the balance of staked assets in Gearbox V3 Farm protocol
     * @dev This function:
     *      1. Retrieves the first substrate (farmDToken address) configured for the market
     *      2. Gets the dToken (staking token) from the farmDToken
     *      3. Gets the underlying asset from the dToken (ERC4626 vault)
     *      4. Retrieves the staking balance from the farmDToken
     *      5. Converts farmDToken balance to dToken (1:1 exchange rate)
     *      6. Converts dToken balance to underlying assets using convertToAssets()
     *      7. Retrieves the underlying asset price from price oracle middleware
     *      8. Converts underlying asset amount to USD value normalized to WAD (18 decimals)
     *      Note: Only the first substrate is used for balance calculation.
     * @return The balance of staked assets in USD, normalized to WAD (18 decimals)
     */
    function balanceOf() external view override returns (uint256) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = substrates.length;

        if (len == 0) {
            return 0;
        }

        address farmDToken = PlasmaVaultConfigLib.bytes32ToAddress(substrates[0]);
        address dToken = IFarmingPool(farmDToken).stakingToken();
        address asset = IERC4626(dToken).asset();

        /// @dev exchange rate between farmDToken and dToken is 1:1
        uint256 balanceOfUnderlyingAssets = IERC4626(dToken).convertToAssets(
            IFarmingPool(farmDToken).balanceOf(address(this))
        );

        (uint256 price, uint256 priceDecimals) = IPriceOracleMiddleware(PlasmaVaultLib.getPriceOracleMiddleware())
            .getAssetPrice(asset);

        return
            IporMath.convertToWad(balanceOfUnderlyingAssets * price, IERC20Metadata(asset).decimals() + priceDecimals);
    }
}
