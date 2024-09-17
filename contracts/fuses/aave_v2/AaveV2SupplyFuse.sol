// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AaveLendingPoolV2, ReserveData} from "./ext/AaveLendingPoolV2.sol";
import {AaveConstantsEthereum} from "./AaveConstantsEthereum.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IFuseInstantWithdraw} from "../IFuseInstantWithdraw.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

/// @dev Struct for entering with supply to the Aave V2 protocol
struct AaveV2SupplyFuseEnterData {
    /// @notice asset address to supply
    address asset;
    /// @notice asset amount to supply
    uint256 amount;
}

/// @dev Struct for exiting with supply (redeem) from the Aave V2 protocol
struct AaveV2SupplyFuseExitData {
    /// @notice asset address to withdraw
    address asset;
    /// @notice asset amount to withdraw
    uint256 amount;
}

/// @dev Fuse for Aave V2 protocol responsible for supplying and withdrawing assets from the Aave V2 protocol
contract AaveV2SupplyFuse is IFuseCommon, IFuseInstantWithdraw {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    AaveLendingPoolV2 public immutable AAVE_POOL;

    event AaveV2SupplyFuseEnter(address version, address asset, uint256 amount);
    event AaveV2SupplyFuseExit(address version, address asset, uint256 amount);
    event AaveV2SupplyFuseExitFailed(address version, address asset, uint256 amount);

    error AaveV2SupplyFuseUnsupportedAsset(address asset);

    constructor(uint256 marketId_, address aavePool_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        AAVE_POOL = AaveLendingPoolV2(aavePool_);
    }

    function enter(AaveV2SupplyFuseEnterData memory data_) external {
        if (data_.amount == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.asset)) {
            revert AaveV2SupplyFuseUnsupportedAsset(data_.asset);
        }

        ERC20(data_.asset).forceApprove(address(AAVE_POOL), data_.amount);

        AAVE_POOL.deposit(data_.asset, data_.amount, address(this), 0);

        emit AaveV2SupplyFuseEnter(VERSION, data_.asset, data_.amount);
    }

    function exit(AaveV2SupplyFuseExitData calldata data_) external {
        _exit(data_);
    }

    /// @dev params[0] - amount in underlying asset, params[1] - asset address
    function instantWithdraw(bytes32[] calldata params_) external override {
        uint256 amount = uint256(params_[0]);

        address asset = PlasmaVaultConfigLib.bytes32ToAddress(params_[1]);

        _exit(AaveV2SupplyFuseExitData(asset, amount));
    }

    function _exit(AaveV2SupplyFuseExitData memory data_) internal {
        if (data_.amount == 0) {
            return;
        }

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

        if (amountToWithdraw == 0) {
            return;
        }

        try AAVE_POOL.withdraw(data_.asset, amountToWithdraw, address(this)) returns (uint256 withdrawnAmount) {
            emit AaveV2SupplyFuseExit(VERSION, data_.asset, withdrawnAmount);
        } catch {
            /// @dev if withdraw failed, continue with the next step
            emit AaveV2SupplyFuseExitFailed(VERSION, data_.asset, data_.amount);
        }
    }
}
