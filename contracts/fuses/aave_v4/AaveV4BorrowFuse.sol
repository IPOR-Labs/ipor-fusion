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
    /// @notice ERC20 token address to borrow
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
    /// @notice ERC20 token address to repay
    address asset;
    /// @notice Aave V4 reserve identifier within the Spoke
    uint256 reserveId;
    /// @notice Amount of tokens to repay
    uint256 amount;
    /// @notice Minimum number of borrow shares to repay
    uint256 minSharesRepaid;
}

/// @title AaveV4BorrowFuse
/// @author IPOR Labs
/// @notice Fuse for Aave V4 protocol responsible for borrowing and repaying assets via Spoke contracts
/// @dev Executes in PlasmaVault storage context via delegatecall. MUST NOT contain storage variables.
///      Substrates are validated as both Asset and Spoke types using AaveV4SubstrateLib encoding.
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

    /// @notice Thrown when a substrate (asset or spoke) is not authorized for this market
    /// @param action The action being performed ("enter" or "exit")
    /// @param substrate The unauthorized substrate bytes32 value
    error AaveV4BorrowFuseUnsupportedSubstrate(string action, bytes32 substrate);

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
    function enter(AaveV4BorrowFuseEnterData memory data_) public returns (address asset, uint256 amount) {
        if (data_.amount == 0) {
            return (data_.asset, 0);
        }

        _validateSubstrates("enter", data_.asset, data_.spoke);

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
        bytes32 spokeBytes32 = TransientStorageLib.getInput(VERSION, 0);
        bytes32 assetBytes32 = TransientStorageLib.getInput(VERSION, 1);
        bytes32 reserveIdBytes32 = TransientStorageLib.getInput(VERSION, 2);
        bytes32 amountBytes32 = TransientStorageLib.getInput(VERSION, 3);
        bytes32 minSharesBytes32 = TransientStorageLib.getInput(VERSION, 4);

        AaveV4BorrowFuseEnterData memory data = AaveV4BorrowFuseEnterData({
            spoke: PlasmaVaultConfigLib.bytes32ToAddress(spokeBytes32),
            asset: PlasmaVaultConfigLib.bytes32ToAddress(assetBytes32),
            reserveId: TypeConversionLib.toUint256(reserveIdBytes32),
            amount: TypeConversionLib.toUint256(amountBytes32),
            minShares: TypeConversionLib.toUint256(minSharesBytes32)
        });

        (address returnedAsset, uint256 returnedAmount) = enter(data);

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(returnedAsset);
        outputs[1] = TypeConversionLib.toBytes32(returnedAmount);

        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Exits (repays) assets to Aave V4 protocol via a Spoke contract
    /// @param data_ Exit data containing spoke, asset, reserveId, and amount to repay
    /// @return asset The address of the repaid asset
    /// @return amount The amount of assets repaid
    function exit(AaveV4BorrowFuseExitData memory data_) public returns (address asset, uint256 amount) {
        if (data_.amount == 0) {
            return (data_.asset, 0);
        }

        _validateSubstrates("exit", data_.asset, data_.spoke);

        uint256 balance = ERC20(data_.asset).balanceOf(address(this));
        uint256 repayAmount = IporMath.min(balance, data_.amount);

        if (repayAmount == 0) {
            return (data_.asset, 0);
        }

        ERC20(data_.asset).forceApprove(data_.spoke, repayAmount);

        (uint256 sharesRepaid, uint256 repaid) = IAaveV4Spoke(data_.spoke).repay(data_.reserveId, repayAmount, address(this));

        if (sharesRepaid < data_.minSharesRepaid) {
            revert AaveV4BorrowFuseInsufficientSharesRepaid(sharesRepaid, data_.minSharesRepaid);
        }

        emit AaveV4BorrowFuseExit(VERSION, data_.spoke, data_.asset, data_.reserveId, repaid, sharesRepaid);

        return (data_.asset, repaid);
    }

    /// @notice Exits (repays) assets to Aave V4 protocol using transient storage for inputs
    /// @dev Reads spoke (0), asset (1), reserveId (2), amount (3), minSharesRepaid (4) from transient storage
    function exitTransient() external {
        bytes32 spokeBytes32 = TransientStorageLib.getInput(VERSION, 0);
        bytes32 assetBytes32 = TransientStorageLib.getInput(VERSION, 1);
        bytes32 reserveIdBytes32 = TransientStorageLib.getInput(VERSION, 2);
        bytes32 amountBytes32 = TransientStorageLib.getInput(VERSION, 3);
        bytes32 minSharesRepaidBytes32 = TransientStorageLib.getInput(VERSION, 4);

        AaveV4BorrowFuseExitData memory data = AaveV4BorrowFuseExitData({
            spoke: PlasmaVaultConfigLib.bytes32ToAddress(spokeBytes32),
            asset: PlasmaVaultConfigLib.bytes32ToAddress(assetBytes32),
            reserveId: TypeConversionLib.toUint256(reserveIdBytes32),
            amount: TypeConversionLib.toUint256(amountBytes32),
            minSharesRepaid: TypeConversionLib.toUint256(minSharesRepaidBytes32)
        });

        (address returnedAsset, uint256 returnedAmount) = exit(data);

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(returnedAsset);
        outputs[1] = TypeConversionLib.toBytes32(returnedAmount);

        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Validates that both asset and spoke substrates are granted for this market
    /// @param action_ The action being performed (for error message)
    /// @param asset_ The asset address to validate
    /// @param spoke_ The spoke address to validate
    function _validateSubstrates(string memory action_, address asset_, address spoke_) internal view {
        bytes32 assetSubstrate = AaveV4SubstrateLib.encodeAsset(asset_);
        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, assetSubstrate)) {
            revert AaveV4BorrowFuseUnsupportedSubstrate(action_, assetSubstrate);
        }

        bytes32 spokeSubstrate = AaveV4SubstrateLib.encodeSpoke(spoke_);
        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, spokeSubstrate)) {
            revert AaveV4BorrowFuseUnsupportedSubstrate(action_, spokeSubstrate);
        }
    }
}
