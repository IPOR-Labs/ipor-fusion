// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {IFuseCommon} from "../IFuseCommon.sol";
import {INonfungiblePositionManager} from "./ext/INonfungiblePositionManager.sol";

import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {AreodromeSlipstreamSubstrateLib, AreodromeSlipstreamSubstrateType, AreodromeSlipstreamSubstrate} from "./AreodromeSlipstreamLib.sol";

/// @title AreodromeSlipstreamModifyPositionFuseEnterData
/// @notice Input data structure for increasing liquidity in an existing Aerodrome Slipstream position
/// @dev The token0 and token1 fields are included for transient storage compatibility but are ignored
///      during execution. The actual token addresses are derived from the NFT position to ensure
///      correct approvals and prevent mismatches between user input and the position's actual tokens.
struct AreodromeSlipstreamModifyPositionFuseEnterData {
    /// @notice The address of the token0 for a specific pool
    /// @dev This field is ignored during execution; actual token0 is derived from the position
    address token0;
    /// @notice The address of the token1 for a specific pool
    /// @dev This field is ignored during execution; actual token1 is derived from the position
    address token1;
    /// @notice tokenId The ID of the token that represents the minted position
    uint256 tokenId;
    /// @notice The desired amount of token0 to be spent
    uint256 amount0Desired;
    /// @notice The desired amount of token1 to be spent
    uint256 amount1Desired;
    /// @notice The minimum amount of token0 to spend, which serves as a slippage check
    uint256 amount0Min;
    /// @notice The minimum amount of token1 to spend, which serves as a slippage check
    uint256 amount1Min;
    /// @notice The time by which the transaction must be included to effect the change
    uint256 deadline;
}

/// @title AreodromeSlipstreamModifyPositionFuseExitData
/// @notice Input data structure for decreasing liquidity in an existing Aerodrome Slipstream position
struct AreodromeSlipstreamModifyPositionFuseExitData {
    /// @notice The ID of the token for which liquidity is being decreased
    uint256 tokenId;
    /// @notice The amount by which liquidity will be decreased
    uint128 liquidity;
    /// @notice The minimum amount of token0 that should be accounted for the burned liquidity
    uint256 amount0Min;
    /// @notice The minimum amount of token1 that should be accounted for the burned liquidity
    uint256 amount1Min;
    /// @notice The time by which the transaction must be included to effect the change
    uint256 deadline;
}

