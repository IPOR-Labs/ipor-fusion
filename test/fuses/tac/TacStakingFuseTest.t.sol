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
import {IStaking, Coin, UnbondingDelegationOutput} from "../../../contracts/fuses/tac/ext/IStaking.sol";
import {IPriceFeed} from "../../../contracts/price_oracle/price_feed/IPriceFeed.sol";
import {PriceOracleMiddlewareManager} from "../../../contracts/managers/price/PriceOracleMiddlewareManager.sol";
import {MockStaking} from "./MockStaking.sol";
import {TacStakingStorageLib} from "../../../contracts/fuses/tac/TacStakingStorageLib.sol";
import {TacStakingDelegatorAddressReader} from "../../../contracts/readers/TacStakingDelegatorAddressReader.sol";
import {InstantWithdrawalFusesParamsStruct} from "../../../contracts/libraries/PlasmaVaultLib.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {TacValidatorAddressConverter} from "../../../contracts/fuses/tac/TacValidatorAddressConverter.sol";
import {Description, CommissionRates} from "../../../contracts/fuses/tac/ext/IStaking.sol";
import {IporMath} from "../../../contracts/libraries/math/IporMath.sol";
import {IPriceOracleMiddleware} from "../../../contracts/price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultLib} from "../../../contracts/libraries/PlasmaVaultLib.sol";
import {TacStakingFuseEnterData, TacStakingFuseExitData, TacStakingFuseRedelegateData} from "../../../contracts/fuses/tac/TacStakingFuse.sol";
import {TacStakingDelegator} from "../../../contracts/fuses/tac/TacStakingDelegator.sol";
import {MockMaintenanceStakingFuse} from "./MockMaintenanceStakingFuse.sol";

interface IwTAC is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 wadAmount) external;
}

