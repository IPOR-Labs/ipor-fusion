// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/aave_v2/AaveV2BalanceFuse.sol

import {AaveV2BalanceFuse} from "contracts/fuses/aave_v2/AaveV2BalanceFuse.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {PriceOracleMiddlewareMock} from "test/price_oracle/PriceOracleMiddlewareMock.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
import {DustBalanceFuseMock} from "test/connectorsLib/DustBalanceFuseMock.sol";
import {FusesLibMock} from "test/connectorsLib/FusesLibMock.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
contract AaveV2BalanceFuseTest is OlympixUnitTest("AaveV2BalanceFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_balanceOf_WhenNoSubstrates_ReturnsZero() public {
            // given: configure market with no substrates for MARKET_ID = 1
            uint256 marketId = 1;
    
            // Ensure storage for this market is empty
            PlasmaVaultStorageLib.MarketSubstratesStruct storage marketSubstrates =
                PlasmaVaultStorageLib.getMarketSubstrates().value[marketId];
            // Clear any existing substrates if present
            uint256 length = marketSubstrates.substrates.length;
            for (uint256 i = 0; i < length; ++i) {
                marketSubstrates.substrateAllowances[marketSubstrates.substrates[i]] = 0;
            }
            marketSubstrates.substrates = new bytes32[](0);
    
            AaveV2BalanceFuse fuse = new AaveV2BalanceFuse(marketId);
    
            // when
            uint256 balance = fuse.balanceOf();
    
            // then: should hit the `len == 0` branch and return 0
            assertEq(balance, 0, "Balance should be zero when no substrates configured");
        }
}