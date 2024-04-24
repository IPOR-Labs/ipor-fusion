// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {AaveLendingPoolV2, ReserveData} from "./AaveLendingPoolV2.sol";
import {AaveConstants} from "./AaveConstants.sol";
import {IFuse} from "../IFuse.sol";
import {IApproveERC20} from "../IApproveERC20.sol";
import {MarketConfigurationLib} from "../../libraries/MarketConfigurationLib.sol";

struct AaveV2SupplyFuseEnterData {
    /// @notice asset address to supply
    address asset;
    /// @notice asset amount to supply
    uint256 amount;
}

struct AaveV2SupplyFuseExitData {
    /// @notice asset address to withdraw
    address asset;
    /// @notice asset amount to withdraw
    uint256 amount;
}

contract AaveV2SupplyFuse is IFuse {
    using SafeCast for uint256;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    AaveLendingPoolV2 public immutable AAVE_POOL;

    event AaveV2SupplyEnterFuse(address version, address asset, uint256 amount);
    event AaveV2SupplyExitFuse(address version, address asset, uint256 amount);

    error AaveV2SupplyFuseUnsupportedAsset(address asset, string errorCode);

    constructor(uint256 marketIdInput, address aavePoolInput) {
        MARKET_ID = marketIdInput;
        VERSION = address(this);
        AAVE_POOL = AaveLendingPoolV2(aavePoolInput);
    }

    function enter(bytes calldata data) external {
        _enter(abi.decode(data, (AaveV2SupplyFuseEnterData)));
    }

    function enter(AaveV2SupplyFuseEnterData memory data) external {
        _enter(data);
    }

    function exit(bytes calldata data) external {
        _exit(abi.decode(data, (AaveV2SupplyFuseExitData)));
    }

    function exit(AaveV2SupplyFuseExitData calldata data) external {
        _exit(data);
    }

    function _enter(AaveV2SupplyFuseEnterData memory data) internal {
        if (!MarketConfigurationLib.isSubstrateAsAssetGranted(MARKET_ID, data.asset)) {
            revert AaveV2SupplyFuseUnsupportedAsset(data.asset, Errors.UNSUPPORTED_ASSET);
        }

        IApproveERC20(data.asset).approve(address(AAVE_POOL), data.amount);

        AAVE_POOL.deposit(data.asset, data.amount, address(this), 0);

        emit AaveV2SupplyEnterFuse(VERSION, data.asset, data.amount);
    }

    function _exit(AaveV2SupplyFuseExitData memory data) internal {
        if (!MarketConfigurationLib.isSubstrateAsAssetGranted(MARKET_ID, data.asset)) {
            revert AaveV2SupplyFuseUnsupportedAsset(data.asset, Errors.UNSUPPORTED_ASSET);
        }
        uint256 amountToWithdraw = data.amount;

        ReserveData memory reserveData = AaveLendingPoolV2(AaveConstants.AAVE_LENDING_POOL_V2).getReserveData(
            data.asset
        );
        uint256 aTokenBalance = ERC20(reserveData.aTokenAddress).balanceOf(address(this));

        if (aTokenBalance < amountToWithdraw) {
            amountToWithdraw = aTokenBalance;
        }

        emit AaveV2SupplyExitFuse(VERSION, data.asset, AAVE_POOL.withdraw(data.asset, amountToWithdraw, address(this)));
    }
}
