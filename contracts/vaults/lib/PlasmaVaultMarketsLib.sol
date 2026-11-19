// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {IFuseCommon} from "../../fuses/IFuseCommon.sol";
import {DataToCheck, MarketToCheck} from "../../libraries/AssetDistributionProtectionLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {FusesLib} from "../../libraries/FusesLib.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";

library PlasmaVaultMarketsLib {
    using Address for address;
    event MarketBalancesUpdated(uint256[] marketIds, int256 deltaInUnderlying);

    /// @notice Emitted when an instant withdrawal entry reverted with error data and was skipped (IL-9659)
    /// @param fuse Address of the instant withdrawal fuse of the skipped entry
    /// @param index Position of the entry in the instant withdrawal list
    /// @param errorSelector First four bytes of the revert data of the entry (zero if the data is shorter)
    event InstantWithdrawalFuseFailed(address fuse, uint256 index, bytes4 errorSelector);

    /// @dev Error thrown when asset price is zero
    error AssetPriceIsZero();

    /// @dev Error thrown when a market passed to updateMarketsBalances has no registered balance fuse
    error MarketWithoutBalanceFuse(uint256 marketId);

    /// @notice Transient slot (ERC-7201 namespace) holding the number of market ids recorded by callbacks
    ///         (PlasmaVault.executeInternal) during the current PlasmaVault.execute (IL-9404)
    /// @dev Calculation:
    ///      keccak256(abi.encode(uint256(keccak256("io.ipor.fusion.transient.CallbackMarkets")) - 1))
    ///      & ~bytes32(uint256(0xff))
    ///      Element i of the list is stored at uint256(keccak256(abi.encode(CALLBACK_MARKETS_TRANSIENT_SLOT))) + i.
    ///      The library functions run via DELEGATECALL, so the list lives in the transient storage of the vault.
    bytes32 internal constant CALLBACK_MARKETS_TRANSIENT_SLOT =
        0x5aa8d5c4eed54ae6d6941b8519babb054f24551cea95ec75fc0249f99cc57400;

    /// @notice Records the markets touched by the fuse actions of a callback (PlasmaVault.executeInternal)
    /// @param markets_ Market ids touched in the callback; zero entries are skipped
    /// @dev Appends the ids to the transient list of the current execute. PlasmaVault.execute takes the list right
    ///      after executeFinished() and refreshes and limit-checks these markets once more, after every callback
    ///      returned and the flash loan was repaid. executeInternal refreshes the callback markets without a limit check
    ///      (IL-9708), because inside the callback the NAV still holds the borrowed tokens; the market caches it writes
    ///      predate the end of the callback (IL-9404), so this is the only limit check of these markets.
    function recordCallbackMarkets(uint256[] memory markets_) public {
        uint256 length = uint256(TransientStorageLib.tload(CALLBACK_MARKETS_TRANSIENT_SLOT));
        uint256 firstElementSlot = uint256(keccak256(abi.encode(CALLBACK_MARKETS_TRANSIENT_SLOT)));
        uint256 marketsLength = markets_.length;

        for (uint256 i; i < marketsLength; ++i) {
            if (markets_[i] != 0) {
                TransientStorageLib.tstore(bytes32(firstElementSlot + length), bytes32(markets_[i]));
                ++length;
            }
        }

        TransientStorageLib.tstore(CALLBACK_MARKETS_TRANSIENT_SLOT, bytes32(length));
    }

    /// @notice Merges the markets of an execute with the markets recorded by its callbacks and clears the record
    /// @param markets_ Market ids collected by PlasmaVault.execute from its own fuse actions (may contain zero entries)
    /// @return markets `markets_` unchanged when no callback recorded a market; otherwise the union of `markets_` and
    ///         the recorded markets without duplicates, non-zero ids first (the ids of `markets_` keep their order)
    ///         and zero entries at the end
    /// @dev Resets the recorded length, so a later execute in the same transaction starts from an empty list; a revert
    ///      of execute also reverts the transient writes (IL-9404).
    function takeCallbackMarkets(uint256[] memory markets_) public returns (uint256[] memory markets) {
        uint256 recordedLength = uint256(TransientStorageLib.tload(CALLBACK_MARKETS_TRANSIENT_SLOT));

        if (recordedLength == 0) {
            return markets_;
        }

        TransientStorageLib.tstore(CALLBACK_MARKETS_TRANSIENT_SLOT, bytes32(0));

        uint256 outerLength = markets_.length;
        uint256 totalLength = outerLength + recordedLength;
        uint256 firstElementSlot = uint256(keccak256(abi.encode(CALLBACK_MARKETS_TRANSIENT_SLOT)));
        uint256 marketId;
        uint256 count;

        markets = new uint256[](totalLength);

        for (uint256 i; i < totalLength; ++i) {
            marketId = i < outerLength
                ? markets_[i]
                : uint256(TransientStorageLib.tload(bytes32(firstElementSlot + i - outerLength)));

            if (marketId != 0 && !_checkIfExistsMarket(markets, marketId)) {
                markets[count] = marketId;
                ++count;
            }
        }
    }

    /// @notice Updates balances for specified markets by fetching balance from balance fuses and converting from USD to underlying asset
    /// @param markets_ Array of market IDs to update balances for
    /// @param assetAddress_ Address of the underlying asset
    /// @param decimals_ Number of decimals for the underlying asset
    /// @param decimalsOffset_ Offset to apply when converting decimals
    /// @return dataToCheck Data structure containing markets and their balances for validation
    /// @dev Filters zero markets, checks balance fuse dependencies, fetches asset price from oracle,
    ///      converts balances from USD (WAD) to underlying asset decimals, and updates total assets in markets.
    ///      Reverts with MarketWithoutBalanceFuse if a market has no registered balance fuse.
    function updateMarketsBalances(
        uint256[] memory markets_,
        address assetAddress_,
        uint256 decimals_,
        uint256 decimalsOffset_
    ) public returns (DataToCheck memory dataToCheck) {
        uint256[] memory filteredMarkets = _filterZeroMarkets(markets_);

        uint256 wadBalanceAmountInUSD;
        // DataToCheck memory dataToCheck;
        address balanceFuse;
        int256 deltasInUnderlying;
        uint256[] memory markets = _checkBalanceFusesDependencies(filteredMarkets);
        uint256 marketsLength = markets.length;

        (uint256 underlyingAssetPrice, uint256 underlyingAssePriceDecimals) = IPriceOracleMiddleware(
            PlasmaVaultLib.getPriceOracleMiddleware()
        ).getAssetPrice(assetAddress_);

        if (underlyingAssetPrice == 0) {
            revert AssetPriceIsZero();
        }

        dataToCheck.marketsToCheck = new MarketToCheck[](marketsLength);

        for (uint256 i; i < marketsLength; ++i) {
            if (markets[i] == 0) {
                break;
            }

            balanceFuse = FusesLib.getBalanceFuse(markets[i]);

            if (balanceFuse == address(0)) {
                revert MarketWithoutBalanceFuse(markets[i]);
            }

            wadBalanceAmountInUSD = abi.decode(
                balanceFuse.functionDelegateCall(abi.encodeWithSignature("balanceOf()")),
                (uint256)
            );
            dataToCheck.marketsToCheck[i].marketId = markets[i];

            dataToCheck.marketsToCheck[i].balanceInMarket = IporMath.convertWadToAssetDecimals(
                IporMath.division(
                    wadBalanceAmountInUSD * IporMath.BASIS_OF_POWER ** underlyingAssePriceDecimals,
                    underlyingAssetPrice
                ),
                (decimals_ - decimalsOffset_)
            );

            deltasInUnderlying =
                deltasInUnderlying +
                PlasmaVaultLib.updateTotalAssetsInMarket(markets[i], dataToCheck.marketsToCheck[i].balanceInMarket);
        }

        if (deltasInUnderlying != 0) {
            PlasmaVaultLib.addToTotalAssetsInAllMarkets(deltasInUnderlying);
        }

        emit MarketBalancesUpdated(markets, deltasInUnderlying);
    }

    /// @notice Withdraws assets from markets using instant withdrawal fuses until the required amount is met
    /// @param assetAddress_ Address of the underlying asset to withdraw
    /// @param assets_ Total amount of assets needed to be withdrawn
    /// @param vaultCurrentBalanceUnderlying_ Current balance of the vault in underlying token
    /// @return markets Array of unique market IDs that were touched during the withdrawal process
    /// @dev Uses instant withdrawal fuses to withdraw assets from markets, tracking unique market IDs
    ///      that were affected. The array may contain zero values at the end if fewer markets were used.
    ///      An entry whose fuse is no longer supported (removed with `removeFuses`) is skipped without a call, an event
    ///      or a revert, and contributes no market; its position in the list is kept so the parameters of the
    ///      following entries, keyed by (fuse, index), still match. If every entry is skipped the requested amount is
    ///      not served and the caller reverts as it does for an empty list. The stored list is not changed by this
    ///      skip: governance still has to rewrite it with `configureInstantWithdrawalFuses`. Vaults whose
    ///      `PlasmaVaultMarketsLib` predates this check keep calling such entries until they are upgraded.
    ///      IL-9659: an entry whose `instantWithdraw` reverts WITH error data (bad params, a revoked substrate) is
    ///      skipped as well: its effects are rolled back, `InstantWithdrawalFuseFailed` is emitted, it contributes no
    ///      market and the loop goes on, so one faulty entry cannot block the withdrawal until governance rewrites the
    ///      list. An entry that reverts with EMPTY data (possibly out of gas, 63/64 rule) still reverts the whole call,
    ///      so the gas limit of the caller cannot decide that a market is skipped. A nested out-of-gas that a wrapper turns
    ///      into error data (for example OpenZeppelin `FailedCall`) is skipped like any other revert with data; this is
    ///      impractical, since it needs about 64 times the gas of the nested call. If every entry fails the requested
    ///      amount is not served and the caller reverts as before.
    function withdrawFromMarkets(
        address assetAddress_,
        uint256 assets_,
        uint256 vaultCurrentBalanceUnderlying_
    ) public returns (uint256[] memory markets) {
        uint256 left;
        uint256 marketIndex;
        uint256 fuseMarketId;

        bytes32[] memory params;

        /// @dev assume that the same fuse can be used multiple times
        /// @dev assume that more than one fuse can be from the same market
        address[] memory fuses = PlasmaVaultLib.getInstantWithdrawalFuses();

        markets = new uint256[](fuses.length);

        left = assets_ - vaultCurrentBalanceUnderlying_;

        uint256 balanceOf;
        uint256 fusesLength = fuses.length;

        for (uint256 i; left != 0 && i < fusesLength; ++i) {
            /// @dev IL-9534: the supported-fuse registry stays authoritative at execution time (as in PlasmaVault.execute),
            ///      an entry whose fuse was removed with removeFuses is skipped. The loop index is kept, because the
            ///      parameters are keyed by (fuse, index), and a skipped entry adds no market to the returned list.
            if (!FusesLib.isFuseSupported(fuses[i])) {
                continue;
            }

            params = PlasmaVaultLib.getInstantWithdrawalFusesParams(fuses[i], i);

            /// @dev always first param is amount, by default is 0 in storage, set to left
            params[0] = bytes32(left);

            (bool success, bytes memory returnData) = fuses[i].delegatecall(
                abi.encodeWithSignature("instantWithdraw(bytes32[])", params)
            );

            if (!success && returnData.length != 0) {
                bytes4 errorSelector;
                if (returnData.length >= 4) {
                    errorSelector = bytes4(returnData);
                }
                emit InstantWithdrawalFuseFailed(fuses[i], i, errorSelector);
                continue;
            }

            /// @dev reverts with FailedInnerCall on an empty revert and with AddressEmptyCode on a target without code
            Address.verifyCallResultFromTarget(fuses[i], success, returnData);

            balanceOf = IERC20(assetAddress_).balanceOf(address(this));

            if (assets_ > balanceOf) {
                left = assets_ - balanceOf;
            } else {
                left = 0;
            }

            fuseMarketId = IFuseCommon(fuses[i]).MARKET_ID();

            if (_checkIfExistsMarket(markets, fuseMarketId) == false) {
                markets[marketIndex] = fuseMarketId;
                marketIndex++;
            }
        }
    }

    function _checkBalanceFusesDependencies(uint256[] memory markets_) private view returns (uint256[] memory) {
        uint256 marketsLength = markets_.length;
        if (marketsLength == 0) {
            return markets_;
        }
        uint256[] memory marketsChecked = new uint256[](marketsLength * 2);
        uint256[] memory marketsToCheck = markets_;
        uint256 index;
        uint256[] memory tempMarketsToCheck;

        while (marketsToCheck.length > 0) {
            tempMarketsToCheck = new uint256[](marketsLength * 2);
            uint256 tempIndex;

            for (uint256 i; i < marketsToCheck.length; ++i) {
                if (!_checkIfExistsMarket(marketsChecked, marketsToCheck[i])) {
                    if (marketsChecked.length == index) {
                        marketsChecked = _increaseArray(marketsChecked, marketsChecked.length * 2);
                    }

                    marketsChecked[index] = marketsToCheck[i];
                    ++index;

                    uint256[] memory dependentMarkets = PlasmaVaultLib.getDependencyBalanceGraph(marketsToCheck[i]);
                    uint256 dependentMarketsLength = dependentMarkets.length;
                    if (dependentMarketsLength > 0) {
                        for (uint256 j; j < dependentMarketsLength; ++j) {
                            if (tempMarketsToCheck.length == tempIndex) {
                                tempMarketsToCheck = _increaseArray(tempMarketsToCheck, tempMarketsToCheck.length * 2);
                            }
                            tempMarketsToCheck[tempIndex] = dependentMarkets[j];
                            ++tempIndex;
                        }
                    }
                }
            }
            marketsToCheck = _getUniqueElements(tempMarketsToCheck);
        }

        return _getUniqueElements(marketsChecked);
    }

    function _checkIfExistsMarket(uint256[] memory markets_, uint256 marketId_) private pure returns (bool exists) {
        for (uint256 i; i < markets_.length; ++i) {
            if (markets_[i] == 0) {
                break;
            }
            if (markets_[i] == marketId_) {
                exists = true;
                break;
            }
        }
    }

    function _increaseArray(uint256[] memory arr_, uint256 newSize_) private pure returns (uint256[] memory) {
        uint256[] memory result = new uint256[](newSize_);
        for (uint256 i; i < arr_.length; ++i) {
            result[i] = arr_[i];
        }
        return result;
    }

    function _getUniqueElements(uint256[] memory inputArray_) private pure returns (uint256[] memory) {
        uint256[] memory tempArray = new uint256[](inputArray_.length);
        uint256 count = 0;

        for (uint256 i; i < inputArray_.length; ++i) {
            if (inputArray_[i] != 0 && !_contains(tempArray, inputArray_[i], count)) {
                tempArray[count] = inputArray_[i];
                count++;
            }
        }

        uint256[] memory uniqueArray = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            uniqueArray[i] = tempArray[i];
        }

        return uniqueArray;
    }

    function _contains(uint256[] memory array_, uint256 element_, uint256 count_) private pure returns (bool) {
        for (uint256 i; i < count_; ++i) {
            if (array_[i] == element_) {
                return true;
            }
        }
        return false;
    }

    /// @notice Filters zero values from markets array
    /// @param markets_ Array that may contain zero values
    /// @return Compacted array without zero values
    function _filterZeroMarkets(uint256[] memory markets_) private pure returns (uint256[] memory) {
        uint256 length = markets_.length;
        if (length == 0) {
            return markets_;
        }

        // Count non-zero elements
        uint256 count;
        for (uint256 i; i < length; ++i) {
            if (markets_[i] != 0) {
                unchecked {
                    ++count;
                }
            }
        }

        // If all elements are non-zero, return original array
        if (count == length) {
            return markets_;
        }

        // Create compacted array
        uint256[] memory filtered = new uint256[](count);
        uint256 index;
        for (uint256 i; i < length; ++i) {
            if (markets_[i] != 0) {
                filtered[index] = markets_[i];
                ++index;
            }
        }

        return filtered;
    }
}
