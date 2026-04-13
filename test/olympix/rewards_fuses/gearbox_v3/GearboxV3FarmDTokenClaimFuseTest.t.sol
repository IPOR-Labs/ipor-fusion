// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/rewards_fuses/gearbox_v3/GearboxV3FarmDTokenClaimFuse.sol

import {GearboxV3FarmDTokenClaimFuse} from "contracts/rewards_fuses/gearbox_v3/GearboxV3FarmDTokenClaimFuse.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";
import {IFarmingPool} from "contracts/fuses/gearbox_v3/ext/IFarmingPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
contract GearboxV3FarmDTokenClaimFuseTest is OlympixUnitTest("GearboxV3FarmDTokenClaimFuse") {


    function test_claim_RevertsWhenRewardsClaimManagerZeroAndHasSubstrates() public {
            // Arrange: set up a fuse with a non-empty substrates array
            uint256 marketId = 1;
            GearboxV3FarmDTokenClaimFuse fuse = new GearboxV3FarmDTokenClaimFuse(marketId);

            // Use PlasmaVaultMock so storage context is shared
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            // configure a single non-zero substrate in vault's storage
            address[] memory assets = new address[](1);
            assets[0] = address(0x1234);
            vault.grantAssetsToMarket(marketId, assets);

            // ensure rewardsClaimManager is zero (default in vault's storage)

            // Expect the custom revert from the fuse
            vm.expectRevert(abi.encodeWithSelector(GearboxV3FarmDTokenClaimFuse.GearboxV3FarmDTokenClaimFuseRewardsClaimManagerZeroAddress.selector, address(fuse)));

            // Act via vault
            vault.execute(address(fuse), abi.encodeWithSignature("claim()"));
        }
}
