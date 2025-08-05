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
    /// @param tokenA_ The first token of a pool, unsorted
    /// @param tokenB_ The second token of a pool, unsorted
    /// @param tickSpacing_ The tick spacing of the pool
    /// @return Poolkey The pool details with ordered token0 and token1 assignments
    function _getPoolKey(address tokenA_, address tokenB_, int24 tickSpacing_) private pure returns (PoolKey memory) {
        if (tokenA_ > tokenB_) (tokenA_, tokenB_) = (tokenB_, tokenA_);
        return PoolKey({token0: tokenA_, token1: tokenB_, tickSpacing: tickSpacing_});
    }

    /// @notice Deterministically computes the pool address given the factory and PoolKey
    /// @param factory_ The CL factory contract address
    /// @param key_ The PoolKey
    /// @return pool The contract address of the V3 pool
    function _computeAddress(address factory_, PoolKey memory key_) private view returns (address pool) {
        if (key_.token0 >= key_.token1) revert TokensNotSorted();
        pool = Clones.predictDeterministicAddress({
            implementation: ICLFactory(factory_).poolImplementation(),
            salt: keccak256(abi.encode(key_.token0, key_.token1, key_.tickSpacing)),
            deployer: factory_
        });
    }
}
