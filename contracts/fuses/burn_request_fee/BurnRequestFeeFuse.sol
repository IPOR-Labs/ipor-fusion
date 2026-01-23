// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFuseCommon} from "../IFuse.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {PlasmaVaultStorageLib} from "../../libraries/PlasmaVaultStorageLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {IPlasmaVaultBase} from "../../interfaces/IPlasmaVaultBase.sol";

/**
 * @title BurnRequestFeeFuse - Fuse for Burning Request Fee Shares
 * @notice Specialized fuse contract for burning request fee shares from the PlasmaVault
 * @dev Routes burn operations through PlasmaVaultBase.updateInternal to ensure proper hook execution
 *
 * Execution Context:
 * - All fuse operations are executed via delegatecall from PlasmaVault
 * - Storage operations affect PlasmaVault's state, not the fuse contract
 * - msg.sender refers to the caller of PlasmaVault.execute
 * - address(this) refers to PlasmaVault's address during execution
 *
 * Inheritance Structure:
 * - IFuseCommon: Base fuse interface implementation
 *
 * Core Features:
 * - Burns request fee shares collected by WithdrawManager
 * - Routes through vault's _update pipeline for proper hook execution
 * - Maintains version and market tracking
 * - Implements fuse enter/exit pattern
 *
 * Share Burning System:
 * - Uses delegatecall to PlasmaVaultBase.updateInternal for burn operations
 * - Ensures voting checkpoints are updated via _transferVotingUnits
 * - Maintains governance state consistency
 * - Operates on WithdrawManager's collected fees
 * - Reduces total supply through burning
 * - Maintains protocol tokenomics
 *
 * Integration Points:
 * - PlasmaVault: Main vault interaction (via delegatecall)
 * - PlasmaVaultBase: Token state management (via nested delegatecall)
 * - WithdrawManager: Fee source
 * - Fuse System: Execution framework
 *
 * Security Considerations:
 * - Burns route through vault's _update pipeline to maintain voting checkpoints
 * - Access controlled operations
 * - State consistency checks
 * - Share burning validation
 * - Version tracking for upgrades
 * - Delegatecall security implications
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
contract BurnRequestFeeFuse is IFuseCommon {
    using Address for address;

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
    /// @dev Sets up the fuse with market ID
    /// @param marketId_ The market ID this fuse will operate on
    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Burns request fee shares from the WithdrawManager
    /// @dev Routes through PlasmaVaultBase.updateInternal via delegatecall to ensure proper hook execution
    ///
    /// Operation Flow:
    /// - Verifies WithdrawManager is set
    /// - Validates amount is non-zero
    /// - Burns shares via delegatecall to PlasmaVaultBase.updateInternal
    /// - Emits BurnRequestFeeEnter event
    ///
    /// Security:
    /// - Routes through vault's _update pipeline to maintain voting checkpoints
    /// - Checks WithdrawManager existence
    /// - Validates input parameters
    /// - Uses nested delegatecall to PlasmaVaultBase for proper hook execution
    ///
    /// @param data_ Struct containing the amount of shares to burn
    function enter(BurnRequestFeeDataEnter memory data_) public {
        address withdrawManager = PlasmaVaultStorageLib.getWithdrawManager().manager;

        if (withdrawManager == address(0)) {
            revert BurnRequestFeeWithdrawManagerNotSet();
        }

        if (data_.amount == 0) {
            return;
        }

        // Route burn through PlasmaVaultBase.updateInternal to ensure voting checkpoints
        // and supply cap validations are properly executed. Using delegatecall ensures
        // the vault's _update pipeline is used instead of bypassing it.
        PlasmaVaultStorageLib.getPlasmaVaultBase().functionDelegateCall(
            abi.encodeWithSelector(IPlasmaVaultBase.updateInternal.selector, withdrawManager, address(0), data_.amount)
        );

        emit BurnRequestFeeEnter(VERSION, data_.amount);
    }

    /// @notice Burns request fee shares using transient storage for input parameters
    /// @dev Reads inputs from transient storage and calls enter(). No outputs are written to transient storage.
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        BurnRequestFeeDataEnter memory data = BurnRequestFeeDataEnter({amount: TypeConversionLib.toUint256(inputs[0])});

        enter(data);
    }

    /// @notice Exit function (not implemented)
    /// @dev Always reverts as this fuse only supports burning
    function exit() external pure {
        revert BurnRequestFeeExitNotImplemented();
    }

    /// @notice Exit function using transient storage (not implemented)
    /// @dev Always reverts as this fuse only supports burning
    function exitTransient() external pure {
        revert BurnRequestFeeExitNotImplemented();
    }
}
