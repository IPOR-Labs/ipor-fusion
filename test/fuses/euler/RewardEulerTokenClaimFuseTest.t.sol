// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {MerklClaimFuse} from "../../../contracts/rewards_fuses/merkl/MerklClaimFuse.sol";
import {RewardsClaimManager} from "../../../contracts/managers/rewards/RewardsClaimManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {RewardEulerTokenClaimFuse, ClaimData} from "../../../contracts/rewards_fuses/euler/RewardEulerTokenClaimFuse.sol";
import {IREUL} from "../../../contracts/rewards_fuses/euler/ext/IREUL.sol";

// Merkl specific addresses on Ethereum mainnet
address constant MERKL_DISTRIBUTOR = 0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae;

// Ethereum mainnet vault address (as requested by user)
address constant PLASMA_VAULT = 0xc2A119EA6De75e4B1451330321CB2474Eb8D82d4;
address constant REWARDS_CLAIM_MANAGER = 0x1930c538c9f12a3F8857936FE50cB83e6699D082;

address constant ATOMIST = 0xD46E5Cd074e149a8d7C11B514f56cEc9A5b555CC;
address constant CLAIM_REWARDS = 0x6c441a03b149f4CD73EAeC31F10A0f3C952f0dF2;

address constant MORPHO = 0x58D97B57BB95320F9a05dC918Aef65434969c2B2;
address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
address constant rEUL = 0xf3e621395fc714B90dA337AA9108771597b4E696;
address constant EUL = 0xd9Fcd98c322942075A5C3860693e9f4f03AAE07b;

