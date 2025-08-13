// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {BeefyVaultV7PriceFeed} from "../../price_oracle/price_feed/BeefyVaultV7PriceFeed.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title BeefyVaultV7PriceFeedFactory
/// @notice Factory contract for creating price feeds that calculate USD prices for Beefy Vault V7 LP tokens
/// @dev This contract is upgradeable and uses UUPS pattern for upgrades
contract BeefyVaultV7PriceFeedFactory is UUPSUpgradeable, Ownable2StepUpgradeable {
    /// @notice Emitted when a new Beefy Vault V7 price feed is created
    /// @param priceFeed The address of the newly created price feed
    /// @param beefyVaultV7 The address of the Beefy Vault V7
    /// @param priceOracleMiddleware The address of the price oracle middleware
    event BeefyVaultV7PriceFeedCreated(address priceFeed, address beefyVaultV7, address priceOracleMiddleware);

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

    /// @notice Creates a new Beefy Vault V7 price feed instance
    /// @param beefyVaultV7_ The address of the Beefy Vault V7
    /// @param priceOracleMiddleware_ The address of the price oracle middleware
    /// @return priceFeed The address of the newly created price feed
    function create(address beefyVaultV7_, address priceOracleMiddleware_) external returns (address priceFeed) {
        priceFeed = address(new BeefyVaultV7PriceFeed(beefyVaultV7_, priceOracleMiddleware_));

        // check if the price feed is already created
        if (priceFeed == address(0)) revert InvalidAddress();

        // check if the price returns non-zero price
        (, int256 price, , , ) = BeefyVaultV7PriceFeed(priceFeed).latestRoundData();
        if (price <= 0) revert InvalidPrice();

        emit BeefyVaultV7PriceFeedCreated(priceFeed, beefyVaultV7_, priceOracleMiddleware_);
    }

    /// @notice Authorizes an upgrade to a new implementation
    /// @dev Required by the OZ UUPS module, can only be called by the owner
    /// @param newImplementation Address of the new implementation
    // solhint-disable-next-line no-empty-blocks
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
