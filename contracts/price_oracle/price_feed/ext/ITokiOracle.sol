// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

interface ITokiOracle {
    function convertYtToUnderlying(
        address liquidityToken,
        uint32 duration,
        uint256 principals
    ) external view returns (uint256);

    function convertYtToAssets(
        address liquidityToken,
        uint32 duration,
        uint256 principals
    ) external view returns (uint256);

    function checkTwapReadiness(
        address liquidityToken,
        uint32 twapWindow
    ) external view returns (bool needsCapacityIncrease, uint16 cardinalityRequired, bool hasOldestData);
}
