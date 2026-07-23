// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {TermFinanceSubstrateLib, TermFinanceSubstrateType} from "../../../../../../contracts/fuses/term_finance/lib/TermFinanceSubstrateLib.sol";

/// @title TermFinanceSubstrateLibHarness
/// @notice External wrapper around the internal `TermFinanceSubstrateLib` functions so that
///         Foundry's coverage tooling can attribute branch hits back to the library.
contract TermFinanceSubstrateLibHarness {
    function collateralPairKey(address servicer_, address collateralToken_) external pure returns (bytes32) {
        return TermFinanceSubstrateLib.collateralPairKey(servicer_, collateralToken_);
    }

    function decodeSubstrateType(bytes32 substrate_) external pure returns (TermFinanceSubstrateType) {
        return TermFinanceSubstrateLib.decodeSubstrateType(substrate_);
    }

    function decodeAddress(bytes32 substrate_) external pure returns (address) {
        return TermFinanceSubstrateLib.decodeAddress(substrate_);
    }

    function isServicerSubstrate(bytes32 raw_) external pure returns (bool) {
        return TermFinanceSubstrateLib.isServicerSubstrate(raw_);
    }

    function isCollateralTokenSubstrate(bytes32 raw_) external pure returns (bool) {
        return TermFinanceSubstrateLib.isCollateralTokenSubstrate(raw_);
    }
}