/// @notice Mock contract for testing executeBatch functionality
contract MockBatchTarget {
    uint256 public value;

    function setValue(uint256 _value) external {
        value = _value;
    }

    function getValue() external view returns (uint256) {
        return value;
    }

    function revertFunction() external pure {
        revert("MockBatchTarget: revertFunction called");
    }
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
    string constant VALIDATOR_ADDRESS_SRC_BECH32 = "tac1pdu86gjvnnr2786xtkw2eggxkmrsur0zjm6vxn";
    address constant VALIDATOR_ADDRESS_SRC_HEX = 0x78346FF37Ad8B536CE9551DEE5D037058d880300;

    string constant VALIDATOR_ADDRESS_DST_BECH32 = "tac1pdu86gjvnnr2786xtkw2eggxkmrsur0zjm6vxn3";
    address constant VALIDATOR_ADDRESS_DST_HEX = 0x78346fF37AD8B536CE9551dee5D037058D880302;

    uint256 constant TAC_MARKET_ID = IporFusionMarkets.TAC_STAKING;

    address alpha;
    address atomist;
    address user;

    PlasmaVault plasmaVault;
    TacStakingFuse tacStakingFuse;
    TacStakingBalanceFuse tacStakingBalanceFuse;
    IporFusionAccessManager accessManager;
    address withdrawManager;
    address priceOracle;

    FusionFactory fusionFactory;

    TacStakingDelegatorAddressReader tacStakingDelegatorAddressReader;
    MockMaintenanceStakingFuse mockMaintenanceStakingFuse;

    string[] validators;
    string[] validatorsSrc;
    string[] validatorsDst;
    uint256[] tacAmounts;
    string[] validatorsExit;
    uint256[] wTacAmounts;

    IStaking staking;

    uint256 stakeAmount;
    uint256 redelegateAmount;

    function setUp() public {
        vm.createSelectFork(vm.envString("TAC_PROVIDER_URL"));

        STAKING = address(new MockStaking(vm));

        IStaking stakingLocal = IStaking(STAKING);
        stakingLocal.createValidator(
            Description({moniker: "test", identity: "test", website: "test", securityContact: "test", details: "test"}),
            CommissionRates({rate: 1000, maxRate: 1000, maxChangeRate: 1000}),
            0,
            VALIDATOR_ADDRESS_SRC_HEX,
            VALIDATOR_ADDRESS_SRC_BECH32,
            0
        );

        alpha = address(0x555);
        atomist = address(0x777);

        user = address(0x333);

        _setupFusionFactory();

        _createVaultWithFusionFactory();

        tacStakingFuse = new TacStakingFuse(TAC_MARKET_ID, wTAC, STAKING);

        tacStakingBalanceFuse = new TacStakingBalanceFuse(TAC_MARKET_ID, STAKING, wTAC);

        tacStakingDelegatorAddressReader = new TacStakingDelegatorAddressReader();
        mockMaintenanceStakingFuse = new MockMaintenanceStakingFuse(TAC_MARKET_ID);

        _setupRoles();

        _addTacStakingFuses();

        // Add MockedMaintenanceStakingFuse as a supported fuse for executeBatch tests
        address[] memory maintenanceFuses = new address[](1);
        maintenanceFuses[0] = address(mockMaintenanceStakingFuse);
        vm.startPrank(atomist);
        PlasmaVaultGovernance(address(plasmaVault)).addFuses(maintenanceFuses);
        vm.stopPrank();

        address[] memory assets = new address[](1);
        assets[0] = wTAC;

        address[] memory sources = new address[](1);
        sources[0] = address(new MockPriceFeed());

        vm.startPrank(atomist);
        PriceOracleMiddlewareManager(address(priceOracle)).setAssetsPriceSources(assets, sources);
        vm.stopPrank();

        FuseAction[] memory createDelegatorCalls = new FuseAction[](1);
        createDelegatorCalls[0] = FuseAction(address(tacStakingFuse), abi.encodeWithSignature("createDelegator()"));
        vm.prank(alpha);
        plasmaVault.execute(createDelegatorCalls);

        validators = new string[](1);
        tacAmounts = new uint256[](1);
        validatorsSrc = new string[](1);
        validatorsDst = new string[](1);
        validatorsExit = new string[](1);
        wTacAmounts = new uint256[](1);
    }

    function testShouldRevertWhenCreatingDelegatorTwice() external {
        // given - delegator is already created in setUp()
        FuseAction[] memory createDelegatorCalls = new FuseAction[](1);
        createDelegatorCalls[0] = FuseAction(address(tacStakingFuse), abi.encodeWithSignature("createDelegator()"));

        // when & then - should revert with TacStakingFuseDelegatorAlreadyCreated error
        vm.prank(alpha);
        vm.expectRevert(abi.encodeWithSelector(TacStakingFuse.TacStakingFuseDelegatorAlreadyCreated.selector));
        plasmaVault.execute(createDelegatorCalls);
    }

    // TacStakingDelegator executeBatch tests
    function testShouldExecuteBatchSuccessfully() external {
        // given
        // Create a mock contract for testing
        MockBatchTarget mockTarget = new MockBatchTarget();

        address[] memory targets = new address[](2);
        targets[0] = address(mockTarget);
        targets[1] = address(mockTarget);

        bytes[] memory calldatas = new bytes[](2);
        calldatas[0] = abi.encodeWithSignature("setValue(uint256)", 42);
        calldatas[1] = abi.encodeWithSignature("setValue(uint256)", 100);

        FuseAction[] memory executeBatchCalls = new FuseAction[](1);
        executeBatchCalls[0] = FuseAction(
            address(mockMaintenanceStakingFuse),
            abi.encodeWithSignature("executeBatch(address[],bytes[])", targets, calldatas)
        );

        // when
        vm.prank(alpha);
        plasmaVault.execute(executeBatchCalls);

        // then
        assertEq(mockTarget.value(), 100, "Last call should set the value to 100");
    }

    function testShouldExecuteBatchWithReturnValues() external {
        // given
        MockBatchTarget mockTarget = new MockBatchTarget();
        mockTarget.setValue(50);

        address[] memory targets = new address[](1);
        targets[0] = address(mockTarget);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("getValue()");

        FuseAction[] memory executeBatchCalls = new FuseAction[](1);
        executeBatchCalls[0] = FuseAction(
            address(mockMaintenanceStakingFuse),
            abi.encodeWithSignature("executeBatch(address[],bytes[])", targets, calldatas)
        );

        // when
        vm.prank(alpha);
        plasmaVault.execute(executeBatchCalls);

        // then - we can't easily get return values through the PlasmaVault execute mechanism
        // but we can verify the call was successful by checking the mock target state
        assertEq(mockTarget.value(), 50, "Mock target value should remain unchanged");
    }

    function testShouldRevertWhenArrayLengthsMismatch() external {
        // given
        address[] memory targets = new address[](2);
        targets[0] = address(0x123);
        targets[1] = address(0x456);

        bytes[] memory calldatas = new bytes[](1); // Mismatch: only 1 calldata for 2 targets
        calldatas[0] = abi.encodeWithSignature("someFunction()");

        FuseAction[] memory executeBatchCalls = new FuseAction[](1);
        executeBatchCalls[0] = FuseAction(
            address(mockMaintenanceStakingFuse),
            abi.encodeWithSignature("executeBatch(address[],bytes[])", targets, calldatas)
        );

        // when & then
        vm.prank(alpha);
        vm.expectRevert(abi.encodeWithSelector(TacStakingDelegator.TacStakingDelegatorInvalidArrayLength.selector));
        plasmaVault.execute(executeBatchCalls);
    }

    function testShouldRevertWhenTargetAddressIsZero() external {
        // given
        address[] memory targets = new address[](1);
        targets[0] = address(0); // Zero address

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("someFunction()");

        FuseAction[] memory executeBatchCalls = new FuseAction[](1);
        executeBatchCalls[0] = FuseAction(
            address(mockMaintenanceStakingFuse),
            abi.encodeWithSignature("executeBatch(address[],bytes[])", targets, calldatas)
        );

        // when & then
        vm.prank(alpha);
        vm.expectRevert(abi.encodeWithSelector(TacStakingDelegator.TacStakingDelegatorInvalidTargetAddress.selector));
        plasmaVault.execute(executeBatchCalls);
    }

    function testShouldRevertWhenCalledByNonPlasmaVault() external {
        // given
        address[] memory targets = new address[](1);
        targets[0] = address(0x123);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("someFunction()");

        FuseAction[] memory executeBatchCalls = new FuseAction[](1);
        executeBatchCalls[0] = FuseAction(
            address(mockMaintenanceStakingFuse),
            abi.encodeWithSignature("executeBatch(address[],bytes[])", targets, calldatas)
        );

        // when & then - should revert when called by non-authorized user
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSignature("AccessManagedUnauthorized(address)", user));
        plasmaVault.execute(executeBatchCalls);
    }

    function testShouldExecuteBatchWithEmptyArrays() external {
        // given
        address[] memory targets = new address[](0);
        bytes[] memory calldatas = new bytes[](0);

        FuseAction[] memory executeBatchCalls = new FuseAction[](1);
        executeBatchCalls[0] = FuseAction(
            address(mockMaintenanceStakingFuse),
            abi.encodeWithSignature("executeBatch(address[],bytes[])", targets, calldatas)
        );

        // when
        vm.prank(alpha);
        plasmaVault.execute(executeBatchCalls);

        // then - should execute successfully with empty arrays
        // We can't easily get return values through the PlasmaVault execute mechanism
        // but we can verify the call was successful by not reverting
    }

    function testShouldExecuteBatchWithRevertingCall() external {
        // given
        MockBatchTarget mockTarget = new MockBatchTarget();

        address[] memory targets = new address[](1);
        targets[0] = address(mockTarget);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("revertFunction()");

        FuseAction[] memory executeBatchCalls = new FuseAction[](1);
        executeBatchCalls[0] = FuseAction(
            address(mockMaintenanceStakingFuse),
            abi.encodeWithSignature("executeBatch(address[],bytes[])", targets, calldatas)
        );

        // when & then - should revert when the target function reverts
        vm.prank(alpha);
        vm.expectRevert("MockBatchTarget: revertFunction called");
        plasmaVault.execute(executeBatchCalls);
    }

    function testShouldExecuteBatchWithMultipleTargets() external {
        // given
        MockBatchTarget mockTarget1 = new MockBatchTarget();
        MockBatchTarget mockTarget2 = new MockBatchTarget();
        MockBatchTarget mockTarget3 = new MockBatchTarget();

        address[] memory targets = new address[](3);
        targets[0] = address(mockTarget1);
        targets[1] = address(mockTarget2);
        targets[2] = address(mockTarget3);

        bytes[] memory calldatas = new bytes[](3);
        calldatas[0] = abi.encodeWithSignature("setValue(uint256)", 10);
        calldatas[1] = abi.encodeWithSignature("setValue(uint256)", 20);
        calldatas[2] = abi.encodeWithSignature("setValue(uint256)", 30);

        FuseAction[] memory executeBatchCalls = new FuseAction[](1);
        executeBatchCalls[0] = FuseAction(
            address(mockMaintenanceStakingFuse),
            abi.encodeWithSignature("executeBatch(address[],bytes[])", targets, calldatas)
        );

        // when
        vm.prank(alpha);
        plasmaVault.execute(executeBatchCalls);

        // then
        assertEq(mockTarget1.value(), 10, "First target should have value 10");
        assertEq(mockTarget2.value(), 20, "Second target should have value 20");
        assertEq(mockTarget3.value(), 30, "Third target should have value 30");
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

        validators[0] = VALIDATOR_ADDRESS_SRC_BECH32;
        tacAmounts[0] = stakeAmount;

        TacStakingFuseEnterData memory enterData = TacStakingFuseEnterData({
            validatorAddresses: validators,
            wTacAmounts: tacAmounts
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(tacStakingFuse),
            abi.encodeWithSignature("enter((string[],uint256[]))", enterData)
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

        validators[0] = VALIDATOR_ADDRESS_SRC_BECH32;
        tacAmounts[0] = stakeAmount;

        TacStakingFuseEnterData memory enterData = TacStakingFuseEnterData({
            validatorAddresses: validators,
            wTacAmounts: tacAmounts
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(tacStakingFuse),
            abi.encodeWithSignature("enter((string[],uint256[]))", enterData)
        );

        vm.prank(alpha);
        plasmaVault.execute(enterCalls);

        uint256 unstakeAmount = stakeAmount;

        validatorsExit[0] = VALIDATOR_ADDRESS_SRC_BECH32;
        wTacAmounts[0] = unstakeAmount;

        TacStakingFuseExitData memory exitData = TacStakingFuseExitData({
            validatorAddresses: validatorsExit,
            wTacAmounts: wTacAmounts
        });

        FuseAction[] memory exitCalls = new FuseAction[](1);
        exitCalls[0] = FuseAction(
            address(tacStakingFuse),
            abi.encodeWithSignature("exit((string[],uint256[]))", exitData)
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

        validators[0] = VALIDATOR_ADDRESS_SRC_BECH32;
        tacAmounts[0] = stakeAmount;

        TacStakingFuseEnterData memory enterData = TacStakingFuseEnterData({
            validatorAddresses: validators,
            wTacAmounts: tacAmounts
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(tacStakingFuse),
            abi.encodeWithSignature("enter((string[],uint256[]))", enterData)
        );

        vm.prank(alpha);
        plasmaVault.execute(enterCalls);

        uint256 vaultTotalAssetsBefore = PlasmaVault(address(plasmaVault)).totalAssets();
        uint256 balanceInMarketBefore = PlasmaVault(address(plasmaVault)).totalAssetsInMarket(TAC_MARKET_ID);

        // Unstake TAC (initiates unbonding)
        validatorsExit[0] = VALIDATOR_ADDRESS_SRC_BECH32;
        wTacAmounts[0] = stakeAmount;
        TacStakingFuseExitData memory exitData = TacStakingFuseExitData({
            validatorAddresses: validatorsExit,
            wTacAmounts: wTacAmounts
        });

        FuseAction[] memory exitCalls = new FuseAction[](1);
        exitCalls[0] = FuseAction(
            address(tacStakingFuse),
            abi.encodeWithSignature("exit((string[],uint256[]))", exitData)
        );

        vm.prank(alpha);
        plasmaVault.execute(exitCalls);

        uint256 vaultTotalAssetsAfter = PlasmaVault(address(plasmaVault)).totalAssets();
        uint256 balanceInMarketAfter = PlasmaVault(address(plasmaVault)).totalAssetsInMarket(TAC_MARKET_ID);

        address delegator = tacStakingDelegatorAddressReader.getTacStakingDelegatorAddress(address(plasmaVault));

        uint256 delegatorNativeBalanceBefore = delegator.balance;
        uint256 vaultWTacBalanceBefore = IwTAC(wTAC).balanceOf(address(plasmaVault));

        // Simulate completion of unbonding period (21 days)
        vm.warp(block.timestamp + 21 days);

        // when
        // Simulate the staking contract transferring native tokens to the delegator
        // This would happen automatically in a real TAC network after the unbonding period
        vm.deal(delegator, delegatorNativeBalanceBefore + stakeAmount);
        MockStaking(STAKING).evmMethodRemoveAllUnbondingDelegations(delegator, VALIDATOR_ADDRESS_SRC_BECH32);

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = TAC_MARKET_ID;

        vm.prank(alpha);
        PlasmaVault(address(plasmaVault)).updateMarketsBalances(marketIds);

        // then
        uint256 vaultTotalAssetsAfterUnbonding = PlasmaVault(address(plasmaVault)).totalAssets(); ///????

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

    function testShouldIncreaseVaultBalanceWhenTransferNativeTokenToDelegator() external {
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

        address delegator = tacStakingDelegatorAddressReader.getTacStakingDelegatorAddress(address(plasmaVault));

        uint256 vaultTotalAssetsBefore = PlasmaVault(address(plasmaVault)).totalAssets();

        // when
        vm.deal(delegator, stakeAmount);

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

    function testShouldGetDelegatorAddressUsingReader() external {
        // given - delegator is created in setUp()

        // when
        address delegator = tacStakingDelegatorAddressReader.getTacStakingDelegatorAddress(address(plasmaVault));

        // then
        assertTrue(delegator != address(0), "Delegator address should not be zero");
    }

    function testShouldInstantWithdrawTacSuccessfully() external {
        // given
        uint256 stakeAmount = 100;

        InstantWithdrawalFusesParamsStruct[] memory instantWithdrawFuses = new InstantWithdrawalFusesParamsStruct[](1);
        bytes32[] memory instantWithdrawParams = new bytes32[](1);
        instantWithdrawParams[0] = bytes32(stakeAmount);

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

        validators[0] = VALIDATOR_ADDRESS_SRC_BECH32;
        tacAmounts[0] = stakeAmount;

        TacStakingFuseEnterData memory enterData = TacStakingFuseEnterData({
            validatorAddresses: validators,
            wTacAmounts: tacAmounts
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(tacStakingFuse),
            abi.encodeWithSignature("enter((string[],uint256[]))", enterData)
        );

        vm.prank(alpha);
        plasmaVault.execute(enterCalls);

        validatorsExit[0] = VALIDATOR_ADDRESS_SRC_BECH32;
        wTacAmounts[0] = stakeAmount;
        TacStakingFuseExitData memory exitData = TacStakingFuseExitData({
            validatorAddresses: validatorsExit,
            wTacAmounts: wTacAmounts
        });

        FuseAction[] memory exitCalls = new FuseAction[](1);
        exitCalls[0] = FuseAction(
            address(tacStakingFuse),
            abi.encodeWithSignature("exit((string[],uint256[]))", exitData)
        );

        vm.prank(alpha);
        plasmaVault.execute(exitCalls);

        address delegator = tacStakingDelegatorAddressReader.getTacStakingDelegatorAddress(address(plasmaVault));

        // Simulate completion of unbonding period (21 days)
        vm.warp(block.timestamp + 21 days);

        uint256 delegatorNativeBalanceBefore = delegator.balance;

        // Simulate the staking contract transferring native tokens to the delegator
        // This would happen automatically in a real TAC network after the unbonding period
        vm.deal(delegator, delegatorNativeBalanceBefore + stakeAmount);
        MockStaking(STAKING).evmMethodRemoveAllUnbondingDelegations(delegator, VALIDATOR_ADDRESS_SRC_BECH32);

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

    function testShouldExitDelegatorSuccessfully() external {
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
        validators[0] = VALIDATOR_ADDRESS_SRC_BECH32;
        tacAmounts[0] = stakeAmount;

        TacStakingFuseEnterData memory enterData = TacStakingFuseEnterData({
            validatorAddresses: validators,
            wTacAmounts: tacAmounts
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(tacStakingFuse),
            abi.encodeWithSignature("enter((string[],uint256[]))", enterData)
        );

        vm.prank(alpha);
        plasmaVault.execute(enterCalls);

        address delegator = tacStakingDelegatorAddressReader.getTacStakingDelegatorAddress(address(plasmaVault));

        // Simulate native tokens being sent to delegator (e.g., from unbonding completion)
        vm.deal(delegator, nativeAmount);

        // Record balances before exit
        uint256 delegatorNativeBalanceBefore = delegator.balance;
        uint256 delegatorWTacBalanceBefore = IwTAC(wTAC).balanceOf(delegator);
        uint256 vaultWTacBalanceBefore = IwTAC(wTAC).balanceOf(address(plasmaVault));

        // when
        FuseAction[] memory exitCalls = new FuseAction[](1);
        exitCalls[0] = FuseAction(address(tacStakingFuse), abi.encodeWithSignature("emergencyExit()"));

        vm.prank(alpha);
        plasmaVault.execute(exitCalls);

        // then
        uint256 delegatorNativeBalanceAfter = delegator.balance;
        uint256 delegatorWTacBalanceAfter = IwTAC(wTAC).balanceOf(delegator);
        uint256 vaultWTacBalanceAfter = IwTAC(wTAC).balanceOf(address(plasmaVault));

        assertEq(delegatorNativeBalanceAfter, 0, "Delegator should have no native tokens after exit");

        assertEq(delegatorWTacBalanceAfter, 0, "Delegator should have no wTAC tokens after exit");

        // Vault should receive all tokens (native converted to wTAC + existing wTAC)
        assertEq(
            vaultWTacBalanceAfter,
            vaultWTacBalanceBefore + delegatorWTacBalanceBefore + nativeAmount,
            "Vault should receive all tokens from delegator"
        );
    }

    function testShouldRedelegateTacSuccessfully() external {
        // given
        uint256 stakeAmount = 100;

        IStaking staking = IStaking(STAKING);
        staking.createValidator(
            Description({
                moniker: "test2",
                identity: "test2",
                website: "test2",
                securityContact: "test2",
                details: "test2"
            }),
            CommissionRates({rate: 1000, maxRate: 1000, maxChangeRate: 1000}),
            0,
            VALIDATOR_ADDRESS_DST_HEX,
            VALIDATOR_ADDRESS_DST_BECH32,
            0
        );

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

        vm.startPrank(atomist);
        bytes32[] memory secondSubstrates = new bytes32[](4);

        (bytes32 firstSlot2, bytes32 secondSlot2) = TacValidatorAddressConverter.validatorAddressToBytes32(
            VALIDATOR_ADDRESS_DST_BECH32
        );

        (bytes32 thirdSlot, bytes32 fourthSlot) = TacValidatorAddressConverter.validatorAddressToBytes32(
            VALIDATOR_ADDRESS_SRC_BECH32
        );

        secondSubstrates[0] = firstSlot2;
        secondSubstrates[1] = secondSlot2;
        secondSubstrates[2] = thirdSlot;
        secondSubstrates[3] = fourthSlot;

        PlasmaVaultGovernance(address(plasmaVault)).grantMarketSubstrates(TAC_MARKET_ID, secondSubstrates);
        vm.stopPrank();

        validators[0] = VALIDATOR_ADDRESS_SRC_BECH32;
        tacAmounts[0] = stakeAmount;

        TacStakingFuseEnterData memory enterData = TacStakingFuseEnterData({
            validatorAddresses: validators,
            wTacAmounts: tacAmounts
        });

        FuseAction[] memory delegateCalls = new FuseAction[](1);
        delegateCalls[0] = FuseAction(
            address(tacStakingFuse),
            abi.encodeWithSignature("enter((string[],uint256[]))", enterData)
        );

        vm.prank(alpha);
        plasmaVault.execute(delegateCalls);

        uint256 vaultTotalAssetsBeforeRedelegate = PlasmaVault(address(plasmaVault)).totalAssets();
        uint256 balanceInMarketBeforeRedelegate = PlasmaVault(address(plasmaVault)).totalAssetsInMarket(TAC_MARKET_ID);

        validatorsSrc[0] = VALIDATOR_ADDRESS_SRC_BECH32;
        validatorsDst[0] = VALIDATOR_ADDRESS_DST_BECH32;
        tacAmounts[0] = stakeAmount;

        TacStakingFuseRedelegateData memory redelegateData = TacStakingFuseRedelegateData({
            validatorSrcAddresses: validatorsSrc,
            validatorDstAddresses: validatorsDst,
            wTacAmounts: tacAmounts
        });

        FuseAction[] memory redelegateCalls = new FuseAction[](1);
        redelegateCalls[0] = FuseAction(
            address(tacStakingFuse),
            abi.encodeWithSignature("redelegate((string[],string[],uint256[]))", redelegateData)
        );

        // when
        vm.prank(alpha);
        plasmaVault.execute(redelegateCalls);

        // then
        uint256 vaultTotalAssetsAfterRedelegate = PlasmaVault(address(plasmaVault)).totalAssets();
        uint256 balanceInMarketAfterRedelegate = PlasmaVault(address(plasmaVault)).totalAssetsInMarket(TAC_MARKET_ID);

        assertEq(
            vaultTotalAssetsAfterRedelegate,
            vaultTotalAssetsBeforeRedelegate,
            "Vault total assets should remain unchanged after redelegation"
        );
        assertEq(
            balanceInMarketAfterRedelegate,
            balanceInMarketBeforeRedelegate,
            "Balance in market should remain unchanged after redelegation"
        );
    }

    function testShouldRedelegateWithPartialAmountSuccessfully() external {
        // given
        stakeAmount = 100;
        redelegateAmount = 50;

        staking = IStaking(STAKING);
        staking.createValidator(
            Description({
                moniker: "test3",
                identity: "test3",
                website: "test3",
                securityContact: "test3",
                details: "test3"
            }),
            CommissionRates({rate: 1000, maxRate: 1000, maxChangeRate: 1000}),
            0,
            VALIDATOR_ADDRESS_DST_HEX,
            VALIDATOR_ADDRESS_DST_BECH32,
            0
        );

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

        vm.startPrank(atomist);
        bytes32[] memory secondSubstrates = new bytes32[](4);
        (bytes32 firstSlot2, bytes32 secondSlot2) = TacValidatorAddressConverter.validatorAddressToBytes32(
            VALIDATOR_ADDRESS_DST_BECH32
        );
        (bytes32 thirdSlot, bytes32 fourthSlot) = TacValidatorAddressConverter.validatorAddressToBytes32(
            VALIDATOR_ADDRESS_SRC_BECH32
        );
        secondSubstrates[0] = firstSlot2;
        secondSubstrates[1] = secondSlot2;
        secondSubstrates[2] = thirdSlot;
        secondSubstrates[3] = fourthSlot;

        PlasmaVaultGovernance(address(plasmaVault)).grantMarketSubstrates(TAC_MARKET_ID, secondSubstrates);
        vm.stopPrank();

        validators[0] = VALIDATOR_ADDRESS_SRC_BECH32;
        tacAmounts[0] = stakeAmount;

        TacStakingFuseEnterData memory enterData = TacStakingFuseEnterData({
            validatorAddresses: validators,
            wTacAmounts: tacAmounts
        });

        FuseAction[] memory delegateCalls = new FuseAction[](1);
        delegateCalls[0] = FuseAction(
            address(tacStakingFuse),
            abi.encodeWithSignature("enter((string[],uint256[]))", enterData)
        );

        vm.prank(alpha);
        plasmaVault.execute(delegateCalls);

        uint256 vaultTotalAssetsBeforeRedelegate = PlasmaVault(address(plasmaVault)).totalAssets();
        uint256 balanceInMarketBeforeRedelegate = PlasmaVault(address(plasmaVault)).totalAssetsInMarket(TAC_MARKET_ID);

        validatorsSrc[0] = VALIDATOR_ADDRESS_SRC_BECH32;
        validatorsDst[0] = VALIDATOR_ADDRESS_DST_BECH32;
        tacAmounts[0] = redelegateAmount;

        TacStakingFuseRedelegateData memory redelegateData = TacStakingFuseRedelegateData({
            validatorSrcAddresses: validatorsSrc,
            validatorDstAddresses: validatorsDst,
            wTacAmounts: tacAmounts
        });
        FuseAction[] memory redelegateCalls = new FuseAction[](1);
        redelegateCalls[0] = FuseAction(
            address(tacStakingFuse),
            abi.encodeWithSignature("redelegate((string[],string[],uint256[]))", redelegateData)
        );

        // Check delegation before redelegation
        address delegator = tacStakingDelegatorAddressReader.getTacStakingDelegatorAddress(address(plasmaVault));
        (uint256 sharesSrcBefore, ) = IStaking(STAKING).delegation(delegator, VALIDATOR_ADDRESS_SRC_BECH32);
        (uint256 sharesDstBefore, ) = IStaking(STAKING).delegation(delegator, VALIDATOR_ADDRESS_DST_BECH32);

        // when
        vm.prank(alpha);
        plasmaVault.execute(redelegateCalls);

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = TAC_MARKET_ID;

        vm.startPrank(atomist);
        accessManager.grantRole(Roles.UPDATE_MARKETS_BALANCES_ROLE, alpha, 0);
        vm.stopPrank();

        vm.prank(alpha);
        plasmaVault.updateMarketsBalances(marketIds);

        // then
        uint256 vaultTotalAssetsAfterRedelegate = PlasmaVault(address(plasmaVault)).totalAssets();
        uint256 balanceInMarketAfterRedelegate = PlasmaVault(address(plasmaVault)).totalAssetsInMarket(TAC_MARKET_ID);

        assertEq(
            vaultTotalAssetsAfterRedelegate,
            vaultTotalAssetsBeforeRedelegate,
            "Vault total assets should remain unchanged after partial redelegation"
        );
        assertEq(
            balanceInMarketAfterRedelegate,
            balanceInMarketBeforeRedelegate,
            "Balance in market should remain unchanged after partial redelegation"
        );

        // Verify that the remaining balance is still delegated to the original validator
        // and the redelegated amount is now with the second validator
        (uint256 sharesSrc, ) = IStaking(STAKING).delegation(delegator, VALIDATOR_ADDRESS_SRC_BECH32);
        (uint256 sharesDst, ) = IStaking(STAKING).delegation(delegator, VALIDATOR_ADDRESS_DST_BECH32);

        assertEq(sharesSrc, stakeAmount - redelegateAmount, "Source validator should have remaining delegation");

        assertEq(sharesDst, redelegateAmount, "Destination validator should have redelegated amount");
    }

    function _setupFusionFactory() private {
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

        vm.startPrank(atomist);
        fusionFactory.grantRole(fusionFactory.DAO_FEE_MANAGER_ROLE(), atomist);
        vm.stopPrank();

        vm.startPrank(atomist);
        fusionFactory.updateDaoFee(atomist, 100, 100);
        vm.stopPrank();
    }

    function _createVaultWithFusionFactory() private {
        FusionFactoryLib.FusionInstance memory instance = fusionFactory.create(
            "TAC Staking Vault",
            "tacVault",
            wTAC,
            1 seconds,
            atomist
        );

        plasmaVault = PlasmaVault(instance.plasmaVault);
        accessManager = IporFusionAccessManager(instance.accessManager);
        withdrawManager = instance.withdrawManager;
        priceOracle = instance.priceManager;
    }

    function _addTacStakingFuses() private {
        address[] memory fuses = new address[](1);
        fuses[0] = address(tacStakingFuse);

        vm.startPrank(atomist);
        PlasmaVaultGovernance(address(plasmaVault)).addFuses(fuses);
        PlasmaVaultGovernance(address(plasmaVault)).addBalanceFuse(TAC_MARKET_ID, address(tacStakingBalanceFuse));

        bytes32[] memory substrates = new bytes32[](4);
        (bytes32 firstSlot, bytes32 secondSlot) = TacValidatorAddressConverter.validatorAddressToBytes32(
            VALIDATOR_ADDRESS_SRC_BECH32
        );
        (bytes32 thirdSlot, bytes32 fourthSlot) = TacValidatorAddressConverter.validatorAddressToBytes32(
            VALIDATOR_ADDRESS_DST_BECH32
        );
        substrates[0] = firstSlot;
        substrates[1] = secondSlot;
        substrates[2] = thirdSlot;
        substrates[3] = fourthSlot;

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
