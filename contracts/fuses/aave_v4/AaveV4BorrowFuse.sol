// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IporMath} from "../../libraries/math/IporMath.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {AaveV4SubstrateLib} from "./AaveV4SubstrateLib.sol";
import {IAaveV4Spoke} from "./ext/IAaveV4Spoke.sol";

/// @dev Data structure for entering (borrow) the Aave V4 protocol
struct AaveV4BorrowFuseEnterData {
    /// @notice Aave V4 Spoke contract address
    address spoke;
    /// @notice ERC20 token address to borrow (cross-checked against the reserve's underlying)
    address asset;
    /// @notice Aave V4 reserve identifier within the Spoke
    uint256 reserveId;
    /// @notice Amount of tokens to borrow
    uint256 amount;
    /// @notice Minimum number of borrow shares to receive
    uint256 minShares;
}

/// @dev Data structure for exiting (repay) from the Aave V4 protocol
struct AaveV4BorrowFuseExitData {
    /// @notice Aave V4 Spoke contract address
    address spoke;
    /// @notice ERC20 token address to repay (cross-checked against the reserve's underlying)
    address asset;
    /// @notice Aave V4 reserve identifier within the Spoke
    uint256 reserveId;
    /// @notice Amount of tokens to repay (capped at the vault balance and, by the Spoke, at the total debt)
    uint256 amount;
    /// @notice Minimum number of borrow shares to repay
    uint256 minSharesRepaid;
}

