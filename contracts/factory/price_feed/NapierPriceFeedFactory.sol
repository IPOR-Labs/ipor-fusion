// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {NapierPtLpPriceFeed} from "../../price_oracle/price_feed/NapierPtLpPriceFeed.sol";
import {NapierYtTwapPriceFeed} from "../../price_oracle/price_feed/NapierYtTwapPriceFeed.sol";

/// @title NapierPriceFeedFactory
/// @notice Factory contract for creating price feeds for Napier Principal Tokens (PT) and LP tokens
/// @dev This contract is upgradeable and uses UUPS pattern for upgrades
contract NapierPriceFeedFactory is UUPSUpgradeable, Ownable2StepUpgradeable {
    /// @notice Emitted when a new Napier price feed is created
    /// @param priceFeed The address of the newly created price feed
    /// @param tokiChainlinkOracle The address of the Toki Chainlink compatible oracle
    event NapierPtLpPriceFeedCreated(address priceFeed, address tokiChainlinkOracle);

    /// @notice Emitted when a new Napier YT price feed is created
    /// @param priceFeed The address of the newly created YT price feed
    /// @param tokiOracle The address of the Toki oracle used for TWAP conversions
    /// @param liquidityToken The Napier pool liquidity token
    /// @param quoteAsset The quote asset (underlying or base asset) used for USD pricing
    /// @param twapWindow TWAP window configured for the feed
    event NapierYtTwapPriceFeedCreated(
        address priceFeed,
        address tokiOracle,
        address liquidityToken,
        address quoteAsset,
        uint32 twapWindow
    );

    /// @notice Error thrown when an invalid address (zero address) is provided
    error InvalidAddress();

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

    /// @notice Creates a new Napier price feed instance
    /// @dev The function validates provided addresses before deploying a new feed proxy
    /// @param priceMiddleware_ Address of the price oracle middleware
    /// @param tokiChainlinkOracle_ Address of the Toki Chainlink compatible oracle
    /// @return priceFeedAddress The address of the newly created price feed
    function createPriceFeed(
        address priceMiddleware_,
        address tokiChainlinkOracle_
    ) external returns (address priceFeedAddress) {
        if (priceMiddleware_ == address(0) || tokiChainlinkOracle_ == address(0)) {
            revert InvalidAddress();
        }

        NapierPtLpPriceFeed napierPriceFeed = new NapierPtLpPriceFeed(priceMiddleware_, tokiChainlinkOracle_);
        priceFeedAddress = address(napierPriceFeed);
        emit NapierPtLpPriceFeedCreated(priceFeedAddress, tokiChainlinkOracle_);
    }

    function createYtPriceFeed(
        address priceMiddleware_,
        address tokiOracle_,
        address liquidityToken_,
        uint32 twapWindow_,
        address quoteAsset_
    ) external returns (address priceFeedAddress) {
        if (priceMiddleware_ == address(0) || tokiOracle_ == address(0) || liquidityToken_ == address(0)) {
            revert InvalidAddress();
        }

        NapierYtTwapPriceFeed napierPriceFeed = new NapierYtTwapPriceFeed(
            priceMiddleware_,
            tokiOracle_,
            liquidityToken_,
            twapWindow_,
            quoteAsset_
        );
        priceFeedAddress = address(napierPriceFeed);
        emit NapierYtTwapPriceFeedCreated(priceFeedAddress, tokiOracle_, liquidityToken_, quoteAsset_, twapWindow_);
    }

    /// @notice Authorizes an upgrade to a new implementation
    /// @dev Required by the OZ UUPS module, can only be called by the owner
    /// @param newImplementation Address of the new implementation
    // solhint-disable-next-line no-empty-blocks
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
