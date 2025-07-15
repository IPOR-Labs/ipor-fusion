// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {CurveStableSwapNGPriceFeed} from "../../price_oracle/price_feed/CurveStableSwapNGPriceFeed.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title CurveStableSwapNGPriceFeedFactory
/// @notice Factory contract for creating price feeds that calculate USD prices for Curve StableSwap NG LP tokens
/// @dev This contract is upgradeable and uses UUPS pattern for upgrades
contract CurveStableSwapNGPriceFeedFactory is UUPSUpgradeable, Ownable2StepUpgradeable {
    /// @notice Emitted when a new Curve StableSwap NG price feed is created
    /// @param priceFeed The address of the newly created price feed
    /// @param curveStableSwapNG The address of the Curve StableSwap NG pool
    /// @param priceOracleMiddleware The address of the price oracle middleware
    event CurveStableSwapNGPriceFeedCreated(
        address priceFeed,
        address curveStableSwapNG,
        address priceOracleMiddleware
    );

    /// @notice Error thrown when an invalid address (zero address) is provided
    error InvalidAddress();

    /// @notice Error thrown when the price feed returns a non-positive price
    error InvalidPrice();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the factory contract
    /// @dev This function can only be called once during contract deployment
    /// @param initialFactoryAdmin_ The address that will be set as the initial admin of the factory
    function initialize(address initialFactoryAdmin_) external initializer {
        if (initialFactoryAdmin_ == address(0)) revert InvalidAddress();
        __Ownable_init(initialFactoryAdmin_);
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
    }

    /// @notice Creates a new Curve StableSwap NG price feed instance
    /// @param curveStableSwapNG_ The address of the Curve StableSwap NG pool
    /// @param priceOracleMiddleware_ The address of the price oracle middleware
    /// @return priceFeed The address of the newly created price feed
    function create(address curveStableSwapNG_, address priceOracleMiddleware_) external returns (address priceFeed) {
        priceFeed = address(new CurveStableSwapNGPriceFeed(curveStableSwapNG_, priceOracleMiddleware_));

        // check if the price feed is already created
        if (priceFeed == address(0)) revert InvalidAddress();

        // check if the price returns non-zero price
        (, int256 price, , , ) = CurveStableSwapNGPriceFeed(priceFeed).latestRoundData();
        if (price <= 0) revert InvalidPrice();

        emit CurveStableSwapNGPriceFeedCreated(priceFeed, curveStableSwapNG_, priceOracleMiddleware_);
    }

    /// @notice Authorizes an upgrade to a new implementation
    /// @dev Required by the OZ UUPS module, can only be called by the owner
    /// @param newImplementation Address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
