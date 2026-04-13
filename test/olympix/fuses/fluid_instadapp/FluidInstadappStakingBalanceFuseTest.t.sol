// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/fluid_instadapp/FluidInstadappStakingBalanceFuse.sol

import {FluidInstadappStakingBalanceFuse} from "contracts/fuses/fluid_instadapp/FluidInstadappStakingBalanceFuse.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {PriceOracleMiddlewareMock} from "test/price_oracle/PriceOracleMiddlewareMock.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
contract FluidInstadappStakingBalanceFuseTest is OlympixUnitTest("FluidInstadappStakingBalanceFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_balanceOf_WhenNoSubstrates_ReturnsZero_hitsLenEqualsZeroBranch() public {
            // given: ensure no substrates are configured for this MARKET_ID
            uint256 marketId = 999_999;
            bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(marketId);
            // sanity: opix expects the len == 0 branch, so substrates.length must be 0
            assertEq(substrates.length, 0, "expected no substrates for this marketId in test environment");
    
            FluidInstadappStakingBalanceFuse fuse = new FluidInstadappStakingBalanceFuse(marketId);
    
            // when
            uint256 balance = fuse.balanceOf();
    
            // then: should hit `if (len == 0)` true branch and return 0
            assertEq(balance, 0, "balance should be zero when there are no substrates configured");
        }
}