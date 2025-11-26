// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {PlasmaVault, PlasmaVaultInitData, FuseAction, MarketSubstratesConfig, MarketBalanceFuseConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";
import {FusionFactory} from "../../../contracts/factory/FusionFactory.sol";
import {FusionFactoryLib} from "../../../contracts/factory/lib/FusionFactoryLib.sol";
import {FusionFactoryStorageLib} from "../../../contracts/factory/lib/FusionFactoryStorageLib.sol";
import {RewardsManagerFactory} from "../../../contracts/factory/RewardsManagerFactory.sol";
import {WithdrawManagerFactory} from "../../../contracts/factory/WithdrawManagerFactory.sol";
import {ContextManagerFactory} from "../../../contracts/factory/ContextManagerFactory.sol";
import {PriceManagerFactory} from "../../../contracts/factory/PriceManagerFactory.sol";
import {PlasmaVaultFactory} from "../../../contracts/factory/PlasmaVaultFactory.sol";
import {AccessManagerFactory} from "../../../contracts/factory/AccessManagerFactory.sol";
import {FeeManagerFactory} from "../../../contracts/managers/fee/FeeManagerFactory.sol";
import {MockERC20} from "../../test_helpers/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {ZeroBalanceFuse} from "../../../contracts/fuses/ZeroBalanceFuse.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {IPriceFeed} from "../../../contracts/price_oracle/price_feed/IPriceFeed.sol";
import {PriceOracleMiddlewareManager} from "../../../contracts/managers/price/PriceOracleMiddlewareManager.sol";

import {TacStakingStorageLib} from "../../../contracts/fuses/tac/lib/TacStakingStorageLib.sol";
import {TacStakingDelegatorAddressReader} from "../../../contracts/readers/TacStakingDelegatorAddressReader.sol";
import {InstantWithdrawalFusesParamsStruct} from "../../../contracts/libraries/PlasmaVaultLib.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {TacValidatorAddressConverter} from "../../../contracts/fuses/tac/lib/TacValidatorAddressConverter.sol";
import {Description, CommissionRates} from "../../../contracts/fuses/tac/ext/IStaking.sol";
import {IporMath} from "../../../contracts/libraries/math/IporMath.sol";
import {IPriceOracleMiddleware} from "../../../contracts/price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultLib} from "../../../contracts/libraries/PlasmaVaultLib.sol";

import {StakeDaoV2BalanceFuse} from "../../../contracts/fuses/stake_dao_v2/StakeDaoV2BalanceFuse.sol";
import {StakeDaoV2SupplyFuse, StakeDaoV2SupplyFuseEnterData} from "../../../contracts/fuses/stake_dao_v2/StakeDaoV2SupplyFuse.sol";
import {StakeDaoV2ClaimFuse} from "../../../contracts/rewards_fuses/stake_dao_v2/StakeDaoV2ClaimFuse.sol";
import {RewardsClaimManager} from "../../../contracts/managers/rewards/RewardsClaimManager.sol";
import {IAccountant} from "../../../contracts/fuses/stake_dao_v2/ext/IAccountant.sol";
import {IRewardVault} from "../../../contracts/fuses/stake_dao_v2/ext/IRewardVault.sol";
import {SimpleMockAccountant} from "./mocks/SimpleMockAccountant.sol";
import {MockRewardVault} from "./mocks/MockRewardVault.sol";
import {BalanceFusesReader} from "../../../contracts/readers/BalanceFusesReader.sol";

