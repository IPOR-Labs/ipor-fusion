// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/moonwell/MoonwellBalanceFuse.sol

import {MoonwellBalanceFuse} from "contracts/fuses/moonwell/MoonwellBalanceFuse.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {PriceOracleMiddlewareMock} from "test/price_oracle/PriceOracleMiddlewareMock.sol";
import {MErc20} from "contracts/fuses/moonwell/ext/MErc20.sol";
contract MoonwellBalanceFuseTest is OlympixUnitTest("MoonwellBalanceFuse") {


    function test_calculateBalance_EmptySubstratesReturnsZero() public {
            // Arrange: create fuse with arbitrary marketId
            uint256 marketId = 1;
            MoonwellBalanceFuse fuse = new MoonwellBalanceFuse(marketId);
    
            // Prepare empty substrates array to hit `substrates_.length == 0` branch
            bytes32[] memory emptySubstrates = new bytes32[](0);
    
            // Act: call external balanceOf overload with empty substrates so it directly
            // calls _calculateBalance(emptySubstrates, plasmaVault_)
            uint256 balance = fuse.balanceOf(emptySubstrates, address(this));
    
            // Assert: balance should be zero
            assertEq(balance, 0, "Balance for empty substrates should be zero");
        }

    function test_balanceOf_UsesElseBranchWhenSubstratesNonEmpty() public {
            // Arrange
            uint256 marketId = 1;
            MoonwellBalanceFuse fuse = new MoonwellBalanceFuse(marketId);

            // create a dummy non-zero mToken address and mock its MErc20 calls
            address dummyMToken = address(0x1234);
            address dummyUnderlying = address(0x5678);
            bytes32[] memory substrates = new bytes32[](1);
            substrates[0] = PlasmaVaultConfigLib.addressToBytes32(dummyMToken);

            // Mock MErc20 calls so the loop doesn't revert
            vm.mockCall(dummyMToken, abi.encodeWithSelector(MErc20.underlying.selector), abi.encode(dummyUnderlying));
            vm.mockCall(dummyMToken, abi.encodeWithSelector(MErc20.balanceOfUnderlying.selector, address(this)), abi.encode(uint256(0)));
            vm.mockCall(dummyMToken, abi.encodeWithSelector(MErc20.borrowBalanceStored.selector, address(this)), abi.encode(uint256(0)));
            // Mock underlying decimals
            vm.mockCall(dummyUnderlying, abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));
            // Mock price oracle middleware (PlasmaVaultLib.getPriceOracleMiddleware() returns address(0) by default)
            // We need to mock the getAssetPrice call at any address since the middleware is at address(0)
            vm.mockCall(address(0), abi.encodeWithSignature("getAssetPrice(address)", dummyUnderlying), abi.encode(uint256(1e8), uint256(8)));

            // Act: call the external overload, which will hit the `substrates_.length == 0` condition as false
            uint256 balance = fuse.balanceOf(substrates, address(this));

            // Assert: we only care that call succeeds and branch is executed
            assertEq(balance, 0, "balance should be zero with no underlying");
        }
}