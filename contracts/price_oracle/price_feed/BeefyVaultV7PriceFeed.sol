// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IPriceFeed} from "./IPriceFeed.sol";
import {IBeefyVaultV7} from "./ext/IBeefyVaultV7.sol";
import {IPriceOracleMiddleware} from "../IPriceOracleMiddleware.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";

contract BeefyVaultV7PriceFeed is IPriceFeed {
    error ZeroAddress();
    error PriceOracleMiddleware_InvalidPrice();
    error BeefyVaultV7_InvalidPricePerFullShare();

    address public immutable BEFY_VAULT_V7;
    address public immutable PRICE_ORACLE_MIDDLEWARE;

    uint256 public constant PRICE_PER_FULL_SHARE_DECIMALS = 18;

    constructor(address _beefyVaultV7, address _priceOracleMiddleware) {
        if (_beefyVaultV7 == address(0) || _priceOracleMiddleware == address(0)) {
            revert ZeroAddress();
        }

        BEFY_VAULT_V7 = _beefyVaultV7;
        PRICE_ORACLE_MIDDLEWARE = _priceOracleMiddleware;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound)
    {
        address asset = address(IBeefyVaultV7(BEFY_VAULT_V7).want());
        IPriceOracleMiddleware priceOracleMiddleware = IPriceOracleMiddleware(PRICE_ORACLE_MIDDLEWARE);
        (uint256 priceAsset, uint256 priceAssetDecimals) = priceOracleMiddleware.getAssetPrice(asset);
        if (priceAsset == 0) {
            revert PriceOracleMiddleware_InvalidPrice();
        }
        uint256 pricePerFullShare = IBeefyVaultV7(BEFY_VAULT_V7).getPricePerFullShare();
        if (pricePerFullShare == 0) {
            revert BeefyVaultV7_InvalidPricePerFullShare();
        }

        /// @dev pricePerFullShare has 18 decimals, from documentation and implementation
        uint256 pricePerShare = IporMath.convertToWad(
            priceAsset * pricePerFullShare,
            priceAssetDecimals + PRICE_PER_FULL_SHARE_DECIMALS
        );

        return (0, int256(pricePerShare), 0, 0, 0);
    }

    function decimals() external view override returns (uint8) {
        return 18;
    }
}
