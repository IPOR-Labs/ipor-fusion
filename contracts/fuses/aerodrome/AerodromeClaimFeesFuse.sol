// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPool} from "./ext/IPool.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {AerodromeSubstrateLib, AerodromeSubstrate, AerodromeSubstrateType} from "./AreodromeLib.sol";

struct AerodromeClaimFeesFuseEnterData {
    address[] pools;
}

/// @title AerodromeClaimFeesFuse
/// @notice Fuse for claiming fees from Aerodrome protocol pools
/// @dev This fuse allows claiming accumulated fees from multiple Aerodrome pools in a single transaction.
///      Each pool address must be granted as a substrate for the specified MARKET_ID.
///      The fuse aggregates total claimed amounts (token0 and token1) across all pools.
/// @author IPOR Labs
contract AerodromeClaimFeesFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    /// @notice The address of this fuse version for tracking purposes
    address public immutable VERSION;

    /// @notice The market ID associated with this fuse
    /// @dev This ID is used to validate that pool addresses are granted as substrates for this market
    uint256 public immutable MARKET_ID;

    /// @notice Event emitted when fees are claimed from a pool
    /// @param version The version identifier of this fuse contract
    /// @param pool The address of the pool from which fees were claimed
    /// @param claimed0 The amount of token0 claimed from the pool
    /// @param claimed1 The amount of token1 claimed from the pool
    event AerodromeClaimFeesFuseEnter(address version, address pool, uint256 claimed0, uint256 claimed1);

    /// @notice Thrown when attempting to claim fees from a pool that is not granted as a substrate
    /// @param operation The operation that failed (e.g., "enter")
    /// @param pool The address of the pool that is not supported
    error AerodromeClaimFeesFuseUnsupportedPool(string operation, address pool);

    /// @notice Thrown when a pool address in the array is zero address
    /// @param index The index in the pools array where the zero address was found
    error AerodromeClaimFeesFuseZeroAddressPool(uint256 index);

    /// @notice Constructor to initialize the fuse with a market ID
    /// @param marketIdInput_ The unique identifier for the market configuration
    /// @dev The market ID is used to validate that pool addresses are granted as substrates.
    ///      VERSION is set to the address of this contract instance for tracking purposes.
    constructor(uint256 marketIdInput_) {
        VERSION = address(this);
        MARKET_ID = marketIdInput_;
    }

    /// @notice Claims fees from Aerodrome pools
    /// @param data_ The data containing array of pool addresses to claim fees from
    /// @return totalClaimed0 Total amount of token0 claimed across all pools
    /// @return totalClaimed1 Total amount of token1 claimed across all pools
    /// @dev Validates that each pool address is not zero and is granted as a substrate for the market.
    ///      Claims fees from each pool and aggregates the total amounts.
    ///      Emits an event for each pool from which fees were claimed.
    /// @custom:revert AerodromeClaimFeesFuseZeroAddressPool When a pool address in the array is zero
    /// @custom:revert AerodromeClaimFeesFuseUnsupportedPool When a pool is not granted as a substrate
    function enter(
        AerodromeClaimFeesFuseEnterData memory data_
    ) public returns (uint256 totalClaimed0, uint256 totalClaimed1) {
        address poolAddress;
        uint256 claimed0;
        uint256 claimed1;
        uint256 len = data_.pools.length;

        for (uint256 i; i < len; ++i) {
            poolAddress = data_.pools[i];
            if (poolAddress == address(0)) {
                revert AerodromeClaimFeesFuseZeroAddressPool(i);
            }
            if (
                !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                    MARKET_ID,
                    AerodromeSubstrateLib.substrateToBytes32(
                        AerodromeSubstrate({substrateAddress: poolAddress, substrateType: AerodromeSubstrateType.Pool})
                    )
                )
            ) {
                revert AerodromeClaimFeesFuseUnsupportedPool("enter", poolAddress);
            }
            (claimed0, claimed1) = IPool(poolAddress).claimFees();

            totalClaimed0 += claimed0;
            totalClaimed1 += claimed1;

            emit AerodromeClaimFeesFuseEnter(VERSION, poolAddress, claimed0, claimed1);
        }
    }

    /// @notice Enters the Fuse using transient storage for parameters
    /// @dev Reads pools array from transient storage (first element is length, subsequent elements are pool addresses).
    ///      Writes returned totalClaimed0 and totalClaimed1 to transient storage outputs.
    ///      This method enables the fuse to be called through transient storage mechanism.
    /// @custom:revert AerodromeClaimFeesFuseZeroAddressPool When a pool address in the array is zero
    /// @custom:revert AerodromeClaimFeesFuseUnsupportedPool When a pool is not granted as a substrate
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        // inputs[0] contains the length of pools array
        uint256 poolsLength = TypeConversionLib.toUint256(inputs[0]);

        // Read pools from inputs[1..n]
        address[] memory pools = new address[](poolsLength);
        for (uint256 i; i < poolsLength; ++i) {
            pools[i] = TypeConversionLib.toAddress(inputs[1 + i]);
        }

        // Call enter() and get returned values
        (uint256 totalClaimed0, uint256 totalClaimed1) = enter(AerodromeClaimFeesFuseEnterData(pools));

        // Write outputs to transient storage
        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(totalClaimed0);
        outputs[1] = TypeConversionLib.toBytes32(totalClaimed1);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}
