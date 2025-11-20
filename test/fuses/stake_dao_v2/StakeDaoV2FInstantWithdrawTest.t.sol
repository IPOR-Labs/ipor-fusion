// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {PlasmaVault, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {StakeDaoV2SupplyFuse, StakeDaoV2SupplyFuseEnterData} from "../../../contracts/fuses/stake_dao_v2/StakeDaoV2SupplyFuse.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {InstantWithdrawalFusesParamsStruct} from "../../../contracts/libraries/PlasmaVaultLib.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {IPlasmaVaultGovernance} from "../../../contracts/interfaces/IPlasmaVaultGovernance.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";

contract StakeDaoV2InstantWithdrawTest is Test {
    address public constant FUSION_PLASMA_VAULT = 0x4c4f752fa54dafB6d51B4A39018271c90bA1156F;
    address public constant FUSION_ACCESS_MANAGER = 0x497F8A5FcA953cd507A67e112B7D95bc712B23F1;
    address public constant CRV_USD = 0x498Bf2B1e120FeD3ad3D42EA2165E9b73f99C1e5;

    address public constant FUSION_PLASMA_VAULT_OWNER = 0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496;
    address public constant ATOMIST = 0x0Ed2fC947952896E6bf90001045f064Fe5dbC344;
    address public constant FUSE_MANAGER = 0x0Ed2fC947952896E6bf90001045f064Fe5dbC344;
    address public constant ALPHA = 0xd8a1087d6bbCd5533F819A4496a06AF452609b99;

    address public constant USER = 0xB5c6082d3307088C98dA8D79991501E113e6365d;

    address public constant STAKEDAO_V2_REWARD_VAULT_LLAMALEND_WETH = 0x2abaD3D0c104fE1C9A412431D070e73108B4eFF8;

    StakeDaoV2SupplyFuse public fuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 382806620);

        vm.startPrank(ATOMIST);
        PlasmaVaultGovernance(FUSION_PLASMA_VAULT).convertToPublicVault();
        vm.stopPrank();

        vm.startPrank(USER);
        IERC20(CRV_USD).approve(FUSION_PLASMA_VAULT, type(uint256).max);
        PlasmaVault(FUSION_PLASMA_VAULT).deposit(100_000e18, USER);
        vm.stopPrank();

        fuse = new StakeDaoV2SupplyFuse(IporFusionMarkets.STAKE_DAO_V2);

        address[] memory fuses = new address[](1);
        fuses[0] = address(fuse);

        vm.startPrank(FUSE_MANAGER);
        PlasmaVaultGovernance(FUSION_PLASMA_VAULT).addFuses(fuses);
        vm.stopPrank();

        // Deposit 90,000e18 to the WETH reward vault using execute
        _depositToWethRewardVault();

        // Configure instant withdrawal fuses
        _configureInstantWithdrawalFuses();
    }

    function _depositToWethRewardVault() private {
        uint256 depositAmount = 95_000e18;

        // Create FuseAction for depositing to WETH reward vault
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(fuse),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                StakeDaoV2SupplyFuseEnterData({
                    rewardVault: STAKEDAO_V2_REWARD_VAULT_LLAMALEND_WETH,
                    lpTokenUnderlyingAmount: depositAmount,
                    minLpTokenUnderlyingAmount: (depositAmount * 99) / 100 // 1% slippage tolerance
                })
            )
        );

        // Execute the deposit using ALPHA role
        vm.startPrank(ALPHA);
        PlasmaVault(FUSION_PLASMA_VAULT).execute(actions);
        vm.stopPrank();
    }

    function _configureInstantWithdrawalFuses() private {
        // Try to grant the role first using the vault owner
        vm.startPrank(ATOMIST);
        IporFusionAccessManager(FUSION_ACCESS_MANAGER).grantRole(
            Roles.CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE,
            ATOMIST,
            0
        );
        vm.stopPrank();

        // Prepare instant withdraw config for StakeDaoV2SupplyFuse
        InstantWithdrawalFusesParamsStruct[] memory instantWithdrawFuses = new InstantWithdrawalFusesParamsStruct[](1);
        bytes32[] memory instantWithdrawParams = new bytes32[](2);

        // First parameter: amount (0 means use all available)
        instantWithdrawParams[0] = 0;
        // Second parameter: reward vault address
        instantWithdrawParams[1] = PlasmaVaultConfigLib.addressToBytes32(STAKEDAO_V2_REWARD_VAULT_LLAMALEND_WETH);

        instantWithdrawFuses[0] = InstantWithdrawalFusesParamsStruct({
            fuse: address(fuse),
            params: instantWithdrawParams
        });

        // Configure instant withdrawal fuses using ATOMIST role
        vm.startPrank(ATOMIST);
        IPlasmaVaultGovernance(FUSION_PLASMA_VAULT).configureInstantWithdrawalFuses(instantWithdrawFuses);
        vm.stopPrank();
    }

    function testUserWithdraw3000Assets() public {
        // given
        uint256 withdrawAmount = 3_000e18;
        uint256 userBalanceBefore = PlasmaVault(FUSION_PLASMA_VAULT).balanceOf(USER);
        uint256 userAssetsBefore = PlasmaVault(FUSION_PLASMA_VAULT).convertToAssets(userBalanceBefore);
        uint256 userCRVUSDBalanceBefore = IERC20(CRV_USD).balanceOf(USER);

        // Check if user has enough assets to withdraw
        require(userAssetsBefore >= withdrawAmount, "Insufficient assets");

        // Fast forward time to ensure user is not locked
        vm.warp(block.timestamp + 2);

        // when
        vm.startPrank(USER);
        PlasmaVault(FUSION_PLASMA_VAULT).withdraw(withdrawAmount, USER, USER);
        vm.stopPrank();

        // then
        uint256 userBalanceAfter = PlasmaVault(FUSION_PLASMA_VAULT).balanceOf(USER);
        uint256 userAssetsAfter = PlasmaVault(FUSION_PLASMA_VAULT).convertToAssets(userBalanceAfter);
        uint256 userCRVUSDBalanceAfter = IERC20(CRV_USD).balanceOf(USER);

        // User should have received the withdrawn assets (check the increase in balance)
        uint256 crvUsdReceived = userCRVUSDBalanceAfter - userCRVUSDBalanceBefore;
        assertEq(crvUsdReceived, withdrawAmount, "User should receive 3000e18 CRV_USD");

        // User's vault balance should be reduced
        assertLt(userBalanceAfter, userBalanceBefore, "User's vault balance should be reduced");
        assertLt(userAssetsAfter, userAssetsBefore, "User's vault assets should be reduced");

        // Verify the withdrawal was successful
        assertTrue(userAssetsAfter < userAssetsBefore, "Withdrawal should reduce user's vault assets");
    }

    function testUserWithdraw50000AssetsInstantWithdraw() public {
        address testUser = address(0x123);

        // given
        uint256 withdrawAmount = 50_000e18;
        uint256 userBalanceBefore = PlasmaVault(FUSION_PLASMA_VAULT).balanceOf(USER);
        uint256 userAssetsBefore = PlasmaVault(FUSION_PLASMA_VAULT).convertToAssets(userBalanceBefore);

        // Check if user has enough assets to withdraw
        require(userAssetsBefore >= withdrawAmount, "Insufficient assets");

        // Fast forward time to ensure user is not locked
        vm.warp(block.timestamp + 2);

        // when
        vm.startPrank(USER);
        PlasmaVault(FUSION_PLASMA_VAULT).withdraw(withdrawAmount, testUser, USER);
        vm.stopPrank();

        // then
        uint256 userBalanceAfter = PlasmaVault(FUSION_PLASMA_VAULT).balanceOf(testUser);
        uint256 userAssetsAfter = PlasmaVault(FUSION_PLASMA_VAULT).convertToAssets(userBalanceAfter);
        uint256 userCRVUSDBalanceAfter = IERC20(CRV_USD).balanceOf(testUser);

        // Allow for small rounding errors (within 10 wei tolerance)
        uint256 tolerance = 10; // 10 wei tolerance for rounding errors
        assertApproxEqAbs(
            userCRVUSDBalanceAfter,
            withdrawAmount,
            tolerance,
            "User should receive close to 50_000e18 CRV_USD"
        );

        // User's vault balance should be reduced
        assertLt(userBalanceAfter, userBalanceBefore, "User's vault balance should be reduced");
        assertLt(userAssetsAfter, userAssetsBefore, "User's vault assets should be reduced");

        // Verify the withdrawal was successful
        assertTrue(userAssetsAfter < userAssetsBefore, "Withdrawal should reduce user's vault assets");
    }
}
