// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IEVC} from "@ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {EulerFuseLib, EulerSubstrate} from "./EulerFuseLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IBorrowing} from "./ext/IBorrowing.sol";
import {IEulerV2VaultGovernance, CFG_DONT_SOCIALIZE_DEBT} from "./ext/IEulerV2VaultGovernance.sol";
import {IEulerV2Swap} from "./ext/IEulerV2Swap.sol";
import {EulerV2SwapFairPointLib} from "./EulerV2SwapFairPointLib.sol";
import {Errors} from "../../libraries/errors/Errors.sol";

/// @notice One position of the Plasma Vault in Euler V2: an eVault and a sub-account; value in USD normalized to WAD
struct EulerPositionValue {
    address eulerVault;
    uint256 subAccountIndex;
    uint256 shares;
    uint256 value;
}

/// @notice One EVC sub-account of the Plasma Vault; debt value in USD normalized to WAD
struct EulerSubAccountValue {
    bytes1 id;
    address account;
    /// @dev eVault the sub-account owes (the EVC allows one controller per account); address(0) without debt
    address controller;
    /// @dev debt found in more than one eVault (not reachable on the EVC); valued conservatively
    bool severalControllers;
    uint256 debtValue;
}

/**
 * @title Fuse for Euler V2 vaults responsible for calculating the balance of the Plasma Vault in Euler V2 vaults based on preconfigured market substrates
 * @notice Values every EVC sub-account of the Plasma Vault on its own, by what the vault keeps once its debt is
 *         settled, and returns the sum over the sub-accounts in USD normalized to WAD (IL-9528, 3sigma audit finding #1)
 * @dev Every EVC sub-account is a separate account with limited liability. A liquidation seizes only collateral that
 *      the sub-account enabled on the EVC and that its controller recognizes (an LTV is configured), and the debt left
 *      afterwards is socialized by the controller unless it sets CFG_DONT_SOCIALIZE_DEBT. A liquidation needs at least
 *      one such collateral, so a sub-account without one cannot be liquidated and its debt cannot be socialized.
 *      With C = seizable collateral, F = every other position of the sub-account (plain supply, collateral the
 *      controller does not recognize) and D = debt, one sub-account is worth:
 *      - no debt: C + F;
 *      - the debt can be socialized: F + max(0, C - D); F survives the liquidation, so it counts in full;
 *      - the debt cannot be socialized (CFG_DONT_SOCIALIZE_DEBT, or no seizable collateral): max(0, C + F - D);
 *        the debt stays on the sub-account and locks every position of it.
 *      When an underwater sub-account will be socialized, the controller writes the residual debt off against its
 *      depositors, the Plasma Vault among them: the vault's shares in that controller (in any sub-account of this
 *      market) are charged their part of it, bounded by the whole debt. The result is never above what the vault keeps
 *      after the liquidation, and the liquidation steps it up by at most the vault's part of the repaid debt.
 *      An eVault and sub-account granted twice (other flags) is counted once; an empty position is not priced.
 *      Sub-account 0x00 is the Plasma Vault address itself, so shares of the eVault that is the vault's own underlying
 *      `asset()` held there are the vault's idle balance, which `totalAssets` already counts. That position still
 *      takes part in the valuation of sub-account 0x00 (collateral, plain supply, debt, socialization charge), and its
 *      value is then taken off the result of sub-account 0x00, floored at zero (IL-9707, 3sigma audit v3 #21). A debt
 *      of sub-account 0x00 can take more than the rest of that sub-account, i.e. part of the idle underlying (the debt
 *      itself, or a liquidation seizing it); the market is never negative and cannot show that part, so NAV is
 *      overstated by it: with an eVault-share underlying, do not borrow on sub-account 0x00 (atomist rule, the fuse
 *      does not enforce it).
 *      The fuse does not signal bad debt: monitor each sub-account off-chain (controller `accountLiquidity`).
 *      EulerSwap pools (IL-9706, 3sigma audit v3 #20): a pool entry (`EulerFuseLib.swapPoolSubstrateToBytes32`) names a
 *      pool installed as an EVC operator of one sub-account. Pool entries are set apart from the eVault rows before any
 *      call to an eVault and create no position and no sub-account. A sub-account with live pools is worth max(0, v - sum
 *      of d), with v its value as above (after the 0x00 rule) and d the oracle value of the pool reserves above the
 *      oracle value of the fair point of the curve (`EulerV2SwapFairPointLib`; rounded up, never negative). The fair
 *      point depends only on the curve parameters and the oracle, so a swap or a donation that moves the holdings of the
 *      sub-account and the pool reserves by the same amounts leaves the result unchanged (only the LP fee stays). `d`
 *      comes from the virtual reserves alone and is not capped by what the sub-account can deliver: equilibrium reserves
 *      far above the holdings understate the value, and `exit` (d becomes 0) or a reconfigure moves it by `d` at once. A
 *      pool on sub-account 0x00 whose supply vault is the vault's `asset()` is outside the invariance below: that leg is
 *      the vault's idle balance, read live by `totalAssets` outside this market, so a donation or a swap moves NAV at
 *      once and the floor at zero drops the offset after a refresh. `EulerV2SwapDeployFuse.enter` rejects such a new
 *      pool; an existing one should be exited. A pool is live when it has code, its `eulerAccount` is the sub-account of
 *      the entry, it is an EVC operator of that sub-account and it has not expired; any other entry that names a pool is
 *      skipped without a revert, the same pool granted twice counts once. An entry must name an EulerSwap v2 pool of the
 *      deploy fuse's factory: an entry without code is skipped, but a contract with code that is not such a pool makes
 *      `getStaticParams()` revert and every refresh of this market reverts until the entry is corrected. `getReserves`
 *      reverts `Locked()` during a swap and the revert is not caught, so the market cannot be refreshed in the middle of
 *      a swap. A live pool without an entry is not seen (EVC operators cannot be listed) and its sub-account is valued
 *      without the term. The pool's supply and borrow eVaults must stay granted as rows while the pool is live: a missing
 *      supply row hides that leg, and a missing borrow row hides the just-in-time debt, so the market is overstated by
 *      it. The invariance holds for the pool sub-account, not for the market: on an underwater pool sub-account `v` does
 *      not move with the seizable leg, so from the fair point a swap cannot raise the result, but after an oracle move a
 *      swap toward the fair point lowers `d` and raises it by that drop, and the socialization charge of another
 *      underwater sub-account moves with the vault's shares in, and the supply of, its controller, so a pool that
 *      supplies that controller moves the charge with a reversible donation (documented limitation). A vault with a pool
 *      entry uses only the Euler fuses of this release: earlier fuses read a pool entry as an eVault row.
 */
