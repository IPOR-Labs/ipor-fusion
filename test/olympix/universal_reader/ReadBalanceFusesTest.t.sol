// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/universal_reader/ReadBalanceFuses.sol

import {ReadBalanceFuses} from "contracts/universal_reader/ReadBalanceFuses.sol";
import {FusesLibMock} from "test/connectorsLib/FusesLibMock.sol";
import {DustBalanceFuseMock} from "test/connectorsLib/DustBalanceFuseMock.sol";
import {IporFusionMarkets} from "contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
import {FusesLib} from "contracts/libraries/FusesLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
contract ReadBalanceFusesTest is OlympixUnitTest("ReadBalanceFuses") {


    function test_getBalance_UsesTrueBranchAndReturnsZeroWhenNoFuseSet() public {
        ReadBalanceFuses reader = new ReadBalanceFuses();

        // given: no balance fuse has been configured for this arbitrary marketId
        uint256 marketId = 123456;

        // when: calling getBalanceFuse hits the `if (true)` branch and reads from empty mapping
        address fuseAddr = reader.getBalanceFuse(marketId);

        // then: mapping default is zero address
        assertEq(fuseAddr, address(0), "expected zero address when no balance fuse configured");
    }

    function test_getBalanceFusesForActiveFuses_EntersElseBranchWhenMarketsExist() public {
            // Use PlasmaVaultMock as shared storage context
            ReadBalanceFuses reader = new ReadBalanceFuses();
            PlasmaVaultMock vault = new PlasmaVaultMock(address(reader), address(0));

            // Deploy a balance fuse mock
            DustBalanceFuseMock fuse = new DustBalanceFuseMock(IporFusionMarkets.MOONWELL, 18);

            // Set up storage in vault's context
            // Set underlying decimals
            vault.execute(address(new FusesLibMock()), abi.encodeWithSignature("setUnderlyingDecimals(uint8)", uint8(18)));

            // Add fuse
            address[] memory fuses = new address[](1);
            fuses[0] = address(fuse);
            vault.addFuses(fuses);

            // Add balance fuse for MOONWELL market
            vault.execute(address(new FusesLibMock()), abi.encodeWithSignature("addBalanceFuse(uint256,address)", IporFusionMarkets.MOONWELL, address(fuse)));

            // Call getBalanceFusesForActiveFuses via vault
            (bool success, bytes memory result) = address(vault).staticcall(
                abi.encodeWithSelector(ReadBalanceFuses.getBalanceFusesForActiveFuses.selector)
            );
            assertTrue(success, "call should succeed");
            address[] memory addrs = abi.decode(result, (address[]));

            assertGt(addrs.length, 0, "should return at least one balance fuse address");
        }

    function test_getAllBalanceMarketIdsForActiveFuses_DeduplicatesMarketIds() public {
            // Use PlasmaVaultMock as shared storage context
            ReadBalanceFuses reader = new ReadBalanceFuses();
            PlasmaVaultMock vault = new PlasmaVaultMock(address(reader), address(0));

            // Deploy two balance fuse mocks with the SAME marketId
            DustBalanceFuseMock fuse1 = new DustBalanceFuseMock(IporFusionMarkets.MOONWELL, 18);
            DustBalanceFuseMock fuse2 = new DustBalanceFuseMock(IporFusionMarkets.MOONWELL, 18);

            // Set underlying decimals
            vault.execute(address(new FusesLibMock()), abi.encodeWithSignature("setUnderlyingDecimals(uint8)", uint8(18)));

            // Register both fuses
            address[] memory fuses = new address[](2);
            fuses[0] = address(fuse1);
            fuses[1] = address(fuse2);
            vault.addFuses(fuses);

            // Call getAllBalanceMarketIdsForActiveFuses via vault
            (bool success, bytes memory result) = address(vault).staticcall(
                abi.encodeWithSelector(ReadBalanceFuses.getAllBalanceMarketIdsForActiveFuses.selector)
            );
            assertTrue(success, "call should succeed");
            uint256[] memory markets = abi.decode(result, (uint256[]));

            // Expect exactly 2 unique market ids: MOONWELL and ERC20_VAULT_BALANCE
            assertEq(markets.length, 2, "should contain exactly 2 unique marketIds");
        }
}
