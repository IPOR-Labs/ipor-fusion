// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BalanceFusesReader} from "../../contracts/readers/BalanceFusesReader.sol";

/**
 * @title Balance Fuses Reader Test
 * @notice Tests for reading balance fuses data from PlasmaVault
 * @dev Tests reading market IDs and fuse addresses from a specific PlasmaVault on Ethereum mainnet
 */
contract BalanceFusesReaderTest is Test {
    BalanceFusesReader public reader;
    address public constant PLASMA_VAULT = 0xe9385eFf3F937FcB0f0085Da9A3F53D6C2B4fB5F;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 22072786);

        // Deploy BalanceFusesReader
        reader = new BalanceFusesReader();
    }

    function testGetBalanceFuseInfo() public {
        // Read balance fuses data from the PlasmaVault
        (uint256[] memory marketIds, address[] memory fuseAddresses) = reader.getBalanceFuseInfo(PLASMA_VAULT);

        assertEq(marketIds.length, 5, "Should have 5 markets");
        assertEq(fuseAddresses.length, 5, "Should have 5 fuse addresses");

        assertEq(marketIds[0], 19, "Market ID should be 19");
        assertEq(marketIds[1], 14, "Market ID should be 14");
        assertEq(marketIds[2], 7, "Market ID should be 7");
        assertEq(marketIds[3], 12, "Market ID should be 12");
        assertEq(marketIds[4], type(uint256).max, "Market ID should be max uint256");

        assertEq(
            fuseAddresses[0],
            0xB1B74e885349cd9D1F0efFb2E1ce0fB79959D7cf,
            "Fuse address should be 0xB1B74e885349cd9D1F0efFb2E1ce0fB79959D7cf"
        );
        assertEq(
            fuseAddresses[1],
            0x0aD1776B9319a03216A44AbA0242cC0Bc7e3CaC3,
            "Fuse address should be 0x0aD1776B9319a03216A44AbA0242cC0Bc7e3CaC3"
        );
        assertEq(
            fuseAddresses[2],
            0x6cEBf3e3392D0860Ed174402884b941DCBB30654,
            "Fuse address should be 0x6cEBf3e3392D0860Ed174402884b941DCBB30654"
        );
        assertEq(
            fuseAddresses[3],
            0xe9562d7bd06b43E6391C5bE4B3c5F5C2BC1E06Bf,
            "Fuse address should be 0xe9562d7bd06b43E6391C5bE4B3c5F5C2BC1E06Bf"
        );
        assertEq(
            fuseAddresses[4],
            0xbc2907d76964510a4232878e7aC6E2B18c474EFb,
            "Fuse address should be 0xbc2907d76964510a4232878e7aC6E2B18c474EFb"
        );
    }
}
