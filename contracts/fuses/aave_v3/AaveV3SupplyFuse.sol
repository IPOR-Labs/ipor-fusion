// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {IPool} from "../../vaults/interfaces/IPool.sol";
import {IFuse} from "../IFuse.sol";
import {IApproveERC20} from "../IApproveERC20.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IAavePoolDataProvider} from "./IAavePoolDataProvider.sol";
import {IFuseInstantWithdraw} from "../IFuseInstantWithdraw.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";

struct AaveV3SupplyFuseEnterData {
    /// @notice asset address to supply
    address asset;
    /// @notice asset amount to supply
    uint256 amount;
    /// @notice user eMode category if pass value bigger than 255 is ignored and not set
    uint256 userEModeCategoryId;
}

struct AaveV3SupplyFuseExitData {
    /// @notice asset address to withdraw
    address asset;
    /// @notice asset amount to withdraw
    uint256 amount;
}

contract AaveV3SupplyFuse is IFuse, IFuseInstantWithdraw {
    using SafeCast for uint256;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    IPool public immutable AAVE_POOL;
    address public immutable AAVE_POOL_DATA_PROVIDER_V3;

    event AaveV3SupplyEnterFuse(address version, address asset, uint256 amount, uint256 userEModeCategoryId);
    event AaveV3SupplyExitFuse(address version, address asset, uint256 amount);
    event AaveV3SupplyExitFailed(address version, address asset, uint256 amount);

    error AaveV3SupplyFuseUnsupportedAsset(string action, address asset, string errorCode);

    constructor(uint256 marketIdInput, address aavePoolInput, address aavePoolDataProviderV3) {
        VERSION = address(this);
        MARKET_ID = marketIdInput;
        AAVE_POOL = IPool(aavePoolInput);
        AAVE_POOL_DATA_PROVIDER_V3 = aavePoolDataProviderV3;
    }

    function enter(bytes calldata data) external override {
        _enter(abi.decode(data, (AaveV3SupplyFuseEnterData)));
    }

    /// @dev technical method to generate ABI
    function enter(AaveV3SupplyFuseEnterData memory data) external {
        _enter(data);
    }

    function exit(bytes calldata data) external override {
        _exit(abi.decode(data, (AaveV3SupplyFuseExitData)));
    }

    /// @dev technical method to generate ABI
    function exit(AaveV3SupplyFuseExitData calldata data) external {
        _exit(data);
    }

    /// @dev params[0] - amount in underlying asset, params[1] - asset address
    function instantWithdraw(bytes32[] calldata params) external override {
        uint256 amount = uint256(params[0]);
        address asset = PlasmaVaultConfigLib.bytes32ToAddress(params[1]);

        _exit(AaveV3SupplyFuseExitData(asset, amount));
    }

    function _enter(AaveV3SupplyFuseEnterData memory data) internal {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data.asset)) {
            revert AaveV3SupplyFuseUnsupportedAsset("enter", data.asset, Errors.UNSUPPORTED_ASSET);
        }

        IApproveERC20(data.asset).approve(address(AAVE_POOL), data.amount);

        AAVE_POOL.supply(data.asset, data.amount, address(this), 0);

        if (data.userEModeCategoryId <= type(uint8).max) {
            AAVE_POOL.setUserEMode(data.userEModeCategoryId.toUint8());
        }

        emit AaveV3SupplyEnterFuse(VERSION, data.asset, data.amount, data.userEModeCategoryId);
    }

    function _exit(AaveV3SupplyFuseExitData memory data) internal {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data.asset)) {
            revert AaveV3SupplyFuseUnsupportedAsset("exit", data.asset, Errors.UNSUPPORTED_ASSET);
        }

        (address aTokenAddress, , ) = IAavePoolDataProvider(AAVE_POOL_DATA_PROVIDER_V3).getReserveTokensAddresses(
            data.asset
        );

        try
            AAVE_POOL.withdraw(
                data.asset,
                IporMath.min(ERC20(aTokenAddress).balanceOf(address(this)), data.amount),
                address(this)
            )
        returns (uint256 withdrawnAmount) {
            emit AaveV3SupplyExitFuse(VERSION, data.asset, withdrawnAmount);
        } catch {
            /// @dev if withdraw failed, continue with the next step
            emit AaveV3SupplyExitFailed(VERSION, data.asset, data.amount);
        }
    }
}
