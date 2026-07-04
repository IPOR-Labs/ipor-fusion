// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {TestAddresses} from "test/test_helpers/TestAddresses.sol";

/// @dev Target contract: contracts/vaults/PlasmaVaultBase.sol

import {PlasmaVaultBase} from "contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";

contract PlasmaVaultBaseTest is OlympixUnitTest("PlasmaVaultBase") {
    PlasmaVaultBase public target;

    /// @dev keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ERC20Capped")) - 1)) & ~bytes32(uint256(0xff))
    /// (mirrors PlasmaVaultStorageLib.ERC20_CAPPED_STORAGE_LOCATION, which is private; slot 0 of the struct holds `cap`)
    bytes32 private constant ERC20_CAPPED_STORAGE_LOCATION =
        0x0f070392f17d5f958cc1ac31867dabecfc5c9758b4a419a200803226d7155d00;

    function setUp() public override {
        target = new PlasmaVaultBase();
    }

    function test_example_deployment_doesNotRevert() public view {
        assertTrue(address(target) != address(0));
    }

    function test_example_cap_returnsZeroBeforeInit() public view {
        // cap is stored in PlasmaVaultStorageLib; uninitialized contract returns 0
        assertEq(target.cap(), 0);
    }

    function test_updateInternal_mintAboveCap_revertsExceededCap() public {
            // total supply cap validation is enabled by default (ERC20CappedValidationFlag == 0
            // in the target's storage, and isTotalSupplyCapValidationEnabled() returns flag == 0)

            // set a low cap directly in the TARGET's storage so that any mint above it will exceed it
            // (calling PlasmaVaultStorageLib/PlasmaVaultLib from the test would only write the
            // test contract's own storage, not the target's)
            vm.store(address(target), ERC20_CAPPED_STORAGE_LOCATION, bytes32(uint256(1)));
            uint256 cap = target.cap();
            assertEq(cap, 1, "cap should be 1 in the target's storage");

            // simulate mint by calling updateInternal from zero address
            // from_ == address(0) triggers the cap-checking branch; after minting cap + 1 shares,
            // supply (cap + 1) > maxSupply (cap) so ERC20ExceededCap(cap + 1, cap) is thrown
            vm.expectRevert(abi.encodeWithSelector(PlasmaVaultBase.ERC20ExceededCap.selector, cap + 1, cap));
            target.updateInternal(address(0), address(this), cap + 1);
        }
    
}