// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AgreementDetails} from "../../../contracts/safe-harbor/ext/IAgreement.sol";

/// @title ISafeHarborAgreementFactory
/// @author IPOR Labs
/// @notice V3 factory ABI pinned to safe-harbor commit 78ba9237377a9622439cbab41a5336673cea1b92.
interface ISafeHarborAgreementFactory {
    /// @notice Creates an Agreement with the supplied legal terms and initial owner.
    /// @param details_ Legal terms and covered chains.
    /// @param validator_ Deployed SEAL chain validator.
    /// @param owner_ Initial Agreement owner.
    /// @param salt_ Deployment salt.
    /// @return Deployed Agreement address.
    function create(AgreementDetails memory details_, address validator_, address owner_, bytes32 salt_)
        external
        returns (address);
}
