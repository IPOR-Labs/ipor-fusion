// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {FullMath} from "../ramses/ext/FullMath.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IFuseInstantWithdraw} from "../IFuseInstantWithdraw.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {IYieldBasisLT} from "./ext/IYieldBasisLT.sol";
/// @notice Data structure for entering - supply - the Yield Basis vault
struct YieldBasisLtSupplyFuseEnterData {
    /// @dev Leveraged Liquidity Token address (lt)
    address ltAddress;
    /// @dev amount to supply, this is amount of underlying asset in the given Yield Basis vault
    uint256 ltAssetAmount;
    /// @dev amount of debt to take, this is amount of debt for AMM to take (approximately ltAssetAmount * ltPrice), this is in USD, represented in 18 decimals
    uint256 debt;
    /// @dev minimum amount of shares to receive, if not enough shares are received, the enter will revert
    uint256 minSharesToReceive;
}

/// @notice Data structure for exiting - withdrawing - the Yield Basis vault
struct YieldBasisLtSupplyFuseExitData {
    /// @dev Leveraged Liquidity Token address (lt)
    address ltAddress;
    /// @dev amount of shares to withdraw, this is amount of shares in the given Yield Basis vault
    uint256 ltSharesAmount;
    /// @dev minimum amount of underlying asset to receive, if not enough underlying asset is received, the exit will revert
    uint256 minLtAssetAmountToReceive;
}

