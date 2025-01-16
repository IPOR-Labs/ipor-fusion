// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IPriceFeed} from "./IPriceFeed.sol";
interface ISavingModule {

    /// @notice Current price of srUSD in rUSD (always >= 1e8)
    /// @return uint256 Price
    function currentPrice() external view returns (uint256);
}

/// @title SrUsdPriceFeedEthereum
/// @notice Price feed for srUSD on Ethereum Mainnet, using SavingModule to get the price, sUSD is always treated as 1 USD
contract SrUsdPriceFeedEthereum is IPriceFeed {
    error InvalidSavingModule();

    uint8 public constant override decimals = 8;

    /// @dev https://docs.reservoir.xyz/security-and-compliance/smart-contract-addresses
    address public immutable SAVING_MODULE;

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

        return (0, srUSDPriceInRUSD, 0, 0, 0);
    }
}
