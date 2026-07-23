// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {TermFinanceOfferRevealFuse} from "contracts/fuses/term_finance/TermFinanceOfferRevealFuse.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";

contract TermFinanceOfferRevealFuseHarness is TermFinanceOfferRevealFuse {
    constructor(uint256 marketId_, address termController_) TermFinanceOfferRevealFuse(marketId_, termController_) {}

    function setMarketSubstrates(uint256 marketId_, bytes32[] memory substrates_) external {
        PlasmaVaultConfigLib.grantMarketSubstrates(marketId_, substrates_);
    }
}
