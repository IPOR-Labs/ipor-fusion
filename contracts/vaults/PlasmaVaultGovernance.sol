// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {FusesLib} from "../libraries/FusesLib.sol";
import {PlasmaVaultConfigLib} from "../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib, InstantWithdrawalFusesParamsStruct} from "../libraries/PlasmaVaultLib.sol";
import {IPriceOracleMiddleware} from "../price_oracle/IPriceOracleMiddleware.sol";
import {Errors} from "../libraries/errors/Errors.sol";
import {PlasmaVaultStorageLib} from "../libraries/PlasmaVaultStorageLib.sol";
import {AssetDistributionProtectionLib, MarketLimit} from "../libraries/AssetDistributionProtectionLib.sol";
import {AccessManagedUpgradeable} from "../managers/access/AccessManagedUpgradeable.sol";
import {CallbackHandlerLib} from "../libraries/CallbackHandlerLib.sol";
import {IPlasmaVaultGovernance} from "../interfaces/IPlasmaVaultGovernance.sol";
import {IIporFusionAccessManager} from "../interfaces/IIporFusionAccessManager.sol";

/// @title Plasma Vault Governance
/// @notice Manages the configuration and governance aspects of the Plasma Vault including fuses, price oracle, fees, and access control
/// @dev Inherits AccessManagedUpgradeable for role-based access control
/// @custom:security-contact security@ipor.network
abstract contract PlasmaVaultGovernance is IPlasmaVaultGovernance, AccessManagedUpgradeable {
    /// @notice Checks if a substrate is granted for a specific market
    /// @param marketId_ The ID of the market to check
    /// @param substrate_ The substrate identifier to verify
    /// @return bool True if the substrate is granted for the market
    /// @custom:access External view
    function isMarketSubstrateGranted(uint256 marketId_, bytes32 substrate_) external view override returns (bool) {
        return PlasmaVaultConfigLib.isMarketSubstrateGranted(marketId_, substrate_);
    }

    /// @notice Verifies if a fuse is supported by the vault
    /// @param fuse_ The address of the fuse to check
    /// @return bool True if the fuse is supported
    /// @custom:access External view
    function isFuseSupported(address fuse_) external view override returns (bool) {
        return FusesLib.isFuseSupported(fuse_);
    }

    /// @notice Checks if a balance fuse is supported for a specific market
    /// @param marketId_ The ID of the market
    /// @param fuse_ The address of the balance fuse
    /// @return bool True if the balance fuse is supported for the market
    /// @custom:access External view
    function isBalanceFuseSupported(uint256 marketId_, address fuse_) external view override returns (bool) {
        return FusesLib.isBalanceFuseSupported(marketId_, fuse_);
    }

    /// @notice Checks if markets limits protection is active
    /// @return bool True if markets limits are activated
    /// @custom:access Public view
    function isMarketsLimitsActivated() public view override returns (bool) {
        return AssetDistributionProtectionLib.isMarketsLimitsActivated();
    }

    /// @notice Gets all substrates granted for a specific market
    /// @param marketId_ The ID of the market
    /// @return bytes32[] Array of granted substrates
    /// @custom:access External view
    function getMarketSubstrates(uint256 marketId_) external view override returns (bytes32[] memory) {
        return PlasmaVaultConfigLib.getMarketSubstrates(marketId_);
    }

    /// @notice Gets all supported fuses
    /// @return address[] Array of supported fuse addresses
    /// @custom:access External view
    function getFuses() external view override returns (address[] memory) {
        return FusesLib.getFusesArray();
    }

    /// @notice Gets the current price oracle middleware address
    /// @return address The price oracle middleware contract address
    /// @custom:access External view
    function getPriceOracleMiddleware() external view override returns (address) {
        return PlasmaVaultLib.getPriceOracleMiddleware();
    }

    /// @notice Gets the performance fee configuration
    /// @return feeData The current performance fee data
    /// @custom:access External view
    function getPerformanceFeeData()
        external
        view
        override
        returns (PlasmaVaultStorageLib.PerformanceFeeData memory feeData)
    {
        feeData = PlasmaVaultLib.getPerformanceFeeData();
    }

    /// @notice Gets the management fee configuration
    /// @return feeData The current management fee data
    /// @custom:access External view
    function getManagementFeeData()
        external
        view
        override
        returns (PlasmaVaultStorageLib.ManagementFeeData memory feeData)
    {
        feeData = PlasmaVaultLib.getManagementFeeData();
    }

    /// @notice Gets the access manager contract address
    /// @return address The access manager address
    /// @custom:access External view
    function getAccessManagerAddress() external view override returns (address) {
        return authority();
    }

    /// @notice Gets the rewards claim manager address
    /// @return address The rewards claim manager contract address
    /// @custom:access External view
    function getRewardsClaimManagerAddress() external view override returns (address) {
        return PlasmaVaultLib.getRewardsClaimManagerAddress();
    }

    /// @notice Gets all instant withdrawal fuses
    /// @return address[] Array of instant withdrawal fuse addresses
    /// @custom:access External view
    function getInstantWithdrawalFuses() external view override returns (address[] memory) {
        return PlasmaVaultLib.getInstantWithdrawalFuses();
    }

    /// @notice Gets parameters for an instant withdrawal fuse
    /// @param fuse_ The fuse address
    /// @param index_ The parameter index
    /// @return bytes32[] Array of parameters for the fuse
    /// @custom:access External view
    function getInstantWithdrawalFusesParams(
        address fuse_,
        uint256 index_
    ) external view override returns (bytes32[] memory) {
        return PlasmaVaultLib.getInstantWithdrawalFusesParams(fuse_, index_);
    }

    /// @notice Gets the market limit for a specific market
    /// @param marketId_ The ID of the market
    /// @return uint256 The market limit percentage
    /// @custom:access External view
    function getMarketLimit(uint256 marketId_) external view override returns (uint256) {
        return PlasmaVaultStorageLib.getMarketsLimits().limitInPercentage[marketId_];
    }

    /// @notice Gets the dependency balance graph for a market
    /// @param marketId_ The ID of the market
    /// @return uint256[] The dependency graph array
    /// @custom:access External view
    function getDependencyBalanceGraph(uint256 marketId_) external view override returns (uint256[] memory) {
        return PlasmaVaultStorageLib.getDependencyBalanceGraph().dependencyGraph[marketId_];
    }

    /// @notice Gets the total supply cap
    /// @return uint256 The maximum total supply allowed
    /// @custom:access External view
    function getTotalSupplyCap() external view override returns (uint256) {
        return PlasmaVaultLib.getTotalSupplyCap();
    }

    /// @notice Adds a balance fuse for a specific market
    /// @param marketId_ The ID of the market
    /// @param fuse_ The address of the fuse to add
    /// @dev Only callable by accounts with FUSE_MANAGER_ROLE
    /// @custom:access FUSE_MANAGER_ROLE restricted
    function addBalanceFuse(uint256 marketId_, address fuse_) external override restricted {
        _addBalanceFuse(marketId_, fuse_);
    }

    /// @notice Removes a balance fuse from a specific market
    /// @param marketId_ The ID of the market
    /// @param fuse_ The address of the fuse to remove
    /// @dev Only callable by accounts with FUSE_MANAGER_ROLE
    /// @custom:access FUSE_MANAGER_ROLE restricted
    function removeBalanceFuse(uint256 marketId_, address fuse_) external override restricted {
        FusesLib.removeBalanceFuse(marketId_, fuse_);
    }

    /// @notice Grants substrates to a specific market
    /// @param marketId_ The ID of the market
    /// @param substrates_ Array of substrates to grant
    /// @dev Only callable by accounts with ATOMIST_ROLE
    /// @custom:access ATOMIST_ROLE restricted
    function grantMarketSubstrates(uint256 marketId_, bytes32[] calldata substrates_) external override restricted {
        PlasmaVaultConfigLib.grantMarketSubstrates(marketId_, substrates_);
    }

    /// @notice Updates dependency balance graphs for multiple markets
    /// @param marketIds_ Array of market IDs
    /// @param dependencies_ Array of dependency arrays for each market
    /// @dev Only callable by accounts with ATOMIST_ROLE
    /// @custom:access ATOMIST_ROLE restricted
    function updateDependencyBalanceGraphs(
        uint256[] memory marketIds_,
        uint256[][] memory dependencies_
    ) external override restricted {
        uint256 marketIdsLength = marketIds_.length;
        if (marketIdsLength != dependencies_.length) {
            revert Errors.WrongArrayLength();
        }
        for (uint256 i; i < marketIdsLength; ++i) {
            PlasmaVaultStorageLib.getDependencyBalanceGraph().dependencyGraph[marketIds_[i]] = dependencies_[i];
        }
    }

    /// @notice Configures the instant withdrawal fuses. Order of the fuse is important, as it will be used in the same order during the instant withdrawal process
    /// @param fuses_ Array of instant withdrawal fuse configurations
    /// @dev Order of the fuses is important, the same fuse can be used multiple times with different parameters (for example different assets, markets or any other substrate specific for the fuse)
    /// @custom:access CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE restricted
    function configureInstantWithdrawalFuses(
        InstantWithdrawalFusesParamsStruct[] calldata fuses_
    ) external override restricted {
        PlasmaVaultLib.configureInstantWithdrawalFuses(fuses_);
    }

    /// @notice Adds new fuses to the vault
    /// @param fuses_ Array of fuse addresses to add
    /// @dev Only callable by accounts with FUSE_MANAGER_ROLE
    /// @custom:access FUSE_MANAGER_ROLE restricted
    function addFuses(address[] calldata fuses_) external override restricted {
        for (uint256 i; i < fuses_.length; ++i) {
            FusesLib.addFuse(fuses_[i]);
        }
    }

    /// @notice Removes fuses from the vault
    /// @param fuses_ Array of fuse addresses to remove
    /// @dev Only callable by accounts with FUSE_MANAGER_ROLE
    /// @custom:access FUSE_MANAGER_ROLE restricted
    function removeFuses(address[] calldata fuses_) external override restricted {
        for (uint256 i; i < fuses_.length; ++i) {
            FusesLib.removeFuse(fuses_[i]);
        }
    }

    /// @notice Sets the price oracle middleware address
    /// @param priceOracleMiddleware_ The new price oracle middleware address
    /// @dev Only callable by accounts with ATOMIST_ROLE
    /// @custom:access ATOMIST_ROLE restricted
    function setPriceOracleMiddleware(address priceOracleMiddleware_) external override restricted {
        IPriceOracleMiddleware oldPriceOracleMiddleware = IPriceOracleMiddleware(PlasmaVaultLib.getPriceOracleMiddleware());
        IPriceOracleMiddleware newPriceOracleMiddleware = IPriceOracleMiddleware(priceOracleMiddleware_);

        if (
            oldPriceOracleMiddleware.QUOTE_CURRENCY() != newPriceOracleMiddleware.QUOTE_CURRENCY() ||
            oldPriceOracleMiddleware.QUOTE_CURRENCY_DECIMALS() != newPriceOracleMiddleware.QUOTE_CURRENCY_DECIMALS()
        ) {
            revert Errors.UnsupportedPriceOracleMiddleware();
        }

        PlasmaVaultLib.setPriceOracleMiddleware(priceOracleMiddleware_);
    }

    /// @notice Configures the performance fee settings
    /// @param feeAccount_ Address to receive performance fees
    /// @param feeInPercentage_ Fee percentage with 2 decimals
    /// @dev Only callable by accounts with TECH_PERFORMANCE_FEE_MANAGER_ROLE
    /// @custom:access TECH_PERFORMANCE_FEE_MANAGER_ROLE restricted
    function configurePerformanceFee(address feeAccount_, uint256 feeInPercentage_) external override restricted {
        PlasmaVaultLib.configurePerformanceFee(feeAccount_, feeInPercentage_);
    }

    /// @notice Configures the management fee settings
    /// @param feeAccount_ Address to receive management fees
    /// @param feeInPercentage_ Fee percentage with 2 decimals
    /// @dev Only callable by accounts with TECH_MANAGEMENT_FEE_MANAGER_ROLE
    /// @custom:access TECH_MANAGEMENT_FEE_MANAGER_ROLE restricted
    function configureManagementFee(address feeAccount_, uint256 feeInPercentage_) external override restricted {
        PlasmaVaultLib.configureManagementFee(feeAccount_, feeInPercentage_);
    }

    /// @notice Sets the rewards claim manager address
    /// @param rewardsClaimManagerAddress_ The new rewards claim manager address
    /// @dev Only callable by accounts with TECH_REWARDS_CLAIM_MANAGER_ROLE
    /// @custom:access TECH_REWARDS_CLAIM_MANAGER_ROLE restricted
    function setRewardsClaimManagerAddress(address rewardsClaimManagerAddress_) public override restricted {
        PlasmaVaultLib.setRewardsClaimManagerAddress(rewardsClaimManagerAddress_);
    }

    /// @notice Sets up market limits for asset distribution protection
    /// @param marketsLimits_ Array of market limit configurations
    /// @dev Only callable by accounts with ATOMIST_ROLE
    /// @custom:access ATOMIST_ROLE restricted
    function setupMarketsLimits(MarketLimit[] calldata marketsLimits_) external override restricted {
        AssetDistributionProtectionLib.setupMarketsLimits(marketsLimits_);
    }

    /// @notice Activates the markets limits protection, by default it is deactivated. After activation the limits
    /// is setup for each market separately.
    /// @dev Only callable by accounts with ATOMIST_ROLE
    /// @custom:access ATOMIST_ROLE restricted
    function activateMarketsLimits() public override restricted {
        AssetDistributionProtectionLib.activateMarketsLimits();
    }

    /// @notice Deactivates the markets limits protection
    /// @dev Only callable by accounts with ATOMIST_ROLE
    /// @custom:access ATOMIST_ROLE restricted
    function deactivateMarketsLimits() public override restricted {
        AssetDistributionProtectionLib.deactivateMarketsLimits();
    }

    /// @notice Updates the callback handler configuration
    /// @param handler_ The callback handler address
    /// @param sender_ The sender address
    /// @param sig_ The function signature
    /// @dev Only callable by accounts with ATOMIST_ROLE
    /// @custom:access ATOMIST_ROLE restricted
    function updateCallbackHandler(address handler_, address sender_, bytes4 sig_) external override restricted {
        CallbackHandlerLib.updateCallbackHandler(handler_, sender_, sig_);
    }

    /// @notice Sets the total supply cap for the vault
    /// @param cap_ The new total supply cap
    /// @dev Only callable by accounts with ATOMIST_ROLE
    /// @custom:access ATOMIST_ROLE restricted
    function setTotalSupplyCap(uint256 cap_) external override restricted {
        PlasmaVaultLib.setTotalSupplyCap(cap_);
    }

    /// @notice Converts the vault to a public vault
    /// @dev Only callable by accounts with ATOMIST_ROLE
    /// @custom:access ATOMIST_ROLE restricted
    function convertToPublicVault() external override restricted {
        IIporFusionAccessManager(authority()).convertToPublicVault(address(this));
    }

    /// @notice Enables transfer of shares
    /// @dev Only callable by accounts with ATOMIST_ROLE
    /// @custom:access ATOMIST_ROLE restricted
    function enableTransferShares() external override restricted {
        IIporFusionAccessManager(authority()).enableTransferShares(address(this));
    }

    /// @notice Sets minimal execution delays for roles
    /// @param rolesIds_ Array of role IDs
    /// @param delays_ Array of corresponding delays
    /// @dev Only callable by accounts with OWNER_ROLE
    /// @custom:access OWNER_ROLE restricted
    function setMinimalExecutionDelaysForRoles(
        uint64[] calldata rolesIds_,
        uint256[] calldata delays_
    ) external override restricted {
        IIporFusionAccessManager(authority()).setMinimalExecutionDelaysForRoles(rolesIds_, delays_);
    }

    function _addFuse(address fuse_) internal {
        if (fuse_ == address(0)) {
            revert Errors.WrongAddress();
        }
        FusesLib.addFuse(fuse_);
    }

    /// @notice Internal helper to add a balance fuse
    /// @param marketId_ The ID of the market
    /// @param fuse_ The address of the fuse to add
    /// @dev Validates fuse address and adds it to the market
    /// @custom:access Internal
    function _addBalanceFuse(uint256 marketId_, address fuse_) internal {
        if (fuse_ == address(0)) {
            revert Errors.WrongAddress();
        }
        FusesLib.addBalanceFuse(marketId_, fuse_);
    }
}
