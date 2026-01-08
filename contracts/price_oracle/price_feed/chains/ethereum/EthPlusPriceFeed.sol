// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPriceFeed} from "../../IPriceFeed.sol";
import {IEthPlusOracle} from "../../ext/IEthPlusOracle.sol";

/// @title Price feed for ETH+ on Ethereum Mainnet
/// @notice Provides price feed functionality for ETH+ token by using the ETH+ Oracle
/// @dev Implements IPriceFeed interface
/// @dev base on https://vscode.blockscan.com/ethereum/0xf87d2F4d42856f0B6Eae140Aaf78bF0F777e9936
contract EthPlusPriceFeed is IPriceFeed {
    using SafeCast for uint256;

    /// @dev ETH+ Oracle address on Ethereum Mainnet
    address public constant ETH_PLUS_ORACLE = 0x3f11C47E7ed54b24D7EFC222FD406d8E1F49Fb69;

    /// @dev Error when invalid price is returned
    error InvalidPrice();

    /// @notice Returns the number of decimals for price precision
    /// @return decimals The number of decimal places
    function decimals() external pure override returns (uint8) {
        return 18;
    }

    /// @notice Gets the latest price data for ETH+ in USD
    /// @return roundId The round ID (always 0 for ETH+ Oracle)
    /// @return price The calculated ETH+ price in USD (with 18 decimals)
    /// @return startedAt The timestamp when the round started (always 0 for ETH+ Oracle)
    /// @return time The timestamp when the price was last updated (always 0 for ETH+ Oracle)
    /// @return answeredInRound The round ID in which the answer was computed (always 0 for ETH+ Oracle)
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound)
    {
        (uint256 lowerBound, uint256 upperBound) = IEthPlusOracle(ETH_PLUS_ORACLE).price();

        if (lowerBound == 0) revert InvalidPrice();

        uint256 averagePrice = (lowerBound + upperBound) / 2;

        return (
            0, // roundId not used in ETH+ Oracle
            averagePrice.toInt256(),
            0, // startedAt not used in ETH+ Oracle
            0, // time not used in ETH+ Oracle
            0 // answeredInRound not used in ETH+ Oracle
        );
    }
}
