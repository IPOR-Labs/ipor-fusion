// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {TestAddresses} from "test/test_helpers/TestAddresses.sol";

/// @dev Target contract: contracts/fuses/compound_v3/CompoundV3BalanceFuse.sol

import {CompoundV3BalanceFuse} from "contracts/fuses/compound_v3/CompoundV3BalanceFuse.sol";

import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {IComet} from "contracts/fuses/compound_v3/ext/IComet.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
contract CompoundV3BalanceFuseTest is OlympixUnitTest("CompoundV3BalanceFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_balanceOf_NoSubstrates_ReturnsZero_HitsLenZeroBranch() public {
            // Arrange
            uint256 marketId = 1;
    
            // Deploy a minimal mock COMET using the test contract itself as address
            // by making this test contract conform to IComet via interface calls.
            // For constructor, we only need baseToken(), baseTokenPriceFeed(), decimals() on base token.
            // We mock these via vm.mockCall so no real logic is needed.
            address comet = address(this);
    
            // Mock COMET.baseToken() and COMET.baseTokenPriceFeed()
            vm.mockCall(comet, abi.encodeWithSelector(IComet.baseToken.selector), abi.encode(address(0xBEEF)));
            vm.mockCall(comet, abi.encodeWithSelector(IComet.baseTokenPriceFeed.selector), abi.encode(address(0xFEED)));
    
            // Mock ERC20(decimals) for base token used in constructor
            vm.mockCall(
                address(0xBEEF),
                abi.encodeWithSelector(bytes4(keccak256("decimals()"))),
                abi.encode(uint8(18))
            );
    
            // Deploy the fuse
            CompoundV3BalanceFuse fuse = new CompoundV3BalanceFuse(marketId, comet);
    
            // Ensure MARKET_ID mapping has no substrates: default mapping is empty
            // but to be explicit we overwrite it with an empty array
            PlasmaVaultStorageLib.MarketSubstratesStruct storage ms =
                PlasmaVaultStorageLib.getMarketSubstrates().value[marketId];
            bytes32[] memory empty = new bytes32[](0);
            ms.substrates = empty;
    
            // Act
            uint256 result = fuse.balanceOf();
    
            // Assert - len == 0 branch returns 0
            assertEq(result, 0, "balance should be zero when no substrates configured");
        }
}