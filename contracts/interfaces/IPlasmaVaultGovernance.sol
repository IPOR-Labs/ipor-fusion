// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.22;

import {PlasmaVaultStorageLib} from "../libraries/PlasmaVaultStorageLib.sol";
import {InstantWithdrawalFusesParamsStruct} from "../libraries/PlasmaVaultLib.sol";
import {MarketLimit} from "../libraries/AssetDistributionProtectionLib.sol";

interface IPlasmaVaultGovernance {
    function isMarketSubstrateGranted(uint256 marketId_, bytes32 substrate_) external view returns (bool);
    function isFuseSupported(address fuse_) external view returns (bool);
    function isBalanceFuseSupported(uint256 marketId_, address fuse_) external view returns (bool);
    function isMarketsLimitsActivated() external view returns (bool);
    function getFuses() external view returns (address[] memory);
    function getPriceOracle() external view returns (address);
    function getPerformanceFeeData() external view returns (PlasmaVaultStorageLib.PerformanceFeeData memory feeData);
    function getManagementFeeData() external view returns (PlasmaVaultStorageLib.ManagementFeeData memory feeData);
    function getAccessManagerAddress() external view returns (address);
    function getRewardsClaimManagerAddress() external view returns (address);
    function getInstantWithdrawalFuses() external view returns (address[] memory);
    function getInstantWithdrawalFusesParams(address fuse_, uint256 index_) external view returns (bytes32[] memory);
    function getMarketLimit(uint256 marketId_) external view returns (uint256);
    function getDependencyBalanceGraph(uint256 marketId_) external view returns (uint256[] memory);
    function addBalanceFuse(uint256 marketId_, address fuse_) external;
    function removeBalanceFuse(uint256 marketId_, address fuse_) external;
    function grandMarketSubstrates(uint256 marketId_, bytes32[] calldata substrates_) external;
    function updateDependencyBalanceGraphs(uint256[] memory marketIds_, uint256[][] memory dependencies_) external;

    /// @notice Configures the instant withdrawal fuses. Order of the fuse is important, as it will be used in the same order during the instant withdrawal process
    /// @dev Order of the fuses is important, the same fuse can be used multiple times with different parameters (for example different assets, markets or any other substrate specific for the fuse)
    function configureInstantWithdrawalFuses(InstantWithdrawalFusesParamsStruct[] calldata fuses_) external;
    function addFuses(address[] calldata fuses_) external;
    function removeFuses(address[] calldata fuses_) external;
    function setPriceOracle(address priceOracle_) external;

    function configurePerformanceFee(address feeManager_, uint256 feeInPercentage_) external;

    function configureManagementFee(address feeManager_, uint256 feeInPercentage_) external;

    function setRewardsClaimManagerAddress(address rewardsClaimManagerAddress_) external;

    function setupMarketsLimits(MarketLimit[] calldata marketsLimits_) external;

    /// @notice Activates the markets limits protection, by default it is deactivated. After activation the limits
    /// is setup for each market separately.
    function activateMarketsLimits() external;

    /// @notice Deactivates the markets limits protection.
    function deactivateMarketsLimits() external;

    function updateCallbackHandler(address handler_, address sender_, bytes4 sig_) external;
}
