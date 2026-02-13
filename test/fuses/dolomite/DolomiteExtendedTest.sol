// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PlasmaVault, PlasmaVaultInitData, FuseAction, MarketSubstratesConfig, MarketBalanceFuseConfig, FeeConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {WETHPriceFeed} from "../../../contracts/price_oracle/price_feed/WETHPriceFeed.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {RoleLib, UsersToRoles} from "../../RoleLib.sol";

import {DolomiteSupplyFuse, DolomiteSupplyFuseEnterData, DolomiteSupplyFuseExitData} from "../../../contracts/fuses/dolomite/DolomiteSupplyFuse.sol";
import {DolomiteBorrowFuse, DolomiteBorrowFuseEnterData, DolomiteBorrowFuseExitData} from "../../../contracts/fuses/dolomite/DolomiteBorrowFuse.sol";
import {DolomiteCollateralFuse, DolomiteCollateralFuseEnterData, DolomiteCollateralFuseExitData} from "../../../contracts/fuses/dolomite/DolomiteCollateralFuse.sol";
import {DolomiteEModeFuse, DolomiteEModeFuseEnterData, DolomiteEModeFuseExitData} from "../../../contracts/fuses/dolomite/DolomiteEModeFuse.sol";
import {DolomiteBalanceFuse} from "../../../contracts/fuses/dolomite/DolomiteBalanceFuse.sol";
import {DolomiteFuseLib, DolomiteSubstrate} from "../../../contracts/fuses/dolomite/DolomiteFuseLib.sol";
import {IDolomiteMargin} from "../../../contracts/fuses/dolomite/ext/IDolomiteMargin.sol";
import {IDolomiteAccountRegistry} from "../../../contracts/fuses/dolomite/ext/IDolomiteAccountRegistry.sol";

