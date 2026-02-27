// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {WrappedPlasmaVaultBase} from "./WrappedPlasmaVaultBase.sol";
import {WhitelistAccessControl} from "./WhitelistAccessControl.sol";

contract WhitelistWrappedPlasmaVault is WrappedPlasmaVaultBase, WhitelistAccessControl {
    /**
     * @notice Initializes the Wrapped Plasma Vault with the underlying asset and vault configuration
     * @dev This constructor is marked as initializer for proxy deployment pattern
     * @param name_ Name of the vault token
     * @param symbol_ Symbol of the vault token
     * @param plasmaVault_ Address of the underlying Plasma Vault that this wrapper will interact with
     * @param initialAdmin_ Address of the initial admin of the whitelist access control
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor(
        string memory name_,
        string memory symbol_,
        address plasmaVault_,
        address initialAdmin_,
        address managementFeeAccount_,
        uint256 managementFeePercentage_,
        address performanceFeeAccount_,
        uint256 performanceFeePercentage_
    )
        WrappedPlasmaVaultBase(
            name_,
            symbol_,
            plasmaVault_,
            managementFeeAccount_,
            managementFeePercentage_,
            performanceFeeAccount_,
            performanceFeePercentage_
        )
        WhitelistAccessControl(initialAdmin_)
    {}
    /**
     * @notice Configures the management fee parameters for the vault
     * @dev Updates management fee recipient and percentage through PlasmaVaultLib
     *
     * Configuration Flow:
     * 1. Parameter Validation
     *    - Validates fee account address
     *    - Verifies fee percentage within limits
     *    - Ensures configuration consistency
     *
     * 2. State Updates
     *    - Updates fee recipient address
     *    - Sets new fee percentage
     *    - Persists configuration in storage
     *
     * 3. Fee System Impact
     *    - Affects future fee calculations
     *    - Influences share price computations
     *    - Updates fee accrual parameters
     *
     * Security Features:
     * - Owner-only access control
     * - Parameter validation
     * - State consistency checks
     * - Safe fee calculations
     *
     * @param feeAccount_ Address to receive the management fees
     * @param feeInPercentage_ Management fee percentage with 2 decimal places (10000 = 100%)
     * @custom:security Restricted to contract owner
     */
    function configureManagementFee(
        address feeAccount_,
        uint256 feeInPercentage_
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        PlasmaVaultLib.configureManagementFee(feeAccount_, feeInPercentage_);
    }

    /**
     * @notice Configures the performance fee parameters for the vault
     * @dev Updates performance fee recipient and percentage through PlasmaVaultLib
     *
     * Configuration Flow:
     * 1. Parameter Validation
     *    - Validates fee account address
     *    - Verifies fee percentage within limits
     *    - Ensures configuration consistency
     *
     * 2. State Updates
     *    - Updates fee recipient address
     *    - Sets new fee percentage
     *    - Persists configuration in storage
     *
     * 3. Fee System Impact
     *    - Affects profit-based fee calculations
     *    - Influences performance tracking
     *    - Updates fee distribution parameters
     *    - Applies to future value increases
     *
     * Security Features:
     * - Owner-only access control
     * - Parameter validation
     * - State consistency checks
     * - Safe fee calculations
     *
     * @param feeAccount_ Address to receive the performance fees
     * @param feeInPercentage_ Performance fee percentage with 2 decimal places (10000 = 100%)
     * @custom:security Restricted to contract owner
     */
    function configurePerformanceFee(
        address feeAccount_,
        uint256 feeInPercentage_
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        PlasmaVaultLib.configurePerformanceFee(feeAccount_, feeInPercentage_);
    }

    function deposit(uint256 assets_, address receiver_) public override onlyRole(WHITELISTED) returns (uint256) {
        return super.deposit(assets_, receiver_);
    }

    function mint(uint256 shares_, address receiver_) public override onlyRole(WHITELISTED) returns (uint256) {
        return super.mint(shares_, receiver_);
    }

    function withdraw(
        uint256 shares_,
        address receiver_,
        address owner_
    ) public override onlyRole(WHITELISTED) returns (uint256) {
        return super.withdraw(shares_, receiver_, owner_);
    }

    function redeem(
        uint256 shares_,
        address receiver_,
        address owner_
    ) public override onlyRole(WHITELISTED) returns (uint256) {
        return super.redeem(shares_, receiver_, owner_);
    }
}
