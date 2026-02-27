// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PlasmaVault, PlasmaVaultInitData, FuseAction, FeeConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {WETHPriceFeed} from "../../../contracts/price_oracle/price_feed/WETHPriceFeed.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {RoleLib, UsersToRoles} from "../../RoleLib.sol";

import {DolomiteSupplyFuse, DolomiteSupplyFuseEnterData, DolomiteSupplyFuseExitData} from "../../../contracts/fuses/dolomite/DolomiteSupplyFuse.sol";
import {DolomiteBorrowFuse, DolomiteBorrowFuseEnterData, DolomiteBorrowFuseExitData} from "../../../contracts/fuses/dolomite/DolomiteBorrowFuse.sol";
import {DolomiteCollateralFuse, DolomiteCollateralFuseEnterData, DolomiteCollateralFuseExitData} from "../../../contracts/fuses/dolomite/DolomiteCollateralFuse.sol";
import {DolomiteBalanceFuse} from "../../../contracts/fuses/dolomite/DolomiteBalanceFuse.sol";
import {DolomiteFuseLib, DolomiteSubstrate} from "../../../contracts/fuses/dolomite/DolomiteFuseLib.sol";
import {IDolomiteMargin} from "../../../contracts/fuses/dolomite/ext/IDolomiteMargin.sol";

