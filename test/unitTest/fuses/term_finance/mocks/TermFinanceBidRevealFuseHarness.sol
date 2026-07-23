// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {TermFinanceBidRevealFuse} from "contracts/fuses/term_finance/TermFinanceBidRevealFuse.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";

/// @notice Harness exposing internal substrate configuration on `TermFinanceBidRevealFuse`
///         for unit testing. Mirror of `TermFinanceOfferRevealFuseHarness`.
contract TermFinanceBidRevealFuseHarness is TermFinanceBidRevealFuse {
    constructor(uint256 marketId_, address termController_) TermFinanceBidRevealFuse(marketId_, termController_) {}

    function setMarketSubstrates(uint256 marketId_, bytes32[] memory substrates_) external {
        PlasmaVaultConfigLib.grantMarketSubstrates(marketId_, substrates_);
    }
}