/// @title AaveV4BorrowFuse
/// @author IPOR Labs
/// @notice Fuse for Aave V4 protocol responsible for borrowing and repaying assets via Spoke contracts
/// @dev Executes in PlasmaVault storage context via delegatecall. MUST NOT contain storage variables.
///      Permissions come from Reserve substrates (spoke, reserveId, flags) encoded with AaveV4SubstrateLib:
///      - enter (borrow) requires a granted substrate for the (spoke, reserveId) pair with canBorrow,
///      - exit (repay) requires any granted substrate for the pair, so debt can always be repaid even
///        after the canBorrow flag has been revoked.
///      Borrowing requires collateral enabled via AaveV4CollateralFuse, otherwise the Spoke reverts with
///      HealthFactorBelowThreshold.
contract AaveV4BorrowFuse is IFuseCommon {
    using SafeERC20 for ERC20;

    /// @notice The address of the version of the Fuse
    address public immutable VERSION;
    /// @notice The Market ID associated with the Fuse
    uint256 public immutable MARKET_ID;

    /// @notice Emitted when entering the Aave V4 borrow fuse (borrowing)
    /// @param version The address of the fuse version
    /// @param spoke The Aave V4 Spoke contract address
    /// @param asset The address of the asset borrowed
    /// @param reserveId The reserve identifier
    /// @param amount The amount of the asset borrowed
    /// @param shares The amount of borrow shares created
    event AaveV4BorrowFuseEnter(
        address version,
        address spoke,
        address asset,
        uint256 reserveId,
        uint256 amount,
        uint256 shares
    );

    /// @notice Emitted when exiting the Aave V4 borrow fuse (repaying)
    /// @param version The address of the fuse version
    /// @param spoke The Aave V4 Spoke contract address
    /// @param asset The address of the asset repaid
    /// @param reserveId The reserve identifier
    /// @param repaidAmount The amount of the asset repaid
    /// @param shares The amount of borrow shares repaid
    event AaveV4BorrowFuseExit(
        address version,
        address spoke,
        address asset,
        uint256 reserveId,
        uint256 repaidAmount,
        uint256 shares
    );

    /// @notice Thrown when the (spoke, reserveId) pair is not granted for the action
    /// @param action The action being performed ("enter" requires canBorrow, "exit" requires any grant)
    /// @param spoke The Spoke contract address
    /// @param reserveId The reserve identifier
    error AaveV4BorrowFuseUnsupportedSubstrate(string action, address spoke, uint256 reserveId);

    /// @notice Thrown when market ID is zero or invalid
    /// @custom:error AaveV4BorrowFuseInvalidMarketId
    error AaveV4BorrowFuseInvalidMarketId();

    /// @notice Thrown when the number of shares received is below the minimum required
    /// @param shares The actual number of shares received
    /// @param minShares The minimum number of shares required
    /// @custom:error AaveV4BorrowFuseInsufficientShares
    error AaveV4BorrowFuseInsufficientShares(uint256 shares, uint256 minShares);

    /// @notice Thrown when the number of shares repaid is below the minimum required
    /// @param sharesRepaid The actual number of shares repaid
    /// @param minSharesRepaid The minimum number of shares required to repay
    /// @custom:error AaveV4BorrowFuseInsufficientSharesRepaid
    error AaveV4BorrowFuseInsufficientSharesRepaid(uint256 sharesRepaid, uint256 minSharesRepaid);

    /// @notice Thrown when the reserve's underlying asset does not match the expected asset
    /// @param reserveId The reserve ID that was queried
    /// @param expected The asset address provided in the fuse data
    /// @param actual The underlying asset address returned by the Spoke for the given reserveId
    error AaveV4BorrowFuseReserveAssetMismatch(uint256 reserveId, address expected, address actual);

    /// @notice Constructor for AaveV4BorrowFuse
    /// @param marketId_ The Market ID associated with the Fuse
    constructor(uint256 marketId_) {
        if (marketId_ == 0) {
            revert AaveV4BorrowFuseInvalidMarketId();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Enters (borrows) assets from Aave V4 protocol via a Spoke contract
    /// @param data_ Enter data containing spoke, asset, reserveId, and amount to borrow
    /// @return asset The address of the borrowed asset
    /// @return amount The amount of assets borrowed
    /// @custom:revert AaveV4BorrowFuseUnsupportedSubstrate When (spoke, reserveId) is not granted with canBorrow
    /// @custom:revert AaveV4BorrowFuseReserveAssetMismatch When the reserve underlying differs from asset
    /// @custom:revert AaveV4BorrowFuseInsufficientShares When received shares are below minShares
    function enter(AaveV4BorrowFuseEnterData memory data_) public returns (address asset, uint256 amount) {
        if (data_.amount == 0) {
            return (data_.asset, 0);
        }

        if (!AaveV4SubstrateLib.canBorrow(MARKET_ID, data_.spoke, data_.reserveId)) {
            revert AaveV4BorrowFuseUnsupportedSubstrate("enter", data_.spoke, data_.reserveId);
        }
        _validateReserveAsset(IAaveV4Spoke(data_.spoke), data_.reserveId, data_.asset);

        (uint256 shares, ) = IAaveV4Spoke(data_.spoke).borrow(data_.reserveId, data_.amount, address(this));

        if (shares < data_.minShares) {
            revert AaveV4BorrowFuseInsufficientShares(shares, data_.minShares);
        }

        emit AaveV4BorrowFuseEnter(VERSION, data_.spoke, data_.asset, data_.reserveId, data_.amount, shares);

        return (data_.asset, data_.amount);
    }

    /// @notice Enters (borrows) assets from Aave V4 protocol using transient storage for inputs
    /// @dev Reads spoke (0), asset (1), reserveId (2), amount (3), minShares (4) from transient storage
    function enterTransient() external {
        AaveV4BorrowFuseEnterData memory data = AaveV4BorrowFuseEnterData({
            spoke: PlasmaVaultConfigLib.bytes32ToAddress(TransientStorageLib.getInput(VERSION, 0)),
            asset: PlasmaVaultConfigLib.bytes32ToAddress(TransientStorageLib.getInput(VERSION, 1)),
            reserveId: TypeConversionLib.toUint256(TransientStorageLib.getInput(VERSION, 2)),
            amount: TypeConversionLib.toUint256(TransientStorageLib.getInput(VERSION, 3)),
            minShares: TypeConversionLib.toUint256(TransientStorageLib.getInput(VERSION, 4))
        });

        (address returnedAsset, uint256 returnedAmount) = enter(data);

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(returnedAsset);
        outputs[1] = TypeConversionLib.toBytes32(returnedAmount);

        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Exits (repays) assets to Aave V4 protocol via a Spoke contract
    /// @dev Repayment is capped at the vault balance; the Spoke caps it at the total debt (drawn + premium)
    ///      and never pulls more than the approved amount. Pass amount >= getUserTotalDebt() for a full repay.
    /// @param data_ Exit data containing spoke, asset, reserveId, and amount to repay
    /// @return asset The address of the repaid asset
    /// @return amount The amount of assets repaid
    /// @custom:revert AaveV4BorrowFuseUnsupportedSubstrate When (spoke, reserveId) is not granted
    /// @custom:revert AaveV4BorrowFuseReserveAssetMismatch When the reserve underlying differs from asset
    /// @custom:revert AaveV4BorrowFuseInsufficientSharesRepaid When repaid shares are below minSharesRepaid
    function exit(AaveV4BorrowFuseExitData memory data_) public returns (address asset, uint256 amount) {
        if (data_.amount == 0) {
            return (data_.asset, 0);
        }

        if (!AaveV4SubstrateLib.canSupply(MARKET_ID, data_.spoke, data_.reserveId)) {
            revert AaveV4BorrowFuseUnsupportedSubstrate("exit", data_.spoke, data_.reserveId);
        }
        _validateReserveAsset(IAaveV4Spoke(data_.spoke), data_.reserveId, data_.asset);

        uint256 balance = ERC20(data_.asset).balanceOf(address(this));
        uint256 repayAmount = IporMath.min(balance, data_.amount);

        if (repayAmount == 0) {
            return (data_.asset, 0);
        }

        ERC20(data_.asset).forceApprove(data_.spoke, repayAmount);

        (uint256 sharesRepaid, uint256 repaid) = IAaveV4Spoke(data_.spoke).repay(
            data_.reserveId,
            repayAmount,
            address(this)
        );

        if (sharesRepaid < data_.minSharesRepaid) {
            revert AaveV4BorrowFuseInsufficientSharesRepaid(sharesRepaid, data_.minSharesRepaid);
        }

        emit AaveV4BorrowFuseExit(VERSION, data_.spoke, data_.asset, data_.reserveId, repaid, sharesRepaid);

        return (data_.asset, repaid);
    }

    /// @notice Exits (repays) assets to Aave V4 protocol using transient storage for inputs
    /// @dev Reads spoke (0), asset (1), reserveId (2), amount (3), minSharesRepaid (4) from transient storage
    function exitTransient() external {
        AaveV4BorrowFuseExitData memory data = AaveV4BorrowFuseExitData({
            spoke: PlasmaVaultConfigLib.bytes32ToAddress(TransientStorageLib.getInput(VERSION, 0)),
            asset: PlasmaVaultConfigLib.bytes32ToAddress(TransientStorageLib.getInput(VERSION, 1)),
            reserveId: TypeConversionLib.toUint256(TransientStorageLib.getInput(VERSION, 2)),
            amount: TypeConversionLib.toUint256(TransientStorageLib.getInput(VERSION, 3)),
            minSharesRepaid: TypeConversionLib.toUint256(TransientStorageLib.getInput(VERSION, 4))
        });

        (address returnedAsset, uint256 returnedAmount) = exit(data);

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(returnedAsset);
        outputs[1] = TypeConversionLib.toBytes32(returnedAmount);

        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Validates that the reserve's underlying asset matches the expected asset
    /// @dev Defense-in-depth cross-check of the alpha-provided asset against the granted reserve
    /// @param spoke_ The Aave V4 Spoke contract
    /// @param reserveId_ The reserve ID to validate
    /// @param expectedAsset_ The asset address that the caller expects at this reserveId
    function _validateReserveAsset(IAaveV4Spoke spoke_, uint256 reserveId_, address expectedAsset_) internal view {
        address actual = spoke_.getReserve(reserveId_).underlying;
        if (actual != expectedAsset_) {
            revert AaveV4BorrowFuseReserveAssetMismatch(reserveId_, expectedAsset_, actual);
        }
    }
}
