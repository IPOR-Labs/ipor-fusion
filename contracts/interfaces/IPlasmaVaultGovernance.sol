// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PlasmaVaultStorageLib} from "../libraries/PlasmaVaultStorageLib.sol";
import {InstantWithdrawalFusesParamsStruct} from "../libraries/PlasmaVaultLib.sol";
import {MarketLimit} from "../libraries/AssetDistributionProtectionLib.sol";

/// @title Plasma Vault Governance interface
interface IPlasmaVaultGovernance {
    /// @notice Checks if the market has granted the substrate
    /// @param marketId_ The marketId of the market
    /// @param substrate_ The substrate to check
    /// @return True if the market has granted the substrate
    function isMarketSubstrateGranted(uint256 marketId_, bytes32 substrate_) external view returns (bool);

    /// @notice Checks if fuse is supported
    /// @param fuse_ The address of the fuse
    /// @return True if the fuse is supported
    function isFuseSupported(address fuse_) external view returns (bool);

    /// @notice Checks if balance fuse is supported in a given market
    /// @param marketId_ The marketId of the market
    /// @param fuse_ The address of the fuse
    /// @return True if the balance fuse is supported
    function isBalanceFuseSupported(uint256 marketId_, address fuse_) external view returns (bool);

    /// @notice Checks if the markets limits protection is activated
    /// @return True if the markets limits protection is activated
    function isMarketsLimitsActivated() external view returns (bool);

    /// @notice Returns the array of market substrates granted in the market
    /// @param marketId_ The marketId of the market
    /// @return The array of substrates granted in the market
    /// @dev Substrates can be assets, vault, markets or any other parameter specific for the market and associated with market external protocol
    function getMarketSubstrates(uint256 marketId_) external view returns (bytes32[] memory);

    /// @notice Returns the array of fuses supported by the Plasma Vault
    /// @return The array of fuses
    function getFuses() external view returns (address[] memory);

    /// @notice Returns the address of the Price Oracle Middleware
    /// @return The address of the Price Oracle Middleware
    function getPriceOracleMiddleware() external view returns (address);

    /// @notice Returns the performance fee configuration data of the Plasma Vault
    /// @return feeData The performance fee configuration data, see PerformanceFeeData struct
    function getPerformanceFeeData() external view returns (PlasmaVaultStorageLib.PerformanceFeeData memory feeData);

    /// @notice Returns the management fee configuration data of the Plasma Vault
    /// @return feeData The management fee configuration data, see ManagementFeeData struct
    function getManagementFeeData() external view returns (PlasmaVaultStorageLib.ManagementFeeData memory feeData);

    /// @notice Returns the address of the Ipor Fusion Access Manager
    /// @return The address of the Ipor Fusion Access Manager
    function getAccessManagerAddress() external view returns (address);

    /// @notice Returns the address of the Rewards Claim Manager
    /// @return The address of the Rewards Claim Manager
    function getRewardsClaimManagerAddress() external view returns (address);

    /// @notice Returns the array of fuses used during the instant withdrawal process, order of the fuses is important
    /// @return The array of fuses, the order of the fuses is important
    function getInstantWithdrawalFuses() external view returns (address[] memory);

    /// @notice Returns the parameters used by the instant withdrawal fuses
    /// @param fuse_ The address of the fuse
    /// @param index_ The index of the fuse in the ordered array of fuses
    /// @return The array of parameters used by the fuse
    function getInstantWithdrawalFusesParams(address fuse_, uint256 index_) external view returns (bytes32[] memory);

    /// @notice Returns the market limit for the given market in percentage represented in 1e18
    /// @param marketId_ The marketId of the market
    /// @return The market limit in percentage represented in 1e18
    /// @dev This is percentage of the total balance in the Plasma Vault
    function getMarketLimit(uint256 marketId_) external view returns (uint256);

    /// @notice Gets the dependency balance graph for the given market, meaning the markets that are dependent on the given market and should be considered in the balance calculation
    /// @param marketId_ The marketId of the market
    /// @return Dependency balance graph is required because exists external protocols where interaction with the market can affect the balance of other markets
    function getDependencyBalanceGraph(uint256 marketId_) external view returns (uint256[] memory);

    /// @notice Returns the total supply cap
    /// @return The total supply cap, the values is represented in underlying decimals
    function getTotalSupplyCap() external view returns (uint256);

    /// @notice Adds the balance fuse to the market
    /// @param marketId_ The marketId of the market
    /// @param fuse_ The address of the balance fuse
    function addBalanceFuse(uint256 marketId_, address fuse_) external;

