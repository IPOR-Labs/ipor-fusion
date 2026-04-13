// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/rewards_fuses/stake_dao_v2/StakeDaoV2ClaimFuse.sol

import {StakeDaoV2ClaimFuse} from "contracts/rewards_fuses/stake_dao_v2/StakeDaoV2ClaimFuse.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {MockRewardVault} from "test/fuses/stake_dao_v2/mocks/MockRewardVault.sol";
import {MockAccountant} from "test/fuses/stake_dao_v2/mocks/MockAccountant.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
contract StakeDaoV2ClaimFuseTest is OlympixUnitTest("StakeDaoV2ClaimFuse") {

    // Helper function for delegatecall to set rewards claim manager
    function setRewardsClaimManager(address manager_) external {
        PlasmaVaultLib.setRewardsClaimManagerAddress(manager_);
    }


    function test_claimExtraRewards_RevertsWhenVaultNotGranted() public {
            uint256 marketId = 1;
            StakeDaoV2ClaimFuse fuse = new StakeDaoV2ClaimFuse(marketId);

            // Use PlasmaVaultMock so storage context is shared
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            // Set rewards claim manager in vault's storage so _getReceiver succeeds
            address rewardsManager = address(0xABC1);
            vault.execute(address(this), abi.encodeWithSelector(this.setRewardsClaimManager.selector, rewardsManager));

            // Prepare a reward vault address that is NOT granted in PlasmaVaultConfigLib
            address[] memory vaults = new address[](1);
            vaults[0] = address(0xDEAD);

            // Prepare matching tokens array
            address[][] memory vaultTokens = new address[][](1);
            vaultTokens[0] = new address[](0);

            // Expect revert from _validateRewardVaults
            vm.expectRevert(abi.encodeWithSelector(
                StakeDaoV2ClaimFuse.StakeDaoV2ClaimFuseRewardVaultNotGranted.selector,
                vaults[0]
            ));

            // Act via vault
            vault.execute(address(fuse), abi.encodeWithSelector(StakeDaoV2ClaimFuse.claimExtraRewards.selector, vaults, vaultTokens));
        }

    function test_getReceiver_RevertsWhenRewardsClaimManagerNotSet() public {
            // Deploy fuse with arbitrary marketId
            StakeDaoV2ClaimFuse fuse = new StakeDaoV2ClaimFuse(1);
    
            // Ensure rewards claim manager address is zero in PlasmaVault storage context
            // (this is the default for a fresh test contract using the library storage)
            assertEq(PlasmaVaultLib.getRewardsClaimManagerAddress(), address(0));
    
            // Expect revert from the public function that uses _getReceiver
            vm.expectRevert(StakeDaoV2ClaimFuse.StakeDaoV2ClaimFuseRewardsClaimManagerNotSet.selector);
            address[] memory emptyVaults = new address[](0);
            fuse.claimMainRewards(emptyVaults);
        }
}