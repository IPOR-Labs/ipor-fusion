// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/maintenance/UpdateWithdrawManagerMaintenanceFuse.sol

import {UpdateWithdrawManagerMaintenanceFuse, UpdateWithdrawManagerMaintenanceFuseEnterData} from "contracts/fuses/maintenance/UpdateWithdrawManagerMaintenanceFuse.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
contract UpdateWithdrawManagerMaintenanceFuseTest is OlympixUnitTest("UpdateWithdrawManagerMaintenanceFuse") {


    function test_enter_WhenNewManagerIsZero_DoesNotUpdateStorage() public {
            // given
            uint256 marketId = 1;
            UpdateWithdrawManagerMaintenanceFuse fuse = new UpdateWithdrawManagerMaintenanceFuse(marketId);

            // precondition: manager is zero
            assertEq(PlasmaVaultStorageLib.getWithdrawManager().manager, address(0));

            UpdateWithdrawManagerMaintenanceFuseEnterData memory data_ =
                UpdateWithdrawManagerMaintenanceFuseEnterData({newManager: address(0)});

            // when - call enter with newManager = address(0) to hit the True branch and early return
            fuse.enter(data_);

            // then - storage must remain unchanged (still zero address)
            assertEq(PlasmaVaultStorageLib.getWithdrawManager().manager, address(0));
        }

    function test_enter_WhenNewManagerIsNonZero_UpdatesStorage() public {
            // given
            uint256 marketId = 1;
            UpdateWithdrawManagerMaintenanceFuse fuse = new UpdateWithdrawManagerMaintenanceFuse(marketId);

            // Use PlasmaVaultMock so storage context is shared
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            address newManager = address(0x1234);
            UpdateWithdrawManagerMaintenanceFuseEnterData memory data_ =
                UpdateWithdrawManagerMaintenanceFuseEnterData({newManager: newManager});

            // when - call enter via vault delegatecall
            vault.execute(address(fuse), abi.encodeWithSelector(UpdateWithdrawManagerMaintenanceFuse.enter.selector, data_));

            // then - read manager back via vault delegatecall
            (bool success, bytes memory result) = address(vault).call(
                abi.encodeWithSelector(UpdateWithdrawManagerMaintenanceFuse.getWithdrawManager.selector)
            );
            assertTrue(success, "getWithdrawManager should succeed");
            address storedManager = abi.decode(result, (address));
            assertEq(storedManager, newManager);
        }

    function test_getWithdrawManager_ReturnsStoredManager() public {
            uint256 marketId = 1;
            UpdateWithdrawManagerMaintenanceFuse fuse = new UpdateWithdrawManagerMaintenanceFuse(marketId);

            // Use PlasmaVaultMock so storage context is shared
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            // Set manager via enter
            address manager = address(0xBEEF);
            UpdateWithdrawManagerMaintenanceFuseEnterData memory data_ =
                UpdateWithdrawManagerMaintenanceFuseEnterData({newManager: manager});
            vault.execute(address(fuse), abi.encodeWithSelector(UpdateWithdrawManagerMaintenanceFuse.enter.selector, data_));

            // when - read via vault's delegatecall
            (bool success, bytes memory result) = address(vault).call(
                abi.encodeWithSelector(UpdateWithdrawManagerMaintenanceFuse.getWithdrawManager.selector)
            );
            assertTrue(success, "getWithdrawManager should succeed");
            address storedManager = abi.decode(result, (address));

            // then
            assertEq(storedManager, manager);
        }
}