contract EulerV2BalanceFuse is IMarketBalanceFuse {
    /// @dev EVC sub-account 0x00 of the Plasma Vault is the vault address itself (see `generateSubAccountAddress`)
    bytes1 private constant _PLASMA_VAULT_SUB_ACCOUNT = 0x00;

    /// @notice Address of this fuse contract version
    /// @dev Immutable value set in constructor, used for tracking and versioning
    address public immutable VERSION;

    /// @notice Market ID this fuse operates on
    /// @dev Immutable value set in constructor, used to retrieve market substrates (Euler V2 vault addresses)
    uint256 public immutable MARKET_ID;

    /// @notice Ethereum Vault Connector (EVC) address for Euler V2 protocol
    /// @dev Immutable value set in constructor, used for Euler V2 protocol interactions
    IEVC public immutable EVC;

    /**
     * @notice Initializes the EulerV2BalanceFuse with a market ID and EVC address
     * @param marketId_ The market ID used to identify the Euler V2 vault substrates
     * @param eulerV2EVC_ The address of the Ethereum Vault Connector for Euler V2 protocol (must not be address(0))
     * @dev Reverts if eulerV2EVC_ is zero address
     */
    constructor(uint256 marketId_, address eulerV2EVC_) {
        if (eulerV2EVC_ == address(0)) {
            revert Errors.WrongAddress();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
        EVC = IEVC(eulerV2EVC_);
    }

    /**
     * @notice Calculates the balance of the Plasma Vault in Euler V2 vaults
     * @dev 1. Reads every distinct (eVault, sub-account) position once: shares, value and debt
     *      2. Values each sub-account as described on the contract
     *      3. Takes the value of the vault's own underlying held on sub-account 0x00 (idle) off the result of that
     *         sub-account, floored at zero; the vault's `asset()` is read only for a market with a row on 0x00
     *      4. Charges the vault's shares in the controller of every underwater sub-account whose debt will be socialized
     *         their part of that debt, and floors the result at zero
     *      EulerSwap pool entries (IL-9706) are set apart in step 1, before any call to an eVault; after step 3 the
     *      displacement of the live pools of each sub-account is taken off the result of that sub-account, floored at
     *      zero (see the contract notice).
     * @return The balance of the Plasma Vault in USD, normalized to WAD (18 decimals)
     * @custom:revert Errors.UnsupportedQuoteCurrencyFromOracle When price oracle cannot provide a price for the asset of
     *                a non-empty position, or for an asset of a live pool
     * @custom:revert Locked() (from the pool) When a live pool is in the middle of a swap
     */
    function balanceOf() external view override returns (uint256) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = substrates.length;

        if (len == 0) {
            return 0;
        }

        EulerPositionValue[] memory positions = new EulerPositionValue[](len);
        EulerSubAccountValue[] memory subAccounts = new EulerSubAccountValue[](len);
        /// @dev IL-9706: EulerSwap pool entries of the market, set apart from the eVault rows (see `_listSwapPool`)
        bytes32[] memory swapPools = new bytes32[](len);

        (uint256 positionsCount, uint256 subAccountsCount) = _readPositions(
            substrates,
            positions,
            subAccounts,
            swapPools
        );

        uint256 balance;
        uint256 socializationCharge;
        uint256 value;
        uint256 socializedDebtValue;

        for (uint256 i; i < subAccountsCount; ++i) {
            (value, socializedDebtValue) = _subAccountValue(i, subAccounts[i], positions, positionsCount);

            if (subAccounts[i].id == _PLASMA_VAULT_SUB_ACCOUNT) {
                value = _withoutIdleUnderlying(i, value, positions, positionsCount);
            }

            value = _withoutSwapPoolDisplacement(subAccounts[i], value, swapPools);

            balance += value;

            if (socializedDebtValue > 0) {
                socializationCharge += _socializationCharge(
                    subAccounts[i].controller,
                    socializedDebtValue,
                    positions,
                    positionsCount
                );
            }
        }

        return balance > socializationCharge ? balance - socializationCharge : 0;
    }

    /// @dev Reads each distinct (eVault, sub-account) position once, and the debt and controller of each sub-account.
    ///      IL-9706: an EulerSwap pool entry is not an eVault row; it goes to `swapPools_` before any call and creates
    ///      no position and no sub-account.
    function _readPositions(
        bytes32[] memory substrates_,
        EulerPositionValue[] memory positions_,
        EulerSubAccountValue[] memory subAccounts_,
        bytes32[] memory swapPools_
    ) private view returns (uint256 positionsCount, uint256 subAccountsCount) {
        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();
        EulerSubstrate memory substrate;
        uint256 subAccountIndex;

        for (uint256 i; i < substrates_.length; ++i) {
            if (EulerFuseLib.isSwapPoolSubstrate(substrates_[i])) {
                _listSwapPool(swapPools_, substrates_[i]);
                continue;
            }

            substrate = EulerFuseLib.bytes32ToSubstrate(substrates_[i]);

            for (subAccountIndex = 0; subAccountIndex < subAccountsCount; ++subAccountIndex) {
                if (subAccounts_[subAccountIndex].id == substrate.subAccounts) {
                    break;
                }
            }

            if (subAccountIndex == subAccountsCount) {
                subAccounts_[subAccountIndex].id = substrate.subAccounts;
                subAccounts_[subAccountIndex].account = EulerFuseLib.generateSubAccountAddress(
                    address(this),
                    substrate.subAccounts
                );
                ++subAccountsCount;
            } else if (_isRead(positions_, positionsCount, substrate.eulerVault, subAccountIndex)) {
                /// @dev the same eVault and sub-account granted twice with other flags: count it once
                continue;
            }

            positions_[positionsCount].eulerVault = substrate.eulerVault;
            positions_[positionsCount].subAccountIndex = subAccountIndex;
            _readPosition(positions_[positionsCount], subAccounts_[subAccountIndex], priceOracleMiddleware);
            ++positionsCount;
        }
    }

    /// @dev Reads the shares and the debt of one position; an empty position is not priced
    function _readPosition(
        EulerPositionValue memory position_,
        EulerSubAccountValue memory subAccount_,
        address priceOracleMiddleware_
    ) private view {
        uint256 shares = ERC4626(position_.eulerVault).balanceOf(subAccount_.account);
        uint256 debt = IBorrowing(position_.eulerVault).debtOf(subAccount_.account);

        if (shares == 0 && debt == 0) {
            return;
        }

        address eulerVaultAsset = ERC4626(position_.eulerVault).asset();

        /// @dev price in USD with the decimals returned by the price oracle middleware
        (uint256 price, uint256 priceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware_).getAssetPrice(
            eulerVaultAsset
        );

        if (price == 0) {
            revert Errors.UnsupportedQuoteCurrencyFromOracle();
        }

        uint256 decimals = IERC20Metadata(eulerVaultAsset).decimals() + priceDecimals;

        if (shares > 0) {
            position_.shares = shares;
            position_.value = IporMath.convertToWad(
                ERC4626(position_.eulerVault).convertToAssets(shares) * price,
                decimals
            );
        }

        if (debt > 0) {
            subAccount_.debtValue += IporMath.convertToWad(debt * price, decimals);

            if (subAccount_.controller == address(0)) {
                subAccount_.controller = position_.eulerVault;
            } else {
                subAccount_.severalControllers = true;
            }
        }
    }

    /// @dev Value of one sub-account for the Plasma Vault (see the contract notice)
    /// @return value The value of the sub-account in USD, normalized to WAD
    /// @return socializedDebtValue The debt the controller writes off after liquidating the sub-account, 0 if none
    function _subAccountValue(
        uint256 subAccountIndex_,
        EulerSubAccountValue memory subAccount_,
        EulerPositionValue[] memory positions_,
        uint256 positionsCount_
    ) private view returns (uint256 value, uint256 socializedDebtValue) {
        (address[] memory seizable, uint256 seizableCount) = _seizableCollaterals(subAccount_);

        uint256 seizableValue;
        uint256 freeValue;

        for (uint256 i; i < positionsCount_; ++i) {
            if (positions_[i].subAccountIndex != subAccountIndex_ || positions_[i].value == 0) {
                continue;
            }

            if (_contains(seizable, seizableCount, positions_[i].eulerVault)) {
                seizableValue += positions_[i].value;
            } else {
                freeValue += positions_[i].value;
            }
        }

        uint256 debtValue = subAccount_.debtValue;

        if (debtValue == 0) {
            return (freeValue, 0);
        }

        if (seizableCount == 0) {
            /// @dev the debt cannot be socialized: it stays on the sub-account and locks every position of it
            return (freeValue > debtValue ? freeValue - debtValue : 0, 0);
        }

        if (seizableValue >= debtValue) {
            return (freeValue + seizableValue - debtValue, 0);
        }

        /// @dev underwater: a liquidation seizes the collateral and the controller writes the rest of the debt off
        return (freeValue, debtValue);
    }

    /// @dev IL-9707 (3sigma audit v3 #21): result of sub-account 0x00 without the vault's own underlying. Shares of the
    ///      eVault equal to the vault's `asset()` held on sub-account 0x00 (the vault address) are its idle balance,
    ///      already counted by `totalAssets`. The position stays in the sub-account valuation (`value_`), only its
    ///      value is taken off, floored at zero. Called only for a market with a row on 0x00, so `asset()` is read
    ///      only there.
    /// @param subAccountIndex_ Index of sub-account 0x00 in the sub-account list
    /// @param value_ Value of sub-account 0x00 from `_subAccountValue`, in USD normalized to WAD
    /// @return The value of sub-account 0x00 without the idle underlying, in USD normalized to WAD
    function _withoutIdleUnderlying(
        uint256 subAccountIndex_,
        uint256 value_,
        EulerPositionValue[] memory positions_,
        uint256 positionsCount_
    ) private view returns (uint256) {
        address underlying = ERC4626(address(this)).asset();

        for (uint256 i; i < positionsCount_; ++i) {
            if (positions_[i].subAccountIndex == subAccountIndex_ && positions_[i].eulerVault == underlying) {
                return value_ > positions_[i].value ? value_ - positions_[i].value : 0;
            }
        }

        return value_;
    }

    /// @dev Collaterals a liquidation can seize from the sub-account when its controller socializes the debt left
    ///      after the liquidation: enabled on the EVC and recognized by the controller (EVK `calculateLiquidation`,
    ///      `checkNoCollateral`). None when the sub-account has no debt, when the controller keeps the residual debt
    ///      (CFG_DONT_SOCIALIZE_DEBT), or when no enabled collateral is recognized, so that no liquidation can run.
    /// @return seizable The collaterals, compacted to the first `seizableCount` entries
    function _seizableCollaterals(
        EulerSubAccountValue memory subAccount_
    ) private view returns (address[] memory seizable, uint256 seizableCount) {
        if (
            subAccount_.debtValue == 0 ||
            subAccount_.severalControllers ||
            (IEulerV2VaultGovernance(subAccount_.controller).configFlags() & CFG_DONT_SOCIALIZE_DEBT) != 0
        ) {
            return (seizable, 0);
        }

        seizable = EVC.getCollaterals(subAccount_.account);
        uint48 targetTimestamp;

        for (uint256 i; i < seizable.length; ++i) {
            /// @dev EVK `LTVConfig.isRecognizedCollateral`: an LTV is configured; never the controller itself
            (, , , targetTimestamp, ) = IEulerV2VaultGovernance(subAccount_.controller).LTVFull(seizable[i]);

            if (targetTimestamp != 0) {
                seizable[seizableCount] = seizable[i];
                ++seizableCount;
            }
        }
    }

    /// @dev Part of the written-off debt borne by the Plasma Vault as a depositor of the controller: its shares in the
    ///      controller (any sub-account of this market) times the debt over the controller's share supply. The
    ///      written-off debt is at most the whole debt (a liquidator repays at least zero), so the charge is never
    ///      below the real loss.
    function _socializationCharge(
        address controller_,
        uint256 debtValue_,
        EulerPositionValue[] memory positions_,
        uint256 positionsCount_
    ) private view returns (uint256) {
        uint256 vaultShares;

        for (uint256 i; i < positionsCount_; ++i) {
            if (positions_[i].eulerVault == controller_) {
                vaultShares += positions_[i].shares;
            }
        }

        if (vaultShares == 0) {
            return 0;
        }

        return Math.mulDiv(debtValue_, vaultShares, ERC4626(controller_).totalSupply(), Math.Rounding.Ceil);
    }

    /// @dev IL-9706 (3sigma audit v3 #20): result of a sub-account without the displacement of its live EulerSwap
    ///      pools, floored at zero. Every live pool of the sub-account is read even when the result is already zero, so
    ///      that a refresh in the middle of a swap always reverts `Locked()` instead of valuing a transient state.
    /// @param subAccount_ The sub-account
    /// @param value_ Value of the sub-account after the 0x00 rule, in USD normalized to WAD
    /// @param swapPools_ Pool entries of the market (see `_listSwapPool`)
    /// @return The value of the sub-account without the displacement of its pools, in USD normalized to WAD
    function _withoutSwapPoolDisplacement(
        EulerSubAccountValue memory subAccount_,
        uint256 value_,
        bytes32[] memory swapPools_
    ) private view returns (uint256) {
        uint256 displacement;
        address pool;
        bytes1 poolSubAccount;

        for (uint256 i; i < swapPools_.length && swapPools_[i] != bytes32(0); ++i) {
            (pool, poolSubAccount) = EulerFuseLib.bytes32ToSwapPoolSubstrate(swapPools_[i]);

            if (poolSubAccount == subAccount_.id) {
                displacement += _swapPoolDisplacement(pool, subAccount_.account);
            }
        }

        return value_ > displacement ? value_ - displacement : 0;
    }

    /// @dev Oracle value of the reserves of one pool above the value of the fair point of its curve, in USD normalized
    ///      to WAD (`EulerV2SwapFairPointLib.poolDisplacementWad`, rounded up, never negative). 0, without reading the
    ///      reserves, for a pool that is not live on `account_`: no code (entry granted before the deploy), another
    ///      `eulerAccount`, not an EVC operator of `account_` (never installed, or uninstalled), or expired. Reverts of
    ///      the pool are not caught: `getReserves` reverts `Locked()` in the middle of a swap.
    function _swapPoolDisplacement(address pool_, address account_) private view returns (uint256) {
        if (pool_.code.length == 0) {
            return 0;
        }

        if (IEulerV2Swap(pool_).getStaticParams().eulerAccount != account_) {
            return 0;
        }

        if (!EVC.isAccountOperatorAuthorized(account_, pool_)) {
            return 0;
        }

        IEulerV2Swap.DynamicParams memory params = IEulerV2Swap(pool_).getDynamicParams();

        /// @dev an expired pool cannot swap; same boundary as EulerV2SwapDeployFuse (expiration <= block.timestamp)
        if (params.expiration != 0 && params.expiration <= block.timestamp) {
            return 0;
        }

        (uint112 reserve0, uint112 reserve1, ) = IEulerV2Swap(pool_).getReserves();
        (address asset0, address asset1) = IEulerV2Swap(pool_).getAssets();

        return EulerV2SwapFairPointLib.poolDisplacementWad(params, reserve0, reserve1, _swapPoolPrices(asset0, asset1));
    }

    /// @dev Oracle prices and token decimals of the two pool assets, in the order of `getAssets()`
    function _swapPoolPrices(
        address asset0_,
        address asset1_
    ) private view returns (EulerV2SwapFairPointLib.AssetPrices memory prices) {
        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();

        prices.price0Wad = _priceWad(priceOracleMiddleware, asset0_);
        prices.price1Wad = _priceWad(priceOracleMiddleware, asset1_);
        prices.decimals0 = IERC20Metadata(asset0_).decimals();
        prices.decimals1 = IERC20Metadata(asset1_).decimals();
    }

    /// @dev USD price of one whole token, normalized to WAD; a zero price reverts as for an eVault position
    function _priceWad(address priceOracleMiddleware_, address asset_) private view returns (uint256) {
        (uint256 price, uint256 priceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware_).getAssetPrice(asset_);

        if (price == 0) {
            revert Errors.UnsupportedQuoteCurrencyFromOracle();
        }

        return IporMath.convertToWad(price, priceDecimals);
    }

    /// @dev Adds a pool entry to `swapPools_`, a list of `substrates.length` slots ended by the first `bytes32(0)`. The
    ///      entry is stored re-encoded from its pool and sub-account (`swapPoolSubstrateToBytes32`, never zero), so flag
    ///      or padding bits do not matter and the same pool and sub-account granted twice is listed once.
    function _listSwapPool(bytes32[] memory swapPools_, bytes32 substrate_) private pure {
        (address pool, bytes1 subAccount) = EulerFuseLib.bytes32ToSwapPoolSubstrate(substrate_);
        bytes32 entry = EulerFuseLib.swapPoolSubstrateToBytes32(pool, subAccount);

        for (uint256 i; i < swapPools_.length; ++i) {
            if (swapPools_[i] == entry) {
                return;
            }

            if (swapPools_[i] == bytes32(0)) {
                swapPools_[i] = entry;
                return;
            }
        }
    }

    function _isRead(
        EulerPositionValue[] memory positions_,
        uint256 positionsCount_,
        address eulerVault_,
        uint256 subAccountIndex_
    ) private pure returns (bool) {
        for (uint256 i; i < positionsCount_; ++i) {
            if (positions_[i].eulerVault == eulerVault_ && positions_[i].subAccountIndex == subAccountIndex_) {
                return true;
            }
        }

        return false;
    }

    function _contains(address[] memory list_, uint256 count_, address account_) private pure returns (bool) {
        for (uint256 i; i < count_; ++i) {
            if (list_[i] == account_) {
                return true;
            }
        }

        return false;
    }
}
