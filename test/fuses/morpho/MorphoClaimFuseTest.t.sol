// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MorphoClaimFuse} from "../../../contracts/rewards_fuses/morpho/MorphoClaimFuse.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVault, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {RewardsClaimManager} from "../../../contracts/managers/rewards/RewardsClaimManager.sol";

address constant PLASMA_VAULT = 0x45aa96f0b3188D47a1DaFdbefCE1db6B37f58216;

address constant ATOMIST = 0xF6a9bd8F6DC537675D499Ac1CA14f2c55d8b5569;
address constant ALPHA = 0x48d3615d78B152819ea0367adF7b9944e399ac9a;

address constant REWARDS_MANAGER = 0x0Ca78DcA6EDA9360CEe43631B60252F5835b4B06;
address constant FUSE_MANAGER = 0xF6a9bd8F6DC537675D499Ac1CA14f2c55d8b5569;

address constant DISTRIBUTOR = 0x5400dBb270c956E8985184335A1C62AcA6Ce1333;
address constant REWARDS_TOKEN = 0xBAa5CC21fd487B8Fcc2F632f3F4E8D37262a0842;

contract MorphoClaimFuseTest is Test {
    PlasmaVault public plasmaVault;
    PlasmaVaultGovernance public plasmaVaultGovernance;
    RewardsClaimManager public rewardsClaimManager;

    MorphoClaimFuse public morphoClaimFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_PROVIDER_URL"), 22993685);
        plasmaVault = PlasmaVault(PLASMA_VAULT);
        plasmaVaultGovernance = PlasmaVaultGovernance(address(plasmaVault));
        rewardsClaimManager = RewardsClaimManager(REWARDS_MANAGER);

        vm.startPrank(ATOMIST);
        morphoClaimFuse = new MorphoClaimFuse(IporFusionMarkets.MORPHO_REWARDS);

        bytes32[] memory substrates_ = new bytes32[](1);
        substrates_[0] = bytes32(uint256(uint160(DISTRIBUTOR)));

        plasmaVaultGovernance.grantMarketSubstrates(IporFusionMarkets.MORPHO_REWARDS, substrates_);
        vm.stopPrank();
    }

    function testClaimRewards() public {
        // given
        address universalRewardsDistributor = address(DISTRIBUTOR);
        address rewardsToken = REWARDS_TOKEN;
        uint256 claimable = 9416686394973420181;
        bytes32[] memory proof = new bytes32[](16);
        proof[0] = 0xd71dd296a44f7dbe30717a8125d05f8f327150af2e57a2e0790543d062708572;
        proof[1] = 0xcb536d8419103c446aa1a394d474a5afc3ed8a50972968bceae4dd4cdcde6963;
        proof[2] = 0x2e5c38b669cbf15f81320c2e317a1352f089b9a3a6732b2d85eade6bea3553c0;
        proof[3] = 0x6cc1af74fb8a9dbc6ee3fcd38875c1fcd3a8c778ad3ada3d46676ea93226d593;
        proof[4] = 0xa12868e714e19fc3fd5c53faacf8af62158abd0afd6fbefe6158273dd51c3132;
        proof[5] = 0x6a627a17e309874d1444fd33ec4a1c6860e4f98028e6b340e129328428b397c3;
        proof[6] = 0x21b27555b2449848b0c805ab4133f04515f711169245ece5d35b7f09cdca65c4;
        proof[7] = 0xb4961acf0f71a220c1d88952b010e1be82e816829e916f9ee62b74b4e1c4b7b6;
        proof[8] = 0x9fa4904da7e2737152890cf0c41e2e9bbf5a62a6f6301c3d185133ac3c69464d;
        proof[9] = 0x4c3c30c0ecbfd809f2a4c3ab01847fb903a1cd54b72b399f6d33ab25b2d35aa2;
        proof[10] = 0xb42462c3b6455a807c20bc8fb42d3c08e7df5d30f4f78a85dff8a882eb7792db;
        proof[11] = 0xbfcb58baa1ec93a340059d76d634744f1995bc82dd58c7a018c9545236329a95;
        proof[12] = 0x7060e12fc8c4f45ab377f6bf5e46b156b8477adf3d62b57c4054d9b0482597ab;
        proof[13] = 0x9ce5b2bec40e4ba9a9b6832d79f2667ffe8ef440a50675125c238900017a5edb;
        proof[14] = 0x6f9fb219cc72b60715f4ec24e4b84231d0fdf5aaaaf7d863c3fc68aa41d2ab19;
        proof[15] = 0xfaef67e355cf50b5c58e014a4a2d69f64061cb2ba39c57f81770d2f24f7e6211;

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction({
            fuse: address(morphoClaimFuse),
            data: abi.encodeWithSignature(
                "claim(address,address,uint256,bytes32[])",
                universalRewardsDistributor,
                rewardsToken,
                claimable,
                proof
            )
        });

        uint256 rewardsClaimManagerBalanceBefore = IERC20(REWARDS_TOKEN).balanceOf(REWARDS_MANAGER);

        address[] memory fuses = new address[](1);
        fuses[0] = address(morphoClaimFuse);

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
        assertEq(rewardsClaimManagerBalanceAfter, claimable, "RewardsClaimManager should have claimed rewards");
    }
}
