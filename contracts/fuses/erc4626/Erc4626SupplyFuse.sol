// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IFuseInstantWithdraw} from "../IFuseInstantWithdraw.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

/// @notice Data structure for entering - supply - the ERC4626 vault
struct Erc4626SupplyFuseEnterData {
    /// @dev ERC4626 vault address
    address vault;
    /// @dev amount to supply, this is amount of underlying asset in the given ERC4626 vault
    uint256 vaultAssetAmount;
}

/// @notice Data structure for exiting - withdrawing - the ERC4626 vault
struct Erc4626SupplyFuseExitData {
    /// @dev ERC4626 vault address
    address vault;
    /// @dev amount to withdraw, this is amount of underlying asset in the given ERC4626 vault
    uint256 vaultAssetAmount;
}

/// @title Generic fuse for ERC4626 vaults responsible for supplying and withdrawing assets from the ERC4626 vaults based on preconfigured market substrates
/// @dev Substrates in this fuse are the assets that are used in the ERC4626 vaults for a given MARKET_ID
contract Erc4626SupplyFuse is IFuseCommon, IFuseInstantWithdraw {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;

    event Erc4626SupplyFuseEnter(address version, address asset, address vault, uint256 vaultAssetAmount);
    event Erc4626SupplyFuseExit(
        address version,
        address asset,
        address vault,
        uint256 vaultAssetAmount,
        uint256 shares
    );
    event Erc4626SupplyFuseExitFailed(address version, address asset, address vault, uint256 vaultAssetAmount);

    error Erc4626SupplyFuseUnsupportedVault(string action, address asset);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    function enter(Erc4626SupplyFuseEnterData memory data_) external {
        if (data_.vaultAssetAmount == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.vault)) {
            revert Erc4626SupplyFuseUnsupportedVault("enter", data_.vault);
        }

        address underlyingAsset = IERC4626(data_.vault).asset();

        uint256 finalVaultAssetAmount = IporMath.min(
            data_.vaultAssetAmount,
            IERC4626(underlyingAsset).balanceOf(address(this))
        );

        if (finalVaultAssetAmount == 0) {
            return;
        }

        ERC20(underlyingAsset).forceApprove(data_.vault, finalVaultAssetAmount);

        IERC4626(data_.vault).deposit(finalVaultAssetAmount, address(this));

        emit Erc4626SupplyFuseEnter(VERSION, underlyingAsset, data_.vault, finalVaultAssetAmount);
    }

    function exit(Erc4626SupplyFuseExitData calldata data_) external {
        _exit(data_);
    }

    /// @dev params[0] - amount in underlying asset, params[1] - vault address
    function instantWithdraw(bytes32[] calldata params_) external override {
        uint256 amount = uint256(params_[0]);

        address vault = PlasmaVaultConfigLib.bytes32ToAddress(params_[1]);

        _exit(Erc4626SupplyFuseExitData(vault, amount));
    }

    function _exit(Erc4626SupplyFuseExitData memory data_) internal {
        if (data_.vaultAssetAmount == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.vault)) {
            revert Erc4626SupplyFuseUnsupportedVault("exit", data_.vault);
        }

        uint256 finalVaultAssetAmount = IporMath.min(
            data_.vaultAssetAmount,
            IERC4626(data_.vault).convertToAssets(IERC4626(data_.vault).balanceOf(address(this)))
        );

        if (finalVaultAssetAmount == 0) {
            return;
        }

        try IERC4626(data_.vault).withdraw(finalVaultAssetAmount, address(this), address(this)) returns (
            uint256 shares
        ) {
            emit Erc4626SupplyFuseExit(
                VERSION,
                IERC4626(data_.vault).asset(),
                data_.vault,
                finalVaultAssetAmount,
                shares
            );
        } catch {
            /// @dev if withdraw failed, continue with the next step
            emit Erc4626SupplyFuseExitFailed(
                VERSION,
                IERC4626(data_.vault).asset(),
                data_.vault,
                finalVaultAssetAmount
            );
        }
    }
}
