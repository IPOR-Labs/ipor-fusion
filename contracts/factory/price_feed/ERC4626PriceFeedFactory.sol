// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC4626PriceFeed} from "../../price_oracle/price_feed/ERC4626PriceFeed.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";

/// @title ERC4626PriceFeedFactory
/// @notice Factory contract for creating price feeds that calculate USD prices for ERC4626 vaults
/// @dev This contract is upgradeable and uses UUPS pattern for upgrades
contract ERC4626PriceFeedFactory is UUPSUpgradeable, Ownable2StepUpgradeable {
    /// @notice Emitted when a new ERC4626 price feed is created
    /// @param priceFeed The address of the newly created price feed
    /// @param vault The address of the ERC4626 vault
    event ERC4626PriceFeedCreated(address priceFeed, address vault);

    /// @notice Error thrown when an invalid address (zero address) is provided
    error InvalidAddress();

    /// @notice Error thrown when the price feed returns an invalid price (zero or negative)
    error InvalidPrice();

    /// @notice Error thrown when the vault is not valid
    error VaultNotValid();

    /// @notice Error thrown when the asset of the vault is not valid
    error AssetOfVaultNotValid();

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

    /// @notice Creates a new ERC4626 price feed instance
    /// @dev The function validates that both addresses are valid and that the created price feed returns a valid price
    /// @param vaultAddress_ The address of the ERC4626 vault
    /// @param priceOracleMiddleware_ The address of the price oracle middleware (currently unused but kept for future compatibility)
    /// @return priceFeedAddress The address of the newly created price feed
    function create(address vaultAddress_, address priceOracleMiddleware_) external returns (address priceFeedAddress) {
        if (vaultAddress_ == address(0) || priceOracleMiddleware_ == address(0)) revert InvalidAddress();

        uint256 vaultDecimals = IERC4626(vaultAddress_).decimals();
        uint256 sharesPrice = IERC4626(vaultAddress_).convertToAssets(1e18);
        address asset = IERC4626(vaultAddress_).asset();

        if (vaultDecimals <= 0 || sharesPrice <= 0 || asset == address(0)) revert VaultNotValid();

        (uint256 assetPrice, uint256 decimals) = IPriceOracleMiddleware(priceOracleMiddleware_).getAssetPrice(asset);
        if (assetPrice <= 0 || decimals <= 0) revert AssetOfVaultNotValid();

        priceFeedAddress = address(new ERC4626PriceFeed(vaultAddress_));
        emit ERC4626PriceFeedCreated(priceFeedAddress, vaultAddress_);
    }

    /// @notice Authorizes an upgrade to a new implementation
    /// @dev Required by the OZ UUPS module, can only be called by the owner
    /// @param newImplementation Address of the new implementation
    // solhint-disable-next-line no-empty-blocks
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
