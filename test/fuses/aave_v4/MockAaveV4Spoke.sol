// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IAaveV4Spoke} from "../../../contracts/fuses/aave_v4/ext/IAaveV4Spoke.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockAaveV4Spoke
/// @notice Mock implementation of IAaveV4Spoke aligned with the real Aave V4 Spoke semantics:
///         - callers act for themselves (msg.sender == onBehalfOf) or revert Unauthorized,
///         - supply does NOT enable collateral; setUsingAsCollateral does,
///         - optional health-factor gate: borrow requires an enabled collateral with supply,
///           disabling collateral with outstanding debt reverts HealthFactorBelowThreshold.
contract MockAaveV4Spoke is IAaveV4Spoke {
    using SafeERC20 for IERC20;

    /// @dev borrowable (0x04) | receiveSharesEnabled (0x08)
    uint8 public constant DEFAULT_FLAGS = 0x0C;

    struct ReserveData {
        address asset;
        uint8 flags;
        bool listed;
        uint256 totalSupplyShares;
        uint256 totalBorrowShares;
        uint256 totalSupplyAssets;
        uint256 totalBorrowAssets;
    }

    struct PositionData {
        uint256 supplyShares;
        uint256 borrowShares;
        bool usingAsCollateral;
    }

    mapping(uint256 => ReserveData) public reserveData;
    mapping(uint256 => mapping(address => PositionData)) public positions;
    uint256 public reserveCount;

    bool public shouldRevertOnWithdraw;
    bool public requireCollateralForBorrow;

    /// @dev Share rate: shares = amount * shareRateNumerator / shareRateDenominator
    uint256 public shareRateNumerator = 1;
    uint256 public shareRateDenominator = 1;

    /// @dev Withdraw rate: withdrawn = capped * withdrawRateNumerator / withdrawRateDenominator
    uint256 public withdrawRateNumerator = 1;
    uint256 public withdrawRateDenominator = 1;

    // ============ Test configuration ============

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
            flags: DEFAULT_FLAGS,
            listed: true,
            totalSupplyShares: 0,
            totalBorrowShares: 0,
            totalSupplyAssets: 0,
            totalBorrowAssets: 0
        });
        if (reserveId_ >= reserveCount) {
            reserveCount = reserveId_ + 1;
        }
    }

    function setReserveFlags(uint256 reserveId_, uint8 flags_) external {
        reserveData[reserveId_].flags = flags_;
    }

    function setShouldRevertOnWithdraw(bool shouldRevert_) external {
        shouldRevertOnWithdraw = shouldRevert_;
    }

    /// @dev When enabled, borrow requires an enabled collateral reserve with supply and
    ///      disabling collateral with outstanding debt reverts (health factor gate)
    function setRequireCollateralForBorrow(bool require_) external {
        requireCollateralForBorrow = require_;
    }

    // ============ Supply / Withdraw ============

    function supply(
        uint256 reserveId,
        uint256 amount,
        address onBehalfOf
    ) external returns (uint256 shares, uint256 suppliedAmount) {
        _checkAuth(onBehalfOf);
        ReserveData storage reserve = _getListed(reserveId);
        IERC20(reserve.asset).safeTransferFrom(msg.sender, address(this), amount);

        shares = (amount * shareRateNumerator) / shareRateDenominator;
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
        _checkAuth(onBehalfOf);
        if (shouldRevertOnWithdraw) {
            revert("MockAaveV4Spoke: withdraw reverted");
        }

        ReserveData storage reserve = _getListed(reserveId);
        uint256 supplyShares = positions[reserveId][onBehalfOf].supplyShares;

        // Convert shares to assets for capping (1:1 in default mock)
        uint256 maxWithdrawAssets = (supplyShares * shareRateDenominator) / shareRateNumerator;
        uint256 capped = amount > maxWithdrawAssets ? maxWithdrawAssets : amount;
        withdrawnAmount = (capped * withdrawRateNumerator) / withdrawRateDenominator;

        // Calculate shares to burn
        withdrawnShares = (withdrawnAmount * shareRateNumerator) / shareRateDenominator;

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
        _checkAuth(onBehalfOf);
        ReserveData storage reserve = _getListed(reserveId);

        if (requireCollateralForBorrow && !_hasCollateral(onBehalfOf)) {
            revert HealthFactorBelowThreshold();
        }

        shares = (amount * shareRateNumerator) / shareRateDenominator;
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
        _checkAuth(onBehalfOf);
        ReserveData storage reserve = _getListed(reserveId);
        uint256 borrowShares = positions[reserveId][onBehalfOf].borrowShares;

        // Convert borrow shares to assets for capping
        uint256 maxRepayAssets = (borrowShares * shareRateDenominator) / shareRateNumerator;
        repaidAmount = amount > maxRepayAssets ? maxRepayAssets : amount;

        IERC20(reserve.asset).safeTransferFrom(msg.sender, address(this), repaidAmount);

        repaidShares = (repaidAmount * shareRateNumerator) / shareRateDenominator;
        positions[reserveId][onBehalfOf].borrowShares -= repaidShares;
        reserve.totalBorrowShares -= repaidShares;
        reserve.totalBorrowAssets -= repaidAmount;
    }

    // ============ Collateral ============

    function setUsingAsCollateral(uint256 reserveId, bool usingAsCollateral, address onBehalfOf) external {
        _checkAuth(onBehalfOf);
        _getListed(reserveId);

        PositionData storage position = positions[reserveId][onBehalfOf];
        if (position.usingAsCollateral == usingAsCollateral) {
            return;
        }

        if (!usingAsCollateral && requireCollateralForBorrow && _hasDebt(onBehalfOf)) {
            revert HealthFactorBelowThreshold();
        }

        position.usingAsCollateral = usingAsCollateral;
    }

    // ============ User Position Queries ============

    function getUserSuppliedShares(uint256 reserveId, address user) external view returns (uint256) {
        return positions[reserveId][user].supplyShares;
    }

    function getUserSuppliedAssets(uint256 reserveId, address user) external view returns (uint256) {
        // Convert shares to assets using share rate
        return (positions[reserveId][user].supplyShares * shareRateDenominator) / shareRateNumerator;
    }

    function getUserDebt(uint256 reserveId, address user) external view returns (uint256, uint256) {
        return (_totalDebt(reserveId, user), 0);
    }

    function getUserTotalDebt(uint256 reserveId, address user) external view returns (uint256) {
        return _totalDebt(reserveId, user);
    }

    function getUserPosition(uint256 reserveId, address user) external view returns (UserPosition memory) {
        PositionData memory position = positions[reserveId][user];
        return
            UserPosition({
                drawnShares: uint120(position.borrowShares),
                premiumShares: 0,
                premiumOffsetRay: 0,
                suppliedShares: uint120(position.supplyShares),
                dynamicConfigKey: 0
            });
    }

    function getUserReserveStatus(uint256 reserveId, address user) external view returns (bool, bool) {
        _getListed(reserveId);
        PositionData memory position = positions[reserveId][user];
        return (position.usingAsCollateral, position.borrowShares > 0);
    }

    function getUserAccountData(address user) external view returns (UserAccountData memory data) {
        bool hasDebt = _hasDebt(user);
        data.healthFactor = !hasDebt ? type(uint256).max : (_hasCollateral(user) ? 2e18 : 0.5e18);
        data.activeCollateralCount = _hasCollateral(user) ? 1 : 0;
        data.borrowCount = hasDebt ? 1 : 0;
    }

    // ============ Reserve Queries ============

    function getReserveCount() external view returns (uint256) {
        return reserveCount;
    }

    function getReserve(uint256 reserveId) external view returns (Reserve memory) {
        ReserveData memory r = _getListed(reserveId);
        return
            Reserve({
                underlying: r.asset,
                hub: address(0),
                assetId: uint16(reserveId),
                decimals: IERC20Metadata(r.asset).decimals(),
                collateralRisk: 0,
                flags: r.flags,
                dynamicConfigKey: 0
            });
    }

    function getReserveConfig(uint256 reserveId) external view returns (ReserveConfig memory) {
        ReserveData memory r = _getListed(reserveId);
        return
            ReserveConfig({
                collateralRisk: 0,
                paused: r.flags & 0x01 != 0,
                frozen: r.flags & 0x02 != 0,
                borrowable: r.flags & 0x04 != 0,
                receiveSharesEnabled: r.flags & 0x08 != 0
            });
    }

    function getDynamicReserveConfig(uint256 reserveId, uint32) external view returns (DynamicReserveConfig memory) {
        _getListed(reserveId);
        return DynamicReserveConfig({collateralFactor: 8000, maxLiquidationBonus: 10500, liquidationFee: 1000});
    }

    function getReserveId(address, uint256 assetId) external view returns (uint256) {
        for (uint256 i; i < reserveCount; ++i) {
            if (reserveData[i].listed && i == assetId) {
                return i;
            }
        }
        revert ReserveNotListed();
    }

    function getReserveSuppliedAssets(uint256 reserveId) external view returns (uint256) {
        return reserveData[reserveId].totalSupplyAssets;
    }

    function getReserveTotalDebt(uint256 reserveId) external view returns (uint256) {
        return reserveData[reserveId].totalBorrowAssets;
    }

    // ============ Immutables ============

    //solhint-disable-next-line func-name-mixedcase
    function ORACLE() external pure returns (address) {
        return address(0);
    }

    //solhint-disable-next-line func-name-mixedcase
    function MAX_USER_RESERVES_LIMIT() external pure returns (uint16) {
        return type(uint16).max;
    }

    // ============ Internal ============

    function _checkAuth(address onBehalfOf_) private view {
        if (msg.sender != onBehalfOf_) {
            revert Unauthorized();
        }
    }

    function _getListed(uint256 reserveId_) private view returns (ReserveData storage reserve) {
        reserve = reserveData[reserveId_];
        if (!reserve.listed) {
            revert ReserveNotListed();
        }
    }

    function _totalDebt(uint256 reserveId_, address user_) private view returns (uint256) {
        return (positions[reserveId_][user_].borrowShares * shareRateDenominator) / shareRateNumerator;
    }

    function _hasCollateral(address user_) private view returns (bool) {
        for (uint256 i; i < reserveCount; ++i) {
            PositionData memory position = positions[i][user_];
            if (reserveData[i].listed && position.usingAsCollateral && position.supplyShares > 0) {
                return true;
            }
        }
        return false;
    }

    function _hasDebt(address user_) private view returns (bool) {
        for (uint256 i; i < reserveCount; ++i) {
            if (reserveData[i].listed && positions[i][user_].borrowShares > 0) {
                return true;
            }
        }
        return false;
    }
}
