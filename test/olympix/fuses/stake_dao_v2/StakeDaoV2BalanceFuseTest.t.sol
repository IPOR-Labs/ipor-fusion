// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/stake_dao_v2/StakeDaoV2BalanceFuse.sol

import {StakeDaoV2BalanceFuse} from "contracts/fuses/stake_dao_v2/StakeDaoV2BalanceFuse.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {IporMath} from "contracts/libraries/math/IporMath.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {MockERC4626} from "test/test_helpers/MockErc4626.sol";
import {MockPriceOracle} from "test/fuses/aave_v4/MockPriceOracle.sol";
contract StakeDaoV2BalanceFuseTest is OlympixUnitTest("StakeDaoV2BalanceFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_balanceOf_returnsZeroWhenNoSubstratesConfigured() public {
            // Deploy fuse with arbitrary marketId
            uint256 marketId = 1;
            StakeDaoV2BalanceFuse fuse = new StakeDaoV2BalanceFuse(marketId);
    
            // Configure PlasmaVaultLib / PlasmaVaultStorageLib context on this test contract
            // 1) Set underlying token decimals used by FusesLib/IporMath paths (not strictly needed here but safe)
            PlasmaVaultStorageLib.getERC4626Storage().underlyingDecimals = 18;
    
            // 2) Set a price oracle middleware address (required by PlasmaVaultLib.getPriceOracleMiddleware in balanceOf)
            //    Use MockPriceOracle which satisfies IPriceOracleMiddleware
            MockPriceOracle priceOracle = new MockPriceOracle();
            PlasmaVaultLib.setPriceOracleMiddleware(address(priceOracle));
    
            // NOTE: We intentionally do NOT configure any market substrates for this MARKET_ID,
            // so PlasmaVaultConfigLib.getMarketSubstrates(marketId) will return an empty array.
    
            // When: calling balanceOf via delegatecall into the fuse, so that
            // `address(this)` is treated as the PlasmaVault storage context
            (bool success, bytes memory data) = address(fuse).staticcall(abi.encodeWithSelector(fuse.balanceOf.selector));
            require(success, "balanceOf call failed");
            uint256 balance = abi.decode(data, (uint256));
    
            // Then: since len == 0, the opix-target-branch-39-True path is taken and function returns 0
            assertEq(balance, 0, "Expected zero balance when no substrates are configured");
        }
}