// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IEVC} from "ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {EulerFuseLib} from "./EulerFuseLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";

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

    /// @notice Emitted when assets are successfully deposited into an Euler V2 vault
    /// @param version The address of this fuse contract version
    /// @param eulerVault The address of the Euler V2 vault receiving the deposit
    /// @param sharesMinted The number of vault shares minted from the deposit (per ERC-4626)
    /// @param subAccount The sub-account address used for the deposit
    event EulerV2SupplyEnterFuse(address version, address eulerVault, uint256 sharesMinted, address subAccount);

    /// @notice Emitted when assets are successfully withdrawn from an Euler V2 vault
    /// @param version The address of this fuse contract version
    /// @param eulerVault The address of the Euler V2 vault from which assets are withdrawn
    /// @param withdrawnAmount The amount of assets withdrawn from the vault
    /// @param subAccount The sub-account address used for the withdrawal
    event EulerV2SupplyExitFuse(address version, address eulerVault, uint256 withdrawnAmount, address subAccount);

    /// @notice Thrown when attempting to supply to an unsupported Euler V2 vault or sub-account combination
    /// @param vault The address of the vault that is not supported
    /// @param subAccount The sub-account identifier that is not supported
    /// @custom:error EulerV2SupplyFuseUnsupportedEnterAction
    error EulerV2SupplyFuseUnsupportedEnterAction(address vault, bytes1 subAccount);

    /// @notice Address of this fuse contract version
    /// @dev Immutable value set in constructor, used for tracking and versioning
    address public immutable VERSION;

    /// @notice Market ID this fuse operates on
    /// @dev Immutable value set in constructor, used to retrieve market substrates (Euler V2 vault addresses)
    uint256 public immutable MARKET_ID;

    /// @notice Ethereum Vault Connector (EVC) address for Euler V2 protocol
    /// @dev Immutable value set in constructor, used for Euler V2 protocol interactions through EVC
    IEVC public immutable EVC;

    /**
     * @notice Initializes the EulerV2SupplyFuse with a market ID and EVC address
     * @param marketId_ The market ID used to identify the Euler V2 vault substrates
     * @param eulerV2EVC_ The address of the Ethereum Vault Connector for Euler V2 protocol
     */
    constructor(uint256 marketId_, address eulerV2EVC_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        EVC = IEVC(eulerV2EVC_);
    }

    /// @notice Enters the Euler V2 Supply Fuse with the specified parameters
    /// @param data_ The data structure containing the parameters for entering the Euler V2 Supply Fuse
    /// @return sharesMinted The number of vault shares minted from the deposit (per ERC-4626)
    function enter(EulerV2SupplyFuseEnterData memory data_) public returns (uint256 sharesMinted) {
        if (data_.maxAmount == 0) {
            return 0;
        }
        if (!EulerFuseLib.canSupply(MARKET_ID, data_.eulerVault, data_.subAccount)) {
            revert EulerV2SupplyFuseUnsupportedEnterAction(data_.eulerVault, data_.subAccount);
        }

        address eulerVaultAsset = ERC4626Upgradeable(data_.eulerVault).asset();
        uint256 transferAmount = IporMath.min(data_.maxAmount, ERC20(eulerVaultAsset).balanceOf(address(this)));
        address plasmaVault = address(this);

        if (transferAmount == 0) {
            return 0;
        }

        address subAccount = EulerFuseLib.generateSubAccountAddress(plasmaVault, data_.subAccount);

        ERC20(eulerVaultAsset).forceApprove(data_.eulerVault, transferAmount);

        /* solhint-disable avoid-low-level-calls */
        sharesMinted = abi.decode(
            EVC.call(
                data_.eulerVault,
                plasmaVault,
                0,
                abi.encodeWithSelector(ERC4626Upgradeable.deposit.selector, transferAmount, subAccount)
            ),
            (uint256)
        );
        /* solhint-enable avoid-low-level-calls */

        emit EulerV2SupplyEnterFuse(VERSION, data_.eulerVault, sharesMinted, subAccount);
    }

    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        address eulerVault = TypeConversionLib.toAddress(inputs[0]);
        uint256 maxAmount = TypeConversionLib.toUint256(inputs[1]);
        bytes1 subAccount = bytes1(uint8(TypeConversionLib.toUint256(inputs[2])));

        uint256 sharesMinted = enter(EulerV2SupplyFuseEnterData(eulerVault, maxAmount, subAccount));

        bytes32[] memory outputs = new bytes32[](1);
        outputs[0] = TypeConversionLib.toBytes32(sharesMinted);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Exits the Euler V2 Supply Fuse with the specified parameters
    /// @param data_ The data structure containing the parameters for exiting the Euler V2 Supply Fuse
    function exit(EulerV2SupplyFuseExitData memory data_) public returns (uint256 withdrawnAmount) {
        if (data_.maxAmount == 0) {
            return 0;
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
            return 0;
        }

        /* solhint-disable avoid-low-level-calls */
        EVC.call(
            data_.eulerVault,
            subAccount,
            0,
            abi.encodeWithSelector(ERC4626Upgradeable.withdraw.selector, finalVaultAssetAmount, plasmaVault, subAccount)
        );
        /* solhint-enable avoid-low-level-calls */

        withdrawnAmount = finalVaultAssetAmount;

        emit EulerV2SupplyExitFuse(VERSION, data_.eulerVault, withdrawnAmount, subAccount);
    }

    function exitTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        address eulerVault = TypeConversionLib.toAddress(inputs[0]);
        uint256 maxAmount = TypeConversionLib.toUint256(inputs[1]);
        bytes1 subAccount = bytes1(uint8(TypeConversionLib.toUint256(inputs[2])));

        uint256 withdrawnAmount = exit(EulerV2SupplyFuseExitData(eulerVault, maxAmount, subAccount));

        bytes32[] memory outputs = new bytes32[](1);
        outputs[0] = TypeConversionLib.toBytes32(withdrawnAmount);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}
