// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/compound_v2/CompoundV2BalanceFuse.sol

import {CompoundV2BalanceFuse} from "contracts/fuses/compound_v2/CompoundV2BalanceFuse.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";
import {PriceOracleMiddlewareMock} from "test/price_oracle/PriceOracleMiddlewareMock.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {CErc20} from "contracts/fuses/compound_v2/ext/CErc20.sol";
contract CompoundV2BalanceFuseTest is OlympixUnitTest("CompoundV2BalanceFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_balanceOf_ReturnsZeroWhenNoSubstrates() public {
            // Deploy fuse with a MARKET_ID that has no configured substrates in the Olympix test environment
            CompoundV2BalanceFuse fuse = new CompoundV2BalanceFuse(999_999);
    
            uint256 balance = fuse.balanceOf();
            assertEq(balance, 0, "Balance should be zero when no substrates are configured");
        }
}