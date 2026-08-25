// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IporMath} from "../../libraries/math/IporMath.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IFuseInstantWithdraw} from "../IFuseInstantWithdraw.sol";
import {AaveV4SubstrateLib, AaveV4ReserveGrant} from "./AaveV4SubstrateLib.sol";
import {IAaveV4Spoke} from "./ext/IAaveV4Spoke.sol";

/// @dev Data structure for entering (supply) the Aave V4 protocol
struct AaveV4SupplyFuseEnterData {
    /// @notice Aave V4 Spoke contract address
    address spoke;
    /// @notice ERC20 token address to supply (cross-checked against the reserve's underlying)
    address asset;
    /// @notice Aave V4 reserve identifier within the Spoke
    uint256 reserveId;
    /// @notice Amount of tokens to supply
    uint256 amount;
    /// @notice Minimum amount of supply shares expected to receive
    uint256 minShares;
}

/// @dev Data structure for exiting (withdraw) from the Aave V4 protocol
struct AaveV4SupplyFuseExitData {
    /// @notice Aave V4 Spoke contract address
    address spoke;
    /// @notice ERC20 token address to withdraw (cross-checked against the reserve's underlying)
    address asset;
    /// @notice Aave V4 reserve identifier within the Spoke
    uint256 reserveId;
    /// @notice Amount of tokens to withdraw
    uint256 amount;
    /// @notice Minimum amount of tokens expected to withdraw
    uint256 minAmount;
}

