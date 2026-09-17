// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

import {FusionFactory} from "../../contracts/factory/FusionFactory.sol";
import {FusionFactoryLogicLib} from "../../contracts/factory/lib/FusionFactoryLogicLib.sol";

/// @title Fork upgrade tests for the FusionFactory vault registry (IL-8227)
/// @notice Upgrades the live FusionFactory proxy to an implementation with isFusionVault and checks that
/// the registry records only vaults created after the upgrade
/// @dev The new FusionFactoryLib and FusionFactory are linked by hand from the compiled artifacts. Foundry's
/// automatic linking would deploy a fresh FusionFactoryLogicLib, while production reuses the one already
/// deployed on each chain, so the test links to that on-chain address and verifies it in runtime bytecode.
/// Artifacts are read from FOUNDRY_OUT (default "out", relative to the project root) and must match the bytecode
/// of the current build, so a stale or foreign output directory fails instead of being used. To exercise the
/// deploy-profile bytecode, run with FOUNDRY_OPTIMIZER_RUNS=200 FOUNDRY_OUT=out200 and --cache-path cache200.
abstract contract FusionFactoryVaultRegistryUpgradeForkTestBase is Test {
    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fusion.factory.FusionVaults")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant FUSION_VAULTS_SLOT = 0xd8f986f99805409cbb90b99bdf93bd9819d8b8f9dd5c2456ffaf840ff9eb8900;
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    uint256 internal constant EIP170_MAX_RUNTIME_SIZE = 24_576;
    uint256 internal constant REDEMPTION_DELAY_IN_SECONDS = 1 days;
    uint256 internal constant DAO_FEE_PACKAGE_INDEX = 0;

    string internal constant FUSION_FACTORY_LIB_ARTIFACT = "/FusionFactoryLib.sol/FusionFactoryLib.json";
    string internal constant FUSION_FACTORY_ARTIFACT = "/FusionFactory.sol/FusionFactory.json";
    string internal constant FUSION_FACTORY_FQN = "contracts/factory/FusionFactory.sol:FusionFactory";
    string internal constant FUSION_FACTORY_LIB_FQN = "contracts/factory/lib/FusionFactoryLib.sol:FusionFactoryLib";
    string internal constant FUSION_FACTORY_LOGIC_LIB_FQN =
        "contracts/factory/lib/FusionFactoryLogicLib.sol:FusionFactoryLogicLib";

    struct ChainConfig {
        string rpcEnv;
        uint256 forkBlock;
        address fusionFactoryProxy;
        address implementation;
        address fusionFactoryLib;
        address fusionFactoryLogicLib;
        uint256 fusionFactoryLogicLibRuntimeSize;
        address usdc;
    }

    struct UpgradeResult {
        address newFusionFactoryLib;
        address newImplementation;
    }

    ChainConfig internal config;
    FusionFactory internal fusionFactory;
    address internal vaultOwner;
    address internal maintenanceManager;

    function _chainConfig() internal pure virtual returns (ChainConfig memory);

    function setUp() public {
        config = _chainConfig();
        vm.createSelectFork(vm.envString(config.rpcEnv), config.forkBlock);
        fusionFactory = FusionFactory(config.fusionFactoryProxy);
        vaultOwner = makeAddr("vaultOwner");
        maintenanceManager = makeAddr("maintenanceManager");
    }

    /// @notice Pinned proxy implementation and library links still match the chain
    function testForkShouldMatchPinnedOnChainFusionFactoryDeployment() public view {
        _assertPinnedOnChainDeployment();
    }

    /// @notice New FusionFactoryLib links the on-chain FusionFactoryLogicLib and the new implementation links the new FusionFactoryLib
    function testForkShouldLinkNewLibrariesToOnChainFusionFactoryLogicLib() public {
        // given
        _assertPinnedOnChainDeployment();

        // when
        UpgradeResult memory result = _deployLinkedImplementation();

        // then
        bytes memory newLibCode = result.newFusionFactoryLib.code;
        bytes memory newImplementationCode = result.newImplementation.code;

        _assertLinkedRuntime(
            newLibCode,
            FUSION_FACTORY_LIB_ARTIFACT,
            FUSION_FACTORY_LIB_FQN,
            FUSION_FACTORY_LOGIC_LIB_FQN,
            config.fusionFactoryLogicLib,
            result.newFusionFactoryLib
        );
        _assertLinkedRuntime(
            newImplementationCode,
            FUSION_FACTORY_ARTIFACT,
            FUSION_FACTORY_FQN,
            FUSION_FACTORY_LIB_FQN,
            result.newFusionFactoryLib,
            result.newImplementation
        );

        assertEq(
            _countAddressOccurrences(newImplementationCode, config.fusionFactoryLib),
            0,
            "new implementation must not reference the old FusionFactoryLib"
        );
        assertEq(
            _countAddressOccurrences(newImplementationCode, config.fusionFactoryLogicLib),
            0,
            "new implementation must reach FusionFactoryLogicLib only through FusionFactoryLib"
        );

        assertLt(newLibCode.length, EIP170_MAX_RUNTIME_SIZE, "new FusionFactoryLib exceeds EIP-170");
        assertLt(newImplementationCode.length, EIP170_MAX_RUNTIME_SIZE, "new FusionFactory exceeds EIP-170");

        emit log_named_uint("new FusionFactoryLib runtime size (artifact build)", newLibCode.length);
        emit log_named_uint("new FusionFactory runtime size (artifact build)", newImplementationCode.length);
    }

    /// @notice Upgrade keeps version and index, leaves pre-upgrade vaults unregistered and registers clone and cloneSupervised results
    function testForkShouldPreserveStateAndRegisterOnlyVaultsClonedAfterUpgrade() public {
        // given
        _assertPinnedOnChainDeployment();

        address admin = fusionFactory.getRoleMember(DEFAULT_ADMIN_ROLE, 0);
        uint256 versionBefore = fusionFactory.getFusionFactoryVersion();
        uint256 indexBefore = fusionFactory.getFusionFactoryIndex();
        assertGt(fusionFactory.getDaoFeePackagesLength(), DAO_FEE_PACKAGE_INDEX, "DAO fee package missing");

        FusionFactoryLogicLib.FusionInstance memory instanceBefore = fusionFactory.clone(
            "Registry Pre Upgrade Vault",
            "RPUV",
            config.usdc,
            REDEMPTION_DELAY_IN_SECONDS,
            vaultOwner,
            DAO_FEE_PACKAGE_INDEX
        );
        address vaultBefore = instanceBefore.plasmaVault;

        assertEq(instanceBefore.index, indexBefore + 1, "pre-upgrade clone index");
        assertGt(vaultBefore.code.length, 0, "pre-upgrade vault not deployed");
        assertEq(_rawFusionVaultEntry(vaultBefore), bytes32(0), "pre-upgrade vault raw slot before upgrade");

        vm.expectRevert();
        fusionFactory.isFusionVault(vaultBefore);

        UpgradeResult memory result = _deployLinkedImplementation();

        // when
        vm.prank(admin);
        fusionFactory.upgradeToAndCall(result.newImplementation, "");

        // then
        assertEq(_implementationOf(address(fusionFactory)), result.newImplementation, "implementation not upgraded");
        assertEq(fusionFactory.getFusionFactoryVersion(), versionBefore, "version changed by upgrade");
        assertEq(fusionFactory.getFusionFactoryIndex(), indexBefore + 1, "index changed by upgrade");
        assertFalse(fusionFactory.isFusionVault(vaultBefore), "pre-upgrade vault must not be registered");
        assertFalse(fusionFactory.isFusionVault(address(0)), "zero address must not be registered");

        FusionFactoryLogicLib.FusionInstance memory instanceAfter = fusionFactory.clone(
            "Registry Post Upgrade Vault",
            "RPOV",
            config.usdc,
            REDEMPTION_DELAY_IN_SECONDS,
            vaultOwner,
            DAO_FEE_PACKAGE_INDEX
        );

        assertEq(instanceAfter.index, indexBefore + 2, "post-upgrade clone index");
        assertEq(instanceAfter.version, versionBefore, "post-upgrade clone version");
        assertEq(fusionFactory.getFusionFactoryIndex(), indexBefore + 2, "index after post-upgrade clone");
        assertTrue(fusionFactory.isFusionVault(instanceAfter.plasmaVault), "post-upgrade clone not registered");
        assertEq(_rawFusionVaultEntry(instanceAfter.plasmaVault), bytes32(uint256(1)), "post-upgrade clone raw slot");

        vm.startPrank(admin);
        fusionFactory.grantRole(fusionFactory.MAINTENANCE_MANAGER_ROLE(), maintenanceManager);
        vm.stopPrank();

        vm.prank(maintenanceManager);
        FusionFactoryLogicLib.FusionInstance memory instanceSupervised = fusionFactory.cloneSupervised(
            "Registry Supervised Vault",
            "RSUV",
            config.usdc,
            REDEMPTION_DELAY_IN_SECONDS,
            vaultOwner,
            DAO_FEE_PACKAGE_INDEX
        );

        assertEq(instanceSupervised.index, indexBefore + 3, "post-upgrade supervised clone index");
        assertEq(instanceSupervised.version, versionBefore, "post-upgrade supervised clone version");
        assertEq(fusionFactory.getFusionFactoryIndex(), indexBefore + 3, "index after supervised clone");
        assertEq(fusionFactory.getFusionFactoryVersion(), versionBefore, "version changed by clones");
        assertTrue(
            fusionFactory.isFusionVault(instanceSupervised.plasmaVault),
            "post-upgrade supervised clone not registered"
        );
        assertEq(
            _rawFusionVaultEntry(instanceSupervised.plasmaVault),
            bytes32(uint256(1)),
            "post-upgrade supervised clone raw slot"
        );

        assertFalse(fusionFactory.isFusionVault(vaultBefore), "pre-upgrade vault registered after clones");
        assertEq(_rawFusionVaultEntry(vaultBefore), bytes32(0), "pre-upgrade vault raw slot after clones");
    }

    function _assertPinnedOnChainDeployment() internal view {
        assertEq(
            _implementationOf(address(fusionFactory)),
            config.implementation,
            "on-chain implementation differs from the pinned one"
        );
        assertEq(
            _countAddressOccurrences(config.implementation.code, config.fusionFactoryLib),
            2,
            "on-chain implementation does not link the pinned FusionFactoryLib"
        );
        assertEq(
            _countAddressOccurrences(config.fusionFactoryLib.code, config.fusionFactoryLogicLib),
            1,
            "on-chain FusionFactoryLib does not link the pinned FusionFactoryLogicLib"
        );
        assertEq(
            config.fusionFactoryLogicLib.code.length,
            config.fusionFactoryLogicLibRuntimeSize,
            "on-chain FusionFactoryLogicLib runtime size"
        );
    }

    function _deployLinkedImplementation() internal returns (UpgradeResult memory result) {
        result.newFusionFactoryLib = _deployLinked(
            FUSION_FACTORY_LIB_ARTIFACT,
            FUSION_FACTORY_LIB_FQN,
            FUSION_FACTORY_LOGIC_LIB_FQN,
            config.fusionFactoryLogicLib
        );
        result.newImplementation = _deployLinked(
            FUSION_FACTORY_ARTIFACT,
            FUSION_FACTORY_FQN,
            FUSION_FACTORY_LIB_FQN,
            result.newFusionFactoryLib
        );
    }

    function _deployLinked(
        string memory artifact_,
        string memory contractFqn_,
        string memory libraryFqn_,
        address library_
    ) internal returns (address deployed) {
        string memory placeholder = _linkPlaceholder(libraryFqn_);
        string memory creationCode = _readCurrentBytecodeObject(artifact_, contractFqn_, placeholder, false);

        assertTrue(vm.indexOf(creationCode, placeholder) != type(uint256).max, "link placeholder not found");
        string memory linked = vm.replace(creationCode, placeholder, _addressHexWithoutPrefix(library_));
        assertEq(vm.indexOf(linked, "__$"), type(uint256).max, "unlinked library placeholder left");

        bytes memory initCode = vm.parseBytes(linked);
        assembly {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
        }
        assertTrue(deployed != address(0), "linked deployment failed");
    }

    /// @dev Checks every link reference of the artifact against the runtime code, then checks the whole
    /// runtime equals the linked artifact once the contract's own address (library call guard, immutables)
    /// is filled in
    function _assertLinkedRuntime(
        bytes memory runtimeCode_,
        string memory artifact_,
        string memory contractFqn_,
        string memory libraryFqn_,
        address library_,
        address self_
    ) internal view {
        string memory placeholder = _linkPlaceholder(libraryFqn_);
        string memory deployedObject = _readCurrentBytecodeObject(artifact_, contractFqn_, placeholder, true);
        string[] memory parts = vm.split(deployedObject, placeholder);

        assertGt(parts.length, 1, "artifact has no link reference");

        /// @dev hex characters before each placeholder, without the 0x prefix, halved to a byte offset
        uint256 hexPosition = bytes(parts[0]).length - 2;
        for (uint256 i = 1; i < parts.length; ++i) {
            uint256 offset = hexPosition / 2;
            assertEq(_addressAt(runtimeCode_, offset), library_, "runtime link target mismatch");
            hexPosition += bytes(placeholder).length + bytes(parts[i]).length;
        }

        assertEq(
            _countAddressOccurrences(runtimeCode_, library_),
            parts.length - 1,
            "unexpected number of link target occurrences"
        );

        bytes memory expected = vm.parseBytes(
            vm.replace(deployedObject, placeholder, _addressHexWithoutPrefix(library_))
        );
        assertEq(expected.length, runtimeCode_.length, "runtime size differs from linked artifact");
        _fillSelfAddress(expected, runtimeCode_, self_);
        assertEq(keccak256(runtimeCode_), keccak256(expected), "runtime differs from linked artifact");
    }

    /// @dev Reads the unlinked bytecode object from the artifact JSON under FOUNDRY_OUT and requires it to equal
    /// the bytecode of the current build (vm.getCode / vm.getDeployedCode, linked by Foundry) once the placeholder
    /// is filled with the library address Foundry linked, so stale or foreign artifacts are rejected
    function _readCurrentBytecodeObject(
        string memory artifact_,
        string memory contractFqn_,
        string memory placeholder_,
        bool deployed_
    ) internal view returns (string memory object) {
        string memory artifactPath = string.concat(vm.envOr("FOUNDRY_OUT", string("out")), artifact_);
        object = vm.parseJsonString(
            vm.readFile(artifactPath),
            deployed_ ? ".deployedBytecode.object" : ".bytecode.object"
        );
        bytes memory buildCode = deployed_ ? vm.getDeployedCode(contractFqn_) : vm.getCode(contractFqn_);
        string[] memory parts = vm.split(object, placeholder_);

        assertGt(parts.length, 1, "artifact has no link reference");

        /// @dev hex characters before the first placeholder, without the 0x prefix, halved to a byte offset
        address buildLinkTarget = _addressAt(buildCode, (bytes(parts[0]).length - 2) / 2);
        bytes memory expected = vm.parseBytes(
            vm.replace(object, placeholder_, _addressHexWithoutPrefix(buildLinkTarget))
        );
        assertEq(
            keccak256(expected),
            keccak256(buildCode),
            string.concat("artifact differs from the current build: ", artifactPath)
        );
    }

    /// @dev Copies the contract's own address into the zeroed positions the compiler leaves for it: the library
    /// call guard (PUSH20 at offset 0) and address(this) immutables
    function _fillSelfAddress(bytes memory expected_, bytes memory runtimeCode_, address self_) internal pure {
        bytes32 selfWord = bytes32(uint256(uint160(self_)));
        uint256 length = expected_.length;

        if (length > 21 && expected_[0] == 0x73 && _addressAt(expected_, 1) == address(0)) {
            if (_addressAt(runtimeCode_, 1) == self_) {
                for (uint256 i = 1; i < 21; ++i) {
                    expected_[i] = runtimeCode_[i];
                }
            }
        }

        for (uint256 i; i + 32 <= length; ) {
            bytes32 expectedWord;
            bytes32 runtimeWord;
            assembly {
                expectedWord := mload(add(add(expected_, 0x20), i))
                runtimeWord := mload(add(add(runtimeCode_, 0x20), i))
            }
            if (expectedWord == bytes32(0) && runtimeWord == selfWord) {
                assembly {
                    mstore(add(add(expected_, 0x20), i), runtimeWord)
                }
                i += 32;
            } else {
                ++i;
            }
        }
    }

    function _countAddressOccurrences(bytes memory code_, address target_) internal pure returns (uint256 count) {
        uint256 length = code_.length;
        if (length < 20) {
            return 0;
        }
        for (uint256 i; i <= length - 20; ++i) {
            if (_addressAt(code_, i) == target_) {
                ++count;
            }
        }
    }

    function _addressAt(bytes memory code_, uint256 offset_) internal pure returns (address result) {
        assertLe(offset_ + 20, code_.length, "offset out of bounds");
        bytes32 word;
        assembly {
            word := mload(add(add(code_, 0x20), offset_))
        }
        result = address(bytes20(word));
    }

    /// @dev Solidity library placeholder: "__$" + first 34 hex characters of keccak256(fully qualified name) + "$__"
    function _linkPlaceholder(string memory libraryFqn_) internal pure returns (string memory) {
        bytes memory hashHex = bytes(vm.toString(keccak256(bytes(libraryFqn_))));
        bytes memory prefix = new bytes(34);
        for (uint256 i; i < 34; ++i) {
            prefix[i] = hashHex[i + 2];
        }
        return string.concat("__$", string(prefix), "$__");
    }

    function _addressHexWithoutPrefix(address target_) internal pure returns (string memory) {
        return vm.replace(vm.toLowercase(vm.toString(target_)), "0x", "");
    }

    function _implementationOf(address proxy_) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy_, ERC1967Utils.IMPLEMENTATION_SLOT))));
    }

    function _rawFusionVaultEntry(address vault_) internal view returns (bytes32) {
        return vm.load(address(fusionFactory), keccak256(abi.encode(vault_, FUSION_VAULTS_SLOT)));
    }
}

