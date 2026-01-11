// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {IEVC} from "ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IFuseInstantWithdraw} from "../IFuseInstantWithdraw.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {EulerFuseLib} from "./EulerFuseLib.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

/// @notice Data structure for entering the Euler V2 Supply Fuse
/// @param eulerVault The address of the Euler vault
/// @param maxAmount The maximum amount to supply
/// @param subAccount The sub-account identifier
struct EulerV2SupplyFuseEnterData {
    address eulerVault;
    uint256 maxAmount;
    bytes1 subAccount;
}

/// @notice Data structure for exiting the Euler V2 Supply Fuse
/// @param eulerVault The address of the Euler vault
/// @param maxAmount The maximum amount to withdraw
/// @param subAccount The sub-account identifier
struct EulerV2SupplyFuseExitData {
    address eulerVault;
    uint256 maxAmount;
    bytes1 subAccount;
}

/// @title Fuse Euler V2 Supply responsible for depositing and withdrawing assets from Euler V2 vaults
/// @dev Substrates in this fuse are the EVaults that are used in Euler V2 for a given MARKET_ID
contract EulerV2SupplyFuse is IFuseCommon, IFuseInstantWithdraw {
    using SafeERC20 for ERC20;

    event EulerV2SupplyEnterFuse(address version, address eulerVault, uint256 supplyAmount, address subAccount);
    event EulerV2SupplyExitFuse(address version, address eulerVault, uint256 withdrawnAmount, address subAccount);

    /// @notice Emitted when exit operation fails during instant withdraw
    event EulerV2SupplyFuseExitFailed(
        address version,
        address eulerVault,
        uint256 amount,
        address subAccount
    );

    error EulerV2SupplyFuseUnsupportedEnterAction(address vault, bytes1 subAccount);
    error EulerV2SupplyFuseUnsupportedVault(address vault, bytes1 subAccount);
    error EulerV2SupplyFuseWrongAddress();
    error EulerV2SupplyFuseWrongValue();
    error EulerV2SupplyFuseInvalidParams();

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    IEVC public immutable EVC;

    constructor(uint256 marketId_, address eulerV2EVC_) {
        if (marketId_ == 0) {
            revert EulerV2SupplyFuseWrongValue();
        }
        if (eulerV2EVC_ == address(0)) {
            revert EulerV2SupplyFuseWrongAddress();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
        EVC = IEVC(eulerV2EVC_);
    }

    /// @notice Enters the Euler V2 Supply Fuse with the specified parameters
    /// @param data_ The data structure containing the parameters for entering the Euler V2 Supply Fuse
    function enter(EulerV2SupplyFuseEnterData memory data_) external {
        if (data_.maxAmount == 0) {
            return;
        }
        if (!EulerFuseLib.canSupply(MARKET_ID, data_.eulerVault, data_.subAccount)) {
            revert EulerV2SupplyFuseUnsupportedEnterAction(data_.eulerVault, data_.subAccount);
        }

        address eulerVaultAsset = ERC4626Upgradeable(data_.eulerVault).asset();
        uint256 transferAmount = IporMath.min(data_.maxAmount, ERC20(eulerVaultAsset).balanceOf(address(this)));
        address plasmaVault = address(this);

        if (transferAmount == 0) {
            return;
        }

        address subAccount = EulerFuseLib.generateSubAccountAddress(plasmaVault, data_.subAccount);

        ERC20(eulerVaultAsset).forceApprove(data_.eulerVault, transferAmount);

        /* solhint-disable avoid-low-level-calls */
        uint256 depositedAmount = abi.decode(
            EVC.call(
                data_.eulerVault,
                plasmaVault,
                0,
                abi.encodeWithSelector(ERC4626Upgradeable.deposit.selector, transferAmount, subAccount)
            ),
            (uint256)
        );
        /* solhint-enable avoid-low-level-calls */

        ERC20(eulerVaultAsset).forceApprove(data_.eulerVault, 0);

        emit EulerV2SupplyEnterFuse(VERSION, data_.eulerVault, depositedAmount, subAccount);
    }

    /// @notice Exits the Euler V2 Supply Fuse with the specified parameters
    /// @param data_ The data structure containing the parameters for exiting the Euler V2 Supply Fuse
    function exit(EulerV2SupplyFuseExitData memory data_) external {
        _exit(data_, false);
    }

    /// @notice Instant withdraw assets from Euler V2 vault
    /// @param params_ Array of parameters:
    ///        params_[0] - amount in underlying asset (uint256)
    ///        params_[1] - euler vault address (address encoded as bytes32)
    ///        params_[2] - subAccount identifier (bytes1 encoded as bytes32)
    /// @dev Only allowed when substrate has isCollateral == false AND canBorrow == false
    function instantWithdraw(bytes32[] calldata params_) external override {
        if (params_.length < 3) {
            revert EulerV2SupplyFuseInvalidParams();
        }

        uint256 amount = uint256(params_[0]);
        address eulerVault = PlasmaVaultConfigLib.bytes32ToAddress(params_[1]);
        bytes1 subAccount = bytes1(params_[2]);

        _exit(EulerV2SupplyFuseExitData(eulerVault, amount, subAccount), true);
    }

    /// @notice Internal exit function with optional exception handling
    /// @param data_ Exit data structure
    /// @param catchExceptions_ If true, validates instant withdraw eligibility and catches exceptions
    function _exit(EulerV2SupplyFuseExitData memory data_, bool catchExceptions_) internal {
        // Validate canInstantWithdraw if catchExceptions_ is true
        if (catchExceptions_) {
            if (!EulerFuseLib.canInstantWithdraw(MARKET_ID, data_.eulerVault, data_.subAccount)) {
                revert EulerV2SupplyFuseUnsupportedVault(data_.eulerVault, data_.subAccount);
            }
        }

        if (data_.maxAmount == 0) {
            return;
        }

        address plasmaVault = address(this);
        address subAccount = EulerFuseLib.generateSubAccountAddress(plasmaVault, data_.subAccount);

        uint256 finalVaultAssetAmount = IporMath.min(
            data_.maxAmount,
            ERC4626Upgradeable(data_.eulerVault).convertToAssets(
                ERC4626Upgradeable(data_.eulerVault).balanceOf(subAccount)
            )
        );

        if (finalVaultAssetAmount == 0) {
            return;
        }

        _performWithdraw(data_.eulerVault, finalVaultAssetAmount, plasmaVault, subAccount, catchExceptions_);
    }

    /// @notice Performs the actual withdraw operation with optional exception handling
    /// @param eulerVault_ The Euler vault address
    /// @param amount_ The amount to withdraw
    /// @param plasmaVault_ The PlasmaVault address
    /// @param subAccount_ The sub-account address
    /// @param catchExceptions_ If true, catches exceptions and emits failure event
    function _performWithdraw(
        address eulerVault_,
        uint256 amount_,
        address plasmaVault_,
        address subAccount_,
        bool catchExceptions_
    ) private {
        bytes memory withdrawCall = abi.encodeWithSelector(
            ERC4626Upgradeable.withdraw.selector,
            amount_,
            plasmaVault_,
            subAccount_
        );

        if (catchExceptions_) {
            /* solhint-disable avoid-low-level-calls */
            try EVC.call(eulerVault_, subAccount_, 0, withdrawCall) {
                emit EulerV2SupplyExitFuse(VERSION, eulerVault_, amount_, subAccount_);
            } catch {
                emit EulerV2SupplyFuseExitFailed(VERSION, eulerVault_, amount_, subAccount_);
            }
            /* solhint-enable avoid-low-level-calls */
        } else {
            /* solhint-disable avoid-low-level-calls */
            EVC.call(eulerVault_, subAccount_, 0, withdrawCall);
            /* solhint-enable avoid-low-level-calls */
            emit EulerV2SupplyExitFuse(VERSION, eulerVault_, amount_, subAccount_);
        }
    }
}
