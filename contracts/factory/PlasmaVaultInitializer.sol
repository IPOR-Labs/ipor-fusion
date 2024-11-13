// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PlasmaVaultDeployData, FeeConfig} from "./PlasmaVaultTypes.sol";
import {InitializationData, DataForInitialization, PlasmaVaultAddress} from "../managers/access/IporFusionAccessManagerInitializationLib.sol";
import {IporFusionAccessManagerInitializerLibV1} from "../vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {InstantWithdrawalFusesParamsStruct} from "../libraries/PlasmaVaultLib.sol";
import {IPlasmaVaultGovernance} from "../interfaces/IPlasmaVaultGovernance.sol";
import {IRewardsClaimManager} from "../interfaces/IRewardsClaimManager.sol";
import {IAccessManager} from "../managers/access/interfaces/IAccessManager.sol";
import {IPlasmaVault} from "../interfaces/IPlasmaVault.sol";
import {IWithdrawManager} from "../managers/withdraw/interfaces/IWithdrawManager.sol";
import {IRewardsManager} from "../managers/rewards/interfaces/IRewardsManager.sol";
import {IFeeManager} from "../managers/fee/interfaces/IFeeManager.sol";
import {PlasmaVaultStorageLib} from "../libraries/PlasmaVaultStorageLib.sol";

contract PlasmaVaultInitializer {
    error InitializationFailed();
    error ZeroAddress();

    struct DeployedAddresses {
        address vault;
        address accessManager;
        address rewardsManager;
        address feeManager;
        address withdrawManager;
    }

    struct ExtendedInitData {
        // Basic initialization data
        PlasmaVaultDeployData vaultData;
        DataForInitialization accessData;
        // Additional configurations
        InstantWithdrawalFusesParamsStruct[] instantWithdrawalFuses;
        address[] rewardFuses;
        uint256[][] marketDependencies;
        uint256[] marketIds;
        uint256 vestingTime;
        address[] callbackHandlers;
    }

    function initialize(
        DeployedAddresses calldata addresses,
        ExtendedInitData calldata extData
    ) external {
        _validateAddresses(addresses);

        // Initialize WithdrawManager if deployed
        if (addresses.withdrawManager != address(0)) {
            _initializeWithdrawManager(addresses.withdrawManager, addresses.accessManager);
        }
        // Initialize remaining managers
        _initializeRewardsManager(addresses.rewardsManager, addresses.accessManager);
        _initializeFeeManager(addresses.feeManager, extData.vaultData.feeConfig, addresses);
        
        // Initialize PlasmaVault with basic configuration
        _initializePlasmaVault(addresses.vault, extData.vaultData, addresses);

        // Configure additional features
        _configureInstantWithdrawalFuses(addresses.vault, extData.instantWithdrawalFuses);
        _configureRewardsFuses(addresses.rewardsManager, extData.rewardFuses);
        _configureMarketDependencies(addresses.vault, extData.marketIds, extData.marketDependencies);
        _configureVestingTime(addresses.rewardsManager, extData.vestingTime);
        _configureCallbackHandlers(addresses.vault, extData.callbackHandlers);

        
        // Generate initialization data using the library
        InitializationData memory initData = IporFusionAccessManagerInitializerLibV1.generateInitializeIporPlasmaVault(
            extData.accessData
        );

        // Initialize AccessManager last to avoid permission issues
        _initializeAccessManager(addresses.accessManager, initData);
    }

    function _validateAddresses(DeployedAddresses calldata addresses) internal pure {
        if (addresses.vault == address(0)) revert ZeroAddress();
        if (addresses.accessManager == address(0)) revert ZeroAddress();
        // Optional addresses are not validated (rewardsManager, feeManager, withdrawManager)
    }

    function _initializeAccessManager(address manager, InitializationData memory data) internal {
        try IAccessManager(manager).initialize(data) {
            // Success
        } catch {
            revert InitializationFailed();
        }
    }

    function _initializeWithdrawManager(address manager, address accessManager) internal {
        try IWithdrawManager(manager).initialize(accessManager) {
            // Success
        } catch {
            revert InitializationFailed();
        }
    }

    function _initializePlasmaVault(
        address vault,
        PlasmaVaultDeployData calldata data,
        DeployedAddresses calldata addresses
    ) internal {
        try IPlasmaVault(vault).initialize(
            IPlasmaVault.PlasmaVaultInitData({
                assetName: data.assetName,
                assetSymbol: data.assetSymbol,
                underlyingToken: data.underlyingToken,
                priceOracleMiddleware: data.priceOracleMiddleware,
                marketSubstratesConfigs: data.marketSubstratesConfigs,
                fuses: data.fuses,
                balanceFuses: data.balanceFuses,
                feeConfig: data.feeConfig,
                accessManager: addresses.accessManager,
                plasmaVaultBase: data.plasmaVaultBase,
                totalSupplyCap: data.totalSupplyCap,
                withdrawManager: addresses.withdrawManager
            })
        ) {
            // Success
        } catch {
            revert InitializationFailed();
        }
    }

    function _initializeRewardsManager(address manager, address accessManager) internal {
        if (manager == address(0)) return;
        
        try IRewardsManager(manager).initialize(accessManager) {
            // Success
        } catch {
            revert InitializationFailed();
        }
    }

    function _initializeFeeManager(
        address manager,
        FeeConfig calldata config,
        DeployedAddresses calldata addresses
    ) internal {
        if (manager == address(0)) return;

        try IFeeManager(manager).initialize(
            addresses.accessManager,
            addresses.vault,
            config
        ) {
            // Success
        } catch {
            revert InitializationFailed();
        }
    }

    function _configureInstantWithdrawalFuses(
        address vault,
        InstantWithdrawalFusesParamsStruct[] calldata fuses
    ) internal {
        if (fuses.length == 0) return;
        
        try IPlasmaVaultGovernance(vault).configureInstantWithdrawalFuses(fuses) {
            // Success
        } catch {
            revert InitializationFailed();
        }
    }

    function _configureRewardsFuses(address rewardsManager, address[] calldata fuses) internal {
        if (rewardsManager == address(0) || fuses.length == 0) return;

        try IRewardsClaimManager(rewardsManager).addRewardFuses(fuses) {
            // Success
        } catch {
            revert InitializationFailed();
        }
    }

    function _configureMarketDependencies(
        address vault,
        uint256[] calldata marketIds,
        uint256[][] calldata dependencies
    ) internal {
        if (marketIds.length == 0) return;

        try IPlasmaVaultGovernance(vault).updateDependencyBalanceGraphs(marketIds, dependencies) {
            // Success
        } catch {
            revert InitializationFailed();
        }
    }

    function _configureVestingTime(address rewardsManager, uint256 vestingTime) internal {
        if (rewardsManager == address(0) || vestingTime == 0) return;

        try IRewardsClaimManager(rewardsManager).setupVestingTime(vestingTime) {
            // Success
        } catch {
            revert InitializationFailed();
        }
    }

    function _configureCallbackHandlers(address vault, address[] calldata handlers) internal {
        if (handlers.length == 0) return;

        try IPlasmaVaultGovernance(vault).setCallbackHandlers(handlers) {
            // Success
        } catch {
            revert InitializationFailed();
        }
    }
}