// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IFuseCommon} from "../IFuseCommon.sol";
import {IFuseInstantWithdraw} from "../IFuseInstantWithdraw.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IFxPool, IFxPoolLimits, IFxPriceOracle} from "./ext/IFxPool.sol";
import {IFxPoolManager} from "./ext/IFxPoolManager.sol";
import {FxMintFuseLib} from "./lib/FxMintFuseLib.sol";
import {FxMintStorageLib} from "./lib/FxMintStorageLib.sol";

/// @notice Supply collateral to an f(x) pool
/// @param pool The f(x) long pool (must be a granted substrate)
/// @param collateralAmount Max collateral to add, in collateral token decimals (capped at the vault balance)
struct FxMintCollateralFuseEnterData {
    address pool;
    uint256 collateralAmount;
}

/// @notice Withdraw collateral from an f(x) pool
/// @param pool The f(x) long pool (must be a granted substrate)
/// @param collateralAmount Collateral to withdraw, in collateral token decimals (>= position = withdraw all)
struct FxMintCollateralFuseExitData {
    address pool;
    uint256 collateralAmount;
}

/// @title FxMintCollateralFuse
/// @notice Adds / withdraws collateral of the vault's f(x) Protocol v2 position (one position per pool). Instant
///         withdrawals free only collateral that needs no repayment, keeping a safety margin under the pool's max
///         debt ratio.
/// @dev f(x) rejects positions below its minimum debt ratio (ErrorDebtRatioTooSmall): a debt-free position cannot
///      exist, so open and fully close positions with FxMintCollateralAndBorrowFuse; this fuse adjusts collateral of
///      a position that carries debt.
contract FxMintCollateralFuse is IFuseCommon, IFuseInstantWithdraw {
    /// @notice Safety margin under the pool's max debt ratio kept by instant withdrawals (1% = 100)
    uint256 public constant INSTANT_LTV_MARGIN_BPS = 100;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    event FxMintCollateralFuseEnter(address version, address pool, uint256 positionId, uint256 amount);
    event FxMintCollateralFuseExit(address version, address pool, uint256 positionId, uint256 amount);
    event FxMintCollateralFuseExitFailed(address version, address pool, uint256 positionId, uint256 amount);

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Adds collateral to an existing position (opening needs debt too: use FxMintCollateralAndBorrowFuse)
    function enter(FxMintCollateralFuseEnterData memory data_) public returns (uint256 positionId, uint256 amount) {
        if (data_.collateralAmount == 0) return (0, 0);
        FxMintFuseLib.checkPool(MARKET_ID, data_.pool, "enter");
        uint256 balance = IERC20(IFxPool(data_.pool).collateralToken()).balanceOf(address(this));
        amount = data_.collateralAmount <= balance ? data_.collateralAmount : balance;
        if (amount == 0) return (0, 0);
        positionId = FxMintFuseLib.operate(data_.pool, FxMintFuseLib.positiveDelta(amount), 0);
        emit FxMintCollateralFuseEnter(VERSION, data_.pool, positionId, amount);
    }

    /// @notice Withdraws collateral (f(x) enforces its debt ratio limit)
    function exit(FxMintCollateralFuseExitData memory data_) public returns (uint256 positionId, uint256 amount) {
        if (data_.collateralAmount == 0) return (0, 0);
        FxMintFuseLib.checkPool(MARKET_ID, data_.pool, "exit");
        uint256 rawColls;
        (positionId, rawColls, ) = FxMintFuseLib.position(data_.pool);
        uint256 current = FxMintFuseLib.collateralAmount(data_.pool, rawColls);
        amount = data_.collateralAmount >= current ? current : data_.collateralAmount;
        FxMintFuseLib.operate(data_.pool, FxMintFuseLib.negativeDelta(data_.collateralAmount, current), 0);
        emit FxMintCollateralFuseExit(VERSION, data_.pool, positionId, amount);
    }

    /// @notice Instant withdrawal: params_[0] = collateral amount, params_[1] = pool. Frees at most what needs no
    ///         repayment; never reverts on f(x) errors (emits FxMintCollateralFuseExitFailed instead).
    function instantWithdraw(bytes32[] calldata params_) external override {
        uint256 wanted = uint256(params_[0]);
        address pool = PlasmaVaultConfigLib.bytes32ToAddress(params_[1]);
        if (wanted == 0) return;
        FxMintFuseLib.checkPool(MARKET_ID, pool, "instantWithdraw");
        (uint256 positionId, uint256 rawColls, uint256 rawDebts) = FxMintFuseLib.position(pool);
        if (positionId == 0) return;

        uint256 free = _freeCollateral(pool, rawColls, rawDebts);
        uint256 amount = wanted < free ? wanted : free;
        if (amount == 0) return;
        int256 delta = FxMintFuseLib.negativeDelta(amount, FxMintFuseLib.collateralAmount(pool, rawColls));

        try IFxPoolManager(IFxPool(pool).poolManager()).operate(pool, positionId, delta, 0) {
            (uint256 c, uint256 d) = IFxPool(pool).getPosition(positionId);
            if (c == 0 && d == 0) FxMintStorageLib.setPositionId(pool, 0);
            emit FxMintCollateralFuseExit(VERSION, pool, positionId, amount);
        } catch {
            emit FxMintCollateralFuseExitFailed(VERSION, pool, positionId, amount);
        }
    }

    /// @dev Collateral (token units) withdrawable while the debt stays under maxDebtRatio x (1 - margin), valued at
    ///      the f(x) oracle's min price (conservative).
    function _freeCollateral(address pool_, uint256 rawColls_, uint256 rawDebts_) private view returns (uint256) {
        if (rawDebts_ == 0) return FxMintFuseLib.collateralAmount(pool_, rawColls_);
        (, uint256 maxRatio) = IFxPoolLimits(pool_).getDebtRatioRange();
        (, uint256 minPrice, ) = IFxPriceOracle(IFxPoolLimits(pool_).priceOracle()).getPrice();
        uint256 effRatio = (maxRatio * (10_000 - INSTANT_LTV_MARGIN_BPS)) / 10_000;
        if (minPrice == 0 || effRatio == 0) return 0;
        // value(raw) = raw * price / 1e18; the debt must stay <= value * effRatio / 1e18
        uint256 denominator = minPrice * effRatio;
        uint256 requiredRaw = (rawDebts_ * 1e36 + denominator - 1) / denominator;
        if (requiredRaw >= rawColls_) return 0;
        return FxMintFuseLib.collateralAmount(pool_, rawColls_ - requiredRaw);
    }
}
