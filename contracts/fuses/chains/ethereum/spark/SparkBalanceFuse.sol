// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IporMath} from "../../../../libraries/math/IporMath.sol";
import {IPriceOracleMiddleware} from "../../../../price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultLib} from "../../../../libraries/PlasmaVaultLib.sol";
import {IMarketBalanceFuse} from "../../../IMarketBalanceFuse.sol";
import {ISavingsDai} from "./ext/ISavingsDai.sol";

/// @title Fuse Spark Balance protocol responsible for calculating the balance of the Plasma Vault in the Spark protocol
contract SparkBalanceFuse is IMarketBalanceFuse {
    address public constant SDAI = 0x83F20F44975D03b1b09e64809B757c47f942BEeA;
    address private constant USD = address(0x0000000000000000000000000000000000000348);

    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        MARKET_ID = marketId_;
    }

    /// @return The balance of the Plasma Vault in associated with Fuse Balance marketId in USD, represented in 18 decimals
    function balanceOf() external view override returns (uint256) {
        return _convertToUsd(SDAI, ISavingsDai(SDAI).balanceOf(address(this)));
    }

    function _convertToUsd(address asset_, uint256 amount_) internal view returns (uint256) {
        if (amount_ == 0) return 0;
        (uint256 price, uint256 decimals) = IPriceOracleMiddleware(PlasmaVaultLib.getPriceOracleMiddleware())
            .getAssetPrice(asset_);
        return IporMath.convertToWad(amount_ * price, IERC20Metadata(asset_).decimals() + decimals);
    }
}
