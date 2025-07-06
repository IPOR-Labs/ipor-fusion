// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IStaking, Coin, UnbondingDelegationOutput, Validator} from "./ext/IStaking.sol";
import {TacStakingStorageLib} from "./TacStakingStorageLib.sol";

contract TacStakingBalanceFuse is IMarketBalanceFuse {
    using SafeCast for uint256;
    using Address for address;

    error TacStakingBalanceFuseInvalidWtacAddress();

    uint256 public immutable MARKET_ID;
    address public immutable staking;
    address public immutable wTAC;

    constructor(uint256 marketId_, address staking_, address wTAC_) {
        if (wTAC_ == address(0)) {
            revert TacStakingBalanceFuseInvalidWtacAddress();
        }

        MARKET_ID = marketId_;
        staking = staking_;
        wTAC = wTAC_;
    }

    function balanceOf() external view override returns (uint256) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        if (substrates.length == 0) {
            return 0;
        }

        uint256 totalBalance = 0;

        address tacStakingExecutor = TacStakingStorageLib.getTacStakingExecutor();

        if (tacStakingExecutor == address(0)) {
            return 0;
        }

        /// @dev Get price oracle middleware to convert TAC balance to USD
        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();

        /// @dev Take into consideration the balance of the executor in Native token
        totalBalance += address(tacStakingExecutor).balance;

        for (uint256 i = 0; i < substrates.length; ++i) {
            bytes32 substrate = substrates[i];

            address validatorAddress = PlasmaVaultConfigLib.bytes32ToAddress(substrate);

            try IStaking(staking).validator(validatorAddress) returns (Validator memory validator) {
                string memory operatorAddress = validator.operatorAddress;

                uint256 shares;
                Coin memory balance;

                try IStaking(staking).delegation(tacStakingExecutor, operatorAddress) returns (
                    uint256 _shares,
                    Coin memory _balance
                ) {
                    shares = _shares;
                    balance = _balance;
                } catch {
                    shares = 0;
                    balance = Coin("", 0);
                }

                if (balance.amount > 0) {
                    // For TAC staking, we use the balance amount from the Coin struct
                    // This represents the actual staked amount in the native token
                    totalBalance += balance.amount;
                }

                // Get unbonding delegation balance using operator address
                try IStaking(staking).unbondingDelegation(tacStakingExecutor, operatorAddress) returns (
                    UnbondingDelegationOutput memory unbondingDelegation
                ) {
                    // Sum up all unbonding entries for this validator
                    for (uint256 j = 0; j < unbondingDelegation.entries.length; ++j) {
                        totalBalance += unbondingDelegation.entries[j].balance;
                    }
                } catch {
                    // If unbonding delegation query fails, continue with next validator
                    continue;
                }
            } catch {
                // If validator query fails, continue with next substrate
                continue;
            }
        }

        /// @dev Convert TAC balance to USD using price oracle middleware
        /// @dev Use wTAC address for pricing since native TAC and wTAC have 1:1 relationship
        if (totalBalance > 0 && priceOracleMiddleware != address(0) && wTAC != address(0)) {
            (uint256 tacPrice, uint256 priceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware).getAssetPrice(wTAC);
            if (tacPrice > 0) {
                totalBalance = IporMath.convertToWad(totalBalance * tacPrice, 18 + priceDecimals);
            }
        }

        return totalBalance;
    }
}
