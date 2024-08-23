// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IFluidLendingStakingRewards} from "./ext/IFluidLendingStakingRewards.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";

/// @title Fuse Fluid Instadapp Staking protocol responsible for calculating the balance of the Plasma Vault in the Fluid Instadapp Staking protocol based on preconfigured market substrates
/// @dev Substrates in this fuse are the staking pools addresses that are used in the Fluid Instadapp Staking protocol for a given MARKET_ID
contract FluidInstadappStakingBalanceFuse is IMarketBalanceFuse {
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
