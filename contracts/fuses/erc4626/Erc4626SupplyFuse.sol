// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IFuse} from "../IFuse.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IFuseInstantWithdraw} from "../IFuseInstantWithdraw.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

struct Erc4626SupplyFuseEnterData {
    /// @dev vault address
    address vault;
    /// @dev max amount to supply
    uint256 amount;
}

struct Erc4626SupplyFuseExitData {
    /// @dev vault address
    address vault;
    /// @dev max amount to withdraw
    uint256 amount;
}

// https://github.com/morpho-org/metamorpho
contract Erc4626SupplyFuse is IFuse, IFuseInstantWithdraw {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;

    event Erc4626SupplyEnterFuse(address version, address asset, address market, uint256 amount);
    event Erc4626SupplyExitFuse(address version, address asset, address market, uint256 amount);

    error Erc4626SupplyFuseUnsupportedVault(string action, address asset);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    function enter(bytes calldata data_) external override {
        Erc4626SupplyFuseEnterData memory data = abi.decode(data_, (Erc4626SupplyFuseEnterData));
        _enter(data);
    }

    /// @dev technical method to generate ABI
    function enter(Erc4626SupplyFuseEnterData memory data_) external {
        _enter(data_);
    }

    function exit(bytes calldata data_) external override {
        Erc4626SupplyFuseExitData memory data = abi.decode(data_, (Erc4626SupplyFuseExitData));
        _exit(data);
    }

    /// @dev technical method to generate ABI
    function exit(Erc4626SupplyFuseExitData calldata data_) external {
        _exit(data_);
    }

    /// @dev params[0] - amount in underlying asset, params[1] - vault address
    function instantWithdraw(bytes32[] calldata params_) external override {
        uint256 amount = uint256(params_[0]);

        address vault = PlasmaVaultConfigLib.bytes32ToAddress(params_[1]);

        _exit(Erc4626SupplyFuseExitData(vault, amount));
    }

    function _enter(Erc4626SupplyFuseEnterData memory data_) internal {
        if (data_.amount == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.vault)) {
            revert Erc4626SupplyFuseUnsupportedVault("enter", data_.vault);
        }

        address underlineAsset = IERC4626(data_.vault).asset();
        ERC20(underlineAsset).forceApprove(data_.vault, data_.amount);

        IERC4626(data_.vault).deposit(data_.amount, address(this));

        emit Erc4626SupplyEnterFuse(VERSION, underlineAsset, data_.vault, data_.amount);
    }

    function _exit(Erc4626SupplyFuseExitData memory data_) internal {
        if (data_.amount == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.vault)) {
            revert Erc4626SupplyFuseUnsupportedVault("exit", data_.vault);
        }

        uint256 vaultBalanceAssets = IERC4626(data_.vault).convertToAssets(
            IERC4626(data_.vault).balanceOf(address(this))
        );

        uint256 shares = IERC4626(data_.vault).withdraw(
            IporMath.min(data_.amount, vaultBalanceAssets),
            address(this),
            address(this)
        );

        emit Erc4626SupplyExitFuse(VERSION, IERC4626(data_.vault).asset(), data_.vault, shares);
    }
}