contract StakeDaoV2FuseTest is Test {
    address constant FUSION_FACTORY = 0x134fCAce7a2C7Ef3dF2479B62f03ddabAEa922d5;

    address constant FUSION_PLASMA_VAULT_OWNER = 0xB0552b6860CE5C0202976Db056b5e3Cc4f9CC765;

    address constant FUSION_ACCESS_MANAGER = 0x19BAf9a25D1a4619Be1f7065c6A8d181a524991D;
    address constant FUSION_PRICE_MANAGER = 0x40e2d65023ef964A673950Df587cE239Bb1CE43d;
    address constant FUSION_REWARDS_MANAGER = 0x47E217B96148F754D134EC44D691A2462C922391;
    address constant FUSION_PLASMA_VAULT_sdSaveUSDC = 0xa4f39ec96B7A2178B381dE9CDc9021fB2490b409;

    address constant STAKEDAO_V2_REWARD_VAULT_LLAMALEND_WBTC = 0x1544E663DD326a6d853a0cc4ceEf0860eb82B287;
    address constant STAKEDAO_V2_REWARD_VAULT_LLAMALEND_WBTC_UNDERLYING = 0xe07f1151887b8FDC6800f737252f6b91b46b5865;

    address constant STAKEDAO_V2_REWARD_VAULT_LLAMALEND_WETH = 0x2abaD3D0c104fE1C9A412431D070e73108B4eFF8;
    address constant STAKEDAO_V2_REWARD_VAULT_LLAMALEND_WETH_UNDERLYING = 0xd3cA9BEc3e681b0f578FD87f20eBCf2B7e0bb739;

    address constant STAKEDAO_V2_REWARD_VAULT_LLAMALEND_EYWA = 0x555928DC8973F10f5bbA677d0EBB7cbac968e36A;
    address constant STAKEDAO_V2_REWARD_VAULT_LLAMALEND_EYWA_UNDERLYING = 0x747A547E48ee52491794b8eA01cd81fc5D59Ad84;

    address constant STAKEDAO_V2_REWARD_VAULT_LLAMALEND_ARB = 0x17E876675258DeE5A7b2e2e14FCFaB44F867896c;
    address constant STAKEDAO_V2_REWARD_VAULT_LLAMALEND_ARB_UNDERLYING = 0xa6C2E6A83D594e862cDB349396856f7FFE9a979B;

    address constant CHAINLINK_PRICE_FEED_USDC = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;

    // @dev https://data.chain.link/feeds/arbitrum/mainnet/crvusd-usd
    address constant CHAINLINK_PRICE_FEED_CRV_USD = 0x0a32255dd4BB6177C994bAAc73E0606fDD568f66;

    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant CRV_USD = 0x498Bf2B1e120FeD3ad3D42EA2165E9b73f99C1e5;

    address constant CRV = 0x11cDb42B0EB46D95f990BeDD4695A6e3fA034978;

    address user;
    address atomist;
    address alpha;

    bytes32[] substrates;
    address stakeDaoV2SupplyFuse;

    address CRV_USD_HOLDER = 0xB5c6082d3307088C98dA8D79991501E113e6365d;
    address USDC_HOLDER = 0x2Df1c51E09aECF9cacB7bc98cB1742757f163dF7;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 368270603);

        user = address(0x333);
        atomist = address(0x777);
        alpha = address(0x555);

        _setupRoles();

        address[] memory assets = new address[](2);
        assets[0] = USDC;
        assets[1] = CRV_USD;

        address[] memory sources = new address[](2);
        sources[0] = CHAINLINK_PRICE_FEED_USDC;
        sources[1] = CHAINLINK_PRICE_FEED_CRV_USD;

        vm.startPrank(atomist);
        PriceOracleMiddlewareManager(FUSION_PRICE_MANAGER).setAssetsPriceSources(assets, sources);
        vm.stopPrank();

        _addStakeDaoV2Fuses();
    }

    function test_shouldDepositToVaultAndRebalanceAssetsProportionallyTo4Vaults() public {
        // given
        uint256 depositAmountCrvUSD = 1000e18; // 1000 crvUSD

        // @dev Simulate that Vault has some crvUSD
        vm.prank(CRV_USD_HOLDER);
        IERC20(CRV_USD).transfer(FUSION_PLASMA_VAULT_sdSaveUSDC, depositAmountCrvUSD);

        // Update balances after deposit
        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.STAKE_DAO_V2;

        // Calculate proportional amounts for 4 vaults (25% each)
        uint256 amountPerVault = depositAmountCrvUSD / 4;

        // Create FuseAction array for rebalancing to 4 vaults
        FuseAction[] memory actions = new FuseAction[](4);

        // Action 1: Supply to first vault (WBTC)
        actions[0] = FuseAction(
            stakeDaoV2SupplyFuse,
            abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                StakeDaoV2SupplyFuseEnterData({
                    rewardVault: STAKEDAO_V2_REWARD_VAULT_LLAMALEND_WBTC,
                    lpTokenUnderlyingAmount: amountPerVault,
                    minLpTokenUnderlyingAmount: (amountPerVault * 99) / 100 // 1% slippage tolerance
                })
            )
        );

        // Action 2: Supply to second vault (WETH)
        actions[1] = FuseAction(
            stakeDaoV2SupplyFuse,
            abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                StakeDaoV2SupplyFuseEnterData({
                    rewardVault: STAKEDAO_V2_REWARD_VAULT_LLAMALEND_WETH,
                    lpTokenUnderlyingAmount: amountPerVault,
                    minLpTokenUnderlyingAmount: (amountPerVault * 99) / 100 // 1% slippage tolerance
                })
            )
        );

        // Action 3: Supply to third vault (EYWA)
        actions[2] = FuseAction(
            stakeDaoV2SupplyFuse,
            abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                StakeDaoV2SupplyFuseEnterData({
                    rewardVault: STAKEDAO_V2_REWARD_VAULT_LLAMALEND_EYWA,
                    lpTokenUnderlyingAmount: amountPerVault,
                    minLpTokenUnderlyingAmount: (amountPerVault * 99) / 100 // 1% slippage tolerance
                })
            )
        );

        // Action 4: Supply to fourth vault (ARB)
        actions[3] = FuseAction(
            stakeDaoV2SupplyFuse,
            abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                StakeDaoV2SupplyFuseEnterData({
                    rewardVault: STAKEDAO_V2_REWARD_VAULT_LLAMALEND_ARB,
                    lpTokenUnderlyingAmount: amountPerVault,
                    minLpTokenUnderlyingAmount: (amountPerVault * 99) / 100 // 1% slippage tolerance
                })
            )
        );

        uint256 totalAssetsInMarketBefore = PlasmaVault(FUSION_PLASMA_VAULT_sdSaveUSDC).totalAssetsInMarket(
            IporFusionMarkets.STAKE_DAO_V2
        );

        uint256 crvUsdVaultBalanceBefore = IERC20(CRV_USD).balanceOf(FUSION_PLASMA_VAULT_sdSaveUSDC);

        assertEq(
            crvUsdVaultBalanceBefore,
            depositAmountCrvUSD,
            "CRV_USD vault balance should be equal to transferred amount"
        );

        // when - Alpha executes rebalancing
        vm.startPrank(alpha);
        PlasmaVault(FUSION_PLASMA_VAULT_sdSaveUSDC).execute(actions);
        vm.stopPrank();

        // Record balance of CRV_USD vault after rebalancing
        uint256 crvUsdVaultBalanceAfter = IERC20(CRV_USD).balanceOf(FUSION_PLASMA_VAULT_sdSaveUSDC);

        assertEq(crvUsdVaultBalanceAfter, 0, "CRV_USD vault balance should be 0 after rebalancing");

        uint256 totalAssetsInMarketAfter = PlasmaVault(FUSION_PLASMA_VAULT_sdSaveUSDC).totalAssetsInMarket(
            IporFusionMarkets.STAKE_DAO_V2
        );

        // Total assets in market should increase
        assertGt(
            totalAssetsInMarketAfter,
            totalAssetsInMarketBefore,
            "Total assets in market should increase after rebalancing"
        );
    }

    function test_shouldClaimMainRewards() public {
        _configureRewardsSubstrates();

        // given
        uint256 depositAmountCrvUSD = 1000e18; // 1000 crvUSD

        address accountant = address(IRewardVault(STAKEDAO_V2_REWARD_VAULT_LLAMALEND_WBTC).ACCOUNTANT());

        SimpleMockAccountant mockAccountant = new SimpleMockAccountant(CRV, 777e18);

        // Deal CRV tokens to the mock accountant so it can transfer them
        deal(CRV, address(mockAccountant), 777e18);

        // Replace the real accountant with our mock
        bytes memory newCode = address(mockAccountant).code;
        vm.etch(accountant, newCode);

        // @dev Simulate that Vault has some crvUSD
        vm.prank(CRV_USD_HOLDER);
        IERC20(CRV_USD).transfer(FUSION_PLASMA_VAULT_sdSaveUSDC, depositAmountCrvUSD);

        // Create StakeDaoV2ClaimFuse
        address stakeDaoV2ClaimFuse = address(new StakeDaoV2ClaimFuse(IporFusionMarkets.STAKE_DAO_V2));

        // Add claim fuse to rewards manager
        address[] memory rewardFuses = new address[](1);
        rewardFuses[0] = stakeDaoV2ClaimFuse;

        vm.startPrank(atomist);
        RewardsClaimManager(FUSION_REWARDS_MANAGER).addRewardFuses(rewardFuses);
        vm.stopPrank();

        // Prepare reward vaults array for claiming
        address[] memory rewardVaults = new address[](1);
        rewardVaults[0] = STAKEDAO_V2_REWARD_VAULT_LLAMALEND_WBTC;

        // Create FuseAction for claiming main rewards
        FuseAction[] memory claimActions = new FuseAction[](1);
        claimActions[0] = FuseAction(
            stakeDaoV2ClaimFuse,
            abi.encodeWithSignature("claimMainRewards(address[])", rewardVaults)
        );

        // Get rewards claim manager address
        address rewardsClaimManager = PlasmaVaultGovernance(FUSION_PLASMA_VAULT_sdSaveUSDC)
            .getRewardsClaimManagerAddress();

        vm.startPrank(alpha);
        // when - Execute claim rewards with error handling
        RewardsClaimManager(rewardsClaimManager).claimRewards(claimActions);
        vm.stopPrank();

        //then
        assertEq(IERC20(CRV).balanceOf(FUSION_REWARDS_MANAGER), 777e18, "CRV balance should be 777e18");
    }

    function test_shouldClaimExtraRewards() public {
        _configureRewardsSubstrates();

        // given
        uint256 depositAmountCrvUSD = 1000e18; // 1000 crvUSD

        // Create mock ERC20 tokens for extra rewards (CVX and LDO as examples)
        MockERC20 mockCVX = new MockERC20("Convex Token", "CVX", 18);
        MockERC20 mockLDO = new MockERC20("Lido Token", "LDO", 18);

        address CVX = address(mockCVX);
        address LDO = address(mockLDO);

        // Create mock reward vault that can claim extra rewards
        MockRewardVault mockRewardVault = new MockRewardVault(CVX, LDO, 123e18, 456e18);

        // Configure all substrates at once
        _configureAllRewardsSubstrates(address(mockRewardVault));

        // Deal extra reward tokens to the mock reward vault
        deal(CVX, address(mockRewardVault), 123e18);
        deal(LDO, address(mockRewardVault), 456e18);

        // @dev Simulate that Vault has some crvUSD
        vm.prank(CRV_USD_HOLDER);
        IERC20(CRV_USD).transfer(FUSION_PLASMA_VAULT_sdSaveUSDC, depositAmountCrvUSD);

        // Create StakeDaoV2ClaimFuse
        address stakeDaoV2ClaimFuse = address(new StakeDaoV2ClaimFuse(IporFusionMarkets.STAKE_DAO_V2));

        // Add claim fuse to rewards manager
        address[] memory rewardFuses = new address[](1);
        rewardFuses[0] = stakeDaoV2ClaimFuse;

        vm.startPrank(atomist);
        RewardsClaimManager(FUSION_REWARDS_MANAGER).addRewardFuses(rewardFuses);
        vm.stopPrank();

        // Prepare reward vaults array for claiming extra rewards
        address[] memory rewardVaults = new address[](1);
        rewardVaults[0] = address(mockRewardVault);

        // Prepare extra reward tokens array for each vault
        address[][] memory rewardVaultsTokens = new address[][](1);
        rewardVaultsTokens[0] = new address[](2);
        rewardVaultsTokens[0][0] = CVX;
        rewardVaultsTokens[0][1] = LDO;

        // Create FuseAction for claiming extra rewards
        FuseAction[] memory claimActions = new FuseAction[](1);
        claimActions[0] = FuseAction(
            stakeDaoV2ClaimFuse,
            abi.encodeWithSignature("claimExtraRewards(address[],address[][])", rewardVaults, rewardVaultsTokens)
        );

        // Get rewards claim manager address
        address rewardsClaimManager = PlasmaVaultGovernance(FUSION_PLASMA_VAULT_sdSaveUSDC)
            .getRewardsClaimManagerAddress();

        vm.startPrank(alpha);
        // when - Execute claim extra rewards
        RewardsClaimManager(rewardsClaimManager).claimRewards(claimActions);
        vm.stopPrank();

        //then
        assertEq(IERC20(CVX).balanceOf(FUSION_REWARDS_MANAGER), 123e18, "CVX balance should be 123e18");
        assertEq(IERC20(LDO).balanceOf(FUSION_REWARDS_MANAGER), 456e18, "LDO balance should be 456e18");
    }

    function test_shouldDepositToSingleVaultAndAssertBalanceFuse() public {
        // given
        uint256 depositAmountCrvUSD = 1000e18; // 1000 crvUSD

        // @dev Simulate that Vault has some crvUSD
        vm.prank(CRV_USD_HOLDER);
        IERC20(CRV_USD).transfer(FUSION_PLASMA_VAULT_sdSaveUSDC, depositAmountCrvUSD);

        // Create FuseAction array for depositing to single vault (WBTC)
        FuseAction[] memory actions = new FuseAction[](1);

        // Action: Supply to WBTC vault only
        actions[0] = FuseAction(
            stakeDaoV2SupplyFuse,
            abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                StakeDaoV2SupplyFuseEnterData({
                    rewardVault: STAKEDAO_V2_REWARD_VAULT_LLAMALEND_WBTC,
                    lpTokenUnderlyingAmount: depositAmountCrvUSD,
                    minLpTokenUnderlyingAmount: (depositAmountCrvUSD * 99) / 100 // 1% slippage tolerance
                })
            )
        );

        uint256 crvUsdVaultBalanceBefore = IERC20(CRV_USD).balanceOf(FUSION_PLASMA_VAULT_sdSaveUSDC);

        assertEq(
            crvUsdVaultBalanceBefore,
            depositAmountCrvUSD,
            "CRV_USD vault balance should be equal to transferred amount"
        );

        uint256 rewardVaultSharesBefore = IERC20(STAKEDAO_V2_REWARD_VAULT_LLAMALEND_WBTC).balanceOf(
            FUSION_PLASMA_VAULT_sdSaveUSDC
        );

        uint256 balanceInMarketBefore = PlasmaVault(FUSION_PLASMA_VAULT_sdSaveUSDC).totalAssetsInMarket(
            IporFusionMarkets.STAKE_DAO_V2
        );

        uint256 plasmaVaultTotalAssetsBefore = PlasmaVault(FUSION_PLASMA_VAULT_sdSaveUSDC).totalAssets();

        // when - Alpha executes deposit to single vault
        vm.startPrank(alpha);
        PlasmaVault(FUSION_PLASMA_VAULT_sdSaveUSDC).execute(actions);
        vm.stopPrank();

        //then

        uint256 crvUsdVaultBalanceAfter = IERC20(CRV_USD).balanceOf(FUSION_PLASMA_VAULT_sdSaveUSDC);

        uint256 rewardVaultSharesAfter = IERC20(STAKEDAO_V2_REWARD_VAULT_LLAMALEND_WBTC).balanceOf(
            FUSION_PLASMA_VAULT_sdSaveUSDC
        );

        uint256 balanceInMarketAfter = PlasmaVault(FUSION_PLASMA_VAULT_sdSaveUSDC).totalAssetsInMarket(
            IporFusionMarkets.STAKE_DAO_V2
        );

        uint256 plasmaVaultTotalAssetsAfter = PlasmaVault(FUSION_PLASMA_VAULT_sdSaveUSDC).totalAssets();

        assertEq(crvUsdVaultBalanceAfter, 0, "CRV_USD vault balance should be 0 after deposit");
        assertGt(
            balanceInMarketAfter,
            balanceInMarketBefore,
            "Balance fuse should show increased balance after deposit"
        );
        assertGt(
            rewardVaultSharesAfter,
            rewardVaultSharesBefore,
            "Vault should have more shares in the reward vault after deposit"
        );
        // @dev Notice! Expected Plasma Vault balance should be around 1000 USD (because crvUSD is stable)
        assertApproxEqRel(
            plasmaVaultTotalAssetsAfter,
            1000e6,
            0.01e18,
            "Plasma vault total assets should be around 1000 USD"
        );

        assertEq(balanceInMarketAfter, 999662185, "Balance in market should be 999662185");
        assertEq(plasmaVaultTotalAssetsAfter, 999540611, "Plasma vault total assets should be 999540611");
        assertEq(
            rewardVaultSharesAfter,
            927825241065344280486965,
            "Reward vault shares should be 927825241065344280486965"
        );
    }

    function _configureRewardsSubstrates() private {
        vm.startPrank(atomist);
        substrates = new bytes32[](4);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(STAKEDAO_V2_REWARD_VAULT_LLAMALEND_WBTC);
        substrates[1] = PlasmaVaultConfigLib.addressToBytes32(STAKEDAO_V2_REWARD_VAULT_LLAMALEND_WETH);
        substrates[2] = PlasmaVaultConfigLib.addressToBytes32(STAKEDAO_V2_REWARD_VAULT_LLAMALEND_EYWA);
        substrates[3] = PlasmaVaultConfigLib.addressToBytes32(STAKEDAO_V2_REWARD_VAULT_LLAMALEND_ARB);

        PlasmaVaultGovernance(address(FUSION_PLASMA_VAULT_sdSaveUSDC)).grantMarketSubstrates(
            IporFusionMarkets.STAKE_DAO_V2,
            substrates
        );
        vm.stopPrank();
    }

    function _configureAllRewardsSubstrates(address mockRewardVault) private {
        vm.startPrank(atomist);

        bytes32[] memory allSubstrates = new bytes32[](1);

        allSubstrates[0] = PlasmaVaultConfigLib.addressToBytes32(mockRewardVault);

        PlasmaVaultGovernance(address(FUSION_PLASMA_VAULT_sdSaveUSDC)).grantMarketSubstrates(
            IporFusionMarkets.STAKE_DAO_V2,
            allSubstrates
        );
        vm.stopPrank();
    }

    function _addStakeDaoV2Fuses() private {
        address[] memory fuses = new address[](1);

        stakeDaoV2SupplyFuse = address(new StakeDaoV2SupplyFuse(IporFusionMarkets.STAKE_DAO_V2));
        fuses[0] = stakeDaoV2SupplyFuse;

        vm.startPrank(atomist);
        PlasmaVaultGovernance(address(FUSION_PLASMA_VAULT_sdSaveUSDC)).addFuses(fuses);

        PlasmaVaultGovernance(address(FUSION_PLASMA_VAULT_sdSaveUSDC)).addBalanceFuse(
            IporFusionMarkets.STAKE_DAO_V2,
            address(new StakeDaoV2BalanceFuse(IporFusionMarkets.STAKE_DAO_V2))
        );

        // Set up substrates for supply fuse (as assets)
        substrates = new bytes32[](4);
        substrates[0] = bytes32(uint256(uint160(STAKEDAO_V2_REWARD_VAULT_LLAMALEND_WBTC)));
        substrates[1] = bytes32(uint256(uint160(STAKEDAO_V2_REWARD_VAULT_LLAMALEND_WETH)));
        substrates[2] = bytes32(uint256(uint160(STAKEDAO_V2_REWARD_VAULT_LLAMALEND_EYWA)));
        substrates[3] = bytes32(uint256(uint160(STAKEDAO_V2_REWARD_VAULT_LLAMALEND_ARB)));

        PlasmaVaultGovernance(address(FUSION_PLASMA_VAULT_sdSaveUSDC)).grantMarketSubstrates(
            IporFusionMarkets.STAKE_DAO_V2,
            substrates
        );

        vm.stopPrank();
    }

    function _setupRoles() private {
        // Grant atomist role to atomist as owner
        vm.startPrank(FUSION_PLASMA_VAULT_OWNER);
        IporFusionAccessManager(FUSION_ACCESS_MANAGER).grantRole(Roles.ATOMIST_ROLE, atomist, 0);
        vm.stopPrank();

        vm.startPrank(atomist);
        IporFusionAccessManager(FUSION_ACCESS_MANAGER).grantRole(Roles.FUSE_MANAGER_ROLE, atomist, 0);
        IporFusionAccessManager(FUSION_ACCESS_MANAGER).grantRole(Roles.ALPHA_ROLE, alpha, 0);
        IporFusionAccessManager(FUSION_ACCESS_MANAGER).grantRole(
            Roles.PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE,
            atomist,
            0
        );

        IporFusionAccessManager(FUSION_ACCESS_MANAGER).grantRole(Roles.CLAIM_REWARDS_ROLE, alpha, 0);
        IporFusionAccessManager(FUSION_ACCESS_MANAGER).grantRole(Roles.TRANSFER_REWARDS_ROLE, alpha, 0);
        IporFusionAccessManager(FUSION_ACCESS_MANAGER).grantRole(Roles.UPDATE_REWARDS_BALANCE_ROLE, alpha, 0);

        vm.stopPrank();
    }
}
