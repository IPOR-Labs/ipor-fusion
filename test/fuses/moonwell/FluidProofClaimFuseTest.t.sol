// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {FluidProofClaimFuse} from "../../../contracts/rewards_fuses/fluid_instadapp/FluidProofClaimFuse.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVault, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {RewardsClaimManager} from "../../../contracts/managers/rewards/RewardsClaimManager.sol";

address constant PLASMA_VAULT = 0x43Ee0243eA8CF02f7087d8B16C8D2007CC9c7cA2;

address constant ATOMIST = 0xF6a9bd8F6DC537675D499Ac1CA14f2c55d8b5569;
address constant ALPHA = 0x6d3BE3f86FB1139d0c9668BD552f05fcB643E6e6;

address constant REWARDS_MANAGER = 0x7a79B55893A8799EE0184ca18fFfC84699749aEA;
address constant FUSE_MANAGER = 0xF6a9bd8F6DC537675D499Ac1CA14f2c55d8b5569;

address constant DISTRIBUTOR = 0x7060FE0Dd3E31be01EFAc6B28C8D38018fD163B0;
address constant REWARDS_TOKEN = 0x6f40d4A6237C257fff2dB00FA0510DeEECd303eb;

contract FluidProofClaimFuseTest is Test {
    PlasmaVault public plasmaVault;
    PlasmaVaultGovernance public plasmaVaultGovernance;
    RewardsClaimManager public rewardsClaimManager;

    FluidProofClaimFuse public fluidProofClaimFuse;

    function setUp1() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 21665786);
        plasmaVault = PlasmaVault(PLASMA_VAULT);
        plasmaVaultGovernance = PlasmaVaultGovernance(address(plasmaVault));
        rewardsClaimManager = RewardsClaimManager(REWARDS_MANAGER);

        vm.startPrank(ATOMIST);
        fluidProofClaimFuse = new FluidProofClaimFuse(IporFusionMarkets.FLUID_REWARDS);

        bytes32[] memory substrates_ = new bytes32[](1);
        substrates_[0] = bytes32(uint256(uint160(DISTRIBUTOR)));

        plasmaVaultGovernance.grantMarketSubstrates(IporFusionMarkets.FLUID_REWARDS, substrates_);
        vm.stopPrank();
    }

    function testClaimRewards() public {
        // given
        setUp1();
        address distributor = DISTRIBUTOR;
        uint256 cumulativeAmount = 184146873116558504675;
        uint8 positionType = 1;
        bytes32 positionId = 0x0000000000000000000000009fb7b4477576fe5b32be4c1843afb1e55f251b33;
        uint256 cycle = 116;
        bytes memory metadata = hex"";

        bytes32[] memory proof = new bytes32[](13);
        proof[0] = 0x471422cc33788df7bac8eb3732649d8513a78e5dcc4fc800b877e5a4d1c164d2;
        proof[1] = 0xa408cf159753dd5de2f6ee28f7a4b6102e3bbf278c55a0af583583e5fa2f31ae;
        proof[2] = 0x5189e1b7c8b4e2493e983dd19ccad4bfe6f47d13753d58ef5eb96c6fbfae956c;
        proof[3] = 0xf963f341de836b40f414a76379d53245b886288eda699d093dde5a8db435162c;
        proof[4] = 0x847a9d34bbe3898845243f35d9af856f551bc65d06b77d6eeba6ead64e2b3655;
        proof[5] = 0x16ae3328fcbdb783fd482619a01cb52eeff18dafadf8042366fbb2a9bfb89166;
        proof[6] = 0x876341e300b44431a84fa7e9a350f4c5d083d5c782676fa5154f6379e28bd44e;
        proof[7] = 0xbe1b5077855fdfb6ea8e9140038ba4f7e542c2be28039e0507e1386948dadfd4;
        proof[8] = 0x28059478d65aee846b17a9786484c9649150b802e7d6ad5db70f4564ded33a29;
        proof[9] = 0xd9d9302d896abc14596fe4a12c77c83f97b0962782cf654a8b5c708eedf3c34a;
        proof[10] = 0xe9ea1921789c4d8f1b5e2666b6d9f644dcdce39503ff0e931f4b70d58077faec;
        proof[11] = 0x4aa452b995187a24b7e990055ed0364578b1362b7d0d778e5f7695d485a71981;
        proof[12] = 0x04a03c60d3f4280d337b4f3010d2e2c626a8fc77fc16a51ef55a99546e4ca582;

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction({
            fuse: address(fluidProofClaimFuse),
            data: abi.encodeWithSignature(
                "claim(address,uint256,uint8,bytes32,uint256,bytes32[],bytes)",
                distributor,
                cumulativeAmount,
                positionType,
                positionId,
                cycle,
                proof,
                metadata
            )
        });

        uint256 rewardsClaimManagerBalanceBefore = IERC20(REWARDS_TOKEN).balanceOf(REWARDS_MANAGER);

        address[] memory fuses = new address[](1);
        fuses[0] = address(fluidProofClaimFuse);

        vm.startPrank(ATOMIST);
        rewardsClaimManager.addRewardFuses(fuses);
        vm.stopPrank();

        // when
        vm.startPrank(ALPHA);
        rewardsClaimManager.claimRewards(calls);
        vm.stopPrank();

        // then
        uint256 rewardsClaimManagerBalanceAfter = IERC20(REWARDS_TOKEN).balanceOf(REWARDS_MANAGER);

        assertEq(rewardsClaimManagerBalanceBefore, 0, "RewardsClaimManager should have 0 balance before");
        assertEq(
            rewardsClaimManagerBalanceAfter,
            184146873116558504675,
            "RewardsClaimManager should have claimed rewards"
        );
    }
}
