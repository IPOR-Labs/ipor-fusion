// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {PreHooksLib} from "../handlers/pre_hooks/PreHooksLib.sol";
import {UniversalReader, ReadResult} from "../universal_reader/UniversalReader.sol";

/**
 * @title PreHookInfo Struct
 * @notice Structure containing information about a pre-hook configuration
 * @dev Used to store and return pre-hook related data from the PlasmaVault system
 */
struct PreHookInfo {
    /// @notice Function selector identifying the pre-hook
    bytes4 selector;
    /// @notice Address of the pre-hook implementation contract
    address implementation;
    /// @notice Array of substrate identifiers associated with this pre-hook
    bytes32[] substrates;
}

/**
 * @title PreHooksInfoReader
 * @notice Reader contract for accessing pre-hooks configuration data from PlasmaVault
 * @dev Provides methods to query pre-hook information both directly and through the UniversalReader pattern
 */
contract PreHooksInfoReader {
    /**
     * @notice Retrieves pre-hooks information from a specific PlasmaVault instance
     * @dev Uses UniversalReader pattern to safely read data from the target vault
     * @param plasmaVault_ Address of the PlasmaVault to read from
     * @return preHooksInfo Array of PreHookInfo structs containing hook configurations
     */
    function getPreHooksInfo(address plasmaVault_) external view returns (PreHookInfo[] memory preHooksInfo) {
        ReadResult memory readResult = UniversalReader(address(plasmaVault_)).read(
            address(this),
            abi.encodeWithSignature("getPreHooksInfo()")
        );
        preHooksInfo = abi.decode(readResult.data, (PreHookInfo[]));
    }

    /**
     * @notice Retrieves all pre-hooks information from the PreHooksLib
     * @dev Aggregates data from multiple PreHooksLib calls to build complete pre-hook configurations
     * @return preHooksInfo Array of PreHookInfo structs containing all registered pre-hooks
     */
    function getPreHooksInfo() external view returns (PreHookInfo[] memory preHooksInfo) {
        bytes4[] memory selectors = PreHooksLib.getPreHookSelectors();
        uint256 length = selectors.length;

        preHooksInfo = new PreHookInfo[](length);

        for (uint256 i; i < length; ++i) {
            bytes4 selector = selectors[i];
            address implementation = PreHooksLib.getPreHookImplementation(selector);
            bytes32[] memory substrates = PreHooksLib.getPreHookSubstrates(selector, implementation);
            preHooksInfo[i] = PreHookInfo(selector, implementation, substrates);
        }
    }
}
