// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {PlasmaVault, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {FusionFactory} from "../../../contracts/factory/FusionFactory.sol";
import {FusionFactoryLogicLib} from "../../../contracts/factory/lib/FusionFactoryLogicLib.sol";
import {FusionFactoryDaoFeePackagesHelper} from "../../test_helpers/FusionFactoryDaoFeePackagesHelper.sol";

// Enso Fuses
import {EnsoFuse, EnsoFuseEnterData, EnsoFuseExitData} from "../../../contracts/fuses/enso/EnsoFuse.sol";
import {EnsoBalanceFuse} from "../../../contracts/fuses/enso/EnsoBalanceFuse.sol";
import {EnsoInitExecutorFuse} from "../../../contracts/fuses/enso/EnsoInitExecutorFuse.sol";
import {EnsoSubstrateLib, EnsoSubstrate} from "../../../contracts/fuses/enso/lib/EnsoSubstrateLib.sol";

// Libraries
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";
import {PriceOracleMiddlewareManager} from "../../../contracts/managers/price/PriceOracleMiddlewareManager.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
// Mock contracts
import {MockDelegateEnsoShortcuts} from "./MockDelegateEnsoShortcuts.sol";
import {MockEnsoTarget} from "./MockEnsoTarget.sol";

contract EnsoFuseTest is Test {
    // Ethereum Mainnet addresses
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    address constant PRICE_FEED_WETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant PRICE_FEED_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address constant PRICE_FEED_DAI_USD = 0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9;

    address constant FUSION_FACTORY_PROXY = 0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852;

    // Test users
    address constant ATOMIST = 0x1111111111111111111111111111111111111111;
    address constant ALPHA = 0x2222222222222222222222222222222222222222;
    address constant USER = 0x3333333333333333333333333333333333333333;
    address constant FUSE_MANAGER = 0x4444444444444444444444444444444444444444;

    // Contracts
    FusionFactory public fusionFactory;
    PlasmaVault public plasmaVault;
    IporFusionAccessManager public accessManager;
    PriceOracleMiddlewareManager public priceOracleMiddlewareManager;
    address public withdrawManager;

    // Enso Fuses
    EnsoFuse public ensoFuse;
    EnsoBalanceFuse public ensoBalanceFuse;
    EnsoInitExecutorFuse public ensoInitExecutorFuse;

    // Mock contracts
    MockDelegateEnsoShortcuts public mockDelegateEnsoShortcuts;
    MockEnsoTarget public mockEnsoTarget;

    // Test amounts
    uint256 constant DEPOSIT_USDC_AMOUNT = 100_000e6; // 100,000 USDC
    uint256 constant SWAP_USDC_AMOUNT = 10_000e6; // 10,000 USDC
    uint256 constant SWAP_DAI_AMOUNT = 10_000e18; // 10,000 DAI

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 23625526);

        fusionFactory = FusionFactory(FUSION_FACTORY_PROXY);

        // Setup fee packages before creating vault
        FusionFactoryDaoFeePackagesHelper.setupDefaultDaoFeePackages(vm, fusionFactory);

        _deployMockContracts();
        _createVaultWithFusionFactory();
        _deployEnsoFuses();
        _setupRoles();
        _configureEnsoFuses();
        _configurePriceOracleMiddleware();

        // Fund USER with USDC for testing using deal
        deal(USDC, USER, DEPOSIT_USDC_AMOUNT);

        // Approve and deposit to vault
        vm.prank(USER);
        ERC20(USDC).approve(address(plasmaVault), DEPOSIT_USDC_AMOUNT);
        vm.prank(USER);
        plasmaVault.deposit(DEPOSIT_USDC_AMOUNT, USER);

        // Fund mock target with DAI for swaps using deal
        deal(DAI, address(mockEnsoTarget), 100_000e18);
    }

    function _deployMockContracts() private {
        // Deploy mock DelegateEnsoShortcuts
        mockDelegateEnsoShortcuts = new MockDelegateEnsoShortcuts();

        // Deploy mock target contract
        mockEnsoTarget = new MockEnsoTarget();
    }

    function _createVaultWithFusionFactory() private {
        // Create vault using FusionFactory with USDC as underlying
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.create(
            "Enso Test Vault",
            "ENSO-V",
            USDC, // underlying token
            1 seconds, // redemption delay
            ATOMIST, // owner
            0 // feePackageIndex
        );

        plasmaVault = PlasmaVault(instance.plasmaVault);
        accessManager = IporFusionAccessManager(instance.accessManager);
        withdrawManager = instance.withdrawManager;
        priceOracleMiddlewareManager = PriceOracleMiddlewareManager(instance.priceManager);
    }

    function _deployEnsoFuses() private {
        // Deploy Enso fuses
        ensoFuse = new EnsoFuse(IporFusionMarkets.ENSO, WETH, address(mockDelegateEnsoShortcuts));
        ensoBalanceFuse = new EnsoBalanceFuse(IporFusionMarkets.ENSO);
        ensoInitExecutorFuse = new EnsoInitExecutorFuse(
            IporFusionMarkets.ENSO,
            WETH,
            address(mockDelegateEnsoShortcuts)
        );
    }

    function _configureEnsoFuses() private {
        vm.startPrank(ATOMIST);

        // Add EnsoFuse to the vault
        address[] memory fuses = new address[](2);
        fuses[0] = address(ensoFuse);
        fuses[1] = address(ensoInitExecutorFuse);

        // Grant market substrates for tokens (using ERC20.transfer selector)
        bytes32[] memory tokenSubstrates = new bytes32[](4);
        tokenSubstrates[0] = EnsoSubstrateLib.encode(
            EnsoSubstrate({target_: USDC, functionSelector_: ERC20.transfer.selector})
        );
        tokenSubstrates[1] = EnsoSubstrateLib.encode(
            EnsoSubstrate({target_: DAI, functionSelector_: ERC20.transfer.selector})
        );
        tokenSubstrates[2] = EnsoSubstrateLib.encode(
            EnsoSubstrate({target_: WETH, functionSelector_: ERC20.transfer.selector})
        );

        // Grant substrate for mock target swap function
        tokenSubstrates[3] = EnsoSubstrateLib.encode(
            EnsoSubstrate({target_: address(mockEnsoTarget), functionSelector_: MockEnsoTarget.swap.selector})
        );

        vm.stopPrank();

        vm.startPrank(FUSE_MANAGER);
        PlasmaVaultGovernance(address(plasmaVault)).addBalanceFuse(IporFusionMarkets.ENSO, address(ensoBalanceFuse));
        PlasmaVaultGovernance(address(plasmaVault)).addFuses(fuses);
        PlasmaVaultGovernance(address(plasmaVault)).grantMarketSubstrates(IporFusionMarkets.ENSO, tokenSubstrates);
        vm.stopPrank();
    }

    function _setupRoles() private {
        vm.startPrank(ATOMIST);

        // First grant ATOMIST_ROLE to ATOMIST (needed to grant other roles)
        accessManager.grantRole(Roles.ATOMIST_ROLE, ATOMIST, 0);

        // Grant other roles
        accessManager.grantRole(Roles.ALPHA_ROLE, ALPHA, 0);
        accessManager.grantRole(Roles.FUSE_MANAGER_ROLE, FUSE_MANAGER, 0);
        accessManager.grantRole(Roles.PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE, ATOMIST, 0);
        accessManager.grantRole(Roles.WHITELIST_ROLE, USER, 0);

        vm.stopPrank();
    }

    function _configurePriceOracleMiddleware() private {
        address[] memory assets = new address[](3);
        assets[0] = USDC;
        assets[1] = DAI;
        assets[2] = WETH;

        address[] memory sources = new address[](3);
        sources[0] = PRICE_FEED_USDC_USD;
        sources[1] = PRICE_FEED_DAI_USD;
        sources[2] = PRICE_FEED_WETH_USD;

        vm.startPrank(ATOMIST);
        priceOracleMiddlewareManager.setAssetsPriceSources(assets, sources);
        vm.stopPrank();
    }

    // Helper function to build Enso command
    function _buildEnsoCommand(address target_, bytes4 selector_, uint256 callType_) internal pure returns (bytes32) {
        // Command layout in bytes32:
        // Bytes 0-3: function selector (most significant)
        // Byte 4: flags (callType)
        // Bytes 12-31: address (least significant 160 bits)

        uint256 selectorBits = uint256(uint32(selector_)) << 224; // Selector at bytes 0-3 (shift left 224 bits)
        uint256 flagsBits = callType_ << 216; // Flags at byte 4 (shift left 216 bits = 27 bytes)
        uint256 targetBits = uint256(uint160(target_)); // Address at bytes 12-31 (least significant)

        return bytes32(selectorBits | flagsBits | targetBits);
    }

    // Helper function to build EnsoFuseEnterData for swaps
    // tokenIn_ = token being swapped FROM (leaves vault, goes to executor)
    // amountIn_ = amount of tokenIn
    // tokenOut_ = token being swapped TO (received by executor)
    // minAmountOut_ = minimum amount of tokenOut expected
    function _buildEnsoEnterData(
        address tokenIn_,
        uint256 amountIn_,
        address tokenOut_,
        uint256 minAmountOut_
    ) internal view returns (EnsoFuseEnterData memory) {
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = _buildEnsoCommand(address(mockEnsoTarget), MockEnsoTarget.swap.selector, 0x01); // FLAG_CT_CALL

        bytes[] memory state = new bytes[](1);
        // MockEnsoTarget.swap(fromToken, toToken, amountIn, minAmountOut)
        state[0] = abi.encode(tokenIn_, tokenOut_, amountIn_, minAmountOut_);

        address[] memory tokensToReturn = new address[](0);

        return
            EnsoFuseEnterData({
                tokenOut: tokenIn_, // Token leaving the vault (input token)
                amountOut: amountIn_, // Amount leaving the vault
                wEthAmount: 0,
                accountId: bytes32(uint256(1)),
                requestId: bytes32(uint256(1)),
                commands: commands,
                state: state,
                tokensToReturn: tokensToReturn
            });
    }

    // Helper function to execute a swap through Enso
    function _executeSwap(address tokenIn_, uint256 amountIn_, address tokenOut_, uint256 minAmountOut_) internal {
        EnsoFuseEnterData memory enterData = _buildEnsoEnterData(tokenIn_, amountIn_, tokenOut_, minAmountOut_);

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(ensoFuse),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256,bytes32,bytes32,bytes32[],bytes[],address[]))",
                enterData
            )
        );

        vm.prank(ALPHA);
        plasmaVault.execute(actions);
    }

    // Helper function to get EnsoExecutor address from PlasmaVault storage
    // We need to read the storage slot directly from PlasmaVault
    function _getEnsoExecutorAddress() internal view returns (address) {
        // EnsoStorageLib uses this specific storage slot (ERC-7201)
        bytes32 ENSO_EXECUTOR_SLOT = 0x2be19acf1082fe0f31c0864ff2dc58ff9679d12ca8fb47a012400b2f6ce3af00;
        // Use vm.load to read from PlasmaVault's storage
        bytes32 data = vm.load(address(plasmaVault), ENSO_EXECUTOR_SLOT);
        return address(uint160(uint256(data)));
    }

    // Helper function to get EnsoExecutor balance
    function _getEnsoExecutorBalance() internal view returns (address assetAddress, uint256 assetBalance) {
        address executorAddress = _getEnsoExecutorAddress();
        if (executorAddress == address(0)) {
            return (address(0), 0);
        }
        (, bytes memory result) = executorAddress.staticcall(abi.encodeWithSignature("getBalance()"));
        return abi.decode(result, (address, uint256));
    }

    // ============================================
    // TESTS
    // ============================================

    function testShouldCreateEnsoExecutorOnFirstEnter() public {
        address executorBefore = _getEnsoExecutorAddress();

        // when
        vm.recordLogs();
        _executeSwap(USDC, SWAP_USDC_AMOUNT, DAI, SWAP_DAI_AMOUNT);

        // then - check if EnsoExecutorCreated event was emitted
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool eventFound = false;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("EnsoExecutorCreated(address,address,address,address)")) {
                eventFound = true;
                break;
            }
        }

        address executorAfter = _getEnsoExecutorAddress();

        assertTrue(eventFound, "EnsoExecutorCreated event should be emitted");
        assertNotEq(executorAfter, executorBefore, "Executor should be created");
    }

    function testShouldNotCreateNewExecutorOnSecondEnter() public {
        // given - first swap creates executor
        _executeSwap(USDC, SWAP_USDC_AMOUNT, DAI, SWAP_DAI_AMOUNT);

        address executorAfterFirstSwap = _getEnsoExecutorAddress();
        assertTrue(executorAfterFirstSwap != address(0), "Executor should be created after first swap");

        // Exit first swap to allow second swap
        EnsoFuseExitData memory exitData = EnsoFuseExitData({tokens: new address[](1)});
        exitData.tokens[0] = DAI;

        FuseAction[] memory exitActions = new FuseAction[](1);
        exitActions[0] = FuseAction(address(ensoFuse), abi.encodeWithSignature("exit((address[]))", exitData));

        vm.prank(ALPHA);
        plasmaVault.execute(exitActions);

        // when - perform second swap and check if event is NOT emitted
        vm.recordLogs();
        _executeSwap(USDC, SWAP_USDC_AMOUNT, DAI, SWAP_DAI_AMOUNT);

        // then - check that EnsoExecutorCreated event was NOT emitted during second swap
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool eventFound = false;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("EnsoExecutorCreated(address,address,address,address)")) {
                eventFound = true;
                break;
            }
        }

        assertFalse(eventFound, "EnsoExecutorCreated event should NOT be emitted on second swap");

        // Verify executor address remains the same
        address executorAfterSecondSwap = _getEnsoExecutorAddress();
        assertEq(executorAfterSecondSwap, executorAfterFirstSwap, "Executor address should remain unchanged");
    }

    function testShouldSwapUsdcToDaiThroughEnso() public {
        // given
        uint256 vaultUsdcBefore = ERC20(USDC).balanceOf(address(plasmaVault));
        uint256 totalAssetsBefore = plasmaVault.totalAssets();
        address executorAddress = _getEnsoExecutorAddress();
        assertEq(executorAddress, address(0), "Executor should not exist yet");

        // when
        _executeSwap(USDC, SWAP_USDC_AMOUNT, DAI, SWAP_DAI_AMOUNT);

        // then
        uint256 vaultUsdcAfter = ERC20(USDC).balanceOf(address(plasmaVault));
        uint256 totalAssetsAfter = plasmaVault.totalAssets();

        // USDC should be transferred from vault to executor
        assertLt(vaultUsdcAfter, vaultUsdcBefore, "Vault USDC should decrease");
        assertEq(vaultUsdcBefore - vaultUsdcAfter, SWAP_USDC_AMOUNT, "Vault USDC should decrease by swap amount");

        // Get executor and check it was created
        executorAddress = _getEnsoExecutorAddress();
        assertTrue(executorAddress != address(0), "Executor should be created");

        // Check DAI is in the executor
        uint256 executorDaiBalance = ERC20(DAI).balanceOf(executorAddress);
        assertEq(executorDaiBalance, SWAP_DAI_AMOUNT, "Executor should physically hold DAI");

        // Get executor balance tracking (tracks input token USDC, not output DAI)
        (address executorAsset, uint256 executorBalance) = _getEnsoExecutorBalance();
        assertEq(executorAsset, USDC, "Executor should track USDC (input token)");
        assertEq(executorBalance, SWAP_USDC_AMOUNT, "Executor should track USDC amount invested");

        // Total assets should remain approximately the same (USDC out, DAI in)
        assertApproxEqAbs(totalAssetsAfter, totalAssetsBefore, 1e18, "Total assets should remain similar");
    }

    function testShouldCheckBalanceAfterSwap() public {
        // given
        _executeSwap(USDC, SWAP_USDC_AMOUNT, DAI, SWAP_DAI_AMOUNT);

        // when
        uint256 ensoMarketBalance = plasmaVault.totalAssetsInMarket(IporFusionMarkets.ENSO);

        // then

        (, uint256 executorBalance) = _getEnsoExecutorBalance();
        assertGt(ensoMarketBalance, 0, "Enso market should have balance");

        // Balance should be approximately equal to swap amount in USD
        assertApproxEqAbs(ensoMarketBalance, executorBalance, 1e18, "Balance should match DAI amount in USD");
    }

    function testShouldExitAndWithdrawDai() public {
        // given - perform swap
        _executeSwap(USDC, SWAP_USDC_AMOUNT, DAI, SWAP_DAI_AMOUNT);

        address executorAddress = _getEnsoExecutorAddress();

        (address executorAssetBefore, uint256 executorBalanceBefore) = _getEnsoExecutorBalance();
        assertEq(executorAssetBefore, USDC, "Executor should have USDC");
        assertGt(executorBalanceBefore, 0, "Executor should have USDC balance");

        uint256 vaultDaiBefore = ERC20(DAI).balanceOf(address(plasmaVault));

        // when - exit and withdraw
        EnsoFuseExitData memory exitData = EnsoFuseExitData({tokens: new address[](1)});
        exitData.tokens[0] = DAI;

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(address(ensoFuse), abi.encodeWithSignature("exit((address[]))", exitData));

        vm.prank(ALPHA);
        plasmaVault.execute(actions);

        // then
        uint256 vaultDaiAfter = ERC20(DAI).balanceOf(address(plasmaVault));
        uint256 executorDaiBalanceAfter = ERC20(DAI).balanceOf(executorAddress);

        assertGt(vaultDaiAfter, vaultDaiBefore, "Vault should receive DAI");
        assertEq(executorDaiBalanceAfter, 0, "Executor should have 0 DAI balance after exit");

        (address executorAssetAfter, uint256 executorBalanceAfter) = _getEnsoExecutorBalance();
        assertEq(executorAssetAfter, address(0), "Executor asset should be cleared");
        assertEq(executorBalanceAfter, 0, "Executor balance should be zero");

        uint256 ensoMarketBalance = plasmaVault.totalAssetsInMarket(IporFusionMarkets.ENSO);
        assertEq(ensoMarketBalance, 0, "Enso market balance should be zero after exit");
    }

    function testShouldRevertWhenInvalidTokenSubstrate() public {
        // given - WBTC is not in granted substrates
        address WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

        EnsoFuseEnterData memory enterData = _buildEnsoEnterData(WBTC, 1e8, USDC, SWAP_USDC_AMOUNT);

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(ensoFuse),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256,bytes32,bytes32,bytes32[],bytes[],address[]))",
                enterData
            )
        );

        // when & then
        vm.prank(ALPHA);
        vm.expectRevert(abi.encodeWithSignature("EnsoFuseUnsupportedAsset(address)", WBTC));
        plasmaVault.execute(actions);
    }

    function testShouldRevertWhenInvalidCommandSubstrate() public {
        // given - build command with non-granted selector
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = _buildEnsoCommand(address(mockEnsoTarget), bytes4(keccak256("invalidFunction()")), 0x01);

        bytes[] memory state = new bytes[](1);
        state[0] = abi.encode(USDC, DAI, SWAP_USDC_AMOUNT, SWAP_DAI_AMOUNT);

        EnsoFuseEnterData memory enterData = EnsoFuseEnterData({
            tokenOut: DAI,
            amountOut: SWAP_DAI_AMOUNT,
            wEthAmount: 0,
            accountId: bytes32(uint256(1)),
            requestId: bytes32(uint256(1)),
            commands: commands,
            state: state,
            tokensToReturn: new address[](0)
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(ensoFuse),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256,bytes32,bytes32,bytes32[],bytes[],address[]))",
                enterData
            )
        );

        // when & then
        vm.prank(ALPHA);
        vm.expectRevert();
        plasmaVault.execute(actions);
    }

    function testShouldRevertWhenUnauthorizedCaller() public {
        // given
        EnsoFuseEnterData memory enterData = _buildEnsoEnterData(DAI, SWAP_DAI_AMOUNT, USDC, SWAP_USDC_AMOUNT);

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(ensoFuse),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256,bytes32,bytes32,bytes32[],bytes[],address[]))",
                enterData
            )
        );

        // when & then - USER doesn't have ALPHA_ROLE
        vm.prank(USER);
        vm.expectRevert();
        plasmaVault.execute(actions);
    }

    function testShouldRevertWhenZeroTokensOut() public {
        // given
        EnsoFuseEnterData memory enterData = _buildEnsoEnterData(address(0), SWAP_DAI_AMOUNT, USDC, SWAP_USDC_AMOUNT);

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(ensoFuse),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256,bytes32,bytes32,bytes32[],bytes[],address[]))",
                enterData
            )
        );

        // when
        vm.prank(ALPHA);
        vm.expectRevert(abi.encodeWithSignature("EnsoFuseInvalidTokenOut()"));
        plasmaVault.execute(actions);
    }

    function testShouldRevertWhenExecutorBalanceNotEmpty() public {
        // given - first swap creates executor with balance
        _executeSwap(USDC, SWAP_USDC_AMOUNT, DAI, SWAP_DAI_AMOUNT);

        (address executorAsset, uint256 executorBalance) = _getEnsoExecutorBalance();
        assertEq(executorAsset, USDC, "Executor should have USDC");
        assertGt(executorBalance, 0, "Executor should have USDC balance");

        // when & then - try to execute another enter without exit first
        EnsoFuseEnterData memory enterData = _buildEnsoEnterData(USDC, SWAP_USDC_AMOUNT, DAI, SWAP_DAI_AMOUNT);

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(ensoFuse),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256,bytes32,bytes32,bytes32[],bytes[],address[]))",
                enterData
            )
        );

        vm.prank(ALPHA);
        vm.expectRevert(abi.encodeWithSignature("EnsoExecutorBalanceAlreadySet()"));
        plasmaVault.execute(actions);
    }

    function testShouldCreateExecutorUsingEnsoInitExecutorFuse() public {
        // given - executor should not exist yet
        address executorBefore = _getEnsoExecutorAddress();
        assertEq(executorBefore, address(0), "Executor should not exist before initialization");

        // when - call enter on EnsoInitExecutorFuse
        vm.recordLogs();

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(address(ensoInitExecutorFuse), abi.encodeWithSignature("enter()"));

        vm.prank(ALPHA);
        plasmaVault.execute(actions);

        // then - check if EnsoExecutorCreated event was emitted
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool eventFound = false;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("EnsoExecutorCreated(address,address,address,address)")) {
                eventFound = true;
                break;
            }
        }

        assertTrue(eventFound, "EnsoExecutorCreated event should be emitted");

        // then - executor should be created
        address executorAfter = _getEnsoExecutorAddress();
        assertNotEq(executorAfter, address(0), "Executor should be created");
        assertTrue(executorAfter != executorBefore, "Executor address should change");
    }

    function testShouldNotCreateNewExecutorWhenAlreadyExists() public {
        // given - create executor using EnsoInitExecutorFuse
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(address(ensoInitExecutorFuse), abi.encodeWithSignature("enter()"));

        vm.prank(ALPHA);
        plasmaVault.execute(actions);

        address executorAfterFirst = _getEnsoExecutorAddress();
        assertTrue(executorAfterFirst != address(0), "Executor should be created after first call");

        // when - call enter again on EnsoInitExecutorFuse
        vm.recordLogs();

        vm.prank(ALPHA);
        plasmaVault.execute(actions);

        // then - check that EnsoExecutorCreated event was NOT emitted during second call
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool eventFound = false;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("EnsoExecutorCreated(address,address,address,address)")) {
                eventFound = true;
                break;
            }
        }

        assertFalse(eventFound, "EnsoExecutorCreated event should NOT be emitted on second call");

        // then - executor address should remain the same
        address executorAfterSecond = _getEnsoExecutorAddress();
        assertEq(executorAfterSecond, executorAfterFirst, "Executor address should remain unchanged");
    }
}
