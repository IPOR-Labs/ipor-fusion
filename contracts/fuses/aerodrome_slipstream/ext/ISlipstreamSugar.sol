// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {INonfungiblePositionManager} from "./INonfungiblePositionManager.sol";

interface ISlipstreamSugar {
    function principal(
        INonfungiblePositionManager positionManager,
        uint256 tokenId,
        uint160 sqrtRatioX96
    ) external view returns (uint256 amount0, uint256 amount1);

    function fees(
        INonfungiblePositionManager positionManager,
        uint256 tokenId
    ) external view returns (uint256 amount0, uint256 amount1);
}
