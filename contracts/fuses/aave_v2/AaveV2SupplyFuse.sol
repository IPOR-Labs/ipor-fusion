// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AaveLendingPoolV2, ReserveData} from "./ext/AaveLendingPoolV2.sol";
import {AaveConstantsEthereum} from "./AaveConstantsEthereum.sol";
import {IFuse} from "../IFuse.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

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
    using SafeERC20 for ERC20;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    AaveLendingPoolV2 public immutable AAVE_POOL;

    event AaveV2SupplyEnterFuse(address version, address asset, uint256 amount);
    event AaveV2SupplyExitFuse(address version, address asset, uint256 amount);

    error AaveV2SupplyFuseUnsupportedAsset(address asset);

    constructor(uint256 marketId_, address aavePool_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        AAVE_POOL = AaveLendingPoolV2(aavePool_);
    }

    function enter(bytes calldata data_) external {
        _enter(abi.decode(data_, (AaveV2SupplyFuseEnterData)));
    }

    function enter(AaveV2SupplyFuseEnterData memory data_) external {
        _enter(data_);
    }

    function exit(bytes calldata data_) external {
        _exit(abi.decode(data_, (AaveV2SupplyFuseExitData)));
    }

    function exit(AaveV2SupplyFuseExitData calldata data_) external {
        _exit(data_);
    }

    function _enter(AaveV2SupplyFuseEnterData memory data_) internal {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.asset)) {
            revert AaveV2SupplyFuseUnsupportedAsset(data_.asset);
        }

        ERC20(data_.asset).forceApprove(address(AAVE_POOL), data_.amount);

        AAVE_POOL.deposit(data_.asset, data_.amount, address(this), 0);

        emit AaveV2SupplyEnterFuse(VERSION, data_.asset, data_.amount);
    }

    function _exit(AaveV2SupplyFuseExitData memory data_) internal {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.asset)) {
            revert AaveV2SupplyFuseUnsupportedAsset(data_.asset);
        }
        uint256 amountToWithdraw = data_.amount;

        ReserveData memory reserveData = AaveLendingPoolV2(AaveConstantsEthereum.AAVE_LENDING_POOL_V2).getReserveData(
            data_.asset
        );
        uint256 aTokenBalance = ERC20(reserveData.aTokenAddress).balanceOf(address(this));

        if (aTokenBalance < amountToWithdraw) {
            amountToWithdraw = aTokenBalance;
        }

        emit AaveV2SupplyExitFuse(
            VERSION,
            data_.asset,
            AAVE_POOL.withdraw(data_.asset, amountToWithdraw, address(this))
        );
    }
}
