// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {IFuse} from "../IFuse.sol";
import {IApproveERC20} from "../IApproveERC20.sol";
import {PlazmaVaultConfigLib} from "../../libraries/PlazmaVaultConfigLib.sol";
import {IFuseInstantWithdraw} from "../IFuseInstantWithdraw.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";

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

    event Erc4626SupplyFuse(address version, string action, address asset, address market, uint256 amount);

    error Erc4626SupplyFuseUnsupportedVault(string action, address asset, string errorCode);

    uint256 public immutable MARKET_ID;
    address public immutable VERSION;

    constructor(uint256 marketIdInput) {
        MARKET_ID = marketIdInput;
        VERSION = address(this);
    }

    function enter(bytes calldata data) external override {
        Erc4626SupplyFuseEnterData memory data = abi.decode(data, (Erc4626SupplyFuseEnterData));
        _enter(data);
    }

    /// @dev technical method to generate ABI
    function enter(Erc4626SupplyFuseEnterData memory data) external {
        _enter(data);
    }

    function exit(bytes calldata data) external override {
        Erc4626SupplyFuseExitData memory data = abi.decode(data, (Erc4626SupplyFuseExitData));
        _exit(data);
    }

    /// @dev technical method to generate ABI
    function exit(Erc4626SupplyFuseExitData calldata data) external {
        _exit(data);
    }

    /// @dev params[0] - amount in underlying asset, params[1] - vault address
    function instantWithdraw(bytes32[] calldata params) external override {
        uint256 amount = uint256(params[0]);
        address vault = PlazmaVaultConfigLib.bytes32ToAddress(params[1]);

        _exit(Erc4626SupplyFuseExitData(vault, amount));
    }

    function _enter(Erc4626SupplyFuseEnterData memory data) internal {
        if (!PlazmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data.vault)) {
            revert Erc4626SupplyFuseUnsupportedVault("enter", data.vault, Errors.UNSUPPORTED_ERC4626);
        }

        address underlineAsset = IERC4626(data.vault).asset();
        IApproveERC20(underlineAsset).approve(data.vault, data.amount);

        IERC4626(data.vault).deposit(data.amount, address(this));

        emit Erc4626SupplyFuse(VERSION, "enter", underlineAsset, data.vault, data.amount);
    }

    function _exit(Erc4626SupplyFuseExitData memory data) internal {
        if (!PlazmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data.vault)) {
            revert Erc4626SupplyFuseUnsupportedVault("exit", data.vault, Errors.UNSUPPORTED_ERC4626);
        }

        uint256 vaultBalanceAssets = IERC4626(data.vault).convertToAssets(
            IERC4626(data.vault).balanceOf(address(this))
        );

        uint256 shares = IERC4626(data.vault).withdraw(
            IporMath.min(data.amount, vaultBalanceAssets),
            address(this),
            address(this)
        );

        emit Erc4626SupplyFuse(VERSION, "exit", IERC4626(data.vault).asset(), data.vault, shares);
    }
}