/// @title FusionFactory vault registry upgrade fork test on Ethereum
/// @notice Runs the vault registry upgrade scenario against the live Ethereum FusionFactory proxy
contract FusionFactoryVaultRegistryUpgradeEthereumForkTest is FusionFactoryVaultRegistryUpgradeForkTestBase {
    function _chainConfig() internal pure override returns (ChainConfig memory) {
        return
            ChainConfig({
                rpcEnv: "ETHEREUM_PROVIDER_URL",
                forkBlock: 25974050,
                fusionFactoryProxy: 0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852,
                implementation: 0xf19C1E9f6616F6056AF1e322A86fDaAaAf0263f5,
                fusionFactoryLib: 0x3A53cF5F8eB2a7e4297205e88065c08afC95FD75,
                fusionFactoryLogicLib: 0x25Ba6AE41E835D2c17D1995fd6477abA369AF616,
                fusionFactoryLogicLibRuntimeSize: 24_249,
                usdc: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
            });
    }
}

/// @title FusionFactory vault registry upgrade fork test on Base
/// @notice Runs the vault registry upgrade scenario against the live Base FusionFactory proxy
contract FusionFactoryVaultRegistryUpgradeBaseForkTest is FusionFactoryVaultRegistryUpgradeForkTestBase {
    function _chainConfig() internal pure override returns (ChainConfig memory) {
        return
            ChainConfig({
                rpcEnv: "BASE_PROVIDER_URL",
                forkBlock: 51289893,
                fusionFactoryProxy: 0x1455717668fA96534f675856347A973fA907e922,
                implementation: 0x610152A79BE7F2Aa3aA70520c9331c18fe8D33b7,
                fusionFactoryLib: 0x3A53cF5F8eB2a7e4297205e88065c08afC95FD75,
                fusionFactoryLogicLib: 0x25Ba6AE41E835D2c17D1995fd6477abA369AF616,
                fusionFactoryLogicLibRuntimeSize: 24_249,
                usdc: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
            });
    }
}

/// @title FusionFactory vault registry upgrade fork test on Arbitrum
/// @notice Runs the vault registry upgrade scenario against the live Arbitrum FusionFactory proxy
contract FusionFactoryVaultRegistryUpgradeArbitrumForkTest is FusionFactoryVaultRegistryUpgradeForkTestBase {
    function _chainConfig() internal pure override returns (ChainConfig memory) {
        return
            ChainConfig({
                rpcEnv: "ARBITRUM_PROVIDER_URL",
                forkBlock: 504996974,
                fusionFactoryProxy: 0x134fCAce7a2C7Ef3dF2479B62f03ddabAEa922d5,
                implementation: 0x87f94ac9aF79261F0BC73582114f805F55Cd0b25,
                fusionFactoryLib: 0x0E910e8e0E8642bdf6Dd4854ba08B0d8d846430A,
                fusionFactoryLogicLib: 0xAf720CfCFfa7e88aB9707c5b0caC9Cde36E7d169,
                fusionFactoryLogicLibRuntimeSize: 24_359,
                usdc: 0xaf88d065e77c8cC2239327C5EDb3A432268e5831
            });
    }
}
