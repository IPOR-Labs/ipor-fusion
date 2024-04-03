// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {AssetsToMarketLib} from "../../libraries/AssetsToMarketLib.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {IConnector} from "../IConnector.sol";
import {IApproveERC20} from "../IApproveERC20.sol";

// https://github.com/morpho-org/metamorpho
contract Erc4626SupplyConnector is IConnector {
    using SafeCast for uint256;

    struct Erc4626SupplyConnectorData {
        // vault address
        address vault;
        // max amount to supply
        uint256 amount;
    }

    event Erc4626SupplyConnector(string action, uint256 version, address tokenIn, address market, uint256 amount);

    error Erc4626SupplyConnectorUnsupportedVault(string action, address token, string errorCode);

    uint256 public immutable MARKET_ID;
    uint256 public constant VERSION = 1;

    constructor(uint256 marketIdInput) {
        MARKET_ID = marketIdInput;
    }

    function enter(bytes calldata data) external returns (bytes memory executionStatus) {
        Erc4626SupplyConnectorData memory data = abi.decode(data, (Erc4626SupplyConnectorData));
        return _enter(data);
    }

    function enter(Erc4626SupplyConnectorData memory data) external returns (bytes memory executionStatus) {
        return _enter(data);
    }

    function _enter(Erc4626SupplyConnectorData memory data) internal returns (bytes memory executionStatus) {
        if (!AssetsToMarketLib.isAssetGrantedToMarket(MARKET_ID, data.vault)) {
            revert Erc4626SupplyConnectorUnsupportedVault("enter", data.vault, Errors.NOT_SUPPORTED_ERC4626);
        }

        address underlineAsset = IERC4626(data.vault).asset();
        IApproveERC20(underlineAsset).approve(data.vault, data.amount);

        IERC4626(data.vault).deposit(data.amount, address(this));

        emit Erc4626SupplyConnector("enter", VERSION, underlineAsset, data.vault, data.amount);
        return abi.encodePacked(uint256(1));
    }

    function exit(bytes calldata data) external returns (bytes memory executionStatus) {
        Erc4626SupplyConnectorData memory data = abi.decode(data, (Erc4626SupplyConnectorData));
        return _exit(data);
    }

    function exit(Erc4626SupplyConnectorData calldata data) external returns (bytes memory executionStatus) {
        return _exit(data);
    }

    function _exit(Erc4626SupplyConnectorData memory data) internal returns (bytes memory executionStatus) {
        if (!AssetsToMarketLib.isAssetGrantedToMarket(MARKET_ID, data.vault)) {
            revert Erc4626SupplyConnectorUnsupportedVault("exit", data.vault, Errors.NOT_SUPPORTED_ERC4626);
        }
        uint256 shares = IERC4626(data.vault).withdraw(data.amount, address(this), address(this));
        emit Erc4626SupplyConnector("exit", VERSION, IERC4626(data.vault).asset(), data.vault, shares);
        return abi.encodePacked(data.amount);
    }
}
