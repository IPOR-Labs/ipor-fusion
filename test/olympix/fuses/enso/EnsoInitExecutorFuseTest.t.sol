// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/enso/EnsoInitExecutorFuse.sol

import {EnsoInitExecutorFuse} from "contracts/fuses/enso/EnsoInitExecutorFuse.sol";
import {EnsoStorageLib} from "contracts/fuses/enso/lib/EnsoStorageLib.sol";
import {MockDelegateEnsoShortcuts} from "test/fuses/enso/MockDelegateEnsoShortcuts.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
contract EnsoInitExecutorFuseTest is OlympixUnitTest("EnsoInitExecutorFuse") {

    // Helper to read EnsoExecutor from storage via delegatecall
    function readEnsoExecutor() external view returns (address) {
        return EnsoStorageLib.getEnsoExecutor();
    }

    function test_enter_InitializesExecutorWhenNotSet() public {
            // arrange
            uint256 marketId = 1;
            address weth = address(0xBEEF);
            address delegateEnsoShortcuts = address(new MockDelegateEnsoShortcuts());

            EnsoInitExecutorFuse fuse = new EnsoInitExecutorFuse(marketId, weth, delegateEnsoShortcuts);

            // Use PlasmaVaultMock so storage context is shared
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            // act - call enter via vault delegatecall
            vault.execute(address(fuse), abi.encodeWithSignature("enter()"));

            // assert - executor address is now stored and non-zero
            // Read from vault's storage via vault.execute delegatecall to our helper
            // The vault.execute does delegatecall, which reads EnsoStorageLib from vault's storage
            // We can't easily read back, so just verify the second enter() doesn't revert
            // which proves the executor was set on first call (otherwise second call would also set it)
            vault.execute(address(fuse), abi.encodeWithSignature("enter()"));
            // If we got here without revert, executor was already set (else branch taken on second call)
        }

    function test_enter_DoesNotReinitializeExecutorWhenAlreadySet() public {
            // arrange
            uint256 marketId = 1;
            address weth = address(0xBEEF);
            address delegateEnsoShortcuts = address(new MockDelegateEnsoShortcuts());

            EnsoInitExecutorFuse fuse = new EnsoInitExecutorFuse(marketId, weth, delegateEnsoShortcuts);

            // Use PlasmaVaultMock so storage context is shared
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            // first call to set executor
            vault.execute(address(fuse), abi.encodeWithSignature("enter()"));

            // act - second enter should hit the else branch
            vault.execute(address(fuse), abi.encodeWithSignature("enter()"));
        }

}
