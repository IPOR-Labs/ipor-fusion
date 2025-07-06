// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {PlasmaVault, PlasmaVaultInitData, FuseAction, MarketSubstratesConfig, MarketBalanceFuseConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {TacStakingFuse, TacStakingFuseEnterData, TacStakingFuseExitData} from "../../../contracts/fuses/tac/TacStakingFuse.sol";
import {TacStakingBalanceFuse} from "../../../contracts/fuses/tac/TacStakingBalanceFuse.sol";
import {PlasmaVaultConfigurator} from "../../utils/PlasmaVaultConfigurator.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
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
import {BurnRequestFeeFuse} from "../../../contracts/fuses/burn_request_fee/BurnRequestFeeFuse.sol";
import {ZeroBalanceFuse} from "../../../contracts/fuses/ZeroBalanceFuse.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {IStaking, Coin} from "../../../contracts/fuses/tac/ext/IStaking.sol";
import {IPriceFeed} from "../../../contracts/price_oracle/price_feed/IPriceFeed.sol";
import {PriceOracleMiddlewareManager} from "../../../contracts/managers/price/PriceOracleMiddlewareManager.sol";
import {MockStaking} from "./MockStaking.sol";
import {TacStakingStorageLib} from "../../../contracts/fuses/tac/TacStakingStorageLib.sol";
import {TacStakingExecutorAddressReader} from "../../../contracts/readers/TacStakingExecutorAddressReader.sol";
import {InstantWithdrawalFusesParamsStruct} from "../../../contracts/libraries/PlasmaVaultLib.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";

import {Description, CommissionRates} from "../../../contracts/fuses/tac/ext/IStaking.sol";

interface IwTAC is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 wadAmount) external;
}

contract MockPriceFeed is IPriceFeed {
    function decimals() external pure returns (uint8) {
        return 18;
    }

    function latestRoundData()
        external
        pure
        returns (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound)
    {
        return (0, 1 ether, 0, 0, 0);
    }
}

