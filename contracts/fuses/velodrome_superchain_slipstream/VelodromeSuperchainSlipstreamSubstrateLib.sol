// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {ICLFactory} from "./ext/ICLFactory.sol";

/// @notice Error when pool does not exist (not deployed)
error PoolNotDeployed(address token0, address token1, int24 tickSpacing);

/// @notice Error when pool has no code (defense-in-depth check)
error PoolHasNoCode(address pool);

enum VelodromeSuperchainSlipstreamSubstrateType {
    UNDEFINED,
    Gauge,
    Pool
}

struct VelodromeSuperchainSlipstreamSubstrate {
    VelodromeSuperchainSlipstreamSubstrateType substrateType;
    address substrateAddress;
}

library VelodromeSuperchainSlipstreamSubstrateLib {
    function substrateToBytes32(
        VelodromeSuperchainSlipstreamSubstrate memory substrate_
    ) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(substrate_.substrateAddress)) | (uint256(substrate_.substrateType) << 160));
    }

    function bytes32ToSubstrate(
        bytes32 bytes32Substrate_
    ) internal pure returns (VelodromeSuperchainSlipstreamSubstrate memory substrate) {
        substrate.substrateType = VelodromeSuperchainSlipstreamSubstrateType(uint256(bytes32Substrate_) >> 160);
        substrate.substrateAddress = PlasmaVaultConfigLib.bytes32ToAddress(bytes32Substrate_);
    }

    /// @notice Returns the pool address from the factory for the given token pair and tick spacing
    /// @dev Uses authoritative lookup from the factory instead of CREATE2 prediction.
    ///      This approach is upgrade-safe: it returns the actual deployed pool address
    ///      regardless of any factory implementation upgrades.
    /// @param factory_ The CL factory contract address
    /// @param tokenA_ The first token of a pool, unsorted
    /// @param tokenB_ The second token of a pool, unsorted
    /// @param tickSpacing_ The tick spacing of the pool
    /// @return pool The contract address of the deployed pool
    /// @custom:revert PoolNotDeployed When no pool exists for the given parameters
    /// @custom:revert PoolHasNoCode When the returned pool address has no code (defense-in-depth)
    function getPoolAddress(
        address factory_,
        address tokenA_,
        address tokenB_,
        int24 tickSpacing_
    ) internal view returns (address pool) {
        // Sort tokens to match factory's expected order
        (address token0, address token1) = tokenA_ < tokenB_ ? (tokenA_, tokenB_) : (tokenB_, tokenA_);

        // Query the factory for the actual deployed pool address
        pool = ICLFactory(factory_).getPool(token0, token1, tickSpacing_);

        // Verify pool exists (factory returns address(0) if not deployed)
        if (pool == address(0)) {
            revert PoolNotDeployed(token0, token1, tickSpacing_);
        }

        // Defense-in-depth: verify the pool has code deployed
        if (pool.code.length == 0) {
            revert PoolHasNoCode(pool);
        }
    }
}
