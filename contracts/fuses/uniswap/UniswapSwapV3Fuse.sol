// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IUniversalRouter} from "./ext/IUniversalRouter.sol";
import {IFuse} from "../IFuse.sol";

struct UniswapSwapV3FuseEnterData {
    uint256 tokenInAmount;
    uint256 minOutAmount;
    bytes path;
}

//@dev from uniswap documentation
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
    using SafeCast for int256;
    using SafeCast for uint256;

    error UniswapSwapV3FuseUnsupportedToken(address asset);
    error UnsupportedMethod();
    error SliceOutOfBounds();

    event UniswapSwapV2EnterFuse(address version, uint256 tokenInAmount, bytes path, uint256 minOutAmount);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address public immutable UNIVERSAL_ROUTER;

    constructor(uint256 marketId_, address universalRouter_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        UNIVERSAL_ROUTER = universalRouter_;
    }

    //solhint-disable-next-line
    function enter(bytes calldata data_) external override {
        revert UnsupportedMethod();
    }

    function enter(UniswapSwapV3FuseEnterData calldata data_) external {
        address[] memory tokens;
        bytes calldata path = data_.path;
        bytes memory memoryPath = data_.path;
        uint256 numberOfTokens;

        if (hasMultiplePools(path)) {
            numberOfTokens = ((path.length.toInt256() - ADDR_SIZE.toInt256()).toUint256() / NEXT_V3_POOL_OFFSET) + 1;
            tokens = new address[](numberOfTokens);
            for (uint256 i; i < numberOfTokens; ++i) {
                tokens[i] = decodeFirstToken(path);
                if (i != numberOfTokens - 1) {
                    path = skipTokenAndFee(path);
                }
            }
        } else {
            numberOfTokens = 2;
            tokens = new address[](numberOfTokens);
            tokens[0] = decodeFirstToken(path);
            path = skipTokenAndFee(path);
            tokens[1] = decodeFirstToken(path);
        }

        for (uint256 i; i < numberOfTokens; ++i) {
            if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, tokens[i])) {
                revert UniswapSwapV3FuseUnsupportedToken(tokens[i]);
            }
        }

        uint256 vaultBalance = IERC20(tokens[0]).balanceOf(address(this));
        uint256 inputAmount = data_.tokenInAmount <= vaultBalance ? data_.tokenInAmount : vaultBalance;

        IERC20(tokens[0]).safeTransfer(UNIVERSAL_ROUTER, inputAmount);

        bytes memory commands = abi.encodePacked(bytes1(uint8(V3_SWAP_EXACT_IN)));

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(address(1), inputAmount, data_.minOutAmount, memoryPath, false);

        IUniversalRouter(UNIVERSAL_ROUTER).execute(commands, inputs);

        emit UniswapSwapV2EnterFuse(VERSION, data_.tokenInAmount, memoryPath, data_.minOutAmount);
    }

    //solhint-disable-next-line
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
