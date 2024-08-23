// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IUniversalRouter} from "./ext/IUniversalRouter.sol";
import {IFuse} from "../IFuse.sol";

struct UniswapSwapV3FuseEnterData {
    uint256 tokenInAmount;
    uint256 minOutAmount;
    bytes path;
}

uint256 constant V3_SWAP_EXACT_IN = 0x00;
/// @dev The length of the bytes encoded address
uint256 constant ADDR_SIZE = 20;
/// @dev The length of the bytes encoded fee
uint256 constant V3_FEE_SIZE = 3;
/// @dev The offset of a single token address (20) and pool fee (3)
uint256 constant NEXT_V3_POOL_OFFSET = ADDR_SIZE + V3_FEE_SIZE;
/// @dev The offset of an encoded pool key
/// Token (20) + Fee (3) + Token (20) = 43
uint256 constant V3_POP_OFFSET = NEXT_V3_POOL_OFFSET + ADDR_SIZE;
/// @dev The minimum length of an encoding that contains 2 or more pools
uint256 constant MULTIPLE_V3_POOLS_MIN_LENGTH = V3_POP_OFFSET + NEXT_V3_POOL_OFFSET;

contract UniswapSwapV3Fuse is IFuse {
    using SafeERC20 for IERC20;
    error UniswapSwapV3FuseUnsupportedToken(address asset);
    error UnsupportedMethod();
    error SliceOutOfBounds();

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address public immutable UNIVERSAL_ROUTER;

    constructor(uint256 marketId_, address universalRouter_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        UNIVERSAL_ROUTER = universalRouter_;
    }

    function enter(bytes calldata data_) external override {
        //        UniswapSwapV3FuseEnterData calldata data = abi.decode(data_, (UniswapSwapV3FuseEnterData));
        //        _enter(data);
    }

    function _enter(UniswapSwapV3FuseEnterData calldata data_) internal {
        address[] memory tokens;
        bytes calldata path = data_.path;
        bytes memory memoryPath = data_.path;
        if (hasMultiplePools(path)) {
            uint256 numberOfTokens = ((path.length - ADDR_SIZE) / NEXT_V3_POOL_OFFSET) + 1;
            tokens = new address[](numberOfTokens);
            for (uint256 i; i < numberOfTokens; ++i) {
                tokens[i] = decodeFirstToken(path);
                path = skipTokenAndFee(path);
            }
        } else {
            tokens = new address[](2);
            tokens[0] = decodeFirstToken(path);
            path = skipToken(path);
            tokens[1] = decodeFirstToken(path);
        }
        //        uint256 pathLength = data_.path.length;
        //        if (data_.tokenInAmount == 0 || pathLength < 2) {
        //            return;
        //        }
        //
        //        for (uint256 i; i < pathLength; ++i) {
        //            if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.path[i])) {
        //                revert UniswapSwapV3FuseUnsupportedToken(data_.path[i]);
        //            }
        //        }
        //        uint256 vaultBalance = IERC20(data_.path[0]).balanceOf(address(this));
        //        uint256 inputAmount = data_.tokenInAmount <= vaultBalance ? data_.tokenInAmount : vaultBalance;
        //        IERC20(data_.path[0]).safeTransfer(UNIVERSAL_ROUTER, inputAmount);
        //        bytes memory commands = abi.encodePacked(bytes1(uint8(V3_SWAP_EXACT_IN)));
        //        bytes[] memory inputs = new bytes[](1);
        //        inputs[0] = abi.encode(address(this), inputAmount, data_.minOutAmount, data_.path, false);
        //
        //        IUniversalRouter(UNIVERSAL_ROUTER).execute(commands, inputs);
    }

    function exit(bytes memory data_) external override {
        revert UnsupportedMethod();
    }

    /// @notice Returns true iff the path contains two or more pools
    /// @param path_ The encoded swap path
    /// @return True if path contains two or more pools, otherwise false
    function hasMultiplePools(bytes calldata path_) private pure returns (bool) {
        return path_.length >= MULTIPLE_V3_POOLS_MIN_LENGTH;
    }

    function decodeFirstToken(bytes calldata path_) private pure returns (address tokenA) {
        tokenA = toAddress(path_);
    }

    /// @notice Skips a token + fee element
    /// @param path_ The swap path
    function skipTokenAndFee(bytes calldata path_) private pure returns (bytes calldata) {
        return path_[NEXT_V3_POOL_OFFSET:];
    }

    function skipToken(bytes calldata path_) private pure returns (bytes calldata) {
        return path_[ADDR_SIZE:];
    }

    /// @notice Returns the address starting at byte 0
    /// @dev length and overflow checks must be carried out before calling
    /// @param bytes_ The input bytes string to slice
    /// @return _address The address starting at byte 0
    function toAddress(bytes calldata bytes_) private pure returns (address _address) {
        if (bytes_.length < ADDR_SIZE) revert SliceOutOfBounds();
        assembly {
            _address := shr(96, calldataload(bytes_.offset))
        }
    }
}
