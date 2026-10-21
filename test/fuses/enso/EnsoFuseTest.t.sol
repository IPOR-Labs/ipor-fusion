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
import {MockEnsoStateStager} from "./MockEnsoStateStager.sol";

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
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
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

    /// @dev Same layout as `_buildEnsoCommand`, plus the first two argument-index bytes (bytes 5
    ///      and 6). Needed for FLAG_DATA commands, where the state slot that supplies the whole
    ///      calldata - and therefore the selector the target actually sees - is addressed by
    ///      byte 5 (byte 6 for VALUECALL, whose first index carries the ETH value).
    function _buildEnsoCommandWithIndices(
        address target_,
        bytes4 selector_,
        uint256 flags_,
        uint8 index0_,
        uint8 index1_
    ) internal pure returns (bytes32) {
        uint256 selectorBits = uint256(uint32(selector_)) << 224; // Bytes 0-3
        uint256 flagsBits = flags_ << 216; // Byte 4
        uint256 index0Bits = uint256(index0_) << 208; // Byte 5
        uint256 index1Bits = uint256(index1_) << 200; // Byte 6
        uint256 targetBits = uint256(uint160(target_)); // Bytes 12-31

        return bytes32(selectorBits | flagsBits | index0Bits | index1Bits | targetBits);
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
                tokensToReturn: tokensToReturn,
                tokensToRevoke: new address[](0),
                spendersToRevoke: new address[](0)
            });
    }

    // Helper function to execute a swap through Enso
    function _executeSwap(address tokenIn_, uint256 amountIn_, address tokenOut_, uint256 minAmountOut_) internal {
        EnsoFuseEnterData memory enterData = _buildEnsoEnterData(tokenIn_, amountIn_, tokenOut_, minAmountOut_);

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(ensoFuse),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256,bytes32,bytes32,bytes32[],bytes[],address[],address[],address[]))",
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
                "enter((address,uint256,uint256,bytes32,bytes32,bytes32[],bytes[],address[],address[],address[]))",
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
            tokensToReturn: new address[](0),
            tokensToRevoke: new address[](0),
            spendersToRevoke: new address[](0)
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(ensoFuse),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256,bytes32,bytes32,bytes32[],bytes[],address[],address[],address[]))",
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
                "enter((address,uint256,uint256,bytes32,bytes32,bytes32[],bytes[],address[],address[],address[]))",
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
                "enter((address,uint256,uint256,bytes32,bytes32,bytes32[],bytes[],address[],address[],address[]))",
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
                "enter((address,uint256,uint256,bytes32,bytes32,bytes32[],bytes[],address[],address[],address[]))",
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

    // ============================================================
    // IL-8047: FLAG_EXTENDED_COMMAND substrate-allowlist bypass
    // ============================================================
    //
    // Regression tests for the bug where `_validateCommands()` treated any command word
    // carrying FLAG_EXTENDED_COMMAND (0x40) as pure metadata and skipped the substrate
    // check for it entirely, even though that word still encodes a live (target, selector)
    // dispatched by the executor's VM.

    address constant EVIL_TARGET = 0xE11eE11ee11ee11EE11EE11Ee11EE11EE11Ee11e;

    function _evilSelector() internal pure returns (bytes4) {
        return bytes4(keccak256("evil()"));
    }

    function testShouldRevertWhenExtendedCommandCallTargetsNonGrantedSubstrate() public {
        // given - an extended (0x40) CALL (0x01) command targeting a non-granted (target, selector)
        //
        // IL-8047 cycle-2 correction 1: tokenOut/amountOut use USDC (a token the vault actually
        // holds and whose `transfer` substrate is granted, see test 4) rather than DAI. With DAI
        // the pre-fix run dies early at the safeTransfer in EnsoFuse.sol (vault holds no DAI),
        // producing an incidental "Dai/insufficient-balance" failure that never reaches the
        // executor. With USDC, execution actually reaches EnsoExecutor.execute() and the mock VM
        // dispatches the un-granted extended CALL end to end, so the pre-fix failure mode is a
        // direct "next call did not revert as expected" — a true pin on the bug.
        bytes4 selEvil = _evilSelector();

        bytes32[] memory commands = new bytes32[](2);
        commands[0] = _buildEnsoCommand(EVIL_TARGET, selEvil, 0x41); // FLAG_CT_CALL | FLAG_EXTENDED_COMMAND
        commands[1] = bytes32(uint256(1)); // argument-index word, not a call

        bytes[] memory state = new bytes[](2);
        state[0] = "";
        state[1] = "";

        EnsoFuseEnterData memory enterData = EnsoFuseEnterData({
            tokenOut: USDC,
            amountOut: SWAP_USDC_AMOUNT,
            wEthAmount: 0,
            accountId: bytes32(uint256(1)),
            requestId: bytes32(uint256(1)),
            commands: commands,
            state: state,
            tokensToReturn: new address[](0),
            tokensToRevoke: new address[](0),
            spendersToRevoke: new address[](0)
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(ensoFuse),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256,bytes32,bytes32,bytes32[],bytes[],address[],address[],address[]))",
                enterData
            )
        );

        // when & then - the fuse must validate the flagged word itself, not skip it
        vm.prank(ALPHA);
        vm.expectRevert(abi.encodeWithSelector(EnsoFuse.EnsoFuseUnsupportedCommand.selector, EVIL_TARGET, selEvil));
        plasmaVault.execute(actions);
    }

    function testShouldRevertWhenExtendedDelegatecallTargetsNonGrantedSubstrate() public {
        // given - an extended (0x40) command with call type DELEGATECALL (0x00), i.e. flags == 0x40
        //
        // IL-8047 cycle-2 correction 1: tokenOut/amountOut use USDC for the same reason as
        // testShouldRevertWhenExtendedCommandCallTargetsNonGrantedSubstrate above — DAI dies
        // early at the vault's safeTransfer pre-fix (incidental failure); USDC lets execution
        // reach the executor so the un-granted extended DELEGATECALL is actually dispatched.
        bytes4 selEvil = _evilSelector();

        bytes32[] memory commands = new bytes32[](2);
        commands[0] = _buildEnsoCommand(EVIL_TARGET, selEvil, 0x40); // FLAG_CT_DELEGATECALL | FLAG_EXTENDED_COMMAND
        commands[1] = bytes32(uint256(1)); // argument-index word, not a call

        bytes[] memory state = new bytes[](2);
        state[0] = "";
        state[1] = "";

        EnsoFuseEnterData memory enterData = EnsoFuseEnterData({
            tokenOut: USDC,
            amountOut: SWAP_USDC_AMOUNT,
            wEthAmount: 0,
            accountId: bytes32(uint256(1)),
            requestId: bytes32(uint256(1)),
            commands: commands,
            state: state,
            tokensToReturn: new address[](0),
            tokensToRevoke: new address[](0),
            spendersToRevoke: new address[](0)
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(ensoFuse),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256,bytes32,bytes32,bytes32[],bytes[],address[],address[],address[]))",
                enterData
            )
        );

        // when & then - delegatecall is not exempt from substrate validation
        vm.prank(ALPHA);
        vm.expectRevert(abi.encodeWithSelector(EnsoFuse.EnsoFuseUnsupportedCommand.selector, EVIL_TARGET, selEvil));
        plasmaVault.execute(actions);
    }

    function testShouldRevertWhenExtendedStaticcallSkipsIndexWordThenValidatesRealCall() public {
        // given - ordering bug: an extended STATICCALL (flags 0x42) must still skip its index
        // word via ++i, then the following real command must be validated normally
        bytes4 selEvil = _evilSelector();

        bytes32[] memory commands = new bytes32[](3);
        commands[0] = _buildEnsoCommand(address(0x1234), bytes4(0), 0x42); // FLAG_CT_STATICCALL | FLAG_EXTENDED_COMMAND
        commands[1] = bytes32(uint256(1)); // argument-index word for command[0], not a call
        commands[2] = _buildEnsoCommand(EVIL_TARGET, selEvil, 0x01); // real CALL, not granted

        bytes[] memory state = new bytes[](3);
        state[0] = "";
        state[1] = "";
        state[2] = "";

        EnsoFuseEnterData memory enterData = EnsoFuseEnterData({
            tokenOut: DAI,
            amountOut: SWAP_DAI_AMOUNT,
            wEthAmount: 0,
            accountId: bytes32(uint256(1)),
            requestId: bytes32(uint256(1)),
            commands: commands,
            state: state,
            tokensToReturn: new address[](0),
            tokensToRevoke: new address[](0),
            spendersToRevoke: new address[](0)
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(ensoFuse),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256,bytes32,bytes32,bytes32[],bytes[],address[],address[],address[]))",
                enterData
            )
        );

        // when & then - must revert on the THIRD command (EVIL_TARGET, selEvil), proving the
        // index word was correctly skipped instead of being mis-validated as its own command
        vm.prank(ALPHA);
        vm.expectRevert(abi.encodeWithSelector(EnsoFuse.EnsoFuseUnsupportedCommand.selector, EVIL_TARGET, selEvil));
        plasmaVault.execute(actions);
    }

    function testShouldPassWhenExtendedCommandTargetsGrantedSubstrateAndSkipsIndexWord() public {
        // given - correctness guard: an extended CALL to a GRANTED substrate must still succeed,
        // and the following index word (crafted to look like a non-granted CALL command if it
        // were wrongly validated) must be skipped, not validated.
        bytes4 selEvil = _evilSelector();

        bytes32[] memory commands = new bytes32[](2);
        commands[0] = _buildEnsoCommand(address(mockEnsoTarget), MockEnsoTarget.swap.selector, 0x41); // granted, extended
        // If this word were wrongly validated as a command it would decode as
        // (EVIL_TARGET, selEvil, callType=DELEGATECALL) which is NOT granted and would revert.
        // The mock ignores callType == DELEGATECALL (0x00) when dispatching, so this word is a
        // safe no-op for actual execution while still being a meaningful validation trap.
        commands[1] = _buildEnsoCommand(EVIL_TARGET, selEvil, 0x00);

        bytes[] memory state = new bytes[](2);
        state[0] = abi.encode(USDC, DAI, SWAP_USDC_AMOUNT, SWAP_DAI_AMOUNT);
        state[1] = "";

        EnsoFuseEnterData memory enterData = EnsoFuseEnterData({
            tokenOut: USDC,
            amountOut: SWAP_USDC_AMOUNT,
            wEthAmount: 0,
            accountId: bytes32(uint256(1)),
            requestId: bytes32(uint256(1)),
            commands: commands,
            state: state,
            tokensToReturn: new address[](0),
            tokensToRevoke: new address[](0),
            spendersToRevoke: new address[](0)
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(ensoFuse),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256,bytes32,bytes32,bytes32[],bytes[],address[],address[],address[]))",
                enterData
            )
        );

        // when - must NOT revert
        vm.prank(ALPHA);
        plasmaVault.execute(actions);

        // then - the shortcut actually executed (DAI landed in the executor)
        address executorAddress = _getEnsoExecutorAddress();
        assertTrue(executorAddress != address(0), "Executor should be created");
        uint256 executorDaiBalance = ERC20(DAI).balanceOf(executorAddress);
        assertEq(executorDaiBalance, SWAP_DAI_AMOUNT, "Executor should physically hold DAI from the extended swap");
    }

    // IL-8047 cycle-2 correction 2: cover the EnsoFuseInvalidCommandsLength branch
    // (EnsoFuse.sol:250-252), which had no test at all after cycle-1.
    function testShouldRevertWhenExtendedCommandIsLastElement() public {
        // given - a single extended command with no following index word. The missing index word
        // is detected before the substrate check (the IL-8047 FLAG_DATA follow-up moved the bounds
        // check up, because a FLAG_DATA command reads its state index out of that very element);
        // either way a trailing extended command must never silently advance `i` past the end.
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = _buildEnsoCommand(address(mockEnsoTarget), MockEnsoTarget.swap.selector, 0x41); // granted, extended

        bytes[] memory state = new bytes[](1);
        state[0] = "";

        EnsoFuseEnterData memory enterData = EnsoFuseEnterData({
            tokenOut: USDC,
            amountOut: SWAP_USDC_AMOUNT,
            wEthAmount: 0,
            accountId: bytes32(uint256(1)),
            requestId: bytes32(uint256(1)),
            commands: commands,
            state: state,
            tokensToReturn: new address[](0),
            tokensToRevoke: new address[](0),
            spendersToRevoke: new address[](0)
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(ensoFuse),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256,bytes32,bytes32,bytes32[],bytes[],address[],address[],address[]))",
                enterData
            )
        );

        // when & then - a trailing extended command with no following index word must revert,
        // not silently advance `i` past the end of the array
        vm.prank(ALPHA);
        vm.expectRevert(EnsoFuse.EnsoFuseInvalidCommandsLength.selector);
        plasmaVault.execute(actions);
    }

    // IL-8047 cycle-2 correction 3: pin flag combinations argued only by inspection in the
    // cycle-1 verification report (masked bits cannot re-open the skip). Post-fix these must
    // revert with EnsoFuseUnsupportedCommand(EVIL_TARGET, selEvil); on the pre-fix code (bug
    // re-injected) they demonstrate a missing revert instead.
    function testShouldRevertWhenExtendedValuecallTargetsNonGrantedSubstrate() public {
        // given - flags 0x43 = FLAG_CT_VALUECALL (0x03) | FLAG_EXTENDED_COMMAND (0x40)
        bytes4 selEvil = _evilSelector();

        bytes32[] memory commands = new bytes32[](2);
        commands[0] = _buildEnsoCommand(EVIL_TARGET, selEvil, 0x43);
        commands[1] = bytes32(uint256(1)); // argument-index word, not a call

        bytes[] memory state = new bytes[](2);
        state[0] = "";
        state[1] = "";

        EnsoFuseEnterData memory enterData = EnsoFuseEnterData({
            tokenOut: USDC,
            amountOut: SWAP_USDC_AMOUNT,
            wEthAmount: 0,
            accountId: bytes32(uint256(1)),
            requestId: bytes32(uint256(1)),
            commands: commands,
            state: state,
            tokensToReturn: new address[](0),
            tokensToRevoke: new address[](0),
            spendersToRevoke: new address[](0)
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(ensoFuse),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256,bytes32,bytes32,bytes32[],bytes[],address[],address[],address[]))",
                enterData
            )
        );

        // when & then
        vm.prank(ALPHA);
        vm.expectRevert(abi.encodeWithSelector(EnsoFuse.EnsoFuseUnsupportedCommand.selector, EVIL_TARGET, selEvil));
        plasmaVault.execute(actions);
    }

    function testShouldRevertWhenExtendedTupleReturnCallTargetsNonGrantedSubstrate() public {
        // given - flags 0xC1 = FLAG_TUPLE_RETURN (0x80) | FLAG_CT_CALL (0x01) | FLAG_EXTENDED_COMMAND (0x40).
        // Neither the undefined tuple-return bit nor any other bit outside FLAG_CT_MASK /
        // FLAG_EXTENDED_COMMAND is compared against in _validateCommands, so this must behave
        // identically to the plain 0x41 case.
        bytes4 selEvil = _evilSelector();

        bytes32[] memory commands = new bytes32[](2);
        commands[0] = _buildEnsoCommand(EVIL_TARGET, selEvil, 0xC1);
        commands[1] = bytes32(uint256(1)); // argument-index word, not a call

        bytes[] memory state = new bytes[](2);
        state[0] = "";
        state[1] = "";

        EnsoFuseEnterData memory enterData = EnsoFuseEnterData({
            tokenOut: USDC,
            amountOut: SWAP_USDC_AMOUNT,
            wEthAmount: 0,
            accountId: bytes32(uint256(1)),
            requestId: bytes32(uint256(1)),
            commands: commands,
            state: state,
            tokensToReturn: new address[](0),
            tokensToRevoke: new address[](0),
            spendersToRevoke: new address[](0)
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(ensoFuse),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256,bytes32,bytes32,bytes32[],bytes[],address[],address[],address[]))",
                enterData
            )
        );

        // when & then
        vm.prank(ALPHA);
        vm.expectRevert(abi.encodeWithSelector(EnsoFuse.EnsoFuseUnsupportedCommand.selector, EVIL_TARGET, selEvil));
        plasmaVault.execute(actions);
    }

    // ============================================================
    // IL-8047 follow-up: FLAG_DATA substrate-allowlist bypass
    // ============================================================
    //
    // Regression tests for the sibling of the FLAG_EXTENDED_COMMAND bypass, raised in the
    // independent review of the IL-8047 fix. With FLAG_DATA (0x20) set, the executor's VM ignores
    // the selector encoded in the command word and calls the target with the raw state slot
    // addressed by the first argument-index byte. Validating `bytes4(command)` therefore checked a
    // selector the VM never dispatches, degrading the (target, selector) allowlist to target-only:
    // a grant of (mockEnsoTarget, swap) exposed every other function of the same target.
    //
    // MockDelegateEnsoShortcuts models FLAG_DATA dispatch (see its `rawData` branch), so these
    // tests exercise the real dispatch semantics rather than only the fuse's validator.

    function testShouldRevertWhenFlagDataSmugglesNonGrantedSelectorInState() public {
        // given - the PoC: a granted selector in the command word, a NON-granted selector of the
        // same target in the state slot the VM will actually pass as calldata. Pre-fix the fuse
        // validated (mockEnsoTarget, swap) - which is granted - and the VM then executed
        // removeLiquidity, which is not.
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = _buildEnsoCommandWithIndices(
            address(mockEnsoTarget),
            MockEnsoTarget.swap.selector, // granted, but discarded by the VM under FLAG_DATA
            0x21, // FLAG_CT_CALL | FLAG_DATA
            0, // calldata comes from state[0]
            0
        );

        bytes[] memory state = new bytes[](1);
        state[0] = abi.encodeWithSelector(MockEnsoTarget.removeLiquidity.selector, DAI, SWAP_DAI_AMOUNT);

        EnsoFuseEnterData memory enterData = EnsoFuseEnterData({
            tokenOut: USDC,
            amountOut: SWAP_USDC_AMOUNT,
            wEthAmount: 0,
            accountId: bytes32(uint256(1)),
            requestId: bytes32(uint256(1)),
            commands: commands,
            state: state,
            tokensToReturn: new address[](0),
            tokensToRevoke: new address[](0),
            spendersToRevoke: new address[](0)
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(ensoFuse),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256,bytes32,bytes32,bytes32[],bytes[],address[],address[],address[]))",
                enterData
            )
        );

        // when & then - the fuse must validate the selector the VM will really dispatch
        vm.prank(ALPHA);
        vm.expectRevert(
            abi.encodeWithSelector(
                EnsoFuse.EnsoFuseUnsupportedCommand.selector,
                address(mockEnsoTarget),
                MockEnsoTarget.removeLiquidity.selector
            )
        );
        plasmaVault.execute(actions);
    }

    function testShouldRevertWhenFlagDataValuecallReadsSecondIndexByte() public {
        // given - VALUECALL (0x03) spends its FIRST index byte on the ETH value, so the calldata
        // index is the SECOND byte. The two state slots are crossed on purpose: byte 5 points at
        // the GRANTED slot and byte 6 at the forbidden one, so a validator that wrongly read the
        // first byte would pass this command.
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = _buildEnsoCommandWithIndices(
            address(mockEnsoTarget),
            MockEnsoTarget.swap.selector,
            0x23, // FLAG_CT_VALUECALL | FLAG_DATA
            1, // ETH-value index -> state[1] (granted calldata; must NOT be used as the selector)
            0 // calldata index -> state[0]
        );

        bytes[] memory state = new bytes[](2);
        state[0] = abi.encodeWithSelector(MockEnsoTarget.removeLiquidity.selector, DAI, SWAP_DAI_AMOUNT);
        state[1] = abi.encodeWithSelector(MockEnsoTarget.swap.selector, USDC, DAI, 0, SWAP_DAI_AMOUNT);

        EnsoFuseEnterData memory enterData = EnsoFuseEnterData({
            tokenOut: USDC,
            amountOut: SWAP_USDC_AMOUNT,
            wEthAmount: 0,
            accountId: bytes32(uint256(1)),
            requestId: bytes32(uint256(1)),
            commands: commands,
            state: state,
            tokensToReturn: new address[](0),
            tokensToRevoke: new address[](0),
            spendersToRevoke: new address[](0)
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(ensoFuse),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256,bytes32,bytes32,bytes32[],bytes[],address[],address[],address[]))",
                enterData
            )
        );

        // when & then
        vm.prank(ALPHA);
        vm.expectRevert(
            abi.encodeWithSelector(
                EnsoFuse.EnsoFuseUnsupportedCommand.selector,
                address(mockEnsoTarget),
                MockEnsoTarget.removeLiquidity.selector
            )
        );
        plasmaVault.execute(actions);
    }

    function testShouldRevertWhenExtendedFlagDataReadsIndexFromNextWord() public {
        // given - for an extended command the argument indices live in the NEXT array element, so
        // the state index must be taken from there and not from byte 5 of the command word. The
        // indices are crossed the same way as in the VALUECALL test: byte 5 of the command word
        // points at the granted slot, the index word at the forbidden one.
        bytes32[] memory commands = new bytes32[](2);
        commands[0] = _buildEnsoCommandWithIndices(
            address(mockEnsoTarget),
            MockEnsoTarget.swap.selector,
            0x61, // FLAG_CT_CALL | FLAG_DATA | FLAG_EXTENDED_COMMAND
            1, // decoy: would resolve to the granted state[1] if read from the command word
            1
        );
        // Argument-index word: first byte 0 -> state[0].
        commands[1] = bytes32(0);

        bytes[] memory state = new bytes[](2);
        state[0] = abi.encodeWithSelector(MockEnsoTarget.removeLiquidity.selector, DAI, SWAP_DAI_AMOUNT);
        state[1] = abi.encodeWithSelector(MockEnsoTarget.swap.selector, USDC, DAI, 0, SWAP_DAI_AMOUNT);

        EnsoFuseEnterData memory enterData = EnsoFuseEnterData({
            tokenOut: USDC,
            amountOut: SWAP_USDC_AMOUNT,
            wEthAmount: 0,
            accountId: bytes32(uint256(1)),
            requestId: bytes32(uint256(1)),
            commands: commands,
            state: state,
            tokensToReturn: new address[](0),
            tokensToRevoke: new address[](0),
            spendersToRevoke: new address[](0)
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(ensoFuse),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256,bytes32,bytes32,bytes32[],bytes[],address[],address[],address[]))",
                enterData
            )
        );

        // when & then
        vm.prank(ALPHA);
        vm.expectRevert(
            abi.encodeWithSelector(
                EnsoFuse.EnsoFuseUnsupportedCommand.selector,
                address(mockEnsoTarget),
                MockEnsoTarget.removeLiquidity.selector
            )
        );
        plasmaVault.execute(actions);
    }

    function testShouldRevertWhenFlagDataStateIndexIsOutOfRange() public {
        // given - an index byte pointing past the end of `state`. The VM would revert on the
        // out-of-bounds read; the fuse must reject it with a diagnostic instead of reading garbage.
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = _buildEnsoCommandWithIndices(
            address(mockEnsoTarget),
            MockEnsoTarget.swap.selector,
            0x21,
            5, // state has 1 slot
            0
        );

        bytes[] memory state = new bytes[](1);
        state[0] = abi.encodeWithSelector(MockEnsoTarget.swap.selector, USDC, DAI, 0, SWAP_DAI_AMOUNT);

        EnsoFuseEnterData memory enterData = EnsoFuseEnterData({
            tokenOut: USDC,
            amountOut: SWAP_USDC_AMOUNT,
            wEthAmount: 0,
            accountId: bytes32(uint256(1)),
            requestId: bytes32(uint256(1)),
            commands: commands,
            state: state,
            tokensToReturn: new address[](0),
            tokensToRevoke: new address[](0),
            spendersToRevoke: new address[](0)
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(ensoFuse),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256,bytes32,bytes32,bytes32[],bytes[],address[],address[],address[]))",
                enterData
            )
        );

        // when & then
        vm.prank(ALPHA);
        vm.expectRevert(abi.encodeWithSelector(EnsoFuse.EnsoFuseInvalidStateIndex.selector, uint256(5)));
        plasmaVault.execute(actions);
    }

    function testShouldRevertWhenFlagDataStateSlotIsShorterThanSelector() public {
        // given - a state slot carrying fewer than four bytes has no selector to check against the
        // allowlist, so it must be rejected rather than zero-padded into some other substrate.
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = _buildEnsoCommandWithIndices(address(mockEnsoTarget), MockEnsoTarget.swap.selector, 0x21, 0, 0);

        bytes[] memory state = new bytes[](1);
        state[0] = hex"aabb";

        EnsoFuseEnterData memory enterData = EnsoFuseEnterData({
            tokenOut: USDC,
            amountOut: SWAP_USDC_AMOUNT,
            wEthAmount: 0,
            accountId: bytes32(uint256(1)),
            requestId: bytes32(uint256(1)),
            commands: commands,
            state: state,
            tokensToReturn: new address[](0),
            tokensToRevoke: new address[](0),
            spendersToRevoke: new address[](0)
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(ensoFuse),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256,bytes32,bytes32,bytes32[],bytes[],address[],address[],address[]))",
                enterData
            )
        );

        // when & then
        vm.prank(ALPHA);
        vm.expectRevert(abi.encodeWithSelector(EnsoFuse.EnsoFuseInvalidStateCalldata.selector, uint256(0)));
        plasmaVault.execute(actions);
    }

    function testShouldSucceedWhenFlagDataCarriesGrantedSelectorInState() public {
        // given - over-correction guard: a FLAG_DATA command whose state slot carries the GRANTED
        // selector must still execute end to end. `amountIn` is 0 because the mock VM issues its
        // convenience approve() only on the non-FLAG_DATA path, exactly as the production VM never
        // approves anything on its own; the DAI leg alone proves the dispatch happened.
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = _buildEnsoCommandWithIndices(address(mockEnsoTarget), MockEnsoTarget.swap.selector, 0x21, 0, 0);

        bytes[] memory state = new bytes[](1);
        state[0] = abi.encodeWithSelector(MockEnsoTarget.swap.selector, USDC, DAI, 0, SWAP_DAI_AMOUNT);

        EnsoFuseEnterData memory enterData = EnsoFuseEnterData({
            tokenOut: USDC,
            amountOut: SWAP_USDC_AMOUNT,
            wEthAmount: 0,
            accountId: bytes32(uint256(1)),
            requestId: bytes32(uint256(1)),
            commands: commands,
            state: state,
            tokensToReturn: new address[](0),
            tokensToRevoke: new address[](0),
            spendersToRevoke: new address[](0)
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(ensoFuse),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256,bytes32,bytes32,bytes32[],bytes[],address[],address[],address[]))",
                enterData
            )
        );

        // when - must NOT revert
        vm.prank(ALPHA);
        plasmaVault.execute(actions);

        // then - the shortcut actually executed (DAI landed in the executor)
        address executorAddress = _getEnsoExecutorAddress();
        assertTrue(executorAddress != address(0), "Executor should be created");
        assertEq(
            ERC20(DAI).balanceOf(executorAddress),
            SWAP_DAI_AMOUNT,
            "Executor should physically hold DAI from the FLAG_DATA swap"
        );
    }

    // ============================================================
    // IL-8047 follow-up (2/2): FLAG_DATA slot restaged mid-shortcut
    // ============================================================
    //
    // Regression tests for the residual raised in the second independent review: the fuse reads the
    // FLAG_DATA selector out of the SUPPLIED `state`, but the production VM writes every command's
    // return data back into `state` (output byte 11) before the next command runs. An unvalidated
    // STATICCALL to an attacker contract could therefore overwrite the slot after validation, and a
    // later FLAG_DATA command on a granted target would dispatch a selector nobody checked.
    //
    // The mock VM does not model state writes, so the exploit tests etch the bytecode of the
    // production DelegateEnsoShortcuts V2 (enso-weiroll 1.4.1) over the mock: the executor
    // delegatecalls the real VM and a missing revert means the smuggled call really ran.

    address constant PRODUCTION_DELEGATE_ENSO_SHORTCUTS = 0xA2F4f9C6ec598CA8c633024f8851c79CA5F43e48;

    function _useProductionEnsoVm() internal {
        assertGt(PRODUCTION_DELEGATE_ENSO_SHORTCUTS.code.length, 0, "Production VM must exist at the fork block");
        vm.etch(address(mockDelegateEnsoShortcuts), PRODUCTION_DELEGATE_ENSO_SHORTCUTS.code);
    }

    /// @dev Full weiroll command word: selector (bytes 0-3), flags (byte 4), first argument index
    ///      (byte 5; the remaining index bytes are left 0 and are never reached when it is 0xff or
    ///      the command is FLAG_DATA), output index (byte 11) and target (bytes 12-31).
    function _buildVmCommand(
        address target_,
        bytes4 selector_,
        uint256 flags_,
        uint8 index0_,
        uint8 output_
    ) internal pure returns (bytes32) {
        return
            bytes32(
                (uint256(uint32(selector_)) << 224) |
                    (flags_ << 216) |
                    (uint256(index0_) << 208) |
                    (uint256(output_) << 160) |
                    uint256(uint160(target_))
            );
    }

    function _enterDataForCommands(
        bytes32[] memory commands_,
        bytes[] memory state_
    ) internal pure returns (EnsoFuseEnterData memory) {
        return
            EnsoFuseEnterData({
                tokenOut: USDC,
                amountOut: SWAP_USDC_AMOUNT,
                wEthAmount: 0,
                accountId: bytes32(uint256(1)),
                requestId: bytes32(uint256(1)),
                commands: commands_,
                state: state_,
                tokensToReturn: new address[](0),
                tokensToRevoke: new address[](0),
                spendersToRevoke: new address[](0)
            });
    }

    function testShouldRevertWhenStaticcallOverwritesFlagDataSlotBeforeDispatch() public {
        // given - the reviewer's PoC on the real VM: state[0] as supplied carries the GRANTED swap
        // selector, but command 0 - a STATICCALL, never substrate-checked - writes attacker-chosen,
        // selector-first calldata into state[0] (variable-length output 0x80). Pre-fix command 1
        // was validated as (mockEnsoTarget, swap) and the VM then dispatched removeLiquidity.
        // The supplied swap is a decoy that would itself revert if dispatched (amountIn 1 with no
        // allowance - the real VM approves nothing), so without the fix the only way this shortcut
        // completes is the restaged removeLiquidity really running.
        _useProductionEnsoVm();
        MockEnsoStateStager stager = new MockEnsoStateStager();
        stager.setPayload(abi.encodeWithSelector(MockEnsoTarget.removeLiquidity.selector, DAI, SWAP_DAI_AMOUNT));

        bytes32[] memory commands = new bytes32[](2);
        commands[0] = _buildVmCommand(address(stager), MockEnsoStateStager.stagedCalldata.selector, 0x02, 0xff, 0x80);
        commands[1] = _buildVmCommand(address(mockEnsoTarget), MockEnsoTarget.swap.selector, 0x21, 0x00, 0xff);

        bytes[] memory state = new bytes[](1);
        state[0] = abi.encodeWithSelector(MockEnsoTarget.swap.selector, USDC, DAI, 1, SWAP_DAI_AMOUNT);

        // when & then
        vm.prank(ALPHA);
        vm.expectRevert(abi.encodeWithSelector(EnsoFuse.EnsoFuseStateSlotOverwritten.selector, uint256(0)));
        plasmaVault.execute(_singleEnterAction(_enterDataForCommands(commands, state)));
    }

    function testShouldRevertWhenStaticcallReplacesWholeStateBeforeFlagData() public {
        // given - same attack through IDX_USE_STATE (0xfe): the STATICCALL's return data replaces the
        // whole state array, so no slot validated from the supplied state survives it. Same
        // self-reverting decoy as above.
        _useProductionEnsoVm();
        MockEnsoStateStager stager = new MockEnsoStateStager();
        stager.setPayload(abi.encodeWithSelector(MockEnsoTarget.removeLiquidity.selector, DAI, SWAP_DAI_AMOUNT));

        bytes32[] memory commands = new bytes32[](2);
        commands[0] = _buildVmCommand(address(stager), MockEnsoStateStager.stagedState.selector, 0x02, 0xff, 0xfe);
        commands[1] = _buildVmCommand(address(mockEnsoTarget), MockEnsoTarget.swap.selector, 0x21, 0x00, 0xff);

        bytes[] memory state = new bytes[](1);
        state[0] = abi.encodeWithSelector(MockEnsoTarget.swap.selector, USDC, DAI, 1, SWAP_DAI_AMOUNT);

        // when & then
        vm.prank(ALPHA);
        vm.expectRevert(abi.encodeWithSelector(EnsoFuse.EnsoFuseStateSlotOverwritten.selector, uint256(0)));
        plasmaVault.execute(_singleEnterAction(_enterDataForCommands(commands, state)));
    }

    function testShouldRevertWhenTupleReturnWritesFlagDataSlot() public {
        // given - a FLAG_TUPLE_RETURN write (`writeTuple`) lands in state[out & 0x7f] just like a
        // plain write. Validator-level pin of the tuple branch of the write tracking; the revert
        // happens before the executor runs, so the mock VM suffices.
        MockEnsoStateStager stager = new MockEnsoStateStager();

        bytes32[] memory commands = new bytes32[](2);
        commands[0] = _buildVmCommand(address(stager), MockEnsoStateStager.stagedWord.selector, 0x82, 0xff, 0x00);
        commands[1] = _buildVmCommand(address(mockEnsoTarget), MockEnsoTarget.swap.selector, 0x21, 0x00, 0xff);

        bytes[] memory state = new bytes[](2);
        state[0] = abi.encodeWithSelector(MockEnsoTarget.swap.selector, USDC, DAI, 0, SWAP_DAI_AMOUNT);
        state[1] = abi.encode(uint256(0));

        // when & then
        vm.prank(ALPHA);
        vm.expectRevert(abi.encodeWithSelector(EnsoFuse.EnsoFuseStateSlotOverwritten.selector, uint256(0)));
        plasmaVault.execute(_singleEnterAction(_enterDataForCommands(commands, state)));
    }

    function testShouldSucceedWhenTupleReturnUsesStateReplaceIndex() public {
        // given - over-correction guard: IDX_USE_STATE replaces the whole state only for NON-tuple
        // writes; `writeTuple` masks 0xfe to slot 126. A tuple write with output 0xfe must not
        // poison a FLAG_DATA command reading an untouched slot 0.
        MockEnsoStateStager stager = new MockEnsoStateStager();

        bytes32[] memory commands = new bytes32[](2);
        commands[0] = _buildVmCommand(address(stager), MockEnsoStateStager.stagedWord.selector, 0x82, 0xff, 0xfe);
        commands[1] = _buildVmCommand(address(mockEnsoTarget), MockEnsoTarget.swap.selector, 0x21, 0x00, 0xff);

        bytes[] memory state = new bytes[](2);
        state[0] = abi.encodeWithSelector(MockEnsoTarget.swap.selector, USDC, DAI, 0, SWAP_DAI_AMOUNT);
        state[1] = abi.encode(uint256(0));

        // when - must NOT revert
        vm.prank(ALPHA);
        plasmaVault.execute(_singleEnterAction(_enterDataForCommands(commands, state)));

        // then
        assertEq(ERC20(DAI).balanceOf(_getEnsoExecutorAddress()), SWAP_DAI_AMOUNT, "FLAG_DATA swap must have executed");
    }

    function testShouldSucceedWhenFlagDataSlotIsWrittenOnlyByOtherOrLaterCommands() public {
        // given - over-correction guard on the real VM, pinning three boundaries of the tracking:
        //  - command 0 (extended STATICCALL) writes a DIFFERENT slot (state[1]);
        //  - its argument-index word has byte 11 = 0x00, a decoy output index that must not be
        //    recorded, since that element is metadata and never dispatched;
        //  - command 3 writes state[0] only AFTER the FLAG_DATA command already dispatched.
        _useProductionEnsoVm();
        MockEnsoStateStager stager = new MockEnsoStateStager();

        bytes32[] memory commands = new bytes32[](4);
        commands[0] = _buildVmCommand(address(stager), MockEnsoStateStager.stagedWord.selector, 0x42, 0x00, 0x01);
        commands[1] = bytes32(uint256(0xff) << 248); // indices: end of args; byte 11 (decoy) = 0x00
        commands[2] = _buildVmCommand(address(mockEnsoTarget), MockEnsoTarget.swap.selector, 0x21, 0x00, 0xff);
        commands[3] = _buildVmCommand(address(stager), MockEnsoStateStager.stagedWord.selector, 0x02, 0xff, 0x00);

        bytes[] memory state = new bytes[](2);
        state[0] = abi.encodeWithSelector(MockEnsoTarget.swap.selector, USDC, DAI, 0, SWAP_DAI_AMOUNT);
        state[1] = abi.encode(uint256(0));

        // when - must NOT revert
        vm.prank(ALPHA);
        plasmaVault.execute(_singleEnterAction(_enterDataForCommands(commands, state)));

        // then - the granted FLAG_DATA swap ran on the production VM
        assertEq(
            ERC20(DAI).balanceOf(_getEnsoExecutorAddress()),
            SWAP_DAI_AMOUNT,
            "FLAG_DATA swap must have executed on the production VM"
        );
    }

    // ============================================================
    // IL-8048: Residual ERC-20 allowances after an Enso shortcut
    // ============================================================
    //
    // Regression tests for the bug where EnsoExecutor.execute() left every allowance created by
    // the delegatecalled weiroll shortcut in place forever. MockDelegateEnsoShortcuts models the
    // real Enso VM's routine behavior of issuing `approve(target, type(uint256).max)` for every
    // CALL command (see MockDelegateEnsoShortcuts.sol:63,66), so these tests exercise the actual
    // executor allowance state, not a synthetic setup.

    function testShouldRevokeDeclaredAllowanceAfterEnter() public {
        // given - a standard USDC -> DAI swap through the mock target, which leaves a max
        // USDC allowance from the executor to the mock target as a side effect of the shortcut
        bytes32[] memory commands = new bytes32[](1);
        commands[0] = _buildEnsoCommand(address(mockEnsoTarget), MockEnsoTarget.swap.selector, 0x01);

        bytes[] memory state = new bytes[](1);
        state[0] = abi.encode(USDC, DAI, SWAP_USDC_AMOUNT, SWAP_DAI_AMOUNT);

        address[] memory tokensToRevoke = new address[](1);
        tokensToRevoke[0] = USDC;
        address[] memory spendersToRevoke = new address[](1);
        spendersToRevoke[0] = address(mockEnsoTarget);

        EnsoFuseEnterData memory enterData = EnsoFuseEnterData({
            tokenOut: USDC,
            amountOut: SWAP_USDC_AMOUNT,
            wEthAmount: 0,
            accountId: bytes32(uint256(1)),
            requestId: bytes32(uint256(1)),
            commands: commands,
            state: state,
            tokensToReturn: new address[](0),
            tokensToRevoke: tokensToRevoke,
            spendersToRevoke: spendersToRevoke
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(ensoFuse),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256,bytes32,bytes32,bytes32[],bytes[],address[],address[],address[]))",
                enterData
            )
        );

        // when
        vm.prank(ALPHA);
        plasmaVault.execute(actions);

        // then - the declared (USDC, mockEnsoTarget) allowance must be revoked to zero
        address executorAddress = _getEnsoExecutorAddress();
        assertEq(
            ERC20(USDC).allowance(executorAddress, address(mockEnsoTarget)),
            0,
            "Declared allowance must be revoked to zero after execute()"
        );

        // sanity: the shortcut itself still executed correctly
        assertEq(
            ERC20(DAI).balanceOf(executorAddress),
            SWAP_DAI_AMOUNT,
            "Executor should still physically hold the swapped DAI"
        );
    }

    function testShouldLeaveAllowanceWhenPairNotDeclared() public {
        // given - the same swap, but the caller declares NO revocation pairs. This documents the
        // residual-risk contract: an undeclared approval is not detected by the contract and
        // persists on the executor. It also guards against a regression where a future change
        // wrongly assumes every approval is swept automatically.
        EnsoFuseEnterData memory enterData = _buildEnsoEnterData(USDC, SWAP_USDC_AMOUNT, DAI, SWAP_DAI_AMOUNT);

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(ensoFuse),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256,bytes32,bytes32,bytes32[],bytes[],address[],address[],address[]))",
                enterData
            )
        );

        // when
        vm.prank(ALPHA);
        plasmaVault.execute(actions);

        // then - the shortcut succeeded and the undeclared allowance is left standing
        address executorAddress = _getEnsoExecutorAddress();
        assertGt(
            ERC20(USDC).allowance(executorAddress, address(mockEnsoTarget)),
            0,
            "Undeclared allowance is not detected and must remain standing"
        );
        assertEq(
            ERC20(DAI).balanceOf(executorAddress),
            SWAP_DAI_AMOUNT,
            "Swap should still succeed when no revocation pairs are declared"
        );
    }

    function testShouldRevertWhenRevokeArrayLengthsMismatch() public {
        // given - 1 token to revoke but 0 paired spenders
        EnsoFuseEnterData memory enterData = _buildEnsoEnterData(USDC, SWAP_USDC_AMOUNT, DAI, SWAP_DAI_AMOUNT);
        enterData.tokensToRevoke = new address[](1);
        enterData.tokensToRevoke[0] = USDC;
        // enterData.spendersToRevoke stays empty (length 0) -> length mismatch

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(ensoFuse),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256,bytes32,bytes32,bytes32[],bytes[],address[],address[],address[]))",
                enterData
            )
        );

        // when & then
        vm.prank(ALPHA);
        vm.expectRevert(abi.encodeWithSelector(EnsoFuse.EnsoFuseInvalidArrayLength.selector));
        plasmaVault.execute(actions);
    }

    function testShouldRevokeMultipleDeclaredAllowances() public {
        // given - two chained swap commands that each leave a distinct max allowance behind:
        // command 1 swaps USDC -> DAI (approves USDC to mockEnsoTarget), command 2 swaps part of
        // the resulting DAI back to USDC (approves DAI to mockEnsoTarget)
        bytes32[] memory commands = new bytes32[](2);
        commands[0] = _buildEnsoCommand(address(mockEnsoTarget), MockEnsoTarget.swap.selector, 0x01);
        commands[1] = _buildEnsoCommand(address(mockEnsoTarget), MockEnsoTarget.swap.selector, 0x01);

        bytes[] memory state = new bytes[](2);
        state[0] = abi.encode(USDC, DAI, SWAP_USDC_AMOUNT, SWAP_DAI_AMOUNT);
        state[1] = abi.encode(DAI, USDC, 1_000e18, 500e6);

        address[] memory tokensToRevoke = new address[](2);
        tokensToRevoke[0] = USDC;
        tokensToRevoke[1] = DAI;
        address[] memory spendersToRevoke = new address[](2);
        spendersToRevoke[0] = address(mockEnsoTarget);
        spendersToRevoke[1] = address(mockEnsoTarget);

        EnsoFuseEnterData memory enterData = EnsoFuseEnterData({
            tokenOut: USDC,
            // amountOut funds the executor with SWAP_USDC_AMOUNT USDC before the delegatecall
            // (command 1 needs the full amount as its transferFrom input); the executor's real
            // USDC balance after both commands run is only 500e6 (spent in command 1, partially
            // recovered in command 2), which just means EnsoExecutor tracks the difference as a
            // pending expected balance - irrelevant to this test's allowance assertions.
            amountOut: SWAP_USDC_AMOUNT,
            wEthAmount: 0,
            accountId: bytes32(uint256(1)),
            requestId: bytes32(uint256(1)),
            commands: commands,
            state: state,
            tokensToReturn: new address[](0),
            tokensToRevoke: tokensToRevoke,
            spendersToRevoke: spendersToRevoke
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(ensoFuse),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256,bytes32,bytes32,bytes32[],bytes[],address[],address[],address[]))",
                enterData
            )
        );

        // when
        vm.prank(ALPHA);
        plasmaVault.execute(actions);

        // then - both declared allowances must be revoked to zero
        address executorAddress = _getEnsoExecutorAddress();
        assertEq(
            ERC20(USDC).allowance(executorAddress, address(mockEnsoTarget)),
            0,
            "Declared USDC allowance must be revoked to zero"
        );
        assertEq(
            ERC20(DAI).allowance(executorAddress, address(mockEnsoTarget)),
            0,
            "Declared DAI allowance must be revoked to zero"
        );
    }

    // ============================================================
    // IL-8046: `tokensToReturn` was validated and forwarded but never consumed in execute()
    // ============================================================
    //
    // Regression tests for the bug where route outputs other than the residual `tokenOut`
    // stayed in EnsoExecutor forever (until a manual exit()), while the pending-balance
    // placeholder still valued the consumed input token. See audit/IL-7942/IL-8046/01-assessment.md
    // and 02-plan.md for the full analysis.

    // Helper: build EnsoFuseEnterData for a single-command swap with an explicit tokensToReturn
    // list (the base _buildEnsoEnterData always passes an empty tokensToReturn).
    function _buildEnsoEnterDataWithReturn(
        address tokenIn_,
        uint256 amountIn_,
        address tokenOut_,
        uint256 minAmountOut_,
        address[] memory tokensToReturn_
    ) internal view returns (EnsoFuseEnterData memory) {
        EnsoFuseEnterData memory enterData = _buildEnsoEnterData(tokenIn_, amountIn_, tokenOut_, minAmountOut_);
        enterData.tokensToReturn = tokensToReturn_;
        return enterData;
    }

    function _executeEnter(EnsoFuseEnterData memory enterData_) internal {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(ensoFuse),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256,bytes32,bytes32,bytes32[],bytes[],address[],address[],address[]))",
                enterData_
            )
        );

        vm.prank(ALPHA);
        plasmaVault.execute(actions);
    }

    function testShouldReturnTokensToReturnToVaultAfterEnter() public {
        // given - USDC -> DAI swap, declaring DAI (the route's output) as tokensToReturn
        address[] memory tokensToReturn = new address[](1);
        tokensToReturn[0] = DAI;

        EnsoFuseEnterData memory enterData = _buildEnsoEnterDataWithReturn(
            USDC,
            SWAP_USDC_AMOUNT,
            DAI,
            SWAP_DAI_AMOUNT,
            tokensToReturn
        );

        // when
        _executeEnter(enterData);

        // then - DAI must be swept out of the executor and into the vault
        address executorAddress = _getEnsoExecutorAddress();
        assertEq(ERC20(DAI).balanceOf(executorAddress), 0, "Executor must hold 0 DAI after tokensToReturn sweep");
        assertEq(ERC20(DAI).balanceOf(address(plasmaVault)), SWAP_DAI_AMOUNT, "Vault DAI must increase by swap amount");

        // and - no pending balance is recorded since tokensToReturn was non-empty
        (address executorAsset, uint256 executorBalance) = _getEnsoExecutorBalance();
        assertEq(executorAsset, USDC, "Pending balance asset is still tokenOut (USDC)");
        assertEq(executorBalance, 0, "Pending balance amount must be zero once outputs are swept");
        assertEq(
            plasmaVault.totalAssetsInMarket(IporFusionMarkets.ENSO),
            0,
            "ENSO market must report zero once outputs are swept"
        );
    }

    function testShouldReturnMultipleOutputTokensAndSkipAlreadySweptTokens() public {
        // given - a two-command route: USDC -> DAI and USDC -> WETH, producing two distinct
        // output tokens in one execute() call. Fund the mock target with WETH for the second leg.
        uint256 halfUsdc = SWAP_USDC_AMOUNT / 2; // 5_000e6
        uint256 daiOut = 5_000e18;
        uint256 wethOut = 1e18;
        deal(WETH, address(mockEnsoTarget), wethOut);

        bytes32[] memory commands = new bytes32[](2);
        commands[0] = _buildEnsoCommand(address(mockEnsoTarget), MockEnsoTarget.swap.selector, 0x01);
        commands[1] = _buildEnsoCommand(address(mockEnsoTarget), MockEnsoTarget.swap.selector, 0x01);

        bytes[] memory state = new bytes[](2);
        state[0] = abi.encode(USDC, DAI, halfUsdc, daiOut);
        state[1] = abi.encode(USDC, WETH, halfUsdc, wethOut);

        // tokensToReturn includes tokenOut (USDC, already swept as the residual-input leg),
        // a duplicate (DAI twice) and WETH (also the ETH re-wrap token, here unused) - all must
        // be handled without reverting.
        address[] memory tokensToReturn = new address[](4);
        tokensToReturn[0] = DAI;
        tokensToReturn[1] = WETH;
        tokensToReturn[2] = USDC;
        tokensToReturn[3] = DAI;

        EnsoFuseEnterData memory enterData = EnsoFuseEnterData({
            tokenOut: USDC,
            amountOut: SWAP_USDC_AMOUNT,
            wEthAmount: 0,
            accountId: bytes32(uint256(1)),
            requestId: bytes32(uint256(1)),
            commands: commands,
            state: state,
            tokensToReturn: tokensToReturn,
            tokensToRevoke: new address[](0),
            spendersToRevoke: new address[](0)
        });

        uint256 vaultDaiBefore = ERC20(DAI).balanceOf(address(plasmaVault));
        uint256 vaultWethBefore = ERC20(WETH).balanceOf(address(plasmaVault));

        // when
        _executeEnter(enterData);

        // then - every output token is fully swept out of the executor
        address executorAddress = _getEnsoExecutorAddress();
        assertEq(ERC20(DAI).balanceOf(executorAddress), 0, "Executor must hold 0 DAI");
        assertEq(ERC20(WETH).balanceOf(executorAddress), 0, "Executor must hold 0 WETH");
        assertEq(ERC20(USDC).balanceOf(executorAddress), 0, "Executor must hold 0 USDC");

        assertEq(
            ERC20(DAI).balanceOf(address(plasmaVault)) - vaultDaiBefore,
            daiOut,
            "Vault DAI must increase by the DAI leg output"
        );
        assertEq(
            ERC20(WETH).balanceOf(address(plasmaVault)) - vaultWethBefore,
            wethOut,
            "Vault WETH must increase by the WETH leg output"
        );

        (address executorAsset, uint256 executorBalance) = _getEnsoExecutorBalance();
        assertEq(executorAsset, USDC, "Pending balance asset is still tokenOut (USDC)");
        assertEq(executorBalance, 0, "Pending balance amount must be zero once outputs are swept");
    }

    function testShouldNotDoubleCountReturnedUnderlyingInTotalAssets() public {
        // given - vault underlying is USDC. Fund the vault with DAI (so enter() can transfer
        // tokenOut = DAI to the executor) and fund the mock target with USDC (the route output,
        // which is also the vault underlying, so it is counted as idle balance the instant it
        // lands - PlasmaVault.sol:1512/1516).
        uint256 daiAmountOut = 10_000e18;
        uint256 usdcSwapOutput = 9_990e6; // route incurs slippage/fees vs. a 1:1 DAI->USDC rate
        deal(DAI, address(plasmaVault), daiAmountOut);
        deal(USDC, address(mockEnsoTarget), usdcSwapOutput);

        address[] memory tokensToReturn = new address[](1);
        tokensToReturn[0] = USDC;

        EnsoFuseEnterData memory enterData = _buildEnsoEnterDataWithReturn(
            DAI,
            daiAmountOut,
            USDC,
            usdcSwapOutput,
            tokensToReturn
        );

        uint256 totalAssetsBefore = plasmaVault.totalAssets();

        // when
        _executeEnter(enterData);

        // then - the returned USDC (vault underlying) is counted exactly once, as idle balance;
        // the DAI cost basis the ENSO market would otherwise report must be exactly zero, not
        // ~10_000e6-worth of DAI on top - this is the double-counting rule from 02-plan.md §
        // "Double counting", not merely the transfer.
        uint256 totalAssetsAfter = plasmaVault.totalAssets();
        assertEq(
            totalAssetsAfter,
            totalAssetsBefore + usdcSwapOutput,
            "totalAssets must increase by exactly the returned USDC, no double count"
        );
        assertEq(
            plasmaVault.totalAssetsInMarket(IporFusionMarkets.ENSO),
            0,
            "ENSO market must report zero once its output was declared returned"
        );
    }

    function testShouldKeepPendingBalanceWhenTokensToReturnIsEmpty() public {
        // given / when - identical to the pre-existing swap path: tokensToReturn is empty, so
        // the cross-chain / delayed-leg placeholder must be kept exactly as at HEAD. This guards
        // against an over-eager fix removing the placeholder outright; it is not evidence for
        // the fix itself (it also passes unmodified at HEAD).
        _executeSwap(USDC, SWAP_USDC_AMOUNT, DAI, SWAP_DAI_AMOUNT);

        // then
        address executorAddress = _getEnsoExecutorAddress();
        assertEq(ERC20(DAI).balanceOf(executorAddress), SWAP_DAI_AMOUNT, "Executor must still hold the DAI output");

        (address executorAsset, uint256 executorBalance) = _getEnsoExecutorBalance();
        assertEq(executorAsset, USDC, "Pending balance asset is tokenOut (USDC)");
        assertEq(executorBalance, SWAP_USDC_AMOUNT, "Pending balance amount must equal the consumed USDC");
    }

    function testShouldRevertWhenTokenToReturnSubstrateNotGranted() public {
        // given - WBTC is not in granted substrates; listing it in tokensToReturn must revert
        // during substrate validation before execute() runs. This validation predates the fix
        // (EnsoFuse.sol:206-219 already checked tokensToReturn); it is now load-bearing for the
        // consumer added in this ticket, not evidence for the fix itself.
        address WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

        address[] memory tokensToReturn = new address[](1);
        tokensToReturn[0] = WBTC;

        EnsoFuseEnterData memory enterData = _buildEnsoEnterDataWithReturn(
            USDC,
            SWAP_USDC_AMOUNT,
            DAI,
            SWAP_DAI_AMOUNT,
            tokensToReturn
        );

        // when & then
        vm.prank(ALPHA);
        vm.expectRevert(abi.encodeWithSignature("EnsoFuseUnsupportedAsset(address)", WBTC));
        plasmaVault.execute(_singleEnterAction(enterData));
    }

    function _singleEnterAction(EnsoFuseEnterData memory enterData_) internal view returns (FuseAction[] memory) {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(ensoFuse),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256,bytes32,bytes32,bytes32[],bytes[],address[],address[],address[]))",
                enterData_
            )
        );
        return actions;
    }
}
