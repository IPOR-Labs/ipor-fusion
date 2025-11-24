// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {RewardsClaimManager} from "../../../contracts/managers/rewards/RewardsClaimManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {SyrupClaimFuse} from "../../../contracts/rewards_fuses/syrup/SyrupClaimFuse.sol";
import {ISyrup} from "../../../contracts/rewards_fuses/syrup/ext/ISyrup.sol";

// Syrup specific addresses on Ethereum mainnet
address constant SYRUP = 0x509712F368255E92410893Ba2E488f40f7E986EA;

// Ethereum mainnet addresses
address constant REWARDS_CLAIM_MANAGER = 0x0a308596404046884Ce239fA6BF344243F5f3af5;

address constant ATOMIST = 0x791B88B70EBE84e637ed6927b7acD64415e9353e;
address constant CLAIM_REWARDS = 0x6d3BE3f86FB1139d0c9668BD552f05fcB643E6e6;

contract SyrupClaimFuseTest is Test {
    SyrupClaimFuse public syrupClaimFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 23696709);
        syrupClaimFuse = new SyrupClaimFuse(SYRUP);

        address[] memory fuses = new address[](1);
        fuses[0] = address(syrupClaimFuse);

        vm.startPrank(ATOMIST);
        RewardsClaimManager(REWARDS_CLAIM_MANAGER).addRewardFuses(fuses);
        vm.stopPrank();
    }

    function testClaimRewards() public {
        // given
        uint256 id = 9807;
        uint256 claimAmount = 7235880000000000000;

        bytes32[] memory proof = new bytes32[](12);
        proof[0] = 0x8101ef2078a123da000f633f454370bc07bd12e9bfa35aaa9c1354b2fc247ef7;
        proof[1] = 0xdd11dee2e389e4b87ed54fac53503ad29c48b19f8ac20beb0ffe0396afe82a35;
        proof[2] = 0xb5c5f96bf1a7971f8e430baa70053f96d80f1d530b577cf9140cfe77c745b653;
        proof[3] = 0xf366bdcd2d873b66471141eebd510146e2f744e3583ad808ce9cf37e3e5db72c;
        proof[4] = 0xbe277bab6c4efc52bcd941c3b0df6ef9ba31a6c741f50e1fafc9b83fe7840e25;
        proof[5] = 0xfe79202816986f7a5822ee37c69923d0c9b84f87323068bd3db3c7dacc776b68;
        proof[6] = 0x44adec6753a31e83450c261a68a90835bf66d4571a09b3171f04100d256559cd;
        proof[7] = 0x2e7363546a6240004536945d0281396a8686bd806b82dbe5b42c6c9cb4fd4669;
        proof[8] = 0x415db1ed91dabe1253d4e72ee7166c2f19507126e5b3ea85afa7ba866537347d;
        proof[9] = 0x166d1a4f56d4002011e8353907b52bcbc06caeff951cdf4466f74668331c830c;
        proof[10] = 0xfdc8bf684701d34416ac97c64cc529c5b19f2afec1c060656fd697d3eb5bf577;
        proof[11] = 0xabc69affcf711f62ad0b3f271b81a8298d7938ce64ea31e06f27c6e8be3d79f9;

        // Get asset address from Syrup contract
        address asset = ISyrup(SYRUP).asset();

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction({
            fuse: address(syrupClaimFuse),
            data: abi.encodeWithSignature("claim(uint256,uint256,bytes32[])", id, claimAmount, proof)
        });

        uint256 balanceBefore = IERC20(asset).balanceOf(REWARDS_CLAIM_MANAGER);

        // when
        vm.startPrank(CLAIM_REWARDS);
        RewardsClaimManager(REWARDS_CLAIM_MANAGER).claimRewards(calls);
        vm.stopPrank();

        // then
        uint256 balanceAfter = IERC20(asset).balanceOf(REWARDS_CLAIM_MANAGER);

        // Verify that rewards were claimed successfully
        assertEq(
            balanceAfter - balanceBefore,
            claimAmount,
            "Rewards should be claimed and transferred to RewardsClaimManager"
        );
    }

    function testClaimRewardsRevertsWhenClaimAmountIsZero() public {
        // given
        uint256 id = 9807;
        uint256 claimAmount = 0;

        bytes32[] memory proof = new bytes32[](12);
        proof[0] = 0x8101ef2078a123da000f633f454370bc07bd12e9bfa35aaa9c1354b2fc247ef7;
        proof[1] = 0xdd11dee2e389e4b87ed54fac53503ad29c48b19f8ac20beb0ffe0396afe82a35;
        proof[2] = 0xb5c5f96bf1a7971f8e430baa70053f96d80f1d530b577cf9140cfe77c745b653;
        proof[3] = 0xf366bdcd2d873b66471141eebd510146e2f744e3583ad808ce9cf37e3e5db72c;
        proof[4] = 0xbe277bab6c4efc52bcd941c3b0df6ef9ba31a6c741f50e1fafc9b83fe7840e25;
        proof[5] = 0xfe79202816986f7a5822ee37c69923d0c9b84f87323068bd3db3c7dacc776b68;
        proof[6] = 0x44adec6753a31e83450c261a68a90835bf66d4571a09b3171f04100d256559cd;
        proof[7] = 0x2e7363546a6240004536945d0281396a8686bd806b82dbe5b42c6c9cb4fd4669;
        proof[8] = 0x415db1ed91dabe1253d4e72ee7166c2f19507126e5b3ea85afa7ba866537347d;
        proof[9] = 0x166d1a4f56d4002011e8353907b52bcbc06caeff951cdf4466f74668331c830c;
        proof[10] = 0xfdc8bf684701d34416ac97c64cc529c5b19f2afec1c060656fd697d3eb5bf577;
        proof[11] = 0xabc69affcf711f62ad0b3f271b81a8298d7938ce64ea31e06f27c6e8be3d79f9;

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction({
            fuse: address(syrupClaimFuse),
            data: abi.encodeWithSignature("claim(uint256,uint256,bytes32[])", id, claimAmount, proof)
        });

        // when & then
        vm.startPrank(CLAIM_REWARDS);
        vm.expectRevert(SyrupClaimFuse.SyrupClaimFuseClaimAmountZero.selector);
        RewardsClaimManager(REWARDS_CLAIM_MANAGER).claimRewards(calls);
        vm.stopPrank();
    }
}
