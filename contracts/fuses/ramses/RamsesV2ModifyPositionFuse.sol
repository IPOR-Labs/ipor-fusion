// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {INonfungiblePositionManagerRamses} from "./ext/INonfungiblePositionManagerRamses.sol";

/**
 * @title RamsesV2ModifyPositionFuse
 * @dev Contract for modifying liquidity positions in the Ramses V2 system.
 */
struct RamsesV2ModifyPositionFuseEnterData {
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

/// @notice Data for exiting RamsesV2ModifyPositionFuse.sol - decrease liquidity
struct RamsesV2ModifyPositionFuseExitData {
    /// @notice tokenId The ID of the token for which liquidity is being decreased
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

/// @dev Associated with fuse balance RamsesV2Balance.
contract RamsesV2ModifyPositionFuse is IFuseCommon {
    using SafeERC20 for IERC20;
    using Address for address;

    /// @notice Event emitted when liquidity is increased in a position
    /// @param version The address of the contract version
    /// @param tokenId The ID of the token
    /// @param liquidity The amount of liquidity added
    /// @param amount0 The amount of token0 added
    /// @param amount1 The amount of token1 added
    event RamsesV2ModifyPositionFuseEnter(
        address version,
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );

    /// @notice Event emitted when liquidity is decreased in a position
    /// @param version The address of the contract version
    /// @param tokenId The ID of the token
    /// @param amount0 The amount of token0 removed
    /// @param amount1 The amount of token1 removed
    event RamsesV2ModifyPositionFuseExit(address version, uint256 tokenId, uint256 amount0, uint256 amount1);

    error RamsesV2ModifyPositionFuseUnsupportedToken(address token0, address token1);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    /// @dev Manage NFTs representing liquidity positions
    address public immutable NONFUNGIBLE_POSITION_MANAGER;

    /**
     * @dev Constructor for the RamsesV2ModifyPositionFuse contract
     * @param marketId_ The ID of the market
     * @param nonfungiblePositionManager_ The address of the non-fungible position manager
     */
    constructor(uint256 marketId_, address nonfungiblePositionManager_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        NONFUNGIBLE_POSITION_MANAGER = nonfungiblePositionManager_;
    }

    /**
     * @notice Function to increase liquidity in a position
     * @param data_ The data containing the parameters for increasing liquidity
     */
    function enter(RamsesV2ModifyPositionFuseEnterData calldata data_) public {
        // empty
    }

    /**
     * @notice Function to decrease liquidity in a position
     * @param data_ The data containing the parameters for decreasing liquidity
     */
    function exit(RamsesV2ModifyPositionFuseExitData calldata data_) public {
        // empty
    }
}
