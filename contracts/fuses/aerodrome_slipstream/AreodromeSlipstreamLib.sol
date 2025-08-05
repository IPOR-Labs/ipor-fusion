// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {ICLFactory} from "./ext/ICLFactory.sol";

enum AreodromeSlipstreamSubstrateType {
    UNDEFINED,
    Gauge,
    Pool
}

struct AreodromeSlipstreamSubstrate {
    AreodromeSlipstreamSubstrateType substrateType;
    address substrateAddress;
}

library AreodromeSlipstreamSubstrateLib {
    function substrateToBytes32(AreodromeSlipstreamSubstrate memory substrate) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(substrate.substrateAddress)) | (uint256(substrate.substrateType) << 160));
    }

    function bytes32ToSubstrate(
        bytes32 bytes32Substrate
    ) internal pure returns (AreodromeSlipstreamSubstrate memory substrate) {
        substrate.substrateType = AreodromeSlipstreamSubstrateType(uint256(bytes32Substrate) >> 160);
        substrate.substrateAddress = PlasmaVaultConfigLib.bytes32ToAddress(bytes32Substrate);
    }

    /// @dev Velodrome V3 Pool Key

    /// @notice The identifying key of the pool
    struct PoolKey {
        address token0;
        address token1;
        int24 tickSpacing;
    }

    /// @notice Returns PoolKey: the ordered tokens with the matched fee levels
    /// @param tokenA The first token of a pool, unsorted
    /// @param tokenB The second token of a pool, unsorted
    /// @param tickSpacing The tick spacing of the pool
    /// @return Poolkey The pool details with ordered token0 and token1 assignments
    function getPoolKey(address tokenA, address tokenB, int24 tickSpacing) private pure returns (PoolKey memory) {
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);
        return PoolKey({token0: tokenA, token1: tokenB, tickSpacing: tickSpacing});
    }

    /// @notice Deterministically computes the pool address given the factory and PoolKey
    /// @param factory The CL factory contract address
    /// @param key The PoolKey
    /// @return pool The contract address of the V3 pool
    function computeAddress(address factory, PoolKey memory key) private view returns (address pool) {
        require(key.token0 < key.token1);

        pool = predictDeterministicAddress({
            master: ICLFactory(factory).poolImplementation(),
            salt: keccak256(abi.encode(key.token0, key.token1, key.tickSpacing)),
            deployer: factory
        });
    }

    /**
     * @dev Computes the address of a clone deployed using {Clones-cloneDeterministic}.
     */
    function predictDeterministicAddress(
        address master,
        bytes32 salt,
        address deployer
    ) internal pure returns (address predicted) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, master))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf3ff00000000000000000000000000000000)
            mstore(add(ptr, 0x38), shl(0x60, deployer))
            mstore(add(ptr, 0x4c), salt)
            mstore(add(ptr, 0x6c), keccak256(ptr, 0x37))
            predicted := keccak256(add(ptr, 0x37), 0x55)
        }
    }

    function getPoolAddress(
        address factory_,
        address tokenA_,
        address tokenB_,
        int24 tickSpacing_
    ) internal view returns (address pool) {
        PoolKey memory key = getPoolKey(tokenA_, tokenB_, tickSpacing_);
        pool = computeAddress(factory_, key);
    }
}
