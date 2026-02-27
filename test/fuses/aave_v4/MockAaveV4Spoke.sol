// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IAaveV4Spoke} from "../../../contracts/fuses/aave_v4/ext/IAaveV4Spoke.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockAaveV4Spoke
/// @notice Mock implementation of IAaveV4Spoke aligned with real Aave V4 ISpokeBase/ISpoke interface
contract MockAaveV4Spoke is IAaveV4Spoke {
    using SafeERC20 for IERC20;

    struct ReserveData {
        address asset;
        uint256 totalSupplyShares;
        uint256 totalBorrowShares;
        uint256 totalSupplyAssets;
        uint256 totalBorrowAssets;
    }

    struct PositionData {
        uint256 supplyShares;
        uint256 borrowShares;
    }

    mapping(uint256 => ReserveData) public reserveData;
    mapping(uint256 => mapping(address => PositionData)) public positions;
    uint256 public reserveCount;
    mapping(address => uint8) public userEModes;

    bool public shouldRevertOnWithdraw;

    /// @dev Share rate: shares = amount * shareRateNumerator / shareRateDenominator
    uint256 public shareRateNumerator = 1;
    uint256 public shareRateDenominator = 1;

    /// @dev Withdraw rate: withdrawn = capped * withdrawRateNumerator / withdrawRateDenominator
    uint256 public withdrawRateNumerator = 1;
    uint256 public withdrawRateDenominator = 1;

    function setShareRate(uint256 numerator_, uint256 denominator_) external {
        shareRateNumerator = numerator_;
        shareRateDenominator = denominator_;
    }

    function setWithdrawRate(uint256 numerator_, uint256 denominator_) external {
        withdrawRateNumerator = numerator_;
        withdrawRateDenominator = denominator_;
    }

    /// @dev Adds a reserve. reserveId is the sequential index (0, 1, 2, ...)
    function addReserve(uint256 reserveId_, address asset_) external {
        reserveData[reserveId_] = ReserveData({
            asset: asset_,
            totalSupplyShares: 0,
            totalBorrowShares: 0,
            totalSupplyAssets: 0,
            totalBorrowAssets: 0
        });
        if (reserveId_ >= reserveCount) {
            reserveCount = reserveId_ + 1;
        }
    }

    function setShouldRevertOnWithdraw(bool shouldRevert_) external {
        shouldRevertOnWithdraw = shouldRevert_;
    }

    // ============ Supply / Withdraw ============

    function supply(
        uint256 reserveId,
        uint256 amount,
        address onBehalfOf
    ) external returns (uint256 shares, uint256 suppliedAmount) {
        ReserveData storage reserve = reserveData[reserveId];
        IERC20(reserve.asset).safeTransferFrom(msg.sender, address(this), amount);

        shares = amount * shareRateNumerator / shareRateDenominator;
        positions[reserveId][onBehalfOf].supplyShares += shares;
        reserve.totalSupplyShares += shares;
        reserve.totalSupplyAssets += amount;
        suppliedAmount = amount;
    }

    function withdraw(
        uint256 reserveId,
        uint256 amount,
        address onBehalfOf
    ) external returns (uint256 withdrawnShares, uint256 withdrawnAmount) {
        if (shouldRevertOnWithdraw) {
            revert("MockAaveV4Spoke: withdraw reverted");
        }

        ReserveData storage reserve = reserveData[reserveId];
        uint256 supplyShares = positions[reserveId][onBehalfOf].supplyShares;

        // Convert shares to assets for capping (1:1 in default mock)
        uint256 maxWithdrawAssets = supplyShares * shareRateDenominator / shareRateNumerator;
        uint256 capped = amount > maxWithdrawAssets ? maxWithdrawAssets : amount;
        withdrawnAmount = capped * withdrawRateNumerator / withdrawRateDenominator;

        // Calculate shares to burn
        withdrawnShares = withdrawnAmount * shareRateNumerator / shareRateDenominator;

        positions[reserveId][onBehalfOf].supplyShares -= withdrawnShares;
        reserve.totalSupplyShares -= withdrawnShares;
        reserve.totalSupplyAssets -= withdrawnAmount;

        // Caller (msg.sender) receives tokens, like real Aave V4
        IERC20(reserve.asset).safeTransfer(msg.sender, withdrawnAmount);
    }

    // ============ Borrow / Repay ============

    function borrow(
        uint256 reserveId,
        uint256 amount,
        address onBehalfOf
    ) external returns (uint256 shares, uint256 borrowedAmount) {
        ReserveData storage reserve = reserveData[reserveId];

        shares = amount * shareRateNumerator / shareRateDenominator;
        positions[reserveId][onBehalfOf].borrowShares += shares;
        reserve.totalBorrowShares += shares;
        reserve.totalBorrowAssets += amount;

        IERC20(reserve.asset).safeTransfer(msg.sender, amount);
        borrowedAmount = amount;
    }

    function repay(
        uint256 reserveId,
        uint256 amount,
        address onBehalfOf
    ) external returns (uint256 repaidShares, uint256 repaidAmount) {
        ReserveData storage reserve = reserveData[reserveId];
        uint256 borrowShares = positions[reserveId][onBehalfOf].borrowShares;

        // Convert borrow shares to assets for capping
        uint256 maxRepayAssets = borrowShares * shareRateDenominator / shareRateNumerator;
        repaidAmount = amount > maxRepayAssets ? maxRepayAssets : amount;

        IERC20(reserve.asset).safeTransferFrom(msg.sender, address(this), repaidAmount);

        repaidShares = repaidAmount * shareRateNumerator / shareRateDenominator;
        positions[reserveId][onBehalfOf].borrowShares -= repaidShares;
        reserve.totalBorrowShares -= repaidShares;
        reserve.totalBorrowAssets -= repaidAmount;
    }

    // ============ User Position Queries ============

    function getUserSuppliedShares(uint256 reserveId, address user) external view returns (uint256) {
        return positions[reserveId][user].supplyShares;
    }

    function getUserSuppliedAssets(uint256 reserveId, address user) external view returns (uint256) {
        // Convert shares to assets using share rate
        return positions[reserveId][user].supplyShares * shareRateDenominator / shareRateNumerator;
    }

    function getUserTotalDebt(uint256 reserveId, address user) external view returns (uint256) {
        // Convert borrow shares to assets using share rate
        return positions[reserveId][user].borrowShares * shareRateDenominator / shareRateNumerator;
    }

    // ============ Reserve Queries ============

    function getReserveCount() external view returns (uint256) {
        return reserveCount;
    }

    function getReserve(uint256 reserveId) external view returns (Reserve memory) {
        ReserveData memory r = reserveData[reserveId];
        return Reserve({
            underlying: r.asset,
            hub: address(0),
            assetId: 0,
            decimals: 0,
            dynamicConfigKey: 0,
            collateralRisk: 0,
            flags: 0
        });
    }

    // ============ Reserve Aggregate Queries ============

    function getReserveSuppliedAssets(uint256 reserveId) external view returns (uint256) {
        return reserveData[reserveId].totalSupplyAssets;
    }

    function getReserveTotalDebt(uint256 reserveId) external view returns (uint256) {
        return reserveData[reserveId].totalBorrowAssets;
    }

    // ============ E-Mode ============

    function setUserEMode(uint8 categoryId) external {
        userEModes[msg.sender] = categoryId;
    }

    function getUserEMode(address user) external view returns (uint8) {
        return userEModes[user];
    }
}
