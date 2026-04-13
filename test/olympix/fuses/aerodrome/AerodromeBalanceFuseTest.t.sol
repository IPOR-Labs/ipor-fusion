// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/aerodrome/AerodromeBalanceFuse.sol

import {AerodromeBalanceFuse} from "contracts/fuses/aerodrome/AerodromeBalanceFuse.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {AerodromeSubstrateLib, AerodromeSubstrate, AerodromeSubstrateType} from "contracts/fuses/aerodrome/AreodromeLib.sol";
import {PriceOracleMiddlewareMock} from "test/price_oracle/PriceOracleMiddlewareMock.sol";
import {IPool} from "contracts/fuses/aerodrome/ext/IPool.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
contract AerodromeBalanceFuseTest is OlympixUnitTest("AerodromeBalanceFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_balanceOf_WhenNoSubstrates_ReturnsZero() public {
            // Arrange
            uint256 marketId = 1;
    
            // configure empty substrates array for this market
            bytes32[] memory empty = new bytes32[](0);
            PlasmaVaultConfigLib.grantMarketSubstrates(marketId, empty);
    
            // sanity: storage really has length 0 to hit `len == 0` branch
            bytes32[] memory stored = PlasmaVaultConfigLib.getMarketSubstrates(marketId);
            assertEq(stored.length, 0, "substrates length should be zero");
    
            // deploy a dummy price oracle and set it in PlasmaVaultLib storage
            PriceOracleMiddlewareMock oracle = new PriceOracleMiddlewareMock(address(0), 18, address(0));
            PlasmaVaultStorageLib.getPriceOracleMiddleware().value = address(oracle);
    
            // deploy fuse with given marketId
            AerodromeBalanceFuse fuse = new AerodromeBalanceFuse(marketId);
    
            // Act
            uint256 balance = fuse.balanceOf();
    
            // Assert
            assertEq(balance, 0, "balance should be zero when no substrates configured");
        }
}