// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.22;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IPriceOracleMiddleware} from "../../priceOracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IFluidLendingStakingRewards} from "./ext/IFluidLendingStakingRewards.sol";

contract FluidInstadappStakingBalanceFuse is IMarketBalanceFuse {
    using SafeCast for uint256;

    uint256 private constant PRICE_DECIMALS = 8;
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        MARKET_ID = marketId_;
    }

    function balanceOf(address plasmaVault_) external view override returns (uint256) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = substrates.length;

        if (len == 0) {
            return 0;
        }

        address stakingPool = PlasmaVaultConfigLib.bytes32ToAddress(substrates[0]);
        address stakingToken = IFluidLendingStakingRewards(stakingPool).stakingToken();
        address asset = IERC4626(stakingToken).asset();

        uint256 balanceOfUnderlyingAssets = IERC4626(stakingToken).convertToAssets(
            IFluidLendingStakingRewards(stakingPool).balanceOf(plasmaVault_)
        );

        if (balanceOfUnderlyingAssets == 0) {
            return 0;
        }

        uint256 price = IPriceOracleMiddleware(PlasmaVaultLib.getPriceOracle()).getAssetPrice(asset);

        return
            IporMath.convertToWad(balanceOfUnderlyingAssets * price, IERC20Metadata(asset).decimals() + PRICE_DECIMALS);
    }
}
