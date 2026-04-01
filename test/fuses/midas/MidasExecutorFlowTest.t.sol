// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {MidasExecutor} from "../../../contracts/fuses/midas/MidasExecutor.sol";
import {MidasRequestSupplyFuse, MidasRequestSupplyFuseEnterData, MidasRequestSupplyFuseExitData} from "../../../contracts/fuses/midas/MidasRequestSupplyFuse.sol";
import {MidasClaimFromExecutorFuse, MidasClaimFromExecutorFuseEnterData} from "../../../contracts/fuses/midas/MidasClaimFromExecutorFuse.sol";
import {MidasBalanceFuse} from "../../../contracts/fuses/midas/MidasBalanceFuse.sol";
import {IMidasDepositVault} from "../../../contracts/fuses/midas/ext/IMidasDepositVault.sol";
import {IMidasRedemptionVault} from "../../../contracts/fuses/midas/ext/IMidasRedemptionVault.sol";
import {IMidasDataFeed} from "../../../contracts/fuses/midas/ext/IMidasDataFeed.sol";
import {MidasSubstrateLib, MidasSubstrate, MidasSubstrateType} from "../../../contracts/fuses/midas/lib/MidasSubstrateLib.sol";
import {MidasPendingRequestsStorageLib} from "../../../contracts/fuses/midas/lib/MidasPendingRequestsStorageLib.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {IPriceOracleMiddleware} from "../../../contracts/price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";
import {MidasPendingRequestsHelper} from "./MidasPendingRequestsHelper.sol";
import {Errors} from "../../../contracts/libraries/errors/Errors.sol";

