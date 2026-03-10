// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {FusionFactory} from "../../../contracts/factory/FusionFactory.sol";
import {FusionFactoryDaoFeePackagesHelper} from "../../test_helpers/FusionFactoryDaoFeePackagesHelper.sol";
import {TestAddresses} from "../../test_helpers/TestAddresses.sol";
import {FusionFactoryLogicLib} from "../../../contracts/factory/lib/FusionFactoryLogicLib.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {EulerFuseLib, EulerSubstrate} from "../../../contracts/fuses/euler/EulerFuseLib.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";
import {FuseAction} from "../../../contracts/interfaces/IPlasmaVault.sol";
import {IEVC} from "ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";
import {IVault} from "ethereum-vault-connector/src/interfaces/IVault.sol";
import {IBorrowing} from "../../../contracts/fuses/euler/ext/IBorrowing.sol";
import {EulerV2BatchFuse, EulerV2BatchItem, EulerV2BatchFuseData} from "../../../contracts/fuses/euler/EulerV2BatchFuse.sol";
import {CallbackHandlerEuler} from "../../../contracts/handlers/callbacks/CallbackHandlerEuler.sol";
import {CallbackData} from "../../../contracts/libraries/CallbackHandlerLib.sol";
import {AaveV3SupplyFuse, AaveV3SupplyFuseEnterData, AaveV3SupplyFuseExitData} from "../../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {AaveV3BorrowFuse, AaveV3BorrowFuseEnterData, AaveV3BorrowFuseExitData} from "../../../contracts/fuses/aave_v3/AaveV3BorrowFuse.sol";
import {AaveV3BalanceFuse} from "../../../contracts/fuses/aave_v3/AaveV3BalanceFuse.sol";
import {UniswapV3SwapFuse, UniswapV3SwapFuseEnterData} from "../../../contracts/fuses/uniswap/UniswapV3SwapFuse.sol";
import {ZeroBalanceFuse} from "../../../contracts/fuses/ZeroBalanceFuse.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";

