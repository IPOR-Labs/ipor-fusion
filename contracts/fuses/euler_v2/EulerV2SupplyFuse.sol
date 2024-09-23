pragma solidity 0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IEVault} from "./ext/IEVault.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IEVC} from "ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";

/// @notice Data structure for entering (deposit) Euler V2 vaults
struct EulerV2SupplyFuseEnterData {
    /// @notice EVault address to deposit into
    address vault;
    /// @notice asset amount to deposit
    uint256 amount;
}

/// @notice Data structure for exiting (withdraw) from Euler V2 vaults
struct EulerV2SupplyFuseExitData {
    /// @notice EVault address to withdraw from
    address vault;
    /// @notice asset amount to withdraw
    uint256 amount;
}

/// @title Fuse Euler V2 Supply responsible for depositing and withdrawing assets from Euler V2 vaults
/// @dev Substrates in this fuse are the EVaults that are used in Euler V2 for a given MARKET_ID
contract EulerV2SupplyFuse is IFuseCommon {
    using SafeERC20 for ERC20;

    event EulerV2SupplyEnterFuse(address version, address vault, uint256 amount);
    event EulerV2SupplyExitFuse(address version, address vault, uint256 withdrawnAmount);

    error EulerV2SupplyFuseUnsupportedVault(string action, address vault);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    IEVC public immutable EVC;

    constructor(uint256 marketId_, address eulerV2EVC_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        EVC = IEVC(eulerV2EVC_);
    }

    function enter(EulerV2SupplyFuseEnterData memory data_) external {
        if (data_.amount == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.vault)) {
            revert EulerV2SupplyFuseUnsupportedVault("enter", data_.vault);
        }

        IEVault vault = IEVault(data_.vault);
        address underlyingAsset = vault.asset();

        uint256 finalVaultAssetAmount = IporMath.min(data_.amount, ERC20(underlyingAsset).balanceOf(address(this)));

        if (finalVaultAssetAmount == 0) {
            return;
        }

        ERC20(underlyingAsset).forceApprove(data_.vault, finalVaultAssetAmount);

        bytes memory depositCalldata = abi.encodeWithSelector(vault.deposit.selector, data_.amount, address(this));

        /* solhint-disable avoid-low-level-calls */
        uint256 depositedAmount = abi.decode(EVC.call(data_.vault, address(this), 0, depositCalldata), (uint256));
        emit EulerV2SupplyEnterFuse(VERSION, data_.vault, depositedAmount);
        /* solhint-enable avoid-low-level-calls */
    }

    function exit(EulerV2SupplyFuseExitData memory data_) external {
        if (data_.amount == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.vault)) {
            revert EulerV2SupplyFuseUnsupportedVault("exit", data_.vault);
        }

        IEVault vault = IEVault(data_.vault);

        uint256 finalVaultAssetAmount = IporMath.min(
            data_.amount,
            vault.convertToAssets(vault.balanceOf(address(this)))
        );

        if (finalVaultAssetAmount == 0) {
            return;
        }

        bytes memory withdrawCalldata = abi.encodeWithSelector(
            vault.withdraw.selector,
            data_.amount,
            address(this),
            address(this)
        );

        /* solhint-disable avoid-low-level-calls */
        uint256 withdrawnAmount = abi.decode(EVC.call(data_.vault, address(this), 0, withdrawCalldata), (uint256));
        emit EulerV2SupplyExitFuse(VERSION, data_.vault, withdrawnAmount);
        /* solhint-enable avoid-low-level-calls */
    }
}
