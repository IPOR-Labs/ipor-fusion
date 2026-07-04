// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

/// @dev Target contract: contracts/managers/rewards/RewardsClaimManager.sol

import {RewardsClaimManager} from "contracts/managers/rewards/RewardsClaimManager.sol";

/// @dev Minimal stub exposing `asset()` — RewardsClaimManager constructor calls
/// `PlasmaVault(plasmaVault_).asset()` so we just need any contract returning a token address.

import {FusesLib} from "contracts/libraries/FusesLib.sol";
import {FuseAction} from "contracts/vaults/PlasmaVault.sol";
contract _MockPlasmaVault {
    address public assetAddr;
    constructor(address asset_) { assetAddr = asset_; }
    function asset() external view returns (address) { return assetAddr; }
}

contract RewardsClaimManagerTest is OlympixUnitTest("RewardsClaimManager") {
    RewardsClaimManager public target;
    MockERC20 public underlying;
    _MockPlasmaVault public vault;
    address public constant AUTHORITY = address(0x1);

    function setUp() public override {
        underlying = new MockERC20("Under", "U", 18);
        vault = new _MockPlasmaVault(address(underlying));
        target = new RewardsClaimManager(AUTHORITY, address(vault));
    }

    function test_example_deployment_doesNotRevert() public view {
        assertTrue(address(target) != address(0));
    }

    function test_example_UNDERLYING_TOKEN_returnsMockAsset() public view {
        assertEq(target.UNDERLYING_TOKEN(), address(underlying));
    }

    function test_example_PLASMA_VAULT_returnsMockVault() public view {
        assertEq(target.PLASMA_VAULT(), address(vault));
    }

    function test_example_balanceOfStartsAtZero() public view {
        assertEq(target.balanceOf(), 0);
    }

    function test_example_isRewardFuseSupportedDefaultsFalse() public view {
        assertFalse(target.isRewardFuseSupported(address(0xBEEF)));
    }

    function test_example_getRewardsFusesEmpty() public view {
        assertEq(target.getRewardsFuses().length, 0);
    }

    function test_example_getVestingDataInitial() public view {
        // Storage uninitialized → struct fields default to zero
        target.getVestingData();
    }

    function test_example_addRewardFusesByAuthority() public {
        // Mock authority to allow caller (AUTHORITY is precompile 0x1 — vm.etch is forbidden on
        // precompiles, but vm.mockCall alone works, same as in the other tests of this file)
        vm.mockCall(AUTHORITY, abi.encodeWithSelector(IAccessManager.canCall.selector), abi.encode(true, uint32(0)));

        address[] memory fuses = new address[](1);
        fuses[0] = address(0xCAFE);
        target.addRewardFuses(fuses);
        assertTrue(target.isRewardFuseSupported(address(0xCAFE)));
        assertEq(target.getRewardsFuses().length, 1);
    }

    function test_example_transferRevertsForUnauthorized() public {
        vm.expectRevert();
        target.transfer(address(underlying), address(0xBEEF), 1);
    }

    function test_transfer_RevertWhenUnderlyingToken_WithNonPrecompileAuthority() public {
            // Use a non-precompile address as AUTHORITY by recreating the contract locally
            address nonPrecompileAuthority = address(0x1234);
            vm.etch(nonPrecompileAuthority, hex"60006000");
            vm.mockCall(
                nonPrecompileAuthority,
                abi.encodeWithSelector(IAccessManager.canCall.selector),
                abi.encode(true, uint32(0))
            );
    
            // Deploy a new RewardsClaimManager using the non-precompile authority
            RewardsClaimManager localTarget = new RewardsClaimManager(nonPrecompileAuthority, address(vault));
    
            vm.expectRevert(RewardsClaimManager.UnableToTransferUnderlyingToken.selector);
            localTarget.transfer(address(underlying), address(0xBEEF), 1 ether);
        }

    function test_claimRewards_RevertsWhenFuseUnsupported_andHitsIfBranch() public {
            // Arrange: mock the existing AUTHORITY (precompile 0x1) to always allow this call
            vm.mockCall(
                AUTHORITY,
                abi.encodeWithSelector(IAccessManager.canCall.selector),
                abi.encode(true, uint32(0))
            );
    
            // Prepare a FuseAction array with an UNSUPPORTED fuse so the `if (!FusesLib.isFuseSupported(...))` is true
            FuseAction[] memory calls = new FuseAction[](1);
            calls[0] = FuseAction({fuse: address(0xDEAD), data: bytes("")});
    
            // Expect the custom error from FusesLib when branch is taken
            vm.expectRevert(
                abi.encodeWithSelector(FusesLib.FuseUnsupported.selector, address(0xDEAD))
            );
    
            // Act: should enter the opix-target-branch-161-True branch and revert
            target.claimRewards(calls);
        }

    function test_claimRewards_AllFusesSupported_hitsElseBranchOnFuseCheck() public {
            // Arrange: mock authority so restricted modifier passes
            vm.mockCall(
                AUTHORITY,
                abi.encodeWithSelector(IAccessManager.canCall.selector),
                abi.encode(true, uint32(0))
            );
    
            // Add a supported fuse so FusesLib.isFuseSupported returns true
            address[] memory fuses = new address[](1);
            fuses[0] = address(0xCAFE);
            target.addRewardFuses(fuses);
    
            // Prepare a FuseAction array where each fuse is supported → enter else branch
            FuseAction[] memory calls = new FuseAction[](1);
            calls[0] = FuseAction({fuse: address(0xCAFE), data: bytes("")});
    
            // Mock PlasmaVault.claimRewards to avoid external dependency
            vm.mockCall(
                address(vault),
                abi.encodeWithSelector(bytes4(keccak256("claimRewards((address,bytes)[])"))),
                ""
            );
    
            // Act: since fuse is supported, branch `!FusesLib.isFuseSupported` is false and we hit the else branch
            target.claimRewards(calls);
        }

    function test_transferVestedTokensToVault_balanceZero_hitsEarlyReturnBranch() public {
            // Arrange: mock authority (cannot etch precompile 0x1, so use a non-precompile address)
            address fakeAuthority = address(0x1234);
            // Point the contract's authority storage to fakeAuthority directly
            // AccessManagedUpgradeable._setAuthority is internal, but constructor already set AUTHORITY (0x1).
            // We cannot change it, so instead mock the existing AUTHORITY to always allow this call.
    
            vm.mockCall(
                AUTHORITY,
                abi.encodeWithSelector(IAccessManager.canCall.selector),
                abi.encode(true, uint32(0))
            );
    
            // Act: call function when balanceOf() is zero (initial state)
            target.transferVestedTokensToVault();
    
            // Assert: no tokens transferred to vault, event not strictly checked here
            assertEq(underlying.balanceOf(address(vault)), 0);
        }
}