// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPool} from "./ext/IPool.sol";

enum BalancerSubstrateType {
    UNDEFINED,
    GAUGE,
    POOL
}

struct BalancerSubstrate {
    BalancerSubstrateType substrateType;
    address substrateAddress;
}

library BalancerSubstrateLib {
    error TokensNotInPool(address pool, address token);

    function substrateToBytes32(BalancerSubstrate memory substrate_) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(substrate_.substrateAddress)) | (uint256(substrate_.substrateType) << 160));
    }

    function bytes32ToSubstrate(bytes32 bytes32Substrate_) internal pure returns (BalancerSubstrate memory substrate) {
        substrate.substrateType = BalancerSubstrateType(uint256(bytes32Substrate_) >> 160);
        substrate.substrateAddress = PlasmaVaultConfigLib.bytes32ToAddress(bytes32Substrate_);
    }

    /**
     * @notice Computes the proportional amounts of tokens to be withdrawn from the pool.
     * @dev This function computes the amount of each token that will be withdrawn in exchange for burning
     * a specific amount of pool tokens (BPT). It ensures that the amounts of tokens withdrawn are proportional
     * to the current pool balances.
     *
     * Calculation: For each token, amountOut = balance * (bptAmountIn / bptTotalSupply).
     * Rounding down is used to prevent withdrawing more than the pool can afford.
     *
     * @param balances Array of current token balances in the pool in 18 decimals
     * @param bptTotalSupply Total supply of the pool tokens (BPT)
     * @param bptAmountIn The amount of pool tokens that will be burned
     * @return amountsOut Array of amounts for each token to be withdrawn in 18 decimals
     */
    function computeProportionalAmountsOut(
        uint256[] memory balances,
        uint256 bptTotalSupply,
        uint256 bptAmountIn
    ) internal pure returns (uint256[] memory amountsOut) {
        /**********************************************************************************************
        // computeProportionalAmountsOut                                                             //
        // (per token)                                                                               //
        // aO = tokenAmountOut             /        bptIn         \                                  //
        // b = tokenBalance      a0 = b * | ---------------------  |                                 //
        // bptIn = bptAmountIn             \     bptTotalSupply    /                                 //
        // bpt = bptTotalSupply                                                                      //
        **********************************************************************************************/

        uint256 len = balances.length;
        // Create a new array to hold the amounts of each token to be withdrawn.
        amountsOut = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            // Since we multiply and divide we don't need to use FP math.
            // Round down since we're calculating amounts out.
            amountsOut[i] = (balances[i] * bptAmountIn) / bptTotalSupply;
        }
    }

    function checkTokensInPool(address pool_, address[] memory tokens_) internal view {
        (IERC20[] memory tokens, , , ) = IPool(pool_).getTokenInfo();
        uint256 tokensToCheckLength = tokens_.length;
        uint256 tokensLength = tokens.length;
        address token;
        bool tokenFound;
        for (uint256 i; i < tokensToCheckLength; ++i) {
            token = tokens_[i];
            tokenFound = false;

            for (uint256 j; j < tokensLength; ++j) {
                if (address(tokens[j]) == token) {
                    tokenFound = true;
                    break;
                }
            }

            if (!tokenFound) {
                revert TokensNotInPool(pool_, tokens_[i]);
            }
        }
    }
}
