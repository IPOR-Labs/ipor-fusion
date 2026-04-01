// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {MidasRequestSupplyFuse, MidasRequestSupplyFuseEnterData, MidasRequestSupplyFuseExitData} from "contracts/fuses/midas/MidasRequestSupplyFuse.sol";
import {MidasSubstrateLib, MidasSubstrateType} from "contracts/fuses/midas/lib/MidasSubstrateLib.sol";
import {Errors} from "contracts/libraries/errors/Errors.sol";
import {MidasRequestSupplyFuseHarness} from "./mocks/MidasRequestSupplyFuseHarness.sol";
import {MockERC20Midas} from "./mocks/MockERC20Midas.sol";
import {MockMidasDepositVault} from "./mocks/MockMidasDepositVault.sol";
import {MockMidasRedemptionVaultFuse} from "./mocks/MockMidasRedemptionVaultFuse.sol";
import {MockMidasExecutorForFuse} from "./mocks/MockMidasExecutorForFuse.sol";

/// @title MidasRequestSupplyFuseTest
/// @notice Unit tests for MidasRequestSupplyFuse - 100% branch coverage target
/// @dev Uses a delegatecall harness to simulate the PlasmaVault storage context.
///      The harness holds all ERC-7201 storage; the fuse runs via delegatecall.
contract MidasRequestSupplyFuseTest is Test {
    // ============ Constants ============

    uint256 constant MARKET_ID = 42;
    uint256 constant DEPOSIT_REQUEST_ID_1 = 1;
    uint256 constant DEPOSIT_REQUEST_ID_2 = 2;
    uint256 constant REDEEM_REQUEST_ID_3 = 3;
    uint256 constant REDEEM_REQUEST_ID_4 = 4;

    // ============ State Variables ============

    MidasRequestSupplyFuse fuse;
    MidasRequestSupplyFuseHarness harness;

    MockERC20Midas tokenIn;   // USDC-like deposit token
    MockERC20Midas mToken;    // mTBILL-like receipt token
    MockERC20Midas tokenOut;  // USDC-like redemption output token

    MockMidasDepositVault depositVault;
    MockMidasRedemptionVaultFuse redemptionVault;
    MockMidasExecutorForFuse mockExecutor;

    // ============ Setup ============

    function setUp() public {
        // Deploy the fuse
        fuse = new MidasRequestSupplyFuse(MARKET_ID);

        // Deploy harness (acts as PlasmaVault, holds delegatecall storage)
        harness = new MidasRequestSupplyFuseHarness(address(fuse));

        // Deploy token mocks
        tokenIn = new MockERC20Midas("Mock USDC", "USDC", 6);
        mToken = new MockERC20Midas("Mock mTBILL", "mTBILL", 18);
        tokenOut = new MockERC20Midas("Mock USDC Out", "USDC", 6);

        // Deploy vault mocks (default requestId=1 for deposits, 3 for redemptions)
        depositVault = new MockMidasDepositVault(DEPOSIT_REQUEST_ID_1);
        redemptionVault = new MockMidasRedemptionVaultFuse(REDEEM_REQUEST_ID_3);

        // Deploy mock executor and pre-set it in harness storage
        mockExecutor = new MockMidasExecutorForFuse(address(harness));
        mockExecutor.setNextDepositRequestId(DEPOSIT_REQUEST_ID_1);
        mockExecutor.setNextRedeemRequestId(REDEEM_REQUEST_ID_3);
        harness.setExecutor(address(mockExecutor));

        // Label addresses for trace readability
        vm.label(address(fuse), "MidasRequestSupplyFuse");
        vm.label(address(harness), "Harness(PlasmaVault)");
        vm.label(address(tokenIn), "TokenIn(USDC)");
        vm.label(address(mToken), "mToken(mTBILL)");
        vm.label(address(tokenOut), "TokenOut(USDC)");
        vm.label(address(depositVault), "DepositVault");
        vm.label(address(redemptionVault), "RedemptionVault");
        vm.label(address(mockExecutor), "MockExecutor");
    }

    // ============ Helpers ============

    /// @dev Grant all substrates needed for a full enter() call
    function _grantEnterSubstrates() internal {
        harness.grantSubstrate(MARKET_ID, MidasSubstrateType.M_TOKEN, address(mToken));
        harness.grantSubstrate(MARKET_ID, MidasSubstrateType.DEPOSIT_VAULT, address(depositVault));
        harness.grantSubstrate(MARKET_ID, MidasSubstrateType.ASSET, address(tokenIn));
    }

    /// @dev Grant all substrates needed for a full exit() call
    function _grantExitSubstrates() internal {
        harness.grantSubstrate(MARKET_ID, MidasSubstrateType.M_TOKEN, address(mToken));
        harness.grantSubstrate(MARKET_ID, MidasSubstrateType.REDEMPTION_VAULT, address(redemptionVault));
        harness.grantSubstrate(MARKET_ID, MidasSubstrateType.ASSET, address(tokenOut));
    }

    /// @dev Mint tokenIn to harness (simulating PlasmaVault holding the tokens)
    function _mintTokenIn(uint256 amount) internal {
        tokenIn.mint(address(harness), amount);
    }

    /// @dev Mint mToken to harness (simulating PlasmaVault holding mTokens)
    function _mintMToken(uint256 amount) internal {
        mToken.mint(address(harness), amount);
    }

    // ============ Constructor Tests ============

    /// @dev Branch C2: valid marketId sets VERSION and MARKET_ID
    function test_constructor_ShouldSetVersionAndMarketId() public {
        // When
        MidasRequestSupplyFuse newFuse = new MidasRequestSupplyFuse(42);

        // Then
        assertEq(newFuse.VERSION(), address(newFuse), "VERSION should equal fuse address");
        assertEq(newFuse.MARKET_ID(), 42, "MARKET_ID should be 42");
    }

    /// @dev Branch C1: marketId == 0 reverts with Errors.WrongValue()
    function test_constructor_ShouldRevertWhenMarketIdIsZero() public {
        // Then
        vm.expectRevert(abi.encodeWithSelector(Errors.WrongValue.selector));

        // When
        new MidasRequestSupplyFuse(0);
    }

    /// @dev Fuzz: any non-zero marketId is accepted
    function test_constructor_Fuzz_ShouldAcceptAnyNonZeroMarketId(uint256 marketId) public {
        // Given
        vm.assume(marketId > 0);

        // When
        MidasRequestSupplyFuse newFuse = new MidasRequestSupplyFuse(marketId);

        // Then
        assertEq(newFuse.MARKET_ID(), marketId, "MARKET_ID should match provided value");
        assertEq(newFuse.VERSION(), address(newFuse), "VERSION should equal fuse address");
    }

    // ============ Enter Tests ============

    /// @dev Branch E1: amount == 0 returns early, no token transfer, no event
    function test_enter_ShouldReturnEarlyWhenAmountIsZero() public {
        // Given
        _mintTokenIn(1000e6);
        MidasRequestSupplyFuseEnterData memory data = MidasRequestSupplyFuseEnterData({
            mToken: address(mToken),
            tokenIn: address(tokenIn),
            amount: 0,
            depositVault: address(depositVault)
        });

        // When/Then: no events, no revert
        vm.recordLogs();
        harness.enter(data);

        // Assert: no MidasRequestSupplyFuseEnter event emitted
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 enterSig = keccak256("MidasRequestSupplyFuseEnter(address,address,uint256,address,uint256,address)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertNotEq(logs[i].topics[0], enterSig, "Enter event should NOT be emitted when amount=0");
        }
        assertEq(tokenIn.balanceOf(address(harness)), 1000e6, "Token balance should be unchanged");
    }

    /// @dev Branch E1 + ID3: amount==0 with existing non-pending deposit triggers cleanup
    function test_enter_ShouldCleanUpPendingDepositsWhenAmountIsZero() public {
        // Given: pre-populate 2 pending deposits
        harness.seedPendingDeposit(address(depositVault), 10);
        harness.seedPendingDeposit(address(depositVault), 20);
        // Request 10: status=1 (processed), Request 20: status=0 (pending)
        depositVault.setRequestStatus(10, 1);
        depositVault.setMintRequest(20, address(harness), address(tokenIn), 0);

        MidasRequestSupplyFuseEnterData memory data = MidasRequestSupplyFuseEnterData({
            mToken: address(mToken),
            tokenIn: address(tokenIn),
            amount: 0,
            depositVault: address(depositVault)
        });

        // When
        vm.expectEmit(true, true, false, true);
        emit MidasRequestSupplyFuse.MidasRequestSupplyFuseCleanedDeposit(address(depositVault), 10);
        harness.enter(data);

        // Then: request 10 removed, request 20 remains
        assertFalse(harness.isDepositPending(address(depositVault), 10), "Request 10 should be removed");
        assertTrue(harness.isDepositPending(address(depositVault), 20), "Request 20 should remain");
    }

    /// @dev Branch E2: mToken substrate not granted
    function test_enter_ShouldRevertWhenMTokenNotGranted() public {
        // Given: mToken NOT granted
        MidasRequestSupplyFuseEnterData memory data = MidasRequestSupplyFuseEnterData({
            mToken: address(mToken),
            tokenIn: address(tokenIn),
            amount: 100e6,
            depositVault: address(depositVault)
        });

        // Then
        vm.expectRevert(
            abi.encodeWithSelector(MidasSubstrateLib.MidasFuseUnsupportedSubstrate.selector, uint8(1), address(mToken))
        );

        // When
        harness.enter(data);
    }

    /// @dev Branch E3: depositVault substrate not granted
    function test_enter_ShouldRevertWhenDepositVaultNotGranted() public {
        // Given: mToken granted, depositVault NOT granted
        harness.grantSubstrate(MARKET_ID, MidasSubstrateType.M_TOKEN, address(mToken));
        MidasRequestSupplyFuseEnterData memory data = MidasRequestSupplyFuseEnterData({
            mToken: address(mToken),
            tokenIn: address(tokenIn),
            amount: 100e6,
            depositVault: address(depositVault)
        });

        // Then
        vm.expectRevert(
            abi.encodeWithSelector(MidasSubstrateLib.MidasFuseUnsupportedSubstrate.selector, uint8(2), address(depositVault))
        );

        // When
        harness.enter(data);
    }

    /// @dev Branch E4: tokenIn substrate not granted
    function test_enter_ShouldRevertWhenTokenInNotGranted() public {
        // Given: mToken + depositVault granted, tokenIn NOT granted
        harness.grantSubstrate(MARKET_ID, MidasSubstrateType.M_TOKEN, address(mToken));
        harness.grantSubstrate(MARKET_ID, MidasSubstrateType.DEPOSIT_VAULT, address(depositVault));
        MidasRequestSupplyFuseEnterData memory data = MidasRequestSupplyFuseEnterData({
            mToken: address(mToken),
            tokenIn: address(tokenIn),
            amount: 100e6,
            depositVault: address(depositVault)
        });

        // Then
        vm.expectRevert(
            abi.encodeWithSelector(MidasSubstrateLib.MidasFuseUnsupportedSubstrate.selector, uint8(5), address(tokenIn))
        );

        // When
        harness.enter(data);
    }

    /// @dev Branch E5: all substrates granted but balance == 0, returns early
    function test_enter_ShouldReturnEarlyWhenBalanceIsZero() public {
        // Given: all substrates granted, but harness has 0 tokenIn balance
        _grantEnterSubstrates();
        // No tokens minted to harness
        MidasRequestSupplyFuseEnterData memory data = MidasRequestSupplyFuseEnterData({
            mToken: address(mToken),
            tokenIn: address(tokenIn),
            amount: 100e6,
            depositVault: address(depositVault)
        });

        // When/Then: no revert, no event
        vm.recordLogs();
        harness.enter(data);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 enterSig = keccak256("MidasRequestSupplyFuseEnter(address,address,uint256,address,uint256,address)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertNotEq(logs[i].topics[0], enterSig, "Enter event should NOT be emitted when balance=0");
        }
        // mockExecutor should NOT have been called
        assertEq(mockExecutor.lastDepositAmount(), 0, "Executor should not have been called");
    }

    /// @dev Branch E6: balance >= amount, uses full amount
    function test_enter_ShouldUseFullAmountWhenBalanceExceedsAmount() public {
        // Given
        _grantEnterSubstrates();
        _mintTokenIn(200e6);
        mockExecutor.setNextDepositRequestId(DEPOSIT_REQUEST_ID_1);
        MidasRequestSupplyFuseEnterData memory data = MidasRequestSupplyFuseEnterData({
            mToken: address(mToken),
            tokenIn: address(tokenIn),
            amount: 100e6,
            depositVault: address(depositVault)
        });

        // When
        harness.enter(data);

        // Then: executor received exactly 100e6
        assertEq(mockExecutor.lastDepositAmount(), 100e6, "Executor should receive exactly amount=100e6");
        assertEq(tokenIn.lastTransferAmount(), 100e6, "Transfer should be 100e6");
        assertEq(tokenIn.lastTransferTo(), address(mockExecutor), "Transfer should go to executor");
        assertTrue(harness.isDepositPending(address(depositVault), DEPOSIT_REQUEST_ID_1), "Request 1 should be pending");
    }

    /// @dev Branch E7: balance < amount, uses balance (partial deposit)
    function test_enter_ShouldUseBalanceWhenAmountExceedsBalance() public {
        // Given: balance=50e6, amount=200e6 => finalAmount=50e6
        _grantEnterSubstrates();
        _mintTokenIn(50e6);
        mockExecutor.setNextDepositRequestId(DEPOSIT_REQUEST_ID_2);
        MidasRequestSupplyFuseEnterData memory data = MidasRequestSupplyFuseEnterData({
            mToken: address(mToken),
            tokenIn: address(tokenIn),
            amount: 200e6,
            depositVault: address(depositVault)
        });

        // When
        harness.enter(data);

        // Then: executor received balance (50e6), not amount (200e6)
        assertEq(mockExecutor.lastDepositAmount(), 50e6, "Executor should receive balance=50e6");
        assertEq(tokenIn.lastTransferAmount(), 50e6, "Transfer should be 50e6 (balance)");
    }

    /// @dev Branch E8: executor returns requestId=0, revert
    function test_enter_ShouldRevertWhenRequestIdIsZero() public {
        // Given
        _grantEnterSubstrates();
        _mintTokenIn(100e6);
        mockExecutor.setNextDepositRequestId(0);
        MidasRequestSupplyFuseEnterData memory data = MidasRequestSupplyFuseEnterData({
            mToken: address(mToken),
            tokenIn: address(tokenIn),
            amount: 100e6,
            depositVault: address(depositVault)
        });

        // Then
        vm.expectRevert(abi.encodeWithSelector(MidasRequestSupplyFuse.MidasRequestSupplyFuseInvalidRequestId.selector));

        // When
        harness.enter(data);
    }

    /// @dev Branch E9: full happy path, event emitted with all correct parameters
    function test_enter_ShouldEmitCorrectEvent() public {
        // Given
        _grantEnterSubstrates();
        _mintTokenIn(100e6);
        mockExecutor.setNextDepositRequestId(DEPOSIT_REQUEST_ID_1);
        MidasRequestSupplyFuseEnterData memory data = MidasRequestSupplyFuseEnterData({
            mToken: address(mToken),
            tokenIn: address(tokenIn),
            amount: 100e6,
            depositVault: address(depositVault)
        });

        // Then: expect event with all parameters
        vm.expectEmit(true, true, true, true);
        emit MidasRequestSupplyFuse.MidasRequestSupplyFuseEnter(
            fuse.VERSION(),
            address(mToken),
            100e6,
            address(tokenIn),
            DEPOSIT_REQUEST_ID_1,
            address(depositVault)
        );

        // When
        harness.enter(data);
    }

    /// @dev Branch E9: pending deposit stored in storage after enter
    function test_enter_ShouldAddPendingDepositToStorage() public {
        // Given
        _grantEnterSubstrates();
        _mintTokenIn(100e6);
        mockExecutor.setNextDepositRequestId(DEPOSIT_REQUEST_ID_1);
        MidasRequestSupplyFuseEnterData memory data = MidasRequestSupplyFuseEnterData({
            mToken: address(mToken),
            tokenIn: address(tokenIn),
            amount: 100e6,
            depositVault: address(depositVault)
        });

        // When
        harness.enter(data);

        // Then
        uint256[] memory ids = harness.getPendingDepositsForVault(address(depositVault));
        assertEq(ids.length, 1, "Should have 1 pending deposit");
        assertEq(ids[0], DEPOSIT_REQUEST_ID_1, "Pending request ID should match");
    }

    /// @dev Branch E9: executor is created if not pre-set in storage
    function test_enter_ShouldCreateExecutorIfNotExists() public {
        // Given: clear the pre-set executor so auto-deployment kicks in
        harness.setExecutor(address(0));
        _grantEnterSubstrates();
        _mintTokenIn(100e6);

        // Need real depositVault that can receive tokens and return requestId
        // Use vm.mockCall to mock the executor creation path
        // Since MidasExecutor is deployed by getOrCreateExecutor, we just check the result
        MidasRequestSupplyFuseEnterData memory data = MidasRequestSupplyFuseEnterData({
            mToken: address(mToken),
            tokenIn: address(tokenIn),
            amount: 100e6,
            depositVault: address(depositVault)
        });

        // When: enter deploys a new MidasExecutor
        // We need to mock the depositVault.depositRequest to return a non-zero requestId
        // The real MidasExecutor will call depositVault.depositRequest
        // First, we need to approve the deposit vault in the executor context
        // This is complex because MidasExecutor calls forceApprove then depositRequest
        // depositVault.depositRequest returns nextRequestId=1
        // But MidasExecutor also calls ERC20.decimals() for WAD conversion
        vm.mockCall(address(tokenIn), abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
        harness.enter(data);

        // Then: executor was created and stored
        address executorAddr = harness.getExecutor();
        assertNotEq(executorAddr, address(0), "Executor should be deployed");
        // Verify it is a valid MidasExecutor (has PLASMA_VAULT set to harness)
        // (We can check via staticcall to PLASMA_VAULT())
        (bool success, bytes memory result) = executorAddr.staticcall(abi.encodeWithSignature("PLASMA_VAULT()"));
        assertTrue(success, "PLASMA_VAULT() call should succeed");
        address pv = abi.decode(result, (address));
        assertEq(pv, address(harness), "Executor PLASMA_VAULT should be harness");
    }

    /// @dev Branch E9: executor reused on second call
    function test_enter_ShouldReuseExistingExecutor() public {
        // Given: executor already pre-set
        _grantEnterSubstrates();
        _mintTokenIn(200e6);
        mockExecutor.setNextDepositRequestId(DEPOSIT_REQUEST_ID_1);

        MidasRequestSupplyFuseEnterData memory data = MidasRequestSupplyFuseEnterData({
            mToken: address(mToken),
            tokenIn: address(tokenIn),
            amount: 100e6,
            depositVault: address(depositVault)
        });

        // When: first call
        harness.enter(data);
        address executorAfterFirst = harness.getExecutor();

        // Second call
        mockExecutor.setNextDepositRequestId(DEPOSIT_REQUEST_ID_2);
        data.amount = 50e6;
        harness.enter(data);
        address executorAfterSecond = harness.getExecutor();

        // Then: same executor used both times
        assertEq(executorAfterFirst, executorAfterSecond, "Same executor should be reused");
        assertEq(executorAfterFirst, address(mockExecutor), "Executor should be the pre-set mock");
    }

    /// @dev Branch E9 + ID3: completed deposit cleaned up before new deposit
    function test_enter_ShouldCleanUpCompletedDepositsBeforeNewDeposit() public {
        // Given: pre-populate pending deposit (ID 5, status=1 = processed)
        harness.seedPendingDeposit(address(depositVault), 5);
        depositVault.setRequestStatus(5, 1);
        _grantEnterSubstrates();
        _mintTokenIn(100e6);
        mockExecutor.setNextDepositRequestId(DEPOSIT_REQUEST_ID_1);

        MidasRequestSupplyFuseEnterData memory data = MidasRequestSupplyFuseEnterData({
            mToken: address(mToken),
            tokenIn: address(tokenIn),
            amount: 100e6,
            depositVault: address(depositVault)
        });

        // When
        harness.enter(data);

        // Then: request 5 removed, new request 1 added
        assertFalse(harness.isDepositPending(address(depositVault), 5), "Request 5 should be cleaned up");
        assertTrue(harness.isDepositPending(address(depositVault), DEPOSIT_REQUEST_ID_1), "New request should be added");
    }

    // ============ Exit Tests ============

    /// @dev Branch X1: amount == 0 returns early, no event
    function test_exit_ShouldReturnEarlyWhenAmountIsZero() public {
        // Given
        _mintMToken(1000e18);
        MidasRequestSupplyFuseExitData memory data = MidasRequestSupplyFuseExitData({
            mToken: address(mToken),
            amount: 0,
            tokenOut: address(tokenOut),
            standardRedemptionVault: address(redemptionVault)
        });

        // When/Then: no events, no revert
        vm.recordLogs();
        harness.exit(data);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 exitSig = keccak256("MidasRequestSupplyFuseExit(address,address,uint256,address,uint256,address)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertNotEq(logs[i].topics[0], exitSig, "Exit event should NOT be emitted when amount=0");
        }
    }

    /// @dev Branch X1 + IR3: amount==0 with existing non-pending redemption triggers cleanup
    function test_exit_ShouldCleanUpPendingRedemptionsWhenAmountIsZero() public {
        // Given: pre-populate 2 pending redemptions
        harness.seedPendingRedemption(address(redemptionVault), 10);
        harness.seedPendingRedemption(address(redemptionVault), 20);
        // Request 10: status=1 (processed), Request 20: status=0 (pending)
        redemptionVault.setRequestStatus(10, 1);
        redemptionVault.setRedeemRequest(20, address(harness), address(tokenOut), 0);

        MidasRequestSupplyFuseExitData memory data = MidasRequestSupplyFuseExitData({
            mToken: address(mToken),
            amount: 0,
            tokenOut: address(tokenOut),
            standardRedemptionVault: address(redemptionVault)
        });

        // When
        vm.expectEmit(true, true, false, true);
        emit MidasRequestSupplyFuse.MidasRequestSupplyFuseCleanedRedemption(address(redemptionVault), 10);
        harness.exit(data);

        // Then
        assertFalse(harness.isRedemptionPending(address(redemptionVault), 10), "Request 10 should be removed");
        assertTrue(harness.isRedemptionPending(address(redemptionVault), 20), "Request 20 should remain");
    }

    /// @dev Branch X2: mToken substrate not granted
    function test_exit_ShouldRevertWhenMTokenNotGranted() public {
        // Given: mToken NOT granted
        MidasRequestSupplyFuseExitData memory data = MidasRequestSupplyFuseExitData({
            mToken: address(mToken),
            amount: 100e18,
            tokenOut: address(tokenOut),
            standardRedemptionVault: address(redemptionVault)
        });

        // Then
        vm.expectRevert(
            abi.encodeWithSelector(MidasSubstrateLib.MidasFuseUnsupportedSubstrate.selector, uint8(1), address(mToken))
        );

        // When
        harness.exit(data);
    }

    /// @dev Branch X3: redemptionVault substrate not granted
    function test_exit_ShouldRevertWhenRedemptionVaultNotGranted() public {
        // Given: mToken granted, redemptionVault NOT granted
        harness.grantSubstrate(MARKET_ID, MidasSubstrateType.M_TOKEN, address(mToken));
        MidasRequestSupplyFuseExitData memory data = MidasRequestSupplyFuseExitData({
            mToken: address(mToken),
            amount: 100e18,
            tokenOut: address(tokenOut),
            standardRedemptionVault: address(redemptionVault)
        });

        // Then
        vm.expectRevert(
            abi.encodeWithSelector(MidasSubstrateLib.MidasFuseUnsupportedSubstrate.selector, uint8(3), address(redemptionVault))
        );

        // When
        harness.exit(data);
    }

    /// @dev Branch X4: tokenOut substrate not granted
    function test_exit_ShouldRevertWhenTokenOutNotGranted() public {
        // Given: mToken + redemptionVault granted, tokenOut NOT granted
        harness.grantSubstrate(MARKET_ID, MidasSubstrateType.M_TOKEN, address(mToken));
        harness.grantSubstrate(MARKET_ID, MidasSubstrateType.REDEMPTION_VAULT, address(redemptionVault));
        MidasRequestSupplyFuseExitData memory data = MidasRequestSupplyFuseExitData({
            mToken: address(mToken),
            amount: 100e18,
            tokenOut: address(tokenOut),
            standardRedemptionVault: address(redemptionVault)
        });

        // Then
        vm.expectRevert(
            abi.encodeWithSelector(MidasSubstrateLib.MidasFuseUnsupportedSubstrate.selector, uint8(5), address(tokenOut))
        );

        // When
        harness.exit(data);
    }

    /// @dev Branch X5: all substrates granted but mToken balance == 0
    function test_exit_ShouldReturnEarlyWhenMTokenBalanceIsZero() public {
        // Given: all substrates granted, no mToken balance
        _grantExitSubstrates();
        MidasRequestSupplyFuseExitData memory data = MidasRequestSupplyFuseExitData({
            mToken: address(mToken),
            amount: 100e18,
            tokenOut: address(tokenOut),
            standardRedemptionVault: address(redemptionVault)
        });

        // When/Then: no revert, no event
        vm.recordLogs();
        harness.exit(data);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 exitSig = keccak256("MidasRequestSupplyFuseExit(address,address,uint256,address,uint256,address)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertNotEq(logs[i].topics[0], exitSig, "Exit event should NOT be emitted when mToken balance=0");
        }
        assertEq(mockExecutor.lastRedeemAmount(), 0, "Executor should not have been called");
    }

    /// @dev Branch X6: mToken balance >= amount, uses full amount
    function test_exit_ShouldUseFullAmountWhenBalanceExceedsAmount() public {
        // Given: balance=100e18, amount=50e18 => finalAmount=50e18
        _grantExitSubstrates();
        _mintMToken(100e18);
        mockExecutor.setNextRedeemRequestId(REDEEM_REQUEST_ID_3);
        MidasRequestSupplyFuseExitData memory data = MidasRequestSupplyFuseExitData({
            mToken: address(mToken),
            amount: 50e18,
            tokenOut: address(tokenOut),
            standardRedemptionVault: address(redemptionVault)
        });

        // When
        harness.exit(data);

        // Then
        assertEq(mockExecutor.lastRedeemAmount(), 50e18, "Executor should receive exactly amount=50e18");
        assertEq(mToken.lastTransferAmount(), 50e18, "Transfer should be 50e18");
        assertEq(mToken.lastTransferTo(), address(mockExecutor), "Transfer should go to executor");
    }

    /// @dev Branch X7: mToken balance < amount, uses balance (partial redemption)
    function test_exit_ShouldUseBalanceWhenAmountExceedsBalance() public {
        // Given: balance=75e18, amount=200e18 => finalAmount=75e18
        _grantExitSubstrates();
        _mintMToken(75e18);
        mockExecutor.setNextRedeemRequestId(REDEEM_REQUEST_ID_4);
        MidasRequestSupplyFuseExitData memory data = MidasRequestSupplyFuseExitData({
            mToken: address(mToken),
            amount: 200e18,
            tokenOut: address(tokenOut),
            standardRedemptionVault: address(redemptionVault)
        });

        // When
        harness.exit(data);

        // Then
        assertEq(mockExecutor.lastRedeemAmount(), 75e18, "Executor should receive balance=75e18");
        assertEq(mToken.lastTransferAmount(), 75e18, "Transfer should be 75e18 (balance)");
    }

    /// @dev Branch X8: executor returns redeemRequestId=0, revert
    function test_exit_ShouldRevertWhenRedeemRequestIdIsZero() public {
        // Given
        _grantExitSubstrates();
        _mintMToken(100e18);
        mockExecutor.setNextRedeemRequestId(0);
        MidasRequestSupplyFuseExitData memory data = MidasRequestSupplyFuseExitData({
            mToken: address(mToken),
            amount: 100e18,
            tokenOut: address(tokenOut),
            standardRedemptionVault: address(redemptionVault)
        });

        // Then
        vm.expectRevert(abi.encodeWithSelector(MidasRequestSupplyFuse.MidasRequestSupplyFuseInvalidRedeemRequestId.selector));

        // When
        harness.exit(data);
    }

    /// @dev Branch X9: full happy path exit, event emitted with all correct parameters
    function test_exit_ShouldEmitCorrectEvent() public {
        // Given
        _grantExitSubstrates();
        _mintMToken(100e18);
        mockExecutor.setNextRedeemRequestId(REDEEM_REQUEST_ID_3);
        MidasRequestSupplyFuseExitData memory data = MidasRequestSupplyFuseExitData({
            mToken: address(mToken),
            amount: 100e18,
            tokenOut: address(tokenOut),
            standardRedemptionVault: address(redemptionVault)
        });

        // Then: expect exit event with all parameters
        vm.expectEmit(true, true, true, true);
        emit MidasRequestSupplyFuse.MidasRequestSupplyFuseExit(
            fuse.VERSION(),
            address(mToken),
            100e18,
            address(tokenOut),
            REDEEM_REQUEST_ID_3,
            address(redemptionVault)
        );

        // When
        harness.exit(data);
    }

    /// @dev Branch X9: pending redemption stored in storage
    function test_exit_ShouldAddPendingRedemptionToStorage() public {
        // Given
        _grantExitSubstrates();
        _mintMToken(100e18);
        mockExecutor.setNextRedeemRequestId(REDEEM_REQUEST_ID_3);
        MidasRequestSupplyFuseExitData memory data = MidasRequestSupplyFuseExitData({
            mToken: address(mToken),
            amount: 100e18,
            tokenOut: address(tokenOut),
            standardRedemptionVault: address(redemptionVault)
        });

        // When
        harness.exit(data);

        // Then
        uint256[] memory ids = harness.getPendingRedemptionsForVault(address(redemptionVault));
        assertEq(ids.length, 1, "Should have 1 pending redemption");
        assertEq(ids[0], REDEEM_REQUEST_ID_3, "Pending redemption ID should match");
    }

    /// @dev Branch X9 + IR3: completed redemption cleaned up before new redeem
    function test_exit_ShouldCleanUpCompletedRedemptionsBeforeNewRedeem() public {
        // Given: pre-populate pending redemption (ID 5, status=1 = processed)
        harness.seedPendingRedemption(address(redemptionVault), 5);
        redemptionVault.setRequestStatus(5, 1);
        _grantExitSubstrates();
        _mintMToken(100e18);
        mockExecutor.setNextRedeemRequestId(REDEEM_REQUEST_ID_3);

        MidasRequestSupplyFuseExitData memory data = MidasRequestSupplyFuseExitData({
            mToken: address(mToken),
            amount: 100e18,
            tokenOut: address(tokenOut),
            standardRedemptionVault: address(redemptionVault)
        });

        // When
        harness.exit(data);

        // Then: request 5 removed, new request 3 added
        assertFalse(harness.isRedemptionPending(address(redemptionVault), 5), "Request 5 should be cleaned up");
        assertTrue(harness.isRedemptionPending(address(redemptionVault), REDEEM_REQUEST_ID_3), "New request should be added");
    }

    // ============ cleanupPendingDeposits Tests ============

    /// @dev Branch CD1: no pending requests, no-op
    function test_cleanupPendingDeposits_ShouldNoOpWhenNoPendingRequests() public {
        // Given: no pending deposits
        // When/Then: no revert
        vm.recordLogs();
        harness.cleanupPendingDeposits(address(depositVault), 0);
        assertEq(vm.getRecordedLogs().length, 0, "No events should be emitted");
    }

    /// @dev Branch CD2: all requests pending (status==0), none removed
    function test_cleanupPendingDeposits_ShouldSkipAllWhenAllPending() public {
        // Given: 3 pending requests, all status=0
        harness.seedPendingDeposit(address(depositVault), 1);
        harness.seedPendingDeposit(address(depositVault), 2);
        harness.seedPendingDeposit(address(depositVault), 3);
        // status defaults to 0 (pending) when not set

        // When
        vm.recordLogs();
        harness.cleanupPendingDeposits(address(depositVault), 0);

        // Then: no removals, still 3 in storage
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "No cleanup events should be emitted");
        assertTrue(harness.isDepositPending(address(depositVault), 1), "Request 1 should remain");
        assertTrue(harness.isDepositPending(address(depositVault), 2), "Request 2 should remain");
        assertTrue(harness.isDepositPending(address(depositVault), 3), "Request 3 should remain");
    }

    /// @dev Branch CD3: mixed pending/non-pending, only non-pending removed
    function test_cleanupPendingDeposits_ShouldRemoveOnlyNonPendingRequests() public {
        // Given: ID 1 (status=1 processed), ID 2 (status=0 pending), ID 3 (status=2 canceled)
        harness.seedPendingDeposit(address(depositVault), 1);
        harness.seedPendingDeposit(address(depositVault), 2);
        harness.seedPendingDeposit(address(depositVault), 3);
        depositVault.setRequestStatus(1, 1);
        // ID 2 stays status=0 (pending)
        depositVault.setRequestStatus(3, 2);

        // When
        harness.cleanupPendingDeposits(address(depositVault), 0);

        // Then: IDs 1 and 3 removed, ID 2 remains
        assertFalse(harness.isDepositPending(address(depositVault), 1), "Request 1 should be removed");
        assertTrue(harness.isDepositPending(address(depositVault), 2), "Request 2 should remain");
        assertFalse(harness.isDepositPending(address(depositVault), 3), "Request 3 should be removed");
    }

    /// @dev Branch CD4: all requests non-pending, all removed
    function test_cleanupPendingDeposits_ShouldRemoveAllWhenNonePending() public {
        // Given: 2 requests, both status=1
        harness.seedPendingDeposit(address(depositVault), 5);
        harness.seedPendingDeposit(address(depositVault), 6);
        depositVault.setRequestStatus(5, 1);
        depositVault.setRequestStatus(6, 1);

        // When
        harness.cleanupPendingDeposits(address(depositVault), 0);

        // Then: both removed
        assertFalse(harness.isDepositPending(address(depositVault), 5), "Request 5 should be removed");
        assertFalse(harness.isDepositPending(address(depositVault), 6), "Request 6 should be removed");
        assertEq(harness.getPendingDepositsForVault(address(depositVault)).length, 0, "Vault should have 0 pending deposits");
    }

    /// @dev Branch CD5: maxIterations_ limits processing
    /// Loop processes from end: IDs [1,2,3] -> processes 3, then 2 (maxIterations_=2), stops. ID 1 remains.
    function test_cleanupPendingDeposits_ShouldRespectMaxIterationsLimit() public {
        // Given: 3 requests, all status=1 (non-pending)
        harness.seedPendingDeposit(address(depositVault), 1);
        harness.seedPendingDeposit(address(depositVault), 2);
        harness.seedPendingDeposit(address(depositVault), 3);
        depositVault.setRequestStatus(1, 1);
        depositVault.setRequestStatus(2, 1);
        depositVault.setRequestStatus(3, 1);

        // When: maxIterations_=2 => processes IDs from end [3, 2], then breaks
        harness.cleanupPendingDeposits(address(depositVault), 2);

        // Then: IDs 3 and 2 removed (processed from end), ID 1 remains
        assertFalse(harness.isDepositPending(address(depositVault), 3), "Request 3 should be removed (last in array)");
        assertFalse(harness.isDepositPending(address(depositVault), 2), "Request 2 should be removed");
        assertTrue(harness.isDepositPending(address(depositVault), 1), "Request 1 should remain (not reached)");
    }

    /// @dev Branch CD6: maxIterations_==0 processes all
    function test_cleanupPendingDeposits_ShouldProcessAllWhenMaxIterationsIsZero() public {
        // Given: 5 requests, all non-pending
        for (uint256 i = 1; i <= 5; i++) {
            harness.seedPendingDeposit(address(depositVault), i);
            depositVault.setRequestStatus(i, 1);
        }

        // When
        harness.cleanupPendingDeposits(address(depositVault), 0);

        // Then: all 5 removed
        assertEq(harness.getPendingDepositsForVault(address(depositVault)).length, 0, "All deposits should be removed");
    }

    /// @dev Branch CD7: pending requests don't count toward maxIterations
    /// IDs [1,2,3,4] with [1=processed, 2=pending, 3=processed, 4=pending], maxIterations=1
    /// Loop from end: 4=pending skip, 3=non-pending remove, iterations=1, break. ID 1 remains.
    function test_cleanupPendingDeposits_ShouldNotCountPendingTowardIterations() public {
        // Given
        harness.seedPendingDeposit(address(depositVault), 1);
        harness.seedPendingDeposit(address(depositVault), 2);
        harness.seedPendingDeposit(address(depositVault), 3);
        harness.seedPendingDeposit(address(depositVault), 4);
        depositVault.setRequestStatus(1, 1); // non-pending
        // 2 stays pending (status=0)
        depositVault.setRequestStatus(3, 1); // non-pending
        // 4 stays pending (status=0)

        // When
        harness.cleanupPendingDeposits(address(depositVault), 1);

        // Then: only ID 3 removed (loop: 4=skip, 3=remove, iterations=1=break)
        assertTrue(harness.isDepositPending(address(depositVault), 1), "Request 1 should remain");
        assertTrue(harness.isDepositPending(address(depositVault), 2), "Request 2 should remain (pending)");
        assertFalse(harness.isDepositPending(address(depositVault), 3), "Request 3 should be removed");
        assertTrue(harness.isDepositPending(address(depositVault), 4), "Request 4 should remain (pending)");
    }

    // ============ cleanupPendingRedemptions Tests ============

    /// @dev Branch CR1: no pending requests, no-op
    function test_cleanupPendingRedemptions_ShouldNoOpWhenNoPendingRequests() public {
        // Given: no pending redemptions
        vm.recordLogs();
        harness.cleanupPendingRedemptions(address(redemptionVault), 0);
        assertEq(vm.getRecordedLogs().length, 0, "No events should be emitted");
    }

    /// @dev Branch CR2: all requests pending, none removed
    function test_cleanupPendingRedemptions_ShouldSkipAllWhenAllPending() public {
        // Given: 3 pending redemptions, all status=0
        harness.seedPendingRedemption(address(redemptionVault), 1);
        harness.seedPendingRedemption(address(redemptionVault), 2);
        harness.seedPendingRedemption(address(redemptionVault), 3);

        // When
        vm.recordLogs();
        harness.cleanupPendingRedemptions(address(redemptionVault), 0);

        // Then: none removed
        assertEq(vm.getRecordedLogs().length, 0, "No cleanup events should be emitted");
        assertTrue(harness.isRedemptionPending(address(redemptionVault), 1), "Request 1 should remain");
        assertTrue(harness.isRedemptionPending(address(redemptionVault), 2), "Request 2 should remain");
        assertTrue(harness.isRedemptionPending(address(redemptionVault), 3), "Request 3 should remain");
    }

    /// @dev Branch CR3: mixed pending/non-pending, only non-pending removed
    function test_cleanupPendingRedemptions_ShouldRemoveOnlyNonPendingRequests() public {
        // Given
        harness.seedPendingRedemption(address(redemptionVault), 1);
        harness.seedPendingRedemption(address(redemptionVault), 2);
        harness.seedPendingRedemption(address(redemptionVault), 3);
        redemptionVault.setRequestStatus(1, 1);   // processed
        // 2 stays pending
        redemptionVault.setRequestStatus(3, 2);   // canceled

        // When
        harness.cleanupPendingRedemptions(address(redemptionVault), 0);

        // Then
        assertFalse(harness.isRedemptionPending(address(redemptionVault), 1), "Request 1 should be removed");
        assertTrue(harness.isRedemptionPending(address(redemptionVault), 2), "Request 2 should remain");
        assertFalse(harness.isRedemptionPending(address(redemptionVault), 3), "Request 3 should be removed");
    }

    /// @dev Branch CR4: all non-pending, all removed
    function test_cleanupPendingRedemptions_ShouldRemoveAllWhenNonePending() public {
        // Given
        harness.seedPendingRedemption(address(redemptionVault), 5);
        harness.seedPendingRedemption(address(redemptionVault), 6);
        redemptionVault.setRequestStatus(5, 1);
        redemptionVault.setRequestStatus(6, 1);

        // When
        harness.cleanupPendingRedemptions(address(redemptionVault), 0);

        // Then
        assertEq(harness.getPendingRedemptionsForVault(address(redemptionVault)).length, 0, "All should be removed");
    }

    /// @dev Branch CR5: maxIterations limits processing (only 1 removed from end)
    function test_cleanupPendingRedemptions_ShouldRespectMaxIterationsLimit() public {
        // Given: 3 non-pending redemptions
        harness.seedPendingRedemption(address(redemptionVault), 1);
        harness.seedPendingRedemption(address(redemptionVault), 2);
        harness.seedPendingRedemption(address(redemptionVault), 3);
        redemptionVault.setRequestStatus(1, 1);
        redemptionVault.setRequestStatus(2, 1);
        redemptionVault.setRequestStatus(3, 1);

        // When: maxIterations_=1 => only last removed
        harness.cleanupPendingRedemptions(address(redemptionVault), 1);

        // Then: only ID 3 removed (last in array)
        assertTrue(harness.isRedemptionPending(address(redemptionVault), 1), "Request 1 should remain");
        assertTrue(harness.isRedemptionPending(address(redemptionVault), 2), "Request 2 should remain");
        assertFalse(harness.isRedemptionPending(address(redemptionVault), 3), "Request 3 should be removed");
    }

    /// @dev Branch CR7: pending don't count toward maxIterations
    function test_cleanupPendingRedemptions_ShouldNotCountPendingTowardIterations() public {
        // Given: [1=non-pending, 2=pending, 3=non-pending, 4=pending], maxIterations=1
        harness.seedPendingRedemption(address(redemptionVault), 1);
        harness.seedPendingRedemption(address(redemptionVault), 2);
        harness.seedPendingRedemption(address(redemptionVault), 3);
        harness.seedPendingRedemption(address(redemptionVault), 4);
        redemptionVault.setRequestStatus(1, 1);
        // 2 stays pending
        redemptionVault.setRequestStatus(3, 1);
        // 4 stays pending

        // When
        harness.cleanupPendingRedemptions(address(redemptionVault), 1);

        // Then: loop from end: 4=skip, 3=remove, iterations=1=break
        assertTrue(harness.isRedemptionPending(address(redemptionVault), 1), "Request 1 should remain");
        assertTrue(harness.isRedemptionPending(address(redemptionVault), 2), "Request 2 should remain (pending)");
        assertFalse(harness.isRedemptionPending(address(redemptionVault), 3), "Request 3 should be removed");
        assertTrue(harness.isRedemptionPending(address(redemptionVault), 4), "Request 4 should remain (pending)");
    }

    // ============ Internal Cleanup Tests (via enter/exit) ============

    /// @dev Branch ID4: all non-pending deposits cleaned via enter(amount=0)
    function test_enter_ShouldCleanAllNonPendingDepositsWithNoLimit() public {
        // Given: 3 deposit requests all status=1
        harness.seedPendingDeposit(address(depositVault), 1);
        harness.seedPendingDeposit(address(depositVault), 2);
        harness.seedPendingDeposit(address(depositVault), 3);
        depositVault.setRequestStatus(1, 1);
        depositVault.setRequestStatus(2, 1);
        depositVault.setRequestStatus(3, 1);

        MidasRequestSupplyFuseEnterData memory data = MidasRequestSupplyFuseEnterData({
            mToken: address(mToken),
            tokenIn: address(tokenIn),
            amount: 0,
            depositVault: address(depositVault)
        });

        // When
        harness.enter(data);

        // Then: all 3 removed
        assertEq(harness.getPendingDepositsForVault(address(depositVault)).length, 0, "All deposits should be cleaned");
    }

    /// @dev Branch IR4: all non-pending redemptions cleaned via exit(amount=0)
    function test_exit_ShouldCleanAllNonPendingRedemptionsWithNoLimit() public {
        // Given: 3 redemption requests all status=1
        harness.seedPendingRedemption(address(redemptionVault), 1);
        harness.seedPendingRedemption(address(redemptionVault), 2);
        harness.seedPendingRedemption(address(redemptionVault), 3);
        redemptionVault.setRequestStatus(1, 1);
        redemptionVault.setRequestStatus(2, 1);
        redemptionVault.setRequestStatus(3, 1);

        MidasRequestSupplyFuseExitData memory data = MidasRequestSupplyFuseExitData({
            mToken: address(mToken),
            amount: 0,
            tokenOut: address(tokenOut),
            standardRedemptionVault: address(redemptionVault)
        });

        // When
        harness.exit(data);

        // Then: all 3 removed
        assertEq(harness.getPendingRedemptionsForVault(address(redemptionVault)).length, 0, "All redemptions should be cleaned");
    }

    /// @dev Branch ID1: empty pending list graceful
    function test_enter_ShouldHandleEmptyPendingListGracefully() public {
        // Given: no pending deposits
        MidasRequestSupplyFuseEnterData memory data = MidasRequestSupplyFuseEnterData({
            mToken: address(mToken),
            tokenIn: address(tokenIn),
            amount: 0,
            depositVault: address(depositVault)
        });

        // When/Then: no revert
        harness.enter(data);
    }

    /// @dev Branch IR1: empty pending list graceful
    function test_exit_ShouldHandleEmptyPendingListGracefully() public {
        // Given: no pending redemptions
        MidasRequestSupplyFuseExitData memory data = MidasRequestSupplyFuseExitData({
            mToken: address(mToken),
            amount: 0,
            tokenOut: address(tokenOut),
            standardRedemptionVault: address(redemptionVault)
        });

        // When/Then: no revert
        harness.exit(data);
    }

    // ============ Fuzz Tests ============

    /// @dev Fuzz: finalAmount = min(balance, amount) for enter
    function test_enter_Fuzz_ShouldCapAmountToBalance(uint128 amount, uint128 balance) public {
        // Given
        vm.assume(amount > 0);
        vm.assume(balance > 0);
        _grantEnterSubstrates();
        tokenIn.setBalance(address(harness), balance);
        mockExecutor.setNextDepositRequestId(DEPOSIT_REQUEST_ID_1);

        uint256 expectedFinalAmount = amount < balance ? uint256(amount) : uint256(balance);

        MidasRequestSupplyFuseEnterData memory data = MidasRequestSupplyFuseEnterData({
            mToken: address(mToken),
            tokenIn: address(tokenIn),
            amount: uint256(amount),
            depositVault: address(depositVault)
        });

        // When
        harness.enter(data);

        // Then: executor received min(balance, amount)
        assertEq(
            mockExecutor.lastDepositAmount(),
            expectedFinalAmount,
            "Executor should receive min(balance, amount)"
        );
    }

    /// @dev Fuzz: finalAmount = min(balance, amount) for exit
    function test_exit_Fuzz_ShouldCapAmountToBalance(uint128 amount, uint128 balance) public {
        // Given
        vm.assume(amount > 0);
        vm.assume(balance > 0);
        _grantExitSubstrates();
        mToken.setBalance(address(harness), balance);
        mockExecutor.setNextRedeemRequestId(REDEEM_REQUEST_ID_3);

        uint256 expectedFinalAmount = amount < balance ? uint256(amount) : uint256(balance);

        MidasRequestSupplyFuseExitData memory data = MidasRequestSupplyFuseExitData({
            mToken: address(mToken),
            amount: uint256(amount),
            tokenOut: address(tokenOut),
            standardRedemptionVault: address(redemptionVault)
        });

        // When
        harness.exit(data);

        // Then
        assertEq(
            mockExecutor.lastRedeemAmount(),
            expectedFinalAmount,
            "Executor should receive min(balance, amount)"
        );
    }

    // ============ Edge Case / Boundary Tests ============

    /// @dev Boundary: balance == amount exactly
    function test_enter_ShouldWorkWhenBalanceExactlyEqualsAmount() public {
        // Given
        _grantEnterSubstrates();
        _mintTokenIn(1000e6);
        mockExecutor.setNextDepositRequestId(DEPOSIT_REQUEST_ID_1);
        MidasRequestSupplyFuseEnterData memory data = MidasRequestSupplyFuseEnterData({
            mToken: address(mToken),
            tokenIn: address(tokenIn),
            amount: 1000e6,
            depositVault: address(depositVault)
        });

        // When
        harness.enter(data);

        // Then: full amount transferred
        assertEq(mockExecutor.lastDepositAmount(), 1000e6, "Should transfer exact balance=amount");
    }

    /// @dev Boundary: amount=1 wei
    function test_enter_ShouldWorkWithAmountOfOne() public {
        // Given
        _grantEnterSubstrates();
        _mintTokenIn(1);
        mockExecutor.setNextDepositRequestId(DEPOSIT_REQUEST_ID_1);
        MidasRequestSupplyFuseEnterData memory data = MidasRequestSupplyFuseEnterData({
            mToken: address(mToken),
            tokenIn: address(tokenIn),
            amount: 1,
            depositVault: address(depositVault)
        });

        // When
        harness.enter(data);

        // Then
        assertEq(mockExecutor.lastDepositAmount(), 1, "Should transfer 1 wei");
    }

    /// @dev Boundary: large amount (type(uint128).max)
    function test_enter_ShouldWorkWithLargeAmount() public {
        // Given
        _grantEnterSubstrates();
        uint256 large = type(uint128).max;
        tokenIn.setBalance(address(harness), large);
        mockExecutor.setNextDepositRequestId(DEPOSIT_REQUEST_ID_1);
        MidasRequestSupplyFuseEnterData memory data = MidasRequestSupplyFuseEnterData({
            mToken: address(mToken),
            tokenIn: address(tokenIn),
            amount: large,
            depositVault: address(depositVault)
        });

        // When
        harness.enter(data);

        // Then: no overflow
        assertEq(mockExecutor.lastDepositAmount(), large, "Should transfer type(uint128).max without overflow");
    }

    /// @dev Boundary: balance == amount for exit
    function test_exit_ShouldWorkWhenBalanceExactlyEqualsAmount() public {
        // Given
        _grantExitSubstrates();
        _mintMToken(100e18);
        mockExecutor.setNextRedeemRequestId(REDEEM_REQUEST_ID_3);
        MidasRequestSupplyFuseExitData memory data = MidasRequestSupplyFuseExitData({
            mToken: address(mToken),
            amount: 100e18,
            tokenOut: address(tokenOut),
            standardRedemptionVault: address(redemptionVault)
        });

        // When
        harness.exit(data);

        // Then
        assertEq(mockExecutor.lastRedeemAmount(), 100e18, "Should transfer exact balance=amount");
    }

    /// @dev Boundary: amount=1 wei for exit
    function test_exit_ShouldWorkWithAmountOfOne() public {
        // Given
        _grantExitSubstrates();
        _mintMToken(1);
        mockExecutor.setNextRedeemRequestId(REDEEM_REQUEST_ID_3);
        MidasRequestSupplyFuseExitData memory data = MidasRequestSupplyFuseExitData({
            mToken: address(mToken),
            amount: 1,
            tokenOut: address(tokenOut),
            standardRedemptionVault: address(redemptionVault)
        });

        // When
        harness.exit(data);

        // Then
        assertEq(mockExecutor.lastRedeemAmount(), 1, "Should transfer 1 wei");
    }

    /// @dev Boundary: single request in cleanup
    function test_cleanupPendingDeposits_ShouldHandleSingleRequest() public {
        // Given: 1 non-pending request
        harness.seedPendingDeposit(address(depositVault), 99);
        depositVault.setRequestStatus(99, 1);

        // When
        harness.cleanupPendingDeposits(address(depositVault), 0);

        // Then
        assertFalse(harness.isDepositPending(address(depositVault), 99), "Request 99 should be removed");
        assertEq(harness.getPendingDepositsForVault(address(depositVault)).length, 0, "Vault should be empty");
    }

    /// @dev Boundary: maxIterations == requestIds.length
    function test_cleanupPendingDeposits_ShouldHandleMaxIterationsEqualToLength() public {
        // Given: 3 non-pending requests, maxIterations_=3
        harness.seedPendingDeposit(address(depositVault), 1);
        harness.seedPendingDeposit(address(depositVault), 2);
        harness.seedPendingDeposit(address(depositVault), 3);
        depositVault.setRequestStatus(1, 1);
        depositVault.setRequestStatus(2, 1);
        depositVault.setRequestStatus(3, 1);

        // When
        harness.cleanupPendingDeposits(address(depositVault), 3);

        // Then: all removed (limit exactly matches count)
        assertEq(harness.getPendingDepositsForVault(address(depositVault)).length, 0, "All should be removed");
    }

    /// @dev Boundary: maxIterations > requestIds.length
    function test_cleanupPendingDeposits_ShouldHandleMaxIterationsExceedingLength() public {
        // Given: 2 non-pending requests, maxIterations_=100
        harness.seedPendingDeposit(address(depositVault), 1);
        harness.seedPendingDeposit(address(depositVault), 2);
        depositVault.setRequestStatus(1, 1);
        depositVault.setRequestStatus(2, 1);

        // When
        harness.cleanupPendingDeposits(address(depositVault), 100);

        // Then: both removed, no out-of-bounds
        assertEq(harness.getPendingDepositsForVault(address(depositVault)).length, 0, "Both should be removed");
    }

    // ============ Cross-Iteration / Multi-Request Interaction Tests ============

    /// @dev Multiple deposits to same vault accumulate in storage
    function test_enter_MultipleDepositsToSameVault() public {
        // Given
        _grantEnterSubstrates();
        _mintTokenIn(300e6);
        mockExecutor.setNextDepositRequestId(DEPOSIT_REQUEST_ID_1);

        MidasRequestSupplyFuseEnterData memory data = MidasRequestSupplyFuseEnterData({
            mToken: address(mToken),
            tokenIn: address(tokenIn),
            amount: 100e6,
            depositVault: address(depositVault)
        });

        // When: first enter
        harness.enter(data);

        // Second enter with different requestId
        mockExecutor.setNextDepositRequestId(DEPOSIT_REQUEST_ID_2);
        data.amount = 50e6;
        harness.enter(data);

        // Then: both requestIds in pending storage
        assertTrue(harness.isDepositPending(address(depositVault), DEPOSIT_REQUEST_ID_1), "Request 1 should be pending");
        assertTrue(harness.isDepositPending(address(depositVault), DEPOSIT_REQUEST_ID_2), "Request 2 should be pending");
    }

    /// @dev Multiple deposits to different vaults are tracked independently
    function test_enter_MultipleDepositsToDifferentVaults() public {
        // Given
        MockMidasDepositVault vaultB = new MockMidasDepositVault(DEPOSIT_REQUEST_ID_2);
        vm.label(address(vaultB), "DepositVaultB");
        harness.grantSubstrate(MARKET_ID, MidasSubstrateType.M_TOKEN, address(mToken));
        harness.grantSubstrate(MARKET_ID, MidasSubstrateType.DEPOSIT_VAULT, address(depositVault));
        harness.grantSubstrate(MARKET_ID, MidasSubstrateType.DEPOSIT_VAULT, address(vaultB));
        harness.grantSubstrate(MARKET_ID, MidasSubstrateType.ASSET, address(tokenIn));
        _mintTokenIn(200e6);

        // When: enter vaultA
        mockExecutor.setNextDepositRequestId(DEPOSIT_REQUEST_ID_1);
        harness.enter(MidasRequestSupplyFuseEnterData({
            mToken: address(mToken),
            tokenIn: address(tokenIn),
            amount: 100e6,
            depositVault: address(depositVault)
        }));

        // Enter vaultB
        mockExecutor.setNextDepositRequestId(DEPOSIT_REQUEST_ID_2);
        harness.enter(MidasRequestSupplyFuseEnterData({
            mToken: address(mToken),
            tokenIn: address(tokenIn),
            amount: 50e6,
            depositVault: address(vaultB)
        }));

        // Then: each vault tracks its own requests independently
        assertTrue(harness.isDepositPending(address(depositVault), DEPOSIT_REQUEST_ID_1), "VaultA request should be pending");
        assertTrue(harness.isDepositPending(address(vaultB), DEPOSIT_REQUEST_ID_2), "VaultB request should be pending");
        assertFalse(harness.isDepositPending(address(depositVault), DEPOSIT_REQUEST_ID_2), "VaultA should not have request 2");
        assertFalse(harness.isDepositPending(address(vaultB), DEPOSIT_REQUEST_ID_1), "VaultB should not have request 1");
    }

    /// @dev Multiple redemptions to same vault accumulate
    function test_exit_MultipleRedemptionsToSameVault() public {
        // Given
        _grantExitSubstrates();
        _mintMToken(200e18);
        mockExecutor.setNextRedeemRequestId(REDEEM_REQUEST_ID_3);

        // When: first exit
        harness.exit(MidasRequestSupplyFuseExitData({
            mToken: address(mToken),
            amount: 50e18,
            tokenOut: address(tokenOut),
            standardRedemptionVault: address(redemptionVault)
        }));

        // Second exit
        mockExecutor.setNextRedeemRequestId(REDEEM_REQUEST_ID_4);
        harness.exit(MidasRequestSupplyFuseExitData({
            mToken: address(mToken),
            amount: 50e18,
            tokenOut: address(tokenOut),
            standardRedemptionVault: address(redemptionVault)
        }));

        // Then: both pending
        assertTrue(harness.isRedemptionPending(address(redemptionVault), REDEEM_REQUEST_ID_3), "Request 3 should be pending");
        assertTrue(harness.isRedemptionPending(address(redemptionVault), REDEEM_REQUEST_ID_4), "Request 4 should be pending");
    }

    /// @dev Enter then exit for same market tracks deposit and redemption independently
    function test_enter_ThenExit_SameMarket() public {
        // Given
        _grantEnterSubstrates();
        _grantExitSubstrates();
        _mintTokenIn(100e6);
        _mintMToken(50e18);

        // When: enter (deposit)
        mockExecutor.setNextDepositRequestId(DEPOSIT_REQUEST_ID_1);
        harness.enter(MidasRequestSupplyFuseEnterData({
            mToken: address(mToken),
            tokenIn: address(tokenIn),
            amount: 100e6,
            depositVault: address(depositVault)
        }));

        // exit (redeem)
        mockExecutor.setNextRedeemRequestId(REDEEM_REQUEST_ID_3);
        harness.exit(MidasRequestSupplyFuseExitData({
            mToken: address(mToken),
            amount: 50e18,
            tokenOut: address(tokenOut),
            standardRedemptionVault: address(redemptionVault)
        }));

        // Then: both tracked independently
        assertTrue(harness.isDepositPending(address(depositVault), DEPOSIT_REQUEST_ID_1), "Deposit request should be pending");
        assertTrue(harness.isRedemptionPending(address(redemptionVault), REDEEM_REQUEST_ID_3), "Redemption request should be pending");
    }

    /// @dev Mixed statuses processed in reverse order
    function test_cleanupPendingDeposits_WithMixedStatusesReverseOrder() public {
        // Given: [1=pending, 2=processed, 3=pending, 4=canceled, 5=processed]
        harness.seedPendingDeposit(address(depositVault), 1);
        harness.seedPendingDeposit(address(depositVault), 2);
        harness.seedPendingDeposit(address(depositVault), 3);
        harness.seedPendingDeposit(address(depositVault), 4);
        harness.seedPendingDeposit(address(depositVault), 5);
        // 1 stays pending
        depositVault.setRequestStatus(2, 1); // processed
        // 3 stays pending
        depositVault.setRequestStatus(4, 2); // canceled
        depositVault.setRequestStatus(5, 1); // processed

        // When
        harness.cleanupPendingDeposits(address(depositVault), 0);

        // Then: IDs 2, 4, 5 removed; 1, 3 remain
        assertTrue(harness.isDepositPending(address(depositVault), 1), "Request 1 should remain (pending)");
        assertFalse(harness.isDepositPending(address(depositVault), 2), "Request 2 should be removed (processed)");
        assertTrue(harness.isDepositPending(address(depositVault), 3), "Request 3 should remain (pending)");
        assertFalse(harness.isDepositPending(address(depositVault), 4), "Request 4 should be removed (canceled)");
        assertFalse(harness.isDepositPending(address(depositVault), 5), "Request 5 should be removed (processed)");
    }

    // ============ Event Verification Tests ============

    /// @dev Cleanup event emitted BEFORE enter event
    function test_enter_ShouldEmitCleanedDepositEventDuringCleanup() public {
        // Given: pre-populate pending deposit (ID 10, status=1)
        harness.seedPendingDeposit(address(depositVault), 10);
        depositVault.setRequestStatus(10, 1);
        _grantEnterSubstrates();
        _mintTokenIn(100e6);
        mockExecutor.setNextDepositRequestId(DEPOSIT_REQUEST_ID_1);

        // Then: expect cleanup event followed by enter event
        vm.expectEmit(true, true, false, true);
        emit MidasRequestSupplyFuse.MidasRequestSupplyFuseCleanedDeposit(address(depositVault), 10);

        vm.expectEmit(true, true, true, true);
        emit MidasRequestSupplyFuse.MidasRequestSupplyFuseEnter(
            fuse.VERSION(),
            address(mToken),
            100e6,
            address(tokenIn),
            DEPOSIT_REQUEST_ID_1,
            address(depositVault)
        );

        // When
        harness.enter(MidasRequestSupplyFuseEnterData({
            mToken: address(mToken),
            tokenIn: address(tokenIn),
            amount: 100e6,
            depositVault: address(depositVault)
        }));
    }

    /// @dev Cleanup event emitted BEFORE exit event
    function test_exit_ShouldEmitCleanedRedemptionEventDuringCleanup() public {
        // Given: pre-populate pending redemption (ID 10, status=1)
        harness.seedPendingRedemption(address(redemptionVault), 10);
        redemptionVault.setRequestStatus(10, 1);
        _grantExitSubstrates();
        _mintMToken(100e18);
        mockExecutor.setNextRedeemRequestId(REDEEM_REQUEST_ID_3);

        // Then: expect cleanup event followed by exit event
        vm.expectEmit(true, true, false, true);
        emit MidasRequestSupplyFuse.MidasRequestSupplyFuseCleanedRedemption(address(redemptionVault), 10);

        vm.expectEmit(true, true, true, true);
        emit MidasRequestSupplyFuse.MidasRequestSupplyFuseExit(
            fuse.VERSION(),
            address(mToken),
            100e18,
            address(tokenOut),
            REDEEM_REQUEST_ID_3,
            address(redemptionVault)
        );

        // When
        harness.exit(MidasRequestSupplyFuseExitData({
            mToken: address(mToken),
            amount: 100e18,
            tokenOut: address(tokenOut),
            standardRedemptionVault: address(redemptionVault)
        }));
    }

    /// @dev 3 cleanup events emitted for deposit cleanup
    function test_cleanupPendingDeposits_ShouldEmitEventForEachRemovedRequest() public {
        // Given: 3 non-pending requests (IDs 7,8,9)
        harness.seedPendingDeposit(address(depositVault), 7);
        harness.seedPendingDeposit(address(depositVault), 8);
        harness.seedPendingDeposit(address(depositVault), 9);
        depositVault.setRequestStatus(7, 1);
        depositVault.setRequestStatus(8, 1);
        depositVault.setRequestStatus(9, 1);

        // When
        vm.recordLogs();
        harness.cleanupPendingDeposits(address(depositVault), 0);

        // Then: 3 events emitted
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("MidasRequestSupplyFuseCleanedDeposit(address,uint256)");
        uint256 eventCount;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                eventCount++;
            }
        }
        assertEq(eventCount, 3, "Should emit 3 MidasRequestSupplyFuseCleanedDeposit events");
    }

    /// @dev 3 cleanup events emitted for redemption cleanup
    function test_cleanupPendingRedemptions_ShouldEmitEventForEachRemovedRequest() public {
        // Given: 3 non-pending requests (IDs 7,8,9)
        harness.seedPendingRedemption(address(redemptionVault), 7);
        harness.seedPendingRedemption(address(redemptionVault), 8);
        harness.seedPendingRedemption(address(redemptionVault), 9);
        redemptionVault.setRequestStatus(7, 1);
        redemptionVault.setRequestStatus(8, 1);
        redemptionVault.setRequestStatus(9, 1);

        // When
        vm.recordLogs();
        harness.cleanupPendingRedemptions(address(redemptionVault), 0);

        // Then: 3 events emitted
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("MidasRequestSupplyFuseCleanedRedemption(address,uint256)");
        uint256 eventCount;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                eventCount++;
            }
        }
        assertEq(eventCount, 3, "Should emit 3 MidasRequestSupplyFuseCleanedRedemption events");
    }
}
