// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IChronicle} from "./../IChronicle.sol";
import {IPriceFeed} from "./../IPriceFeed.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title USDMPriceFeed
/// @notice PriceOracle adapter for Chronicle push-based price feeds.
/// @dev Note: Chronicle price feeds currently have a caller whitelist.
/// To be able read price data, the caller (this contract) must be explicitly authorized.
contract USDMPriceFeed is IPriceFeed {
    using SafeCast for int256;
    using SafeCast for uint256;
    // wUSDM/USD Chronicle Oracle (Arbitrum)
    address public constant WUSDM_USD_ORACLE_FEED = 0xdC6720c996Fad27256c7fd6E0a271e2A4687eF18;
    address public constant WUSDM = 0x57F5E098CaD7A3D1Eed53991D4d66C45C9AF7812;
    IChronicle public chronicle = IChronicle(WUSDM_USD_ORACLE_FEED);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound)
    {
        uint256 wUSDMPriceUSD = chronicle.read();
        uint256 wUSDMUSDMExchangeRate = (IERC4626(WUSDM).totalAssets() * 1e18) / IERC4626(WUSDM).totalSupply();
        uint256 USDMPriceUSD = (wUSDMPriceUSD * wUSDMUSDMExchangeRate) / 1e18;
        // To int
        return (uint80(0), USDMPriceUSD.toInt256(), 0, 0, 0);
    }
}
