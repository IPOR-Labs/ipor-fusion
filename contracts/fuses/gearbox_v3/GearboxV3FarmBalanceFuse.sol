// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {IFarmingPool} from "./ext/IFarmingPool.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";

/// @title Fuse Gearbox V3 Farm Balance protocol responsible for calculating the balance of the Plasma Vault in the Gearbox V3 Farm protocol based on preconfigured market substrates
/// @dev Substrates in this fuse are the farmDToken addresses that are used in the Gearbox V3 Farm protocol for a given MARKET_ID
contract GearboxV3FarmBalanceFuse is IMarketBalanceFuse {
    using SafeCast for uint256;

    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        MARKET_ID = marketId_;
    }

    /// @return The balance of the Plasma Vault in associated with Fuse Balance marketId in USD, represented in 18 decimals
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
