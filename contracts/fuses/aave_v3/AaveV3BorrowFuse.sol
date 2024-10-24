// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IPool} from "./ext/IPool.sol";
import {IPoolAddressesProvider} from "./ext/IPoolAddressesProvider.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

/// @notice Structure for entering (borrow) to the Aave V3 protocol
struct AaveV3BorrowFuseEnterData {
    /// @notice asset address to borrow
    address asset;
    /// @notice asset amount to borrow
    uint256 amount;
}

/// @notice Structure for exiting (repay) from the Aave V3 protocol
struct AaveV3BorrowFuseExitData {
    /// @notice borrowed asset address to repay
    address asset;
    /// @notice borrowed asset amount to repay
    uint256 amount;
}

/// @title Fuse Aave V3 Borrow protocol responsible for borrowing and repaying assets in variable interest rate from the Aave V3 protocol based on preconfigured market substrates
/// @dev Substrates in this fuse are the assets that are used in the Aave V3 protocol for a given MARKET_ID
contract AaveV3BorrowFuse is IFuseCommon {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;

    /// @dev interest rate mode = 2 in Aave V3 means variable interest rate.
    uint256 public constant INTEREST_RATE_MODE = 2;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    address public immutable AAVE_V3_POOL_ADDRESSES_PROVIDER;

    event AaveV3BorrowFuseEnter(address version, address asset, uint256 amount, uint256 interestRateMode);

    /// @dev Exit for borrow is repay
    event AaveV3BorrowFuseExit(address version, address asset, uint256 repaidAmount, uint256 interestRateMode);

    error AaveV3BorrowFuseUnsupportedAsset(string action, address asset);

    constructor(uint256 marketId_, address aaveV3PoolAddressesProvider_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        if (aaveV3PoolAddressesProvider_ == address(0)) {
            revert Errors.WrongAddress();
        }
        AAVE_V3_POOL_ADDRESSES_PROVIDER = aaveV3PoolAddressesProvider_;
    }

    function enter(AaveV3BorrowFuseEnterData memory data_) external {
        if (data_.amount == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.asset)) {
            revert AaveV3BorrowFuseUnsupportedAsset("enter", data_.asset);
        }

        IPool(IPoolAddressesProvider(AAVE_V3_POOL_ADDRESSES_PROVIDER).getPool()).borrow(
            data_.asset,
            data_.amount,
            INTEREST_RATE_MODE,
            0,
            address(this)
        );

        emit AaveV3BorrowFuseEnter(VERSION, data_.asset, data_.amount, INTEREST_RATE_MODE);
    }

    function exit(AaveV3BorrowFuseExitData calldata data_) external {
        if (data_.amount == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.asset)) {
            revert AaveV3BorrowFuseUnsupportedAsset("exit", data_.asset);
        }

        address aavePool = IPoolAddressesProvider(AAVE_V3_POOL_ADDRESSES_PROVIDER).getPool();

        ERC20(data_.asset).forceApprove(aavePool, data_.amount);

        uint256 repaidAmount = IPool(aavePool).repay(data_.asset, data_.amount, INTEREST_RATE_MODE, address(this));

        emit AaveV3BorrowFuseExit(VERSION, data_.asset, repaidAmount, INTEREST_RATE_MODE);
    }
}
