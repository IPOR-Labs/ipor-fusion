// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

library EbisuMathLib {
    function calculateTroveId(address ethAdapter, address plasmaVault, address zapper, uint256 ownerId) internal pure returns (uint256 liquityId) {
        // since Ebisu hides the troveId return value
        // we need to calculate it following Ebisu and Liquity algorithm

        // LeverageLSTZapper.sol: _params.ownerIndex = _getTroveIndex(msg.sender, _params.ownerIndex);
        uint256 ebisuId = uint256(keccak256(abi.encode(ethAdapter, ownerId)));

        // LeverageLSTZapper.sol: troveId = borrowerOperations.openTrove(... _params.ownerIndex, ...);
        // BorrowerOperations.sol: vars.troveId = uint256(keccak256(abi.encode(msg.sender, _owner, _ownerIndex)));
        liquityId = uint256(keccak256(abi.encode(zapper, plasmaVault, ebisuId)));
    }
}