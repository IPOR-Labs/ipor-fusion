// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {IStaking, Coin, UnbondingDelegationOutput} from "./ext/IStaking.sol";
import {TacStakingStorageLib} from "./lib/TacStakingStorageLib.sol";
import {TacValidatorAddressConverter} from "./lib/TacValidatorAddressConverter.sol";

contract TacStakingBalanceFuse is IMarketBalanceFuse {
    using SafeCast for uint256;
    using Address for address;

    error TacStakingBalanceFuseInvalidWtacAddress();
    error TacStakingBalanceFuseInvalidStakingAddress();
    error TacStakingBalanceFuseInvalidPriceOracleMiddleware();
    error TacStakingBalanceFuseInvalidSubstrateLength();

    uint256 public immutable MARKET_ID;
    address public immutable W_TAC;
    address public immutable STAKING;

    constructor(uint256 marketId_, address wTAC_, address staking_) {
        if (wTAC_ == address(0)) {
            revert TacStakingBalanceFuseInvalidWtacAddress();
        }

        if (staking_ == address(0)) {
            revert TacStakingBalanceFuseInvalidStakingAddress();
        }

        MARKET_ID = marketId_;
        W_TAC = wTAC_;
        STAKING = staking_;
    }

    function balanceOf() external view override returns (uint256 balanceInUSD) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 substratesLength = substrates.length;

        if (substratesLength == 0) {
            return 0;
        }

        if (substratesLength % 2 != 0) {
            revert TacStakingBalanceFuseInvalidSubstrateLength();
        }

        address tacStakingDelegator = TacStakingStorageLib.getTacStakingDelegator();

        if (tacStakingDelegator == address(0)) {
            return 0;
        }

        /// @dev Get price oracle middleware to convert TAC balance to USD
        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();

        if (priceOracleMiddleware == address(0)) {
            revert TacStakingBalanceFuseInvalidPriceOracleMiddleware();
        }

        uint256 totalBalance = 0;

        string memory validatorAddress;
        Coin memory balance;
        UnbondingDelegationOutput memory unbondingDelegation;

        uint256 entriesLength;

        for (uint256 i; i < substratesLength - 1; i += 2) {
            validatorAddress = TacValidatorAddressConverter.bytes32ToValidatorAddress(substrates[i], substrates[i + 1]);

            if (bytes(validatorAddress).length > 0) {
                (, balance) = IStaking(STAKING).delegation(tacStakingDelegator, validatorAddress);

                totalBalance += balance.amount;

                unbondingDelegation = IStaking(STAKING).unbondingDelegation(tacStakingDelegator, validatorAddress);
                entriesLength = unbondingDelegation.entries.length;

                for (uint256 j; j < entriesLength; ++j) {
                    totalBalance += unbondingDelegation.entries[j].balance;
                }
            }
        }

        /// @dev Take into consideration the balance of the executor in Native token
        totalBalance += address(tacStakingDelegator).balance;

        /// @dev Convert TAC balance to USD using price oracle middleware
        /// @dev Use wTAC address for pricing since native TAC and wTAC have 1:1 relationship
        if (totalBalance > 0) {
            (uint256 wTacPrice, uint256 wTacPriceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware)
                .getAssetPrice(W_TAC);
            if (wTacPrice > 0) {
                balanceInUSD = IporMath.convertToWad(totalBalance * wTacPrice, 18 + wTacPriceDecimals);
            }
        }
    }
}
