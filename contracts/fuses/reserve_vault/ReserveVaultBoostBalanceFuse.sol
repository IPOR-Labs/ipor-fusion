// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {UniversalReader, ReadResult} from "../../universal_reader/UniversalReader.sol";
import {ReserveVaultBoostLib} from "./lib/ReserveVaultBoostLib.sol";

/// @title ReserveVaultBoostBalanceFuse
/// @notice Balance fuse of the reserve vault boost market of a member vault: returns the transient boost that the
///         reserve vaults hold for this member vault, as a USD value in WAD (18 decimals) rounded up
/// @dev Context. The fuse runs by delegatecall in the member vault (A), so `address(this)` is A. The substrates of
///      `MARKET_ID` are reserve vault addresses (C) as bytes32. While C exits from A at a loss, C stores a boost X, in
///      A's underlying asset, in its own transient storage under `ReserveVaultBoostLib.boostSlot(A)` and refreshes this
///      market in A, so that A's total assets include X while C withdraws its principal. C then clears X and refreshes
///      the market again. Outside that window X is 0 and the fuse returns 0.
///      The boost is the normal exit path, not a loss-only path. X is sized to cover the gap between C's whole
///      position in A and C's whole principal, and that gap is often just rounding: C's deposit rounds shares down, so
///      right after an enter at almost any share price the position is worth the principal minus a few wei. A boost
///      of at least 1 wei is therefore needed on almost every exit without a real gain, and every member vault needs
///      this market and C's refresh role configured, not only vaults that are expected to lose value.
/// @dev Read path. For each substrate the fuse calls `UniversalReader(C).read(VERSION, abi.encodeCall(readBoost, (A)))`.
///      C static-calls itself and runs `readBoost` of this fuse's code by delegatecall in C's context, so the `tload`
///      in `ReserveVaultBoostLib.getBoost` reads C's transient storage (`tload` is allowed in a static context). C does
///      not register this fuse: `UniversalReader.read` only rejects the zero target. `read` has no reentrancy guard,
///      so the read works while C is inside its own `execute`.
/// @dev Valuation. The boosts of all substrates are summed in A's underlying asset and converted to USD once, with
///      `ReserveVaultBoostLib.convertToUsdWadRoundUp`, A's price oracle middleware and the price of A's underlying
///      asset: the same oracle and asset that `PlasmaVaultMarketsLib.updateMarketsBalances` uses to convert the USD
///      value back. The asset decimals are A's `decimals()` minus `PlasmaVaultLib.DECIMALS_OFFSET`, the exact value the
///      vault passes to that back-conversion. The value is rounded up because the vault converts back with floor
///      divisions; a floor here would book X - 1 and C's withdrawal of the full principal would revert.
/// @dev Precision domain (see `ReserveVaultBoostLib.convertToUsdWadRoundUp`). Let d be the asset decimals, pd the
///      price decimals and booked the amount the vault books for this market. Always booked >= X. For d <= 18, when
///      price * 10^(18 - d) >= 10^pd (one asset wei is worth at least one USD WAD unit), the result is exact,
///      booked == X; a 6-decimal asset is inside the domain at any price of at least 1e-12 USD. Outside the domain the
///      excess is below the asset value of one USD WAD unit (an 18-decimal asset, X = 1 wei and price 0.1 USD book
///      10 wei). For d > 18 the vault books only multiples of 10^(d - 18) wei, so X is first rounded up to that grain.
///      The excess is harmless: C withdraws exactly its requested amount. Summing before the single conversion keeps
///      the result exact inside the domain also when more than one substrate holds a boost.
/// @dev Zero total. When every substrate returns 0, the fuse returns 0 without reading A's asset, decimals or price.
///      Outside an exit window this is the normal case, so a refresh of this market costs only the substrate reads and
///      does not depend on the oracle.
/// @custom:security Trust. Every substrate is fully trusted. The size of X is decided by the code C runs (the reserve
///      vault supply fuse), and this fuse returns whatever C's `read` returns, with no cap and no check against C's
///      position in A. Granting a reserve vault C as a substrate of this market trusts C's fuse manager and C's Alpha,
///      not only A's own Alpha: a fuse that C's fuse manager adds and C's Alpha executes can write any value into the
///      boost slot of A (the slot formula is public), refresh this market in A with C's update role and withdraw
///      against C's shares of A at that inflated price. A malicious or misconfigured fuse set on C can thus inflate
///      A's net asset value through the boost and drain A, including its instant-withdraw markets. A substrate can
///      also block every refresh that includes this market by reverting. Grant only reserve vaults whose governance
///      (atomist, fuse manager and Alpha together) is trusted as much as A's own atomist and fuse manager.
/// @custom:security Configuration. The boost market has this balance fuse only: no action fuse, because there is no
///      position to enter or exit, only a transient valuation. It must have no dependency graph edge, in either
///      direction: C books and clears the boost by refreshing exactly this market, and that refresh must not revalue
///      other markets of A in the middle of C's exit. The fuse does not enforce either rule; see
///      `contracts/fuses/reserve_vault/README.md`.
/// @author IPOR Labs
contract ReserveVaultBoostBalanceFuse is IMarketBalanceFuse {
    /// @notice Address of this fuse contract version
    /// @dev Immutable value set in the constructor; also the delegatecall target of the reserve vault reads
    address public immutable VERSION;

    /// @notice Market ID this fuse operates on (the reserve vault boost market)
    /// @dev Immutable value set in the constructor, used to retrieve the market substrates (reserve vault addresses)
    uint256 public immutable MARKET_ID;

    /// @notice Initializes the fuse with the boost market ID
    /// @param marketId_ The market ID whose substrates are the reserve vault addresses
    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Returns the boost that the reserve vaults hold for the member vault, in USD WAD, rounded up
    /// @dev Runs by delegatecall in the member vault. Sums `readBoost(memberVault)` read through each substrate's
    ///      UniversalReader, returns 0 for a zero sum without reading the price, and otherwise converts the sum once
    ///      with `ReserveVaultBoostLib.convertToUsdWadRoundUp` at the member vault's oracle price of its underlying
    ///      asset. Reverts when a substrate read reverts, on a zero price for a non-zero sum, and on overflow.
    /// @return The boost in USD, normalized to WAD (18 decimals); zero outside a reserve vault exit
    function balanceOf() external view override returns (uint256) {
        bytes32[] memory reserveVaults = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);
        uint256 len = reserveVaults.length;

        if (len == 0) {
            return 0;
        }

        address memberVault = address(this);
        bytes memory readBoostCall = abi.encodeCall(ReserveVaultBoostBalanceFuse.readBoost, (memberVault));
        uint256 totalBoost;
        ReadResult memory readResult;

        for (uint256 i; i < len; ++i) {
            readResult = UniversalReader(PlasmaVaultConfigLib.bytes32ToAddress(reserveVaults[i])).read(
                VERSION,
                readBoostCall
            );
            totalBoost += abi.decode(readResult.data, (uint256));
        }

        if (totalBoost == 0) {
            return 0;
        }

        (uint256 price, uint256 priceDecimals) = IPriceOracleMiddleware(PlasmaVaultLib.getPriceOracleMiddleware())
            .getAssetPrice(IERC4626(memberVault).asset());

        return
            ReserveVaultBoostLib.convertToUsdWadRoundUp(
                totalBoost,
                price,
                priceDecimals,
                IERC4626(memberVault).decimals() - PlasmaVaultLib.DECIMALS_OFFSET
            );
    }

    /// @notice Returns the boost stored for a member vault in the transient storage of the calling context
    /// @dev Meaningful only when run by delegatecall in a reserve vault, which `UniversalReader.read` of the reserve
    ///      vault does; it then returns the reserve vault's boost for `memberVault_`. Called directly on this contract
    ///      it reads the fuse's own transient storage, which nothing writes, and returns 0.
    /// @param memberVault_ The member vault whose boost is read
    /// @return The boost, in the member vault's underlying asset; zero outside a reserve vault exit
    function readBoost(address memberVault_) external view returns (uint256) {
        return ReserveVaultBoostLib.getBoost(memberVault_);
    }
}
