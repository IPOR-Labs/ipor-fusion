// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {TermFinanceRedeemFuse} from "contracts/fuses/term_finance/TermFinanceRedeemFuse.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";

contract TermFinanceRedeemFuseHarness is TermFinanceRedeemFuse {
    constructor(uint256 marketId_, address termController_) TermFinanceRedeemFuse(marketId_, termController_) {}

    function setMarketSubstrates(uint256 marketId_, bytes32[] memory substrates_) external {
        PlasmaVaultConfigLib.grantMarketSubstrates(marketId_, substrates_);
    }
}
