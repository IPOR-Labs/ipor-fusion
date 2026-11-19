// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

/// @title PlasmaVaultLibraryAbiCompletenessTest
/// @notice Every event and error of the libraries PlasmaVault runs under delegatecall for markets and fees
///         must be declared in the PlasmaVault ABI.
/// @dev The libraries emit and revert from the vault address, but explorers, indexers, Safe and `cast` decode
///      them only if the vault ABI declares them. Reads the compiled artifacts under `out/` (default profile).
contract PlasmaVaultLibraryAbiCompletenessTest is Test {
    function testShouldCoverPlasmaVaultMarketsLibInAbi() public view {
        _assertAbiComplete("PlasmaVaultMarketsLib");
    }

    function testShouldCoverPlasmaVaultFeesLibInAbi() public view {
        _assertAbiComplete("PlasmaVaultFeesLib");
    }

    function _assertAbiComplete(string memory lib) internal view {
        string memory hostJson = vm.readFile(_artifactPath("PlasmaVault"));
        string memory libJson = vm.readFile(_artifactPath(lib));
        for (uint256 t; t < 2; ++t) {
            string memory kind = t == 0 ? "event" : "error";
            string[] memory libSigs = _signatures(libJson, kind);
            assertGt(libSigs.length, 0, string.concat(lib, ": no ", kind, " found in artifact"));
            string[] memory hostSigs = _signatures(hostJson, kind);
            for (uint256 s; s < libSigs.length; ++s) {
                assertTrue(
                    _contains(hostSigs, libSigs[s]),
                    string.concat("PlasmaVault ABI is missing ", kind, " ", libSigs[s], " (from ", lib, ")")
                );
            }
        }
    }

    function _artifactPath(string memory name) internal pure returns (string memory) {
        return string.concat("out/", name, ".sol/", name, ".json");
    }

    /// @dev `name(type,type,...)` of every ABI entry of the given kind ("event" or "error").
    function _signatures(string memory json, string memory kind) internal view returns (string[] memory sigs) {
        string[] memory tmp = new string[](256);
        uint256 n;
        for (uint256 i; ; ++i) {
            string memory p = string.concat(".abi[", vm.toString(i), "]");
            if (!vm.keyExistsJson(json, p)) break;
            if (keccak256(bytes(vm.parseJsonString(json, string.concat(p, ".type")))) != keccak256(bytes(kind))) {
                continue;
            }
            string memory sig = string.concat(vm.parseJsonString(json, string.concat(p, ".name")), "(");
            for (uint256 k; ; ++k) {
                string memory ip = string.concat(p, ".inputs[", vm.toString(k), "].type");
                if (!vm.keyExistsJson(json, ip)) break;
                sig = string.concat(sig, k == 0 ? "" : ",", vm.parseJsonString(json, ip));
            }
            tmp[n++] = string.concat(sig, ")");
        }
        sigs = new string[](n);
        for (uint256 i; i < n; ++i) sigs[i] = tmp[i];
    }

    function _contains(string[] memory a, string memory x) internal pure returns (bool) {
        bytes32 hx = keccak256(bytes(x));
        for (uint256 i; i < a.length; ++i) {
            if (keccak256(bytes(a[i])) == hx) return true;
        }
        return false;
    }
}
