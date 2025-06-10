// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ContextManagerInitSetup} from "./ContextManagerInitSetup.sol";
import {TestAddresses} from "../test_helpers/TestAddresses.sol";
import {ExecuteData} from "../../contracts/managers/context/ContextManager.sol";
import {IERC20} from "../../lib/forge-std/src/interfaces/IERC20.sol";
import {FuseAction} from "../../contracts/vaults/PlasmaVault.sol";
import {MoonwellSupplyFuseEnterData, MoonwellSupplyFuse} from "../../contracts/fuses/moonwell/MoonwellSupplyFuse.sol";
import {IPlasmaVaultGovernance} from "../../contracts/interfaces/IPlasmaVaultGovernance.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {MarketLimit} from "../../contracts/libraries/AssetDistributionProtectionLib.sol";
import {InstantWithdrawalFusesParamsStruct} from "../../contracts/libraries/PlasmaVaultLib.sol";
import {ZeroBalanceFuse} from "../../contracts/fuses/ZeroBalanceFuse.sol";

contract ContextManagerPlasmaVaultTest is Test, ContextManagerInitSetup {
    // Test events
    event ContextCall(address indexed target, bytes data, bytes result);
    address internal immutable _USER_2 = makeAddr("USER2");

    address[] private _addresses;
    bytes[] private _data;

    function setUp() public {
        initSetup();
        deal(_UNDERLYING_TOKEN, _USER_2, 100e18); // Note: wstETH uses 18 decimals
        vm.startPrank(_USER_2);
        IERC20(_UNDERLYING_TOKEN).approve(address(_plasmaVault), 100e18);
        vm.stopPrank();
    }

    function testUserCanApprovedByContextManager() public {
        // given
        _addresses = new address[](1);
        _addresses[0] = address(_plasmaVault);
        _data = new bytes[](1);
        _data[0] = abi.encodeWithSelector(IERC20.approve.selector, _USER, type(uint256).max);
        ExecuteData memory executeData = ExecuteData({targets: _addresses, datas: _data});

        // when
        vm.startPrank(_USER_2);
        _contextManager.runWithContext(executeData);
        vm.stopPrank();

        // then

        assertEq(_plasmaVault.allowance(_USER_2, _USER), type(uint256).max, "allowance should be max");
    }
    function testUserCanDepositUsingContextManager() public {
        // given
        uint256 depositAmount = 10e18;
        _addresses = new address[](1);
        _addresses[0] = address(_plasmaVault);

        _data = new bytes[](1);
        _data[0] = abi.encodeWithSelector(_plasmaVault.deposit.selector, depositAmount, _USER_2);

        ExecuteData memory executeData = ExecuteData({targets: _addresses, datas: _data});

        uint256 balanceBefore = _plasmaVault.balanceOf(_USER_2);

        // when
        vm.startPrank(_USER_2);
        _contextManager.runWithContext(executeData);
        vm.stopPrank();

        // then
        uint256 balanceAfter = _plasmaVault.balanceOf(_USER_2);
        assertEq(balanceAfter - balanceBefore, depositAmount * 100, "deposit amount should match balance increase");
    }

    function testUserCanMintUsingContextManager() public {
        // given
        uint256 mintAmount = 10e18;
        _addresses = new address[](1);
        _addresses[0] = address(_plasmaVault);

        _data = new bytes[](1);
        _data[0] = abi.encodeWithSelector(_plasmaVault.mint.selector, mintAmount, _USER_2);

        ExecuteData memory executeData = ExecuteData({targets: _addresses, datas: _data});

        uint256 balanceBefore = _plasmaVault.balanceOf(_USER_2);

        // when
        vm.startPrank(_USER_2);
        _contextManager.runWithContext(executeData);
        vm.stopPrank();

        // then
        uint256 balanceAfter = _plasmaVault.balanceOf(_USER_2);
        assertEq(balanceAfter - balanceBefore, mintAmount, "mint amount should match balance increase");
    }

    function testUserCanTransferUsingContextManager() public {
        // given
        uint256 transferAmount = 10e18;
        address recipient = makeAddr("RECIPIENT");
        _addresses = new address[](1);
        _addresses[0] = address(_plasmaVault);

        _data = new bytes[](1);
        _data[0] = abi.encodeWithSelector(_plasmaVault.transfer.selector, recipient, transferAmount);

        ExecuteData memory executeData = ExecuteData({targets: _addresses, datas: _data});

        uint256 senderBalanceBefore = _plasmaVault.balanceOf(_USER);
        uint256 recipientBalanceBefore = _plasmaVault.balanceOf(recipient);

        // when
        vm.startPrank(_USER);
        _contextManager.runWithContext(executeData);
        vm.stopPrank();

        // then
        uint256 senderBalanceAfter = _plasmaVault.balanceOf(_USER);
        uint256 recipientBalanceAfter = _plasmaVault.balanceOf(recipient);

        assertEq(
            senderBalanceBefore - senderBalanceAfter,
            transferAmount,
            "sender balance should decrease by transfer amount"
        );
        assertEq(
            recipientBalanceAfter - recipientBalanceBefore,
            transferAmount,
            "recipient balance should increase by transfer amount"
        );
    }

    function testUserCanTransferFromUsingContextManager() public {
        // given
        uint256 transferAmount = 10e18;
        address recipient = makeAddr("RECIPIENT");

        // Setup approval for USER_2 to spend USER's tokens
        vm.startPrank(_USER);
        _plasmaVault.approve(_USER_2, transferAmount);
        vm.stopPrank();

        _addresses = new address[](1);
        _addresses[0] = address(_plasmaVault);

        _data = new bytes[](1);
        _data[0] = abi.encodeWithSelector(_plasmaVault.transferFrom.selector, _USER, recipient, transferAmount);

        ExecuteData memory executeData = ExecuteData({targets: _addresses, datas: _data});

        uint256 ownerBalanceBefore = _plasmaVault.balanceOf(_USER);
        uint256 recipientBalanceBefore = _plasmaVault.balanceOf(recipient);
        uint256 allowanceBefore = _plasmaVault.allowance(_USER, _USER_2);

        // when
        vm.startPrank(_USER_2);
        _contextManager.runWithContext(executeData);
        vm.stopPrank();

        // then
        uint256 ownerBalanceAfter = _plasmaVault.balanceOf(_USER);
        uint256 recipientBalanceAfter = _plasmaVault.balanceOf(recipient);
        uint256 allowanceAfter = _plasmaVault.allowance(_USER, _USER_2);

        assertEq(
            ownerBalanceBefore - ownerBalanceAfter,
            transferAmount,
            "owner balance should decrease by transfer amount"
        );
        assertEq(
            recipientBalanceAfter - recipientBalanceBefore,
            transferAmount,
            "recipient balance should increase by transfer amount"
        );
        assertEq(allowanceBefore - allowanceAfter, transferAmount, "allowance should decrease by transfer amount");
    }

    function testUserCanWithdrawUsingContextManager() public {
        // given
        uint256 withdrawAmount = 10e18;
        address recipient = makeAddr("RECIPIENT");

        _addresses = new address[](1);
        _addresses[0] = address(_plasmaVault);

        _data = new bytes[](1);
        _data[0] = abi.encodeWithSelector(_plasmaVault.withdraw.selector, withdrawAmount, recipient, _USER);

        ExecuteData memory executeData = ExecuteData({targets: _addresses, datas: _data});

        uint256 ownerSharesBefore = _plasmaVault.balanceOf(_USER);
        uint256 recipientTokensBefore = IERC20(_UNDERLYING_TOKEN).balanceOf(recipient);

        // when
        vm.startPrank(_USER);
        _contextManager.runWithContext(executeData);
        vm.stopPrank();

        // then
        uint256 ownerSharesAfter = _plasmaVault.balanceOf(_USER);
        uint256 recipientTokensAfter = IERC20(_UNDERLYING_TOKEN).balanceOf(recipient);

        assertEq(
            ownerSharesBefore - ownerSharesAfter,
            withdrawAmount * 100,
            "owner shares should decrease by withdraw amount * 100"
        );
        assertEq(
            recipientTokensAfter - recipientTokensBefore,
            withdrawAmount,
            "recipient should receive correct amount of underlying tokens"
        );
    }

    function testUserCanRedeemUsingContextManager() public {
        // given
        uint256 redeemAmount = 10e18;
        address recipient = makeAddr("RECIPIENT");

        _addresses = new address[](1);
        _addresses[0] = address(_plasmaVault);

        _data = new bytes[](1);
        _data[0] = abi.encodeWithSelector(_plasmaVault.redeem.selector, redeemAmount, recipient, _USER);

        ExecuteData memory executeData = ExecuteData({targets: _addresses, datas: _data});

        uint256 ownerSharesBefore = _plasmaVault.balanceOf(_USER);
        uint256 recipientTokensBefore = IERC20(_UNDERLYING_TOKEN).balanceOf(recipient);

        // when
        vm.startPrank(_USER);
        _contextManager.runWithContext(executeData);
        vm.stopPrank();

        // then
        uint256 ownerSharesAfter = _plasmaVault.balanceOf(_USER);
        uint256 recipientTokensAfter = IERC20(_UNDERLYING_TOKEN).balanceOf(recipient);

        assertEq(ownerSharesBefore - ownerSharesAfter, redeemAmount, "owner shares should decrease by redeem amount");
        assertEq(
            recipientTokensAfter - recipientTokensBefore,
            redeemAmount / 100,
            "recipient should receive correct amount of underlying tokens"
        );
    }

    function testAtomistCanSupplyToMoonwellUsingContextManager() public {
        // given
        uint256 supplyAmount = 500e6; // 500 USDC (6 decimals)

        // Create FuseAction array for execute call
        FuseAction[] memory fuseActions = new FuseAction[](1);
        fuseActions[0] = FuseAction({
            fuse: address(_moonwellAddresses.suppluFuse),
            data: abi.encodeWithSelector(
                MoonwellSupplyFuse.enter.selector,
                MoonwellSupplyFuseEnterData({asset: _UNDERLYING_TOKEN, amount: supplyAmount})
            )
        });

        // Create context manager execution data
        _addresses = new address[](1);
        _data = new bytes[](1);

        _addresses[0] = address(_plasmaVault);
        _data[0] = abi.encodeWithSelector(_plasmaVault.execute.selector, fuseActions);

        ExecuteData memory executeData = ExecuteData({targets: _addresses, datas: _data});

        uint256 initialUSDCBalance = IERC20(_UNDERLYING_TOKEN).balanceOf(address(_plasmaVault));

        // when
        vm.startPrank(TestAddresses.ALPHA);
        _contextManager.runWithContext(executeData);
        vm.stopPrank();

        // then
        uint256 finalUSDCBalance = IERC20(_UNDERLYING_TOKEN).balanceOf(address(_plasmaVault));

        assertEq(finalUSDCBalance, 99999999999500000000, "finalUSDCBalance should be 99999999999500000000");
        assertEq(initialUSDCBalance, 100000000000000000000, "initialUSDCBalance should be 100000000000000000000");
    }

    function testFuseManagerCanAddBalanceFuseUsingContextManager() public {
        // given
        uint256 marketId = 1;
        address newFuse = address(new ZeroBalanceFuse(marketId));

        _addresses = new address[](1);
        _addresses[0] = address(_plasmaVault);

        _data = new bytes[](1);
        _data[0] = abi.encodeWithSelector(IPlasmaVaultGovernance.addBalanceFuse.selector, marketId, newFuse);

        ExecuteData memory executeData = ExecuteData({targets: _addresses, datas: _data});

        // when
        vm.startPrank(TestAddresses.FUSE_MANAGER);
        _contextManager.runWithContext(executeData);
        vm.stopPrank();

        // then
        bool isSupported = PlasmaVaultGovernance(address(_plasmaVault)).isBalanceFuseSupported(marketId, newFuse);
        assertTrue(isSupported, "Balance fuse should be supported after addition");
    }

    function testFuseManagerCanRemoveBalanceFuseUsingContextManager() public {
        // given
        uint256 marketId = 2;
        address fuseToRemove = 0x62286efb801ae4eE93733c3bc1bFA0746e5103D8;

        // First add the balance fuse
        _addresses = new address[](1);
        _addresses[0] = address(_plasmaVault);
        _data = new bytes[](1);
        _data[0] = abi.encodeWithSelector(IPlasmaVaultGovernance.addBalanceFuse.selector, marketId, fuseToRemove);

        ExecuteData memory executeData = ExecuteData({targets: _addresses, datas: _data});

        vm.startPrank(TestAddresses.FUSE_MANAGER);
        _contextManager.runWithContext(executeData);
        vm.stopPrank();
        // Verify fuse was added successfully
        bool isSupportedAfterAdd = PlasmaVaultGovernance(address(_plasmaVault)).isBalanceFuseSupported(
            marketId,
            fuseToRemove
        );
        assertTrue(isSupportedAfterAdd, "Balance fuse should be supported after addition");

        // Now remove the balance fuse
        _data[0] = abi.encodeWithSelector(IPlasmaVaultGovernance.removeBalanceFuse.selector, marketId, fuseToRemove);
        executeData = ExecuteData({targets: _addresses, datas: _data});

        vm.startPrank(TestAddresses.FUSE_MANAGER);
        _contextManager.runWithContext(executeData);
        vm.stopPrank();

        // then
        bool isSupportedAfterRemove = PlasmaVaultGovernance(address(_plasmaVault)).isBalanceFuseSupported(
            marketId,
            fuseToRemove
        );
        assertFalse(isSupportedAfterRemove, "Balance fuse should not be supported after removal");
    }

    function testFuseManagerCanGrantMarketSubstratesUsingContextManager() public {
        // given
        uint256 marketId = 1;
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = keccak256("SUBSTRATE_1");
        substrates[1] = keccak256("SUBSTRATE_2");

        _addresses = new address[](1);
        _addresses[0] = address(_plasmaVault);

        _data = new bytes[](1);
        _data[0] = abi.encodeWithSelector(IPlasmaVaultGovernance.grantMarketSubstrates.selector, marketId, substrates);

        ExecuteData memory executeData = ExecuteData({targets: _addresses, datas: _data});

        // when
        vm.startPrank(TestAddresses.FUSE_MANAGER);
        _contextManager.runWithContext(executeData);
        vm.stopPrank();

        // then
        for (uint256 i; i < substrates.length; i++) {
            bool isGranted = PlasmaVaultGovernance(address(_plasmaVault)).isMarketSubstrateGranted(
                marketId,
                substrates[i]
            );
            assertTrue(isGranted, string.concat("Substrate ", vm.toString(i), " should be granted"));
        }

        // Verify we can get all granted substrates
        bytes32[] memory grantedSubstrates = PlasmaVaultGovernance(address(_plasmaVault)).getMarketSubstrates(marketId);
        assertEq(grantedSubstrates.length, substrates.length, "Should have correct number of substrates");

        for (uint256 i; i < substrates.length; i++) {
            assertEq(grantedSubstrates[i], substrates[i], string.concat("Substrate ", vm.toString(i), " should match"));
        }
    }

    function testAtomistCanUpdateDependencyBalanceGraphsUsingContextManager() public {
        // given
        uint256[] memory marketIds = new uint256[](2);
        marketIds[0] = 1;
        marketIds[1] = 2;

        uint256[][] memory dependencies = new uint256[][](2);
        dependencies[0] = new uint256[](2);
        dependencies[0][0] = 3;
        dependencies[0][1] = 4;
        dependencies[1] = new uint256[](3);
        dependencies[1][0] = 5;
        dependencies[1][1] = 6;
        dependencies[1][2] = 7;

        _addresses = new address[](1);
        _addresses[0] = address(_plasmaVault);

        _data = new bytes[](1);
        _data[0] = abi.encodeWithSelector(
            IPlasmaVaultGovernance.updateDependencyBalanceGraphs.selector,
            marketIds,
            dependencies
        );

        ExecuteData memory executeData = ExecuteData({targets: _addresses, datas: _data});

        // when
        vm.startPrank(TestAddresses.FUSE_MANAGER);
        _contextManager.runWithContext(executeData);
        vm.stopPrank();

        // then
        for (uint256 i; i < marketIds.length; i++) {
            uint256[] memory graphDependencies = PlasmaVaultGovernance(address(_plasmaVault)).getDependencyBalanceGraph(
                marketIds[i]
            );

            assertEq(
                graphDependencies.length,
                dependencies[i].length,
                string.concat("Market ", vm.toString(marketIds[i]), " should have correct number of dependencies")
            );

            for (uint256 j; j < dependencies[i].length; j++) {
                assertEq(
                    graphDependencies[j],
                    dependencies[i][j],
                    string.concat("Market ", vm.toString(marketIds[i]), " dependency ", vm.toString(j), " should match")
                );
            }
        }
    }

    function testAtomistCanConfigureInstantWithdrawalFusesUsingContextManager() public {
        // given
        address[] memory fuses = PlasmaVaultGovernance(address(_plasmaVault)).getFuses();

        address fuse1 = fuses[0];
        address fuse2 = fuses[2];

        bytes32[] memory params1 = new bytes32[](2);
        params1[0] = keccak256("PARAM1_1");
        params1[1] = keccak256("PARAM1_2");

        bytes32[] memory params2 = new bytes32[](1);
        params2[0] = keccak256("PARAM2_1");

        InstantWithdrawalFusesParamsStruct[] memory fusesParams = new InstantWithdrawalFusesParamsStruct[](2);
        fusesParams[0] = InstantWithdrawalFusesParamsStruct({fuse: fuse1, params: params1});
        fusesParams[1] = InstantWithdrawalFusesParamsStruct({fuse: fuse2, params: params2});

        _addresses = new address[](1);
        _addresses[0] = address(_plasmaVault);

        _data = new bytes[](1);
        _data[0] = abi.encodeWithSelector(IPlasmaVaultGovernance.configureInstantWithdrawalFuses.selector, fusesParams);

        ExecuteData memory executeData = ExecuteData({targets: _addresses, datas: _data});

        // when
        vm.startPrank(TestAddresses.CONFIG_INSTANT_WITHDRAWAL_FUSES_MANAGER);
        _contextManager.runWithContext(executeData);
        vm.stopPrank();

        // then
        address[] memory configuredFuses = PlasmaVaultGovernance(address(_plasmaVault)).getInstantWithdrawalFuses();
        assertEq(configuredFuses.length, 2, "Should have correct number of fuses");
        assertEq(configuredFuses[0], fuse1, "First fuse should match");
        assertEq(configuredFuses[1], fuse2, "Second fuse should match");

        // Verify params for first fuse
        bytes32[] memory fuse1Params = PlasmaVaultGovernance(address(_plasmaVault)).getInstantWithdrawalFusesParams(
            fuse1,
            0
        );
        assertEq(fuse1Params.length, params1.length, "First fuse should have correct number of params");
        assertEq(fuse1Params[0], params1[0], "First param of first fuse should match");
        assertEq(fuse1Params[1], params1[1], "Second param of first fuse should match");

        // Verify params for second fuse
        bytes32[] memory fuse2Params = PlasmaVaultGovernance(address(_plasmaVault)).getInstantWithdrawalFusesParams(
            fuse2,
            1
        );

        assertEq(fuse2Params.length, params2.length, "Second fuse should have correct number of params");
        assertEq(fuse2Params[0], params2[0], "First param of second fuse should match");
    }

    function testFuseManagerCanAddFusesUsingContextManager() public {
        // given
        address[] memory newFuses = new address[](2);
        newFuses[0] = makeAddr("NEW_FUSE_1");
        newFuses[1] = makeAddr("NEW_FUSE_2");

        _addresses = new address[](1);
        _addresses[0] = address(_plasmaVault);

        _data = new bytes[](1);
        _data[0] = abi.encodeWithSelector(IPlasmaVaultGovernance.addFuses.selector, newFuses);

        ExecuteData memory executeData = ExecuteData({targets: _addresses, datas: _data});

        // Store initial fuses count
        address[] memory initialFuses = PlasmaVaultGovernance(address(_plasmaVault)).getFuses();
        uint256 initialFusesCount = initialFuses.length;

        // when
        vm.startPrank(TestAddresses.FUSE_MANAGER);
        _contextManager.runWithContext(executeData);
        vm.stopPrank();

        // then
        address[] memory updatedFuses = PlasmaVaultGovernance(address(_plasmaVault)).getFuses();

        // Verify total count increased
        assertEq(updatedFuses.length, initialFusesCount + 2, "Should have added two new fuses");

        // Verify new fuses are supported
        assertTrue(
            PlasmaVaultGovernance(address(_plasmaVault)).isFuseSupported(newFuses[0]),
            "First new fuse should be supported"
        );
        assertTrue(
            PlasmaVaultGovernance(address(_plasmaVault)).isFuseSupported(newFuses[1]),
            "Second new fuse should be supported"
        );

        // Verify new fuses are in the array
        bool found1 = false;
        bool found2 = false;
        for (uint256 i; i < updatedFuses.length; i++) {
            if (updatedFuses[i] == newFuses[0]) found1 = true;
            if (updatedFuses[i] == newFuses[1]) found2 = true;
        }
        assertTrue(found1, "First new fuse should be in array");
        assertTrue(found2, "Second new fuse should be in array");
    }

    function testFuseManagerCanRemoveFusesUsingContextManager() public {
        // given
        // First add some fuses that we'll remove
        address[] memory newFuses = new address[](2);
        newFuses[0] = makeAddr("FUSE_TO_REMOVE_1");
        newFuses[1] = makeAddr("FUSE_TO_REMOVE_2");

        _addresses = new address[](1);
        _addresses[0] = address(_plasmaVault);

        // Add the fuses first
        _data = new bytes[](1);
        _data[0] = abi.encodeWithSelector(IPlasmaVaultGovernance.addFuses.selector, newFuses);

        ExecuteData memory executeData = ExecuteData({targets: _addresses, datas: _data});

        vm.startPrank(TestAddresses.FUSE_MANAGER);
        _contextManager.runWithContext(executeData);

        // Verify fuses were added successfully
        assertTrue(
            PlasmaVaultGovernance(address(_plasmaVault)).isFuseSupported(newFuses[0]),
            "First fuse should be supported after addition"
        );
        assertTrue(
            PlasmaVaultGovernance(address(_plasmaVault)).isFuseSupported(newFuses[1]),
            "Second fuse should be supported after addition"
        );

        // Store fuses count before removal
        address[] memory fusesBeforeRemoval = PlasmaVaultGovernance(address(_plasmaVault)).getFuses();
        uint256 initialFusesCount = fusesBeforeRemoval.length;

        // Now remove the fuses
        _data[0] = abi.encodeWithSelector(IPlasmaVaultGovernance.removeFuses.selector, newFuses);
        executeData = ExecuteData({targets: _addresses, datas: _data});

        // when
        _contextManager.runWithContext(executeData);
        vm.stopPrank();

        // then
        address[] memory updatedFuses = PlasmaVaultGovernance(address(_plasmaVault)).getFuses();

        // Verify total count decreased
        assertEq(updatedFuses.length, initialFusesCount - 2, "Should have removed two fuses");

        // Verify fuses are no longer supported
        assertFalse(
            PlasmaVaultGovernance(address(_plasmaVault)).isFuseSupported(newFuses[0]),
            "First fuse should not be supported after removal"
        );
        assertFalse(
            PlasmaVaultGovernance(address(_plasmaVault)).isFuseSupported(newFuses[1]),
            "Second fuse should not be supported after removal"
        );

        // Verify fuses are not in the array
        bool found1 = false;
        bool found2 = false;
        for (uint256 i; i < updatedFuses.length; i++) {
            if (updatedFuses[i] == newFuses[0]) found1 = true;
            if (updatedFuses[i] == newFuses[1]) found2 = true;
        }
        assertFalse(found1, "First fuse should not be in array");
        assertFalse(found2, "Second fuse should not be in array");
    }

    function testAtomistCanSetPriceOracleMiddlewareUsingContextManager() public {
        // given
        // Only check if function is exexcuted, so the address can be any
        address newPriceOracle = PlasmaVaultGovernance(address(_plasmaVault)).getPriceOracleMiddleware();

        _addresses = new address[](1);
        _addresses[0] = address(_plasmaVault);

        _data = new bytes[](1);
        _data[0] = abi.encodeWithSelector(IPlasmaVaultGovernance.setPriceOracleMiddleware.selector, newPriceOracle);

        ExecuteData memory executeData = ExecuteData({targets: _addresses, datas: _data});

        address initialPriceOracle = PlasmaVaultGovernance(address(_plasmaVault)).getPriceOracleMiddleware();

        // when
        vm.startPrank(TestAddresses.ATOMIST);
        _contextManager.runWithContext(executeData);
        vm.stopPrank();

        // then
        address updatedPriceOracle = PlasmaVaultGovernance(address(_plasmaVault)).getPriceOracleMiddleware();
        assertEq(updatedPriceOracle, initialPriceOracle);
    }

    function testAtomistCanSetupMarketsLimitsUsingContextManager() public {
        // given
        MarketLimit[] memory marketLimits = new MarketLimit[](2);
        marketLimits[0] = MarketLimit({marketId: 1, limitInPercentage: 3000}); // 30%
        marketLimits[1] = MarketLimit({marketId: 2, limitInPercentage: 7000}); // 70%

        _addresses = new address[](1);
        _addresses[0] = address(_plasmaVault);

        _data = new bytes[](1);
        _data[0] = abi.encodeWithSelector(IPlasmaVaultGovernance.setupMarketsLimits.selector, marketLimits);

        ExecuteData memory executeData = ExecuteData({targets: _addresses, datas: _data});

        // Activate markets limits first (required for limits to work)
        vm.startPrank(TestAddresses.ATOMIST);
        PlasmaVaultGovernance(address(_plasmaVault)).activateMarketsLimits();

        // when
        _contextManager.runWithContext(executeData);
        vm.stopPrank();

        // then
        for (uint256 i; i < marketLimits.length; i++) {
            uint256 limit = PlasmaVaultGovernance(address(_plasmaVault)).getMarketLimit(marketLimits[i].marketId);
            assertEq(
                limit,
                marketLimits[i].limitInPercentage,
                string.concat("Market ", vm.toString(marketLimits[i].marketId), " should have correct limit")
            );
        }

        // Verify markets limits are activated
        assertTrue(
            PlasmaVaultGovernance(address(_plasmaVault)).isMarketsLimitsActivated(),
            "Markets limits should be activated"
        );
    }

    function testAtomistCanActivateMarketsLimitsUsingContextManager() public {
        // given
        // Ensure markets limits are deactivated initially
        vm.startPrank(TestAddresses.ATOMIST);
        PlasmaVaultGovernance(address(_plasmaVault)).deactivateMarketsLimits();
        vm.stopPrank();

        assertFalse(
            PlasmaVaultGovernance(address(_plasmaVault)).isMarketsLimitsActivated(),
            "Markets limits should be deactivated initially"
        );

        _addresses = new address[](1);
        _addresses[0] = address(_plasmaVault);

        _data = new bytes[](1);
        _data[0] = abi.encodeWithSelector(IPlasmaVaultGovernance.activateMarketsLimits.selector);

        ExecuteData memory executeData = ExecuteData({targets: _addresses, datas: _data});

        // when
        vm.startPrank(TestAddresses.ATOMIST);
        _contextManager.runWithContext(executeData);
        vm.stopPrank();

        // then
        assertTrue(
            PlasmaVaultGovernance(address(_plasmaVault)).isMarketsLimitsActivated(),
            "Markets limits should be activated"
        );
    }

    function testAtomistCanDeactivateMarketsLimitsUsingContextManager() public {
        // given
        // Ensure markets limits are activated initially
        vm.startPrank(TestAddresses.ATOMIST);
        PlasmaVaultGovernance(address(_plasmaVault)).activateMarketsLimits();
        vm.stopPrank();

        assertTrue(
            PlasmaVaultGovernance(address(_plasmaVault)).isMarketsLimitsActivated(),
            "Markets limits should be activated initially"
        );

        _addresses = new address[](1);
        _addresses[0] = address(_plasmaVault);

        _data = new bytes[](1);
        _data[0] = abi.encodeWithSelector(IPlasmaVaultGovernance.deactivateMarketsLimits.selector);

        ExecuteData memory executeData = ExecuteData({targets: _addresses, datas: _data});

        // when
        vm.startPrank(TestAddresses.ATOMIST);
        _contextManager.runWithContext(executeData);
        vm.stopPrank();

        // then
        assertFalse(
            PlasmaVaultGovernance(address(_plasmaVault)).isMarketsLimitsActivated(),
            "Markets limits should be deactivated"
        );
    }

    function testAtomistCanUpdateCallbackHandlerUsingContextManager() public {
        // given
        address handler = makeAddr("CALLBACK_HANDLER");
        address sender = makeAddr("CALLBACK_SENDER");
        bytes4 sig = bytes4(keccak256("testCallback(uint256,address)"));

        _addresses = new address[](1);
        _addresses[0] = address(_plasmaVault);

        _data = new bytes[](1);
        _data[0] = abi.encodeWithSelector(IPlasmaVaultGovernance.updateCallbackHandler.selector, handler, sender, sig);

        ExecuteData memory executeData = ExecuteData({targets: _addresses, datas: _data});

        // when
        vm.startPrank(TestAddresses.ATOMIST);
        _contextManager.runWithContext(executeData);
        vm.stopPrank();

        // then
        // Note: Since CallbackHandlerLib doesn't expose a getter for handlers,
        // we can only verify the function executes without reverting
        // The actual handler verification is covered in CallbackHandlerLib tests
    }

    function testAtomistCanSetTotalSupplyCapUsingContextManager() public {
        // given
        uint256 newCap = 1000000e18;

        _addresses = new address[](1);
        _addresses[0] = address(_plasmaVault);

        _data = new bytes[](1);
        _data[0] = abi.encodeWithSelector(IPlasmaVaultGovernance.setTotalSupplyCap.selector, newCap);

        ExecuteData memory executeData = ExecuteData({targets: _addresses, datas: _data});

        uint256 initialCap = PlasmaVaultGovernance(address(_plasmaVault)).getTotalSupplyCap();

        // when
        vm.startPrank(TestAddresses.ATOMIST);
        _contextManager.runWithContext(executeData);
        vm.stopPrank();

        // then
        uint256 updatedCap = PlasmaVaultGovernance(address(_plasmaVault)).getTotalSupplyCap();
        assertNotEq(updatedCap, initialCap, "Total supply cap should have changed");
        assertEq(updatedCap, newCap, "Total supply cap should be set to new value");
    }

    function testAtomistCanConvertToPublicVaultUsingContextManager() public {
        // given
        _addresses = new address[](1);
        _addresses[0] = address(_plasmaVault);

        _data = new bytes[](1);
        _data[0] = abi.encodeWithSelector(IPlasmaVaultGovernance.convertToPublicVault.selector);

        ExecuteData memory executeData = ExecuteData({targets: _addresses, datas: _data});

        // when
        vm.startPrank(TestAddresses.ATOMIST);
        _contextManager.runWithContext(executeData);
        vm.stopPrank();

        // then
        // Note: Since the access manager state is internal, we can only verify
        // the function executes without reverting. The actual state change
        // verification is covered in IporFusionAccessManager tests
    }

    function testAtomistCanEnableTransferSharesUsingContextManager() public {
        // given
        _addresses = new address[](1);
        _addresses[0] = address(_plasmaVault);

        _data = new bytes[](1);
        _data[0] = abi.encodeWithSelector(IPlasmaVaultGovernance.enableTransferShares.selector);

        ExecuteData memory executeData = ExecuteData({targets: _addresses, datas: _data});

        // when
        vm.startPrank(TestAddresses.ATOMIST);
        _contextManager.runWithContext(executeData);
        vm.stopPrank();

        // then
        // Note: Since the access manager state is internal, we can only verify
        // the function executes without reverting. The actual state change
        // verification is covered in IporFusionAccessManager tests
    }

    function testAtomistCanSetMinimalExecutionDelaysForRolesUsingContextManager() public {
        // given
        uint64[] memory rolesIds = new uint64[](2);
        rolesIds[0] = 1; // Example role ID
        rolesIds[1] = 2; // Example role ID

        uint256[] memory delays = new uint256[](2);
        delays[0] = 1 days;
        delays[1] = 2 days;

        _addresses = new address[](1);
        _addresses[0] = address(_plasmaVault);

        _data = new bytes[](1);
        _data[0] = abi.encodeWithSelector(
            IPlasmaVaultGovernance.setMinimalExecutionDelaysForRoles.selector,
            rolesIds,
            delays
        );

        ExecuteData memory executeData = ExecuteData({targets: _addresses, datas: _data});

        // when
        vm.startPrank(TestAddresses.OWNER);
        _contextManager.runWithContext(executeData);
        vm.stopPrank();

        // then
        // Note: Since the access manager state is internal, we can only verify
        // the function executes without reverting. The actual state change
        // verification is covered in IporFusionAccessManager tests
    }
}