contract RewardEulerTokenClaimFuseTest is Test {
    MerklClaimFuse public merklClaimFuse;
    RewardEulerTokenClaimFuse public rewardEulerTokenClaimFuse;

    function setUp() public {
        // Fork Ethereum mainnet at a recent block
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 23642516);

        // Deploy the MerklClaimFuse with the Merkl Distributor address
        merklClaimFuse = new MerklClaimFuse(MERKL_DISTRIBUTOR);
        rewardEulerTokenClaimFuse = new RewardEulerTokenClaimFuse(rEUL, EUL);

        address[] memory fuses = new address[](2);
        fuses[0] = address(merklClaimFuse);
        fuses[1] = address(rewardEulerTokenClaimFuse);

        vm.startPrank(ATOMIST);
        RewardsClaimManager(REWARDS_CLAIM_MANAGER).addRewardFuses(fuses);
        vm.stopPrank();

        // given
        address[] memory tokens = new address[](3);
        tokens[0] = USDC;
        tokens[1] = MORPHO;
        tokens[2] = rEUL;

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 27089060; // USDC amount from Merkl data
        amounts[1] = 21616604949855645436; // MORPHO amount from Merkl data
        amounts[2] = 1299460096756760831; // rEUL amount from Merkl data

        bytes32[][] memory proofs = new bytes32[][](3);

        // USDC proof from Merkl data
        proofs[0] = new bytes32[](18);
        proofs[0][0] = 0x21be1c6ac1c4c0f608d9ea86ba67e12c8447d0581fed1d4343d022b0920f8a49;
        proofs[0][1] = 0xe1590ac73a03cb6bef31b0642a4f00edcfd13e09ffcc52bb03b0490a99aed0f3;
        proofs[0][2] = 0x21451e0736e3b5204ecc6b12e9ed1a8e17e4830cbba4bc03d0ac86b716a66d58;
        proofs[0][3] = 0xcad5972422fe4274968c02ed863c73edc1876491dec4d4c1544b2a2bf52148ec;
        proofs[0][4] = 0x1cd0c2cddb8cba39eb025a641781f7e0db9a2cd5dd74d62031b9806529f379f2;
        proofs[0][5] = 0x3dc586e1bd9c62ee43381ad1083799c9a975df3b32fd2f26d2e859dc6e07468e;
        proofs[0][6] = 0x28a42eab14d240ac1f2dfdf3c7b038afbd6d1f2b7854e9d35e792954106f035e;
        proofs[0][7] = 0x1429b8f7141319806b5720d5fe8726fdb76cc47c75437ab510e13f355c48683f;
        proofs[0][8] = 0x9e0f6e6303cda007b2ee9273cb2bedfef0d564d919ccd69207ba1a160232f610;
        proofs[0][9] = 0x65f98ca62266d6300fa6b5df6a6e782957d3371777092cce13b0787f50b4155c;
        proofs[0][10] = 0x9275f7e00bc52d15852ff64959c312d2fa000bf0cdb6e9fe5fd46b48e0059a48;
        proofs[0][11] = 0xecf903b7123ad1be97c1aa46dca9b0febbd5228d47258780c0cf351831d18cde;
        proofs[0][12] = 0xbf38ede483b7d58c80972ca13723d79f7d972b85ee7b2f5b73bb716a1e6923ce;
        proofs[0][13] = 0x96f1f4f5cdf3013c5d1dfec76e0e4e181ead17e0d5e63ecfccdddcfb92808054;
        proofs[0][14] = 0x6431560af28a77449d81d78be68ad1220b6c6f6e98183ad3febcf88ba9c956d6;
        proofs[0][15] = 0x0695e75d4f344cc5a8ce5b37e02f220a7bc7121707f3a3732dfb19fe66d119f0;
        proofs[0][16] = 0x55efb38f9f125bc77aacddd5b5b9c2913b72d3b47da439e864ca03a3f7505062;
        proofs[0][17] = 0x874654ebfdc540ec945408104b5a56b700574e76d3e9076ec11eaad7dde81a91;

        // MORPHO proof from Merkl data
        proofs[1] = new bytes32[](18);
        proofs[1][0] = 0x3187041e4f8b6f37b5d4fcdf37e95cdbc8b35cf554409352e5d86fdf444a567b;
        proofs[1][1] = 0xeacfb6acc2917ac630b401757ce1265d4d68ff51b106cf3c9ac16b958b198460;
        proofs[1][2] = 0x52e30c01ac8780db571de32379325dc6f02832977137f9e139c44142e1057f3e;
        proofs[1][3] = 0x9825ff5bf3f53a9a7e2b04e6af93cd54fc881261bb02b8709711cb3beb05a07b;
        proofs[1][4] = 0x29d07e85b21221ebc0369bc3a9b3dc1342d54ebff198f3c3517da04b37a05b67;
        proofs[1][5] = 0xe962dc99d34f1cf706505df952adb533489d647a94addd399c953151956eada8;
        proofs[1][6] = 0xf5675b1a346d80ba03e28bb2e0dfa44be5f2bbb6290755cdb6ccb9e42c6e9c0d;
        proofs[1][7] = 0xac3ee137ae3edaea47990cd9f730bf9402afcf92b01201e90854a275eb59d3a1;
        proofs[1][8] = 0x54234f2d62b3de9698e22e5e47f6224c9f2bd74d98395d8f1ddb4a6d220e4ac9;
        proofs[1][9] = 0x31a35ec48ff96b99d4c5a0048ed27e47ee426b47023c1b7a86ad1939063d4255;
        proofs[1][10] = 0x24ee8f34270054317bf063c73bb9e6f08d52184ff98edfdfb8bd8ee5302111f9;
        proofs[1][11] = 0x0b3f2c22012861d83f23f6d8bbb9f63da153ce1573c6a293bd307dc17a4b370d;
        proofs[1][12] = 0x1542165b8fab34550c6b5a7aa3205dd24bd666e32bb1a59ea709ec5740817254;
        proofs[1][13] = 0x118a0c6340760e1c4c91628fa0e48e17a5cdb2415a60de3b48abf12ac622e16f;
        proofs[1][14] = 0xc8abbd4b5fc48721fbc4f3c8a8c9accc0906b7077987ea1822f7a69827c7bf18;
        proofs[1][15] = 0x5a26e79128663db7276f2f294ddc36aeb0eaa1fb9f32ecebd9def819fd0f6cc1;
        proofs[1][16] = 0x55efb38f9f125bc77aacddd5b5b9c2913b72d3b47da439e864ca03a3f7505062;
        proofs[1][17] = 0x874654ebfdc540ec945408104b5a56b700574e76d3e9076ec11eaad7dde81a91;

        // rEUL proof from Merkl data
        proofs[2] = new bytes32[](18);
        proofs[2][0] = 0x45b880e647622ce12991b2d2126e0ad8b9955ec922435922a505f28c67095bd2;
        proofs[2][1] = 0x7cddcef2fdc1e4717fcdda25c9c79b90eda75fd30a791874959517e1e0e256af;
        proofs[2][2] = 0x2dce50ad4d80b89279660dff58dca69987d105bff4c0fe9c9686d19412a42007;
        proofs[2][3] = 0xc4d3a3fbc992eda6bfa597f4b0d47b4c30132553959d136c24234a54facb8f1e;
        proofs[2][4] = 0x64584131ae131b0baa3e87d84ed0939f3af5244a2cd7c4e1dae5f24be9b8d1fc;
        proofs[2][5] = 0x3cd1e66b21b4e2a1de90cdde87edc127c3330b43c89e02f56745d8f0f3ef480e;
        proofs[2][6] = 0x81ea09d15dfba5489c1042b62410e4e4eeb74b329b9a89878b9585b2d159915e;
        proofs[2][7] = 0x057e5336d03eda03d73453217b4d0fddfcc6a011bf27937ca1358ff81250ca5e;
        proofs[2][8] = 0x64b7d78104c41128972a0bf4b3b098b900428c7859dde0a26fef7ef0a761cca8;
        proofs[2][9] = 0x4ec82e84f6105c249c047424d6e6403bb794e24ea1034d70645bd04c32e3c688;
        proofs[2][10] = 0x1fb3ba1d59fda6f179ead3821739947354745a6af48dc2f22d4233fa7ef768ae;
        proofs[2][11] = 0xc1ff08b3a682bece50f4660bd537b85b9a7554471e47bad58856475a8d626bf2;
        proofs[2][12] = 0x920f051bd485225ffd0f6f6492f9f2c1806e09831aacb1bfbbacd5c175a28e74;
        proofs[2][13] = 0xc444b52d2bcd6299a728f83a7971f5fa581ea6b503a5cf25b1e3454b0649d79e;
        proofs[2][14] = 0x8d1fc2a451a96ddd5e1d4ff48a577996d3075898c363606d051f32f68e746ed3;
        proofs[2][15] = 0x5a26e79128663db7276f2f294ddc36aeb0eaa1fb9f32ecebd9def819fd0f6cc1;
        proofs[2][16] = 0x55efb38f9f125bc77aacddd5b5b9c2913b72d3b47da439e864ca03a3f7505062;
        proofs[2][17] = 0x874654ebfdc540ec945408104b5a56b700574e76d3e9076ec11eaad7dde81a91;

        address[] memory doNotTransferToRewardManager = new address[](1); // Empty array - transfer all tokens
        doNotTransferToRewardManager[0] = rEUL;

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction({
            fuse: address(merklClaimFuse),
            data: abi.encodeWithSignature(
                "claim(address[],uint256[],bytes32[][],address[])",
                tokens,
                amounts,
                proofs,
                doNotTransferToRewardManager
            )
        });

        vm.startPrank(CLAIM_REWARDS);
        RewardsClaimManager(REWARDS_CLAIM_MANAGER).claimRewards(calls);
        vm.stopPrank();
    }

    function testShouldClaimAllEULFromREUL() public {
        // given
        uint256[] memory lockTimestamps = IREUL(rEUL).getLockedAmountsLockTimestamps(PLASMA_VAULT);

        ClaimData memory claimData = ClaimData({lockTimestamps: lockTimestamps, allowRemainderLoss: true});

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction({
            fuse: address(rewardEulerTokenClaimFuse),
            data: abi.encodeWithSelector(RewardEulerTokenClaimFuse.claim.selector, claimData)
        });

        vm.warp(block.timestamp + 200 days);
        (uint256 accountAmount, uint256 remainderAmount) = IREUL(rEUL).getWithdrawAmountsByLockTimestamp(
            PLASMA_VAULT,
            lockTimestamps[0]
        );
        uint256 eulerRewardsManagerBalanceBefore = IERC20(EUL).balanceOf(REWARDS_CLAIM_MANAGER);
        vm.startPrank(CLAIM_REWARDS);
        RewardsClaimManager(REWARDS_CLAIM_MANAGER).claimRewards(calls);
        vm.stopPrank();

        uint256 eulerRewardsManagerBalanceAfter = IERC20(EUL).balanceOf(REWARDS_CLAIM_MANAGER);
        assertEq(eulerRewardsManagerBalanceAfter - eulerRewardsManagerBalanceBefore, accountAmount);
    }

    function testShouldClaimPartialEULFromREUL() public {
        // given
        uint256[] memory lockTimestamps = IREUL(rEUL).getLockedAmountsLockTimestamps(PLASMA_VAULT);

        ClaimData memory claimData = ClaimData({lockTimestamps: lockTimestamps, allowRemainderLoss: true});

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction({
            fuse: address(rewardEulerTokenClaimFuse),
            data: abi.encodeWithSelector(RewardEulerTokenClaimFuse.claim.selector, claimData)
        });

        (uint256 accountAmount, ) = IREUL(rEUL).getWithdrawAmountsByLockTimestamp(PLASMA_VAULT, lockTimestamps[0]);
        uint256 eulerRewardsManagerBalanceBefore = IERC20(EUL).balanceOf(REWARDS_CLAIM_MANAGER);
        vm.startPrank(CLAIM_REWARDS);
        RewardsClaimManager(REWARDS_CLAIM_MANAGER).claimRewards(calls);
        vm.stopPrank();

        uint256 eulerRewardsManagerBalanceAfter = IERC20(EUL).balanceOf(REWARDS_CLAIM_MANAGER);
        assertEq(eulerRewardsManagerBalanceAfter - eulerRewardsManagerBalanceBefore, accountAmount);
    }

    function testShouldRevertClaimWhenAllowRemainerLostFalse() public {
        // given
        uint256[] memory lockTimestamps = IREUL(rEUL).getLockedAmountsLockTimestamps(PLASMA_VAULT);

        ClaimData memory claimData = ClaimData({lockTimestamps: lockTimestamps, allowRemainderLoss: false});

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction({
            fuse: address(rewardEulerTokenClaimFuse),
            data: abi.encodeWithSelector(RewardEulerTokenClaimFuse.claim.selector, claimData)
        });

        (uint256 accountAmount, ) = IREUL(rEUL).getWithdrawAmountsByLockTimestamp(PLASMA_VAULT, lockTimestamps[0]);
        uint256 eulerRewardsManagerBalanceBefore = IERC20(EUL).balanceOf(REWARDS_CLAIM_MANAGER);

        bytes memory error = abi.encodeWithSignature("RemainderLossNotAllowed()");
        vm.expectRevert(error);

        vm.startPrank(CLAIM_REWARDS);
        RewardsClaimManager(REWARDS_CLAIM_MANAGER).claimRewards(calls);
        vm.stopPrank();
    }
}