/// @title YieldBasisLtSupplyFuse
/// @notice Generic fuse for Yield Basis vaults responsible for supplying and withdrawing assets from the Yield Basis vaults based on preconfigured market substrates
/// @dev Substrates in this fuse are the assets that are used in the Yield Basis vaults for a given MARKET_ID.
///      This fuse implements both IFuseCommon (for enter/exit operations) and IFuseInstantWithdraw (for instant withdrawal functionality).
///      It supports transient storage operations through enterTransient() and exitTransient() methods.
contract YieldBasisLtSupplyFuse is IFuseCommon, IFuseInstantWithdraw {
    using SafeERC20 for IERC20;

    event YieldBasisLtSupplyFuseEnter(
        address version,
        address ltAddress,
        address ltAssetToken,
        uint256 ltAssetAmount,
        uint256 debt,
        uint256 ltSharesAmountReceived
    );
    event YieldBasisLtSupplyFuseInstantWithdrawExit(
        address version,
        address ltAddress,
        uint256 ltSharesAmount,
        uint256 ltAssetAmountReceived,
        int256 debtChange
    );

    event YieldBasisLtSupplyFuseExit(
        address version,
        address ltAddress,
        uint256 ltSharesAmount,
        uint256 ltAssetAmountReceived
    );

    error YieldBasisLtSupplyFuseUnsupportedVault(string action, address asset);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Supply assets to Yield Basis vault
    /// @param data_ Struct containing ltAddress, ltAssetAmount, debt, and minSharesToReceive
    /// @return ltAddress Leveraged Liquidity Token address
    /// @return ltAssetToken Asset token address
    /// @return ltAssetAmount Amount of underlying asset supplied
    /// @return debt Amount of debt taken
    /// @return ltSharesAmountReceived Amount of shares received
    function enter(
        YieldBasisLtSupplyFuseEnterData memory data_
    )
        public
        returns (
            address ltAddress,
            address ltAssetToken,
            uint256 ltAssetAmount,
            uint256 debt,
            uint256 ltSharesAmountReceived
        )
    {
        if (data_.ltAssetAmount == 0) {
            return (address(0), address(0), 0, 0, 0);
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.ltAddress)) {
            revert YieldBasisLtSupplyFuseUnsupportedVault("enter", data_.ltAddress);
        }

        ltAssetToken = IYieldBasisLT(data_.ltAddress).ASSET_TOKEN();

        IERC20(ltAssetToken).forceApprove(data_.ltAddress, data_.ltAssetAmount);

        ltSharesAmountReceived = IYieldBasisLT(data_.ltAddress).deposit(
            data_.ltAssetAmount,
            data_.debt,
            data_.minSharesToReceive,
            address(this)
        );

        IERC20(ltAssetToken).forceApprove(data_.ltAddress, 0);

        ltAddress = data_.ltAddress;
        ltAssetAmount = data_.ltAssetAmount;
        debt = data_.debt;

        emit YieldBasisLtSupplyFuseEnter(VERSION, ltAddress, ltAssetToken, ltAssetAmount, debt, ltSharesAmountReceived);
    }

    /// @notice Withdraw assets from Yield Basis vault
    /// @param data_ Struct containing ltAddress, ltSharesAmount, and minLtAssetAmountToReceive
    /// @return ltAddress Leveraged Liquidity Token address
    /// @return ltSharesAmount Amount of shares withdrawn
    /// @return ltAssetAmountReceived Amount of underlying asset received
    function exit(
        YieldBasisLtSupplyFuseExitData memory data_
    ) public returns (address ltAddress, uint256 ltSharesAmount, uint256 ltAssetAmountReceived) {
        return _exit(data_);
    }

    /**
     * @notice Performs instant withdrawal from Yield Basis vault based on underlying asset amount
     * @dev This function calculates the required LT shares based on the underlying asset amount and withdraws them.
     *      It implements the IFuseInstantWithdraw interface for instant withdrawal functionality.
     *      params[0] - amount in underlying assets (bytes32 encoded uint256)
     *      params[1] - LT address (bytes32 encoded address)
     * @param params_ Array of bytes32 parameters:
     *                - params[0]: Amount in underlying assets (bytes32 encoded uint256)
     *                - params[1]: Leveraged Liquidity Token address (bytes32 encoded address)
     */
    function instantWithdraw(bytes32[] calldata params_) external override {
        address plasmaVaultAddress = address(this);
        uint256 plasmaVaultUnderlyingAssetsAmount = uint256(params_[0]);
        uint256 plasmaVaultUnderlyingAssetsAmountDecimals = IERC20Metadata(IERC4626(plasmaVaultAddress).asset())
            .decimals();

        address ltAddress = PlasmaVaultConfigLib.bytes32ToAddress(params_[1]);

        if (plasmaVaultUnderlyingAssetsAmount == 0) {
            return;
        }

        IYieldBasisLT lt = IYieldBasisLT(ltAddress);

        uint256 underlyingAmountInWad = IporMath.convertToWad(
            plasmaVaultUnderlyingAssetsAmount,
            plasmaVaultUnderlyingAssetsAmountDecimals
        );

        uint256 ltSharesAmount = FullMath.mulDiv(underlyingAmountInWad, 1e18, lt.pricePerShare());

        uint256 ltSharesToWithdraw = IporMath.min(ltSharesAmount, lt.balanceOf(plasmaVaultAddress));

        if (ltSharesToWithdraw == 0) {
            return;
        }

        _exit(YieldBasisLtSupplyFuseExitData(ltAddress, ltSharesToWithdraw, 0));
    }

    /// @notice Internal function to withdraw assets from Yield Basis vault
    /// @param data_ Struct containing ltAddress, ltSharesAmount, and minLtAssetAmountToReceive
    /// @return ltAddress Leveraged Liquidity Token address
    /// @return ltSharesAmount Amount of shares withdrawn
    /// @return ltAssetAmountReceived Amount of underlying asset received
    function _exit(
        YieldBasisLtSupplyFuseExitData memory data_
    ) internal returns (address ltAddress, uint256 ltSharesAmount, uint256 ltAssetAmountReceived) {
        if (data_.ltSharesAmount == 0) {
            return (address(0), 0, 0);
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.ltAddress)) {
            revert YieldBasisLtSupplyFuseUnsupportedVault("exit", data_.ltAddress);
        }

        ltAssetAmountReceived = IYieldBasisLT(data_.ltAddress).withdraw(
            data_.ltSharesAmount,
            data_.minLtAssetAmountToReceive,
            address(this)
        );

        ltAddress = data_.ltAddress;
        ltSharesAmount = data_.ltSharesAmount;

        emit YieldBasisLtSupplyFuseExit(VERSION, ltAddress, ltSharesAmount, ltAssetAmountReceived);
    }

    /// @notice Enters the Fuse using transient storage for parameters
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        address ltAddress = TypeConversionLib.toAddress(inputs[0]);
        uint256 ltAssetAmount = TypeConversionLib.toUint256(inputs[1]);
        uint256 debt = TypeConversionLib.toUint256(inputs[2]);
        uint256 minSharesToReceive = TypeConversionLib.toUint256(inputs[3]);

        (
            address returnedLtAddress,
            address returnedLtAssetToken,
            uint256 returnedLtAssetAmount,
            uint256 returnedDebt,
            uint256 returnedLtSharesAmountReceived
        ) = enter(YieldBasisLtSupplyFuseEnterData(ltAddress, ltAssetAmount, debt, minSharesToReceive));

        bytes32[] memory outputs = new bytes32[](5);
        outputs[0] = TypeConversionLib.toBytes32(returnedLtAddress);
        outputs[1] = TypeConversionLib.toBytes32(returnedLtAssetToken);
        outputs[2] = TypeConversionLib.toBytes32(returnedLtAssetAmount);
        outputs[3] = TypeConversionLib.toBytes32(returnedDebt);
        outputs[4] = TypeConversionLib.toBytes32(returnedLtSharesAmountReceived);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Exits the Fuse using transient storage for parameters
    function exitTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        address ltAddress = TypeConversionLib.toAddress(inputs[0]);
        uint256 ltSharesAmount = TypeConversionLib.toUint256(inputs[1]);
        uint256 minLtAssetAmountToReceive = TypeConversionLib.toUint256(inputs[2]);

        (address returnedLtAddress, uint256 returnedLtSharesAmount, uint256 returnedLtAssetAmountReceived) = exit(
            YieldBasisLtSupplyFuseExitData(ltAddress, ltSharesAmount, minLtAssetAmountToReceive)
        );

        bytes32[] memory outputs = new bytes32[](3);
        outputs[0] = TypeConversionLib.toBytes32(returnedLtAddress);
        outputs[1] = TypeConversionLib.toBytes32(returnedLtSharesAmount);
        outputs[2] = TypeConversionLib.toBytes32(returnedLtAssetAmountReceived);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}
