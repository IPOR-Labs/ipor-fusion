// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IUniversalRouter} from "../../../contracts/fuses/napier/ext/IUniversalRouter.sol";

interface NapierFactory {
    function DEFAULT_SPLIT_RATIO_BPS() external pure returns (uint16);

    function isValidImplementation(NapierHelper.ModuleIndex moduleType, address implementation)
        external
        view
        returns (bool);
}

/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
/*                      NAPIER HELPER                           */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @notice Helper library for deploying new TokiPool using UniswapV4Router
/// @dev This library provides a convenient way to deploy TokiPools without importing
///      the full Factory and related contracts from src
library NapierHelper {
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    /*                         TYPES                               */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Module index enum (minimal subset)
    enum ModuleIndex {
        FEE_MODULE_INDEX, // 0
        REWARD_PROXY_MODULE_INDEX, // 1
        VERIFIER_MODULE_INDEX, // 2
        POOL_FEE_MODULE_INDEX // 3

    }

    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    /*                         STRUCTS                              */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Factory Suite structure
    struct FactorySuite {
        address accessManagerImplementation;
        address ptBlueprint;
        address resolverBlueprint;
        address poolDeployerImplementation;
        bytes poolArgs;
        bytes resolverArgs;
    }

    /// @notice Factory Module Parameter structure
    struct FactoryModuleParam {
        ModuleIndex moduleType;
        address implementation;
        bytes immutableData;
    }

    /// @notice TokiPool Deployment Parameters
    struct TokiPoolDeploymentParams {
        bytes32 salt;
        address hook;
        uint16 pausableFlags;
        bytes hookParams;
        address hooklet;
        bytes hookletParams;
        address vault0;
        address vault1;
        bytes vault0Params;
        bytes vault1Params;
        address liquidityTokenImplementation;
        bytes liquidityTokenImmutableData;
    }
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    /*                      CONSTANTS                              */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Command bytes
    uint256 constant TP_CREATE_POOL = 0x35;
    uint256 constant TP_SPLIT_INITIAL_LIQUIDITY = 0x32;
    uint256 constant TP_ADD_LIQUIDITY = 0x36;

    /// @notice Action constants for router commands
    uint256 constant CONTRACT_BALANCE = 0x8000000000000000000000000000000000000000000000000000000000000000;
    address constant MSG_SENDER = address(1);
    address constant ADDRESS_THIS = address(2);

    uint256 constant DEFAULT_CARDINALITY_NEXT = 0;
    bytes constant DEFAULT_VAULT_PARAMS = abi.encode(uint16(0), uint16(10_000), uint16(10_000), uint16(10_000));

    /// @notice Encode hook parameters for TokiPool deployment
    /// @param scalarRoot Scalar root value for the hook
    /// @param initialAnchor Initial anchor value for the hook
    /// @return encodedParams Encoded hook parameters
    function encodeHookParams(uint256 scalarRoot, int256 initialAnchor)
        internal
        pure
        returns (bytes memory encodedParams)
    {
        return abi.encode(DEFAULT_CARDINALITY_NEXT, abi.encode(scalarRoot, initialAnchor));
    }

    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    /*                    POOL DEPLOYMENT                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Deploy a new TokiPool using UniswapV4Router
    /// @param router The UniswapV4Router contract address
    /// @param suite Factory suite containing deployment configuration
    /// @param modules Array of module parameters
    /// @param expiry Expiry timestamp for the Principal Token
    /// @param curator Curator address (can be address(0) for no curator)
    /// @param salt Salt for deterministic deployment
    /// @param deadline Transaction deadline timestamp
    function deployTokiPool(
        address router,
        FactorySuite memory suite,
        FactoryModuleParam[] memory modules,
        uint256 expiry,
        address curator,
        bytes32 salt,
        uint256 deadline
    ) internal {
        // Build command: TP_CREATE_POOL
        bytes memory commands = abi.encodePacked(bytes1(uint8(TP_CREATE_POOL)));

        // Build inputs array
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(suite, modules, expiry, curator, salt);

        // Execute via router
        IUniversalRouter(router).execute(commands, inputs, deadline);
    }

    /// @notice Deploy a new TokiPool and add initial liquidity in a single transaction
    /// @dev This function executes three commands in sequence:
    ///      1. TP_CREATE_POOL - Creates the pool and Principal Token
    ///      2. TP_SPLIT_INITIAL_LIQUIDITY - Splits underlying token into PT/YT
    ///      3. TP_ADD_LIQUIDITY - Adds liquidity to the pool
    /// @param router The UniswapV4Router contract address
    /// @param suite Factory suite containing deployment configuration
    /// @param modules Array of module parameters
    /// @param expiry Expiry timestamp for the Principal Token
    /// @param curator Curator address (can be address(0) for no curator)
    /// @param salt Salt for deterministic deployment
    /// @param amount0 Amount of underlying token to use for initial liquidity
    /// @param receiver Address to receive Yield Tokens (YT) from the split
    /// @param desiredImpliedRate Desired implied rate in wad (e.g., 0.185e18 for 18.5%)
    /// @param liquidityMinimum Minimum liquidity tokens expected (slippage protection)
    /// @param deadline Transaction deadline timestamp
    function deployTokiPoolAndAddLiquidity(
        address router,
        FactorySuite memory suite,
        FactoryModuleParam[] memory modules,
        uint256 expiry,
        address curator,
        bytes32 salt,
        uint256 amount0,
        address receiver,
        uint256 desiredImpliedRate,
        uint256 liquidityMinimum,
        uint256 deadline
    ) internal returns (address deployedPt, address deployedPool) {
        VM.recordLogs();

        // Build commands: TP_CREATE_POOL + TP_SPLIT_INITIAL_LIQUIDITY + TP_ADD_LIQUIDITY
        bytes memory commands = abi.encodePacked(
            bytes1(uint8(TP_CREATE_POOL)), bytes1(uint8(TP_SPLIT_INITIAL_LIQUIDITY)), bytes1(uint8(TP_ADD_LIQUIDITY))
        );

        // Build inputs array
        bytes[] memory inputs = new bytes[](3);

        // 0: TP_CREATE_POOL - (suite, modules, expiry, curator, salt)
        inputs[0] = abi.encode(suite, modules, expiry, curator, salt);

        // 1: TP_SPLIT_INITIAL_LIQUIDITY - (PoolKey, uint256 amount0, address receiver, uint256 desiredImpliedRate)
        // Use ZERO_KEY to load pool key from transient storage after pool creation
        PoolKey memory ZERO_KEY;
        inputs[1] = abi.encode(ZERO_KEY, amount0, receiver, desiredImpliedRate);

        // 2: TP_ADD_LIQUIDITY - (PoolKey, uint256 amount0, uint256 amount1, uint256 liquidityMinimum, address receiver)
        // Use CONTRACT_BALANCE to use all available tokens in the router contract
        inputs[2] = abi.encode(ZERO_KEY, CONTRACT_BALANCE, CONTRACT_BALANCE, liquidityMinimum, receiver);

        // Execute via router
        IUniversalRouter(router).execute(commands, inputs, deadline);

        (deployedPt, deployedPool) = getDeployedAddressesFromEvent();
    }

    /// @notice Pack fee percentages into a single uint256 (FeePcts)
    /// @dev Equivalent to FeePctsLib.pack
    /// @param issuanceFeePct Issuance fee percentage in basis points (0-10000)
    /// @param performanceFeePct Performance fee percentage in basis points (0-10000)
    /// @param redemptionFeePct Redemption fee percentage in basis points (0-10000)
    /// @param postSettlementFeePct Post-settlement fee percentage in basis points (0-10000)
    /// @return packed The packed fee percentages as uint256
    function packFeePcts(
        address factory,
        uint16 issuanceFeePct,
        uint16 performanceFeePct,
        uint16 redemptionFeePct,
        uint16 postSettlementFeePct
    ) internal pure returns (uint256 packed) {
        uint256 splitFeePct = NapierFactory(factory).DEFAULT_SPLIT_RATIO_BPS();
        packed = (uint256(postSettlementFeePct) << 64) | (uint256(redemptionFeePct) << 48)
            | (uint256(performanceFeePct) << 32) | (uint256(issuanceFeePct) << 16) | uint256(splitFeePct);
    }

    /// @notice Pack pool fee parameters into a single uint256 (FeePctsPool)
    /// @dev Equivalent to FeePctsPoolLib.pack
    /// @param ammFeeParams AMM fee parameters (128-bit encoded value)
    /// @param reserveFeePct Reserve fee percentage in basis points (0-10000)
    /// @return packed The packed pool fee parameters as uint256
    function packFeePctsPool(address factory, uint128 ammFeeParams, uint16 reserveFeePct)
        internal
        pure
        returns (uint256 packed)
    {
        uint256 splitFeePct = NapierFactory(factory).DEFAULT_SPLIT_RATIO_BPS();
        packed = (uint256(reserveFeePct) << 144) | (uint256(ammFeeParams) << 16) | uint256(splitFeePct);
    }

    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    /*                      SALT MINING                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Mine a salt for Principal Token deployment ensuring PT address > underlying address
    /// @dev This function iterates through salts until it finds one that produces a PT address
    ///      greater than the underlying token address, which is required for Uniswap V4 pool deployment
    /// @param factory Factory contract address
    /// @param msgSender The address that will call the router (used for salt hashing)
    /// @param ptBlueprint Principal Token blueprint address
    /// @param underlying Underlying token address (PT must be > this address)
    /// @param router Router address (UniswapV4Router) - used for salt hashing when deploying via router
    /// @return salt The mined salt that produces PT address > underlying address
    function minePrincipalTokenSalt(
        address underlying,
        address ptBlueprint,
        address factory,
        address msgSender,
        address router
    ) internal view returns (bytes32 salt) {
        bytes32 initCodeHash = keccak256(_extractCreationCode(ptBlueprint));
        uint256 underlyingValue = uint256(uint160(underlying));
        uint256 startSalt = uint256(_hash(uint256(uint160(msgSender)), uint256(salt)));

        while (true) {
            unchecked {
                startSalt++;
            }

            address predictedAddress =
                predictPrincipalTokenAddress(bytes32(startSalt), initCodeHash, factory, msgSender, router);

            // Check if predicted PT address > underlying address
            if (uint160(predictedAddress) > underlyingValue) {
                return bytes32(startSalt);
            }
        }
    }

    /// @notice Predict the Principal Token address given a salt
    /// @dev This mirrors the salt hashing logic used by Factory when deploying via router
    /// @param salt User-provided salt
    /// @param bytecodeHash Hash of the Principal Token blueprint creation code
    /// @param factory Factory contract address
    /// @param msgSender The address that will call the router
    /// @param router Router address (UniswapV4Router)
    /// @return predictedAddress The predicted Principal Token address
    function predictPrincipalTokenAddress(
        bytes32 salt,
        bytes32 bytecodeHash,
        address factory,
        address msgSender,
        address router
    ) internal view returns (address predictedAddress) {
        // First hash: msgSender + salt
        uint256 intermediate = uint256(_hash(uint256(uint160(msgSender)), uint256(salt)));
        // Second hash: chainId + router + intermediate
        bytes32 safeSalt = _hash(block.chainid, uint256(uint160(router)), intermediate);
        // Compute CREATE2 address
        return Create2.computeAddress(safeSalt, bytecodeHash, factory);
    }

    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    /*                    INTERNAL HELPERS                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Efficient hash function for two uint256 values
    /// @dev Equivalent to EfficientHashLib.hash from solady, optimized with assembly
    function _hash(uint256 a, uint256 b) internal pure returns (bytes32 result) {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, a)
            mstore(0x20, b)
            result := keccak256(0x00, 0x40)
        }
    }

    /// @notice Efficient hash function for three uint256 values
    /// @dev Equivalent to EfficientHashLib.hash from solady, optimized with assembly
    function _hash(uint256 a, uint256 b, uint256 c) internal pure returns (bytes32 result) {
        /// @solidity memory-safe-assembly
        assembly {
            let m := mload(0x40)
            mstore(m, a)
            mstore(add(m, 0x20), b)
            mstore(add(m, 0x40), c)
            result := keccak256(m, 0x60)
        }
    }

    /// @notice Extract deployed PT and Pool addresses from Factory.Deployed event
    /// @dev Searches through recorded logs for the Deployed event signature
    /// @return deployedPt The deployed Principal Token address
    /// @return deployedPool The deployed Pool address
    function getDeployedAddressesFromEvent() internal returns (address deployedPt, address deployedPool) {
        Vm.Log[] memory logs = VM.getRecordedLogs();
        bytes32 topic = keccak256("Deployed(address,address,address,uint256,address)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic) {
                deployedPt = address(uint160(uint256(logs[i].topics[1])));
                deployedPool = address(uint160(uint256(logs[i].topics[3])));
                break;
            }
        }
    }

    /// @notice Extract creation code from a blueprint contract
    /// @dev Equivalent to LibBlueprint.extractCreationCode
    /// @param blueprint Address of the blueprint contract
    /// @return initcode The extracted creation code
    function _extractCreationCode(address blueprint) internal view returns (bytes memory initcode) {
        uint256 size;
        uint256 offset = 3; // Skip first 3 bytes (EIP-5202 header)

        assembly {
            size := extcodesize(blueprint)
        }

        // Check if there's any code after the offset
        if (size <= offset) {
            revert("InvalidBlueprint");
        }

        // Extract the initcode
        uint256 initcodeSize = size - offset;
        initcode = new bytes(initcodeSize);

        assembly {
            extcodecopy(blueprint, add(initcode, 32), offset, initcodeSize)
        }
    }
}
