// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IChronicle} from "../../../ext/IChronicle.sol";
import {IPriceFeed} from "../../IPriceFeed.sol";
import {Errors} from "../../../../libraries/errors/Errors.sol";

/// @title Price feed for USDM on Arbitrum
/// @notice PriceOracle adapter for Chronicle push-based price feeds.
/// @dev Note: Chronicle price feeds currently have a caller whitelist.
/// To be able read price data, the caller (this contract) must be explicitly authorized.
contract USDMPriceFeedArbitrum is IPriceFeed {
    using SafeCast for int256;
    using SafeCast for uint256;

    uint256 private constant WAD_UNIT = 1e18;

    uint256 private constant CHRONICLE_DECIMALS = 18;

    /// @dev wUSDM/USD Chronicle Oracle (Arbitrum)
    address public constant WUSDM_USD_ORACLE_FEED = 0xdC6720c996Fad27256c7fd6E0a271e2A4687eF18;
    address public constant WUSDM = 0x57F5E098CaD7A3D1Eed53991D4d66C45C9AF7812;

    IChronicle public immutable CHRONICLE;
    uint256 private immutable PRICE_DENOMINATOR;

    constructor() {
        CHRONICLE = IChronicle(WUSDM_USD_ORACLE_FEED);

        /// @dev Notice! It is enough to check during construction not during runtime because WUSDM_USD_ORACLE_FEED is immutable not upgradeable contract and decimals are not expected to change.
        if (CHRONICLE_DECIMALS != CHRONICLE.decimals()) {
            revert Errors.WrongDecimals();
        }

        PRICE_DENOMINATOR = 10 ** (CHRONICLE_DECIMALS - _decimals());
    }

    function decimals() external pure override returns (uint8) {
        return _decimals();
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound)
    {
        // Get wUSDM price in USD from Chronicle
        uint256 wUsdMPriceUSD = CHRONICLE.read();
        if (wUsdMPriceUSD == 0) {
            revert Errors.WrongValue();
        }

        // Get wUSDM total supply and total assets
        uint256 totalSupply = IERC4626(WUSDM).totalSupply();
        if (totalSupply == 0) {
            revert Errors.WrongValue();
        }

        uint256 totalAssets = IERC4626(WUSDM).totalAssets();

        // Calculate exchange rate with better precision handling
        uint256 wUsdMUsdmExchangeRate = (totalAssets * WAD_UNIT) / totalSupply;

        // Calculate final USDM price in USD
        uint256 usdmPriceUSD = ((wUsdMPriceUSD * wUsdMUsdmExchangeRate) / WAD_UNIT) / PRICE_DENOMINATOR;

        if (usdmPriceUSD == 0) {
            revert Errors.WrongValue();
        }

        return (uint80(0), usdmPriceUSD.toInt256(), 0, 0, 0);
    }

    function _decimals() internal pure returns (uint8) {
        return 8;
    }
}
