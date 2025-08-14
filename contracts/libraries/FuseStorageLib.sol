// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title Fuses storage library responsible for managing storage fuses in the Plasma Vault
library FuseStorageLib {
    /**
     * @dev Storage slot for managing supported fuses in the Plasma Vault
     * @notice Maps fuse addresses to their index in the fuses array for tracking supported fuses
     *
     * Calculation:
     * keccak256(abi.encode(uint256(keccak256("io.ipor.CfgFuses")) - 1)) & ~bytes32(uint256(0xff))
     *
     * Purpose:
     * - Tracks which fuses are supported by the vault
     * - Enables efficient fuse validation
     * - Maps fuse addresses to their array indices
     * - Core component of fuse management system
     *
     * Storage Layout:
     * - Points to Fuses struct containing:
     *   - value: mapping(address fuse => uint256 index)
     *     - Zero index indicates unsupported fuse
     *     - Non-zero index (index + 1) indicates supported fuse
     *
     * Usage Pattern:
     * - Checked during fuse operations via isFuseSupported()
     * - Updated when adding/removing fuses
     * - Used for fuse validation in vault operations
     * - Maintains synchronization with fuses array
     *
     * Integration Points:
     * - FusesLib.isFuseSupported: Validates fuse status
     * - FusesLib.addFuse: Updates supported fuses
     * - FusesLib.removeFuse: Removes fuse support
     * - PlasmaVault: References for operation validation
     *
     * Security Considerations:
     * - Only modifiable through governance
     * - Critical for controlling vault integrations
     * - Must maintain consistency with fuses array
     * - Key component of vault security
     */
    bytes32 private constant CFG_FUSES = 0x48932b860eb451ad240d4fe2b46522e5a0ac079d201fe50d4e0be078c75b5400;

    /**
     * @dev Storage slot for storing the array of supported fuses in the Plasma Vault
     * @notice Maintains ordered list of all supported fuse addresses
     *
     * Calculation:
     * keccak256(abi.encode(uint256(keccak256("io.ipor.CfgFusesArray")) - 1)) & ~bytes32(uint256(0xff))
     *
     * Purpose:
     * - Stores complete list of supported fuses
     * - Enables iteration over all supported fuses
     * - Maintains order of fuse addition
     * - Provides efficient fuse removal mechanism
     *
     * Storage Layout:
     * - Points to FusesArray struct containing:
     *   - value: address[] array of fuse addresses
     *     - Each element is a supported fuse contract address
     *     - Array index corresponds to (mapping index - 1) in CFG_FUSES
     *
     * Usage Pattern:
     * - Referenced when listing all supported fuses
     * - Updated during fuse addition/removal
     * - Used for fuse enumeration
     * - Maintains parallel structure with CFG_FUSES mapping
     *
     * Integration Points:
     * - FusesLib.getFusesArray: Retrieves complete fuse list
     * - FusesLib.addFuse: Appends new fuses
     * - FusesLib.removeFuse: Manages array updates
     * - Governance: References for fuse management
     *
     * Security Considerations:
     * - Must stay synchronized with CFG_FUSES mapping
     * - Array operations must handle index updates correctly
     * - Critical for fuse system integrity
     * - Requires careful management during removals
     */
    bytes32 private constant CFG_FUSES_ARRAY = 0xad43e358bd6e59a5a0c80f6bf25fa771408af4d80f621cdc680c8dfbf607ab00;

    /**
     * @dev Storage slot for managing Uniswap V3 NFT position token IDs in the Plasma Vault
     * @notice Tracks and manages Uniswap V3 LP positions held by the vault
     *
     * Calculation:
     * keccak256(abi.encode(uint256(keccak256("io.ipor.UniswapV3TokenIds")) - 1)) & ~bytes32(uint256(0xff))
     *
     * Purpose:
     * - Tracks all Uniswap V3 NFT positions owned by the vault
     * - Enables efficient position management and lookup
     * - Supports liquidity provision operations
     * - Facilitates position value calculations
     *
     * Storage Layout:
     * - Points to UniswapV3TokenIds struct containing:
     *   - tokenIds: uint256[] array of Uniswap V3 NFT position IDs
     *   - indexes: mapping(uint256 tokenId => uint256 index) for position lookup
     *     - Maps each token ID to its index in the tokenIds array
     *     - Zero index indicates non-existent position
     *
     * Usage Pattern:
     * - Updated when creating new Uniswap V3 positions
     * - Referenced during position management
     * - Used for position value calculations
     * - Maintains efficient position tracking
     *
     * Integration Points:
     * - UniswapV3NewPositionFuse: Position creation and management
     * - PositionValue: NFT position valuation
     * - Balance calculation systems
     * - Withdrawal and rebalancing operations
     *
     * Security Considerations:
     * - Must accurately track all vault positions
     * - Critical for proper liquidity management
     * - Requires careful index management
     * - Essential for position ownership verification
     */
    bytes32 private constant UNISWAP_V3_TOKEN_IDS = 0x3651659bd419f7c37743f3e14a337c9f9d1cfc4d650d91508f44d1acbe960f00;

    /**
     * @dev Storage slot for managing Ramses V2 NFT position token IDs in the Plasma Vault
     * @notice Tracks and manages Ramses V2 LP positions held by the vault
     *
     * Calculation:
     * keccak256(abi.encode(uint256(keccak256("io.ipor.RamsesV2TokenIds")) - 1)) & ~bytes32(uint256(0xff))
     *
     * Purpose:
     * - Tracks all Ramses V2 NFT positions owned by the vault
     * - Enables efficient position management and lookup
     * - Supports concentrated liquidity position tracking
     * - Mirrors Uniswap V3-style position management for Arbitrum
     *
     * Storage Layout:
     * - Points to RamsesV2TokenIds struct containing:
     *   - tokenIds: uint256[] array of Ramses V2 NFT position IDs
     *   - indexes: mapping(uint256 tokenId => uint256 index) for position lookup
     *     - Maps each token ID to its index in the tokenIds array
     *     - Zero index indicates non-existent position
     *
     * Usage Pattern:
     * - Updated when creating new Ramses V2 positions
     * - Referenced during position management
     * - Used for position value calculations
     * - Maintains efficient position tracking on Arbitrum
     *
     * Integration Points:
     * - Ramses V2 position management fuses
     * - Position value calculation systems
     * - Balance tracking mechanisms
     * - Arbitrum-specific liquidity operations
     *
     * Security Considerations:
     * - Must accurately track all vault positions
     * - Critical for Arbitrum liquidity management
     * - Requires careful index management
     * - Essential for position ownership verification
     * - Parallel structure to Uniswap V3 position tracking
     */
    bytes32 private constant RAMSES_V2_TOKEN_IDS = 0x1a3831a406f27d4d5d820158b29ce95a1e8e840bf416921917aa388e2461b700;


    /**
     * @dev Storage slot for managing Liquity V2 Troves position token IDs in the Plasma Vault
     * @notice Tracks and manages Liquity V2 Troves positions held by the vault
     *
     * Calculation:
     * keccak256(abi.encode(uint256(keccak256("io.ipor.LiquityV2OwnerIds")) - 1)) & ~bytes32(uint256(0xff))
     *
     * Purpose:
     * - Tracks all Liquity V2 Troves positions owned by the vault
     * - Enables efficient position management and lookup
     * - Supports concentrated liquidity position tracking
     * - Mirrors Uniswap V3-style position management for Arbitrum
     *
     * Storage Layout:
     * - Points to LiquityV2OwnerIds struct containing:
     *   - lastIndex: uint256 last index used for new positions
     *   - idByOwnerIndex: mapping(address => mapping(uint256 ownerIndex => uint256 troveId))
     *     - Maps each owner index to its corresponding trove ID
     *     - Zero id indicates non-existent or closed position
     *
     * Usage Pattern:
     * - Updated when creating new Liquity V2 positions
     * - Referenced during position management
     * - Used for position value calculations
     * - Maintains efficient position tracking on Arbitrum
     *
     * Integration Points:
     * - Liquity V2 position management fuses
     * - Position value calculation systems
     * - Balance tracking mechanisms
     * - Arbitrum-specific liquidity operations
     *
     * Security Considerations:
     * - Must accurately track all vault positions
     * - Critical for Arbitrum liquidity management
     * - Requires careful index management
     * - Essential for position ownership verification
     * - Parallel structure to Uniswap V3 position tracking
     */
    bytes32 private constant LIQUITY_V2_OWNER_IDS =
        0x666c67a69b8006dd3640f09d1123ec0d376176b37a6ef588f4e3637b5ecdff00;
    /// @custom:storage-location erc7201:io.ipor.CfgFuses
    struct Fuses {
        /// @dev fuse address => If index = 0 - is not granted, otherwise - granted
        mapping(address fuse => uint256 index) value;
    }

    /// @custom:storage-location erc7201:io.ipor.CfgFusesArray
    struct FusesArray {
        /// @dev value is a fuse address
        address[] value;
    }

    /// @custom:storage-location erc7201:io.ipor.UniswapV3TokenIds
    struct UniswapV3TokenIds {
        uint256[] tokenIds;
        mapping(uint256 tokenId => uint256 index) indexes;
    }

    /// @custom:storage-location erc7201:io.ipor.RamsesV2TokenIds
    struct RamsesV2TokenIds {
        uint256[] tokenIds;
        mapping(uint256 tokenId => uint256 index) indexes;
    }

    /// @custom:storage-location erc7201:io.ipor.LiquityV2OwnerIds
    struct LiquityV2OwnerIds {
        mapping(address registry => uint256[] troveIds) troveIds;
        mapping(address registry => mapping(uint256 index => uint256 troveId)) idsByIndex;
    }

    /// @notice Gets the fuses storage pointer
    function getFuses() internal pure returns (Fuses storage fuses) {
        assembly {
            fuses.slot := CFG_FUSES
        }
    }

    /// @notice Gets the fuses array storage pointer
    function getFusesArray() internal pure returns (FusesArray storage fusesArray) {
        assembly {
            fusesArray.slot := CFG_FUSES_ARRAY
        }
    }

    /// @notice Gets the UniswapV3TokenIds storage pointer
    function getUniswapV3TokenIds() internal pure returns (UniswapV3TokenIds storage uniswapV3TokenIds) {
        assembly {
            uniswapV3TokenIds.slot := UNISWAP_V3_TOKEN_IDS
        }
    }

    /// @notice Gets the UniswapV3TokenIds storage pointer
    function getRamsesV2TokenIds() internal pure returns (RamsesV2TokenIds storage ramsesV2TokenIds) {
        assembly {
            ramsesV2TokenIds.slot := RAMSES_V2_TOKEN_IDS
        }
    }

    /// @notice Gets the LiquityV2OwnerIds storage pointer
    function getLiquityV2OwnerIds() internal pure returns (LiquityV2OwnerIds storage liquityV2OwnerIds) {
        assembly {
            liquityV2OwnerIds.slot := LIQUITY_V2_OWNER_IDS
        }
    }
}
