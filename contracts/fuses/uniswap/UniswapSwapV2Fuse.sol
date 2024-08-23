// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IUniversalRouter} from "./ext/IUniversalRouter.sol";
import {IFuse} from "../IFuse.sol";

struct UniswapSwapV2FuseEnterData {
    uint256 tokenInAmount;
    address[] path;
    uint256 minOutAmount;
    uint256 uniswapVersion;
}

uint256 constant V2_SWAP_EXACT_IN = 0x08;
uint256 constant V3_SWAP_EXACT_IN = 0x00;

contract UniswapSwapV2Fuse is IFuse {
    using SafeERC20 for IERC20;
    error UniswapSwapV2FuseUnsupportedToken(address asset);
    error UnsupportedMethod();

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address public immutable UNIVERSAL_ROUTER;

    constructor(uint256 marketId_, address universalRouter_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        UNIVERSAL_ROUTER = universalRouter_;
    }

    function enter(bytes calldata data_) external override {
        _enter(abi.decode(data_, (UniswapSwapV2FuseEnterData)));
    }

    function _enter(UniswapSwapV2FuseEnterData memory data_) internal {
        uint256 pathLength = data_.path.length;
        if (data_.tokenInAmount == 0 || pathLength < 2) {
            return;
        }

        for (uint256 i; i < pathLength; ++i) {
            if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.path[i])) {
                revert UniswapSwapV2FuseUnsupportedToken(data_.path[i]);
            }
        }

        uint256 vaultBalance = IERC20(data_.path[0]).balanceOf(address(this));
        uint256 inputAmount = data_.tokenInAmount <= vaultBalance ? data_.tokenInAmount : vaultBalance;

        IERC20(data_.path[0]).safeTransfer(UNIVERSAL_ROUTER, inputAmount);

        bytes memory commands = abi.encodePacked(bytes1(uint8(V2_SWAP_EXACT_IN)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(address(this), inputAmount, data_.minOutAmount, data_.path, false);

        IUniversalRouter(UNIVERSAL_ROUTER).execute(commands, inputs);
    }

    function exit(bytes calldata data_) external override {
        revert UnsupportedMethod();
    }
}
