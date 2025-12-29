// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ExchangeRateValidatorPreHook} from "../../contracts/handlers/pre_hooks/pre_hooks/ExchangeRateValidatorPreHook.sol";
import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ExchangeRateValidatorConfigLib, ExchangeRateValidatorConfig, HookType, ValidatorData, Hook} from "../../contracts/handlers/pre_hooks/pre_hooks/ExchangeRateValidatorConfigLib.sol";
import {SimpleExecutePreHook} from "./SimpleExecutePreHook.sol";

/// @title ExchangeRateValidatorPreHookTest
/// @notice Tests for ExchangeRateValidatorPreHook
contract ExchangeRateValidatorPreHookTest is Test {
    ExchangeRateValidatorPreHook private _exchangeRateValidatorPreHook;
    IporFusionAccessManager private _accessManager;
    address private constant PLASMA_VAULT = 0x6f66b845604dad6E80b2A1472e6cAcbbE66A8C40;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    address private constant ATOMIST = 0x8c52fE65e3AfE15392F23536aAd128edE9aE4102;
    address private constant OWNER = 0xf2C6a2225BE9829eD77263b032E3D92C52aE6694;
    address private constant USER = 0x1212121212121212121212121212121212121212;

    /// @notice Sets up the test environment by forking Ethereum mainnet
    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 23739479);

        _accessManager = IporFusionAccessManager(PlasmaVault(PLASMA_VAULT).authority());

        vm.startPrank(OWNER);
        _exchangeRateValidatorPreHook = new ExchangeRateValidatorPreHook(IporFusionMarkets.EXCHANGE_RATE_VALIDATOR);
        _accessManager.grantRole(Roles.PRE_HOOKS_MANAGER_ROLE, ATOMIST, 0);
        vm.stopPrank();

        // Add pre-hook to deposit function
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = PlasmaVault.deposit.selector;

        address[] memory preHooks = new address[](1);
        preHooks[0] = address(_exchangeRateValidatorPreHook);

        bytes32[][] memory substrates = new bytes32[][](1);
        substrates[0] = new bytes32[](0);

        vm.startPrank(ATOMIST);
        PlasmaVaultGovernance(PLASMA_VAULT).setPreHookImplementations(selectors, preHooks, substrates);
        vm.stopPrank();
    }

    /// @notice Test that user can deposit when pre-hook has no substrates configured
    /// @dev When substrates.length == 0, pre-hook should return early and allow deposit
    function testShouldAllowDepositWhenPreHookHasNoSubstrates() public {
        // given - ensure user has USDC
        uint256 depositAmount = 10_000e6;
        deal(USDC, USER, depositAmount);

        uint256 vaultTotalAssetsBefore = PlasmaVault(PLASMA_VAULT).totalAssets();
        uint256 userVaultBalanceBefore = PlasmaVault(PLASMA_VAULT).balanceOf(USER);
        uint256 userUsdcBalanceBefore = IERC20(USDC).balanceOf(USER);

        // when - user approves and deposits
        vm.startPrank(USER);
        IERC20(USDC).approve(PLASMA_VAULT, depositAmount);
        PlasmaVault(PLASMA_VAULT).deposit(depositAmount, USER);
        vm.stopPrank();

        // then - verify deposit succeeded
        uint256 vaultTotalAssetsAfter = PlasmaVault(PLASMA_VAULT).totalAssets();
        uint256 userVaultBalanceAfter = PlasmaVault(PLASMA_VAULT).balanceOf(USER);
        uint256 userUsdcBalanceAfter = IERC20(USDC).balanceOf(USER);

        // Vault should have received the deposit
        assertGt(vaultTotalAssetsAfter, vaultTotalAssetsBefore, "Vault total assets should increase");

        // User should have received vault shares
        assertGt(userVaultBalanceAfter, userVaultBalanceBefore, "User vault balance should increase");

        // User's USDC should be transferred to vault
        assertEq(userUsdcBalanceAfter, userUsdcBalanceBefore - depositAmount, "User USDC balance should decrease");
    }

    /// @notice Test that user can deposit when pre-hook has substrate with current exchange rate and 1% threshold
    /// @dev Sets up validator substrate with current exchange rate and 1% threshold, then verifies deposit succeeds
    function testShouldAllowDepositWhenPreHookHasSubstrateWithCurrentExchangeRate() public {
        // given - calculate current exchange rate
        PlasmaVault plasmaVault = PlasmaVault(PLASMA_VAULT);
        uint256 currentExchangeRate = plasmaVault.convertToAssets(10 ** plasmaVault.decimals());

        // 1% threshold in 1e18 precision (0.01e18 = 1e16)
        uint120 threshold = 1e16;

        // Create validator data with current exchange rate and 1% threshold
        ValidatorData memory validatorData = ValidatorData({
            exchangeRate: uint128(currentExchangeRate),
            threshold: threshold
        });

        // Encode validator data to bytes31
        bytes31 validatorDataBytes = ExchangeRateValidatorConfigLib.validatorDataToBytes31(validatorData);

        // Create ExchangeRateValidatorConfig with VALIDATOR type
        ExchangeRateValidatorConfig memory config = ExchangeRateValidatorConfig({
            typ: HookType.VALIDATOR,
            data: validatorDataBytes
        });

        // Encode config to bytes32
        bytes32 substrate = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(config);

        // Add substrate to market EXCHANGE_RATE_VALIDATOR
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = substrate;

        vm.startPrank(ATOMIST);
        PlasmaVaultGovernance(PLASMA_VAULT).grantMarketSubstrates(
            IporFusionMarkets.EXCHANGE_RATE_VALIDATOR,
            substrates
        );
        vm.stopPrank();

        // Ensure user has USDC
        uint256 depositAmount = 10_000e6;
        deal(USDC, USER, depositAmount);

        uint256 vaultTotalAssetsBefore = plasmaVault.totalAssets();
        uint256 userVaultBalanceBefore = plasmaVault.balanceOf(USER);
        uint256 userUsdcBalanceBefore = IERC20(USDC).balanceOf(USER);

        // when - user approves and deposits
        vm.startPrank(USER);
        IERC20(USDC).approve(PLASMA_VAULT, depositAmount);
        plasmaVault.deposit(depositAmount, USER);
        vm.stopPrank();

        // then - verify deposit succeeded
        uint256 vaultTotalAssetsAfter = plasmaVault.totalAssets();
        uint256 userVaultBalanceAfter = plasmaVault.balanceOf(USER);
        uint256 userUsdcBalanceAfter = IERC20(USDC).balanceOf(USER);

        // Vault should have received the deposit
        assertGt(vaultTotalAssetsAfter, vaultTotalAssetsBefore, "Vault total assets should increase");

        // User should have received vault shares
        assertGt(userVaultBalanceAfter, userVaultBalanceBefore, "User vault balance should increase");

        // User's USDC should be transferred to vault
        assertEq(userUsdcBalanceAfter, userUsdcBalanceBefore - depositAmount, "User USDC balance should decrease");
    }

    /// @notice Test that deposit should fail when pre-hook has substrate with exchange rate more than 1% higher than current
    /// @dev Sets up validator substrate with exchange rate 2% higher than current and 1% threshold, then verifies deposit reverts
    function testShouldRevertDepositWhenPreHookHasSubstrateWithExchangeRateMoreThanThreshold() public {
        // given - calculate current exchange rate
        PlasmaVault plasmaVault = PlasmaVault(PLASMA_VAULT);
        uint256 currentExchangeRate = plasmaVault.convertToAssets(10 ** plasmaVault.decimals());

        // Set expected exchange rate to 2% higher than current (more than 1% threshold)
        // Using 1e18 precision: 2% = 0.02e18 = 2e16
        uint256 expectedExchangeRate = (currentExchangeRate * 102e16) / 1e18;

        // 1% threshold in 1e18 precision (0.01e18 = 1e16)
        uint120 threshold = 1e16;

        // Create validator data with exchange rate 2% higher than current and 1% threshold
        ValidatorData memory validatorData = ValidatorData({
            exchangeRate: uint128(expectedExchangeRate),
            threshold: threshold
        });

        // Encode validator data to bytes31
        bytes31 validatorDataBytes = ExchangeRateValidatorConfigLib.validatorDataToBytes31(validatorData);

        // Create ExchangeRateValidatorConfig with VALIDATOR type
        ExchangeRateValidatorConfig memory config = ExchangeRateValidatorConfig({
            typ: HookType.VALIDATOR,
            data: validatorDataBytes
        });

        // Encode config to bytes32
        bytes32 substrate = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(config);

        // Add substrate to market EXCHANGE_RATE_VALIDATOR
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = substrate;

        vm.startPrank(ATOMIST);
        PlasmaVaultGovernance(PLASMA_VAULT).grantMarketSubstrates(
            IporFusionMarkets.EXCHANGE_RATE_VALIDATOR,
            substrates
        );
        vm.stopPrank();

        // Ensure user has USDC
        uint256 depositAmount = 10_000e6;
        deal(USDC, USER, depositAmount);

        uint256 vaultTotalAssetsBefore = plasmaVault.totalAssets();
        uint256 userVaultBalanceBefore = plasmaVault.balanceOf(USER);
        uint256 userUsdcBalanceBefore = IERC20(USDC).balanceOf(USER);

        // when - user approves and tries to deposit
        vm.startPrank(USER);
        IERC20(USDC).approve(PLASMA_VAULT, depositAmount);

        // then - verify deposit reverts with ExchangeRateOutOfRange error
        vm.expectRevert(
            abi.encodeWithSelector(
                ExchangeRateValidatorPreHook.ExchangeRateOutOfRange.selector,
                currentExchangeRate,
                expectedExchangeRate,
                threshold
            )
        );
        plasmaVault.deposit(depositAmount, USER);
        vm.stopPrank();

        // Verify that nothing changed (deposit failed)
        uint256 vaultTotalAssetsAfter = plasmaVault.totalAssets();
        uint256 userVaultBalanceAfter = plasmaVault.balanceOf(USER);
        uint256 userUsdcBalanceAfter = IERC20(USDC).balanceOf(USER);

        assertEq(vaultTotalAssetsAfter, vaultTotalAssetsBefore, "Vault total assets should not change");
        assertEq(userVaultBalanceAfter, userVaultBalanceBefore, "User vault balance should not change");
        assertEq(userUsdcBalanceAfter, userUsdcBalanceBefore, "User USDC balance should not change");
    }

    /// @notice Test that deposit should fail when pre-hook has substrate with exchange rate more than 1% lower than current
    /// @dev Sets up validator substrate with exchange rate 2% lower than current and 1% threshold, then verifies deposit reverts
    function testShouldRevertDepositWhenPreHookHasSubstrateWithExchangeRateMoreThanThresholdBelow() public {
        // given - calculate current exchange rate
        PlasmaVault plasmaVault = PlasmaVault(PLASMA_VAULT);
        uint256 currentExchangeRate = plasmaVault.convertToAssets(10 ** plasmaVault.decimals());

        // Set expected exchange rate to 2% lower than current (more than 1% threshold)
        // Using 1e18 precision: 2% = 0.02e18 = 2e16
        uint256 expectedExchangeRate = (currentExchangeRate * 98e16) / 1e18;

        // 1% threshold in 1e18 precision (0.01e18 = 1e16)
        uint120 threshold = 1e16;

        // Create validator data with exchange rate 2% lower than current and 1% threshold
        ValidatorData memory validatorData = ValidatorData({
            exchangeRate: uint128(expectedExchangeRate),
            threshold: threshold
        });

        // Encode validator data to bytes31
        bytes31 validatorDataBytes = ExchangeRateValidatorConfigLib.validatorDataToBytes31(validatorData);

        // Create ExchangeRateValidatorConfig with VALIDATOR type
        ExchangeRateValidatorConfig memory config = ExchangeRateValidatorConfig({
            typ: HookType.VALIDATOR,
            data: validatorDataBytes
        });

        // Encode config to bytes32
        bytes32 substrate = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(config);

        // Add substrate to market EXCHANGE_RATE_VALIDATOR
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = substrate;

        vm.startPrank(ATOMIST);
        PlasmaVaultGovernance(PLASMA_VAULT).grantMarketSubstrates(
            IporFusionMarkets.EXCHANGE_RATE_VALIDATOR,
            substrates
        );
        vm.stopPrank();

        // Ensure user has USDC
        uint256 depositAmount = 10_000e6;
        deal(USDC, USER, depositAmount);

        uint256 vaultTotalAssetsBefore = plasmaVault.totalAssets();
        uint256 userVaultBalanceBefore = plasmaVault.balanceOf(USER);
        uint256 userUsdcBalanceBefore = IERC20(USDC).balanceOf(USER);

        // when - user approves and tries to deposit
        vm.startPrank(USER);
        IERC20(USDC).approve(PLASMA_VAULT, depositAmount);

        // then - verify deposit reverts with ExchangeRateOutOfRange error
        vm.expectRevert(
            abi.encodeWithSelector(
                ExchangeRateValidatorPreHook.ExchangeRateOutOfRange.selector,
                currentExchangeRate,
                expectedExchangeRate,
                threshold
            )
        );
        plasmaVault.deposit(depositAmount, USER);
        vm.stopPrank();

        // Verify that nothing changed (deposit failed)
        uint256 vaultTotalAssetsAfter = plasmaVault.totalAssets();
        uint256 userVaultBalanceAfter = plasmaVault.balanceOf(USER);
        uint256 userUsdcBalanceAfter = IERC20(USDC).balanceOf(USER);

        assertEq(vaultTotalAssetsAfter, vaultTotalAssetsBefore, "Vault total assets should not change");
        assertEq(userVaultBalanceAfter, userVaultBalanceBefore, "User vault balance should not change");
        assertEq(userUsdcBalanceAfter, userUsdcBalanceBefore, "User USDC balance should not change");
    }

    /// @notice Test that substrate exchange rate is updated during deposit when deviation is within threshold
    /// @dev Sets up validator substrate with exchange rate 0.75% higher than current (within threshold but > threshold/2),
    ///      then verifies deposit succeeds, event is emitted, and substrate is updated to current exchange rate
    function testShouldUpdateSubstrateExchangeRateDuringDeposit() public {
        // given - calculate current exchange rate
        PlasmaVault plasmaVault = PlasmaVault(PLASMA_VAULT);
        uint256 currentExchangeRate = plasmaVault.convertToAssets(10 ** plasmaVault.decimals());
        uint256 expectedExchangeRate = (currentExchangeRate * 10075e14) / 1e18;
        uint120 threshold = 1e16;

        // Create and encode substrate
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(
            ExchangeRateValidatorConfig({
                typ: HookType.VALIDATOR,
                data: ExchangeRateValidatorConfigLib.validatorDataToBytes31(
                    ValidatorData({exchangeRate: uint128(expectedExchangeRate), threshold: threshold})
                )
            })
        );

        vm.startPrank(ATOMIST);
        PlasmaVaultGovernance(PLASMA_VAULT).grantMarketSubstrates(
            IporFusionMarkets.EXCHANGE_RATE_VALIDATOR,
            substrates
        );
        vm.stopPrank();

        // Ensure user has USDC and prepare for deposit
        uint256 depositAmount = 10_000e6;
        deal(USDC, USER, depositAmount);
        uint256 vaultTotalAssetsBefore = plasmaVault.totalAssets();

        // when - user approves and deposits
        vm.startPrank(USER);
        IERC20(USDC).approve(PLASMA_VAULT, depositAmount);
        vm.expectEmit(true, true, true, true);
        emit ExchangeRateValidatorPreHook.ExchangeRateUpdated(expectedExchangeRate, currentExchangeRate, threshold);
        plasmaVault.deposit(depositAmount, USER);
        vm.stopPrank();

        // then - verify deposit succeeded
        assertGt(plasmaVault.totalAssets(), vaultTotalAssetsBefore, "Vault total assets should increase");

        // Read and verify substrate was updated
        bytes32[] memory substratesAfter = PlasmaVaultGovernance(PLASMA_VAULT).getMarketSubstrates(
            IporFusionMarkets.EXCHANGE_RATE_VALIDATOR
        );
        assertEq(substratesAfter.length, 1, "Should have one substrate");

        ExchangeRateValidatorConfig memory updatedConfig = ExchangeRateValidatorConfigLib
            .bytes32ToExchangeRateValidatorConfig(substratesAfter[0]);
        assertEq(uint256(updatedConfig.typ), uint256(HookType.VALIDATOR), "Substrate type should be VALIDATOR");

        ValidatorData memory updatedValidatorData = ExchangeRateValidatorConfigLib.bytes31ToValidatorData(
            updatedConfig.data
        );
        assertEq(
            uint256(updatedValidatorData.exchangeRate),
            currentExchangeRate,
            "Exchange rate should be updated to current"
        );
        assertEq(updatedValidatorData.threshold, threshold, "Threshold should remain unchanged");
    }

    /// @notice Test that substrate exchange rate is NOT updated during deposit when deviation is <= threshold/2
    /// @dev Sets up validator substrate with exchange rate 0.3% higher than current (<= threshold/2),
    ///      then verifies deposit succeeds, no event is emitted, and substrate remains unchanged
    function testShouldNotUpdateSubstrateExchangeRateWhenDeviationWithinHalfThreshold() public {
        // given - calculate current exchange rate
        PlasmaVault plasmaVault = PlasmaVault(PLASMA_VAULT);
        uint256 currentExchangeRate = plasmaVault.convertToAssets(10 ** plasmaVault.decimals());
        // Set expected exchange rate to 0.3% higher than current
        // This is <= threshold/2 (0.5%), so it should NOT update
        // Using 1e18 precision: 0.3% = 0.003e18 = 3e15
        uint256 expectedExchangeRate = (currentExchangeRate * 1003e15) / 1e18;
        uint120 threshold = 1e16;

        // Create and encode substrate
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(
            ExchangeRateValidatorConfig({
                typ: HookType.VALIDATOR,
                data: ExchangeRateValidatorConfigLib.validatorDataToBytes31(
                    ValidatorData({exchangeRate: uint128(expectedExchangeRate), threshold: threshold})
                )
            })
        );

        vm.startPrank(ATOMIST);
        PlasmaVaultGovernance(PLASMA_VAULT).grantMarketSubstrates(
            IporFusionMarkets.EXCHANGE_RATE_VALIDATOR,
            substrates
        );
        vm.stopPrank();

        // Ensure user has USDC and prepare for deposit
        uint256 depositAmount = 10_000e6;
        deal(USDC, USER, depositAmount);
        uint256 vaultTotalAssetsBefore = plasmaVault.totalAssets();

        // when - user approves and deposits (no event expected)
        vm.startPrank(USER);
        IERC20(USDC).approve(PLASMA_VAULT, depositAmount);
        plasmaVault.deposit(depositAmount, USER);
        vm.stopPrank();

        // then - verify deposit succeeded
        assertGt(plasmaVault.totalAssets(), vaultTotalAssetsBefore, "Vault total assets should increase");

        // Read and verify substrate was NOT updated
        bytes32[] memory substratesAfter = PlasmaVaultGovernance(PLASMA_VAULT).getMarketSubstrates(
            IporFusionMarkets.EXCHANGE_RATE_VALIDATOR
        );
        assertEq(substratesAfter.length, 1, "Should have one substrate");

        ExchangeRateValidatorConfig memory updatedConfig = ExchangeRateValidatorConfigLib
            .bytes32ToExchangeRateValidatorConfig(substratesAfter[0]);
        assertEq(uint256(updatedConfig.typ), uint256(HookType.VALIDATOR), "Substrate type should be VALIDATOR");

        ValidatorData memory updatedValidatorData = ExchangeRateValidatorConfigLib.bytes31ToValidatorData(
            updatedConfig.data
        );

        // Verify exchange rate was NOT updated (should remain as expected)
        assertEq(
            uint256(updatedValidatorData.exchangeRate),
            expectedExchangeRate,
            "Exchange rate should NOT be updated when deviation <= threshold/2"
        );
        assertEq(updatedValidatorData.threshold, threshold, "Threshold should remain unchanged");
    }

    /// @notice Test that pre-hook is executed before validation when both are configured
    /// @dev Sets up validator substrate with current exchange rate (passes validation) and a pre-hook,
    ///      then verifies pre-hook executes before validation and deposit succeeds
    function testShouldExecutePreHookBeforeValidation() public {
        // given - calculate current exchange rate
        PlasmaVault plasmaVault = PlasmaVault(PLASMA_VAULT);
        uint256 currentExchangeRate = plasmaVault.convertToAssets(10 ** plasmaVault.decimals());
        uint120 threshold = 1e16;

        // Deploy SimpleExecutePreHook
        SimpleExecutePreHook simplePreHook = new SimpleExecutePreHook(123);

        // Create substrates array with pre-hook and validator
        bytes32[] memory substrates = new bytes32[](2);

        // First substrate: Pre-hook at index 0
        substrates[0] = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(
            ExchangeRateValidatorConfig({
                typ: HookType.PREHOOKS,
                data: ExchangeRateValidatorConfigLib.hookToBytes31(
                    Hook({hookAddress: address(simplePreHook), index: 0})
                )
            })
        );

        // Second substrate: Validator with current exchange rate (will pass validation)
        substrates[1] = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(
            ExchangeRateValidatorConfig({
                typ: HookType.VALIDATOR,
                data: ExchangeRateValidatorConfigLib.validatorDataToBytes31(
                    ValidatorData({exchangeRate: uint128(currentExchangeRate), threshold: threshold})
                )
            })
        );

        vm.startPrank(ATOMIST);
        PlasmaVaultGovernance(PLASMA_VAULT).grantMarketSubstrates(
            IporFusionMarkets.EXCHANGE_RATE_VALIDATOR,
            substrates
        );
        vm.stopPrank();

        // Ensure user has USDC
        uint256 depositAmount = 10_000e6;
        deal(USDC, USER, depositAmount);
        uint256 vaultTotalAssetsBefore = plasmaVault.totalAssets();

        // when - user approves and deposits
        vm.startPrank(USER);
        IERC20(USDC).approve(PLASMA_VAULT, depositAmount);

        // Expect Execute event from SimpleExecutePreHook
        vm.expectEmit(true, true, true, true);
        emit SimpleExecutePreHook.Execute(123, PlasmaVault.deposit.selector);

        plasmaVault.deposit(depositAmount, USER);
        vm.stopPrank();

        // then - verify deposit succeeded
        assertGt(plasmaVault.totalAssets(), vaultTotalAssetsBefore, "Vault total assets should increase");
    }

    /// @notice Test that pre-hook and post-hook are executed before and after validation
    /// @dev Sets up validator substrate with current exchange rate (passes validation), a pre-hook, and a post-hook,
    ///      then verifies pre-hook executes before validation, post-hook executes after validation, and deposit succeeds
    function testShouldExecutePreHookAndPostHookAroundValidation() public {
        // given - calculate current exchange rate
        PlasmaVault plasmaVault = PlasmaVault(PLASMA_VAULT);
        uint256 currentExchangeRate = plasmaVault.convertToAssets(10 ** plasmaVault.decimals());
        uint120 threshold = 1e16;

        // Deploy SimpleExecutePreHook for both pre and post hooks
        SimpleExecutePreHook preHook = new SimpleExecutePreHook(123);
        SimpleExecutePreHook postHook = new SimpleExecutePreHook(456);

        // Create substrates array with pre-hook, validator, and post-hook
        bytes32[] memory substrates = new bytes32[](3);

        // First substrate: Pre-hook at index 0
        substrates[0] = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(
            ExchangeRateValidatorConfig({
                typ: HookType.PREHOOKS,
                data: ExchangeRateValidatorConfigLib.hookToBytes31(Hook({hookAddress: address(preHook), index: 0}))
            })
        );

        // Second substrate: Validator with current exchange rate (will pass validation)
        substrates[1] = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(
            ExchangeRateValidatorConfig({
                typ: HookType.VALIDATOR,
                data: ExchangeRateValidatorConfigLib.validatorDataToBytes31(
                    ValidatorData({exchangeRate: uint128(currentExchangeRate), threshold: threshold})
                )
            })
        );

        // Third substrate: Post-hook at index 0
        substrates[2] = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(
            ExchangeRateValidatorConfig({
                typ: HookType.POSTHOOKS,
                data: ExchangeRateValidatorConfigLib.hookToBytes31(Hook({hookAddress: address(postHook), index: 0}))
            })
        );

        vm.startPrank(ATOMIST);
        PlasmaVaultGovernance(PLASMA_VAULT).grantMarketSubstrates(
            IporFusionMarkets.EXCHANGE_RATE_VALIDATOR,
            substrates
        );
        vm.stopPrank();

        // Ensure user has USDC
        uint256 depositAmount = 10_000e6;
        deal(USDC, USER, depositAmount);
        uint256 vaultTotalAssetsBefore = plasmaVault.totalAssets();

        // when - user approves and deposits
        vm.startPrank(USER);
        IERC20(USDC).approve(PLASMA_VAULT, depositAmount);

        // Expect Execute events: first from pre-hook, then from post-hook
        vm.expectEmit(true, true, true, true);
        emit SimpleExecutePreHook.Execute(123, PlasmaVault.deposit.selector);

        vm.expectEmit(true, true, true, true);
        emit SimpleExecutePreHook.Execute(456, PlasmaVault.deposit.selector);

        plasmaVault.deposit(depositAmount, USER);
        vm.stopPrank();

        // then - verify deposit succeeded
        assertGt(plasmaVault.totalAssets(), vaultTotalAssetsBefore, "Vault total assets should increase");
    }

    /// @notice Test that multiple pre-hooks and post-hooks are executed in order
    /// @dev Sets up validator substrate with current exchange rate (passes validation), two pre-hooks, and two post-hooks,
    ///      then verifies all hooks execute in correct order and deposit succeeds
    function testShouldExecuteMultiplePreHooksAndPostHooks() public {
        // given - calculate current exchange rate
        PlasmaVault plasmaVault = PlasmaVault(PLASMA_VAULT);
        uint256 currentExchangeRate = plasmaVault.convertToAssets(10 ** plasmaVault.decimals());
        uint120 threshold = 1e16;

        // Deploy multiple SimpleExecutePreHook instances
        SimpleExecutePreHook preHook1 = new SimpleExecutePreHook(111);
        SimpleExecutePreHook preHook2 = new SimpleExecutePreHook(222);
        SimpleExecutePreHook postHook1 = new SimpleExecutePreHook(333);
        SimpleExecutePreHook postHook2 = new SimpleExecutePreHook(444);

        // Create substrates array with two pre-hooks, validator, and two post-hooks
        bytes32[] memory substrates = new bytes32[](5);

        // First substrate: Pre-hook 1 at index 0
        substrates[0] = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(
            ExchangeRateValidatorConfig({
                typ: HookType.PREHOOKS,
                data: ExchangeRateValidatorConfigLib.hookToBytes31(Hook({hookAddress: address(preHook1), index: 0}))
            })
        );

        // Second substrate: Pre-hook 2 at index 1
        substrates[1] = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(
            ExchangeRateValidatorConfig({
                typ: HookType.PREHOOKS,
                data: ExchangeRateValidatorConfigLib.hookToBytes31(Hook({hookAddress: address(preHook2), index: 1}))
            })
        );

        // Third substrate: Validator with current exchange rate (will pass validation)
        substrates[2] = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(
            ExchangeRateValidatorConfig({
                typ: HookType.VALIDATOR,
                data: ExchangeRateValidatorConfigLib.validatorDataToBytes31(
                    ValidatorData({exchangeRate: uint128(currentExchangeRate), threshold: threshold})
                )
            })
        );

        // Fourth substrate: Post-hook 1 at index 0
        substrates[3] = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(
            ExchangeRateValidatorConfig({
                typ: HookType.POSTHOOKS,
                data: ExchangeRateValidatorConfigLib.hookToBytes31(Hook({hookAddress: address(postHook1), index: 0}))
            })
        );

        // Fifth substrate: Post-hook 2 at index 1
        substrates[4] = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(
            ExchangeRateValidatorConfig({
                typ: HookType.POSTHOOKS,
                data: ExchangeRateValidatorConfigLib.hookToBytes31(Hook({hookAddress: address(postHook2), index: 1}))
            })
        );

        vm.startPrank(ATOMIST);
        PlasmaVaultGovernance(PLASMA_VAULT).grantMarketSubstrates(
            IporFusionMarkets.EXCHANGE_RATE_VALIDATOR,
            substrates
        );
        vm.stopPrank();

        // Ensure user has USDC
        uint256 depositAmount = 10_000e6;
        deal(USDC, USER, depositAmount);
        uint256 vaultTotalAssetsBefore = plasmaVault.totalAssets();

        // when - user approves and deposits
        vm.startPrank(USER);
        IERC20(USDC).approve(PLASMA_VAULT, depositAmount);

        // Expect Execute events in order: pre-hook 1, pre-hook 2, post-hook 1, post-hook 2
        vm.expectEmit(true, true, true, true);
        emit SimpleExecutePreHook.Execute(111, PlasmaVault.deposit.selector);

        vm.expectEmit(true, true, true, true);
        emit SimpleExecutePreHook.Execute(222, PlasmaVault.deposit.selector);

        vm.expectEmit(true, true, true, true);
        emit SimpleExecutePreHook.Execute(333, PlasmaVault.deposit.selector);

        vm.expectEmit(true, true, true, true);
        emit SimpleExecutePreHook.Execute(444, PlasmaVault.deposit.selector);

        plasmaVault.deposit(depositAmount, USER);
        vm.stopPrank();

        // then - verify deposit succeeded
        assertGt(plasmaVault.totalAssets(), vaultTotalAssetsBefore, "Vault total assets should increase");
    }

    /// @notice Test that all hooks are executed even when there are gaps in hook indices
    /// @dev This is a regression test for the bug where break was used instead of continue,
    ///      causing hooks after gaps to be skipped
    function testShouldExecuteAllHooksWhenGapExistsInHookIndices() public {
        // given - calculate current exchange rate
        PlasmaVault plasmaVault = PlasmaVault(PLASMA_VAULT);
        uint256 currentExchangeRate = plasmaVault.convertToAssets(10 ** plasmaVault.decimals());
        uint120 threshold = 1e16;

        // Deploy hooks with different identifiers
        SimpleExecutePreHook preHook1 = new SimpleExecutePreHook(111); // Will be at index 0
        SimpleExecutePreHook preHook2 = new SimpleExecutePreHook(333); // Will be at index 2 (gap at 1)
        SimpleExecutePreHook preHook3 = new SimpleExecutePreHook(555); // Will be at index 5 (gaps at 3,4)

        // Create substrates array with non-contiguous pre-hook indices
        bytes32[] memory substrates = new bytes32[](4);

        // Pre-hook at index 0
        substrates[0] = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(
            ExchangeRateValidatorConfig({
                typ: HookType.PREHOOKS,
                data: ExchangeRateValidatorConfigLib.hookToBytes31(Hook({hookAddress: address(preHook1), index: 0}))
            })
        );

        // Pre-hook at index 2 (gap at index 1)
        substrates[1] = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(
            ExchangeRateValidatorConfig({
                typ: HookType.PREHOOKS,
                data: ExchangeRateValidatorConfigLib.hookToBytes31(Hook({hookAddress: address(preHook2), index: 2}))
            })
        );

        // Pre-hook at index 5 (gaps at indices 3, 4)
        substrates[2] = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(
            ExchangeRateValidatorConfig({
                typ: HookType.PREHOOKS,
                data: ExchangeRateValidatorConfigLib.hookToBytes31(Hook({hookAddress: address(preHook3), index: 5}))
            })
        );

        // Validator with current exchange rate (will pass validation)
        substrates[3] = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(
            ExchangeRateValidatorConfig({
                typ: HookType.VALIDATOR,
                data: ExchangeRateValidatorConfigLib.validatorDataToBytes31(
                    ValidatorData({exchangeRate: uint128(currentExchangeRate), threshold: threshold})
                )
            })
        );

        vm.startPrank(ATOMIST);
        PlasmaVaultGovernance(PLASMA_VAULT).grantMarketSubstrates(
            IporFusionMarkets.EXCHANGE_RATE_VALIDATOR,
            substrates
        );
        vm.stopPrank();

        // Ensure user has USDC
        uint256 depositAmount = 10_000e6;
        deal(USDC, USER, depositAmount);
        uint256 vaultTotalAssetsBefore = plasmaVault.totalAssets();

        // when - user approves and deposits
        vm.startPrank(USER);
        IERC20(USDC).approve(PLASMA_VAULT, depositAmount);

        // Expect Execute events from ALL three pre-hooks (not just the first one)
        // This verifies that gaps don't cause early termination
        vm.expectEmit(true, true, true, true);
        emit SimpleExecutePreHook.Execute(111, PlasmaVault.deposit.selector);

        vm.expectEmit(true, true, true, true);
        emit SimpleExecutePreHook.Execute(333, PlasmaVault.deposit.selector);

        vm.expectEmit(true, true, true, true);
        emit SimpleExecutePreHook.Execute(555, PlasmaVault.deposit.selector);

        plasmaVault.deposit(depositAmount, USER);
        vm.stopPrank();

        // then - verify deposit succeeded
        assertGt(plasmaVault.totalAssets(), vaultTotalAssetsBefore, "Vault total assets should increase");
    }
}
