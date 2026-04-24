// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IporMath} from "../../libraries/math/IporMath.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IAavePoolDataProvider} from "./ext/IAavePoolDataProvider.sol";
import {IPool} from "./ext/IPool.sol";
import {IPoolAddressesProvider} from "./ext/IPoolAddressesProvider.sol";

/// @notice Structure for entering (repay with aTokens) to the Aave V3 protocol
struct AaveV3RepayWithATokensFuseEnterData {
    /// @notice asset address whose variable debt will be repaid with the caller's aTokens
    address asset;
    /// @notice requested repay amount. The fuse caps it to the caller's current aToken balance
    /// (pass type(uint256).max to let Aave repay the full debt and clear aToken dust).
    uint256 amount;
    /// @notice minimum amount that MUST actually be repaid, otherwise the call reverts.
    /// Protects strategies from prior swap slippage leaving too few aTokens on the vault.
    uint256 minAmount;
}

/// @title Fuse Aave V3 Repay With aTokens protocol responsible for repaying variable debt using the caller's aTokens on the Aave V3 protocol based on preconfigured market substrates
/// @notice Fuse for Aave V3 protocol responsible for calling `IPool.repayWithATokens` so that an existing variable debt position is settled directly against the PlasmaVault's aToken balance, without withdrawing the underlying asset
/// @dev Substrates in this fuse are the assets that are used in the Aave V3 protocol for a given MARKET_ID
/// @dev The operation is terminal; this fuse exposes only `enter()`. Repaying debt has no symmetric inverse — to open a new borrow afterwards, strategies must explicitly call `AaveV3BorrowFuse.enter()`
/// @author IPOR Labs
contract AaveV3RepayWithATokensFuse is IFuseCommon {
    /// @notice interest rate mode = 2 in Aave V3 means variable interest rate.
    uint256 public constant INTEREST_RATE_MODE = 2;

    /// @notice The address of the version of the Fuse
    address public immutable VERSION;
    /// @notice The Market ID associated with the Fuse
    uint256 public immutable MARKET_ID;

    /// @notice The address of the Aave V3 Pool Addresses Provider
    address public immutable AAVE_V3_POOL_ADDRESSES_PROVIDER;

    /// @notice Emitted when entering the Aave V3 repay-with-aTokens fuse
    /// @param version The address of the fuse version
    /// @param asset The address of the asset whose debt was repaid
    /// @param amountRequested The amount passed to the fuse as the repay request (may be type(uint256).max)
    /// @param minAmount The minimum amount required to be repaid (slippage guard)
    /// @param amountRepaid The amount actually repaid by Aave (may be smaller than amountRequested when it is capped to the aToken balance or to the outstanding debt)
    event AaveV3RepayWithATokensFuseEnter(
        address version,
        address asset,
        uint256 amountRequested,
        uint256 minAmount,
        uint256 amountRepaid
    );

    /// @notice Error thrown when an unsupported asset is used in enter operation
    /// @param action The action being performed ("enter")
    /// @param asset The address of the unsupported asset
    error AaveV3RepayWithATokensFuseUnsupportedAsset(string action, address asset);

    /// @notice Error thrown when market ID is zero or invalid
    /// @dev Market ID must be a non-zero value to identify the market configuration
    error AaveV3RepayWithATokensFuseInvalidMarketId();

    /// @notice Error thrown when the Aave V3 Pool Addresses Provider is the zero address
    error AaveV3RepayWithATokensFuseInvalidAddressesProvider();

    /// @notice Error thrown when the actually-repaid amount is strictly below the requested minimum
    /// @param asset The address of the asset whose debt was repaid
    /// @param minAmount The minimum amount that had to be repaid for the call to succeed
    /// @param amountRepaid The amount actually repaid by Aave
    error AaveV3RepayWithATokensFuseRepaidAmountBelowMinimum(address asset, uint256 minAmount, uint256 amountRepaid);

    /// @notice Constructor for AaveV3RepayWithATokensFuse
    /// @param marketId_ The Market ID associated with the Fuse
    /// @param aaveV3PoolAddressesProvider_ The address of the Aave V3 Pool Addresses Provider
    constructor(uint256 marketId_, address aaveV3PoolAddressesProvider_) {
        if (marketId_ == 0) {
            revert AaveV3RepayWithATokensFuseInvalidMarketId();
        }
        if (aaveV3PoolAddressesProvider_ == address(0)) {
            revert AaveV3RepayWithATokensFuseInvalidAddressesProvider();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
        AAVE_V3_POOL_ADDRESSES_PROVIDER = aaveV3PoolAddressesProvider_;
    }

    /// @notice Repays variable debt on Aave V3 by burning the caller's aTokens
    /// @dev The effective repay amount is `min(data_.amount, aTokenBalance)`; `type(uint256).max`
    /// is forwarded to Aave unchanged so that Aave itself repays the full outstanding debt and
    /// cleans any residual aToken dust.
    /// @dev `data_.minAmount` is a slippage guard against prior swaps leaving too few aTokens on
    /// the vault: if Aave reports a repaid amount strictly below `minAmount`, the call reverts.
    /// @dev No token approval is needed: `repayWithATokens` burns aTokens directly from the caller
    /// (the PlasmaVault under delegatecall) through the aToken's Pool-only burn path.
    /// @param data_ Enter data containing the asset address, the requested repay amount and the minimum repay amount
    function enter(AaveV3RepayWithATokensFuseEnterData memory data_) external {
        if (data_.amount == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.asset)) {
            revert AaveV3RepayWithATokensFuseUnsupportedAsset("enter", data_.asset);
        }

        IPoolAddressesProvider addressesProvider = IPoolAddressesProvider(AAVE_V3_POOL_ADDRESSES_PROVIDER);

        (address aTokenAddress, , ) = IAavePoolDataProvider(addressesProvider.getPoolDataProvider())
            .getReserveTokensAddresses(data_.asset);

        uint256 aTokenBalance = ERC20(aTokenAddress).balanceOf(address(this));

        /// @dev for type(uint256).max forward unchanged so Aave clears dust; otherwise cap to balance
        uint256 finalAmount = data_.amount == type(uint256).max
            ? type(uint256).max
            : IporMath.min(data_.amount, aTokenBalance);

        if (finalAmount == 0) {
            if (data_.minAmount > 0) {
                revert AaveV3RepayWithATokensFuseRepaidAmountBelowMinimum(data_.asset, data_.minAmount, 0);
            }
            return;
        }

        uint256 repaidAmount = IPool(addressesProvider.getPool()).repayWithATokens(
            data_.asset,
            finalAmount,
            INTEREST_RATE_MODE
        );

        if (repaidAmount < data_.minAmount) {
            revert AaveV3RepayWithATokensFuseRepaidAmountBelowMinimum(data_.asset, data_.minAmount, repaidAmount);
        }

        emit AaveV3RepayWithATokensFuseEnter(VERSION, data_.asset, data_.amount, data_.minAmount, repaidAmount);
    }
}
