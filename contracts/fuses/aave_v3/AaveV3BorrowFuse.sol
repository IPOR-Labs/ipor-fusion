// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IFuse} from "../IFuse.sol";
import {IPool} from "./ext/IPool.sol";
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
contract AaveV3BorrowFuse is IFuse {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;

    /// @dev interest rate mode = 2 in Aave V3 means variable interest rate.
    uint256 public constant INTEREST_RATE_MODE = 2;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    IPool public immutable AAVE_POOL;

    event AaveV3BorrowEnterFuse(address version, address asset, uint256 amount, uint256 interestRateMode);

    /// @dev Exit for borrow is repay
    event AaveV3BorrowExitFuse(address version, address asset, uint256 repaidAmount, uint256 interestRateMode);

    error AaveV3BorrowFuseUnsupportedAsset(string action, address asset);

    constructor(uint256 marketId_, address aavePool_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        AAVE_POOL = IPool(aavePool_);
    }

    function enter(bytes calldata data_) external override {
        _enter(abi.decode(data_, (AaveV3BorrowFuseEnterData)));
    }

    function enter(AaveV3BorrowFuseEnterData memory data_) external {
        _enter(data_);
    }

    function exit(bytes calldata data_) external override {
        _exit(abi.decode(data_, (AaveV3BorrowFuseExitData)));
    }

    function exit(AaveV3BorrowFuseExitData calldata data_) external {
        _exit(data_);
    }

    function _enter(AaveV3BorrowFuseEnterData memory data_) internal {
        if (data_.amount == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.asset)) {
            revert AaveV3BorrowFuseUnsupportedAsset("enter", data_.asset);
        }

        AAVE_POOL.borrow(data_.asset, data_.amount, INTEREST_RATE_MODE, 0, address(this));

        emit AaveV3BorrowEnterFuse(VERSION, data_.asset, data_.amount, INTEREST_RATE_MODE);
    }

    function _exit(AaveV3BorrowFuseExitData memory data_) internal {
        if (data_.amount == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.asset)) {
            revert AaveV3BorrowFuseUnsupportedAsset("exit", data_.asset);
        }

        ERC20(data_.asset).forceApprove(address(AAVE_POOL), data_.amount);

        uint256 repaidAmount = AAVE_POOL.repay(data_.asset, data_.amount, INTEREST_RATE_MODE, address(this));

        emit AaveV3BorrowExitFuse(VERSION, data_.asset, repaidAmount, INTEREST_RATE_MODE);
    }
}