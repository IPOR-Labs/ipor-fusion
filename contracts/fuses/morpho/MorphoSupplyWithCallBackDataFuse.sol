// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";

import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";

import {IMorpho, MarketParams, Id} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "@morpho-org/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {SharesMathLib} from "@morpho-org/morpho-blue/src/libraries/SharesMathLib.sol";
import {MarketParamsLib} from "@morpho-org/morpho-blue/src/libraries/MarketParamsLib.sol";
import {MorphoLib} from "@morpho-org/morpho-blue/src/libraries/periphery/MorphoLib.sol";
import {IFuseInstantWithdraw} from "../IFuseInstantWithdraw.sol";
import {CallbackData} from "../../libraries/CallbackHandlerLib.sol";

/// @notice Structure for entering (supply) to the Morpho protocol with callback data
/// @param morphoMarketId The Morpho market ID to supply to
/// @param maxTokenAmount The maximum amount of tokens to supply
/// @param callbackFuseActionsData Encoded FuseAction array to execute during callback
struct MorphoSupplyFuseEnterData {
    /// @notice The Morpho market ID to supply to
    bytes32 morphoMarketId;
    /// @notice The maximum amount of tokens to supply
    uint256 maxTokenAmount;
    /// @notice Data to be passed to the callback and executed inside the execute function
    bytes callbackFuseActionsData;
}

/// @notice Structure for exiting (withdraw) from the Morpho protocol
/// @param morphoMarketId The Morpho market ID to withdraw from
/// @param amount The amount of assets to withdraw
struct MorphoSupplyFuseExitData {
    /// @notice The Morpho market ID to withdraw from
    bytes32 morphoMarketId;
    /// @notice The amount of assets to withdraw
    uint256 amount;
}

/**
 * @title Fuse for supplying and withdrawing assets from Morpho protocol with callback support
 * @notice Enables supplying assets to Morpho protocol markets and withdrawing them, with support for callback-based actions
 * @dev Substrates in this fuse are the Morpho Market IDs (bytes32) that are configured for a given MARKET_ID.
 *      This fuse supports callback data that allows executing additional FuseActions during the supply operation.
 *      The callback mechanism enables complex multi-step operations within a single transaction.
 */
