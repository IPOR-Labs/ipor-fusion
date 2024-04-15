// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {AaveLendingPoolV2} from "./AaveLendingPoolV2.sol";
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

    constructor(address aavePoolInput, uint256 marketIdInput) {
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

    function _enter(AaveV2SupplyFuseEnterData memory data) internal {
        if (!MarketConfigurationLib.isSubstrateAsAssetGranted(MARKET_ID, data.asset)) {
            revert AaveV2SupplyFuseUnsupportedAsset(data.asset, Errors.UNSUPPORTED_ASSET);
        }

        IApproveERC20(data.asset).approve(address(AAVE_POOL), data.amount);

        AAVE_POOL.deposit(data.asset, data.amount, address(this), 0);

        emit AaveV2SupplyEnterFuse(VERSION, data.asset, data.amount);
    }

    function exit(bytes calldata data) external {
        _exit(abi.decode(data, (AaveV2SupplyFuseExitData)));
    }

    function exit(AaveV2SupplyFuseExitData calldata data) external {
        _exit(data);
    }

    function _exit(AaveV2SupplyFuseExitData memory data) internal {
        if (!MarketConfigurationLib.isSubstrateAsAssetGranted(MARKET_ID, data.asset)) {
            revert AaveV2SupplyFuseUnsupportedAsset(data.asset, Errors.UNSUPPORTED_ASSET);
        }

        uint256 withdrawnAmount = AAVE_POOL.withdraw(data.asset, data.amount, address(this));

        emit AaveV2SupplyExitFuse(VERSION, data.asset, withdrawnAmount);
    }
}
