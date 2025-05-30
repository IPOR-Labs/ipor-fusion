// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {IFuseCommon} from "../../fuses/IFuseCommon.sol";
import {DataToCheck, MarketToCheck} from "../../libraries/AssetDistributionProtectionLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {FusesLib} from "../../libraries/FusesLib.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";

library PlasmaVaultMarketsLib {
    using Address for address;
    event MarketBalancesUpdated(uint256[] marketIds, int256 deltaInUnderlying);

    function updateMarketsBalances(
        uint256[] memory markets_,
        address assetAddress_,
        uint256 decimals_,
        uint256 decimalsOffset_
    ) public returns (DataToCheck memory dataToCheck) {
        uint256 wadBalanceAmountInUSD;
        // DataToCheck memory dataToCheck;
        address balanceFuse;
        int256 deltasInUnderlying;
        uint256[] memory markets = _checkBalanceFusesDependencies(markets_);
        uint256 marketsLength = markets.length;

        /// @dev USD price is represented in 8 decimals
        (uint256 underlyingAssetPrice, uint256 underlyingAssePriceDecimals) = IPriceOracleMiddleware(
            PlasmaVaultLib.getPriceOracleMiddleware()
        ).getAssetPrice(assetAddress_);

        dataToCheck.marketsToCheck = new MarketToCheck[](marketsLength);

        for (uint256 i; i < marketsLength; ++i) {
            if (markets[i] == 0) {
                break;
            }

            balanceFuse = FusesLib.getBalanceFuse(markets[i]);

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
            params = PlasmaVaultLib.getInstantWithdrawalFusesParams(fuses[i], i);

            /// @dev always first param is amount, by default is 0 in storage, set to left
            params[0] = bytes32(left);

            fuses[i].functionDelegateCall(abi.encodeWithSignature("instantWithdraw(bytes32[])", params));

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

                    uint256 dependentMarketsLength = PlasmaVaultLib.getDependencyBalanceGraph(marketsToCheck[i]).length;
                    if (dependentMarketsLength > 0) {
                        for (uint256 j; j < dependentMarketsLength; ++j) {
                            if (tempMarketsToCheck.length == tempIndex) {
                                tempMarketsToCheck = _increaseArray(tempMarketsToCheck, tempMarketsToCheck.length * 2);
                            }
                            tempMarketsToCheck[tempIndex] = PlasmaVaultLib.getDependencyBalanceGraph(marketsToCheck[i])[
                                j
                            ];
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
}
