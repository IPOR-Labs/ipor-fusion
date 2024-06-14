// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {FusesLib} from "../libraries/FusesLib.sol";
import {PlasmaVaultConfigLib} from "../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../libraries/PlasmaVaultLib.sol";
import {IPriceOracleMiddleware} from "../priceOracle/IPriceOracleMiddleware.sol";
import {Errors} from "../libraries/errors/Errors.sol";
import {PlasmaVaultStorageLib} from "../libraries/PlasmaVaultStorageLib.sol";
import {AccessManaged} from "../managers/AccessManaged.sol";

/// @title PlasmaVault contract, ERC4626 contract, decimals in underlying token decimals
abstract contract PlasmaVaultGovernance is AccessManaged {
    constructor(address accessManager_) AccessManaged(accessManager_) {}

    function isMarketSubstrateGranted(uint256 marketId, bytes32 substrate) external view returns (bool) {
        return PlasmaVaultConfigLib.isMarketSubstrateGranted(marketId, substrate);
    }

    function isFuseSupported(address fuse) external view returns (bool) {
        return FusesLib.isFuseSupported(fuse);
    }

    function isBalanceFuseSupported(uint256 marketId, address fuse) external view returns (bool) {
        return FusesLib.isBalanceFuseSupported(marketId, fuse);
    }

    function getFuses() external view returns (address[] memory) {
        return FusesLib.getFusesArray();
    }

    function getPriceOracle() external view returns (address) {
        return PlasmaVaultLib.getPriceOracle();
    }

    function getPerformanceFeeData() external view returns (PlasmaVaultStorageLib.PerformanceFeeData memory feeData) {
        feeData = PlasmaVaultLib.getPerformanceFeeData();
    }

    function getManagementFeeData() external view returns (PlasmaVaultStorageLib.ManagementFeeData memory feeData) {
        feeData = PlasmaVaultLib.getManagementFeeData();
    }

    function getAccessManagerAddress() public view returns (address) {
        return authority();
    }

    function getRewardsClaimManagerAddress() public view returns (address) {
        return PlasmaVaultLib.getRewardsClaimManagerAddress();
    }

    function addBalanceFuse(uint256 marketId, address fuse) external restricted {
        _addBalanceFuse(marketId, fuse);
    }

    function removeBalanceFuse(uint256 marketId, address fuse) external restricted {
        FusesLib.removeBalanceFuse(marketId, fuse);
    }

    function grandMarketSubstrates(uint256 marketId, bytes32[] calldata substrates) external restricted {
        PlasmaVaultConfigLib.grandMarketSubstrates(marketId, substrates);
    }

    /// @notice Configures the instant withdrawal fuses. Order of the fuse is important, as it will be used in the same order during the instant withdrawal process
    /// @dev Order of the fuses is important, the same fuse can be used multiple times with different parameters (for example different assets, markets or any other substrate specific for the fuse)
    function configureInstantWithdrawalFuses(
        PlasmaVaultLib.InstantWithdrawalFusesParamsStruct[] calldata fuses
    ) external restricted {
        PlasmaVaultLib.configureInstantWithdrawalFuses(fuses);
    }

    function addFuses(address[] calldata fuses) external restricted {
        for (uint256 i; i < fuses.length; ++i) {
            FusesLib.addFuse(fuses[i]);
        }
    }

    function removeFuses(address[] calldata fuses) external restricted {
        for (uint256 i; i < fuses.length; ++i) {
            FusesLib.removeFuse(fuses[i]);
        }
    }

    function setPriceOracle(address priceOracle) external restricted {
        IPriceOracleMiddleware oldPriceOracle = IPriceOracleMiddleware(PlasmaVaultLib.getPriceOracle());
        IPriceOracleMiddleware newPriceOracle = IPriceOracleMiddleware(priceOracle);
        if (
            oldPriceOracle.BASE_CURRENCY() != newPriceOracle.BASE_CURRENCY() ||
            oldPriceOracle.BASE_CURRENCY_DECIMALS() != newPriceOracle.BASE_CURRENCY_DECIMALS()
        ) {
            revert Errors.UnsupportedPriceOracle(Errors.PRICE_ORACLE_ERROR);
        }

        PlasmaVaultLib.setPriceOracle(priceOracle);
    }

    function configurePerformanceFee(address feeManager, uint256 feeInPercentage) external restricted {
        PlasmaVaultLib.configurePerformanceFee(feeManager, feeInPercentage);
    }

    function configureManagementFee(address feeManager, uint256 feeInPercentage) external restricted {
        PlasmaVaultLib.configureManagementFee(feeManager, feeInPercentage);
    }

    function setRewardsClaimManagerAddress(address rewardsClaimManagerAddress_) public restricted {
        PlasmaVaultLib.setRewardsClaimManagerAddress(rewardsClaimManagerAddress_);
    }

    function _addFuse(address fuse) internal {
        if (fuse == address(0)) {
            revert Errors.WrongAddress();
        }
        FusesLib.addFuse(fuse);
    }

    function _addBalanceFuse(uint256 marketId, address fuse) internal {
        if (fuse == address(0)) {
            revert Errors.WrongAddress();
        }
        FusesLib.addBalanceFuse(marketId, fuse);
    }
}
