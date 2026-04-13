// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/euler/EulerV2BatchFuse.sol

import {EulerV2BatchFuse, EulerV2BatchFuseData, EulerV2BatchItem} from "contracts/fuses/euler/EulerV2BatchFuse.sol";
import {IEVC} from "ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";
import {EulerFuseLib} from "contracts/fuses/euler/EulerFuseLib.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {IFuseCommon} from "contracts/fuses/IFuseCommon.sol";
import {IBorrowing} from "contracts/fuses/euler/ext/IBorrowing.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {IVault} from "ethereum-vault-connector/src/interfaces/IVault.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
contract EulerV2BatchFuseTest is OlympixUnitTest("EulerV2BatchFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_validate_RevertOnEmptyBatchItems() public {
            // Arrange: deploy fuse with a dummy EVC address (zero is fine for this test)
            uint256 marketId = 1;
            EulerV2BatchFuse fuse = new EulerV2BatchFuse(marketId, address(0));
    
            // Prepare data with empty batchItems to trigger the EmptyBatchItems branch
            EulerV2BatchFuseData memory data_;
            data_.batchItems = new EulerV2BatchItem[](0);
            data_.assetsForApprovals = new address[](0);
            data_.eulerVaultsForApprovals = new address[](0);
    
            // Expect revert with the custom error
            vm.expectRevert(EulerV2BatchFuse.EmptyBatchItems.selector);
            fuse.enter(data_);
        }

    function test_validatePlasmaVaultCallback_elseBranch_and_enter_revertsOnUnsupportedOperation() public {
            // Deploy mocks and fuse
            MockERC20 underlying = new MockERC20("Token", "TKN", 18);
            IEVC evc = IEVC(address(0x1234));
            EulerV2BatchFuse fuse = new EulerV2BatchFuse(1, address(evc));
    
            // Prepare a batch item that targets the PlasmaVault address (here we just use the fuse address)
            // and uses a selector that is NOT CallbackHandlerEuler.onEulerFlashLoan
            EulerV2BatchItem[] memory items = new EulerV2BatchItem[](1);
            items[0] = EulerV2BatchItem({
                targetContract: address(fuse),
                onBehalfOfAccount: 0x01,
                data: abi.encodeWithSelector(bytes4(0xdeadbeef))
            });
    
            address[] memory assets = new address[](0);
            address[] memory vaults = new address[](0);
    
            EulerV2BatchFuseData memory data_ = EulerV2BatchFuseData({
                batchItems: items,
                assetsForApprovals: assets,
                eulerVaultsForApprovals: vaults
            });
    
            // When calling enter, validation will reach _validatePlasmaVaultCallback,
            // take the else branch (since selector != onEulerFlashLoan), then revert with UnsupportedOperation
            vm.expectRevert(EulerV2BatchFuse.UnsupportedOperation.selector);
            fuse.enter(data_);
        }
}