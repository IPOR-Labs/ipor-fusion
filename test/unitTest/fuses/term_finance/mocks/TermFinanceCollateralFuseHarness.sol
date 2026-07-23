// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {TermFinanceCollateralFuse} from "contracts/fuses/term_finance/TermFinanceCollateralFuse.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";

/// @notice Test harness mirroring the `TermFinanceOfferFuseHarness` / `TermFinanceRedeemFuseHarness`
///         pattern: extends the fuse so calls run in the harness's storage context, with an
///         external setter for substrate allowlists.
/// @dev Substrates are written via `PlasmaVaultConfigLib.grantMarketSubstrates`. The WithdrawManager
///      storage slot is poked directly from the test using `vm.store` (see
///      `TermFinanceCollateralFuseTest._setWithdrawManager`).
contract TermFinanceCollateralFuseHarness is TermFinanceCollateralFuse {
    constructor(
        uint256 marketId_,
        address termController_
    ) TermFinanceCollateralFuse(marketId_, termController_) {}

    function setMarketSubstrates(uint256 marketId_, bytes32[] memory substrates_) external {
        PlasmaVaultConfigLib.grantMarketSubstrates(marketId_, substrates_);
    }
}
