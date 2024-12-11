// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IEVC} from "ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {EulerFuseLib} from "./EulerFuseLib.sol";

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
contract EulerV2SupplyFuse is IFuseCommon {
    using SafeERC20 for ERC20;

    event EulerV2SupplyEnterFuse(address version, address eulerVault, uint256 supplyAmount, address subAccount);
    event EulerV2SupplyExitFuse(address version, address eulerVault, uint256 withdrawnAmount, address subAccount);

    error EulerV2SupplyFuseUnsupportedEnterAction(address vault, bytes1 subAccount);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    IEVC public immutable EVC;

    constructor(uint256 marketId_, address eulerV2EVC_) {
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
        emit EulerV2SupplyEnterFuse(VERSION, data_.eulerVault, depositedAmount, subAccount);
    }

    /// @notice Exits the Euler V2 Supply Fuse with the specified parameters
    /// @param data_ The data structure containing the parameters for exiting the Euler V2 Supply Fuse
    function exit(EulerV2SupplyFuseExitData memory data_) external {
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

        /* solhint-disable avoid-low-level-calls */
        EVC.call(
            data_.eulerVault,
            subAccount,
            0,
            abi.encodeWithSelector(ERC4626Upgradeable.withdraw.selector, finalVaultAssetAmount, plasmaVault, subAccount)
        );
        /* solhint-enable avoid-low-level-calls */

        emit EulerV2SupplyExitFuse(VERSION, data_.eulerVault, finalVaultAssetAmount, subAccount);
    }
}
