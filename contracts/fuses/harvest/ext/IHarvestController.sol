// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

interface IHarvestController {
    function doHardWork(address _vault) external;
    function addHardWorker(address _worker) external;
}
