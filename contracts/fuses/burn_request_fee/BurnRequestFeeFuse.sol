// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IFuseCommon} from "../IFuse.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {PlasmaVaultStorageLib} from "../../libraries/PlasmaVaultStorageLib.sol";

/**
 * @title BurnRequestFeeFuse - Fuse for Burning Request Fee Shares
 * @notice Specialized fuse contract for burning request fee shares from the PlasmaVault
 * @dev Inherits from ERC20Upgradeable to interact with PlasmaVault's share token functionality
 *
 * Execution Context:
 * - All fuse operations are executed via delegatecall from PlasmaVault
 * - Storage operations affect PlasmaVault's state, not the fuse contract
 * - msg.sender refers to the caller of PlasmaVault.execute
 * - address(this) refers to PlasmaVault's address during execution
 * - ERC20 operations modify PlasmaVault's token balances
 *
 * Inheritance Structure:
 * - ERC20Upgradeable: Used to interact with PlasmaVault's share token system
 * - IFuseCommon: Base fuse interface implementation
 *
 * Core Features:
 * - Burns request fee shares collected by WithdrawManager
 * - Manages share token state through ERC20 operations
 * - Maintains version and market tracking
 * - Implements fuse enter/exit pattern
 *
 * Share Burning System:
 * - Utilizes ERC20Upgradeable._burn for share destruction
 * - Operates on WithdrawManager's collected fees
 * - Reduces total supply through burning
 * - Maintains protocol tokenomics
 *
 * Integration Points:
 * - PlasmaVault: Main vault interaction (via delegatecall)
 * - WithdrawManager: Fee source
 * - ERC20 Share Token: State management
 * - Fuse System: Execution framework
 *
 * Security Considerations:
 * - Access controlled operations
 * - State consistency checks
 * - Share burning validation
 * - Version tracking for upgrades
 * - Delegatecall security implications
 * - Storage layout compatibility
 *
 */

/// @notice Data structure for the enter function parameters
/// @dev Used to pass burning amount to the enter function
struct BurnRequestFeeDataEnter {
    /// @notice Amount of shares to burn
    uint256 amount;
}

/// @title BurnRequestFeeFuse
/// @notice Contract responsible for burning request fee shares from PlasmaVault
contract BurnRequestFeeFuse is IFuseCommon, ERC20Upgradeable {
    /// @notice Thrown when WithdrawManager address is not set in PlasmaVault
    error BurnRequestFeeWithdrawManagerNotSet();

    /// @notice Thrown when exit function is called (not implemented)
    error BurnRequestFeeExitNotImplemented();

    /// @notice Emitted when request fee shares are burned
    /// @param version Address of the fuse contract version
    /// @param amount Amount of shares burned
    event BurnRequestFeeEnter(address version, uint256 amount);

    /// @notice Address of this fuse contract version
    /// @dev Immutable value set in constructor
    address public immutable VERSION;

    /// @notice Market ID this fuse operates on
    /// @dev Immutable value set in constructor
    uint256 public immutable MARKET_ID;

    /// @notice Initializes the BurnRequestFeeFuse contract
    /// @dev Sets up the fuse with market ID and initializes ERC20 metadata
    /// @param marketId_ The market ID this fuse will operate on
    constructor(uint256 marketId_) initializer {
        VERSION = address(this);
        MARKET_ID = marketId_;
        __ERC20_init("Burn Request Fee - Fuse", "BRF");
    }

    /// @notice Burns request fee shares from the WithdrawManager
    /// @dev Executes the share burning operation using ERC20Upgradeable._burn
    ///
    /// Operation Flow:
    /// - Verifies WithdrawManager is set
    /// - Validates amount is non-zero
    /// - Burns shares using ERC20 functionality
    /// - Emits BurnRequestFeeEnter event
    ///
    /// Security:
    /// - Checks WithdrawManager existence
    /// - Validates input parameters
    /// - Uses safe burning mechanism
    ///
    /// @param data_ Struct containing the amount of shares to burn
    function enter(BurnRequestFeeDataEnter memory data_) external {
        address withdrawManager = PlasmaVaultStorageLib.getWithdrawManager().manager;

        if (withdrawManager == address(0)) {
            revert BurnRequestFeeWithdrawManagerNotSet();
        }

        if (data_.amount == 0) {
            return;
        }

        _burn(withdrawManager, data_.amount);

        emit BurnRequestFeeEnter(VERSION, data_.amount);
    }

    /// @notice Exit function (not implemented)
    /// @dev Always reverts as this fuse only supports burning
    function exit() external pure {
        revert BurnRequestFeeExitNotImplemented();
    }
}
