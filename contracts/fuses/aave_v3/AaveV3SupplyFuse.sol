// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {IPool} from "../../vaults/interfaces/IPool.sol";
import {IFuse} from "../IFuse.sol";
import {IApproveERC20} from "../IApproveERC20.sol";
import {MarketConfigurationLib} from "../../libraries/MarketConfigurationLib.sol";

contract AaveV3SupplyFuse is IFuse {
    using SafeCast for uint256;

    struct AaveV3SupplyFuseData {
        // token to supply
        address asset;
        // max amount to supply
        uint256 amount;
        // user eMode category if pass value bigger than 255 is ignored and not set
        uint256 userEModeCategoryId;
    }

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    IPool public immutable AAVE_POOL;

    event AaveV3SupplyFuse(address version, string action, address asset, uint256 amount, uint256 userEModeCategoryId);

    error AaveV3SupplyFuseUnsupportedAsset(string action, address asset, string errorCode);

    constructor(address aavePoolInput, uint256 marketIdInput) {
        AAVE_POOL = IPool(aavePoolInput);
        MARKET_ID = marketIdInput;
        VERSION = address(this);
    }

    function enter(bytes calldata data) external {
        AaveV3SupplyFuseData memory structData = abi.decode(data, (AaveV3SupplyFuseData));
        _enter(structData);
    }

    function enter(AaveV3SupplyFuseData memory data) external {
        _enter(data);
    }

    function _enter(AaveV3SupplyFuseData memory data) internal {
        if (!MarketConfigurationLib.isSubstrateAsAssetGranted(MARKET_ID, data.asset)) {
            revert AaveV3SupplyFuseUnsupportedAsset("enter", data.asset, Errors.UNSUPPORTED_ASSET);
        }

        IApproveERC20(data.asset).approve(address(AAVE_POOL), data.amount);

        AAVE_POOL.supply(data.asset, data.amount, address(this), 0);

        if (data.userEModeCategoryId <= type(uint8).max) {
            AAVE_POOL.setUserEMode(data.userEModeCategoryId.toUint8());
        }

        emit AaveV3SupplyFuse(VERSION, "enter", data.asset, data.amount, data.userEModeCategoryId);
    }

    function exit(bytes calldata data) external {
        AaveV3SupplyFuseData memory data = abi.decode(data, (AaveV3SupplyFuseData));
        _exit(data);
    }

    function exit(AaveV3SupplyFuseData calldata data) external {
        _exit(data);
    }

    function _exit(AaveV3SupplyFuseData memory data) internal {
        if (!MarketConfigurationLib.isSubstrateAsAssetGranted(MARKET_ID, data.asset)) {
            revert AaveV3SupplyFuseUnsupportedAsset("exit", data.asset, Errors.UNSUPPORTED_ASSET);
        }

        uint256 withdrawnAmount = AAVE_POOL.withdraw(data.asset, data.amount, address(this));

        emit AaveV3SupplyFuse(VERSION, "exit", data.asset, withdrawnAmount, data.userEModeCategoryId);
    }
}
