// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {ERC20} from "@fusion/@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeCast} from "@fusion/@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@fusion/@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Errors} from "../../libraries/errors/Errors.sol";
import {IFuse} from "../IFuse.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {CErc20} from "./ext/CErc20.sol";

struct CompoundV2SupplyFuseEnterData {
    /// @notis asset address to supply
    address asset;
    /// @notice asset amount to supply
    uint256 amount;
}

struct CompoundV2SupplyFuseExitData {
    /// @notice asset address to withdraw
    address asset;
    /// @notice asset amount to withdraw
    uint256 amount;
}

contract CompoundV2SupplyFuse is IFuse {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    event CompoundV2SupplyEnterFuse(address version, address asset, address market, uint256 amount);
    event CompoundV2SupplyExitFuse(address version, address asset, address market, uint256 amount);

    error CompoundV2SupplyFuseUnsupportedAsset(address asset, string errorCode);

    constructor(uint256 marketIdInput) {
        VERSION = address(this);
        MARKET_ID = marketIdInput;
    }

    function enter(bytes calldata data) external {
        _enter(abi.decode(data, (CompoundV2SupplyFuseEnterData)));
    }

    function enter(CompoundV2SupplyFuseEnterData memory data) external {
        _enter(data);
    }

    function exit(bytes calldata data) external {
        _exit(abi.decode(data, (CompoundV2SupplyFuseExitData)));
    }

    function exit(CompoundV2SupplyFuseExitData calldata data) external {
        _exit(data);
    }

    function _enter(CompoundV2SupplyFuseEnterData memory data) internal {
        CErc20 cToken = CErc20(_getCToken(MARKET_ID, data.asset));

        ERC20(data.asset).forceApprove(address(cToken), data.amount);

        cToken.mint(data.amount);

        emit CompoundV2SupplyEnterFuse(VERSION, data.asset, address(cToken), data.amount);
    }

    function _exit(CompoundV2SupplyFuseExitData memory data) internal {
        CErc20 cToken = CErc20(_getCToken(MARKET_ID, data.asset));

        uint256 balance = cToken.balanceOfUnderlying(address(this));
        uint256 amountToWithdraw = data.amount > balance ? balance : data.amount;

        cToken.redeemUnderlying(amountToWithdraw);

        emit CompoundV2SupplyExitFuse(VERSION, data.asset, address(cToken), amountToWithdraw);
    }

    function _getCToken(uint256 marketId, address asset) internal view returns (address) {
        bytes32[] memory assetsRaw = PlasmaVaultConfigLib.getMarketSubstrates(marketId);
        uint256 len = assetsRaw.length;
        if (len == 0) {
            revert CompoundV2SupplyFuseUnsupportedAsset(asset, Errors.UNSUPPORTED_ASSET);
        }
        for (uint256 i; i < len; ++i) {
            address cToken = PlasmaVaultConfigLib.bytes32ToAddress(assetsRaw[i]);
            if (CErc20(cToken).underlying() == asset) {
                return cToken;
            }
        }
        revert CompoundV2SupplyFuseUnsupportedAsset(asset, Errors.UNSUPPORTED_ASSET);
    }
}
