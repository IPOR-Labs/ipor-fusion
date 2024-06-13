// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {IFuse} from "../IFuse.sol";
import {IComet} from "./ext/IComet.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IFuseInstantWithdraw} from "../IFuseInstantWithdraw.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";

struct CompoundV3SupplyFuseEnterData {
    /// @notice asset address to supply
    address asset;
    /// @notice asset amount to supply
    uint256 amount;
}

struct CompoundV3SupplyFuseExitData {
    /// @notice asset address to withdraw
    address asset;
    /// @notice asset amount to withdraw
    uint256 amount;
}

contract CompoundV3SupplyFuse is IFuse, IFuseInstantWithdraw {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    IComet public immutable COMET;
    address public immutable COMPOUND_BASE_TOKEN;

    event CompoundV3SupplyEnterFuse(address version, address asset, address market, uint256 amount);
    event CompoundV3SupplyExitFuse(address version, address asset, address market, uint256 amount);

    error CompoundV3SupplyFuseUnsupportedAsset(string action, address asset, string errorCode);

    constructor(uint256 marketIdInput, address cometAddressInput) {
        VERSION = address(this);
        MARKET_ID = marketIdInput;
        COMET = IComet(cometAddressInput);
        COMPOUND_BASE_TOKEN = COMET.baseToken();
    }

    function enter(bytes calldata data) external override {
        _enter(abi.decode(data, (CompoundV3SupplyFuseEnterData)));
    }

    /// @dev technical method to generate ABI
    function enter(CompoundV3SupplyFuseEnterData memory data) external {
        _enter(data);
    }

    function exit(bytes calldata data) external override {
        _exit(abi.decode(data, (CompoundV3SupplyFuseExitData)));
    }

    /// @dev technical method to generate ABI
    function exit(CompoundV3SupplyFuseExitData calldata data) external {
        _exit(data);
    }

    /// @dev params[0] - amount in underlying asset, params[1] - asset address
    function instantWithdraw(bytes32[] calldata params) external override {
        uint256 amount = uint256(params[0]);
        address asset = PlasmaVaultConfigLib.bytes32ToAddress(params[1]);

        _exit(CompoundV3SupplyFuseExitData(asset, amount));
    }

    function _enter(CompoundV3SupplyFuseEnterData memory data) internal {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data.asset)) {
            revert CompoundV3SupplyFuseUnsupportedAsset("enter", data.asset, Errors.UNSUPPORTED_ASSET);
        }

        ERC20(data.asset).forceApprove(address(COMET), data.amount);

        COMET.supply(data.asset, data.amount);

        emit CompoundV3SupplyEnterFuse(VERSION, data.asset, address(COMET), data.amount);
    }

    function _exit(CompoundV3SupplyFuseExitData memory data) internal {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data.asset)) {
            revert CompoundV3SupplyFuseUnsupportedAsset("exit", data.asset, Errors.UNSUPPORTED_ASSET);
        }

        COMET.withdraw(data.asset, IporMath.min(data.amount, _getBalance(data.asset)));

        emit CompoundV3SupplyExitFuse(VERSION, data.asset, address(COMET), data.amount);
    }

    function _getBalance(address asset) private view returns (uint256) {
        if (asset == COMPOUND_BASE_TOKEN) {
            return COMET.balanceOf(address(this));
        } else {
            return COMET.collateralBalanceOf(address(this), asset);
        }
    }
}
