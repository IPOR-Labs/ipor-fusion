// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

library EbisuMathLib {
    /// @notice calculates the trove id (given by Liquity), as a function of our ownerIndex (given by us)
    function calculateTroveId(address ethAdapter_, address plasmaVault_, address zapper_, uint256 ownerIndex_) internal pure returns (uint256 troveId) {
        // since Ebisu hides the troveId return value
        // we need to calculate it following Ebisu and Liquity algorithm
        uint256 ebisuId = uint256(keccak256(abi.encode(ethAdapter_, ownerIndex_)));
        troveId = uint256(keccak256(abi.encode(zapper_, plasmaVault_, ebisuId)));
    }
}