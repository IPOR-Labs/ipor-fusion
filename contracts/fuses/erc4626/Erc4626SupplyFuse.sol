// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {IFuse} from "../IFuse.sol";
import {IApproveERC20} from "../IApproveERC20.sol";
import {MarketConfigurationLib} from "../../libraries/MarketConfigurationLib.sol";

// https://github.com/morpho-org/metamorpho
contract Erc4626SupplyFuse is IFuse {
    using SafeCast for uint256;

    struct Erc4626SupplyFuseData {
        // vault address
        address vault;
        // max amount to supply
        uint256 amount;
    }

    event Erc4626SupplyFuse(address version, string action, address asset, address market, uint256 amount);

    error Erc4626SupplyFuseUnsupportedVault(string action, address asset, string errorCode);

    uint256 public immutable MARKET_ID;
    address public immutable VERSION;

    constructor(uint256 marketIdInput) {
        MARKET_ID = marketIdInput;
        VERSION = address(this);
    }

    function enter(bytes calldata data) external {
        Erc4626SupplyFuseData memory data = abi.decode(data, (Erc4626SupplyFuseData));
        _enter(data);
    }

    function enter(Erc4626SupplyFuseData memory data) external {
        _enter(data);
    }

    function _enter(Erc4626SupplyFuseData memory data) internal {
        if (!MarketConfigurationLib.isSubstrateAsAssetGranted(MARKET_ID, data.vault)) {
            revert Erc4626SupplyFuseUnsupportedVault("enter", data.vault, Errors.UNSUPPORTED_ERC4626);
        }

        address underlineAsset = IERC4626(data.vault).asset();
        IApproveERC20(underlineAsset).approve(data.vault, data.amount);

        IERC4626(data.vault).deposit(data.amount, address(this));

        emit Erc4626SupplyFuse(VERSION, "enter", underlineAsset, data.vault, data.amount);
    }

    function exit(bytes calldata data) external {
        Erc4626SupplyFuseData memory data = abi.decode(data, (Erc4626SupplyFuseData));
        _exit(data);
    }

    function exit(Erc4626SupplyFuseData calldata data) external {
        _exit(data);
    }

    function _exit(Erc4626SupplyFuseData memory data) internal {
        if (!MarketConfigurationLib.isSubstrateAsAssetGranted(MARKET_ID, data.vault)) {
            revert Erc4626SupplyFuseUnsupportedVault("exit", data.vault, Errors.UNSUPPORTED_ERC4626);
        }

        uint256 shares = IERC4626(data.vault).withdraw(data.amount, address(this), address(this));

        emit Erc4626SupplyFuse(VERSION, "exit", IERC4626(data.vault).asset(), data.vault, shares);
    }
}
