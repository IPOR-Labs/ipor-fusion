// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IPriceFeed} from "../../IPriceFeed.sol";

interface ISavingModule {
    /// @notice Current price of srUSD in rUSD (always >= 1e8)
    /// @return uint256 Price
    function currentPrice() external view returns (uint256);
}

/// @title SrUsdPriceFeedEthereum
/// @notice Price feed for srUSD on Ethereum Mainnet, using SavingModule to get the price, sUSD is always treated as 1 USD
contract SrUsdPriceFeedEthereum is IPriceFeed {
    using SafeCast for uint256;

    error InvalidSavingModule();

    /// @dev https://docs.reservoir.xyz/security-and-compliance/smart-contract-addresses
    address public immutable SAVING_MODULE;

    /// @notice The number of decimals used in price values
    // solhint-disable-next-line const-name-snakecase
    uint8 public constant override decimals = 8;

    constructor(address savingModule) {
        if (savingModule == address(0)) {
            revert InvalidSavingModule();
        }
        SAVING_MODULE = savingModule;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound)
    {
        uint256 srUSDPriceInRUSD = ISavingModule(SAVING_MODULE).currentPrice();

        /// @dev In this implementation sUSD is always treated as 1 USD

        return (0, srUSDPriceInRUSD.toInt256(), 0, 0, 0);
    }
}
