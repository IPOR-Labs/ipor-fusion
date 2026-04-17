// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {DIAPriceFeed} from "../../price_oracle/price_feed/DIAPriceFeed.sol";

/// @title DIAPriceFeedFactory
/// @notice UUPS-upgradeable factory for `DIAPriceFeed` instances.
/// @dev Mirrors the pattern used by `DualCrossReferencePriceFeedFactory`.
contract DIAPriceFeedFactory is UUPSUpgradeable, Ownable2StepUpgradeable {
    event DIAPriceFeedCreated(
        address priceFeed,
        address diaOracle,
        string key,
        uint32 maxStalePeriod,
        uint8 diaDecimals,
        uint8 priceFeedDecimals
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

    /// @notice Deploys a new `DIAPriceFeed`.
    /// @dev Argument validation (zero oracle, empty key, zero / too-long stale
    /// period, decimals sanity) is delegated to the `DIAPriceFeed` constructor;
    /// reverts surface here unchanged.
    /// @param diaOracle_ DIA oracle contract address.
    /// @param key_ DIA oracle key, e.g. "OUSD/USD".
    /// @param maxStalePeriod_ Maximum publication age, in seconds.
    /// @param diaDecimals_ Number of decimals used by the DIA oracle for this key
    ///        (usually 8, but some chains publish with 5).
    /// @param priceFeedDecimals_ Number of decimals the feed should expose
    ///        (must be >= `diaDecimals_`; DIA values are rescaled by
    ///        `10 ** (priceFeedDecimals_ - diaDecimals_)`).
    /// @return priceFeed Address of the newly deployed feed.
    function create(
        address diaOracle_,
        string calldata key_,
        uint32 maxStalePeriod_,
        uint8 diaDecimals_,
        uint8 priceFeedDecimals_
    ) external returns (address priceFeed) {
        priceFeed = address(
            new DIAPriceFeed(diaOracle_, key_, maxStalePeriod_, diaDecimals_, priceFeedDecimals_)
        );
        emit DIAPriceFeedCreated(priceFeed, diaOracle_, key_, maxStalePeriod_, diaDecimals_, priceFeedDecimals_);
    }

    /// @dev Required by the OZ UUPS module, can only be called by the owner.
    // solhint-disable-next-line no-empty-blocks
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