contract TacStakingFuseTest is Test {
    /// @dev TAC mainnet staking contract 0x0000000000000000000000000000000000000800
    address STAKING;
    address constant wTAC = 0xB63B9f0eb4A6E6f191529D71d4D88cc8900Df2C9;

    /// @dev You can off-chain convert validator address to operator address.
    string constant VALIDATOR_OPERATOR_ADDRESS = "tac1pdu86gjvnnr2786xtkw2eggxkmrsur0zjm6vxn";
    address constant VALIDATOR_ADDRESS = 0x78346FF37Ad8B536CE9551DEE5D037058d880300;

    uint256 constant TAC_MARKET_ID = IporFusionMarkets.TAC_STAKING;

    // Test addresses
    address alpha;
    address atomist;
    address user;

    // Contracts
    PlasmaVault plasmaVault;
    TacStakingFuse tacStakingFuse;
    TacStakingBalanceFuse tacStakingBalanceFuse;
    IporFusionAccessManager accessManager;
    address withdrawManager;
    address priceOracle;

    // FusionFactory
    FusionFactory fusionFactory;

    // Reader
    TacStakingExecutorAddressReader tacStakingExecutorAddressReader;

    function setUp() public {
        // Setup fork for TAC network
        vm.createSelectFork(vm.envString("TAC_PROVIDER_URL"));

        STAKING = address(new MockStaking());

        IStaking staking = IStaking(STAKING);
        staking.createValidator(
            Description({moniker: "test", identity: "test", website: "test", securityContact: "test", details: "test"}),
            CommissionRates({rate: 1000, maxRate: 1000, maxChangeRate: 1000}),
            0,
            VALIDATOR_ADDRESS,
            VALIDATOR_OPERATOR_ADDRESS,
            0
        );

        // Setup test addresses
        alpha = address(0x555);
        atomist = address(0x777);

        user = address(0x333);

        // Setup FusionFactory
        _setupFusionFactory();

        // Create vault using FusionFactory
        _createVaultWithFusionFactory();

        // plasmaVault address logged for debugging

        // Setup TAC staking fuse with new constructor parameters
        tacStakingFuse = new TacStakingFuse(TAC_MARKET_ID, wTAC, STAKING);

        // Setup TAC staking balance fuse with real staking contract
        tacStakingBalanceFuse = new TacStakingBalanceFuse(TAC_MARKET_ID, STAKING, wTAC);

        // Setup reader
        tacStakingExecutorAddressReader = new TacStakingExecutorAddressReader();

        // Setup roles FIRST (before adding fuses)
        _setupRoles();

        // Add TAC staking fuses to the vault AFTER roles are set up
        _addTacStakingFuses();

        address[] memory assets = new address[](1);
        assets[0] = wTAC;

        address[] memory sources = new address[](1);
        sources[0] = address(new MockPriceFeed());

        vm.startPrank(atomist);
        PriceOracleMiddlewareManager(address(priceOracle)).setAssetsPriceSources(assets, sources);
        vm.stopPrank();

        // Create executor by alpha via vault execute method
        FuseAction[] memory createExecutorCalls = new FuseAction[](1);
        createExecutorCalls[0] = FuseAction(address(tacStakingFuse), abi.encodeWithSignature("createExecutor()"));
        vm.prank(alpha);
        plasmaVault.execute(createExecutorCalls);
    }

    function testShouldRevertWhenCreatingExecutorTwice() external {
        // given - executor is already created in setUp()
        FuseAction[] memory createExecutorCalls = new FuseAction[](1);
        createExecutorCalls[0] = FuseAction(address(tacStakingFuse), abi.encodeWithSignature("createExecutor()"));

        // when & then - should revert with TacStakingFuseExecutorAlreadyCreated error
        vm.prank(alpha);
        vm.expectRevert(abi.encodeWithSelector(TacStakingFuse.TacStakingFuseExecutorAlreadyCreated.selector));
        plasmaVault.execute(createExecutorCalls);
    }

    function testShouldStakeTacSuccessfully() external {
        // given
        uint256 stakeAmount = 100;

        vm.deal(user, stakeAmount);

        vm.startPrank(user);
        IwTAC(wTAC).deposit{value: stakeAmount}();
        vm.stopPrank();

        vm.startPrank(atomist);
        accessManager.grantRole(Roles.WHITELIST_ROLE, user, 0);
        vm.stopPrank();

        vm.startPrank(user);
        IwTAC(wTAC).approve(address(plasmaVault), stakeAmount);
        vm.stopPrank();

        vm.startPrank(user);
        PlasmaVault(address(plasmaVault)).deposit(IwTAC(wTAC).balanceOf(user), user);
        vm.stopPrank();

        TacStakingFuseEnterData memory enterData = TacStakingFuseEnterData({
            validator: VALIDATOR_ADDRESS,
            tacAmount: stakeAmount
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(tacStakingFuse),
            abi.encodeWithSignature("enter((address,uint256))", enterData)
        );

        uint256 stakingBalanceBefore = address(STAKING).balance;
        uint256 vaultTotalAssetsBefore = PlasmaVault(address(plasmaVault)).totalAssets();

        // when
        vm.prank(alpha);
        plasmaVault.execute(enterCalls);

        // then
        uint256 stakingBalanceAfter = address(STAKING).balance;
        uint256 vaultTotalAssetsAfter = PlasmaVault(address(plasmaVault)).totalAssets();

        assertEq(
            stakingBalanceAfter,
            stakingBalanceBefore,
            "Staking balance should remain unchanged after staking - TAC specification"
        );
        assertEq(
            vaultTotalAssetsAfter,
            vaultTotalAssetsBefore,
            "Vault total assets should remain unchanged after staking"
        );
    }

    function testShouldUnstakeTacSuccessfully() external {
        // given
        uint256 stakeAmount = 100;

        vm.deal(user, stakeAmount);

        vm.startPrank(user);
        IwTAC(wTAC).deposit{value: stakeAmount}();
        vm.stopPrank();

        vm.startPrank(atomist);
        accessManager.grantRole(Roles.WHITELIST_ROLE, user, 0);
        vm.stopPrank();

        vm.startPrank(user);
        IwTAC(wTAC).approve(address(plasmaVault), stakeAmount);
        vm.stopPrank();

        vm.startPrank(user);
        PlasmaVault(address(plasmaVault)).deposit(IwTAC(wTAC).balanceOf(user), user);
        vm.stopPrank();

        TacStakingFuseEnterData memory enterData = TacStakingFuseEnterData({
            validator: VALIDATOR_ADDRESS,
            tacAmount: stakeAmount
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(tacStakingFuse),
            abi.encodeWithSignature("enter((address,uint256))", enterData)
        );

        vm.prank(alpha);
        plasmaVault.execute(enterCalls);

        uint256 unstakeAmount = stakeAmount;

        TacStakingFuseExitData memory exitData = TacStakingFuseExitData({
            validator: VALIDATOR_ADDRESS,
            wTacAmount: unstakeAmount
        });

        FuseAction[] memory exitCalls = new FuseAction[](1);
        exitCalls[0] = FuseAction(
            address(tacStakingFuse),
            abi.encodeWithSignature("exit((address,uint256))", exitData)
        );

        uint256 stakingBalanceBefore = address(STAKING).balance;
        uint256 vaultTotalAssetsBefore = PlasmaVault(address(plasmaVault)).totalAssets();

        // when
        vm.prank(alpha);
        plasmaVault.execute(exitCalls);

        // then
        uint256 stakingBalanceAfter = address(STAKING).balance;
        uint256 vaultTotalAssetsAfter = PlasmaVault(address(plasmaVault)).totalAssets();

        assertEq(stakingBalanceAfter, stakingBalanceBefore, "Vault should have received native TAC after unstaking");
        assertEq(
            vaultTotalAssetsAfter,
            vaultTotalAssetsBefore,
            "Vault total assets should remain unchanged after unstaking"
        );
    }

    function testShouldReceiveNativeTokensAfterUnbondingPeriod() external {
        // given
        uint256 stakeAmount = 100;

        vm.deal(user, stakeAmount);

        vm.startPrank(user);
        IwTAC(wTAC).deposit{value: stakeAmount}();
        vm.stopPrank();

        vm.startPrank(atomist);
        accessManager.grantRole(Roles.WHITELIST_ROLE, user, 0);
        vm.stopPrank();

        vm.startPrank(atomist);
        accessManager.grantRole(Roles.UPDATE_MARKETS_BALANCES_ROLE, alpha, 0);
        vm.stopPrank();

        vm.startPrank(user);
        IwTAC(wTAC).approve(address(plasmaVault), stakeAmount);
        vm.stopPrank();

        vm.startPrank(user);
        PlasmaVault(address(plasmaVault)).deposit(IwTAC(wTAC).balanceOf(user), user);
        vm.stopPrank();

        // Stake TAC
        TacStakingFuseEnterData memory enterData = TacStakingFuseEnterData({
            validator: VALIDATOR_ADDRESS,
            tacAmount: stakeAmount
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(tacStakingFuse),
            abi.encodeWithSignature("enter((address,uint256))", enterData)
        );

        vm.prank(alpha);
        plasmaVault.execute(enterCalls);

        uint256 vaultTotalAssetsBefore = PlasmaVault(address(plasmaVault)).totalAssets();
        uint256 balanceInMarketBefore = PlasmaVault(address(plasmaVault)).totalAssetsInMarket(TAC_MARKET_ID);

        // Unstake TAC (initiates unbonding)
        TacStakingFuseExitData memory exitData = TacStakingFuseExitData({
            validator: VALIDATOR_ADDRESS,
            wTacAmount: stakeAmount
        });

        FuseAction[] memory exitCalls = new FuseAction[](1);
        exitCalls[0] = FuseAction(
            address(tacStakingFuse),
            abi.encodeWithSignature("exit((address,uint256))", exitData)
        );

        vm.prank(alpha);
        plasmaVault.execute(exitCalls);

        uint256 vaultTotalAssetsAfter = PlasmaVault(address(plasmaVault)).totalAssets();
        uint256 balanceInMarketAfter = PlasmaVault(address(plasmaVault)).totalAssetsInMarket(TAC_MARKET_ID);

        // Get executor address using the reader
        address executor = tacStakingExecutorAddressReader.getTacStakingExecutorAddress(address(plasmaVault));

        // Record balances before unbonding completion
        uint256 executorNativeBalanceBefore = executor.balance;
        uint256 vaultWTacBalanceBefore = IwTAC(wTAC).balanceOf(address(plasmaVault));

        // Simulate completion of unbonding period (21 days)
        vm.warp(block.timestamp + 21 days);

        // when
        // Simulate the staking contract transferring native tokens to the executor
        // This would happen automatically in a real TAC network after the unbonding period
        vm.deal(executor, executorNativeBalanceBefore + stakeAmount);
        MockStaking(STAKING).evmMethodRemoveAllUnbondingDelegations(executor, VALIDATOR_OPERATOR_ADDRESS);

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = TAC_MARKET_ID;

        vm.prank(alpha);
        PlasmaVault(address(plasmaVault)).updateMarketsBalances(marketIds);

        // then
        uint256 vaultTotalAssetsAfterUnbonding = PlasmaVault(address(plasmaVault)).totalAssets();
        uint256 balanceInMarketAfterUnbonding = PlasmaVault(address(plasmaVault)).totalAssetsInMarket(TAC_MARKET_ID);

        assertEq(
            vaultTotalAssetsAfter,
            vaultTotalAssetsBefore,
            "Vault total assets should be equal to the initial balance"
        );
        assertEq(
            balanceInMarketAfter,
            balanceInMarketBefore,
            "Balance in market should be equal to the initial balance"
        );

        assertEq(
            vaultTotalAssetsAfterUnbonding,
            vaultTotalAssetsBefore,
            "Vault total assets should be equal to the initial balance after unbonding period"
        );
        assertEq(
            balanceInMarketAfterUnbonding,
            balanceInMarketBefore,
            "Balance in market should be equal to the initial balance after unbonding period"
        );

        assertGt(vaultTotalAssetsBefore, 0, "Vault total assets should be greater than 0");
        assertGt(balanceInMarketBefore, 0, "Balance in market should be greater than 0");
        assertGt(vaultTotalAssetsAfterUnbonding, 0, "Vault total assets should be greater than 0");
        assertGt(balanceInMarketAfterUnbonding, 0, "Balance in market should be greater than 0");
    }

    function testShouldIncreaseVaultBalanceWhenTransferNativeTokenToExecutor() external {
        // given
        uint256 stakeAmount = 100;

        vm.deal(user, stakeAmount);

        vm.startPrank(user);
        IwTAC(wTAC).deposit{value: stakeAmount}();
        vm.stopPrank();

        vm.startPrank(atomist);
        accessManager.grantRole(Roles.WHITELIST_ROLE, user, 0);
        vm.stopPrank();

        vm.startPrank(atomist);
        accessManager.grantRole(Roles.UPDATE_MARKETS_BALANCES_ROLE, alpha, 0);
        vm.stopPrank();

        vm.startPrank(user);
        IwTAC(wTAC).approve(address(plasmaVault), stakeAmount);
        vm.stopPrank();

        vm.startPrank(user);
        PlasmaVault(address(plasmaVault)).deposit(IwTAC(wTAC).balanceOf(user), user);
        vm.stopPrank();

        // Get executor address using the reader
        address executor = tacStakingExecutorAddressReader.getTacStakingExecutorAddress(address(plasmaVault));

        uint256 vaultTotalAssetsBefore = PlasmaVault(address(plasmaVault)).totalAssets();

        // when
        vm.deal(executor, stakeAmount);

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = TAC_MARKET_ID;

        vm.prank(alpha);
        PlasmaVault(address(plasmaVault)).updateMarketsBalances(marketIds);

        // then
        uint256 vaultTotalAssetsAfter = PlasmaVault(address(plasmaVault)).totalAssets();

        assertGt(
            vaultTotalAssetsAfter,
            vaultTotalAssetsBefore,
            "Vault total assets should increase by the stake amount"
        );
    }

    function testShouldGetExecutorAddressUsingReader() external {
        // given - executor is created in setUp()

        // when
        address executor = tacStakingExecutorAddressReader.getTacStakingExecutorAddress(address(plasmaVault));

        // then
        assertTrue(executor != address(0), "Executor address should not be zero");
    }

    function testShouldInstantWithdrawTacSuccessfully() external {
        // given
        uint256 stakeAmount = 100;

        // Configure instant withdraw order
        InstantWithdrawalFusesParamsStruct[] memory instantWithdrawFuses = new InstantWithdrawalFusesParamsStruct[](1);
        bytes32[] memory instantWithdrawParams = new bytes32[](1);
        instantWithdrawParams[0] = bytes32(stakeAmount); // amount

        instantWithdrawFuses[0] = InstantWithdrawalFusesParamsStruct({
            fuse: address(tacStakingFuse),
            params: instantWithdrawParams
        });

        vm.prank(atomist);
        PlasmaVaultGovernance(address(plasmaVault)).configureInstantWithdrawalFuses(instantWithdrawFuses);

        vm.deal(user, stakeAmount);

        vm.startPrank(user);
        IwTAC(wTAC).deposit{value: stakeAmount}();
        vm.stopPrank();

        vm.startPrank(atomist);
        accessManager.grantRole(Roles.WHITELIST_ROLE, user, 0);
        vm.stopPrank();

        vm.startPrank(atomist);
        accessManager.grantRole(Roles.UPDATE_MARKETS_BALANCES_ROLE, alpha, 0);
        vm.stopPrank();

        vm.startPrank(user);
        IwTAC(wTAC).approve(address(plasmaVault), stakeAmount);
        vm.stopPrank();

        vm.startPrank(user);
        PlasmaVault(address(plasmaVault)).deposit(IwTAC(wTAC).balanceOf(user), user);
        vm.stopPrank();

        // Stake TAC
        TacStakingFuseEnterData memory enterData = TacStakingFuseEnterData({
            validator: VALIDATOR_ADDRESS,
            tacAmount: stakeAmount
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(tacStakingFuse),
            abi.encodeWithSignature("enter((address,uint256))", enterData)
        );

        vm.prank(alpha);
        plasmaVault.execute(enterCalls);

        // Unstake TAC (initiates unbonding)
        TacStakingFuseExitData memory exitData = TacStakingFuseExitData({
            validator: VALIDATOR_ADDRESS,
            wTacAmount: stakeAmount
        });

        FuseAction[] memory exitCalls = new FuseAction[](1);
        exitCalls[0] = FuseAction(
            address(tacStakingFuse),
            abi.encodeWithSignature("exit((address,uint256))", exitData)
        );

        vm.prank(alpha);
        plasmaVault.execute(exitCalls);

        // Get executor address using the reader
        address executor = tacStakingExecutorAddressReader.getTacStakingExecutorAddress(address(plasmaVault));

        // Simulate completion of unbonding period (21 days)
        vm.warp(block.timestamp + 21 days);

        uint256 executorNativeBalanceBefore = executor.balance;

        // Simulate the staking contract transferring native tokens to the executor
        // This would happen automatically in a real TAC network after the unbonding period
        vm.deal(executor, executorNativeBalanceBefore + stakeAmount);
        MockStaking(STAKING).evmMethodRemoveAllUnbondingDelegations(executor, VALIDATOR_OPERATOR_ADDRESS);

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = TAC_MARKET_ID;

        vm.prank(alpha);
        PlasmaVault(address(plasmaVault)).updateMarketsBalances(marketIds);

        uint256 vaultTotalAssetsBefore = PlasmaVault(address(plasmaVault)).totalAssets();
        uint256 userBalanceBefore = IwTAC(wTAC).balanceOf(user);

        uint256 userSharesBefore = PlasmaVault(address(plasmaVault)).balanceOf(user);

        // when
        vm.prank(user);
        PlasmaVault(address(plasmaVault)).redeem(userSharesBefore - 500, user, user);

        // then
        uint256 vaultTotalAssetsAfter = PlasmaVault(address(plasmaVault)).totalAssets();
        uint256 userBalanceAfter = IwTAC(wTAC).balanceOf(user);

        assertLt(
            vaultTotalAssetsAfter,
            vaultTotalAssetsBefore,
            "Vault total assets should be less than the initial balance"
        );
        assertGt(userBalanceAfter, userBalanceBefore, "User balance should be greater than the initial balance");
    }

    function testShouldExitExecutorSuccessfully() external {
        // given
        uint256 stakeAmount = 100;
        uint256 nativeAmount = 50;

        vm.deal(user, stakeAmount);

        vm.startPrank(user);
        IwTAC(wTAC).deposit{value: stakeAmount}();
        vm.stopPrank();

        vm.startPrank(atomist);
        accessManager.grantRole(Roles.WHITELIST_ROLE, user, 0);
        vm.stopPrank();

        vm.startPrank(user);
        IwTAC(wTAC).approve(address(plasmaVault), stakeAmount);
        vm.stopPrank();

        vm.startPrank(user);
        PlasmaVault(address(plasmaVault)).deposit(IwTAC(wTAC).balanceOf(user), user);
        vm.stopPrank();

        // Stake TAC
        TacStakingFuseEnterData memory enterData = TacStakingFuseEnterData({
            validator: VALIDATOR_ADDRESS,
            tacAmount: stakeAmount
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(tacStakingFuse),
            abi.encodeWithSignature("enter((address,uint256))", enterData)
        );

        vm.prank(alpha);
        plasmaVault.execute(enterCalls);

        // Get executor address using the reader
        address executor = tacStakingExecutorAddressReader.getTacStakingExecutorAddress(address(plasmaVault));

        // Simulate native tokens being sent to executor (e.g., from unbonding completion)
        vm.deal(executor, nativeAmount);

        // Record balances before exit
        uint256 executorNativeBalanceBefore = executor.balance;
        uint256 executorWTacBalanceBefore = IwTAC(wTAC).balanceOf(executor);
        uint256 vaultWTacBalanceBefore = IwTAC(wTAC).balanceOf(address(plasmaVault));

        // when
        FuseAction[] memory exitCalls = new FuseAction[](1);
        exitCalls[0] = FuseAction(address(tacStakingFuse), abi.encodeWithSignature("exit()"));

        vm.prank(alpha);
        plasmaVault.execute(exitCalls);

        // then
        uint256 executorNativeBalanceAfter = executor.balance;
        uint256 executorWTacBalanceAfter = IwTAC(wTAC).balanceOf(executor);
        uint256 vaultWTacBalanceAfter = IwTAC(wTAC).balanceOf(address(plasmaVault));

        // Executor should have no native tokens left
        assertEq(executorNativeBalanceAfter, 0, "Executor should have no native tokens after exit");

        // Executor should have no wTAC tokens left
        assertEq(executorWTacBalanceAfter, 0, "Executor should have no wTAC tokens after exit");

        // Vault should receive all tokens (native converted to wTAC + existing wTAC)
        assertEq(
            vaultWTacBalanceAfter,
            vaultWTacBalanceBefore + executorWTacBalanceBefore + nativeAmount,
            "Vault should receive all tokens from executor"
        );
    }

    function _setupFusionFactory() private {
        // Deploy factory contracts
        FusionFactoryStorageLib.FactoryAddresses memory factoryAddresses = FusionFactoryStorageLib.FactoryAddresses({
            accessManagerFactory: address(new AccessManagerFactory()),
            plasmaVaultFactory: address(new PlasmaVaultFactory()),
            feeManagerFactory: address(new FeeManagerFactory()),
            withdrawManagerFactory: address(new WithdrawManagerFactory()),
            rewardsManagerFactory: address(new RewardsManagerFactory()),
            contextManagerFactory: address(new ContextManagerFactory()),
            priceManagerFactory: address(new PriceManagerFactory())
        });

        address plasmaVaultBase = address(new PlasmaVaultBase());
        address burnRequestFeeFuse = address(new BurnRequestFeeFuse(IporFusionMarkets.ZERO_BALANCE_MARKET));
        address burnRequestFeeBalanceFuse = address(new ZeroBalanceFuse(IporFusionMarkets.ZERO_BALANCE_MARKET));

        PriceOracleMiddleware priceOracleMiddlewareImplementation = new PriceOracleMiddleware(address(0));
        address priceOracleMiddleware = address(
            new ERC1967Proxy(
                address(priceOracleMiddlewareImplementation),
                abi.encodeWithSignature("initialize(address)", atomist)
            )
        );

        // Deploy implementation and proxy for FusionFactory
        FusionFactory implementation = new FusionFactory();
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address[],(address,address,address,address,address,address,address),address,address,address,address)",
            atomist,
            new address[](0), // No plasma vault admins
            factoryAddresses,
            plasmaVaultBase,
            priceOracleMiddleware,
            burnRequestFeeFuse,
            burnRequestFeeBalanceFuse
        );
        fusionFactory = FusionFactory(address(new ERC1967Proxy(address(implementation), initData)));

        // Setup DAO fee
        vm.startPrank(atomist);
        fusionFactory.grantRole(fusionFactory.DAO_FEE_MANAGER_ROLE(), atomist);
        vm.stopPrank();

        vm.startPrank(atomist);
        fusionFactory.updateDaoFee(atomist, 100, 100);
        vm.stopPrank();
    }

    function _createVaultWithFusionFactory() private {
        // Create vault using FusionFactory
        FusionFactoryLib.FusionInstance memory instance = fusionFactory.create(
            "TAC Staking Vault",
            "tacVault",
            wTAC,
            1 seconds, // redemption delay
            atomist // owner
        );

        // Set the plasmaVault from the factory instance
        plasmaVault = PlasmaVault(instance.plasmaVault);
        accessManager = IporFusionAccessManager(instance.accessManager);
        withdrawManager = instance.withdrawManager;
        priceOracle = instance.priceManager;
    }

    function _addTacStakingFuses() private {
        // Add TAC staking fuses to the vault
        address[] memory fuses = new address[](1);
        fuses[0] = address(tacStakingFuse);

        vm.startPrank(atomist);
        PlasmaVaultGovernance(address(plasmaVault)).addFuses(fuses);
        PlasmaVaultGovernance(address(plasmaVault)).addBalanceFuse(TAC_MARKET_ID, address(tacStakingBalanceFuse));

        // Grant validator as substrate to the market
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(VALIDATOR_ADDRESS);
        PlasmaVaultGovernance(address(plasmaVault)).grantMarketSubstrates(TAC_MARKET_ID, substrates);
        vm.stopPrank();
    }

    function _setupRoles() private {
        // Grant atomist role to atomist address (needed to grant other roles)
        vm.prank(atomist);
        accessManager.grantRole(Roles.ATOMIST_ROLE, atomist, 0);

        // Grant alpha role to alpha address
        vm.prank(atomist);
        accessManager.grantRole(Roles.ALPHA_ROLE, alpha, 0);

        // Grant fuse manager role to atomist address (needed to add fuses)
        vm.prank(atomist);
        accessManager.grantRole(Roles.FUSE_MANAGER_ROLE, atomist, 0);

        // Grant instant withdrawal fuses role to atomist address (needed to configure instant withdrawal fuses)
        vm.prank(atomist);
        accessManager.grantRole(Roles.CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE, atomist, 0);

        // Grant PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE to atomist
        vm.startPrank(atomist);
        accessManager.grantRole(Roles.PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE, atomist, 0);
        vm.stopPrank();
    }
}
