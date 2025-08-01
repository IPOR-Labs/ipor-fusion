// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IPool} from "./ext/IPool.sol";
import {IPoolAddressesProvider} from "./ext/IPoolAddressesProvider.sol";
import {IAavePoolDataProvider} from "./ext/IAavePoolDataProvider.sol";
import {IFuseInstantWithdraw} from "../IFuseInstantWithdraw.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

/// @dev Struct for entering with supply to the Aave V3 protocol
struct AaveV3SupplyFuseEnterData {
    /// @notice asset address to supply
    address asset;
    /// @notice asset amount to supply
    uint256 amount;
    /// @notice user eMode category if pass value bigger than 255 is ignored and not set
    uint256 userEModeCategoryId;
}

/// @dev Struct for exiting with supply (redeem) from the Aave V3 protocol
struct AaveV3SupplyFuseExitData {
    /// @notice asset address to withdraw
    address asset;
    /// @notice asset amount to withdraw
    uint256 amount;
}
/// @dev Fuse for Aave V3 protocol responsible for supplying and withdrawing assets from the Aave V3 protocol
contract AaveV3SupplyFuse is IFuseCommon, IFuseInstantWithdraw {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    address public immutable AAVE_V3_POOL_ADDRESSES_PROVIDER;

    event AaveV3SupplyFuseEnter(address version, address asset, uint256 amount, uint256 userEModeCategoryId);
    event AaveV3SupplyFuseExit(address version, address asset, uint256 amount);
    event AaveV3SupplyFuseExitFailed(address version, address asset, uint256 amount);

    error AaveV3SupplyFuseUnsupportedAsset(string action, address asset);

    constructor(uint256 marketId_, address aaveV3PoolAddressesProvider_) {
        if (marketId_ == 0) {
            revert Errors.WrongValue();
        }
        if (aaveV3PoolAddressesProvider_ == address(0)) {
            revert Errors.WrongAddress();
        }

        VERSION = address(this);
        MARKET_ID = marketId_;
        AAVE_V3_POOL_ADDRESSES_PROVIDER = aaveV3PoolAddressesProvider_;
    }

    function enter(AaveV3SupplyFuseEnterData memory data_) external {
        if (data_.amount == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.asset)) {
            revert AaveV3SupplyFuseUnsupportedAsset("enter", data_.asset);
        }

        IPool aavePool = IPool(IPoolAddressesProvider(AAVE_V3_POOL_ADDRESSES_PROVIDER).getPool());

        uint256 finalAmount = IporMath.min(ERC20(data_.asset).balanceOf(address(this)), data_.amount);

        ERC20(data_.asset).forceApprove(address(aavePool), finalAmount);

        aavePool.supply(data_.asset, finalAmount, address(this), 0);

        if (data_.userEModeCategoryId <= type(uint8).max) {
            aavePool.setUserEMode(data_.userEModeCategoryId.toUint8());
        }

        emit AaveV3SupplyFuseEnter(VERSION, data_.asset, finalAmount, data_.userEModeCategoryId);
    }

    function exit(AaveV3SupplyFuseExitData calldata data_) external {
        _exit(data_);
    }

    /// @dev params[0] - amount in underlying asset, params[1] - asset address
    function instantWithdraw(bytes32[] calldata params_) external override {
        uint256 amount = uint256(params_[0]);

        address asset = PlasmaVaultConfigLib.bytes32ToAddress(params_[1]);

        _exit(AaveV3SupplyFuseExitData(asset, amount));
    }

    function _exit(AaveV3SupplyFuseExitData memory data) internal {
        if (data.amount == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data.asset)) {
            revert AaveV3SupplyFuseUnsupportedAsset("exit", data.asset);
        }

        (address aTokenAddress, , ) = IAavePoolDataProvider(
            IPoolAddressesProvider(AAVE_V3_POOL_ADDRESSES_PROVIDER).getPoolDataProvider()
        ).getReserveTokensAddresses(data.asset);

        uint256 finalAmount = IporMath.min(ERC20(aTokenAddress).balanceOf(address(this)), data.amount);

        if (finalAmount == 0) {
            return;
        }

        IPool aavePool = IPool(IPoolAddressesProvider(AAVE_V3_POOL_ADDRESSES_PROVIDER).getPool());

        try aavePool.withdraw(data.asset, finalAmount, address(this)) returns (uint256 withdrawnAmount) {
            emit AaveV3SupplyFuseExit(VERSION, data.asset, withdrawnAmount);
        } catch {
            /// @dev if withdraw failed, continue with the next step
            emit AaveV3SupplyFuseExitFailed(VERSION, data.asset, data.amount);
        }
    }
}
