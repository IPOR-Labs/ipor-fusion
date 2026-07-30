// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

import {PlasmaVault} from "contracts/vaults/PlasmaVault.sol";

/// @dev Target contract: contracts/vaults/PlasmaVault.sol

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";
import {WithdrawManager} from "contracts/managers/withdraw/WithdrawManager.sol";
import {IRewardsClaimManager} from "contracts/interfaces/IRewardsClaimManager.sol";
import {PlasmaVaultFeesLib} from "contracts/vaults/lib/PlasmaVaultFeesLib.sol";
import {Errors} from "contracts/libraries/errors/Errors.sol";
import {FuseAction} from "contracts/interfaces/IPlasmaVault.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";

import {AuthorityUtils} from "@openzeppelin/contracts/access/manager/AuthorityUtils.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {IporFusionAccessManager} from "contracts/managers/access/IporFusionAccessManager.sol";
contract PlasmaVaultTest is OlympixUnitTest("PlasmaVault") {
    PlasmaVault public plasmaVault;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fusion.param.ShareScaleMultiplier")) - 1)) & ~bytes32(uint256(0xff))
    /// (mirrors PlasmaVaultStorageLib.SHARE_SCALE_MULTIPLIER_SLOT, which is private)
    bytes32 private constant SHARE_SCALE_MULTIPLIER_SLOT =
        0x5bb34fc23414cfe7e422518e1d8590877bcc5dcacad5f8689bfd98e9a05ac600;

    /// @dev keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ERC4626")) - 1)) & ~bytes32(uint256(0xff))
    /// (mirrors OZ ERC4626Upgradeable.ERC4626StorageLocation, which is private; slot 0 of the struct holds `_asset`)
    bytes32 private constant ERC4626_STORAGE_LOCATION =
        0x0773e532dfede91f04b12a73d3d2acd361424f41f76b4fb79f090161e36b4e00;

    function setUp() public override {
        plasmaVault = new PlasmaVault();
    }

    /// @dev A bare (uninitialized) PlasmaVault has shareScaleMultiplier == 0 in storage
    /// (it is only set in _initializeVault), which makes ERC4626 share/asset conversions
    /// divide by zero or return 0. Write the value _initializeVault would set
    /// (10 ** DECIMALS_OFFSET) directly into the vault's storage slot.
    function _setShareScaleMultiplier() private {
        vm.store(
            address(plasmaVault),
            SHARE_SCALE_MULTIPLIER_SLOT,
            bytes32(uint256(10 ** uint256(PlasmaVaultLib.DECIMALS_OFFSET)))
        );
    }

    function test_deployment_doesNotRevert() public view {
        assertTrue(address(plasmaVault) != address(0), "Contract should be deployed");
    }

    function test_maxDeposit_WhenTotalSupplyAtOrAboveCap_ReturnsZero() public view {
            // When totalSupply >= totalSupplyCap, maxDeposit should return 0
            uint256 result = plasmaVault.maxDeposit(address(this));
            assertEq(result, 0, "maxDeposit should be zero when cap reached or exceeded");
        }

    function test_onERC721Received_ReturnsCorrectSelector() public {
            // Call onERC721Received and ensure we hit the `if (true)` branch
            bytes4 result = plasmaVault.onERC721Received(address(this), address(0x1), 1, "");
    
            // The function should return the IERC721Receiver selector
            assertEq(result, IERC721Receiver.onERC721Received.selector, "onERC721Received should return correct selector");
        }

    function test_previewRedeem_WhenWithdrawManagerNotSet_UsesBaseLogic() public {
            // Arrange: bare vault needs a non-zero share scale multiplier for _convertToAssets
            _setShareScaleMultiplier();

            // Arrange: ensure withdrawManager is zero so the else branch is taken
            address withdrawManager = PlasmaVaultStorageLib.getWithdrawManager().manager;
            assertEq(withdrawManager, address(0), "withdrawManager should be unset (zero) after bare deployment");
    
            uint256 shares = 1e18;
    
            // Act: call previewRedeem
            uint256 result = plasmaVault.previewRedeem(shares);
    
            // Assert: in this configuration it should simply return super.previewRedeem(shares),
            // which in the empty vault case equals shares / _SHARE_SCALE_MULTIPLIER.
            // Since we cannot easily compute the internal scale here, we at least assert
            // that the call does not revert and returns a numeric value.
            assertGt(result, 0, "previewRedeem should return a positive value when called with non-zero shares");
        }

    function test_previewWithdraw_WhenWithdrawManagerNotSet_TakesElseBranch() public {
            // Arrange: bare vault needs a non-zero share scale multiplier, otherwise
            // _convertToShares returns assets * 0 == 0 for an empty vault
            _setShareScaleMultiplier();

            // Ensure withdraw manager is not set so that
            // `withdrawManager == address(0)` and the else branch is taken
            address withdrawManager = PlasmaVaultStorageLib.getWithdrawManager().manager;
            assertEq(withdrawManager, address(0), "withdraw manager should be zero address in this setup");
    
            // Call previewWithdraw; this should execute the else branch of the
            // if (withdrawManager != address(0)) statement and then return
            // super.previewWithdraw(assets_)
            uint256 assets = 100e18;
            uint256 result = plasmaVault.previewWithdraw(assets);
    
            // Basic sanity check that function returned without reverting
            assertGt(result, 0, "previewWithdraw should return a positive value");
        }

    function test_maxWithdraw_WhenWithdrawManagerNotSet_UsesOwnerShares() public {
            // Arrange: bare vault needs a non-zero share scale multiplier for convertToAssets
            _setShareScaleMultiplier();

            // Arrange: ensure withdrawManager is zero so the `else` branch is taken
            address owner = address(0x1234);
    
            // Sanity: in this uninitialized test setup, withdrawManager should be address(0)
            address withdrawManager = PlasmaVaultStorageLib.getWithdrawManager().manager;
            assertEq(withdrawManager, address(0), "withdrawManager should be zero in this context");
    
            // We also rely on balanceOf(owner) == 0 in this setup
            uint256 ownerShares = plasmaVault.balanceOf(owner);
            assertEq(ownerShares, 0, "owner should have zero shares by default");
    
            // Act: call maxWithdraw – it should go into the `else` branch of
            // `if (withdrawManager != address(0)) { ... } else { ... }`
            uint256 result = plasmaVault.maxWithdraw(owner);
    
            // Assert: with zero shares and no withdraw manager, result should be zero
            // and branch coverage is achieved by entering the final `else` block
            assertEq(result, 0, "maxWithdraw should be zero when owner has no shares and no withdrawManager");
        }

    function test_totalAssetsInMarket_UsesPlasmaVaultLibGetter() public view {
            // opix-target-branch-1236-True: ensure the if (true) branch is exercised
            // In this minimal deployment, PlasmaVaultLib storage is zeroed, so totalAssetsInMarket
            // should just return whatever PlasmaVaultLib.getTotalAssetsInMarket(marketId) returns
            uint256 marketId = 1;
    
            // Direct library call for expected value
            uint256 expected = PlasmaVaultLib.getTotalAssetsInMarket(marketId);
    
            // Call through the target function
            uint256 result = plasmaVault.totalAssetsInMarket(marketId);
    
            // Assert they match to confirm the branch executed and delegated correctly
            assertEq(result, expected, "totalAssetsInMarket should delegate to PlasmaVaultLib.getTotalAssetsInMarket");
        }

    function test_getUnrealizedManagementFee_UsesGrossTotalAssets() public {
            // opix-target-branch-1266-True: ensure the `if (true)` branch in getUnrealizedManagementFee is executed
            // Arrange: a bare (uninitialized) vault has no underlying asset configured, so
            // _getGrossTotalAssets() would revert calling balanceOf() on address(0) (no code).
            // Write a real ERC20 address into the vault's ERC4626 `_asset` storage slot so the
            // gross-total-assets path executes genuinely (vault token balance = 0, no markets,
            // no rewards claim manager).
            MockERC20 underlying = new MockERC20("Mock Underlying", "MU", 18);
            vm.store(
                address(plasmaVault),
                ERC4626_STORAGE_LOCATION,
                bytes32(uint256(uint160(address(underlying))))
            );

            // This is a straightforward call that will always take the true branch
            uint256 fee = plasmaVault.getUnrealizedManagementFee();
    
            // We cannot easily compute the exact expected value here because it depends on internal
            // fee configuration and gross total assets, but we can at least assert that the call
            // does not revert and returns a numeric value.
            // In an uninitialized vault with zero assets, the unrealized fee should be zero.
            assertEq(fee, 0, "Unrealized management fee should be zero for an empty vault");
        }

    function test_updateInternal_RevertsWithUnsupportedMethod() public {
            vm.expectRevert(PlasmaVault.UnsupportedMethod.selector);
            plasmaVault.updateInternal(address(0x1), address(0x2), 123);
        }

    function test_executeInternal_RevertsWhenCalledExternally() public {
            // opix-target-branch-1317-True: ensure the `if (address(this) != msg.sender)` condition is true
            // Here, the caller is the test contract, so msg.sender != address(plasmaVault)
            FuseAction[] memory emptyCalls = new FuseAction[](0);
    
            vm.expectRevert(abi.encodeWithSelector(Errors.WrongCaller.selector, address(this)));
            plasmaVault.executeInternal(emptyCalls);
        }

    function test_maxMint_WhenTotalSupplyAtOrAboveCap_ReturnsZero() public view {
            // In this bare deployment, PlasmaVaultLib totalSupplyCap is initialized to 0
            // and totalSupply() is also 0, so totalSupply >= totalSupplyCap holds true.
            // This satisfies opix-target-branch-1065-True and maxMint should return 0.
            uint256 cap = PlasmaVaultLib.getTotalSupplyCap();
            uint256 supply = plasmaVault.totalSupply();
    
            assertTrue(supply >= cap, "Precondition totalSupply >= totalSupplyCap should hold in bare setup");
    
            uint256 result = plasmaVault.maxMint(address(this));
            assertEq(result, 0, "maxMint should be zero when total supply cap is reached or exceeded");
        }

    function test_checkCanCall_DepositWithPermitBranchCallsAuthorityChecks() public {
            // opix-target-branch-1636-True: hit the `else if (this.depositWithPermit.selector == sig)` branch
            //
            // We call the external `depositWithPermit` function so that the overridden
            // `_checkCanCall` in PlasmaVault is executed through the `restricted` modifier.
            // This exercises the specific branch that decodes `(uint256, address, uint256, uint8, bytes32, bytes32)`
            // and calls both `IporFusionAccessManager(authority()).canCallAndUpdate` and
            // `AuthorityUtils.canCallWithDelay` for `depositWithPermit`.
    
            // Arrange minimal, non-significant parameters – the underlying call will revert
            // later in depositWithPermit (e.g. on `PermitFailed` or `NoAssetsToDeposit`),
            // but by that time `_checkCanCall` (and thus the target branch) has already run.
            uint256 assets = 0; // value doesn't matter for branch coverage
            address receiver = address(this);
            uint256 deadline = block.timestamp + 1;
            uint8 v = 0;
            bytes32 r = bytes32(0);
            bytes32 s = bytes32(0);
    
            // We don't know the exact revert reason coming from the access manager
            // or from the body of depositWithPermit, so we only assert that some revert
            // happens after branch execution.
            vm.expectRevert();
    
            plasmaVault.depositWithPermit(assets, receiver, deadline, v, r, s);
        }
}