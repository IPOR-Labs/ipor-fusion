// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IAaveV4Spoke} from "../../../contracts/fuses/aave_v4/ext/IAaveV4Spoke.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockAaveV4Spoke
/// @notice Mock implementation of IAaveV4Spoke for testing Aave V4 fuses
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
    uint256[] public reserveIds;

    bool public shouldRevertOnWithdraw;

    /// @dev Share rate: shares = amount * shareRateNumerator / shareRateDenominator
    ///      Default 1:1 (both = 1). Set to e.g. (90, 100) for 90% shares per amount.
    uint256 public shareRateNumerator = 1;
    uint256 public shareRateDenominator = 1;

    /// @dev Withdraw rate: withdrawn = min(amount, maxWithdraw) * withdrawRateNumerator / withdrawRateDenominator
    ///      Default 1:1. Set to e.g. (90, 100) to return 90% of requested amount.
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

    function addReserve(uint256 reserveId_, address asset_) external {
        reserveData[reserveId_] = ReserveData({
            asset: asset_,
            totalSupplyShares: 0,
            totalBorrowShares: 0,
            totalSupplyAssets: 0,
            totalBorrowAssets: 0
        });
        reserveIds.push(reserveId_);
    }

    function setShouldRevertOnWithdraw(bool shouldRevert_) external {
        shouldRevertOnWithdraw = shouldRevert_;
    }

    function supply(uint256 reserveId, uint256 amount, address onBehalfOf) external returns (uint256 shares) {
        ReserveData storage reserve = reserveData[reserveId];
        IERC20(reserve.asset).safeTransferFrom(msg.sender, address(this), amount);

        shares = amount * shareRateNumerator / shareRateDenominator;
        positions[reserveId][onBehalfOf].supplyShares += shares;
        reserve.totalSupplyShares += shares;
        reserve.totalSupplyAssets += amount;
    }

    function withdraw(uint256 reserveId, uint256 amount, address to) external returns (uint256 withdrawn) {
        if (shouldRevertOnWithdraw) {
            revert("MockAaveV4Spoke: withdraw reverted");
        }

        ReserveData storage reserve = reserveData[reserveId];
        uint256 supplyShares = positions[reserveId][msg.sender].supplyShares;

        uint256 maxWithdraw = supplyShares;
        uint256 capped = amount > maxWithdraw ? maxWithdraw : amount;
        withdrawn = capped * withdrawRateNumerator / withdrawRateDenominator;

        positions[reserveId][msg.sender].supplyShares -= withdrawn;
        reserve.totalSupplyShares -= withdrawn;
        reserve.totalSupplyAssets -= withdrawn;

        IERC20(reserve.asset).safeTransfer(to, withdrawn);
    }

    function borrow(uint256 reserveId, uint256 amount, address onBehalfOf) external returns (uint256 shares) {
        ReserveData storage reserve = reserveData[reserveId];

        shares = amount * shareRateNumerator / shareRateDenominator;
        positions[reserveId][onBehalfOf].borrowShares += shares;
        reserve.totalBorrowShares += shares;
        reserve.totalBorrowAssets += amount;

        IERC20(reserve.asset).safeTransfer(msg.sender, amount);
    }

    function repay(uint256 reserveId, uint256 amount, address onBehalfOf) external returns (uint256 repaid) {
        ReserveData storage reserve = reserveData[reserveId];
        uint256 borrowShares = positions[reserveId][onBehalfOf].borrowShares;

        uint256 maxRepay = borrowShares;
        repaid = amount > maxRepay ? maxRepay : amount;

        IERC20(reserve.asset).safeTransferFrom(msg.sender, address(this), repaid);

        positions[reserveId][onBehalfOf].borrowShares -= repaid;
        reserve.totalBorrowShares -= repaid;
        reserve.totalBorrowAssets -= repaid;
    }

    function getPosition(
        uint256 reserveId,
        address user
    ) external view returns (uint256 supplyShares, uint256 borrowShares) {
        PositionData memory pos = positions[reserveId][user];
        return (pos.supplyShares, pos.borrowShares);
    }

    function getReserve(
        uint256 reserveId
    )
        external
        view
        returns (
            address asset,
            uint256 totalSupplyShares,
            uint256 totalBorrowShares,
            uint256 totalSupplyAssets,
            uint256 totalBorrowAssets
        )
    {
        ReserveData memory r = reserveData[reserveId];
        return (r.asset, r.totalSupplyShares, r.totalBorrowShares, r.totalSupplyAssets, r.totalBorrowAssets);
    }

    // 1:1 conversion for testing simplicity
    function convertToSupplyAssets(uint256, uint256 shares) external pure returns (uint256 assets) {
        return shares;
    }

    function convertToDebtAssets(uint256, uint256 shares) external pure returns (uint256 assets) {
        return shares;
    }

    function getReserveCount() external view returns (uint256 count) {
        return reserveIds.length;
    }

    function getReserveId(uint256 index) external view returns (uint256 reserveId) {
        return reserveIds[index];
    }
}
