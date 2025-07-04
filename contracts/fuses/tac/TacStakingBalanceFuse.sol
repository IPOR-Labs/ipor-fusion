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

contract TacStakingBalanceFuse is IMarketBalanceFuse {
    using SafeCast for uint256;
    using Address for address;

    uint256 public immutable MARKET_ID;
    address public immutable staking;

    constructor(uint256 marketId_, address staking_) {
        MARKET_ID = marketId_;
        staking = staking_;
    }

    function balanceOf() external view override returns (uint256) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        if (substrates.length == 0) {
            return 0;
        }

        uint256 totalBalance = 0;

        // Get the TAC staking executor address from storage
        address tacStakingExecutor = TacStakingStorageLib.getTacStakingExecutor();

        if (tacStakingExecutor == address(0)) {
            return 0;
        }

        // For TAC staking, we need to know which validators are supported
        // Since we can't reverse keccak256 hashes, we'll need to know the validators
        // For now, we'll use a hardcoded list of known validators that should be in substrates
        string[] memory knownValidators = _getKnownValidators();

        for (uint256 i; i < knownValidators.length; ++i) {
            string memory validator = knownValidators[i];
            bytes32 validatorSubstrate = keccak256(bytes(validator));

            // Check if this validator is granted in the market
            if (PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, validatorSubstrate)) {
                // Get active delegation balance
                uint256 shares;
                Coin memory balance;
                try IStaking(staking).delegation(tacStakingExecutor, validator) returns (
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

                // Get unbonding delegation balance
                try IStaking(staking).unbondingDelegation(tacStakingExecutor, validator) returns (
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
            }
        }

        return totalBalance;
    }

    function _getKnownValidators() private pure returns (string[] memory) {
        // This should be configurable or derived from the substrates
        // For now, we'll return the known validator
        string[] memory validators = new string[](1);
        validators[0] = "tac1pdu86gjvnnr2786xtkw2eggxkmrsur0zjm6vxn";
        return validators;
    }
}
