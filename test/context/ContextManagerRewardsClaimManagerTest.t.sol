// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ContextManagerInitSetup} from "./ContextManagerInitSetup.sol";
import {TestAddresses} from "../test_helpers/TestAddresses.sol";
import {ExecuteData} from "../../contracts/managers/context/ContextManager.sol";
import {IERC20} from "../../lib/forge-std/src/interfaces/IERC20.sol";
import {FuseAction} from "../../contracts/vaults/PlasmaVault.sol";
import {MoonwellClaimFuse} from "../../contracts/rewards_fuses/moonwell/MoonwellClaimFuse.sol";
import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {MoonwellClaimFuseData} from "../../contracts/rewards_fuses/moonwell/MoonwellClaimFuse.sol";
import {MoonwellSupplyFuseEnterData} from "../../contracts/fuses/moonwell/MoonwellSupplyFuse.sol";

contract ContextManagerRewardsClaimManagerTest is Test, ContextManagerInitSetup {
    // Test events
    event ContextCall(address indexed target, bytes data, bytes result);
    address internal immutable _USER_2 = makeAddr("USER2");

    address[] private _addresses;
    bytes[] private _data;

    MoonwellClaimFuse internal _claimFuse;

    function setUp() public {
        initSetup();
        deal(_UNDERLYING_TOKEN, _USER_2, 100e18); // Note: wstETH uses 18 decimals
        vm.startPrank(_USER_2);
        IERC20(_UNDERLYING_TOKEN).approve(address(_plasmaVault), 100e18);
        vm.stopPrank();

        address[] memory addresses = new address[](1);
        addresses[0] = address(_rewardsClaimManager);

        vm.startPrank(TestAddresses.ATOMIST);
        _contextManager.addApprovedAddresses(addresses);
        vm.stopPrank();

        // Deploy MoonwellClaimFuse
        _claimFuse = new MoonwellClaimFuse(IporFusionMarkets.MOONWELL, TestAddresses.BASE_MOONWELL_COMPTROLLER);
    }

    function testAddRewardFuses() public {
        // Prepare data for adding reward fuses
        address[] memory fuses = new address[](1);
        fuses[0] = address(_claimFuse);

        bytes memory addRewardFusesData = abi.encodeWithSignature("addRewardFuses(address[])", fuses);

        // Prepare context data
        address[] memory targets = new address[](1);
        targets[0] = address(_rewardsClaimManager);

        bytes[] memory data = new bytes[](1);
        data[0] = addRewardFusesData;

        // Execute through context manager
        vm.prank(TestAddresses.FUSE_MANAGER);
        _contextManager.runWithContext(ExecuteData({targets: targets, datas: data}));

        // Verify the fuse was added by checking if it's in the rewards fuses list
        address[] memory rewardFuses = _rewardsClaimManager.getRewardsFuses();
        bool fuseFound = false;

        for (uint256 i = 0; i < rewardFuses.length; i++) {
            if (rewardFuses[i] == address(_claimFuse)) {
                fuseFound = true;
                break;
            }
        }

        assertTrue(fuseFound, "Claim fuse should be added to rewards fuses");
    }

    function testRemoveRewardFuses() public {
        // First add the fuse so we can remove it
        address[] memory fuses = new address[](1);
        fuses[0] = address(_claimFuse);

        bytes memory addRewardFusesData = abi.encodeWithSignature("addRewardFuses(address[])", fuses);

        address[] memory targets = new address[](1);
        targets[0] = address(_rewardsClaimManager);

        bytes[] memory data = new bytes[](1);
        data[0] = addRewardFusesData;

        // Add the fuse first
        vm.prank(TestAddresses.FUSE_MANAGER);
        _contextManager.runWithContext(ExecuteData({targets: targets, datas: data}));

        // Verify fuse was added
        address[] memory rewardFuses = _rewardsClaimManager.getRewardsFuses();
        bool fuseFoundAfterAdd = false;
        for (uint256 i = 0; i < rewardFuses.length; i++) {
            if (rewardFuses[i] == address(_claimFuse)) {
                fuseFoundAfterAdd = true;
                break;
            }
        }
        assertTrue(fuseFoundAfterAdd, "Claim fuse should be added before removal");

        // Now prepare removal data
        bytes memory removeRewardFusesData = abi.encodeWithSignature("removeRewardFuses(address[])", fuses);

        data[0] = removeRewardFusesData;

        // Execute removal through context manager
        vm.prank(TestAddresses.FUSE_MANAGER);
        _contextManager.runWithContext(ExecuteData({targets: targets, datas: data}));

        // Verify the fuse was removed
        address[] memory rewardFusesAfterRemoval = _rewardsClaimManager.getRewardsFuses();
        bool fuseFoundAfterRemoval = false;
        for (uint256 i = 0; i < rewardFusesAfterRemoval.length; i++) {
            if (rewardFusesAfterRemoval[i] == address(_claimFuse)) {
                fuseFoundAfterRemoval = true;
                break;
            }
        }
        assertFalse(fuseFoundAfterRemoval, "Claim fuse should be removed from rewards fuses");
    }

    function testSetupVestingTime() public {
        // Prepare vesting time parameters
        uint32 newVestingTime = 7 days;

        bytes memory setupVestingTimeData = abi.encodeWithSignature("setupVestingTime(uint256)", newVestingTime);

        // Prepare context data
        address[] memory targets = new address[](1);
        targets[0] = address(_rewardsClaimManager);

        bytes[] memory data = new bytes[](1);
        data[0] = setupVestingTimeData;

        // Execute through context manager
        vm.prank(TestAddresses.ATOMIST);
        _contextManager.runWithContext(ExecuteData({targets: targets, datas: data}));

        // Verify the vesting time was updated
        uint32 updatedVestingTime = _rewardsClaimManager.getVestingData().vestingTime;
        assertEq(updatedVestingTime, newVestingTime, "Vesting time should be updated to the new value");
    }

    function testClaimRewards() public {
        // Setup - supply to Moonwell first
        uint256 supplyAmount = 500e6; // 500 USDC

        // Prepare supply action
        MoonwellSupplyFuseEnterData memory enterData = MoonwellSupplyFuseEnterData({
            asset: _UNDERLYING_TOKEN,
            amount: supplyAmount
        });

        // Create FuseAction for supply
        FuseAction[] memory supplyActions = new FuseAction[](1);
        supplyActions[0] = FuseAction({
            fuse: _moonwellAddresses.suppluFuse,
            data: abi.encodeWithSignature("enter((address,uint256))", enterData)
        });

        // Execute supply through PlasmaVault
        vm.prank(TestAddresses.ALPHA);
        _plasmaVault.execute(supplyActions);

        // Add claim fuse to rewards manager
        address[] memory fuses = new address[](1);
        fuses[0] = address(_claimFuse);

        bytes memory addRewardFusesData = abi.encodeWithSignature("addRewardFuses(address[])", fuses);

        address[] memory targets = new address[](1);
        targets[0] = address(_rewardsClaimManager);

        bytes[] memory data = new bytes[](1);
        data[0] = addRewardFusesData;

        vm.prank(TestAddresses.FUSE_MANAGER);
        _contextManager.runWithContext(ExecuteData({targets: targets, datas: data}));

        // Warp time to accumulate rewards
        vm.warp(block.timestamp + 100 days);

        // Prepare claim rewards action
        address[] memory mTokens = new address[](1);
        mTokens[0] = TestAddresses.BASE_M_USDC;

        FuseAction[] memory claimActions = new FuseAction[](1);
        claimActions[0] = FuseAction({
            fuse: address(_claimFuse),
            data: abi.encodeWithSignature("claim((address[]))", MoonwellClaimFuseData({mTokens: mTokens}))
        });

        // Preperate execution to context manager
        // Prepare context data
        address[] memory targetsClaim = new address[](1);
        targetsClaim[0] = address(_rewardsClaimManager);

        bytes[] memory dataClaim = new bytes[](1);
        dataClaim[0] = abi.encodeWithSignature("claimRewards((address,bytes)[])", claimActions);

        // Execute through context manager
        vm.prank(TestAddresses.CLAIM_REWARDS);
        _contextManager.runWithContext(ExecuteData({targets: targetsClaim, datas: dataClaim}));

        // Test only if transaction execute without error
        assertTrue(true);
    }
}
