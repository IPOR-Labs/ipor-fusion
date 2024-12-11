// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PlasmaVault, PlasmaVaultInitData, MarketBalanceFuseConfig, FeeConfig} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {FeeManagerFactory} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {MarketSubstratesConfig} from "../../contracts/vaults/PlasmaVault.sol";

struct DeployMinimalPlasmaVaultParams {
    address underlyingToken;
    string underlyingTokenName;
    address priceOracleMiddleware;
    address atomist;
}

/// @title PlasmaVaultHelper
/// @notice Helper library for testing PlasmaVault operations
/// @dev Contains utility functions to assist with PlasmaVault testing
library PlasmaVaultHelper {
    /// @notice Deploys a minimal PlasmaVault with basic configuration
    /// @param params Parameters for deployment
    /// @return plasmaVault Address of the deployed PlasmaVault
    function deployMinimalPlasmaVault(
        DeployMinimalPlasmaVaultParams memory params
    ) internal returns (PlasmaVault plasmaVault) {
        // Create fee configuration
        FeeConfig memory feeConfig = FeeConfig({
            iporDaoManagementFee: 0,
            iporDaoPerformanceFee: 0,
            atomistManagementFee: 0,
            atomistPerformanceFee: 0,
            feeFactory: address(new FeeManagerFactory()),
            feeRecipientAddress: address(0),
            iporDaoFeeRecipientAddress: address(0)
        });

        // Deploy access manager
        address accessManager = address(new IporFusionAccessManager(params.atomist, 0));

        // Create initialization data for PlasmaVault
        PlasmaVaultInitData memory initData = PlasmaVaultInitData({
            assetName: string(abi.encodePacked(params.underlyingTokenName, " Plasma Vault")),
            assetSymbol: string(abi.encodePacked(params.underlyingTokenName, "-PV")),
            underlyingToken: params.underlyingToken,
            priceOracleMiddleware: params.priceOracleMiddleware,
            marketSubstratesConfigs: new MarketSubstratesConfig[](0),
            fuses: new address[](0),
            balanceFuses: new MarketBalanceFuseConfig[](0),
            feeConfig: feeConfig,
            accessManager: accessManager,
            plasmaVaultBase: address(new PlasmaVaultBase()),
            totalSupplyCap: type(uint256).max,
            withdrawManager: address(0)
        });

        return new PlasmaVault(initData);
    }

    function accessManagerOf(PlasmaVault plasmaVault_) internal view returns (IporFusionAccessManager) {
        return IporFusionAccessManager(PlasmaVault(plasmaVault_).authority());
    }

    function priceOracleMiddlewareOf(PlasmaVault plasmaVault_) internal view returns (address) {
        return PlasmaVaultGovernance(address(plasmaVault_)).getPriceOracleMiddleware();
    }

    function addSubstratesToMarket(PlasmaVault plasmaVault_, uint256 marketId_, bytes32[] memory substrates_) internal {
        // Grant market substrates
        PlasmaVaultGovernance(address(plasmaVault_)).grantMarketSubstrates(marketId_, substrates_);
    }

    function addFusesToVault(PlasmaVault plasmaVault_, address[] memory fuses_) internal {
        PlasmaVaultGovernance(address(plasmaVault_)).addFuses(fuses_);
    }

    function addBalanceFusesToVault(PlasmaVault plasmaVault_, uint256 marketId_, address balanceFuse_) internal {
        PlasmaVaultGovernance(address(plasmaVault_)).addBalanceFuse(marketId_, balanceFuse_);
    }

    function addressOf(PlasmaVault plasmaVault_) internal view returns (address) {
        return address(plasmaVault_);
    }

    /// @notice Adds dependency balance graph for a single market
    /// @param plasmaVault_ The plasma vault instance
    /// @param marketId_ The market ID
    /// @param dependencies_ Array of dependencies for the market
    function addDependencyBalanceGraphs(
        PlasmaVault plasmaVault_,
        uint256 marketId_,
        uint256[] memory dependencies_
    ) internal {
        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = marketId_;

        uint256[][] memory allDependencies = new uint256[][](1);
        allDependencies[0] = dependencies_;

        PlasmaVaultGovernance(address(plasmaVault_)).updateDependencyBalanceGraphs(marketIds, allDependencies);
    }

    function addRewardsClaimManager(PlasmaVault plasmaVault_, address rewardsClaimManager_) internal {
        PlasmaVaultGovernance(address(plasmaVault_)).setRewardsClaimManagerAddress(rewardsClaimManager_);
    }
}
