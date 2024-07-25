// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IMarketBalanceFuse} from "./../IMarketBalanceFuse.sol";
import {IporMath} from "./../../libraries/math/IporMath.sol";
import {PlasmaVaultConfigLib} from "./../../libraries/PlasmaVaultConfigLib.sol";
import {IChildLiquidityGauge} from "./ext/IChildLiquidityGauge.sol";
import {IPriceOracleMiddleware} from "./../../priceOracle/IPriceOracleMiddleware.sol";

contract CurveChildLiquidityGaugeBalanceFuse is IMarketBalanceFuse {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;

    uint256 private constant PRICE_DECIMALS = 8;

    uint256 public immutable MARKET_ID;
    IPriceOracleMiddleware public immutable PRICE_ORACLE;

    constructor(uint256 marketIdInput, address priceOracle) {
        MARKET_ID = marketIdInput;
    }

    function balanceOf(address plasmaVault) external view override returns (uint256) {
        /// @notice substrates below are the Curve staked LP tokens
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = substrates.length;
        if (len == 0) {
            return 0;
        }

        uint256 balance;
        address stakedLpTokenAddress;
        address lpTokenAddress;

        for (uint256 i; i < len; ++i) {
            stakedLpTokenAddress = PlasmaVaultConfigLib.bytes32ToAddress(substrates[i]);
            lpTokenAddress = IChildLiquidityGauge(stakedLpTokenAddress).lp_token();
        }
    }
}
