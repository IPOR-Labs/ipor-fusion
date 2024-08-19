// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Errors} from "./errors/Errors.sol";
import {PlasmaVaultStorageLib} from "./PlasmaVaultStorageLib.sol";

/// @notice Technical struct used to pass parameters in the `updateInstantWithdrawalFuses` function
struct InstantWithdrawalFusesParamsStruct {
    /// @notice The address of the fuse
    address fuse;
    /// @notice The parameters of the fuse, first element is an amount, second element is an address of the asset or a market id or other substrate specific for the fuse
    bytes32[] params;
}

library PlasmaVaultLib {
    using SafeCast for uint256;
    using SafeCast for int256;

    error InvalidPerformanceFee(uint256 feeInPercentage);

    event InstantWithdrawalFusesConfigured(InstantWithdrawalFusesParamsStruct[] fuses);
    event PriceOracleChanged(address newPriceOracle);
    event PerformanceFeeDataConfigured(address feeManager, uint256 feeInPercentage);
    event ManagementFeeDataConfigured(address feeManager, uint256 feeInPercentage);
    event RewardsClaimManagerAddressChanged(address newRewardsClaimManagerAddress);
    event DependencyBalanceGraphChanged(uint256 marketId, uint256[] newDependenceGraph);

    /// @notice Gets the total assets in the vault for all markets
    /// @return The total assets in the vault for all markets, represented in decimals of the underlying asset
    //solhint-disable-next-line
    function getTotalAssetsInAllMarkets() internal view returns (uint256) {
        return PlasmaVaultStorageLib.getTotalAssets().value;
    }

    /// @notice Gets the total assets in the vault for a specific market
    /// @param marketId_ The market id
    /// @return The total assets in the vault for the market, represented in decimals of the underlying asset
    //solhint-disable-next-line
    function getTotalAssetsInMarket(uint256 marketId_) internal view returns (uint256) {
        return PlasmaVaultStorageLib.getMarketTotalAssets().value[marketId_];
    }

    function getDependencyBalanceGraph(uint256 marketId_) internal view returns (uint256[] memory) {
        return PlasmaVaultStorageLib.getDependencyBalanceGraph().dependencyGraph[marketId_];
    }

    function updateDependencyBalanceGraph(uint256 marketId_, uint256[] memory newDependenceGraph_) internal {
        PlasmaVaultStorageLib.getDependencyBalanceGraph().dependencyGraph[marketId_] = newDependenceGraph_;
        emit DependencyBalanceGraphChanged(marketId_, newDependenceGraph_);
    }

    /// @notice Adds an amount to the total assets in the vault for all markets
    /// @param amount_ The amount to add, represented in decimals of the underlying asset
    function addToTotalAssetsInAllMarkets(int256 amount_) internal {
        if (amount_ < 0) {
            PlasmaVaultStorageLib.getTotalAssets().value -= (-amount_).toUint256();
        } else {
            PlasmaVaultStorageLib.getTotalAssets().value += amount_.toUint256();
        }
    }

    /// @notice Updates the total assets in the Plasma Vault for a specific market
    /// @param marketId_ The market id
    /// @param newTotalAssetsInUnderlying_ The new total assets in the vault for the market, represented in decimals of the underlying asset
    function updateTotalAssetsInMarket(
        uint256 marketId_,
        uint256 newTotalAssetsInUnderlying_
    ) internal returns (int256 deltaInUnderlying) {
        uint256 oldTotalAssetsInUnderlying = PlasmaVaultStorageLib.getMarketTotalAssets().value[marketId_];
        PlasmaVaultStorageLib.getMarketTotalAssets().value[marketId_] = newTotalAssetsInUnderlying_;
        deltaInUnderlying = newTotalAssetsInUnderlying_.toInt256() - oldTotalAssetsInUnderlying.toInt256();
    }

    /// @notice Gets the management fee data
    //solhint-disable-next-line
    function getManagementFeeData()
        internal
        view
        returns (PlasmaVaultStorageLib.ManagementFeeData memory managementFeeData)
    {
        return PlasmaVaultStorageLib.getManagementFeeData();
    }

    /// @notice Configures the management fee data like the fee manager and the fee in percentage
    /// @param feeManager_ The address of the fee manager responsible for managing the management fee
    /// @param feeInPercentage_ The fee in percentage, represented in 2 decimals, example: 100% = 10000, 1% = 100, 0.01% = 1
    function configureManagementFee(address feeManager_, uint256 feeInPercentage_) internal {
        if (feeManager_ == address(0)) {
            revert Errors.WrongAddress();
        }
        if (feeInPercentage_ > 10000) {
            revert InvalidPerformanceFee(feeInPercentage_);
        }

        PlasmaVaultStorageLib.ManagementFeeData storage managementFeeData = PlasmaVaultStorageLib
            .getManagementFeeData();

        managementFeeData.feeManager = feeManager_;
        managementFeeData.feeInPercentage = feeInPercentage_.toUint16();

        emit ManagementFeeDataConfigured(feeManager_, feeInPercentage_);
    }

    /// @notice Gets the performance fee data
    //solhint-disable-next-line
    function getPerformanceFeeData()
        internal
        view
        returns (PlasmaVaultStorageLib.PerformanceFeeData memory performanceFeeData)
    {
        return PlasmaVaultStorageLib.getPerformanceFeeData();
    }

    /// @notice Configures the performance fee data like the fee manager and the fee in percentage
    /// @param feeManager_ The address of the fee manager responsible for managing the performance fee
    /// @param feeInPercentage_ The fee in percentage, represented in 2 decimals, example: 100% = 10000, 1% = 100, 0.01% = 1
    function configurePerformanceFee(address feeManager_, uint256 feeInPercentage_) internal {
        if (feeManager_ == address(0)) {
            revert Errors.WrongAddress();
        }
        if (feeInPercentage_ > 10000) {
            revert InvalidPerformanceFee(feeInPercentage_);
        }

        PlasmaVaultStorageLib.PerformanceFeeData storage performanceFeeData = PlasmaVaultStorageLib
            .getPerformanceFeeData();

        performanceFeeData.feeManager = feeManager_;
        performanceFeeData.feeInPercentage = feeInPercentage_.toUint16();

        emit PerformanceFeeDataConfigured(feeManager_, feeInPercentage_);
    }

    /// @notice Updates the management fee data with the current timestamp
    /// @dev lastUpdateTimestamp is used to calculate unrealized management fees
    function updateManagementFeeData() internal {
        PlasmaVaultStorageLib.ManagementFeeData storage feeData = PlasmaVaultStorageLib.getManagementFeeData();
        feeData.lastUpdateTimestamp = block.timestamp.toUint32();
    }

    /// @notice Gets instant withdrawal fuses
    function getInstantWithdrawalFuses() internal view returns (address[] memory) {
        return PlasmaVaultStorageLib.getInstantWithdrawalFusesArray().value;
    }

    /// @notice Gets the instant withdrawal fuses parameters for a specific fuse
    /// @param fuse_ The fuse address
    /// @param index_ The index of the param in the fuse
    function getInstantWithdrawalFusesParams(address fuse_, uint256 index_) internal view returns (bytes32[] memory) {
        return
            PlasmaVaultStorageLib.getInstantWithdrawalFusesParams().value[keccak256(abi.encodePacked(fuse_, index_))];
    }

    /// @notice Configures the instant withdrawal fuses. Order of the fuse is important, as it will be used in the same order during the instant withdrawal process
    /// @param fuses_ The fuses to configure
    /// @dev Order of the fuses is important, the same fuse can be used multiple times with different parameters (for example different assets, markets or any other substrate specific for the fuse)
    function configureInstantWithdrawalFuses(InstantWithdrawalFusesParamsStruct[] calldata fuses_) internal {
        address[] memory fusesList = new address[](fuses_.length);

        PlasmaVaultStorageLib.InstantWithdrawalFusesParams storage instantWithdrawalFusesParams = PlasmaVaultStorageLib
            .getInstantWithdrawalFusesParams();

        bytes32 key;

        for (uint256 i; i < fuses_.length; ++i) {
            fusesList[i] = fuses_[i].fuse;
            key = keccak256(abi.encodePacked(fuses_[i].fuse, i));

            delete instantWithdrawalFusesParams.value[key];

            for (uint256 j; j < fuses_[i].params.length; ++j) {
                instantWithdrawalFusesParams.value[key].push(fuses_[i].params[j]);
            }
        }

        delete PlasmaVaultStorageLib.getInstantWithdrawalFusesArray().value;

        PlasmaVaultStorageLib.getInstantWithdrawalFusesArray().value = fusesList;

        emit InstantWithdrawalFusesConfigured(fuses_);
    }

    /// @notice Gets the price oracle address
    function getPriceOracle() internal view returns (address) {
        return PlasmaVaultStorageLib.getPriceOracle().value;
    }

    /// @notice Sets the price oracle address
    /// @param priceOracle_ The price oracle address
    function setPriceOracle(address priceOracle_) internal {
        PlasmaVaultStorageLib.getPriceOracle().value = priceOracle_;
        emit PriceOracleChanged(priceOracle_);
    }

    /// @notice Gets the rewards claim manager address
    function getRewardsClaimManagerAddress() internal view returns (address) {
        return PlasmaVaultStorageLib.getRewardsClaimManagerAddress().value;
    }

    /// @notice Sets the rewards claim manager address
    /// @param rewardsClaimManagerAddress_ The rewards claim manager address
    function setRewardsClaimManagerAddress(address rewardsClaimManagerAddress_) internal {
        PlasmaVaultStorageLib.getRewardsClaimManagerAddress().value = rewardsClaimManagerAddress_;
        emit RewardsClaimManagerAddressChanged(rewardsClaimManagerAddress_);
    }

    function executeStarted() internal {
        PlasmaVaultStorageLib.getExecutionState().value = 1;
    }

    function executeFinished() internal {
        PlasmaVaultStorageLib.getExecutionState().value = 0;
    }

    function isExecutionStarted() internal view returns (bool) {
        return PlasmaVaultStorageLib.getExecutionState().value == 1;
    }

    function getPlasmaVaultBaseAddress() internal view returns (address) {
        return PlasmaVaultStorageLib.getPlasmaVaultBaseAddress().value;
    }
}