/// @title AaveV4SupplyFuse
/// @author IPOR Labs
/// @notice Fuse for Aave V4 protocol responsible for supplying and withdrawing assets via Spoke contracts
/// @dev Executes in PlasmaVault storage context via delegatecall. MUST NOT contain storage variables.
///      Permissions come from Reserve substrates (spoke, reserveId, flags) encoded with AaveV4SubstrateLib:
///      - enter/exit require any granted substrate for the (spoke, reserveId) pair,
///      - instantWithdraw additionally requires that no granted variant of the pair has isCollateral and that
///        the reserve is not currently enabled as collateral on the Spoke, so user withdrawals can never lower
///        the health factor of a leveraged position.
///      Supplying does not enable the reserve as collateral in Aave V4 - see AaveV4CollateralFuse.
contract AaveV4SupplyFuse is IFuseCommon, IFuseInstantWithdraw {
    using SafeERC20 for ERC20;

    /// @notice The address of the version of the Fuse
    address public immutable VERSION;
    /// @notice The Market ID associated with the Fuse
    uint256 public immutable MARKET_ID;

    /// @notice Emitted when entering the Aave V4 supply fuse
    /// @param version The address of the fuse version
    /// @param spoke The Aave V4 Spoke contract address
    /// @param asset The address of the asset supplied
    /// @param reserveId The reserve identifier
    /// @param shares The amount of supply shares received
    event AaveV4SupplyFuseEnter(address version, address spoke, address asset, uint256 reserveId, uint256 shares);

    /// @notice Emitted when exiting the Aave V4 supply fuse
    /// @param version The address of the fuse version
    /// @param spoke The Aave V4 Spoke contract address
    /// @param asset The address of the asset withdrawn
    /// @param reserveId The reserve identifier
    /// @param amount The amount of the asset withdrawn
    event AaveV4SupplyFuseExit(address version, address spoke, address asset, uint256 reserveId, uint256 amount);

    /// @notice Emitted when exiting the Aave V4 supply fuse fails during instant withdraw
    /// @param version The address of the fuse version
    /// @param spoke The Aave V4 Spoke contract address
    /// @param asset The address of the asset
    /// @param reserveId The reserve identifier
    /// @param amount The amount that was attempted to withdraw
    event AaveV4SupplyFuseExitFailed(address version, address spoke, address asset, uint256 reserveId, uint256 amount);

    /// @notice Thrown when market ID is zero or invalid
    /// @custom:error AaveV4SupplyFuseInvalidMarketId
    error AaveV4SupplyFuseInvalidMarketId();

    /// @notice Thrown when received shares are below the minimum required
    /// @param receivedShares The amount of shares actually received
    /// @param minShares The minimum amount of shares required
    /// @custom:error AaveV4SupplyFuseInsufficientShares
    error AaveV4SupplyFuseInsufficientShares(uint256 receivedShares, uint256 minShares);

    /// @notice Thrown when withdrawn amount is below the minimum required
    /// @param withdrawnAmount The amount actually withdrawn
    /// @param minAmount The minimum amount required
    /// @custom:error AaveV4SupplyFuseInsufficientAmount
    error AaveV4SupplyFuseInsufficientAmount(uint256 withdrawnAmount, uint256 minAmount);

    /// @notice Thrown when the (spoke, reserveId) pair is not granted for this market
    /// @param action The action being performed ("enter" or "exit")
    /// @param spoke The Spoke contract address
    /// @param reserveId The reserve identifier
    error AaveV4SupplyFuseUnsupportedSubstrate(string action, address spoke, uint256 reserveId);

    /// @notice Thrown when instant withdraw is attempted on a reserve that may be, or currently is, collateral
    /// @param spoke The Spoke contract address
    /// @param reserveId The reserve identifier
    error AaveV4SupplyFuseInstantWithdrawNotAllowed(address spoke, uint256 reserveId);

    /// @notice Thrown when instant withdraw params are malformed
    /// @custom:error AaveV4SupplyFuseInvalidParams
    error AaveV4SupplyFuseInvalidParams();

    /// @notice Thrown when the reserve's underlying asset does not match the expected asset
    /// @param reserveId The reserve ID that was queried
    /// @param expected The asset address provided in the fuse data
    /// @param actual The underlying asset address returned by the Spoke for the given reserveId
    error AaveV4SupplyFuseReserveAssetMismatch(uint256 reserveId, address expected, address actual);

    /// @notice Constructor for AaveV4SupplyFuse
    /// @param marketId_ The Market ID associated with the Fuse
    constructor(uint256 marketId_) {
        if (marketId_ == 0) {
            revert AaveV4SupplyFuseInvalidMarketId();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Enters (supplies) assets to Aave V4 protocol via a Spoke contract
    /// @param data_ Enter data containing spoke, asset, reserveId, amount, and minShares
    /// @return asset The address of the supplied asset
    /// @return amount The amount of assets supplied
    /// @custom:revert AaveV4SupplyFuseUnsupportedSubstrate When (spoke, reserveId) is not granted
    /// @custom:revert AaveV4SupplyFuseReserveAssetMismatch When the reserve underlying differs from asset
    /// @custom:revert AaveV4SupplyFuseInsufficientShares When received shares are below minShares
    function enter(AaveV4SupplyFuseEnterData memory data_) public returns (address asset, uint256 amount) {
        if (data_.amount == 0) {
            return (data_.asset, 0);
        }

        if (!AaveV4SubstrateLib.canSupply(MARKET_ID, data_.spoke, data_.reserveId)) {
            revert AaveV4SupplyFuseUnsupportedSubstrate("enter", data_.spoke, data_.reserveId);
        }
        _validateReserveAsset(IAaveV4Spoke(data_.spoke), data_.reserveId, data_.asset);

        uint256 finalAmount = IporMath.min(ERC20(data_.asset).balanceOf(address(this)), data_.amount);

        if (finalAmount == 0) {
            return (data_.asset, 0);
        }

        ERC20(data_.asset).forceApprove(data_.spoke, finalAmount);

        (uint256 shares, ) = IAaveV4Spoke(data_.spoke).supply(data_.reserveId, finalAmount, address(this));

        if (shares < data_.minShares) {
            revert AaveV4SupplyFuseInsufficientShares(shares, data_.minShares);
        }

        emit AaveV4SupplyFuseEnter(VERSION, data_.spoke, data_.asset, data_.reserveId, shares);

        return (data_.asset, finalAmount);
    }

    /// @notice Enters (supplies) assets to Aave V4 protocol using transient storage for inputs
    /// @dev Reads spoke (0), asset (1), reserveId (2), amount (3), minShares (4) from transient storage
    function enterTransient() external {
        AaveV4SupplyFuseEnterData memory data = AaveV4SupplyFuseEnterData({
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

    /// @notice Exits (withdraws) assets from Aave V4 protocol via a Spoke contract
    /// @param data_ Exit data containing spoke, asset, reserveId, amount, and minAmount
    /// @return asset The address of the withdrawn asset
    /// @return amount The amount of assets withdrawn
    /// @custom:revert AaveV4SupplyFuseInsufficientAmount When withdrawn amount is below minAmount
    function exit(AaveV4SupplyFuseExitData calldata data_) public returns (address asset, uint256 amount) {
        return _exit(data_, false);
    }

    /// @notice Exits (withdraws) assets from Aave V4 protocol using transient storage for inputs
    /// @dev Reads spoke (0), asset (1), reserveId (2), amount (3), minAmount (4) from transient storage
    function exitTransient() external {
        AaveV4SupplyFuseExitData memory data = AaveV4SupplyFuseExitData({
            spoke: PlasmaVaultConfigLib.bytes32ToAddress(TransientStorageLib.getInput(VERSION, 0)),
            asset: PlasmaVaultConfigLib.bytes32ToAddress(TransientStorageLib.getInput(VERSION, 1)),
            reserveId: TypeConversionLib.toUint256(TransientStorageLib.getInput(VERSION, 2)),
            amount: TypeConversionLib.toUint256(TransientStorageLib.getInput(VERSION, 3)),
            minAmount: TypeConversionLib.toUint256(TransientStorageLib.getInput(VERSION, 4))
        });

        (address returnedAsset, uint256 returnedAmount) = _exit(data, false);

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(returnedAsset);
        outputs[1] = TypeConversionLib.toBytes32(returnedAmount);

        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Performs instant withdrawal from Aave V4 protocol with exception handling
    /// @dev Only reserves that are neither granted as collateral nor currently enabled as collateral are eligible.
    ///      Aave V4 withdrawals have no slippage (the Spoke returns exactly min(amount, supplied)), so params_[4] is
    ///      reserved and NOT enforced on this path: the requested amount is dynamic (set by the vault per withdrawal)
    ///      and a static minimum would revert every user withdrawal smaller than it.
    /// @param params_ Array of parameters: [0] amount, [1] asset address, [2] spoke address, [3] reserveId, [4] reserved (0)
    /// @custom:revert AaveV4SupplyFuseInvalidParams When fewer than 5 params are provided
    /// @custom:revert AaveV4SupplyFuseInstantWithdrawNotAllowed When the reserve may be, or currently is, collateral
    function instantWithdraw(bytes32[] calldata params_) external override {
        if (params_.length < 5) {
            revert AaveV4SupplyFuseInvalidParams();
        }

        _exit(
            AaveV4SupplyFuseExitData({
                spoke: PlasmaVaultConfigLib.bytes32ToAddress(params_[2]),
                asset: PlasmaVaultConfigLib.bytes32ToAddress(params_[1]),
                reserveId: uint256(params_[3]),
                amount: uint256(params_[0]),
                minAmount: 0
            }),
            true
        );
    }

    /// @notice Internal function to exit (withdraw) assets from Aave V4 protocol
    /// @param data_ Exit data containing spoke, asset, reserveId, and amount
    /// @param catchExceptions_ Whether to catch exceptions during withdrawal (instant withdraw path)
    /// @return asset The address of the withdrawn asset
    /// @return amount The amount of assets withdrawn
    function _exit(
        AaveV4SupplyFuseExitData memory data_,
        bool catchExceptions_
    ) internal returns (address asset, uint256 amount) {
        if (data_.amount == 0) {
            return (data_.asset, 0);
        }

        AaveV4ReserveGrant memory grant = AaveV4SubstrateLib.getReserveGrant(MARKET_ID, data_.spoke, data_.reserveId);

        if (!grant.granted) {
            revert AaveV4SupplyFuseUnsupportedSubstrate("exit", data_.spoke, data_.reserveId);
        }

        if (catchExceptions_) {
            _validateInstantWithdrawAllowed(grant, data_.spoke, data_.reserveId);
        }

        _validateReserveAsset(IAaveV4Spoke(data_.spoke), data_.reserveId, data_.asset);

        uint256 supplyAssets = IAaveV4Spoke(data_.spoke).getUserSuppliedAssets(data_.reserveId, address(this));

        if (supplyAssets == 0) {
            return (data_.asset, 0);
        }

        uint256 finalAmount = IporMath.min(supplyAssets, data_.amount);

        if (finalAmount == 0) {
            return (data_.asset, 0);
        }

        if (catchExceptions_) {
            /// @dev no minAmount check on the instant path: a revert here would not be caught and would block
            ///      every user withdrawal that needs market liquidity (see instantWithdraw)
            try IAaveV4Spoke(data_.spoke).withdraw(data_.reserveId, finalAmount, address(this)) returns (
                uint256,
                uint256 withdrawnAmount
            ) {
                emit AaveV4SupplyFuseExit(VERSION, data_.spoke, data_.asset, data_.reserveId, withdrawnAmount);
                return (data_.asset, withdrawnAmount);
            } catch {
                emit AaveV4SupplyFuseExitFailed(VERSION, data_.spoke, data_.asset, data_.reserveId, finalAmount);
                return (data_.asset, 0);
            }
        } else {
            (, uint256 withdrawnAmount) = IAaveV4Spoke(data_.spoke).withdraw(
                data_.reserveId,
                finalAmount,
                address(this)
            );
            if (withdrawnAmount < data_.minAmount) {
                revert AaveV4SupplyFuseInsufficientAmount(withdrawnAmount, data_.minAmount);
            }
            emit AaveV4SupplyFuseExit(VERSION, data_.spoke, data_.asset, data_.reserveId, withdrawnAmount);
            return (data_.asset, withdrawnAmount);
        }
    }

    /// @notice Validates that a reserve may serve user withdrawals
    /// @dev Two independent guards: the grant must not allow collateral (configuration intent) and the reserve
    ///      must not currently be enabled as collateral on the Spoke (on-chain truth, e.g. enabled before the grant
    ///      was downgraded). Either one failing means a user withdrawal could touch the vault's collateral.
    /// @param grant_ The effective grant of the reserve
    /// @param spoke_ The Aave V4 Spoke contract address
    /// @param reserveId_ The reserve identifier
    function _validateInstantWithdrawAllowed(
        AaveV4ReserveGrant memory grant_,
        address spoke_,
        uint256 reserveId_
    ) internal view {
        if (grant_.isCollateral) {
            revert AaveV4SupplyFuseInstantWithdrawNotAllowed(spoke_, reserveId_);
        }

        (bool usingAsCollateral, ) = IAaveV4Spoke(spoke_).getUserReserveStatus(reserveId_, address(this));
        if (usingAsCollateral) {
            revert AaveV4SupplyFuseInstantWithdrawNotAllowed(spoke_, reserveId_);
        }
    }

    /// @notice Validates that the reserve's underlying asset matches the expected asset
    /// @dev Defense-in-depth cross-check of the alpha-provided asset against the granted reserve
    /// @param spoke_ The Aave V4 Spoke contract
    /// @param reserveId_ The reserve ID to validate
    /// @param expectedAsset_ The asset address that the caller expects at this reserveId
    function _validateReserveAsset(IAaveV4Spoke spoke_, uint256 reserveId_, address expectedAsset_) internal view {
        address actual = spoke_.getReserve(reserveId_).underlying;
        if (actual != expectedAsset_) {
            revert AaveV4SupplyFuseReserveAssetMismatch(reserveId_, expectedAsset_, actual);
        }
    }
}