/// @title AreodromeSlipstreamModifyPositionFuse
/// @notice Fuse for modifying (increasing or decreasing) liquidity in existing Aerodrome Slipstream NFT positions
/// @dev This fuse allows users to add or remove liquidity from existing NFT positions in Aerodrome Slipstream pools.
///      It validates that the pool is granted as a substrate. Token addresses are derived from the position
///      (not user input) to ensure correct approvals and avoid mismatches.
///      Supports both standard function calls and transient storage-based calls.
/// @author IPOR Labs
contract AreodromeSlipstreamModifyPositionFuse is IFuseCommon {
    using SafeERC20 for IERC20;
    using Address for address;

    /// @notice Emitted when liquidity is increased in an existing position
    /// @param version The address of the fuse contract version (VERSION immutable)
    /// @param tokenId The NFT token ID representing the liquidity position
    /// @param liquidity The amount of liquidity added to the position
    /// @param amount0 The amount of token0 used to increase liquidity
    /// @param amount1 The amount of token1 used to increase liquidity
    event AreodromeSlipstreamModifyPositionFuseEnter(
        address version,
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );

    /// @notice Emitted when liquidity is decreased in an existing position
    /// @param version The address of the fuse contract version (VERSION immutable)
    /// @param tokenId The NFT token ID representing the liquidity position
    /// @param amount0 The amount of token0 received from decreasing liquidity
    /// @param amount1 The amount of token1 received from decreasing liquidity
    event AreodromeSlipstreamModifyPositionFuseExit(address version, uint256 tokenId, uint256 amount0, uint256 amount1);

    /// @notice Thrown when attempting to modify a position in a pool that is not granted as a substrate
    /// @param pool The address of the pool that is not supported
    error AreodromeSlipstreamModifyPositionFuseUnsupportedPool(address pool);

    /// @notice Thrown when an invalid address (zero address) is provided
    error InvalidAddress();

    /// @notice Thrown when return data from external call is invalid or insufficient
    error InvalidReturnData();

    /// @notice Thrown when an invalid amount (zero) is provided for operations
    error InvalidAmount();

    /// @notice Thrown when an invalid token ID (zero) is provided
    error InvalidTokenId();

    /// @notice Thrown when the deadline has already expired
    error DeadlineExpired();

    /// @notice The version identifier of this fuse contract
    address public immutable VERSION;

    /// @notice The market ID associated with this fuse
    /// @dev Used to validate that pools and assets are granted for this market
    uint256 public immutable MARKET_ID;

    /// @notice The address of the Aerodrome Slipstream NonfungiblePositionManager contract
    /// @dev Manages NFT positions representing liquidity in Aerodrome Slipstream pools
    address public immutable NONFUNGIBLE_POSITION_MANAGER;

    /// @notice The address of the Aerodrome Slipstream Factory contract
    /// @dev Used to compute pool addresses from token pairs and tick spacing
    address public immutable FACTORY;

    /// @notice Constructor to initialize the fuse with market ID and position manager
    /// @param marketId_ The unique identifier for the market configuration
    /// @param nonfungiblePositionManager_ The address of the Aerodrome Slipstream NonfungiblePositionManager contract
    /// @dev Validates that nonfungiblePositionManager_ is not zero address.
    ///      Retrieves and validates the factory address from the position manager.
    ///      Sets VERSION to the address of this contract instance.
    /// @custom:revert InvalidAddress When nonfungiblePositionManager_ or factory address is zero
    constructor(uint256 marketId_, address nonfungiblePositionManager_) {
        if (nonfungiblePositionManager_ == address(0)) {
            revert InvalidAddress();
        }

        VERSION = address(this);
        MARKET_ID = marketId_;
        NONFUNGIBLE_POSITION_MANAGER = nonfungiblePositionManager_;
        FACTORY = INonfungiblePositionManager(nonfungiblePositionManager_).factory();

        if (FACTORY == address(0)) {
            revert InvalidAddress();
        }
    }

    /// @notice Increases liquidity in an existing position
    /// @dev Validates that at least one of amount0Desired or amount1Desired is greater than zero before proceeding.
    ///      Validates that the position's pool is granted as a substrate.
    ///      Derives actual token0/token1 from the position to ensure correct approvals and avoid user input mismatches.
    ///      Approves tokens, increases liquidity, and resets approvals to zero after the operation completes.
    /// @param data_ The data containing tokenId, amounts, and deadline (token0/token1 fields are ignored; actual tokens derived from position)
    /// @return tokenId The ID of the token position
    /// @return liquidity The amount of liquidity added to the position
    /// @return amount0 The amount of token0 actually used to increase liquidity
    /// @return amount1 The amount of token1 actually used to increase liquidity
    /// @custom:revert DeadlineExpired When deadline is in the past
    /// @custom:revert InvalidAmount When both amount0Desired and amount1Desired are zero
    /// @custom:revert InvalidTokenId When tokenId is zero
    /// @custom:revert AreodromeSlipstreamModifyPositionFuseUnsupportedPool When pool is not granted as a substrate
    function enter(
        AreodromeSlipstreamModifyPositionFuseEnterData memory data_
    ) public returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        // Validate deadline is not in the past
        if (data_.deadline < block.timestamp) {
            revert DeadlineExpired();
        }

        // Validate that at least one amount is greater than zero
        // This prevents unnecessary gas consumption and potential state inconsistencies
        if (data_.amount0Desired == 0 && data_.amount1Desired == 0) {
            revert InvalidAmount();
        }

        // Validate pool and assets, and get the actual tokens from the position
        (address actualToken0, address actualToken1) = _validatePool(data_.tokenId);

        // Use the actual tokens from the position for approvals (not user-provided tokens)
        // This prevents mismatches between user input and the position's actual tokens
        IERC20(actualToken0).forceApprove(address(NONFUNGIBLE_POSITION_MANAGER), data_.amount0Desired);
        IERC20(actualToken1).forceApprove(address(NONFUNGIBLE_POSITION_MANAGER), data_.amount1Desired);

        INonfungiblePositionManager.IncreaseLiquidityParams memory params = INonfungiblePositionManager
            .IncreaseLiquidityParams({
                tokenId: data_.tokenId,
                amount0Desired: data_.amount0Desired,
                amount1Desired: data_.amount1Desired,
                amount0Min: data_.amount0Min,
                amount1Min: data_.amount1Min,
                deadline: data_.deadline
            });

        (liquidity, amount0, amount1) = INonfungiblePositionManager(NONFUNGIBLE_POSITION_MANAGER).increaseLiquidity(
            params
        );

        // Reset approvals to zero using the actual tokens
        IERC20(actualToken0).forceApprove(address(NONFUNGIBLE_POSITION_MANAGER), 0);
        IERC20(actualToken1).forceApprove(address(NONFUNGIBLE_POSITION_MANAGER), 0);

        emit AreodromeSlipstreamModifyPositionFuseEnter(VERSION, data_.tokenId, liquidity, amount0, amount1);

        return (data_.tokenId, liquidity, amount0, amount1);
    }

    /// @notice Increases liquidity in an existing position using transient storage for inputs
    /// @dev Reads token0, token1, tokenId, amount0Desired, amount1Desired, amount0Min, amount1Min, deadline from transient storage
    /// @dev Writes returned tokenId, liquidity, amount0, amount1 to transient storage outputs
    /// @dev Uses batch getInputs() instead of individual getInput() calls for gas efficiency
    function enterTransient() external {
        // Batch fetch all inputs in single call to save ~100-200 gas
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        address token0 = TypeConversionLib.toAddress(inputs[0]);
        address token1 = TypeConversionLib.toAddress(inputs[1]);
        uint256 tokenId = TypeConversionLib.toUint256(inputs[2]);
        uint256 amount0Desired = TypeConversionLib.toUint256(inputs[3]);
        uint256 amount1Desired = TypeConversionLib.toUint256(inputs[4]);
        uint256 amount0Min = TypeConversionLib.toUint256(inputs[5]);
        uint256 amount1Min = TypeConversionLib.toUint256(inputs[6]);
        uint256 deadline = TypeConversionLib.toUint256(inputs[7]);

        AreodromeSlipstreamModifyPositionFuseEnterData memory data = AreodromeSlipstreamModifyPositionFuseEnterData({
            token0: token0,
            token1: token1,
            tokenId: tokenId,
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: amount0Min,
            amount1Min: amount1Min,
            deadline: deadline
        });

        (uint256 returnedTokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = enter(data);

        bytes32[] memory outputs = new bytes32[](4);
        outputs[0] = TypeConversionLib.toBytes32(returnedTokenId);
        outputs[1] = TypeConversionLib.toBytes32(uint256(liquidity));
        outputs[2] = TypeConversionLib.toBytes32(amount0);
        outputs[3] = TypeConversionLib.toBytes32(amount1);

        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Decreases liquidity in an existing position
    /// @dev Validates liquidity amount and pool before decreasing liquidity.
    ///      Returns the amounts of token0 and token1 received from the position.
    /// @param data_ The data containing tokenId, liquidity amount, minimum amounts, and deadline
    /// @return tokenId The ID of the token position
    /// @return amount0 The amount of token0 received from decreasing liquidity
    /// @return amount1 The amount of token1 received from decreasing liquidity
    /// @custom:revert DeadlineExpired When deadline is in the past
    /// @custom:revert InvalidAmount When liquidity is zero
    /// @custom:revert InvalidTokenId When tokenId is zero
    /// @custom:revert AreodromeSlipstreamModifyPositionFuseUnsupportedPool When pool is not granted as a substrate
    function exit(
        AreodromeSlipstreamModifyPositionFuseExitData memory data_
    ) public returns (uint256 tokenId, uint256 amount0, uint256 amount1) {
        // Validate deadline is not in the past
        if (data_.deadline < block.timestamp) {
            revert DeadlineExpired();
        }

        if (data_.liquidity == 0) {
            revert InvalidAmount();
        }

        // Validate pool and assets (tokens are validated but not needed for decreaseLiquidity)
        _validatePool(data_.tokenId);

        INonfungiblePositionManager.DecreaseLiquidityParams memory params = INonfungiblePositionManager
            .DecreaseLiquidityParams({
                tokenId: data_.tokenId,
                liquidity: data_.liquidity,
                amount0Min: data_.amount0Min,
                amount1Min: data_.amount1Min,
                deadline: data_.deadline
            });

        (amount0, amount1) = INonfungiblePositionManager(NONFUNGIBLE_POSITION_MANAGER).decreaseLiquidity(params);

        emit AreodromeSlipstreamModifyPositionFuseExit(VERSION, data_.tokenId, amount0, amount1);

        return (data_.tokenId, amount0, amount1);
    }

    /// @notice Decreases liquidity in an existing position using transient storage for inputs
    /// @dev Reads tokenId, liquidity, amount0Min, amount1Min, deadline from transient storage
    /// @dev Writes returned tokenId, amount0, amount1 to transient storage outputs
    /// @dev Uses batch getInputs() instead of individual getInput() calls for gas efficiency
    function exitTransient() external {
        // Batch fetch all inputs in single call to save ~80-150 gas
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        uint256 tokenId = TypeConversionLib.toUint256(inputs[0]);
        uint128 liquidity = TypeConversionLib.toUint128(TypeConversionLib.toUint256(inputs[1]));
        uint256 amount0Min = TypeConversionLib.toUint256(inputs[2]);
        uint256 amount1Min = TypeConversionLib.toUint256(inputs[3]);
        uint256 deadline = TypeConversionLib.toUint256(inputs[4]);

        AreodromeSlipstreamModifyPositionFuseExitData memory data = AreodromeSlipstreamModifyPositionFuseExitData({
            tokenId: tokenId,
            liquidity: liquidity,
            amount0Min: amount0Min,
            amount1Min: amount1Min,
            deadline: deadline
        });

        (uint256 returnedTokenId, uint256 amount0, uint256 amount1) = exit(data);

        bytes32[] memory outputs = new bytes32[](3);
        outputs[0] = TypeConversionLib.toBytes32(returnedTokenId);
        outputs[1] = TypeConversionLib.toBytes32(amount0);
        outputs[2] = TypeConversionLib.toBytes32(amount1);

        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Validates that the pool associated with a token ID is granted as a substrate
    /// @param tokenId_ The NFT token ID to validate
    /// @return token0 The address of token0 in the position
    /// @return token1 The address of token1 in the position
    /// @dev Reads position data from the NonfungiblePositionManager to extract token0, token1, and tickSpacing.
    ///      Computes the pool address and validates it against granted substrates.
    ///      Returns the actual tokens from the position to ensure correct approvals.
    /// @dev Assembly is used for return data parsing instead of abi.decode for gas efficiency.
    ///      The positions() function returns a struct with 12 fields, but we only need 3 (token0, token1, tickSpacing).
    ///      Using abi.decode would require decoding all 12 fields, increasing gas costs significantly.
    ///      Assembly allows us to extract only the required fields at known offsets.
    /// @custom:revert InvalidTokenId When tokenId is zero
    /// @custom:revert InvalidReturnData When return data from positions() call is insufficient
    /// @custom:revert AreodromeSlipstreamModifyPositionFuseUnsupportedPool When pool is not granted as a substrate
    function _validatePool(uint256 tokenId_) internal view returns (address token0, address token1) {
        // Validate tokenId is not zero
        if (tokenId_ == 0) {
            revert InvalidTokenId();
        }

        int24 tickSpacing;

        // INonfungiblePositionManager.positions(tokenId) selector: 0x99fbab88
        // 0x99fbab88 = bytes4(keccak256("positions(uint256)"))
        bytes memory returnData = NONFUNGIBLE_POSITION_MANAGER.functionStaticCall(
            abi.encodeWithSelector(INonfungiblePositionManager.positions.selector, tokenId_)
        );

        // positions returns (
        //    uint96 nonce,                    // offset 0
        //    address operator,                // offset 1
        //    address token0,                  // offset 2
        //    address token1,                  // offset 3
        //    int24 tickSpacing,               // offset 4
        //    ... )
        // All types are padded to 32 bytes in ABI encoding.

        if (returnData.length < 160) revert InvalidReturnData();

        assembly {
            // returnData is a pointer to bytes array in memory.
            // First 32 bytes at returnData is the length of the array.
            // The actual data starts at returnData + 32.

            // We need to skip nonce (index 0) and operator (index 1).
            // Each slot is 32 bytes.
            // token0 is at index 2: 32 (length) + 32 * 2 = 96
            token0 := mload(add(returnData, 96))

            // token1 is at index 3: 32 (length) + 32 * 3 = 128
            token1 := mload(add(returnData, 128))

            // tickSpacing is at index 4: 32 (length) + 32 * 4 = 160
            // tickSpacing is int24, so we need to ensure we handle sign extension correctly?
            // mload loads 32 bytes.
            // In ABI encoding, signed integers are sign-extended to 32 bytes.
            // Since tickSpacing is int24, it fits in int256/uint256 variable in assembly.
            // When assigning to int24 solidity variable, it will be cast implicitly.
            tickSpacing := mload(add(returnData, 160))
        }

        address pool = AreodromeSlipstreamSubstrateLib.getPoolAddress(FACTORY, token0, token1, tickSpacing);

        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                AreodromeSlipstreamSubstrateLib.substrateToBytes32(
                    AreodromeSlipstreamSubstrate({
                        substrateType: AreodromeSlipstreamSubstrateType.Pool,
                        substrateAddress: pool
                    })
                )
            )
        ) {
            revert AreodromeSlipstreamModifyPositionFuseUnsupportedPool(pool);
        }

        return (token0, token1);
    }
}
