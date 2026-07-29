// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ChainlinkGuardedPriceFeed} from "../../price_oracle/price_feed/ChainlinkGuardedPriceFeed.sol";

/// @title ChainlinkGuardedPriceFeedFactory
/// @notice UUPS-upgradeable factory for `ChainlinkGuardedPriceFeed` instances.
/// Tracks created feeds per creator (`msg.sender`) and per wrapped aggregator.
/// @dev Mirrors the pattern used by `DualCrossReferencePriceFeedFactory`.
contract ChainlinkGuardedPriceFeedFactory is UUPSUpgradeable, Ownable2StepUpgradeable {
    /// @custom:storage-location erc7201:io.ipor.factory.ChainlinkGuardedPriceFeedFactory
    struct FactoryStorage {
        mapping(address creator => address[] priceFeeds) priceFeedsByCreator;
        mapping(address aggregator => address[] priceFeeds) priceFeedsByAggregator;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.factory.ChainlinkGuardedPriceFeedFactory")) - 1)) & ~bytes32(uint256(0xff))
    /// Do not change this value.
    bytes32 private constant FACTORY_STORAGE_SLOT = 0xebb272a95cc4593723a0affb0b34760049a5e648a7bd7da793f81a59569bfd00;

    /// @notice Emitted for every feed deployed by `create`.
    /// @param priceFeed Address of the newly deployed feed.
    /// @param aggregator Wrapped Chainlink aggregator (proxy) address.
    /// @param maxStalePeriod Maximum allowed answer age, in seconds.
    /// @param maxDeviation Maximum allowed deviation, WAD-scaled (1e18 == 100%).
    /// @param roundsToCheck Number of previous rounds averaged for the deviation check.
    /// @param minValidRounds Minimum number of usable previous rounds required.
    /// @param creator Caller of `create`.
    event ChainlinkGuardedPriceFeedCreated(
        address priceFeed,
        address aggregator,
        uint32 maxStalePeriod,
        uint256 maxDeviation,
        uint256 roundsToCheck,
        uint256 minValidRounds,
        address creator
    );

    error InvalidAddress();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the factory and its UUPS / Ownable2Step state.
    /// @param initialFactoryAdmin_ Address that becomes the factory owner.
    function initialize(address initialFactoryAdmin_) external initializer {
        if (initialFactoryAdmin_ == address(0)) revert InvalidAddress();
        __Ownable_init(initialFactoryAdmin_);
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
    }

    /// @notice Deploys a new `ChainlinkGuardedPriceFeed`.
    /// @dev Argument validation (zero aggregator, stale-period / deviation / rounds
    /// bounds) is delegated to the `ChainlinkGuardedPriceFeed` constructor; reverts
    /// surface here unchanged. After deployment the factory calls `latestRoundData()`
    /// once, so creation fails immediately for a dead or misconfigured aggregator or
    /// a `maxDeviation_` the current market data cannot satisfy.
    /// @param aggregator_ Chainlink aggregator (proxy) address to wrap.
    /// @param maxStalePeriod_ Maximum allowed answer age, in seconds.
    /// @param maxDeviation_ Maximum allowed deviation from the mean of previous
    ///        rounds, WAD-scaled (1e18 == 100%, e.g. 5e16 == 5%).
    /// @param roundsToCheck_ Number of previous rounds to average, in [1, 10].
    /// @param minValidRounds_ Minimum number of usable previous rounds required for a
    ///        read to succeed, in [1, `roundsToCheck_`].
    /// @return priceFeed Address of the newly deployed feed.
    function create(
        address aggregator_,
        uint32 maxStalePeriod_,
        uint256 maxDeviation_,
        uint256 roundsToCheck_,
        uint256 minValidRounds_
    ) external returns (address priceFeed) {
        priceFeed = address(
            new ChainlinkGuardedPriceFeed(
                aggregator_,
                maxStalePeriod_,
                maxDeviation_,
                roundsToCheck_,
                minValidRounds_
            )
        );

        ChainlinkGuardedPriceFeed(priceFeed).latestRoundData();

        FactoryStorage storage $ = _getFactoryStorage();
        $.priceFeedsByCreator[msg.sender].push(priceFeed);
        $.priceFeedsByAggregator[aggregator_].push(priceFeed);

        emit ChainlinkGuardedPriceFeedCreated(
            priceFeed,
            aggregator_,
            maxStalePeriod_,
            maxDeviation_,
            roundsToCheck_,
            minValidRounds_,
            msg.sender
        );
    }

    /// @notice Returns all price feeds created by `creator_`.
    /// @param creator_ Address that called `create`.
    /// @return Price feed addresses in creation order.
    function getPriceFeedsByCreator(address creator_) external view returns (address[] memory) {
        return _getFactoryStorage().priceFeedsByCreator[creator_];
    }

    /// @notice Returns all price feeds wrapping `aggregator_`.
    /// @param aggregator_ Chainlink aggregator (proxy) address.
    /// @return Price feed addresses in creation order.
    function getPriceFeedsByAggregator(address aggregator_) external view returns (address[] memory) {
        return _getFactoryStorage().priceFeedsByAggregator[aggregator_];
    }

    /// @notice Returns the number of price feeds created by `creator_`.
    /// @param creator_ Address that called `create`.
    /// @return Number of feeds created by `creator_`.
    function getPriceFeedsByCreatorCount(address creator_) external view returns (uint256) {
        return _getFactoryStorage().priceFeedsByCreator[creator_].length;
    }

    /// @notice Returns the number of price feeds wrapping `aggregator_`.
    /// @param aggregator_ Chainlink aggregator (proxy) address.
    /// @return Number of feeds wrapping `aggregator_`.
    function getPriceFeedsByAggregatorCount(address aggregator_) external view returns (uint256) {
        return _getFactoryStorage().priceFeedsByAggregator[aggregator_].length;
    }

    /// @dev Required by the OZ UUPS module, can only be called by the owner.
    // solhint-disable-next-line no-empty-blocks
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function _getFactoryStorage() private pure returns (FactoryStorage storage $) {
        assembly {
            $.slot := FACTORY_STORAGE_SLOT
        }
    }
}
