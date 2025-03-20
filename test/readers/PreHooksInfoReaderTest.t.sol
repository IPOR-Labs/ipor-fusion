// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PreHooksInfoReader, PreHookInfo} from "../../contracts/readers/PreHooksInfoReader.sol";

/**
 * @title Balance Fuses Reader Test
 * @notice Tests for reading balance fuses data from PlasmaVault
 * @dev Tests reading market IDs and fuse addresses from a specific PlasmaVault on Ethereum mainnet
 */
contract BalanceFusesReaderTest is Test {
    PreHooksInfoReader public reader;
    address public constant PLASMA_VAULT = 0xa121d23cECD8050082d13a1FC062598c5449dBE9;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_PROVIDER_URL"), 27849076);

        // Deploy BalanceFusesReader
        reader = new PreHooksInfoReader();
    }

    function test_getPreHooksInfo() public {
        PreHookInfo[] memory preHooksInfo = reader.getPreHooksInfo(PLASMA_VAULT);

        assertEq(preHooksInfo.length, 5);

        assertEq(preHooksInfo[0].selector, bytes4(0x6e553f65)); // deposit
        assertEq(preHooksInfo[0].implementation, 0x7f9179DC81cd0dBE6488eCD192cf37d2B9530F0C);
        assertEq(preHooksInfo[0].substrates.length, 1);
        assertEq(
            preHooksInfo[0].substrates[0],
            bytes32(0x000000000000000000000000000000000000000000000000000110d9316ec000)
        );

        assertEq(preHooksInfo[1].selector, bytes4(0x94bf804d)); // mint
        assertEq(preHooksInfo[1].implementation, 0x7f9179DC81cd0dBE6488eCD192cf37d2B9530F0C);
        assertEq(preHooksInfo[1].substrates.length, 1);
        assertEq(
            preHooksInfo[1].substrates[0],
            bytes32(0x000000000000000000000000000000000000000000000000000110d9316ec000)
        );

        assertEq(preHooksInfo[2].selector, bytes4(0xba087652)); // redeem
        assertEq(preHooksInfo[2].implementation, 0x7f9179DC81cd0dBE6488eCD192cf37d2B9530F0C);
        assertEq(preHooksInfo[2].substrates.length, 1);
        assertEq(
            preHooksInfo[2].substrates[0],
            bytes32(0x000000000000000000000000000000000000000000000000000110d9316ec000)
        );

        assertEq(preHooksInfo[3].selector, bytes4(0xb460af94)); // withdraw
        assertEq(preHooksInfo[3].implementation, 0x7f9179DC81cd0dBE6488eCD192cf37d2B9530F0C);
        assertEq(preHooksInfo[3].substrates.length, 1);
        assertEq(
            preHooksInfo[3].substrates[0],
            bytes32(0x000000000000000000000000000000000000000000000000000110d9316ec000)
        );

        assertEq(preHooksInfo[4].selector, bytes4(0x50921b23)); // depositWithPermit
        assertEq(preHooksInfo[4].implementation, 0x7f9179DC81cd0dBE6488eCD192cf37d2B9530F0C);
        assertEq(preHooksInfo[4].substrates.length, 1);
        assertEq(
            preHooksInfo[4].substrates[0],
            bytes32(0x000000000000000000000000000000000000000000000000000110d9316ec000)
        );
    }
}
