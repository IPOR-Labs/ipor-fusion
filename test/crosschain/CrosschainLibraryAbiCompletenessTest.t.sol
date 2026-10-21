// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

/// @title CrosschainLibraryAbiCompletenessTest
/// @notice Every event and error of every (transitively) linked library must be declared in the ABI of the
///         host contract that links it.
/// @dev Linked libraries run under delegatecall, so their events and errors are emitted from / raised by the
///      host address, but explorers, indexers, Safe and `cast` decode them only if the host ABI declares them.
///      The check reads the compiled artifacts under `out/`: the libraries of each host are discovered from
///      `deployedBytecode.linkReferences` (transitively), so a newly linked library is picked up automatically.
///      The library list per host is also pinned (`_expectedLibraries`) and must equal the artifact's
///      `linkReferences` set, so a library added or removed without updating the pin fails the test.
contract CrosschainLibraryAbiCompletenessTest is Test {
    function testShouldCoverStargateExecutorLibrariesInAbi() public view {
        _assertHostAbiComplete("StargateCrosschainExecutor");
    }

    function testShouldCoverStargateDispatcherLibrariesInAbi() public view {
        _assertHostAbiComplete("StargateCrosschainDispatcher");
    }

    function testShouldCoverStargateFactoryLibrariesInAbi() public view {
        _assertHostAbiComplete("StargateCrosschainFactory");
    }

    function testShouldCoverCcipExecutorLibrariesInAbi() public view {
        _assertHostAbiComplete("CcipCrosschainExecutor");
    }

    function testShouldCoverCcipDispatcherLibrariesInAbi() public view {
        _assertHostAbiComplete("CcipCrosschainDispatcher");
    }

    function testShouldCoverCcipFactoryLibrariesInAbi() public view {
        _assertHostAbiComplete("CcipCrosschainFactory");
    }

    function _assertHostAbiComplete(string memory host) internal view {
        string memory hostJson = vm.readFile(_artifactPath(host, host));
        string[] memory libs = _expectedLibraries(host);

        // linkReferences (populated under the deploy profile) must match the pinned list, transitively.
        string[] memory linked = _linkedLibrariesTransitive(host);
        assertGt(linked.length, 0, string.concat(host, ": no linkReferences found in artifact"));
        for (uint256 i; i < linked.length; ++i) {
            assertTrue(
                _contains(libs, linked[i]),
                string.concat(host, ": linked library missing from _expectedLibraries: ", linked[i])
            );
        }
        for (uint256 i; i < libs.length; ++i) {
            assertTrue(
                _contains(linked, libs[i]),
                string.concat(host, ": _expectedLibraries entry is not linked: ", libs[i])
            );
        }

        for (uint256 t; t < 2; ++t) {
            string memory kind = t == 0 ? "event" : "error";
            string[] memory hostSigs = _signatures(hostJson, kind);
            for (uint256 l; l < libs.length; ++l) {
                string[] memory libSigs = _signatures(vm.readFile(_artifactPath(libs[l], libs[l])), kind);
                for (uint256 s; s < libSigs.length; ++s) {
                    assertTrue(
                        _contains(hostSigs, libSigs[s]),
                        string.concat(host, " ABI is missing ", kind, " ", libSigs[s], " (from ", libs[l], ")")
                    );
                }
            }
        }
    }

    /// @dev Libraries each host may run (directly or transitively). Must equal the artifacts'
    ///      `linkReferences` set (asserted in `_assertHostAbiComplete`).
    function _expectedLibraries(string memory host) internal pure returns (string[] memory libs) {
        bytes32 h = keccak256(bytes(host));
        if (h == keccak256("StargateCrosschainExecutor")) {
            libs = new string[](7);
            libs[0] = "StargateExecutorAccountingLib";
            libs[1] = "StargateExecutorAttestationLib";
            libs[2] = "StargateExecutorDeploymentLib";
            libs[3] = "StargateLzSendLib";
            libs[4] = "StargateAssetSendLib";
            libs[5] = "RescueLogicLib";
            libs[6] = "StargateExecutorCommandLib";
        } else if (h == keccak256("StargateCrosschainDispatcher")) {
            libs = new string[](5);
            libs[0] = "StargateLzSendLib";
            libs[1] = "StargateAssetSendLib";
            libs[2] = "RescueLogicLib";
            libs[3] = "CrosschainVaultActionLib";
            libs[4] = "StargateDispatcherLib";
        } else if (h == keccak256("StargateCrosschainFactory")) {
            libs = new string[](3);
            libs[0] = "StargateLzSendLib";
            libs[1] = "RescueLogicLib";
            libs[2] = "StargateFactoryLib";
        } else if (h == keccak256("CcipCrosschainExecutor")) {
            libs = new string[](7);
            libs[0] = "CcipExecutorAttestationLib";
            libs[1] = "CcipExecutorCommandLib";
            libs[2] = "CcipExecutorTransferLib";
            libs[3] = "CcipDecimalsLib";
            libs[4] = "CcipRouteLib";
            libs[5] = "CcipSendLib";
            libs[6] = "RescueLogicLib";
        } else if (h == keccak256("CcipCrosschainDispatcher")) {
            libs = new string[](5);
            libs[0] = "CcipRouteLib";
            libs[1] = "CcipSendLib";
            libs[2] = "RescueLogicLib";
            libs[3] = "CrosschainVaultActionLib";
            libs[4] = "CcipDispatcherLib";
        } else if (h == keccak256("CcipCrosschainFactory")) {
            libs = new string[](2);
            libs[0] = "CcipRouteLib";
            libs[1] = "CcipSendLib";
        } else {
            revert(string.concat("unknown host ", host));
        }
    }

    function _artifactPath(string memory file, string memory contractName) internal pure returns (string memory) {
        return string.concat("out/", file, ".sol/", contractName, ".json");
    }

    /// @dev Names of the libraries in `deployedBytecode.linkReferences`, followed transitively.
    function _linkedLibrariesTransitive(string memory host) internal view returns (string[] memory out) {
        string[] memory queue = new string[](32);
        string[] memory seen = new string[](32);
        uint256 head;
        uint256 tail;
        uint256 n;
        queue[tail++] = host;
        while (head < tail) {
            string memory json = vm.readFile(_artifactPath(queue[head], queue[head]));
            ++head;
            string memory base = ".deployedBytecode.linkReferences";
            if (!vm.keyExistsJson(json, base)) continue;
            string[] memory files = vm.parseJsonKeys(json, base);
            for (uint256 f; f < files.length; ++f) {
                string[] memory names = vm.parseJsonKeys(json, string.concat(base, _bracketKey(files[f])));
                for (uint256 k; k < names.length; ++k) {
                    if (_contains(_slice(seen, n), names[k])) continue;
                    seen[n++] = names[k];
                    queue[tail++] = names[k];
                }
            }
        }
        out = _slice(seen, n);
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
        sigs = _slice(tmp, n);
    }

    function _slice(string[] memory a, uint256 n) internal pure returns (string[] memory r) {
        r = new string[](n);
        for (uint256 i; i < n; ++i) r[i] = a[i];
    }

    function _contains(string[] memory a, string memory x) internal pure returns (bool) {
        bytes32 hx = keccak256(bytes(x));
        for (uint256 i; i < a.length; ++i) {
            if (keccak256(bytes(a[i])) == hx) return true;
        }
        return false;
    }

    /// @dev JSONPath bracket key `["<key>"]`; the quote is built as a byte so no string literal needs escaping
    ///      (prettier and solhint `quotes` disagree on escaped quotes).
    function _bracketKey(string memory key_) private pure returns (string memory) {
        return string(abi.encodePacked("[", bytes1(0x22), key_, bytes1(0x22), "]"));
    }
}
