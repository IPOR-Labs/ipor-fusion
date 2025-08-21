// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

struct Slot0 {
    // the current price
    uint160 sqrtPriceX96;
    // the current tick
    int24 tick;
    // the most-recently updated index of the observations array
    uint16 observationIndex;
    // the current maximum number of observations that are being stored
    uint16 observationCardinality;
    // the next maximum number of observations to store, triggered in observations.write
    uint16 observationCardinalityNext;
    // whether the pool is locked
    bool unlocked;
}

interface ICLPool {
    function slot0() external view returns (Slot0 memory);

    function token0() external view returns (address);

    function token1() external view returns (address);
}
