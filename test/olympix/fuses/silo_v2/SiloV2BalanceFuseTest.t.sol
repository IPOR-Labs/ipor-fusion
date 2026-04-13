// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/silo_v2/SiloV2BalanceFuse.sol

import {SiloV2BalanceFuse} from "contracts/fuses/silo_v2/SiloV2BalanceFuse.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";
import {PriceOracleMiddlewareMock} from "test/price_oracle/PriceOracleMiddlewareMock.sol";
import {ISiloConfig} from "contracts/fuses/silo_v2/ext/ISiloConfig.sol";
import {ISilo} from "contracts/fuses/silo_v2/ext/ISilo.sol";
import {IShareToken} from "contracts/fuses/silo_v2/ext/IShareToken.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
contract SiloV2BalanceFuseTest is OlympixUnitTest("SiloV2BalanceFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_balanceOf_ReturnsZeroWhenNoSubstrates_branch37True() public {
            uint256 marketId = 999_999; // use an ID that has no substrates configured in test env
            SiloV2BalanceFuse fuse = new SiloV2BalanceFuse(marketId);
    
            // Precondition: no substrates for this market so len == 0
            bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(marketId);
            assertEq(substrates.length, 0, "substrates should be empty for this marketId");
    
            uint256 balance = fuse.balanceOf();
    
            assertEq(balance, 0, "balanceOf should return 0 when there are no substrates (len == 0 branch)");
        }
}