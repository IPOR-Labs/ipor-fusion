// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {IPool} from "../../vaults/interfaces/IPool.sol";
import {IFuse} from "../IFuse.sol";
import {IApproveERC20} from "../IApproveERC20.sol";
import {MarketConfigurationLib} from "../../libraries/MarketConfigurationLib.sol";
import {IAavePoolDataProvider} from "./IAavePoolDataProvider.sol";
import {AaveConstants} from "./AaveConstants.sol";

contract AaveV3SupplyFuse is IFuse {
    using SafeCast for uint256;

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

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    IPool public immutable AAVE_POOL;

    event AaveV3SupplyEnterFuse(address version, address asset, uint256 amount, uint256 userEModeCategoryId);
    event AaveV3SupplyExitFuse(address version, address asset, uint256 amount);

    error AaveV3SupplyFuseUnsupportedAsset(string action, address asset, string errorCode);

    constructor(address aavePoolInput, uint256 marketIdInput) {
        AAVE_POOL = IPool(aavePoolInput);
        MARKET_ID = marketIdInput;
        VERSION = address(this);
    }

    function enter(bytes calldata data) external {
        _enter(abi.decode(data, (AaveV3SupplyFuseEnterData)));
    }

    function enter(AaveV3SupplyFuseEnterData memory data) external {
        _enter(data);
    }

    /// @dev params[0] - amount in underlying asset, params[1] - asset address
    function withdraw(bytes32[] calldata params) external override {
        uint256 amount = uint256(params[0]);
        address asset = MarketConfigurationLib.bytes32ToAddress(params[1]);
        _exit(AaveV3SupplyFuseExitData(asset, amount));
    }

    function _enter(AaveV3SupplyFuseEnterData memory data) internal {
        if (!MarketConfigurationLib.isSubstrateAsAssetGranted(MARKET_ID, data.asset)) {
            revert AaveV3SupplyFuseUnsupportedAsset("enter", data.asset, Errors.UNSUPPORTED_ASSET);
        }

        IApproveERC20(data.asset).approve(address(AAVE_POOL), data.amount);

        AAVE_POOL.supply(data.asset, data.amount, address(this), 0);

        if (data.userEModeCategoryId <= type(uint8).max) {
            AAVE_POOL.setUserEMode(data.userEModeCategoryId.toUint8());
        }

        emit AaveV3SupplyEnterFuse(VERSION, data.asset, data.amount, data.userEModeCategoryId);
    }

    function exit(bytes calldata data) external {
        _exit(abi.decode(data, (AaveV3SupplyFuseExitData)));
    }

    function exit(AaveV3SupplyFuseExitData calldata data) external {
        _exit(data);
    }

    function _exit(AaveV3SupplyFuseExitData memory data) internal {
        if (!MarketConfigurationLib.isSubstrateAsAssetGranted(MARKET_ID, data.asset)) {
            revert AaveV3SupplyFuseUnsupportedAsset("exit", data.asset, Errors.UNSUPPORTED_ASSET);
        }

        uint256 amountToWithdraw = data.amount;

        (address aTokenAddress, , ) = IAavePoolDataProvider(AaveConstants.ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3_MAINNET)
            .getReserveTokensAddresses(data.asset);

        uint256 aTokenBalance = ERC20(aTokenAddress).balanceOf(address(this));

        if (aTokenBalance < amountToWithdraw) {
            amountToWithdraw = aTokenBalance;
        }

        uint256 withdrawnAmount = AAVE_POOL.withdraw(data.asset, amountToWithdraw, address(this));

        emit AaveV3SupplyExitFuse(VERSION, data.asset, withdrawnAmount);
    }
}
