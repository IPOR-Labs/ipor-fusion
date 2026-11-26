// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {ReserveVaultStorageLib} from "./lib/ReserveVaultStorageLib.sol";
import {ReserveVaultBoostLib} from "./lib/ReserveVaultBoostLib.sol";

/// @title ReserveVaultBalanceFuse
/// @notice Balance fuse of the reserve vault market: values what the reserve vault deposited into its member vaults at
///         the principal recorded in the reserve vault's ledger, in USD with 18 decimals
/// @dev Runs by delegatecall in the reserve vault. The substrates of `MARKET_ID` are the member vault addresses. The
///      principal of a member vault is the amount of the member vault's asset that the reserve vault deposited into it
///      through `ReserveVaultSupplyFuse` and has not withdrawn yet (`ReserveVaultStorageLib`). Called directly on the
///      fuse, `balanceOf` reads the fuse's own empty storage and returns 0.
/// @dev Principal, not market value. The fuse never reads the reserve vault's shares in a member vault nor the member
///      vault's share price. A gain or a loss of a member vault does not change this balance, so the reserve vault's
///      share price does not move with the share prices of its member vaults.
/// @dev Iteration. The substrates of `MARKET_ID` are read in order and a member vault with zero principal is skipped
///      before any external call: a granted member vault that holds no principal costs one storage read and cannot make
///      the balance revert. For a member vault with principal the fuse reads the member vault's `asset()` and the price
///      of that asset from the reserve vault's price oracle middleware. Substrate grants reject duplicates, so each
///      member vault is counted once.
/// @dev Conversion. The principal held in the reserve vault's underlying asset (member vaults whose `asset()` equals
///      `IERC4626(address(this)).asset()`) is summed over the member vaults and converted to USD once, rounded up, with
///      `ReserveVaultBoostLib.convertToUsdWadRoundUp` and the underlying's price from the reserve vault's oracle. A
///      principal held in any other asset is converted with the same function separately for each member vault.
///      Why up: `PlasmaVaultMarketsLib.updateMarketsBalances` converts the USD balance back to the underlying with
///      floor divisions, so a floor here would lose one wei of NAV with no loss behind it. Example: a principal of
///      100000001 of a 6-decimal underlying at a price of 0.999873211457913207 would be booked as 100000000.
///      Why once: rounding every member vault up separately can book more than the summed principal near the edge of
///      the precision domain, while one conversion of the sum stays exact inside it.
/// @dev Precision domain. Let d be the decimals of the underlying (d <= 18), pd the decimals of its price. When
///      price * 10^(18 - d) >= 10^pd, i.e. one wei of the underlying is worth at least one USD WAD unit, the vault books
///      back exactly the summed principal, whatever the number of member vaults. A 6-decimal underlying is inside the
///      domain at any price of at least 1e-12 USD. Outside the domain no exact representation exists and the summed
///      principal can be over-booked by less than the value of one USD WAD unit expressed in the underlying: an
///      18-decimal underlying at 0.1 USD books 10 wei for a principal of 1 wei. Above 18 decimals the vault books only
///      multiples of 10^(d - 18) wei, so the principal is first rounded up to that grain. In every case the summed
///      principal is never booked below its amount. Exact bounds: `ReserveVaultBoostLib.convertToUsdWadRoundUp`.
/// @dev Other assets. A principal held in an asset other than the underlying is valued at that asset's price, and the
///      vault converts the USD value into the underlying at the underlying's price. The booked amount is then a market
///      value of that principal, not an exact amount; rounding up adds less than one USD WAD unit per member vault.
/// @dev Revoked substrate. A member vault removed from the substrates of `MARKET_ID` while its principal is non-zero is
///      no longer valued: the market balance drops by its principal while the ledger keeps it, and granting the member
///      vault again restores it. Revoking a member vault that still holds principal is a configuration error; the fuse
///      does not guard against it.
/// @dev Reverts instead of valuing at zero: a member vault with principal whose `asset()` reverts, an asset without a
///      price source in the middleware, a zero price (`ReserveVaultBoostLib.ReserveVaultUsdConversionZeroPrice`) and an
///      arithmetic overflow make `balanceOf` revert.
/// @custom:security Unrecoverable principal stays booked. When a member vault cannot repay its principal (its assets
///      are lost or locked), this balance still shows the full principal and the reserve vault's share price stays
///      unchanged, because the family has no write-off path. Depositors who leave the reserve vault are paid at that
///      price and the shortfall falls on those who stay. This is a known and accepted design property: the reserve
///      vault's depositors carry the credit risk of the member vaults without seeing it in the share price.
/// @author IPOR Labs
contract ReserveVaultBalanceFuse is IMarketBalanceFuse {
    /// @notice Address of this fuse contract version
    /// @dev Immutable value set in the constructor, used for tracking and versioning
    address public immutable VERSION;

    /// @notice Market ID this fuse operates on
    /// @dev Immutable value set in the constructor; its substrates are the member vault addresses
    uint256 public immutable MARKET_ID;

    /// @notice Initializes the fuse with the market whose substrates are the member vaults
    /// @param marketId_ The market ID of the reserve vault market
    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Returns the reserve vault's balance in the member vaults of `MARKET_ID`: the recorded principal in USD
    /// @dev Skips every member vault with zero principal before any external call, sums the principal held in the
    ///      reserve vault's underlying and converts it once, converts a principal held in another asset per member vault;
    ///      every conversion rounds up (see the contract notes for the precision domain).
    /// @return balance The recorded principal of all member vaults in USD, in WAD (18 decimals), rounded up
    function balanceOf() external view override returns (uint256 balance) {
        bytes32[] memory memberVaults = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = memberVaults.length;

        if (len == 0) {
            return 0;
        }

        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();
        address underlying = IERC4626(address(this)).asset();

        uint256 underlyingPrincipal;
        uint256 principal;
        address memberVault;
        address memberVaultAsset;

        for (uint256 i; i < len; ++i) {
            memberVault = PlasmaVaultConfigLib.bytes32ToAddress(memberVaults[i]);
            principal = ReserveVaultStorageLib.getPrincipal(memberVault);

            if (principal == 0) {
                continue;
            }

            memberVaultAsset = IERC4626(memberVault).asset();

            if (memberVaultAsset == underlying) {
                underlyingPrincipal += principal;
            } else {
                balance += _convertToUsdWad(priceOracleMiddleware, memberVaultAsset, principal);
            }
        }

        if (underlyingPrincipal != 0) {
            balance += _convertToUsdWad(priceOracleMiddleware, underlying, underlyingPrincipal);
        }
    }

    /// @notice Converts an amount of an asset to USD in WAD, rounded up, at the price of the reserve vault's oracle
    /// @param priceOracleMiddleware_ The reserve vault's price oracle middleware
    /// @param asset_ The asset of the amount
    /// @param amount_ The amount, in the asset's decimals
    /// @return The USD value in WAD (18 decimals), rounded up
    function _convertToUsdWad(
        address priceOracleMiddleware_,
        address asset_,
        uint256 amount_
    ) private view returns (uint256) {
        (uint256 price, uint256 priceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware_).getAssetPrice(asset_);
        return
            ReserveVaultBoostLib.convertToUsdWadRoundUp(
                amount_,
                price,
                priceDecimals,
                IERC20Metadata(asset_).decimals()
            );
    }
}
