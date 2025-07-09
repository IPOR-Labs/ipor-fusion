// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IStaking, Coin, UnbondingDelegationOutput} from "./ext/IStaking.sol";
import {TacStakingStorageLib} from "./TacStakingStorageLib.sol";
import {TacValidatorAddressConverter} from "./TacValidatorAddressConverter.sol";
contract TacStakingBalanceFuse is IMarketBalanceFuse {
    using SafeCast for uint256;
    using Address for address;

    error TacStakingBalanceFuseInvalidWtacAddress();
    error TacStakingBalanceFuseInvalidPriceOracleMiddleware();
    error TacStakingBalanceFuseInvalidSubstrateLength();

    uint256 public immutable MARKET_ID;
    address public immutable W_TAC;
    address public immutable STAKING;

    constructor(uint256 marketId_, address staking_, address wTAC_) {
        if (wTAC_ == address(0)) {
            revert TacStakingBalanceFuseInvalidWtacAddress();
        }

        MARKET_ID = marketId_;
        W_TAC = wTAC_;
        STAKING = staking_;
    }

    function balanceOf() external view override returns (uint256 balanceInUSD) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        if (substrates.length == 0) {
            return 0;
        }

        if (substrates.length % 2 != 0) {
            revert TacStakingBalanceFuseInvalidSubstrateLength();
        }

        address tacStakingExecutor = TacStakingStorageLib.getTacStakingExecutor();

        if (tacStakingExecutor == address(0)) {
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

        for (uint256 i; i < substrates.length; i += 2) {
            if (i + 1 >= substrates.length) {
                break;
            }

            if (i % 2 != 0) {
                continue;
            }

            validatorAddress = TacValidatorAddressConverter.bytes32ToValidatorAddress(substrates[i], substrates[i + 1]);

            if (bytes(validatorAddress).length > 0) {
                (, balance) = IStaking(STAKING).delegation(tacStakingExecutor, validatorAddress);

                if (balance.amount > 0) {
                    totalBalance += balance.amount;
                }

                unbondingDelegation = IStaking(STAKING).unbondingDelegation(tacStakingExecutor, validatorAddress);

                for (uint256 j; j < unbondingDelegation.entries.length; ++j) {
                    totalBalance += unbondingDelegation.entries[j].balance;
                }
            }
        }

        /// @dev Take into consideration the balance of the executor in Native token
        totalBalance += address(tacStakingExecutor).balance;

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
