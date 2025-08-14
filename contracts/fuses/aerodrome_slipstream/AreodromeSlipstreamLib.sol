// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {ICLFactory} from "./ext/ICLFactory.sol";

/// @notice Error when token order is invalid (expected token0 < token1)
error WrongTokenOrder();

enum AreodromeSlipstreamSubstrateType {
    UNDEFINED,
    Gauge,
    Pool
}

struct AreodromeSlipstreamSubstrate {
    AreodromeSlipstreamSubstrateType substrateType;
    address substrateAddress;
}

struct PoolKey {
    address token0;
    address token1;
    int24 tickSpacing;
}

library AreodromeSlipstreamSubstrateLib {
    function substrateToBytes32(AreodromeSlipstreamSubstrate memory substrate_) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(substrate_.substrateAddress)) | (uint256(substrate_.substrateType) << 160));
    }

    function bytes32ToSubstrate(
        bytes32 bytes32Substrate_
    ) internal pure returns (AreodromeSlipstreamSubstrate memory substrate) {
        substrate.substrateType = AreodromeSlipstreamSubstrateType(uint256(bytes32Substrate_) >> 160);
        substrate.substrateAddress = PlasmaVaultConfigLib.bytes32ToAddress(bytes32Substrate_);
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
        if (!(key_.token0 < key_.token1)) {
            revert WrongTokenOrder();
        }

        pool = _predictDeterministicAddress(
            ICLFactory(factory_).poolImplementation(),
            keccak256(abi.encode(key_.token0, key_.token1, key_.tickSpacing)),
            factory_
        );
    }

    /**
     * @dev Computes the address of a clone deployed using {Clones-cloneDeterministic}.
     */
    function _predictDeterministicAddress(
        address master_,
        bytes32 salt_,
        address deployer_
    ) private pure returns (address predicted) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, master_))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf3ff00000000000000000000000000000000)
            mstore(add(ptr, 0x38), shl(0x60, deployer_))
            mstore(add(ptr, 0x4c), salt_)
            mstore(add(ptr, 0x6c), keccak256(ptr, 0x37))
            predicted := keccak256(add(ptr, 0x37), 0x55)
        }
    }
}