/// @title MidasExecutorFlowTest
/// @notice Comprehensive tests for the MidasExecutor pattern covering:
///         - MidasExecutor unit tests (constructor, authorization, claimAssets)
///         - Executor deployment (lazy + explicit via deployExecutor)
///         - Deposit flow through executor
///         - Redemption flow through executor
///         - Claim fuse tests
///         - Full lifecycle tests (deposit + claim, redemption + claim)
///         - Balance fuse double-counting verification
contract MidasExecutorFlowTest is Test {
    address public constant MTBILL_TOKEN = 0xDD629E5241CbC5919847783e6C96B2De4754e438;
    address public constant MBASIS_TOKEN = 0x2a8c22E3b10036f3AEF5875d04f8441d4188b656;
    address public constant MTBILL_DEPOSIT_VAULT = 0x99361435420711723aF805F08187c9E6bF796683;
    address public constant MBASIS_DEPOSIT_VAULT = 0xa8a5c4FF4c86a459EBbDC39c5BE77833B3A15d88;
    address public constant MTBILL_REDEMPTION_VAULT = 0xF6e51d24F4793Ac5e71e0502213a9BBE3A6d4517;
    address public constant MBASIS_REDEMPTION_VAULT = 0x19AB19e61A930bc5C7B75Bf06cDd954218Ca9F0b;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint256 public constant MARKET_ID = IporFusionMarkets.MIDAS;
    uint256 public constant FORK_BLOCK = 21800000;

    // Mock data feed price: ~$1.07 per mTBILL (18 decimals)
    uint256 public constant MOCK_MTBILL_PRICE = 1_070000000000000000;

    MidasRequestSupplyFuse public requestFuse;
    MidasClaimFromExecutorFuse public claimFuse;
    MidasBalanceFuse public balanceFuse;
    MidasPendingRequestsHelper public storageHelper;
    PlasmaVaultMock public vault;

    // Mock price oracle address
    address public constant MOCK_PRICE_ORACLE = address(0xBEEF);

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), FORK_BLOCK);

        requestFuse = new MidasRequestSupplyFuse(MARKET_ID);
        claimFuse = new MidasClaimFromExecutorFuse(MARKET_ID);
        balanceFuse = new MidasBalanceFuse(MARKET_ID);
        storageHelper = new MidasPendingRequestsHelper();
        vault = new PlasmaVaultMock(address(requestFuse), address(balanceFuse));

        bytes32[] memory substrates = new bytes32[](7);
        substrates[0] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.M_TOKEN, substrateAddress: MTBILL_TOKEN})
        );
        substrates[1] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.DEPOSIT_VAULT, substrateAddress: MTBILL_DEPOSIT_VAULT})
        );
        substrates[2] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.M_TOKEN, substrateAddress: MBASIS_TOKEN})
        );
        substrates[3] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.DEPOSIT_VAULT, substrateAddress: MBASIS_DEPOSIT_VAULT})
        );
        substrates[4] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.ASSET, substrateAddress: USDC})
        );
        substrates[5] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({
                substrateType: MidasSubstrateType.REDEMPTION_VAULT,
                substrateAddress: MTBILL_REDEMPTION_VAULT
            })
        );
        substrates[6] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({
                substrateType: MidasSubstrateType.REDEMPTION_VAULT,
                substrateAddress: MBASIS_REDEMPTION_VAULT
            })
        );
        vault.grantMarketSubstrates(MARKET_ID, substrates);

        // Mock mToken() and mTokenDataFeed() on deposit vaults
        vm.mockCall(
            MTBILL_DEPOSIT_VAULT,
            abi.encodeWithSelector(IMidasDepositVault.mToken.selector),
            abi.encode(MTBILL_TOKEN)
        );
        address mtbillDataFeed = _mockDataFeedAddress(MTBILL_DEPOSIT_VAULT);
        vm.mockCall(
            mtbillDataFeed,
            abi.encodeWithSelector(IMidasDataFeed.getDataInBase18.selector),
            abi.encode(MOCK_MTBILL_PRICE)
        );

        vm.mockCall(
            MBASIS_DEPOSIT_VAULT,
            abi.encodeWithSelector(IMidasDepositVault.mToken.selector),
            abi.encode(MBASIS_TOKEN)
        );
        address mbasisDataFeed = _mockDataFeedAddress(MBASIS_DEPOSIT_VAULT);
        vm.mockCall(
            mbasisDataFeed,
            abi.encodeWithSelector(IMidasDataFeed.getDataInBase18.selector),
            abi.encode(MOCK_MTBILL_PRICE) // reuse price for simplicity
        );

        // Mock mToken() on redemption vaults
        vm.mockCall(
            MTBILL_REDEMPTION_VAULT,
            abi.encodeWithSelector(IMidasRedemptionVault.mToken.selector),
            abi.encode(MTBILL_TOKEN)
        );
        vm.mockCall(
            MBASIS_REDEMPTION_VAULT,
            abi.encodeWithSelector(IMidasRedemptionVault.mToken.selector),
            abi.encode(MBASIS_TOKEN)
        );

        // Mock mintRequests to return empty/default by default (so cleanup in enter/exit doesn't interfere)
        vm.mockCall(
            MTBILL_DEPOSIT_VAULT,
            abi.encodeWithSignature("mintRequests(uint256)"),
            abi.encode(
                IMidasDepositVault.Request({
                    sender: address(0),
                    tokenIn: address(0),
                    status: 0,
                    depositedUsdAmount: 0,
                    usdAmountWithoutFees: 0,
                    tokenOutRate: 0
                })
            )
        );
        vm.mockCall(
            MTBILL_REDEMPTION_VAULT,
            abi.encodeWithSignature("redeemRequests(uint256)"),
            abi.encode(
                IMidasRedemptionVault.Request({
                    sender: address(0),
                    tokenOut: address(0),
                    status: 0,
                    amountMToken: 0,
                    mTokenRate: 0,
                    tokenOutRate: 0
                })
            )
        );

        vm.label(address(requestFuse), "MidasRequestSupplyFuse");
        vm.label(address(claimFuse), "MidasClaimFromExecutorFuse");
        vm.label(address(balanceFuse), "MidasBalanceFuse");
        vm.label(address(storageHelper), "MidasPendingRequestsHelper");
        vm.label(address(vault), "PlasmaVaultMock");
        vm.label(MTBILL_TOKEN, "mTBILL");
        vm.label(MBASIS_TOKEN, "mBASIS");
        vm.label(MTBILL_DEPOSIT_VAULT, "MidasDepositVault");
        vm.label(MBASIS_DEPOSIT_VAULT, "MidasBasisDepositVault");
        vm.label(MTBILL_REDEMPTION_VAULT, "MidasRedemptionVault");
        vm.label(MBASIS_REDEMPTION_VAULT, "MidasBasisRedemptionVault");
        vm.label(USDC, "USDC");
    }

    // ============ Helpers ============

    /// @dev Helper: mock mTokenDataFeed() on a deposit vault and return the data feed address
    function _mockDataFeedAddress(address depositVault_) internal returns (address dataFeed) {
        dataFeed = address(uint160(uint256(keccak256(abi.encodePacked("dataFeed", depositVault_)))));
        vm.mockCall(
            depositVault_,
            abi.encodeWithSelector(IMidasDepositVault.mTokenDataFeed.selector),
            abi.encode(dataFeed)
        );
        vm.label(dataFeed, string.concat("MockDataFeed_", vm.toString(depositVault_)));
    }

    /// @dev Helper: read the executor address directly from the ERC-7201 storage slot on the vault
    function _readExecutorSlot() internal view returns (address) {
        // MIDAS_EXECUTOR_SLOT = 0x70d197bb241b100c004ed80fc4b87ce41500fa5c47b2ad133730792ea68d7d00
        bytes32 slot = 0x70d197bb241b100c004ed80fc4b87ce41500fa5c47b2ad133730792ea68d7d00;
        bytes32 value = vm.load(address(vault), slot);
        return address(uint160(uint256(value)));
    }

    /// @dev Helper: deploy executor via the claim fuse's deployExecutor() through vault delegatecall
    function _deployExecutor() internal returns (address executor) {
        vault.execute(
            address(claimFuse),
            abi.encodeWithSignature("deployExecutor()")
        );
        executor = _readExecutorSlot();
    }

    /// @dev Helper: perform a deposit enter() and return the executor address
    function _enterDeposit(uint256 usdcAmount, uint256 mockRequestId) internal returns (address executor) {
        deal(USDC, address(vault), usdcAmount);

        vm.mockCall(
            MTBILL_DEPOSIT_VAULT,
            abi.encodeWithSignature("depositRequest(address,uint256,bytes32)"),
            abi.encode(mockRequestId)
        );

        vault.enterMidasRequestSupply(
            MidasRequestSupplyFuseEnterData({
                mToken: MTBILL_TOKEN,
                tokenIn: USDC,
                amount: usdcAmount,
                depositVault: MTBILL_DEPOSIT_VAULT
            })
        );

        executor = _readExecutorSlot();
    }

    /// @dev Helper: perform a redemption exit() and return the executor address
    function _exitRedemption(uint256 mTokenAmount, uint256 mockRequestId) internal returns (address executor) {
        deal(MTBILL_TOKEN, address(vault), mTokenAmount);

        vm.mockCall(
            MTBILL_REDEMPTION_VAULT,
            abi.encodeWithSignature("redeemRequest(address,uint256)"),
            abi.encode(mockRequestId)
        );

        vault.exitMidasRequestSupply(
            MidasRequestSupplyFuseExitData({
                mToken: MTBILL_TOKEN,
                amount: mTokenAmount,
                tokenOut: USDC,
                standardRedemptionVault: MTBILL_REDEMPTION_VAULT
            })
        );

        executor = _readExecutorSlot();
    }

    /// @dev Helper: add a pending deposit to vault's storage via delegatecall
    function _addPendingDeposit(address depositVault_, uint256 requestId_) internal {
        vault.execute(
            address(storageHelper),
            abi.encodeWithSelector(MidasPendingRequestsHelper.addPendingDeposit.selector, depositVault_, requestId_)
        );
    }

    /// @dev Helper: add a pending redemption to vault's storage via delegatecall
    function _addPendingRedemption(address redemptionVault_, uint256 requestId_) internal {
        vault.execute(
            address(storageHelper),
            abi.encodeWithSelector(
                MidasPendingRequestsHelper.addPendingRedemption.selector, redemptionVault_, requestId_
            )
        );
    }

    /// @dev Helper: call balanceOf on the vault through the balance fuse (delegatecall)
    function _getBalance() internal returns (uint256) {
        return vault.balanceOf();
    }

    // ============ MidasExecutor Unit Tests ============

    function testShouldExecutorConstructorSetPlasmaVault() public {
        MidasExecutor executor = new MidasExecutor(address(vault));
        assertEq(executor.PLASMA_VAULT(), address(vault), "PLASMA_VAULT should be set to vault address");
    }

    function testShouldExecutorRevertWhenCallerNotPlasmaVault() public {
        MidasExecutor executor = new MidasExecutor(address(vault));

        // Call from a non-vault address
        address attacker = address(0xBAD);
        vm.prank(attacker);
        vm.expectRevert(MidasExecutor.MidasExecutorUnauthorizedCaller.selector);
        executor.depositRequest(USDC, 1000e6, MTBILL_DEPOSIT_VAULT);

        vm.prank(attacker);
        vm.expectRevert(MidasExecutor.MidasExecutorUnauthorizedCaller.selector);
        executor.redeemRequest(MTBILL_TOKEN, 100e18, USDC, MTBILL_REDEMPTION_VAULT);

        vm.prank(attacker);
        vm.expectRevert(MidasExecutor.MidasExecutorUnauthorizedCaller.selector);
        executor.claimAssets(USDC);
    }

    function testShouldExecutorRevertWhenPlasmaVaultAddressZero() public {
        vm.expectRevert(MidasExecutor.MidasExecutorInvalidPlasmaVaultAddress.selector);
        new MidasExecutor(address(0));
    }

    function testShouldExecutorClaimAssetsTransferToPlasmaVault() public {
        MidasExecutor executor = new MidasExecutor(address(this));

        // Deal tokens to executor
        uint256 tokenAmount = 500e6;
        deal(USDC, address(executor), tokenAmount);

        uint256 balanceBefore = IERC20(USDC).balanceOf(address(this));
        uint256 amount = executor.claimAssets(USDC);
        uint256 balanceAfter = IERC20(USDC).balanceOf(address(this));

        assertEq(amount, tokenAmount, "claimAssets should return the full balance");
        assertEq(balanceAfter - balanceBefore, tokenAmount, "Tokens should be transferred to PlasmaVault");
        assertEq(IERC20(USDC).balanceOf(address(executor)), 0, "Executor should have zero balance after claim");
    }

    function testShouldExecutorClaimAssetsReturnZeroWhenNoBalance() public {
        MidasExecutor executor = new MidasExecutor(address(this));

        uint256 amount = executor.claimAssets(USDC);
        assertEq(amount, 0, "claimAssets should return 0 when executor has no balance");
    }

    // ============ Executor Deployment Tests ============

    function testShouldDeployExecutorCreateNewExecutor() public {
        address executor = _deployExecutor();
        assertTrue(executor != address(0), "Executor should be deployed (non-zero address)");

        // Verify the executor's PLASMA_VAULT is the vault
        assertEq(
            MidasExecutor(executor).PLASMA_VAULT(),
            address(vault),
            "Executor PLASMA_VAULT should be the vault"
        );
    }

    function testShouldDeployExecutorIdempotent() public {
        address executor1 = _deployExecutor();
        address executor2 = _readExecutorSlot();

        // Call deployExecutor again
        vault.execute(
            address(claimFuse),
            abi.encodeWithSignature("deployExecutor()")
        );
        address executor3 = _readExecutorSlot();

        assertEq(executor1, executor2, "Executor address should be stable after first deploy");
        assertEq(executor1, executor3, "Calling deployExecutor twice should return the same address");
    }

    function testShouldEnterCreateExecutorOnFirstCall() public {
        // Before enter, no executor should exist
        assertEq(_readExecutorSlot(), address(0), "No executor should exist before first enter()");

        uint256 usdcAmount = 100_000e6;
        uint256 mockRequestId = 42;

        // Perform enter which should create executor lazily
        address executor = _enterDeposit(usdcAmount, mockRequestId);

        assertTrue(executor != address(0), "Executor should be created during first enter() call");
        assertEq(
            MidasExecutor(executor).PLASMA_VAULT(),
            address(vault),
            "Lazily deployed executor should have correct PLASMA_VAULT"
        );
    }

    // ============ Deposit Flow Through Executor Tests ============

    function testShouldDepositFlowTransferUsdcToExecutor() public {
        uint256 usdcAmount = 100_000e6;
        uint256 mockRequestId = 42;

        deal(USDC, address(vault), usdcAmount);

        vm.mockCall(
            MTBILL_DEPOSIT_VAULT,
            abi.encodeWithSignature("depositRequest(address,uint256,bytes32)"),
            abi.encode(mockRequestId)
        );

        uint256 vaultUsdcBefore = IERC20(USDC).balanceOf(address(vault));

        vault.enterMidasRequestSupply(
            MidasRequestSupplyFuseEnterData({
                mToken: MTBILL_TOKEN,
                tokenIn: USDC,
                amount: usdcAmount,
                depositVault: MTBILL_DEPOSIT_VAULT
            })
        );

        uint256 vaultUsdcAfter = IERC20(USDC).balanceOf(address(vault));

        // Vault USDC should decrease (transferred to executor which forwarded to mock)
        assertEq(vaultUsdcAfter, 0, "Vault should have no USDC after deposit (transferred to executor)");
        assertEq(vaultUsdcBefore, usdcAmount, "Vault should have had USDC before deposit");
    }

    function testShouldDepositFlowExecutorCallDepositRequest() public {
        uint256 usdcAmount = 100_000e6;
        uint256 mockRequestId = 42;

        deal(USDC, address(vault), usdcAmount);

        vm.mockCall(
            MTBILL_DEPOSIT_VAULT,
            abi.encodeWithSignature("depositRequest(address,uint256,bytes32)"),
            abi.encode(mockRequestId)
        );

        // The fact that enter() succeeds (doesn't revert on requestId == 0) proves depositRequest was called
        vm.expectEmit(true, true, true, true);
        emit MidasRequestSupplyFuse.MidasRequestSupplyFuseEnter(
            requestFuse.VERSION(), MTBILL_TOKEN, usdcAmount, USDC, mockRequestId, MTBILL_DEPOSIT_VAULT
        );

        vault.enterMidasRequestSupply(
            MidasRequestSupplyFuseEnterData({
                mToken: MTBILL_TOKEN,
                tokenIn: USDC,
                amount: usdcAmount,
                depositVault: MTBILL_DEPOSIT_VAULT
            })
        );
    }

    function testShouldDepositFlowStoreRequestId() public {
        uint256 usdcAmount = 100_000e6;
        uint256 mockRequestId = 42;

        _enterDeposit(usdcAmount, mockRequestId);

        // Verify by trying to add the same requestId (should revert with duplicate)
        deal(USDC, address(vault), usdcAmount);
        vm.mockCall(
            MTBILL_DEPOSIT_VAULT,
            abi.encodeWithSignature("depositRequest(address,uint256,bytes32)"),
            abi.encode(mockRequestId)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                MidasPendingRequestsStorageLib.MidasPendingStorageRequestAlreadyExists.selector,
                MTBILL_DEPOSIT_VAULT,
                mockRequestId
            )
        );
        vault.enterMidasRequestSupply(
            MidasRequestSupplyFuseEnterData({
                mToken: MTBILL_TOKEN,
                tokenIn: USDC,
                amount: usdcAmount,
                depositVault: MTBILL_DEPOSIT_VAULT
            })
        );
    }

    // ============ Redemption Flow Through Executor Tests ============

    function testShouldRedemptionFlowTransferMTokensToExecutor() public {
        uint256 mTokenAmount = 100e18;
        uint256 mockRequestId = 55;

        deal(MTBILL_TOKEN, address(vault), mTokenAmount);

        vm.mockCall(
            MTBILL_REDEMPTION_VAULT,
            abi.encodeWithSignature("redeemRequest(address,uint256)"),
            abi.encode(mockRequestId)
        );

        uint256 vaultMTokenBefore = IERC20(MTBILL_TOKEN).balanceOf(address(vault));

        vault.exitMidasRequestSupply(
            MidasRequestSupplyFuseExitData({
                mToken: MTBILL_TOKEN,
                amount: mTokenAmount,
                tokenOut: USDC,
                standardRedemptionVault: MTBILL_REDEMPTION_VAULT
            })
        );

        uint256 vaultMTokenAfter = IERC20(MTBILL_TOKEN).balanceOf(address(vault));

        assertEq(vaultMTokenBefore, mTokenAmount, "Vault should have had mTokens before redemption");
        assertEq(vaultMTokenAfter, 0, "Vault should have no mTokens after redemption (transferred to executor)");
    }

    function testShouldRedemptionFlowExecutorCallRedeemRequest() public {
        uint256 mTokenAmount = 100e18;
        uint256 mockRequestId = 55;

        deal(MTBILL_TOKEN, address(vault), mTokenAmount);

        vm.mockCall(
            MTBILL_REDEMPTION_VAULT,
            abi.encodeWithSignature("redeemRequest(address,uint256)"),
            abi.encode(mockRequestId)
        );

        vm.expectEmit(true, true, true, true);
        emit MidasRequestSupplyFuse.MidasRequestSupplyFuseExit(
            requestFuse.VERSION(), MTBILL_TOKEN, mTokenAmount, USDC, mockRequestId, MTBILL_REDEMPTION_VAULT
        );

        vault.exitMidasRequestSupply(
            MidasRequestSupplyFuseExitData({
                mToken: MTBILL_TOKEN,
                amount: mTokenAmount,
                tokenOut: USDC,
                standardRedemptionVault: MTBILL_REDEMPTION_VAULT
            })
        );
    }

    function testShouldRedemptionFlowStoreRequestId() public {
        uint256 mTokenAmount = 100e18;
        uint256 mockRequestId = 55;

        _exitRedemption(mTokenAmount, mockRequestId);

        // Verify storage by trying to add duplicate (should revert)
        deal(MTBILL_TOKEN, address(vault), mTokenAmount);
        vm.mockCall(
            MTBILL_REDEMPTION_VAULT,
            abi.encodeWithSignature("redeemRequest(address,uint256)"),
            abi.encode(mockRequestId)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                MidasPendingRequestsStorageLib.MidasPendingStorageRequestAlreadyExists.selector,
                MTBILL_REDEMPTION_VAULT,
                mockRequestId
            )
        );
        vault.exitMidasRequestSupply(
            MidasRequestSupplyFuseExitData({
                mToken: MTBILL_TOKEN,
                amount: mTokenAmount,
                tokenOut: USDC,
                standardRedemptionVault: MTBILL_REDEMPTION_VAULT
            })
        );
    }

    // ============ Claim Fuse Tests ============

    function testShouldClaimFuseTransferMTokensFromExecutorToVault() public {
        uint256 usdcAmount = 100_000e6;
        uint256 mockRequestId = 42;

        // Step 1: enter() deposits USDC through executor
        address executor = _enterDeposit(usdcAmount, mockRequestId);

        // Step 2: simulate Midas admin approval by dealing mTokens to executor
        uint256 mTokensToDeliver = 93_000e18; // ~93k mTBILL for 100k USDC
        deal(MTBILL_TOKEN, executor, mTokensToDeliver);

        // Step 3: claim mTokens from executor to vault
        uint256 vaultMTokenBefore = IERC20(MTBILL_TOKEN).balanceOf(address(vault));

        vault.execute(
            address(claimFuse),
            abi.encodeWithSignature("enter((address))", MidasClaimFromExecutorFuseEnterData({token: MTBILL_TOKEN}))
        );

        uint256 vaultMTokenAfter = IERC20(MTBILL_TOKEN).balanceOf(address(vault));
        uint256 executorMTokenAfter = IERC20(MTBILL_TOKEN).balanceOf(executor);

        assertEq(vaultMTokenAfter - vaultMTokenBefore, mTokensToDeliver, "Vault should receive mTokens from executor");
        assertEq(executorMTokenAfter, 0, "Executor should have zero mTokens after claim");
    }

    function testShouldClaimFuseTransferUsdcFromExecutorToVault() public {
        uint256 mTokenAmount = 100e18;
        uint256 mockRequestId = 55;

        // Step 1: exit() redeems mTokens through executor
        address executor = _exitRedemption(mTokenAmount, mockRequestId);

        // Step 2: simulate Midas admin approval by dealing USDC to executor
        uint256 usdcToDeliver = 107_000e6; // ~107k USDC for 100 mTBILL
        deal(USDC, executor, usdcToDeliver);

        // Step 3: claim USDC from executor to vault
        uint256 vaultUsdcBefore = IERC20(USDC).balanceOf(address(vault));

        vault.execute(
            address(claimFuse),
            abi.encodeWithSignature("enter((address))", MidasClaimFromExecutorFuseEnterData({token: USDC}))
        );

        uint256 vaultUsdcAfter = IERC20(USDC).balanceOf(address(vault));
        uint256 executorUsdcAfter = IERC20(USDC).balanceOf(executor);

        assertEq(vaultUsdcAfter - vaultUsdcBefore, usdcToDeliver, "Vault should receive USDC from executor");
        assertEq(executorUsdcAfter, 0, "Executor should have zero USDC after claim");
    }

    function testShouldClaimFuseRevertWhenExecutorNotDeployed() public {
        // Fresh vault without any prior enter/exit (no executor deployed)
        MidasClaimFromExecutorFuse freshClaimFuse = new MidasClaimFromExecutorFuse(MARKET_ID);
        MidasRequestSupplyFuse freshRequestFuse = new MidasRequestSupplyFuse(MARKET_ID);
        PlasmaVaultMock freshVault = new PlasmaVaultMock(address(freshRequestFuse), address(0));

        // Grant substrates to the fresh vault
        bytes32[] memory subs = new bytes32[](2);
        subs[0] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.M_TOKEN, substrateAddress: MTBILL_TOKEN})
        );
        subs[1] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.ASSET, substrateAddress: USDC})
        );
        freshVault.grantMarketSubstrates(MARKET_ID, subs);

        vm.expectRevert(MidasClaimFromExecutorFuse.MidasClaimFromExecutorFuseExecutorNotDeployed.selector);
        freshVault.execute(
            address(freshClaimFuse),
            abi.encodeWithSignature("enter((address))", MidasClaimFromExecutorFuseEnterData({token: MTBILL_TOKEN}))
        );
    }

    function testShouldClaimFuseRevertWhenTokenNotGranted() public {
        // Deploy executor first
        _deployExecutor();

        // Try to claim a non-granted token (some random address)
        address randomToken = address(0x1234);

        vm.expectRevert(
            abi.encodeWithSelector(
                MidasClaimFromExecutorFuse.MidasClaimFromExecutorFuseTokenNotGranted.selector,
                randomToken
            )
        );
        vault.execute(
            address(claimFuse),
            abi.encodeWithSignature("enter((address))", MidasClaimFromExecutorFuseEnterData({token: randomToken}))
        );
    }

    function testShouldClaimFuseEmitEvent() public {
        uint256 usdcAmount = 100_000e6;
        uint256 mockRequestId = 42;

        address executor = _enterDeposit(usdcAmount, mockRequestId);

        // Simulate Midas approval
        uint256 mTokensToDeliver = 93_000e18;
        deal(MTBILL_TOKEN, executor, mTokensToDeliver);

        vm.expectEmit(true, true, true, true);
        emit MidasClaimFromExecutorFuse.MidasClaimFromExecutorFuseClaimed(
            claimFuse.VERSION(), MTBILL_TOKEN, mTokensToDeliver
        );

        vault.execute(
            address(claimFuse),
            abi.encodeWithSignature("enter((address))", MidasClaimFromExecutorFuseEnterData({token: MTBILL_TOKEN}))
        );
    }

    // ============ Full Lifecycle Tests ============

    function testShouldFullDepositLifecycle() public {
        // Phase 1: Vault has USDC, requests deposit via enter()
        uint256 usdcAmount = 100_000e6;
        uint256 mockRequestId = 42;

        address executor = _enterDeposit(usdcAmount, mockRequestId);

        // Verify: vault has no USDC (transferred to executor which forwarded to Midas mock)
        assertEq(IERC20(USDC).balanceOf(address(vault)), 0, "Vault should have 0 USDC after enter");

        // Phase 2: Midas admin approves deposit, mints mTokens to executor
        uint256 mTokensApproved = 93_457e18;
        deal(MTBILL_TOKEN, executor, mTokensApproved);

        // Verify: executor holds mTokens, vault does not
        assertEq(IERC20(MTBILL_TOKEN).balanceOf(executor), mTokensApproved, "Executor should hold mTokens");
        assertEq(IERC20(MTBILL_TOKEN).balanceOf(address(vault)), 0, "Vault should have 0 mTokens before claim");

        // Phase 3: Keeper calls claim fuse to pull mTokens from executor to vault
        vault.execute(
            address(claimFuse),
            abi.encodeWithSignature("enter((address))", MidasClaimFromExecutorFuseEnterData({token: MTBILL_TOKEN}))
        );

        // Verify: vault now holds mTokens, executor is empty
        assertEq(
            IERC20(MTBILL_TOKEN).balanceOf(address(vault)),
            mTokensApproved,
            "Vault should hold all mTokens after claim"
        );
        assertEq(IERC20(MTBILL_TOKEN).balanceOf(executor), 0, "Executor should be empty after claim");
    }

    function testShouldFullRedemptionLifecycle() public {
        // Phase 1: Vault has mTokens, requests redemption via exit()
        uint256 mTokenAmount = 100e18;
        uint256 mockRequestId = 55;

        address executor = _exitRedemption(mTokenAmount, mockRequestId);

        // Verify: vault has no mTokens (transferred to executor which forwarded to Midas mock)
        assertEq(IERC20(MTBILL_TOKEN).balanceOf(address(vault)), 0, "Vault should have 0 mTokens after exit");

        // Phase 2: Midas admin approves redemption, sends USDC to executor
        uint256 usdcApproved = 107_000e6;
        deal(USDC, executor, usdcApproved);

        // Verify: executor holds USDC, vault does not
        assertEq(IERC20(USDC).balanceOf(executor), usdcApproved, "Executor should hold USDC");
        assertEq(IERC20(USDC).balanceOf(address(vault)), 0, "Vault should have 0 USDC before claim");

        // Phase 3: Keeper calls claim fuse to pull USDC from executor to vault
        vault.execute(
            address(claimFuse),
            abi.encodeWithSignature("enter((address))", MidasClaimFromExecutorFuseEnterData({token: USDC}))
        );

        // Verify: vault now holds USDC, executor is empty
        assertEq(IERC20(USDC).balanceOf(address(vault)), usdcApproved, "Vault should hold all USDC after claim");
        assertEq(IERC20(USDC).balanceOf(executor), 0, "Executor should be empty after claim");
    }

    function testShouldNoDoubleCountingAfterApproval() public {
        // This test verifies the key fix: when Midas approves a deposit and mints mTokens
        // to the executor, the balance fuse should count those mTokens on the executor
        // (component D) but NOT also count them as pending deposits (component B).
        //
        // The pending deposit tracking in storage still has the requestId until cleanup,
        // but the balance fuse only counts requests with status == Pending (0).
        // After Midas processes the request, status changes to Processed (1),
        // so the pending value becomes 0, while executor balance picks up the mTokens.

        uint256 usdcAmount = 100_000e6;
        uint256 mockRequestId = 42;

        // Step 1: enter() to deposit
        address executor = _enterDeposit(usdcAmount, mockRequestId);

        // Step 2: Set up price oracle for balance fuse (needed for executor asset valuation)
        vault.setPriceOracleMiddleware(MOCK_PRICE_ORACLE);
        vm.mockCall(
            MOCK_PRICE_ORACLE,
            abi.encodeWithSelector(IPriceOracleMiddleware.getAssetPrice.selector, USDC),
            abi.encode(uint256(1e6), uint256(6)) // $1 with 6 decimals
        );

        // Step 3: Mock pending deposit request as Pending (status=0)
        vm.mockCall(
            MTBILL_DEPOSIT_VAULT,
            abi.encodeWithSelector(IMidasDepositVault.mintRequests.selector, mockRequestId),
            abi.encode(
                IMidasDepositVault.Request({
                    sender: address(vault),
                    tokenIn: USDC,
                    status: 0, // Pending
                    depositedUsdAmount: 100_000e18,
                    usdAmountWithoutFees: 99_000e18,
                    tokenOutRate: 0
                })
            )
        );

        uint256 balanceWhilePending = _getBalance();
        // While pending: component B (pending deposit) = 100_000e18
        // No mTokens on vault or executor yet
        assertGt(balanceWhilePending, 0, "Balance should be > 0 while request is pending");

        // Step 4: Simulate Midas approval - mTokens minted to executor, status changes to Processed
        // Midas consumes the USDC from executor (mock didn't actually transfer it)
        // and mints mTokens to executor instead
        uint256 mTokensApproved = 93_457e18;
        deal(USDC, executor, 0); // Midas consumed the USDC
        deal(MTBILL_TOKEN, executor, mTokensApproved);

        // Mock the request as Processed (status=1) - no longer counted in pending
        vm.mockCall(
            MTBILL_DEPOSIT_VAULT,
            abi.encodeWithSelector(IMidasDepositVault.mintRequests.selector, mockRequestId),
            abi.encode(
                IMidasDepositVault.Request({
                    sender: address(vault),
                    tokenIn: USDC,
                    status: 1, // Processed - NOT counted in pending
                    depositedUsdAmount: 100_000e18,
                    usdAmountWithoutFees: 99_000e18,
                    tokenOutRate: MOCK_MTBILL_PRICE
                })
            )
        );

        uint256 balanceAfterApproval = _getBalance();

        // After approval: component B = 0 (processed, not pending)
        // Component D = mTokens on executor valued at price
        // Expected: mTokensApproved * MOCK_MTBILL_PRICE / 1e18
        uint256 expectedExecutorValue = (mTokensApproved * MOCK_MTBILL_PRICE) / 1e18;

        assertEq(
            balanceAfterApproval,
            expectedExecutorValue,
            "Balance after approval should only count executor mTokens, not double-count pending"
        );

        // Step 5: Claim mTokens from executor to vault
        vault.execute(
            address(claimFuse),
            abi.encodeWithSignature("enter((address))", MidasClaimFromExecutorFuseEnterData({token: MTBILL_TOKEN}))
        );

        uint256 balanceAfterClaim = _getBalance();

        // After claim: mTokens moved from executor to vault
        // Component A (vault mTokens) = mTokensApproved * price
        // Component D (executor) = 0
        uint256 expectedVaultValue = (mTokensApproved * MOCK_MTBILL_PRICE) / 1e18;

        assertEq(
            balanceAfterClaim,
            expectedVaultValue,
            "Balance after claim should equal vault mToken value"
        );

        // Most importantly: balance should be consistent (no double counting)
        assertEq(
            balanceAfterApproval,
            balanceAfterClaim,
            "Balance should be the same whether mTokens are on executor or vault (no double counting)"
        );
    }
}