    /// @notice Removes the balance fuse from the market
    /// @param marketId_ The marketId of the market
    /// @param fuse_ The address of the balance fuse
    function removeBalanceFuse(uint256 marketId_, address fuse_) external;

    /// @notice Grants the substrates to the market
    /// @param marketId_ The marketId of the market
    /// @param substrates_ The substrates to grant
    /// @dev Substrates can be assets, vault, markets or any other parameter specific for the market and associated with market external protocol
    function grantMarketSubstrates(uint256 marketId_, bytes32[] calldata substrates_) external;

    /// @notice Updates the dependency balance graphs for the markets
    /// @param marketIds_ The array of marketIds
    /// @param dependencies_ dependency graph of markets
    function updateDependencyBalanceGraphs(uint256[] memory marketIds_, uint256[][] memory dependencies_) external;

    /// @notice Configures the instant withdrawal fuses. Order of the fuse is important, as it will be used in the same order during the instant withdrawal process
    /// @param fuses_ The array of InstantWithdrawalFusesParamsStruct to configure
    /// @dev Order of the fuses is important, the same fuse can be used multiple times with different parameters (for example different assets, markets or any other substrate specific for the fuse)
    function configureInstantWithdrawalFuses(InstantWithdrawalFusesParamsStruct[] calldata fuses_) external;

    /// @notice Adds the fuses supported by the Plasma Vault
    /// @param fuses_ The array of fuses to add
    function addFuses(address[] calldata fuses_) external;

    /// @notice Removes the fuses supported by the Plasma Vault
    /// @param fuses_ The array of fuses to remove
    function removeFuses(address[] calldata fuses_) external;

    /// @notice Sets the Price Oracle Middleware address
    /// @param priceOracleMiddleware_ The address of the Price Oracle Middleware
    function setPriceOracleMiddleware(address priceOracleMiddleware_) external;

    /// @notice Configures the performance fee
    /// @param feeAccount_ The address of the technical Performance Fee Account that will receive the performance fee collected by the Plasma Vault and later on distributed to IPOR DAO and recipients by FeeManager
    /// @param feeInPercentage_ The fee in percentage represented in 2 decimals, example 100% = 10000, 1% = 100, 0.01% = 1
    /// @dev feeAccount_ can be also EOA address or MultiSig address, in this case it will receive the performance fee directly
    function configurePerformanceFee(address feeAccount_, uint256 feeInPercentage_) external;

    /// @notice Configures the management fee
    /// @param feeAccount_ The address of the technical Management Fee Account that will receive the management fee collected by the Plasma Vault and later on distributed to IPOR DAO and recipients by FeeManager
    /// @param feeInPercentage_ The fee in percentage represented in 2 decimals, example 100% = 10000, 1% = 100, 0.01% = 1
    /// @dev feeAccount_ can be also EOA address or MultiSig address, in this case it will receive the management fee directly
    function configureManagementFee(address feeAccount_, uint256 feeInPercentage_) external;

    /// @notice Sets the Rewards Claim Manager address
    /// @param rewardsClaimManagerAddress_ The address of the Rewards Claim Manager
    function setRewardsClaimManagerAddress(address rewardsClaimManagerAddress_) external;

    /// @notice Sets the market limit for the given market in percentage represented in 18 decimals
    /// @param marketsLimits_ The array of MarketLimit to setup, see MarketLimit struct
    function setupMarketsLimits(MarketLimit[] calldata marketsLimits_) external;

    /// @notice Activates the markets limits protection, by default it is deactivated. After activation the limits is setup for each market separately.
    function activateMarketsLimits() external;

    /// @notice Deactivates the markets limits protection.
    function deactivateMarketsLimits() external;

    /// @notice Updates the callback handler
    /// @param handler_ The address of the handler
    /// @param sender_ The address of the sender
    /// @param sig_ The signature of the function
    function updateCallbackHandler(address handler_, address sender_, bytes4 sig_) external;

    /// @notice Sets the total supply cap
    /// @param cap_ The total supply cap, the values is represented in underlying decimals
    function setTotalSupplyCap(uint256 cap_) external;

    /// @notice Converts the specified vault to a public vault - mint and deposit functions are allowed for everyone.
    /// @dev Notice! Can convert to public but cannot convert back to private.
    function convertToPublicVault() external;

    /// @notice Enables transfer shares, transfer and transferFrom functions are allowed for everyone.
    function enableTransferShares() external;

    /// @notice Sets the minimal execution delay required for the specified roles.
    /// @param rolesIds_ The roles for which the minimal execution delay is set
    /// @param delays_ The minimal execution delays for the specified roles
    function setMinimalExecutionDelaysForRoles(uint64[] calldata rolesIds_, uint256[] calldata delays_) external;
}