contract MorphoSupplyWithCallBackDataFuse is IFuseCommon, IFuseInstantWithdraw {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;
    using MorphoBalancesLib for IMorpho;
    using MorphoLib for IMorpho;
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;

    /// @notice Morpho protocol contract address
    /// @dev Immutable constant set at contract deployment
    IMorpho public constant MORPHO = IMorpho(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);

    /// @notice Emitted when assets are supplied to Morpho protocol
    /// @param version The address of this fuse contract version
    /// @param asset The address of the asset supplied
    /// @param market The Morpho market ID
    /// @param amount The amount of assets supplied
    event MorphoSupplyFuseEnter(address version, address asset, bytes32 market, uint256 amount);

    /// @notice Emitted when assets are withdrawn from Morpho protocol
    /// @param version The address of this fuse contract version
    /// @param asset The address of the asset withdrawn
    /// @param market The Morpho market ID
    /// @param amount The amount of assets withdrawn
    event MorphoSupplyFuseExit(address version, address asset, bytes32 market, uint256 amount);

    /// @notice Emitted when withdrawal from Morpho protocol fails
    /// @param version The address of this fuse contract version
    /// @param asset The address of the asset that failed to withdraw
    /// @param market The Morpho market ID
    event MorphoSupplyFuseExitFailed(address version, address asset, bytes32 market);

    /// @notice Thrown when an unsupported Morpho market is accessed
    /// @param action The action being performed ("enter" or "exit")
    /// @param morphoMarketId The Morpho market ID that is not supported
    /// @custom:error MorphoSupplyFuseUnsupportedMarket
    error MorphoSupplyFuseUnsupportedMarket(string action, bytes32 morphoMarketId);

    /// @notice Address of this fuse contract version
    /// @dev Immutable value set in constructor, used for tracking and versioning
    address public immutable VERSION;

    /// @notice Market ID this fuse operates on
    /// @dev Immutable value set in constructor, used to retrieve market substrates (Morpho Market IDs)
    uint256 public immutable MARKET_ID;

    /**
     * @notice Initializes the MorphoSupplyWithCallBackDataFuse with a market ID
     * @param marketId_ The market ID used to identify the Morpho market substrates
     * @dev Sets VERSION to the address of this contract instance for tracking purposes
     */
    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /**
     * @notice Supplies assets to Morpho protocol with callback support
     * @param data_ Struct containing morphoMarketId, maxTokenAmount, and callbackFuseActionsData
     * @return asset The address of the asset supplied
     * @return market The Morpho market ID
     * @return amount The amount of assets actually supplied
     * @dev This function:
     *      1. Validates that maxTokenAmount is not zero (returns early if zero)
     *      2. Validates that the Morpho market ID is granted for this market
     *      3. Retrieves market parameters from Morpho
     *      4. Approves tokens for Morpho protocol
     *      5. Calls Morpho.supply() with callback data encoded as CallbackData struct
     *      6. Emits MorphoSupplyFuseEnter event with supplied amount
     *      The callback data allows executing additional FuseActions during the supply operation.
     */
    function enter(
        MorphoSupplyFuseEnterData memory data_
    ) public returns (address asset, bytes32 market, uint256 amount) {
        if (data_.maxTokenAmount == 0) {
            return (address(0), bytes32(0), 0);
        }

        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, data_.morphoMarketId)) {
            revert MorphoSupplyFuseUnsupportedMarket("enter", data_.morphoMarketId);
        }

        MarketParams memory marketParams = MORPHO.idToMarketParams(Id.wrap(data_.morphoMarketId));

        ERC20(marketParams.loanToken).forceApprove(address(MORPHO), data_.maxTokenAmount);

        (uint256 assetsSupplied, ) = MORPHO.supply(
            marketParams,
            data_.maxTokenAmount,
            0,
            address(this),
            abi.encode(
                CallbackData({
                    asset: marketParams.loanToken,
                    addressToApprove: address(MORPHO),
                    amountToApprove: data_.maxTokenAmount,
                    actionData: data_.callbackFuseActionsData
                })
            )
        );

        asset = marketParams.loanToken;
        market = data_.morphoMarketId;
        amount = assetsSupplied;

        emit MorphoSupplyFuseEnter(VERSION, asset, market, amount);
    }

    /**
     * @notice Withdraws assets from Morpho protocol
     * @param data_ Struct containing morphoMarketId and amount to withdraw
     * @return asset The address of the asset withdrawn
     * @return market The Morpho market ID
     * @return amount The amount of assets actually withdrawn
     * @dev Calls internal _exit() function without exception handling
     */
    function exit(
        MorphoSupplyFuseExitData calldata data_
    ) public returns (address asset, bytes32 market, uint256 amount) {
        return _exit(data_, false);
    }

    /**
     * @notice Instant withdraw assets from Morpho protocol (with exception handling)
     * @param params_ Array of parameters: params_[0] = amount in underlying asset, params_[1] = Morpho market ID
     * @dev This function is called during instant withdrawal scenarios and catches exceptions to prevent reverts
     */
    function instantWithdraw(bytes32[] calldata params_) external override {
        uint256 amount = uint256(params_[0]);

        bytes32 morphoMarketId = params_[1];

        _exit(MorphoSupplyFuseExitData(morphoMarketId, amount), true);
    }

    /**
     * @notice Internal function to withdraw assets from Morpho protocol
     * @param data_ Struct containing morphoMarketId and amount to withdraw
     * @param catchExceptions_ If true, catches exceptions during withdrawal and emits failure event
     * @return asset The address of the asset withdrawn
     * @return market The Morpho market ID
     * @return amount The amount of assets actually withdrawn
     * @dev This function:
     *      1. Validates that amount is not zero (returns early if zero)
     *      2. Validates that the Morpho market ID is granted for this market
     *      3. Retrieves market parameters and calculates available shares
     *      4. Determines withdrawal amount (full shares if amount >= max, partial otherwise)
     *      5. Calls _performWithdraw() to execute the withdrawal
     */
    function _exit(
        MorphoSupplyFuseExitData memory data_,
        bool catchExceptions_
    ) internal returns (address asset, bytes32 market, uint256 amount) {
        if (data_.amount == 0) {
            return (address(0), bytes32(0), 0);
        }

        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, data_.morphoMarketId)) {
            revert MorphoSupplyFuseUnsupportedMarket("exit", data_.morphoMarketId);
        }

        MarketParams memory marketParams = MORPHO.idToMarketParams(Id.wrap(data_.morphoMarketId));
        Id id = marketParams.id();

        MORPHO.accrueInterest(marketParams);

        uint256 totalSupplyAssets = MORPHO.totalSupplyAssets(id);
        uint256 totalSupplyShares = MORPHO.totalSupplyShares(id);

        uint256 shares = MORPHO.supplyShares(id, address(this));

        if (shares == 0) {
            return (address(0), bytes32(0), 0);
        }

        uint256 assetsMax = shares.toAssetsDown(totalSupplyAssets, totalSupplyShares);

        if (assetsMax == 0) {
            return (address(0), bytes32(0), 0);
        }

        asset = marketParams.loanToken;
        market = data_.morphoMarketId;

        if (data_.amount >= assetsMax) {
            amount = _performWithdraw(marketParams, data_.morphoMarketId, 0, shares, catchExceptions_);
        } else {
            amount = _performWithdraw(marketParams, data_.morphoMarketId, data_.amount, 0, catchExceptions_);
        }
    }

    /**
     * @notice Performs the actual withdrawal from Morpho protocol
     * @param marketParams_ The Morpho market parameters
     * @param morphoMarketId_ The Morpho market ID
     * @param assets_ The amount of assets to withdraw (0 if using shares)
     * @param shares_ The amount of shares to withdraw (0 if using assets)
     * @param catchExceptions_ If true, catches exceptions and emits failure event instead of reverting
     * @return amount The amount of assets actually withdrawn
     * @dev This function handles both asset-based and share-based withdrawals.
     *      If catchExceptions_ is true, it uses try-catch to handle failures gracefully.
     */
    function _performWithdraw(
        MarketParams memory marketParams_,
        bytes32 morphoMarketId_,
        uint256 assets_,
        uint256 shares_,
        bool catchExceptions_
    ) private returns (uint256 amount) {
        if (catchExceptions_) {
            try MORPHO.withdraw(marketParams_, assets_, shares_, address(this), address(this)) returns (
                uint256 assetsWithdrawn,
                uint256 /* sharesWithdrawn */
            ) {
                amount = assetsWithdrawn;
                emit MorphoSupplyFuseExit(VERSION, marketParams_.loanToken, morphoMarketId_, amount);
            } catch {
                /// @dev if withdraw failed, continue with the next step
                amount = 0;
                emit MorphoSupplyFuseExitFailed(VERSION, marketParams_.loanToken, morphoMarketId_);
            }
        } else {
            (uint256 assetsWithdrawn, ) = MORPHO.withdraw(
                marketParams_,
                assets_,
                shares_,
                address(this),
                address(this)
            );
            emit MorphoSupplyFuseExit(VERSION, marketParams_.loanToken, morphoMarketId_, assetsWithdrawn);
        }
    }
}