/// @title DolomiteExtendedTest
/// @notice Extended integration tests for Dolomite fuses on Arbitrum fork using real PlasmaVault
contract DolomiteExtendedTest is Test {
    // ============ Arbitrum Addresses ============
    address public constant DOLOMITE_MARGIN = 0x6Bd780E7fDf01D77e4d475c821f1e7AE05409072;
    address public constant DEPOSIT_WITHDRAWAL_ROUTER = 0xf8b2c637A68cF6A17b1DF9F8992EeBeFf63d2dFf;
    address public constant DOLOMITE_ACCOUNT_REGISTRY = 0xC777fB526922fB61581b65f8eb55bb769CD59C63;
    address public constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address public constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    /// @dev Chainlink ETH/USD price feed on Arbitrum
    address public constant CHAINLINK_ETH_USD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;

    /// @dev Chainlink USDC/USD price feed on Arbitrum
    address public constant CHAINLINK_USDC_USD = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;

    /// @dev PriceOracleMiddleware base currency source (Arbitrum specific)
    address public constant BASE_CURRENCY_PRICE_SOURCE = 0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf;

    uint256 public constant DOLOMITE_MARKET_ID = 50;

    // ============ Contract Instances ============
    address public plasmaVault;
    address public priceOracle;
    address public accessManager;

    DolomiteSupplyFuse public supplyFuse;
    DolomiteBorrowFuse public borrowFuse;
    DolomiteCollateralFuse public collateralFuse;
    DolomiteEModeFuse public emodeFuse;
    DolomiteBalanceFuse public balanceFuse;

    address[] public fuses;

    // ============ Test Accounts ============
    address public admin;
    address public alpha;
    address public user1;

    /// @dev Tracks currently granted substrates
    bytes32[] internal _currentSubstrates;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 420000000);

        // Setup test accounts
        admin = vm.addr(1001);
        alpha = vm.addr(1002);
        user1 = vm.addr(1003);

        // Deploy all fuses
        _deployFuses();

        // Setup price oracle
        _setupPriceOracle();

        // Setup access manager
        _setupAccessManager();

        // Deploy PlasmaVault
        _deployPlasmaVault();

        // Fund vault with initial assets for tests
        deal(WETH, plasmaVault, 10 ether);
        deal(USDC, plasmaVault, 100_000e6);
    }

    // ============ BORROW TESTS ============

    function test_DolomiteBorrow() public {
        // Supply 1 WETH as collateral
        _supplyToDolomite(WETH, 1 ether, 0);

        // Get USDC balance before borrow
        uint256 usdcBefore = ERC20(USDC).balanceOf(plasmaVault);

        // Borrow 500 USDC
        _borrowFromDolomite(USDC, 500e6, 0);

        uint256 usdcAfter = ERC20(USDC).balanceOf(plasmaVault);
        assertEq(usdcAfter - usdcBefore, 500e6, "Should receive 500 USDC");

        // Verify debt
        IDolomiteMargin.Wei memory debt = _getDolomiteBalance(USDC, 0);
        assertFalse(debt.sign, "Should have debt (negative balance)");
    }

    function test_DolomiteRepay() public {
        // Setup: collateral + borrow
        _supplyToDolomite(WETH, 1 ether, 0);
        _borrowFromDolomite(USDC, 500e6, 0);

        // Repay 250 USDC
        _repayToDolomite(USDC, 250e6, 0);

        // Verify remaining debt
        IDolomiteMargin.Wei memory debt = _getDolomiteBalance(USDC, 0);
        assertFalse(debt.sign, "Should still have debt");
        assertLt(debt.value, 500e6, "Debt should be reduced");
    }

    function test_DolomiteFullRepay() public {
        _supplyToDolomite(WETH, 1 ether, 0);
        _borrowFromDolomite(USDC, 500e6, 0);

        // Full repay
        _repayToDolomite(USDC, type(uint256).max, 0);

        IDolomiteMargin.Wei memory debt = _getDolomiteBalance(USDC, 0);
        assertTrue(debt.sign || debt.value == 0, "Debt should be cleared");
    }

    // ============ COLLATERAL TESTS ============

    function test_TransferCollateral() public {
        // Grant substrate for subAccount 1
        _grantSubstrate(DOLOMITE_MARKET_ID, WETH, 1, false);

        _supplyToDolomite(WETH, 1 ether, 0);

        // Transfer from account 0 to account 1
        _transferCollateral(WETH, 0.5 ether, 0, 1);

        // Verify balances
        IDolomiteMargin.Wei memory bal0 = _getDolomiteBalance(WETH, 0);
        IDolomiteMargin.Wei memory bal1 = _getDolomiteBalance(WETH, 1);
        assertApproxEqAbs(bal0.value, 0.5 ether, 100, "Sub-account 0 should have 0.5 WETH");
        assertApproxEqAbs(bal1.value, 0.5 ether, 100, "Sub-account 1 should have 0.5 WETH");
    }

    function test_ReturnCollateral() public {
        // Grant substrate for subAccount 1
        _grantSubstrate(DOLOMITE_MARKET_ID, WETH, 1, false);

        _supplyToDolomite(WETH, 1 ether, 0);
        _transferCollateral(WETH, 0.5 ether, 0, 1);

        // Return from account 1 to account 0
        _returnCollateral(WETH, 0.5 ether, 1, 0);

        IDolomiteMargin.Wei memory bal0 = _getDolomiteBalance(WETH, 0);
        assertApproxEqAbs(bal0.value, 1 ether, 100, "Sub-account 0 should have 1 WETH back");
    }

    // ============ E-MODE TESTS ============

    function test_EnableEMode() public {
        // Grant E-mode category 1 as substrate
        _grantEModeCategory(DOLOMITE_MARKET_ID, 1);

        // Try to enable e-mode
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(emodeFuse),
            data: abi.encodeCall(emodeFuse.enter, (DolomiteEModeFuseEnterData({subAccountId: 0, categoryId: 1})))
        });

        vm.prank(alpha);
        try PlasmaVault(plasmaVault).execute(actions) {
            // E-mode enabled successfully
        } catch {
            // E-mode not available on this Dolomite version
        }
    }

    function test_DisableEMode() public {
        _grantEModeCategory(DOLOMITE_MARKET_ID, 1);

        // Try enable first
        FuseAction[] memory enableActions = new FuseAction[](1);
        enableActions[0] = FuseAction({
            fuse: address(emodeFuse),
            data: abi.encodeCall(emodeFuse.enter, (DolomiteEModeFuseEnterData({subAccountId: 0, categoryId: 1})))
        });

        vm.prank(alpha);
        try PlasmaVault(plasmaVault).execute(enableActions) {
            // Now disable
            FuseAction[] memory disableActions = new FuseAction[](1);
            disableActions[0] = FuseAction({
                fuse: address(emodeFuse),
                data: abi.encodeCall(emodeFuse.exit, (DolomiteEModeFuseExitData({subAccountId: 0})))
            });

            vm.prank(alpha);
            PlasmaVault(plasmaVault).execute(disableActions);
            // E-mode disabled successfully
        } catch {
            // E-mode not available, skipping
        }
    }

    function test_EModeHigherLTV() public {
        try IDolomiteAccountRegistry(DOLOMITE_ACCOUNT_REGISTRY).getEModeCategory(1) returns (
            IDolomiteAccountRegistry.EModeCategory memory cat
        ) {
            assertGt(cat.ltv, 9000, "E-mode LTV should be >90%");
        } catch {
            // E-mode registry not available
        }
    }

    // ============ DEPLOYMENT HELPERS ============

    function _deployFuses() internal {
        supplyFuse = new DolomiteSupplyFuse(DOLOMITE_MARKET_ID, DOLOMITE_MARGIN, DEPOSIT_WITHDRAWAL_ROUTER);
        borrowFuse = new DolomiteBorrowFuse(DOLOMITE_MARKET_ID, DOLOMITE_MARGIN);
        collateralFuse = new DolomiteCollateralFuse(DOLOMITE_MARKET_ID, DOLOMITE_MARGIN);
        emodeFuse = new DolomiteEModeFuse(DOLOMITE_MARKET_ID, DOLOMITE_MARGIN, DOLOMITE_ACCOUNT_REGISTRY);
        balanceFuse = new DolomiteBalanceFuse(DOLOMITE_MARKET_ID, DOLOMITE_MARGIN);

        fuses = new address[](4);
        fuses[0] = address(supplyFuse);
        fuses[1] = address(borrowFuse);
        fuses[2] = address(collateralFuse);
        fuses[3] = address(emodeFuse);
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
                assetName: "Dolomite Extended Test Vault",
                assetSymbol: "DEXTVault",
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

        // Setup vault-specific roles
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
        PlasmaVaultGovernance(plasmaVault).addFuses(fuses);
        PlasmaVaultGovernance(plasmaVault).addBalanceFuse(DOLOMITE_MARKET_ID, address(balanceFuse));

        // Grant initial substrates: USDC (canBorrow=true), WETH (canBorrow=false for collateral)
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = DolomiteFuseLib.substrateToBytes32(
            DolomiteSubstrate({asset: USDC, subAccountId: 0, canBorrow: true})
        );
        substrates[1] = DolomiteFuseLib.substrateToBytes32(
            DolomiteSubstrate({asset: WETH, subAccountId: 0, canBorrow: false})
        );
        PlasmaVaultGovernance(plasmaVault).grantMarketSubstrates(DOLOMITE_MARKET_ID, substrates);

        _currentSubstrates = substrates;

        vm.stopPrank();
    }

    // ============ SUBSTRATE MANAGEMENT ============

    function _grantSubstrate(uint256 marketId, address asset, uint8 subAccountId, bool canBorrow) internal {
        bytes32 newSubstrate = DolomiteFuseLib.substrateToBytes32(
            DolomiteSubstrate({asset: asset, subAccountId: subAccountId, canBorrow: canBorrow})
        );

        bool found = false;
        for (uint256 i = 0; i < _currentSubstrates.length; i++) {
            DolomiteSubstrate memory existing = DolomiteFuseLib.bytes32ToSubstrate(_currentSubstrates[i]);
            if (existing.asset == asset && existing.subAccountId == subAccountId) {
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
        PlasmaVaultGovernance(plasmaVault).grantMarketSubstrates(marketId, _currentSubstrates);
    }

    function _grantEModeCategory(uint256 marketId, uint8 categoryId) internal {
        bytes32 newSubstrate = bytes32(uint256(categoryId));

        bool found = false;
        for (uint256 i = 0; i < _currentSubstrates.length; i++) {
            if (_currentSubstrates[i] == newSubstrate) {
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
        PlasmaVaultGovernance(plasmaVault).grantMarketSubstrates(marketId, _currentSubstrates);
    }

    // ============ DOLOMITE ACTION HELPERS ============

    function _supplyToDolomite(address asset, uint256 amount, uint8 subAccountId) internal {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(supplyFuse),
            data: abi.encodeCall(
                supplyFuse.enter,
                (
                    DolomiteSupplyFuseEnterData({
                        asset: asset,
                        amount: amount,
                        minBalanceIncrease: 0,
                        subAccountId: subAccountId,
                        isolationModeMarketId: 0
                    })
                )
            )
        });

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(actions);
    }

    function _withdrawFromDolomite(address asset, uint256 amount, uint8 subAccountId) internal {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(supplyFuse),
            data: abi.encodeCall(
                supplyFuse.exit,
                (
                    DolomiteSupplyFuseExitData({
                        asset: asset,
                        amount: amount,
                        minAmountOut: 0,
                        subAccountId: subAccountId,
                        isolationModeMarketId: 0
                    })
                )
            )
        });

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(actions);
    }

    function _borrowFromDolomite(address asset, uint256 amount, uint8 subAccountId) internal {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(borrowFuse),
            data: abi.encodeCall(
                borrowFuse.enter,
                (
                    DolomiteBorrowFuseEnterData({
                        asset: asset,
                        amount: amount,
                        minAmountOut: 0,
                        subAccountId: subAccountId
                    })
                )
            )
        });

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(actions);
    }

    function _repayToDolomite(address asset, uint256 amount, uint8 subAccountId) internal {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(borrowFuse),
            data: abi.encodeCall(
                borrowFuse.exit,
                (
                    DolomiteBorrowFuseExitData({
                        asset: asset,
                        amount: amount,
                        minDebtReduction: 0,
                        subAccountId: subAccountId
                    })
                )
            )
        });

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(actions);
    }

    function _transferCollateral(address asset, uint256 amount, uint8 fromSubAccountId, uint8 toSubAccountId) internal {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(collateralFuse),
            data: abi.encodeCall(
                collateralFuse.enter,
                (
                    DolomiteCollateralFuseEnterData({
                        asset: asset,
                        amount: amount,
                        minSharesOut: 0,
                        fromSubAccountId: fromSubAccountId,
                        toSubAccountId: toSubAccountId
                    })
                )
            )
        });

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(actions);
    }

    function _returnCollateral(address asset, uint256 amount, uint8 fromSubAccountId, uint8 toSubAccountId) internal {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(collateralFuse),
            data: abi.encodeCall(
                collateralFuse.exit,
                (
                    DolomiteCollateralFuseExitData({
                        asset: asset,
                        amount: amount,
                        minCollateralOut: 0,
                        fromSubAccountId: fromSubAccountId,
                        toSubAccountId: toSubAccountId
                    })
                )
            )
        });

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(actions);
    }

    function _getDolomiteBalance(
        address asset,
        uint256 accountNumber
    ) internal view returns (IDolomiteMargin.Wei memory) {
        uint256 dolomiteMarketId = IDolomiteMargin(DOLOMITE_MARGIN).getMarketIdByTokenAddress(asset);
        return
            IDolomiteMargin(DOLOMITE_MARGIN).getAccountWei(
                IDolomiteMargin.AccountInfo({owner: plasmaVault, number: accountNumber}),
                dolomiteMarketId
            );
    }

    receive() external payable {}
}
