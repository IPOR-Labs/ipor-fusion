// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {DualCrossReferencePriceFeed} from "../../price_oracle/price_feed/DualCrossReferencePriceFeed.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title DualCrossReferencePriceFeedFactory
/// @notice Factory contract for creating price feeds that calculate USD prices by cross-referencing exactly two price feeds
/// @dev This contract is upgradeable and uses UUPS pattern for upgrades
contract DualCrossReferencePriceFeedFactory is UUPSUpgradeable, Ownable2StepUpgradeable {
    /// @notice Emitted when a new dual cross-reference price feed is created
    /// @param priceFeed The address of the newly created price feed
    /// @param assetX The address of the first asset
    /// @param assetXAssetYOracleFeed The address of the oracle feed for assetX/assetY pair
    /// @param assetYUsdOracleFeed The address of the oracle feed for assetY/USD pair
    event DualCrossReferencePriceFeedCreated(
        address priceFeed,
        address assetX,
        address assetXAssetYOracleFeed,
        address assetYUsdOracleFeed
    );

    /// @notice Error thrown when an invalid address (zero address) is provided
    error InvalidAddress();

    /// @notice Initializes the factory contract
    /// @dev This function can only be called once during contract deployment
    /// @param initialFactoryAdmin_ The address that will be set as the initial admin of the factory
    function initialize(address initialFactoryAdmin_) external initializer {
        if (initialFactoryAdmin_ == address(0)) revert InvalidAddress();
        __Ownable_init(initialFactoryAdmin_);
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
    }

    /// @notice Creates a new dual cross-reference price feed instance
    /// @param assetX_ The address of the first asset
    /// @param assetXAssetYOracleFeed_ The address of the oracle feed for assetX/assetY pair
    /// @param assetYUsdOracleFeed_ The address of the oracle feed for assetY/USD pair
    /// @return priceFeed The address of the newly created price feed
    function create(
        address assetX_,
        address assetXAssetYOracleFeed_,
        address assetYUsdOracleFeed_
    ) external returns (address priceFeed) {
        priceFeed = address(new DualCrossReferencePriceFeed(assetX_, assetXAssetYOracleFeed_, assetYUsdOracleFeed_));
        emit DualCrossReferencePriceFeedCreated(priceFeed, assetX_, assetXAssetYOracleFeed_, assetYUsdOracleFeed_);
    }

    /// @notice Authorizes an upgrade to a new implementation
    /// @dev Required by the OZ UUPS module, can only be called by the owner
    /// @param newImplementation Address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