/// @title DolomiteFuseCoverageTest
/// @notice Tests for improving code coverage of Dolomite fuses
contract DolomiteFuseCoverageTest is Test {
    // ============ Arbitrum Addresses ============
    address public constant DOLOMITE_MARGIN = 0x6Bd780E7fDf01D77e4d475c821f1e7AE05409072;
    address public constant DEPOSIT_WITHDRAWAL_ROUTER = 0xf8b2c637A68cF6A17b1DF9F8992EeBeFf63d2dFf;
    address public constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address public constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address public constant CHAINLINK_ETH_USD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address public constant CHAINLINK_USDC_USD = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    address public constant BASE_CURRENCY_PRICE_SOURCE = 0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf;

    uint256 public constant DOLOMITE_MARKET_ID = 46;

    // ============ Contract Instances ============
    address public plasmaVault;
    address public priceOracle;
    address public accessManager;

    DolomiteSupplyFuse public supplyFuse;
    DolomiteBorrowFuse public borrowFuse;
    DolomiteCollateralFuse public collateralFuse;
    DolomiteBalanceFuse public balanceFuse;

    // ============ Test Accounts ============
    address public admin;
    address public alpha;

    bytes32[] internal _currentSubstrates;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 420000000);

        admin = vm.addr(1001);
        alpha = vm.addr(1002);

        _deployFuses();
        _setupPriceOracle();
        _setupAccessManager();
        _deployPlasmaVault();
    }

    // ============================================================================
    // CONSTRUCTOR VALIDATION TESTS
    // ============================================================================

    function test_SupplyFuse_Constructor_InvalidMarketId() public {
        vm.expectRevert(abi.encodeWithSignature("DolomiteSupplyFuseInvalidMarketId()"));
        new DolomiteSupplyFuse(0, DOLOMITE_MARGIN, DEPOSIT_WITHDRAWAL_ROUTER);
    }

    function test_SupplyFuse_Constructor_InvalidDolomiteMargin() public {
        vm.expectRevert(abi.encodeWithSignature("DolomiteSupplyFuseInvalidDolomiteMargin()"));
        new DolomiteSupplyFuse(DOLOMITE_MARKET_ID, address(0), DEPOSIT_WITHDRAWAL_ROUTER);
    }

    function test_SupplyFuse_Constructor_InvalidRouter() public {
        vm.expectRevert(abi.encodeWithSignature("DolomiteSupplyFuseInvalidRouter()"));
        new DolomiteSupplyFuse(DOLOMITE_MARKET_ID, DOLOMITE_MARGIN, address(0));
    }

    function test_BorrowFuse_Constructor_InvalidMarketId() public {
        vm.expectRevert(abi.encodeWithSignature("DolomiteBorrowFuseInvalidMarketId()"));
        new DolomiteBorrowFuse(0, DOLOMITE_MARGIN);
    }

    function test_BorrowFuse_Constructor_InvalidDolomiteMargin() public {
        vm.expectRevert(abi.encodeWithSignature("DolomiteBorrowFuseInvalidDolomiteMargin()"));
        new DolomiteBorrowFuse(DOLOMITE_MARKET_ID, address(0));
    }

    function test_CollateralFuse_Constructor_InvalidMarketId() public {
        vm.expectRevert(abi.encodeWithSignature("DolomiteCollateralFuseInvalidMarketId()"));
        new DolomiteCollateralFuse(0, DOLOMITE_MARGIN);
    }

    function test_CollateralFuse_Constructor_InvalidDolomiteMargin() public {
        vm.expectRevert(abi.encodeWithSignature("DolomiteCollateralFuseInvalidDolomiteMargin()"));
        new DolomiteCollateralFuse(DOLOMITE_MARKET_ID, address(0));
    }

    function test_BalanceFuse_Constructor_InvalidMarketId() public {
        vm.expectRevert(abi.encodeWithSignature("DolomiteBalanceFuseInvalidMarketId()"));
        new DolomiteBalanceFuse(0, DOLOMITE_MARGIN);
    }

    function test_BalanceFuse_Constructor_InvalidDolomiteMargin() public {
        vm.expectRevert(abi.encodeWithSignature("DolomiteBalanceFuseInvalidDolomiteMargin()"));
        new DolomiteBalanceFuse(DOLOMITE_MARKET_ID, address(0));
    }

    // ============================================================================
    // SUPPLY FUSE SLIPPAGE TESTS
    // ============================================================================

    function test_SupplyFuse_Enter_WithMinBalanceIncrease() public {
        uint256 supplyAmount = 1000e6;
        deal(USDC, plasmaVault, supplyAmount);

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(supplyFuse),
            data: abi.encodeCall(
                supplyFuse.enter,
                (
                    DolomiteSupplyFuseEnterData({
                        asset: USDC,
                        amount: supplyAmount,
                        minBalanceIncrease: supplyAmount - 10, // Allow small rounding
                        subAccountId: 0,
                        isolationModeMarketId: 0
                    })
                )
            )
        });

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(actions);
    }

    function test_SupplyFuse_Enter_ZeroAmount_WithMinBalanceIncrease_ShouldRevert() public {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(supplyFuse),
            data: abi.encodeCall(
                supplyFuse.enter,
                (
                    DolomiteSupplyFuseEnterData({
                        asset: USDC,
                        amount: 0,
                        minBalanceIncrease: 100, // Non-zero min with zero amount should revert
                        subAccountId: 0,
                        isolationModeMarketId: 0
                    })
                )
            )
        });

        vm.prank(alpha);
        vm.expectRevert();
        PlasmaVault(plasmaVault).execute(actions);
    }

    function test_SupplyFuse_Exit_WithMinAmountOut() public {
        // First supply
        uint256 supplyAmount = 1000e6;
        deal(USDC, plasmaVault, supplyAmount);
        _supplyToDolomite(USDC, supplyAmount, 0);

        // Withdraw with minAmountOut
        uint256 withdrawAmount = 500e6;
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(supplyFuse),
            data: abi.encodeCall(
                supplyFuse.exit,
                (
                    DolomiteSupplyFuseExitData({
                        asset: USDC,
                        amount: withdrawAmount,
                        minAmountOut: withdrawAmount - 10, // Allow small rounding
                        subAccountId: 0,
                        isolationModeMarketId: 0
                    })
                )
            )
        });

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(actions);
    }

    function test_SupplyFuse_Exit_ZeroAmount_WithMinAmountOut_ShouldRevert() public {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(supplyFuse),
            data: abi.encodeCall(
                supplyFuse.exit,
                (
                    DolomiteSupplyFuseExitData({
                        asset: USDC,
                        amount: 0,
                        minAmountOut: 100, // Non-zero min with zero amount should revert
                        subAccountId: 0,
                        isolationModeMarketId: 0
                    })
                )
            )
        });

        vm.prank(alpha);
        vm.expectRevert();
        PlasmaVault(plasmaVault).execute(actions);
    }

    function test_SupplyFuse_Exit_NoBalance_WithMinAmountOut_ShouldRevert() public {
        // Try to withdraw without any supply, with minAmountOut > 0
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(supplyFuse),
            data: abi.encodeCall(
                supplyFuse.exit,
                (
                    DolomiteSupplyFuseExitData({
                        asset: USDC,
                        amount: 1000e6,
                        minAmountOut: 100,
                        subAccountId: 0,
                        isolationModeMarketId: 0
                    })
                )
            )
        });

        vm.prank(alpha);
        vm.expectRevert();
        PlasmaVault(plasmaVault).execute(actions);
    }

    function test_SupplyFuse_Enter_UnsupportedAsset() public {
        // WETH is not in substrates for supply
        deal(WETH, plasmaVault, 1 ether);

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(supplyFuse),
            data: abi.encodeCall(
                supplyFuse.enter,
                (
                    DolomiteSupplyFuseEnterData({
                        asset: WETH,
                        amount: 1 ether,
                        minBalanceIncrease: 0,
                        subAccountId: 0,
                        isolationModeMarketId: 0
                    })
                )
            )
        });

        vm.prank(alpha);
        vm.expectRevert();
        PlasmaVault(plasmaVault).execute(actions);
    }

    // ============================================================================
    // INSTANT WITHDRAW TESTS
    // ============================================================================

    function test_SupplyFuse_InstantWithdraw() public {
        // First supply some tokens
        uint256 supplyAmount = 1000e6;
        deal(USDC, plasmaVault, supplyAmount);
        _supplyToDolomite(USDC, supplyAmount, 0);

        uint256 balanceBefore = ERC20(USDC).balanceOf(plasmaVault);

        // Use exit with max withdrawal to test full withdrawal path
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(supplyFuse),
            data: abi.encodeCall(
                supplyFuse.exit,
                (
                    DolomiteSupplyFuseExitData({
                        asset: USDC,
                        amount: type(uint256).max, // Full withdrawal
                        minAmountOut: 0,
                        subAccountId: 0,
                        isolationModeMarketId: 0
                    })
                )
            )
        });

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(actions);

        uint256 balanceAfter = ERC20(USDC).balanceOf(plasmaVault);
        assertGt(balanceAfter, balanceBefore, "Should have received tokens");
    }

    function test_SupplyFuse_InstantWithdraw_WithOptionalParams() public {
        uint256 supplyAmount = 1000e6;
        deal(USDC, plasmaVault, supplyAmount);
        _supplyToDolomite(USDC, supplyAmount, 0);

        // Partial withdrawal with slippage protection
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(supplyFuse),
            data: abi.encodeCall(
                supplyFuse.exit,
                (
                    DolomiteSupplyFuseExitData({
                        asset: USDC,
                        amount: 500e6,
                        minAmountOut: 400e6, // With slippage protection
                        subAccountId: 0,
                        isolationModeMarketId: 0
                    })
                )
            )
        });

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(actions);
    }

    // ============================================================================
    // BORROW FUSE TESTS
    // ============================================================================

    function test_BorrowFuse_Enter_WithSlippageProtection() public {
        // Setup: need collateral first
        _grantSubstrate(DOLOMITE_MARKET_ID, WETH, 0, false); // WETH as collateral
        _grantSubstrate(DOLOMITE_MARKET_ID, USDC, 0, true); // USDC can borrow

        deal(WETH, plasmaVault, 2 ether);
        _supplyWETHToDolomite(2 ether, 0);

        // Borrow with minAmountOut
        uint256 borrowAmount = 500e6;
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(borrowFuse),
            data: abi.encodeCall(
                borrowFuse.enter,
                (
                    DolomiteBorrowFuseEnterData({
                        asset: USDC,
                        amount: borrowAmount,
                        minAmountOut: borrowAmount - 10, // Allow small variance
                        subAccountId: 0
                    })
                )
            )
        });

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(actions);
    }

    function test_BorrowFuse_Enter_ZeroAmount() public {
        _grantSubstrate(DOLOMITE_MARKET_ID, USDC, 0, true);

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(borrowFuse),
            data: abi.encodeCall(
                borrowFuse.enter,
                (DolomiteBorrowFuseEnterData({asset: USDC, amount: 0, minAmountOut: 0, subAccountId: 0}))
            )
        });

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(actions);
    }

    function test_BorrowFuse_Exit_NoDebt_ShouldRevert() public {
        _grantSubstrate(DOLOMITE_MARKET_ID, USDC, 0, true);

        // Try to repay without any debt
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(borrowFuse),
            data: abi.encodeCall(
                borrowFuse.exit,
                (DolomiteBorrowFuseExitData({asset: USDC, amount: 100e6, minDebtReduction: 0, subAccountId: 0}))
            )
        });

        vm.prank(alpha);
        vm.expectRevert();
        PlasmaVault(plasmaVault).execute(actions);
    }

    function test_BorrowFuse_Exit_ZeroAmount() public {
        _grantSubstrate(DOLOMITE_MARKET_ID, USDC, 0, true);

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(borrowFuse),
            data: abi.encodeCall(
                borrowFuse.exit,
                (DolomiteBorrowFuseExitData({asset: USDC, amount: 0, minDebtReduction: 0, subAccountId: 0}))
            )
        });

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(actions);
    }

    function test_BorrowFuse_Exit_WithMinDebtReduction() public {
        // Setup collateral and borrow
        _grantSubstrate(DOLOMITE_MARKET_ID, WETH, 0, false);
        _grantSubstrate(DOLOMITE_MARKET_ID, USDC, 0, true);

        deal(WETH, plasmaVault, 2 ether);
        _supplyWETHToDolomite(2 ether, 0);
        _borrowFromDolomite(USDC, 500e6, 0);

        // Repay with minDebtReduction
        deal(USDC, plasmaVault, 300e6);

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(borrowFuse),
            data: abi.encodeCall(
                borrowFuse.exit,
                (
                    DolomiteBorrowFuseExitData({
                        asset: USDC,
                        amount: 200e6,
                        minDebtReduction: 190e6, // Allow some variance
                        subAccountId: 0
                    })
                )
            )
        });

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(actions);
    }

    function test_BorrowFuse_GetBorrowBalance() public {
        // Setup and borrow
        _grantSubstrate(DOLOMITE_MARKET_ID, WETH, 0, false);
        _grantSubstrate(DOLOMITE_MARKET_ID, USDC, 0, true);

        deal(WETH, plasmaVault, 2 ether);
        _supplyWETHToDolomite(2 ether, 0);
        _borrowFromDolomite(USDC, 500e6, 0);

        // Check borrow balance directly via Dolomite
        IDolomiteMargin.Wei memory balance = _getDolomiteBalance(USDC, 0);

        // Debt is negative balance
        assertFalse(balance.sign, "Should have debt (negative balance)");
        assertGt(balance.value, 0, "Debt value should be positive");
    }

    function test_BorrowFuse_GetBorrowBalance_NoDebt() public {
        vm.prank(plasmaVault);
        (bool success, bytes memory result) = address(borrowFuse).staticcall(
            abi.encodeCall(borrowFuse.getBorrowBalance, (USDC, 0))
        );

        assertTrue(success, "getBorrowBalance should succeed");
        uint256 debt = abi.decode(result, (uint256));
        assertEq(debt, 0, "Should have no debt");
    }

    // ============================================================================
    // COLLATERAL FUSE TESTS
    // ============================================================================

    function test_CollateralFuse_Enter_ZeroAmount() public {
        _grantSubstrate(DOLOMITE_MARKET_ID, USDC, 0, false);
        _grantSubstrate(DOLOMITE_MARKET_ID, USDC, 1, false);

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(collateralFuse),
            data: abi.encodeCall(
                collateralFuse.enter,
                (
                    DolomiteCollateralFuseEnterData({
                        asset: USDC,
                        amount: 0,
                        minSharesOut: 0,
                        fromSubAccountId: 0,
                        toSubAccountId: 1
                    })
                )
            )
        });

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(actions);
    }

    function test_CollateralFuse_Enter_WithSlippage() public {
        _grantSubstrate(DOLOMITE_MARKET_ID, USDC, 0, false);
        _grantSubstrate(DOLOMITE_MARKET_ID, USDC, 1, false);

        // Supply first
        deal(USDC, plasmaVault, 1000e6);
        _supplyToDolomite(USDC, 1000e6, 0);

        // Transfer with minSharesOut
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(collateralFuse),
            data: abi.encodeCall(
                collateralFuse.enter,
                (
                    DolomiteCollateralFuseEnterData({
                        asset: USDC,
                        amount: 500e6,
                        minSharesOut: 490e6, // Allow some variance
                        fromSubAccountId: 0,
                        toSubAccountId: 1
                    })
                )
            )
        });

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(actions);
    }

    function test_CollateralFuse_Enter_InsufficientBalance() public {
        _grantSubstrate(DOLOMITE_MARKET_ID, USDC, 0, false);
        _grantSubstrate(DOLOMITE_MARKET_ID, USDC, 1, false);

        // Try to transfer without any balance
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(collateralFuse),
            data: abi.encodeCall(
                collateralFuse.enter,
                (
                    DolomiteCollateralFuseEnterData({
                        asset: USDC,
                        amount: 1000e6,
                        minSharesOut: 0,
                        fromSubAccountId: 0,
                        toSubAccountId: 1
                    })
                )
            )
        });

        vm.prank(alpha);
        vm.expectRevert();
        PlasmaVault(plasmaVault).execute(actions);
    }

    function test_CollateralFuse_Exit_ZeroAmount() public {
        _grantSubstrate(DOLOMITE_MARKET_ID, USDC, 0, false);
        _grantSubstrate(DOLOMITE_MARKET_ID, USDC, 1, false);

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(collateralFuse),
            data: abi.encodeCall(
                collateralFuse.exit,
                (
                    DolomiteCollateralFuseExitData({
                        asset: USDC,
                        amount: 0,
                        minCollateralOut: 0,
                        fromSubAccountId: 1,
                        toSubAccountId: 0
                    })
                )
            )
        });

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(actions);
    }

    function test_CollateralFuse_Exit_NoBalance() public {
        _grantSubstrate(DOLOMITE_MARKET_ID, USDC, 0, false);
        _grantSubstrate(DOLOMITE_MARKET_ID, USDC, 1, false);

        // Exit with no balance should return (asset, 0)
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(collateralFuse),
            data: abi.encodeCall(
                collateralFuse.exit,
                (
                    DolomiteCollateralFuseExitData({
                        asset: USDC,
                        amount: 1000e6,
                        minCollateralOut: 0,
                        fromSubAccountId: 1,
                        toSubAccountId: 0
                    })
                )
            )
        });

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(actions);
    }

    function test_CollateralFuse_Exit_WithSlippage() public {
        _grantSubstrate(DOLOMITE_MARKET_ID, USDC, 0, false);
        _grantSubstrate(DOLOMITE_MARKET_ID, USDC, 1, false);

        // Supply and transfer to sub-account 1
        deal(USDC, plasmaVault, 1000e6);
        _supplyToDolomite(USDC, 1000e6, 0);
        _transferCollateral(USDC, 500e6, 0, 1);

        // Return with minCollateralOut
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(collateralFuse),
            data: abi.encodeCall(
                collateralFuse.exit,
                (
                    DolomiteCollateralFuseExitData({
                        asset: USDC,
                        amount: 300e6,
                        minCollateralOut: 290e6,
                        fromSubAccountId: 1,
                        toSubAccountId: 0
                    })
                )
            )
        });

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(actions);
    }

    function test_CollateralFuse_GetCollateralBalance() public {
        // Supply first
        deal(USDC, plasmaVault, 1000e6);
        _supplyToDolomite(USDC, 1000e6, 0);

        // Check balance directly via Dolomite
        IDolomiteMargin.Wei memory balance = _getDolomiteBalance(USDC, 0);

        assertTrue(balance.sign, "Should have positive balance (collateral)");
        assertGt(balance.value, 0, "Collateral value should be positive");
    }

    function test_CollateralFuse_GetCollateralBalance_NoBalance() public {
        vm.prank(plasmaVault);
        (bool success, bytes memory result) = address(collateralFuse).staticcall(
            abi.encodeCall(collateralFuse.getCollateralBalance, (USDC, 0))
        );

        assertTrue(success, "getCollateralBalance should succeed");
        uint256 balance = abi.decode(result, (uint256));
        assertEq(balance, 0, "Should have no collateral");
    }

    // ============================================================================
    // FUSE LIB TESTS
    // ============================================================================

    function test_FuseLib_SubstrateEncoding() public {
        DolomiteSubstrate memory original = DolomiteSubstrate({
            asset: 0xaf88d065e77c8cC2239327C5EDb3A432268e5831,
            subAccountId: 5,
            canBorrow: true
        });

        bytes32 encoded = DolomiteFuseLib.substrateToBytes32(original);
        DolomiteSubstrate memory decoded = DolomiteFuseLib.bytes32ToSubstrate(encoded);

        assertEq(decoded.asset, original.asset, "Asset should match");
        assertEq(decoded.subAccountId, original.subAccountId, "SubAccountId should match");
        assertEq(decoded.canBorrow, original.canBorrow, "CanBorrow should match");
    }

    function test_FuseLib_SubstrateEncoding_NoBorrow() public {
        DolomiteSubstrate memory original = DolomiteSubstrate({
            asset: 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1,
            subAccountId: 0,
            canBorrow: false
        });

        bytes32 encoded = DolomiteFuseLib.substrateToBytes32(original);
        DolomiteSubstrate memory decoded = DolomiteFuseLib.bytes32ToSubstrate(encoded);

        assertEq(decoded.asset, original.asset, "Asset should match");
        assertEq(decoded.subAccountId, original.subAccountId, "SubAccountId should match");
        assertEq(decoded.canBorrow, original.canBorrow, "CanBorrow should match");
    }

    // ============================================================================
    // DEPLOYMENT HELPERS
    // ============================================================================

    function _deployFuses() internal {
        supplyFuse = new DolomiteSupplyFuse(DOLOMITE_MARKET_ID, DOLOMITE_MARGIN, DEPOSIT_WITHDRAWAL_ROUTER);
        borrowFuse = new DolomiteBorrowFuse(DOLOMITE_MARKET_ID, DOLOMITE_MARGIN);
        collateralFuse = new DolomiteCollateralFuse(DOLOMITE_MARKET_ID, DOLOMITE_MARGIN);
        balanceFuse = new DolomiteBalanceFuse(DOLOMITE_MARKET_ID, DOLOMITE_MARGIN);
    }

    function _setupPriceOracle() internal {
        vm.startPrank(admin);

        PriceOracleMiddleware implementation = new PriceOracleMiddleware(BASE_CURRENCY_PRICE_SOURCE);
        priceOracle = address(
            new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", admin))
        );

        address[] memory assets = new address[](2);
        address[] memory sources = new address[](2);

        assets[0] = USDC;
        sources[0] = CHAINLINK_USDC_USD;

        assets[1] = WETH;
        sources[1] = address(new WETHPriceFeed(CHAINLINK_ETH_USD));

        PriceOracleMiddleware(priceOracle).setAssetsPricesSources(assets, sources);

        vm.stopPrank();
    }

    function _setupAccessManager() internal {
        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = admin;
        usersToRoles.atomist = admin;

        address[] memory alphas = new address[](1);
        alphas[0] = alpha;
        usersToRoles.alphas = alphas;

        accessManager = address(RoleLib.createAccessManager(usersToRoles, 0, vm));
    }

    function _deployPlasmaVault() internal {
        vm.startPrank(admin);

        address withdrawManager = address(new WithdrawManager(accessManager));

        FeeConfig memory feeConfig = FeeConfigHelper.createZeroFeeConfig();

        plasmaVault = address(new PlasmaVault());
        PlasmaVault(plasmaVault).proxyInitialize(
            PlasmaVaultInitData({
                assetName: "Dolomite Coverage Test Vault",
                assetSymbol: "DCTVault",
                underlyingToken: USDC,
                priceOracleMiddleware: priceOracle,
                feeConfig: feeConfig,
                accessManager: accessManager,
                plasmaVaultBase: address(new PlasmaVaultBase()),
                withdrawManager: withdrawManager,
                plasmaVaultVotesPlugin: address(0)
            })
        );

        vm.stopPrank();

        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = admin;
        usersToRoles.atomist = admin;
        RoleLib.setupPlasmaVaultRoles(
            usersToRoles,
            vm,
            plasmaVault,
            IporFusionAccessManager(accessManager),
            withdrawManager
        );

        vm.startPrank(admin);

        address[] memory fusesToAdd = new address[](3);
        fusesToAdd[0] = address(supplyFuse);
        fusesToAdd[1] = address(borrowFuse);
        fusesToAdd[2] = address(collateralFuse);
        PlasmaVaultGovernance(plasmaVault).addFuses(fusesToAdd);

        PlasmaVaultGovernance(plasmaVault).addBalanceFuse(DOLOMITE_MARKET_ID, address(balanceFuse));

        // Initial substrates: USDC only
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = DolomiteFuseLib.substrateToBytes32(
            DolomiteSubstrate({asset: USDC, subAccountId: 0, canBorrow: false})
        );
        PlasmaVaultGovernance(plasmaVault).grantMarketSubstrates(DOLOMITE_MARKET_ID, substrates);

        _currentSubstrates = substrates;

        vm.stopPrank();
    }

    function _grantSubstrate(uint256 marketId_, address asset_, uint8 subAccountId_, bool canBorrow_) internal {
        bytes32 newSubstrate = DolomiteFuseLib.substrateToBytes32(
            DolomiteSubstrate({asset: asset_, subAccountId: subAccountId_, canBorrow: canBorrow_})
        );

        bool found = false;
        for (uint256 i = 0; i < _currentSubstrates.length; i++) {
            DolomiteSubstrate memory existing = DolomiteFuseLib.bytes32ToSubstrate(_currentSubstrates[i]);
            if (existing.asset == asset_ && existing.subAccountId == subAccountId_) {
                _currentSubstrates[i] = newSubstrate;
                found = true;
                break;
            }
        }

        if (!found) {
            bytes32[] memory newArray = new bytes32[](_currentSubstrates.length + 1);
            for (uint256 i = 0; i < _currentSubstrates.length; i++) {
                newArray[i] = _currentSubstrates[i];
            }
            newArray[_currentSubstrates.length] = newSubstrate;
            _currentSubstrates = newArray;
        }

        vm.prank(admin);
        PlasmaVaultGovernance(plasmaVault).grantMarketSubstrates(marketId_, _currentSubstrates);
    }

    function _supplyToDolomite(address asset_, uint256 amount_, uint8 subAccountId_) internal {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(supplyFuse),
            data: abi.encodeCall(
                supplyFuse.enter,
                (
                    DolomiteSupplyFuseEnterData({
                        asset: asset_,
                        amount: amount_,
                        minBalanceIncrease: 0,
                        subAccountId: subAccountId_,
                        isolationModeMarketId: 0
                    })
                )
            )
        });

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(actions);
    }

    function _supplyWETHToDolomite(uint256 amount_, uint8 subAccountId_) internal {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(supplyFuse),
            data: abi.encodeCall(
                supplyFuse.enter,
                (
                    DolomiteSupplyFuseEnterData({
                        asset: WETH,
                        amount: amount_,
                        minBalanceIncrease: 0,
                        subAccountId: subAccountId_,
                        isolationModeMarketId: 0
                    })
                )
            )
        });

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(actions);
    }

    function _borrowFromDolomite(address asset_, uint256 amount_, uint8 subAccountId_) internal {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(borrowFuse),
            data: abi.encodeCall(
                borrowFuse.enter,
                (
                    DolomiteBorrowFuseEnterData({
                        asset: asset_,
                        amount: amount_,
                        minAmountOut: 0,
                        subAccountId: subAccountId_
                    })
                )
            )
        });

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(actions);
    }

    function _transferCollateral(
        address asset_,
        uint256 amount_,
        uint8 fromSubAccountId_,
        uint8 toSubAccountId_
    ) internal {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(collateralFuse),
            data: abi.encodeCall(
                collateralFuse.enter,
                (
                    DolomiteCollateralFuseEnterData({
                        asset: asset_,
                        amount: amount_,
                        minSharesOut: 0,
                        fromSubAccountId: fromSubAccountId_,
                        toSubAccountId: toSubAccountId_
                    })
                )
            )
        });

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(actions);
    }

    function _getDolomiteBalance(
        address asset_,
        uint256 accountNumber_
    ) internal view returns (IDolomiteMargin.Wei memory) {
        uint256 dolomiteMarketId = IDolomiteMargin(DOLOMITE_MARGIN).getMarketIdByTokenAddress(asset_);
        return
            IDolomiteMargin(DOLOMITE_MARGIN).getAccountWei(
                IDolomiteMargin.AccountInfo({owner: plasmaVault, number: accountNumber_}),
                dolomiteMarketId
            );
    }

    receive() external payable {}
}
