// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/velodrome_superchain/VelodromeSuperchainBalanceFuse.sol

import {VelodromeSuperchainBalanceFuse} from "contracts/fuses/velodrome_superchain/VelodromeSuperchainBalanceFuse.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {MockPriceOracle} from "test/fuses/aave_v4/MockPriceOracle.sol";
import {IPool} from "contracts/fuses/velodrome_superchain/ext/IPool.sol";
import {ILeafGauge} from "contracts/fuses/velodrome_superchain/ext/ILeafGauge.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
contract VelodromeSuperchainBalanceFuseTest is OlympixUnitTest("VelodromeSuperchainBalanceFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_balanceOf_zeroSubstrates_returnsZero() public {
            uint256 marketId = 1;
            VelodromeSuperchainBalanceFuse fuse = new VelodromeSuperchainBalanceFuse(marketId);
    
            bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(marketId);
            assertEq(substrates.length, 0, "precondition: substrates length should be zero");
    
            uint256 balance = fuse.balanceOf();
    
            assertEq(balance, 0, "balance for empty substrates must be zero");
        }
}