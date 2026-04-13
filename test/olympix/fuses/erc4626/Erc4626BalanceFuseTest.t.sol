// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/erc4626/Erc4626BalanceFuse.sol

import {Erc4626BalanceFuse} from "contracts/fuses/erc4626/Erc4626BalanceFuse.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {MockERC4626} from "test/test_helpers/MockErc4626.sol";
import {MockPriceOracle} from "test/fuses/aave_v4/MockPriceOracle.sol";
contract Erc4626BalanceFuseTest is OlympixUnitTest("Erc4626BalanceFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_balanceOf_ReturnsZeroWhenNoSubstrates() public {
            // Deploy fuse with arbitrary marketId
            uint256 marketId = 1;
            Erc4626BalanceFuse fuse = new Erc4626BalanceFuse(marketId);
    
            // No substrates are configured for this marketId, so getMarketSubstrates(marketId) is empty
            // Also, price oracle middleware is zero address by default, but it won't be used
    
            uint256 balance = fuse.balanceOf();
    
            // Since len == 0, function should return 0 and hit the opix-target-branch-57-True path
            assertEq(balance, 0, "Balance should be zero when no ERC4626 substrates are configured");
        }
}