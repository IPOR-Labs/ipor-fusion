// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IporMath} from "../../../../libraries/math/IporMath.sol";
import {TypeConversionLib} from "../../../../libraries/TypeConversionLib.sol";
import {TransientStorageLib} from "../../../../transient_storage/TransientStorageLib.sol";
import {IFuseCommon} from "../../../IFuseCommon.sol";
import {IFuseInstantWithdraw} from "../../../IFuseInstantWithdraw.sol";
import {ILitePSM} from "./ext/ILitePSM.sol";

/// @notice Data structure for entering the LitePSM fuse (USDC -> USDS -> sUSDS)
struct LitePSMSupplyFuseEnterData {
    /// @dev amount of USDC to convert to USDS and deposit into sUSDS (6 decimals)
    uint256 amount;
    /// @dev maximum allowed tin fee (WAD-based), reverts if actual tin exceeds this value
    uint256 allowedTin;
    /// @dev minimum sUSDS shares expected from the deposit; reverts if fewer received
    uint256 minSharesOut;
}

/// @notice Data structure for exiting the LitePSM fuse (sUSDS -> USDS -> USDC)
struct LitePSMSupplyFuseExitData {
    /// @dev amount of USDC to receive (6 decimals)
    uint256 amount;
    /// @dev maximum allowed tout fee (WAD-based), reverts if actual tout exceeds this value
    uint256 allowedTout;
    /// @dev minimum USDC amount expected; reverts if fewer received (ignored in instantWithdraw)
    uint256 minAmountOut;
}

/// @notice Thrown when the actual PSM fee exceeds the allowed threshold
error LitePSMSupplyFuseFeeExceeded(uint256 actualFee, uint256 allowedFee);

/// @notice Thrown when sUSDS shares received are below the minimum required
error LitePSMSupplyFuseInsufficientShares(uint256 receivedShares, uint256 minSharesOut);

/// @notice Thrown when USDC received is below the minimum required
error LitePSMSupplyFuseInsufficientAmountOut(uint256 receivedAmount, uint256 minAmountOut);

