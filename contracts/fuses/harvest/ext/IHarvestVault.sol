// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

interface IHarvestVault {
    function controller() external view returns (address);
}
