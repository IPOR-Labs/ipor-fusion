// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {AlphasLib} from "../libraries/AlphasLib.sol";
import {FusesLib} from "../libraries/FusesLib.sol";
import {AccessControlLib} from "../libraries/AccessControlLib.sol";
import {PlasmaVaultConfigLib} from "../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../libraries/PlasmaVaultLib.sol";
import {IIporPriceOracle} from "../priceOracle/IIporPriceOracle.sol";
import {Errors} from "../libraries/errors/Errors.sol";
import {PlasmaVaultStorageLib} from "../libraries/PlasmaVaultStorageLib.sol";

/// @title PlasmaVault contract, ERC4626 contract, decimals in underlying token decimals
abstract contract PlasmaVaultGovernance is Ownable2Step {
    modifier onlyPerformanceFeeManager() {
        if (msg.sender != PlasmaVaultLib.getPerformanceFeeData().feeManager) {
            revert SenderNotPerformanceFeeManager();
        }
        _;
    }

    modifier onlyManagementFeeManager() {
        if (msg.sender != PlasmaVaultLib.getManagementFeeData().feeManager) {
            revert SenderNotManagementFeeManager();
        }
        _;
    }

    error InvalidAlpha();
    error SenderNotPerformanceFeeManager();
    error SenderNotManagementFeeManager();

    /// @param initialOwner Address of the owner
    constructor(address initialOwner, address guardElectron) Ownable(initialOwner) {
        PlasmaVaultLib.setGuardElectronAddress(guardElectron);
    }

    function isAlphaGranted(address alpha) external view returns (bool) {
        return AlphasLib.isAlphaGranted(alpha);
    }

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

    function isAccessControlActivated() external view returns (bool) {
        return AccessControlLib.isControlAccessActivated();
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

    function grantAlpha(address alpha) external onlyOwner {
        if (alpha == address(0)) {
            revert Errors.WrongAddress();
        }
        _grantAlpha(alpha);
    }

    function revokeAlpha(address alpha) external onlyOwner {
        if (alpha == address(0)) {
            revert Errors.WrongAddress();
        }
        AlphasLib.revokeAlpha(alpha);
    }

    function addFuse(address fuse) external onlyOwner {
        _addFuse(fuse);
    }

    function removeFuse(address fuse) external onlyOwner {
        if (fuse == address(0)) {
            revert Errors.WrongAddress();
        }
        FusesLib.removeFuse(fuse);
    }

    function addBalanceFuse(uint256 marketId, address fuse) external onlyOwner {
        _addBalanceFuse(marketId, fuse);
    }

    function removeBalanceFuse(uint256 marketId, address fuse) external onlyOwner {
        FusesLib.removeBalanceFuse(marketId, fuse);
    }

    function grandMarketSubstrates(uint256 marketId, bytes32[] calldata substrates) external onlyOwner {
        PlasmaVaultConfigLib.grandMarketSubstrates(marketId, substrates);
    }

    /// @notice Configures the instant withdrawal fuses. Order of the fuse is important, as it will be used in the same order during the instant withdrawal process
    /// @dev Order of the fuses is important, the same fuse can be used multiple times with different parameters (for example different assets, markets or any other substrate specific for the fuse)
    function configureInstantWithdrawalFuses(
        PlasmaVaultLib.InstantWithdrawalFusesParamsStruct[] calldata fuses
    ) external onlyOwner {
        PlasmaVaultLib.configureInstantWithdrawalFuses(fuses);
    }

    function addFuses(address[] calldata fuses) external onlyOwner {
        for (uint256 i; i < fuses.length; ++i) {
            FusesLib.addFuse(fuses[i]);
        }
    }

    function removeFuses(address[] calldata fuses) external onlyOwner {
        for (uint256 i; i < fuses.length; ++i) {
            FusesLib.removeFuse(fuses[i]);
        }
    }

    function activateAccessControl() external onlyOwner {
        AccessControlLib.activateAccessControl();
    }

    function grantAccessToVault(address account) external onlyOwner {
        AccessControlLib.grantAccessToVault(account);
    }

    function revokeAccessToVault(address account) external onlyOwner {
        AccessControlLib.revokeAccessToVault(account);
    }

    function deactivateAccessControl() external onlyOwner {
        AccessControlLib.deactivateAccessControl();
    }

    function setPriceOracle(address priceOracle) external onlyOwner {
        IIporPriceOracle oldPriceOracle = IIporPriceOracle(PlasmaVaultLib.getPriceOracle());
        IIporPriceOracle newPriceOracle = IIporPriceOracle(priceOracle);
        if (
            oldPriceOracle.BASE_CURRENCY() != newPriceOracle.BASE_CURRENCY() ||
            oldPriceOracle.BASE_CURRENCY_DECIMALS() != newPriceOracle.BASE_CURRENCY_DECIMALS()
        ) {
            revert Errors.UnsupportedPriceOracle(Errors.PRICE_ORACLE_ERROR);
        }

        PlasmaVaultLib.setPriceOracle(priceOracle);
    }

    function configurePerformanceFee(address feeManager, uint256 feeInPercentage) external onlyPerformanceFeeManager {
        PlasmaVaultLib.configurePerformanceFee(feeManager, feeInPercentage);
    }

    function configureManagementFee(address feeManager, uint256 feeInPercentage) external onlyManagementFeeManager {
        PlasmaVaultLib.configureManagementFee(feeManager, feeInPercentage);
    }

    function getGuardElectronAddress() public view returns (address) {
        return PlasmaVaultLib.getGuardElectronAddress();
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

    function _grantAlpha(address alpha) internal {
        if (alpha == address(0)) {
            revert InvalidAlpha();
        }

        AlphasLib.grantAlpha(alpha);
    }
}