/// @title Fuse for Sky LitePSM + sUSDS responsible for converting USDC to sUSDS and back
/// @notice Integrates with the LitePSMWrapper-USDS-USDC contract and sUSDS ERC4626 vault from the Sky ecosystem.
///
///         - Enter: USDC -> USDS (LitePSM sellGem) -> sUSDS (ERC4626 deposit)
///         - Exit:  sUSDS (ERC4626 withdraw) -> USDS -> USDC (LitePSM buyGem)
///
///         LitePSM exchanges USDS and USDC at a fixed 1:1 ratio (decimal adjustment only).
///         Governance-controlled fees (tin/tout) may apply to sellGem/buyGem respectively.
/// @dev Uses the LitePSMWrapper which routes USDS<->USDC swaps through DAI internally.
///      See: https://developers.skyeco.com/guides/psm/litepsm/
///
///      BALANCE & ACCOUNTING DEPENDENCY:
///      This fuse converts USDC (held by PlasmaVault) into sUSDS. After enter(), USDC disappears
///      from the vault's direct token balance and sUSDS shares appear on a separate market.
///
///      This fuse does NOT track balance — use ZeroBalanceFuse on this fuse's market.
///      sUSDS must be tracked on a SEPARATE market via Erc4626BalanceFuse or Erc20BalanceFuse.
///
///      Required configuration:
///        - ZeroBalanceFuse on this fuse's market (this fuse holds no assets itself)
///        - Erc4626BalanceFuse (or Erc20BalanceFuse) on the sUSDS market to track sUSDS value
///        - Dependency graph: this fuse's market -> sUSDS market
///
///      Balance Update Dependency Graph:
///        ┌──────────────┐         ┌──────────────┐
///        │  Market N    │ depends │  Market M    │
///        │  (LitePSM)   │───on───>│  (sUSDS)     │
///        │  ZeroBalance │         │  Erc4626Bal  │
///        └──────────────┘         └──────────────┘
contract LitePSMSupplyFuse is IFuseCommon, IFuseInstantWithdraw {
    using SafeERC20 for ERC20;

    /// @notice Address of USDC token
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /// @notice Address of USDS token
    address public constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;

    /// @notice Address of sUSDS ERC4626 vault
    address public constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;

    /// @notice Address of the LitePSM Wrapper contract
    address public constant LITE_PSM = 0xA188EEC8F81263234dA3622A406892F3D630f98c;

    /// @dev Decimal conversion factor: USDS (18 decimals) / USDC (6 decimals) = 1e12
    uint256 private constant DECIMAL_CONVERSION = 1e12;

    /// @dev WAD precision used by the PSM for fee calculations
    uint256 private constant WAD = 1e18;

    /// @notice Address of this fuse contract
    address public immutable VERSION;

    /// @notice Market ID for the fuse
    uint256 public immutable MARKET_ID;

    /// @notice Emitted when entering (USDC -> USDS)
    /// @param version Address of the fuse
    /// @param usdcAmount Amount of USDC sold
    /// @param usdsAmount Amount of USDS received
    event LitePSMSupplyFuseEnter(address version, uint256 usdcAmount, uint256 usdsAmount);

    /// @notice Emitted when exiting (USDS -> USDC)
    /// @param version Address of the fuse
    /// @param usdcAmount Amount of USDC received
    /// @param usdsAmount Amount of USDS sold
    event LitePSMSupplyFuseExit(address version, uint256 usdcAmount, uint256 usdsAmount);

    /// @notice Emitted when exit fails
    /// @param version Address of the fuse
    /// @param amount Amount of USDC attempted to withdraw
    event LitePSMSupplyFuseExitFailed(address version, uint256 amount);

    /// @notice Constructor
    /// @param marketIdInput Market ID
    constructor(uint256 marketIdInput) {
        VERSION = address(this);
        MARKET_ID = marketIdInput;
    }

    /// @notice Enters by converting USDC to USDS via LitePSM sellGem, then depositing USDS into sUSDS
    /// @param data The input data containing the USDC amount
    /// @return usdsReceived The amount of USDS received and deposited into sUSDS
    function enter(LitePSMSupplyFuseEnterData memory data) public returns (uint256 usdsReceived) {
        if (data.amount == 0) {
            return 0;
        }

        address plasmaVault = address(this);

        uint256 tin = ILitePSM(LITE_PSM).tin();
        if (tin > data.allowedTin) {
            revert LitePSMSupplyFuseFeeExceeded(tin, data.allowedTin);
        }

        uint256 finalAmount = IporMath.min(data.amount, ERC20(USDC).balanceOf(plasmaVault));
        if (finalAmount == 0) {
            return 0;
        }

        // USDC -> USDS via LitePSM (if tin is enabled, tin fee is deducted by the PSM, reducing USDS output)
        ERC20(USDC).forceApprove(LITE_PSM, finalAmount);
        ILitePSM(LITE_PSM).sellGem(plasmaVault, finalAmount);

        // Deposit entire USDS balance into sUSDS
        usdsReceived = ERC20(USDS).balanceOf(plasmaVault);

        ERC20(USDS).forceApprove(SUSDS, usdsReceived);
        uint256 sharesReceived = IERC4626(SUSDS).deposit(usdsReceived, plasmaVault);

        if (sharesReceived < data.minSharesOut) {
            revert LitePSMSupplyFuseInsufficientShares(sharesReceived, data.minSharesOut);
        }

        emit LitePSMSupplyFuseEnter(VERSION, finalAmount, usdsReceived);
    }

    /// @notice Enters using transient storage for input/output
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        uint256 amount = TypeConversionLib.toUint256(inputs[0]);
        uint256 allowedTin = TypeConversionLib.toUint256(inputs[1]);
        uint256 minSharesOut = TypeConversionLib.toUint256(inputs[2]);

        uint256 usdsReceived = enter(LitePSMSupplyFuseEnterData({amount: amount, allowedTin: allowedTin, minSharesOut: minSharesOut}));

        bytes32[] memory outputs = new bytes32[](1);
        outputs[0] = TypeConversionLib.toBytes32(usdsReceived);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Exits by withdrawing from sUSDS, then converting USDS to USDC via LitePSM buyGem
    /// @param data The input data containing the USDC amount to receive (6 decimals)
    /// @return usdcReceived The amount of USDC received
    function exit(LitePSMSupplyFuseExitData calldata data) external returns (uint256 usdcReceived) {
        return _exit(data, false);
    }

    /// @notice Exits using transient storage for input/output
    function exitTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        uint256 amount = TypeConversionLib.toUint256(inputs[0]);
        uint256 allowedTout = TypeConversionLib.toUint256(inputs[1]);
        uint256 minAmountOut = TypeConversionLib.toUint256(inputs[2]);

        uint256 usdcReceived = _exit(LitePSMSupplyFuseExitData({amount: amount, allowedTout: allowedTout, minAmountOut: minAmountOut}), false);

        bytes32[] memory outputs = new bytes32[](1);
        outputs[0] = TypeConversionLib.toBytes32(usdcReceived);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Instant withdraw
    /// @dev params[0] - amount in USDC (6 decimals), params[1] - allowedTout (WAD-based)
    /// @param params_ The parameters for instant withdraw
    function instantWithdraw(bytes32[] calldata params_) external override {
        _exit(LitePSMSupplyFuseExitData({amount: uint256(params_[0]), allowedTout: uint256(params_[1]), minAmountOut: 0}), true);
    }

    /// @notice Internal exit logic: sUSDS -> USDS -> USDC
    /// @param data_ The input data for exiting (amount in USDC, 6 decimals)
    /// @param catchExceptions_ Whether to catch exceptions
    /// @return usdcReceived The amount of USDC received
    function _exit(LitePSMSupplyFuseExitData memory data_, bool catchExceptions_) private returns (uint256 usdcReceived) {
        if (data_.amount == 0) {
            return 0;
        }

        address plasmaVault = address(this);

        uint256 tout = ILitePSM(LITE_PSM).tout();
        if (tout > data_.allowedTout) {
            if (!catchExceptions_) {
                revert LitePSMSupplyFuseFeeExceeded(tout, data_.allowedTout);
            }
            emit LitePSMSupplyFuseExitFailed(VERSION, data_.amount);
            return 0;
        }

        (uint256 finalUsdcAmount, uint256 finalUsdsAmount) = _computeExitAmounts(data_.amount, tout);

        if (finalUsdcAmount == 0) {
            return 0;
        }

        uint256 usdcBalanceBefore = ERC20(USDC).balanceOf(plasmaVault);

        if (!catchExceptions_) {
            IERC4626(SUSDS).withdraw(finalUsdsAmount, plasmaVault, plasmaVault);
            ERC20(USDS).forceApprove(LITE_PSM, finalUsdsAmount);
            ILitePSM(LITE_PSM).buyGem(plasmaVault, finalUsdcAmount);
            usdcReceived = ERC20(USDC).balanceOf(plasmaVault) - usdcBalanceBefore;
            if (usdcReceived < data_.minAmountOut) {
                revert LitePSMSupplyFuseInsufficientAmountOut(usdcReceived, data_.minAmountOut);
            }
            emit LitePSMSupplyFuseExit(VERSION, usdcReceived, finalUsdsAmount);
            return usdcReceived;
        }

        try IERC4626(SUSDS).withdraw(finalUsdsAmount, plasmaVault, plasmaVault) {} catch {
            emit LitePSMSupplyFuseExitFailed(VERSION, finalUsdcAmount);
            return 0;
        }
        // force approve cannot fail
        ERC20(USDS).forceApprove(LITE_PSM, finalUsdsAmount);
        try ILitePSM(LITE_PSM).buyGem(plasmaVault, finalUsdcAmount) {
            usdcReceived = ERC20(USDC).balanceOf(plasmaVault) - usdcBalanceBefore;
            emit LitePSMSupplyFuseExit(VERSION, usdcReceived, finalUsdsAmount);
        } catch {
            // buyGem failed, deposit USDS balance back into sUSDS to avoid leaving loose USDS
            uint256 usdsBalance = ERC20(USDS).balanceOf(plasmaVault);
            ERC20(USDS).forceApprove(SUSDS, usdsBalance);
            // we try our best to clean up state, if this fails the tx will revert
            IERC4626(SUSDS).deposit(usdsBalance, plasmaVault);
            emit LitePSMSupplyFuseExitFailed(VERSION, finalUsdcAmount);
        }
    }

    /// @notice Computes the USDC and USDS amounts for exit, accounting for tout fee and sUSDS availability
    /// @param usdcAmount_ Desired USDC amount to receive (6 decimals)
    /// @return finalUsdcAmount The actual USDC amount that can be received
    /// @return finalUsdsAmount The USDS amount to withdraw from sUSDS (includes tout fee)
    function _computeExitAmounts(uint256 usdcAmount_, uint256 tout_) private view returns (uint256 finalUsdcAmount, uint256 finalUsdsAmount) {
        uint256 usdsRequired = _usdcToUsdsWithTout(usdcAmount_, tout_);

        uint256 maxUsdsWithdraw = IERC4626(SUSDS).maxWithdraw(address(this));

        if (usdsRequired <= maxUsdsWithdraw) {
            finalUsdcAmount = usdcAmount_;
            finalUsdsAmount = usdsRequired;
        } else {
            // Work backwards from max USDS available to find max USDC amount.
            // Round down to USDC precision; any sub-USDC remainder stays as sUSDS shares (yield-bearing).
            finalUsdcAmount = _usdsToUsdcWithTout(maxUsdsWithdraw, tout_);
            finalUsdsAmount = _usdcToUsdsWithTout(finalUsdcAmount, tout_);
        }
    }

    /// @notice Converts a USDC amount (6 decimals) to the USDS amount (18 decimals) required by buyGem, including the tout fee
    /// @param usdcAmount_ USDC amount (6 decimals)
    /// @param tout_ The PSM tout fee (WAD-based)
    /// @return usdsAmount The total USDS needed: usdcAmount * 1e12 + usdcAmount * 1e12 * tout / WAD
    function _usdcToUsdsWithTout(uint256 usdcAmount_, uint256 tout_) private pure returns (uint256 usdsAmount) {
        uint256 usdsBase = usdcAmount_ * DECIMAL_CONVERSION;
        usdsAmount = usdsBase + usdsBase * tout_ / WAD;
    }

    /// @notice Converts a max USDS amount (18 decimals) back to the maximum USDC (6 decimals) receivable via buyGem, accounting for tout fee
    /// @param usdsAmount_ Available USDS amount (18 decimals)
    /// @param tout_ The PSM tout fee (WAD-based)
    /// @return usdcAmount The max USDC receivable, rounded down to 6-decimal precision
    function _usdsToUsdcWithTout(uint256 usdsAmount_, uint256 tout_) private pure returns (uint256 usdcAmount) {
        usdcAmount = usdsAmount_ * WAD / ((WAD + tout_) * DECIMAL_CONVERSION);
    }
}