/// @title EulerV2 Batch Flash Loan Flow Test
/// @notice Demonstrates EVC batch "flash liquidity" with realistic DeFi operations in the callback:
///         flash borrow USDC from Euler → supply USDC to Aave as collateral → borrow WETH from Aave →
///         swap WETH→USDC on Uniswap V3 → repay Euler. Aave leveraged position remains open.
/// @dev Uses deferred liquidity checks in EVC batch to execute flash-loan-like operations entirely within Euler V2.
///      This simulates a common DeFi pattern: use flash liquidity to open a leveraged position on another protocol.
contract EulerV2BatchFlashLoan is Test {
    // Euler V2
    address public constant EULER_V2_EVC = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;
    address public constant EULER_VAULT = 0xe0a80d35bB6618CBA260120b279d357978c42BCE;

    // Aave V3
    address public constant AAVE_POOL_ADDRESSES_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;

    // Uniswap V3
    address public constant UNIVERSAL_ROUTER = 0xEf1c6E67703c7BD7107eed8303Fbe6EC2554BF6B;

    // Tokens
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Infrastructure
    address public constant FUSION_FACTORY = 0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852;
    address public constant BALANCE_FUSE_EULERV2 = 0xAE9a37DD9229687662834e6696e396e7837BAABD;

    // Roles
    address public constant ATOMIST = TestAddresses.ATOMIST;
    address public constant FUSE_MANAGER = TestAddresses.FUSE_MANAGER;
    address public constant ALPHA = TestAddresses.ALPHA;
    address public constant USER = TestAddresses.USER;

    EulerV2BatchFuse public batchFuse;
    AaveV3SupplyFuse public aaveSupplyFuse;
    AaveV3BorrowFuse public aaveBorrowFuse;
    UniswapV3SwapFuse public uniswapSwapFuse;

    address public plasmaVault;
    address public accessManager;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 23485836);

        FusionFactory fusionFactory = FusionFactory(FUSION_FACTORY);
        FusionFactoryDaoFeePackagesHelper.setupDefaultDaoFeePackages(vm, fusionFactory);

        FusionFactoryLogicLib.FusionInstance memory fusionInstance = fusionFactory.clone(
            "EulerV2BatchFL",
            "EULERV2BATCHFL",
            USDC,
            0,
            TestAddresses.OWNER,
            0
        );

        plasmaVault = fusionInstance.plasmaVault;
        accessManager = fusionInstance.accessManager;

        // Deploy fuses
        batchFuse = new EulerV2BatchFuse(IporFusionMarkets.EULER_V2, EULER_V2_EVC);
        aaveSupplyFuse = new AaveV3SupplyFuse(IporFusionMarkets.AAVE_V3, AAVE_POOL_ADDRESSES_PROVIDER);
        aaveBorrowFuse = new AaveV3BorrowFuse(IporFusionMarkets.AAVE_V3, AAVE_POOL_ADDRESSES_PROVIDER);
        uniswapSwapFuse = new UniswapV3SwapFuse(IporFusionMarkets.UNISWAP_SWAP_V3, UNIVERSAL_ROUTER);

        _setupRoles();
        _registerFuses();
        _grantMarketSubstratesForEuler();
        _grantMarketSubstratesForAave();
        _grantMarketSubstratesForUniswap();
        _setupBalanceFuses();
        _registerCallbackHandler();

        // Convert to public vault so anyone can deposit
        vm.prank(ATOMIST);
        PlasmaVaultGovernance(plasmaVault).convertToPublicVault();

        // Fund PlasmaVault via deposit (USER deposits USDC)
        uint256 depositAmount = 10_000e6;
        deal(USDC, USER, depositAmount);
        vm.startPrank(USER);
        ERC20(USDC).approve(plasmaVault, depositAmount);
        PlasmaVault(plasmaVault).deposit(depositAmount, USER);
        vm.stopPrank();
    }

    /// @notice Demonstrates EVC batch flash liquidity: borrow from Euler, open leveraged position on Aave + swap, repay Euler
    /// @dev The EVC deferred checks allow borrowing without collateral mid-batch, as long as debt is repaid before batch ends.
    ///      Flow:
    ///        1. enableController — register PlasmaVault as borrower for Euler vault
    ///        2. borrow 1,000 USDC from Euler (deferred check, no collateral needed)
    ///        3. onEulerFlashLoan callback — inner FuseActions:
    ///           a. AaveV3SupplyFuse.enter() — supply 1,000 USDC to Aave V3 as collateral
    ///           b. AaveV3BorrowFuse.enter() — borrow 0.1 WETH from Aave V3 against USDC collateral
    ///           c. UniswapV3SwapFuse.enter() — swap 0.1 WETH → USDC on Uniswap V3
    ///        4. repay 1,000 USDC to Euler (using vault's existing USDC + swap proceeds)
    ///        5. disableController — cleanup
    ///      After execution: PlasmaVault holds a leveraged Aave position (USDC collateral + WETH debt)
    function testShouldExecuteFlashLoanWithAaveBorrowAndSwapInCallback() public {
        uint256 flashLoanAmount = 1_000e6;
        uint256 wethBorrowAmount = 0.1 ether;

        // --- Record state before ---
        uint256 usdcBalanceBefore = ERC20(USDC).balanceOf(plasmaVault);
        address subAccount = EulerFuseLib.generateSubAccountAddress(plasmaVault, bytes1(0x00));

        // --- Build callback FuseActions (executed inside the EVC batch callback) ---
        // These actions use flash-borrowed USDC to open a leveraged position on Aave:
        //   1. Supply USDC to Aave as collateral
        //   2. Borrow WETH from Aave against the collateral
        //   3. Swap WETH → USDC on Uniswap (to get USDC back for Euler repay)
        FuseAction[] memory callbackActions = new FuseAction[](3);

        // Action 1: Supply flash-borrowed USDC to Aave V3 as collateral
        callbackActions[0] = FuseAction(
            address(aaveSupplyFuse),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                AaveV3SupplyFuseEnterData({
                    asset: USDC,
                    amount: flashLoanAmount,
                    userEModeCategoryId: 256 // > 255 = ignored
                })
            )
        );

        // Action 2: Borrow WETH from Aave V3 against USDC collateral
        callbackActions[1] = FuseAction(
            address(aaveBorrowFuse),
            abi.encodeWithSignature(
                "enter((address,uint256))",
                AaveV3BorrowFuseEnterData({asset: WETH, amount: wethBorrowAmount})
            )
        );

        // Action 3: Swap WETH → USDC on Uniswap V3 (converts borrowed WETH to USDC for Euler repay)
        callbackActions[2] = FuseAction(
            address(uniswapSwapFuse),
            abi.encodeWithSignature(
                "enter((uint256,uint256,bytes))",
                UniswapV3SwapFuseEnterData({
                    tokenInAmount: wethBorrowAmount,
                    minOutAmount: 0,
                    path: abi.encodePacked(WETH, uint24(500), USDC)
                })
            )
        );

        // --- Build EVC batch items ---
        EulerV2BatchItem[] memory batchItems = new EulerV2BatchItem[](5);

        // Step 1: Enable controller — register as borrower for Euler vault
        batchItems[0] = EulerV2BatchItem(
            EULER_V2_EVC,
            bytes1(0x00),
            abi.encodeWithSelector(IEVC.enableController.selector, plasmaVault, EULER_VAULT)
        );

        // Step 2: Borrow USDC (deferred liquidity check — no collateral required mid-batch)
        batchItems[1] = EulerV2BatchItem(
            EULER_VAULT,
            bytes1(0x00),
            abi.encodeWithSelector(IBorrowing.borrow.selector, flashLoanAmount, plasmaVault)
        );

        // Step 3: Callback — execute inner FuseActions (Aave supply collateral + borrow WETH + swap to USDC)
        batchItems[2] = EulerV2BatchItem(
            plasmaVault,
            bytes1(0x00),
            abi.encodeWithSelector(
                CallbackHandlerEuler.onEulerFlashLoan.selector,
                abi.encode(
                    CallbackData({
                        asset: USDC,
                        addressToApprove: EULER_VAULT,
                        amountToApprove: flashLoanAmount,
                        actionData: abi.encode(callbackActions)
                    })
                )
            )
        );

        // Step 4: Repay the borrowed USDC to Euler
        batchItems[3] = EulerV2BatchItem(
            EULER_VAULT,
            bytes1(0x00),
            abi.encodeWithSelector(IBorrowing.repay.selector, flashLoanAmount, plasmaVault)
        );

        // Step 5: Disable controller — cleanup
        batchItems[4] = EulerV2BatchItem(
            EULER_VAULT,
            bytes1(0x00),
            abi.encodeWithSelector(IVault.disableController.selector)
        );

        // --- Build batch fuse data with approvals (asset→vault pairs for Euler repay) ---
        address[] memory assetsForApprovals = new address[](1);
        assetsForApprovals[0] = USDC;

        address[] memory eulerVaultsForApprovals = new address[](1);
        eulerVaultsForApprovals[0] = EULER_VAULT;

        EulerV2BatchFuseData memory batchData = EulerV2BatchFuseData(
            batchItems,
            assetsForApprovals,
            eulerVaultsForApprovals
        );

        // --- Execute via PlasmaVault ---
        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(batchFuse),
            abi.encodeWithSelector(EulerV2BatchFuse.enter.selector, batchData)
        );

        vm.startPrank(ALPHA);
        PlasmaVault(plasmaVault).execute(enterCalls);
        vm.stopPrank();

        // --- Assertions ---
        uint256 usdcBalanceAfter = ERC20(USDC).balanceOf(plasmaVault);
        uint256 wethBalanceAfter = ERC20(WETH).balanceOf(plasmaVault);
        uint256 eulerDebtAfter = IBorrowing(EULER_VAULT).debtOf(subAccount);

        // Euler flash loan fully repaid — no outstanding debt on Euler
        assertEq(eulerDebtAfter, 0, "No debt should remain on Euler vault after repayment");

        // No WETH left in vault — all swapped to USDC
        assertEq(wethBalanceAfter, 0, "No WETH should remain in PlasmaVault (all swapped to USDC)");

        // USDC balance: started with 10,000. Flash borrowed 1,000, supplied to Aave (locked as collateral).
        // Swap proceeds (~0.1 WETH ≈ ~180-250 USDC) returned as USDC, used together with existing USDC for Euler repay.
        // Net effect: vault USDC decreased by ~(1,000 - swapProceeds) since collateral is locked in Aave.
        assertLt(
            usdcBalanceAfter,
            usdcBalanceBefore,
            "USDC balance should decrease (collateral locked in Aave)"
        );
        assertGt(
            usdcBalanceAfter,
            usdcBalanceBefore - flashLoanAmount,
            "USDC balance decrease should be less than flash loan amount (offset by swap proceeds)"
        );
    }

    // --- Setup helpers ---

    function _setupRoles() private {
        vm.prank(TestAddresses.OWNER);
        IporFusionAccessManager(accessManager).grantRole(Roles.ATOMIST_ROLE, ATOMIST, 0);

        vm.startPrank(ATOMIST);
        IporFusionAccessManager(accessManager).grantRole(Roles.ALPHA_ROLE, ALPHA, 0);
        IporFusionAccessManager(accessManager).grantRole(Roles.FUSE_MANAGER_ROLE, FUSE_MANAGER, 0);
        vm.stopPrank();
    }

    function _registerFuses() private {
        address[] memory fuses = new address[](4);
        fuses[0] = address(batchFuse);
        fuses[1] = address(aaveSupplyFuse);
        fuses[2] = address(aaveBorrowFuse);
        fuses[3] = address(uniswapSwapFuse);

        vm.startPrank(FUSE_MANAGER);
        PlasmaVaultGovernance(plasmaVault).addFuses(fuses);
        vm.stopPrank();
    }

    function _grantMarketSubstratesForEuler() private {
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: EULER_VAULT, isCollateral: true, canBorrow: true, subAccounts: 0x00})
        );

        vm.startPrank(FUSE_MANAGER);
        PlasmaVaultGovernance(plasmaVault).grantMarketSubstrates(IporFusionMarkets.EULER_V2, substrates);
        vm.stopPrank();
    }

    function _grantMarketSubstratesForAave() private {
        bytes32[] memory assets = new bytes32[](2);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);
        assets[1] = PlasmaVaultConfigLib.addressToBytes32(WETH);

        vm.startPrank(FUSE_MANAGER);
        PlasmaVaultGovernance(plasmaVault).grantMarketSubstrates(IporFusionMarkets.AAVE_V3, assets);
        vm.stopPrank();
    }

    function _grantMarketSubstratesForUniswap() private {
        bytes32[] memory tokens = new bytes32[](2);
        tokens[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);
        tokens[1] = PlasmaVaultConfigLib.addressToBytes32(WETH);

        vm.startPrank(FUSE_MANAGER);
        PlasmaVaultGovernance(plasmaVault).grantMarketSubstrates(IporFusionMarkets.UNISWAP_SWAP_V3, tokens);
        vm.stopPrank();
    }

    function _setupBalanceFuses() private {
        AaveV3BalanceFuse aaveBalanceFuse = new AaveV3BalanceFuse(
            IporFusionMarkets.AAVE_V3,
            AAVE_POOL_ADDRESSES_PROVIDER
        );
        ZeroBalanceFuse uniswapBalanceFuse = new ZeroBalanceFuse(IporFusionMarkets.UNISWAP_SWAP_V3);

        vm.startPrank(FUSE_MANAGER);
        PlasmaVaultGovernance(plasmaVault).addBalanceFuse(IporFusionMarkets.EULER_V2, BALANCE_FUSE_EULERV2);
        PlasmaVaultGovernance(plasmaVault).addBalanceFuse(IporFusionMarkets.AAVE_V3, address(aaveBalanceFuse));
        PlasmaVaultGovernance(plasmaVault).addBalanceFuse(IporFusionMarkets.UNISWAP_SWAP_V3, address(uniswapBalanceFuse));
        vm.stopPrank();
    }

    function _registerCallbackHandler() private {
        CallbackHandlerEuler callbackHandler = new CallbackHandlerEuler();

        vm.startPrank(FUSE_MANAGER);
        PlasmaVaultGovernance(plasmaVault).updateCallbackHandler(
            address(callbackHandler),
            EULER_V2_EVC,
            CallbackHandlerEuler.onEulerFlashLoan.selector
        );
        vm.stopPrank();
    }
}
