// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {INonfungiblePositionManager} from "./ext/INonfungiblePositionManager.sol";
import {AreodromeSlipstreamSubstrateLib, AreodromeSlipstreamSubstrateType, AreodromeSlipstreamSubstrate} from "./AreodromeSlipstreamLib.sol";

struct AreodromeSlipstreamModifyPositionFuseEnterData {
    /// @notice The address of the token0 for a specific pool
    address token0;
    /// @notice The address of the token1 for a specific pool
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

contract AreodromeSlipstreamModifyPositionFuse is IFuseCommon {
    using SafeERC20 for IERC20;
    using Address for address;

    event AreodromeSlipstreamModifyPositionFuseEnter(
        address version,
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );
    event AreodromeSlipstreamModifyPositionFuseExit(address version, uint256 tokenId, uint256 amount0, uint256 amount1);

    error AreodromeSlipstreamModifyPositionFuseUnsupportedPool(address pool);
    error InvalidAddress();

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    /// @dev Manage NFTs representing liquidity positions
    address public immutable NONFUNGIBLE_POSITION_MANAGER;
    address public immutable FACTORY;

    constructor(uint256 marketId_, address nonfungiblePositionManager_) {
        if (nonfungiblePositionManager_ == address(0)) {
            revert InvalidAddress();
        }

        VERSION = address(this);
        MARKET_ID = marketId_;
        NONFUNGIBLE_POSITION_MANAGER = nonfungiblePositionManager_;
        FACTORY = INonfungiblePositionManager(nonfungiblePositionManager_).factory();
    }

    function validatePool(uint256 tokenId) external view {
        address token0;
        address token1;
        int24 tickSpacing;

        // INonfungiblePositionManager.positions(tokenId) selector: 0x99fbab88
        // 0x99fbab88 = bytes4(keccak256("positions(uint256)"))
        bytes memory returnData = NONFUNGIBLE_POSITION_MANAGER.functionStaticCall(
            abi.encodeWithSelector(INonfungiblePositionManager.positions.selector, tokenId)
        );

        // positions returns (
        //    uint96 nonce,                    // offset 0
        //    address operator,                // offset 1
        //    address token0,                  // offset 2
        //    address token1,                  // offset 3
        //    int24 tickSpacing,               // offset 4
        //    ... )
        // All types are padded to 32 bytes in ABI encoding.

        if (returnData.length < 160) revert("Invalid return data");

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
    }

    function enter(AreodromeSlipstreamModifyPositionFuseEnterData calldata data_) public {
        // this.validatePool(data_.tokenId);

        IERC20(data_.token0).forceApprove(address(NONFUNGIBLE_POSITION_MANAGER), data_.amount0Desired);
        IERC20(data_.token1).forceApprove(address(NONFUNGIBLE_POSITION_MANAGER), data_.amount1Desired);

        INonfungiblePositionManager.IncreaseLiquidityParams memory params = INonfungiblePositionManager
            .IncreaseLiquidityParams({
                tokenId: data_.tokenId,
                amount0Desired: data_.amount0Desired,
                amount1Desired: data_.amount1Desired,
                amount0Min: data_.amount0Min,
                amount1Min: data_.amount1Min,
                deadline: data_.deadline
            });

        (uint128 liquidity, uint256 amount0, uint256 amount1) = INonfungiblePositionManager(
            NONFUNGIBLE_POSITION_MANAGER
        ).increaseLiquidity(params);

        IERC20(data_.token0).forceApprove(address(NONFUNGIBLE_POSITION_MANAGER), 0);
        IERC20(data_.token1).forceApprove(address(NONFUNGIBLE_POSITION_MANAGER), 0);

        emit AreodromeSlipstreamModifyPositionFuseEnter(VERSION, data_.tokenId, liquidity, amount0, amount1);
    }

    function exit(AreodromeSlipstreamModifyPositionFuseExitData calldata data_) public {
        // this.validatePool(data_.tokenId);

        INonfungiblePositionManager.DecreaseLiquidityParams memory params = INonfungiblePositionManager
            .DecreaseLiquidityParams({
                tokenId: data_.tokenId,
                liquidity: data_.liquidity,
                amount0Min: data_.amount0Min,
                amount1Min: data_.amount1Min,
                deadline: data_.deadline
            });

        (uint256 amount0, uint256 amount1) = INonfungiblePositionManager(NONFUNGIBLE_POSITION_MANAGER)
            .decreaseLiquidity(params);

        emit AreodromeSlipstreamModifyPositionFuseExit(VERSION, data_.tokenId, amount0, amount1);
    }
}
