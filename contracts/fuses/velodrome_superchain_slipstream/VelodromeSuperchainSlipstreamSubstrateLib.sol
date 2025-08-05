// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {ICLFactory} from "./ext/ICLFactory.sol";

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
    error TokensNotSorted();

    function substrateToBytes32(
        VelodromeSuperchainSlipstreamSubstrate memory substrate
    ) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(substrate.substrateAddress)) | (uint256(substrate.substrateType) << 160));
    }

    function bytes32ToSubstrate(
        bytes32 bytes32Substrate
    ) internal pure returns (VelodromeSuperchainSlipstreamSubstrate memory substrate) {
        substrate.substrateType = VelodromeSuperchainSlipstreamSubstrateType(uint256(bytes32Substrate) >> 160);
        substrate.substrateAddress = PlasmaVaultConfigLib.bytes32ToAddress(bytes32Substrate);
    }

    /// @dev Velodrome V3 Pool Key

    /// @notice The identifying key of the pool
    struct PoolKey {
        address token0;
        address token1;
        int24 tickSpacing;
    }

    function getPoolAddress(
        address factory_,
        address tokenA_,
        address tokenB_,
        int24 tickSpacing_
    ) internal view returns (address pool) {
        PoolKey memory key = _getPoolKey(tokenA_, tokenB_, tickSpacing_);
        pool = _computeAddress(factory_, key);
    }

    /// @notice Returns PoolKey: the ordered tokens with the matched fee levels
    /// @param tokenA The first token of a pool, unsorted
    /// @param tokenB The second token of a pool, unsorted
    /// @param tickSpacing The tick spacing of the pool
    /// @return Poolkey The pool details with ordered token0 and token1 assignments
    function _getPoolKey(address tokenA, address tokenB, int24 tickSpacing) private pure returns (PoolKey memory) {
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);
        return PoolKey({token0: tokenA, token1: tokenB, tickSpacing: tickSpacing});
    }

    /// @notice Deterministically computes the pool address given the factory and PoolKey
    /// @param factory The CL factory contract address
    /// @param key The PoolKey
    /// @return pool The contract address of the V3 pool
    function _computeAddress(address factory, PoolKey memory key) private view returns (address pool) {
        if (key.token0 >= key.token1) revert TokensNotSorted();
        pool = Clones.predictDeterministicAddress({
            implementation: ICLFactory(factory).poolImplementation(),
            salt: keccak256(abi.encode(key.token0, key.token1, key.tickSpacing)),
            deployer: factory
        });
    }
}
