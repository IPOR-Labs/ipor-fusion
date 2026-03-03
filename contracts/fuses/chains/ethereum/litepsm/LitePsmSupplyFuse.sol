// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IporMath} from "../../../../libraries/math/IporMath.sol";
import {TypeConversionLib} from "../../../../libraries/TypeConversionLib.sol";
import {TransientStorageLib} from "../../../../transient_storage/TransientStorageLib.sol";
import {IFuseCommon} from "../../../IFuseCommon.sol";
import {IFuseInstantWithdraw} from "../../../IFuseInstantWithdraw.sol";
import {ILitePSM} from "./ext/ILitePSM.sol";

/// @notice Data structure for entering the LitePSM fuse (USDC -> USDS)
struct LitePsmSupplyFuseEnterData {
    /// @dev amount of USDC to convert to USDS (6 decimals)
    uint256 amount;
}

/// @notice Data structure for exiting the LitePSM fuse (USDS -> USDC)
struct LitePsmSupplyFuseExitData {
    /// @dev amount of USDS to sell for USDC (18 decimals)
    uint256 amount;
}

/// @title Fuse for Sky LitePSM responsible for swapping USDC to USDS and back
/// @notice Integrates with the LitePSMWrapper-USDS-USDC contract from the Sky (formerly Maker) ecosystem.
///         LitePSM exchanges USDS and USDC at a fixed 1:1 ratio with zero slippage (no AMM curve).
///         Conversion is purely a decimal adjustment: 1 USDC (6 dec) = 1 USDS (18 dec).
///
///         - Enter (sellGem): Sells USDC for USDS. The PSM takes USDC from the caller and returns USDS.
///         - Exit (buyGem): Buys USDC with USDS. The PSM takes USDS from the caller and returns USDC.
///
///         Governance-controlled fees (tin/tout) may apply to sellGem/buyGem respectively.
///         Swap amounts are limited by the available DAI/USDC liquidity in the PSM buffer.
///         LitePSM offers no on-chain slippage protection; fees can change within the same block
///         if a pending governance action executes before the swap transaction.
/// @dev Uses the LitePSMWrapper which routes USDS<->USDC swaps through DAI internally.
///      See: https://developers.skyeco.com/guides/psm/litepsm/
contract LitePsmSupplyFuse is IFuseCommon, IFuseInstantWithdraw {
    using SafeERC20 for ERC20;

    /// @notice Address of USDC token
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /// @notice Address of USDS token
    address public constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;

    /// @notice Address of the LitePSM Wrapper contract
    address public constant LITE_PSM = 0xA188EEC8F81263234dA3622A406892F3D630f98c;

    /// @dev Decimal conversion factor: USDS (18 decimals) / USDC (6 decimals) = 1e12
    uint256 private constant DECIMAL_CONVERSION = 1e12;

    /// @notice Address of this fuse contract
    address public immutable VERSION;

    /// @notice Market ID for the fuse
    uint256 public immutable MARKET_ID;

    /// @notice Emitted when entering (USDC -> USDS)
    /// @param version Address of the fuse
    /// @param usdcAmount Amount of USDC sold
    /// @param usdsAmount Amount of USDS received
    event LitePsmSupplyFuseEnter(address version, uint256 usdcAmount, uint256 usdsAmount);

    /// @notice Emitted when exiting (USDS -> USDC)
    /// @param version Address of the fuse
    /// @param usdcAmount Amount of USDC received
    /// @param usdsAmount Amount of USDS sold
    event LitePsmSupplyFuseExit(address version, uint256 usdcAmount, uint256 usdsAmount);

    /// @notice Emitted when exit fails
    /// @param version Address of the fuse
    /// @param amount Amount of USDC attempted to withdraw
    event LitePsmSupplyFuseExitFailed(address version, uint256 amount);

    /// @notice Constructor
    /// @param marketIdInput Market ID
    constructor(uint256 marketIdInput) {
        VERSION = address(this);
        MARKET_ID = marketIdInput;
    }

    /// @notice Enters by converting USDC to USDS via LitePSM sellGem
    /// @param data The input data containing the USDC amount
    /// @return usdsReceived The amount of USDS received
    function enter(LitePsmSupplyFuseEnterData memory data) public returns (uint256 usdsReceived) {
        if (data.amount == 0) {
            return 0;
        }

        uint256 finalAmount = IporMath.min(data.amount, ERC20(USDC).balanceOf(address(this)));
        if (finalAmount == 0) {
            return 0;
        }

        // USDC -> USDS via LitePSM
        ERC20(USDC).forceApprove(LITE_PSM, finalAmount);
        uint256 usdsBalanceBefore = ERC20(USDS).balanceOf(address(this));
        ILitePSM(LITE_PSM).sellGem(address(this), finalAmount);
        usdsReceived = ERC20(USDS).balanceOf(address(this)) - usdsBalanceBefore;

        emit LitePsmSupplyFuseEnter(VERSION, finalAmount, usdsReceived);
    }

    /// @notice Enters using transient storage for input/output
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        uint256 amount = TypeConversionLib.toUint256(inputs[0]);

        uint256 usdsReceived = enter(LitePsmSupplyFuseEnterData({amount: amount}));

        bytes32[] memory outputs = new bytes32[](1);
        outputs[0] = TypeConversionLib.toBytes32(usdsReceived);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Exits by converting USDS to USDC via LitePSM buyGem
    /// @param data The input data containing the USDS amount to sell
    /// @return usdsUsed The amount of USDS used
    function exit(LitePsmSupplyFuseExitData calldata data) external returns (uint256 usdsUsed) {
        return _exit(data, false);
    }

    /// @notice Exits using transient storage for input/output
    function exitTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        uint256 amount = TypeConversionLib.toUint256(inputs[0]);

        uint256 usdsUsed = _exit(LitePsmSupplyFuseExitData({amount: amount}), false);

        bytes32[] memory outputs = new bytes32[](1);
        outputs[0] = TypeConversionLib.toBytes32(usdsUsed);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Instant withdraw
    /// @dev params[0] - amount in underlying asset (USDS, 18 decimals)
    /// @param params_ The parameters for instant withdraw
    function instantWithdraw(bytes32[] calldata params_) external override {
        _exit(LitePsmSupplyFuseExitData({amount: uint256(params_[0])}), true);
    }

    /// @notice Internal exit logic
    /// @param data_ The input data for exiting (amount in USDS, 18 decimals)
    /// @param catchExceptions_ Whether to catch exceptions during buyGem
    /// @return usdsUsed The amount of USDS used
    function _exit(LitePsmSupplyFuseExitData memory data_, bool catchExceptions_) private returns (uint256 usdsUsed) {
        if (data_.amount == 0) {
            return 0;
        }

        // Cap to available USDS balance
        uint256 finalUsdsAmount = IporMath.min(data_.amount, ERC20(USDS).balanceOf(address(this)));

        if (finalUsdsAmount == 0) {
            return 0;
        }

        // Convert USDS amount (18 dec) to USDC amount (6 dec)
        uint256 usdcAmount = finalUsdsAmount / DECIMAL_CONVERSION;

        if (usdcAmount == 0) {
            return 0;
        }

        if (catchExceptions_) {
            ERC20(USDS).forceApprove(LITE_PSM, finalUsdsAmount);
            try ILitePSM(LITE_PSM).buyGem(address(this), usdcAmount) {
                usdsUsed = finalUsdsAmount;
                emit LitePsmSupplyFuseExit(VERSION, usdcAmount, finalUsdsAmount);
            } catch {
                /// @dev if buyGem failed, continue with the next step
                emit LitePsmSupplyFuseExitFailed(VERSION, usdcAmount);
            }
        } else {
            ERC20(USDS).forceApprove(LITE_PSM, finalUsdsAmount);
            ILitePSM(LITE_PSM).buyGem(address(this), usdcAmount);
            usdsUsed = finalUsdsAmount;
            emit LitePsmSupplyFuseExit(VERSION, usdcAmount, finalUsdsAmount);
        }
    }
}
