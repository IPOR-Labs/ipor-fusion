// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

library EbisuMathLibrary {
    function calculateTroveId(address plasmaVault, address zapper, uint256 ownerId) internal pure returns (uint256) {
        // since Ebisu hides the troveId return value
        // we need to calculate it following Ebisu and Liquity algorithm
        uint256 ebisuId = uint256(keccak256(abi.encode(plasmaVault, ownerId)));
        uint256 liquityId = uint256(keccak256(abi.encode(zapper, plasmaVault, ebisuId)));
        return liquityId;
    }
}