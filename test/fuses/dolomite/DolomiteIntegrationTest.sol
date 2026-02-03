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
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {RoleLib, UsersToRoles} from "../../RoleLib.sol";

import {DolomiteSupplyFuse, DolomiteSupplyFuseEnterData, DolomiteSupplyFuseExitData} from "../../../contracts/fuses/dolomite/DolomiteSupplyFuse.sol";
import {DolomiteBalanceFuse} from "../../../contracts/fuses/dolomite/DolomiteBalanceFuse.sol";
import {DolomiteFuseLib, DolomiteSubstrate} from "../../../contracts/fuses/dolomite/DolomiteFuseLib.sol";
import {IDolomiteMargin} from "../../../contracts/fuses/dolomite/ext/IDolomiteMargin.sol";

/// @title DolomiteIntegrationTest
/// @notice Integration tests for Dolomite fuses on Arbitrum fork using real PlasmaVault
/// @dev Uses real Dolomite contracts on Arbitrum mainnet fork
contract DolomiteIntegrationTest is Test {
    // ============ Arbitrum Addresses ============

    /// @dev Dolomite Margin main contract on Arbitrum
    address public constant DOLOMITE_MARGIN = 0x6Bd780E7fDf01D77e4d475c821f1e7AE05409072;

    /// @dev Dolomite DepositWithdrawalRouter on Arbitrum (new v2)
    address public constant DEPOSIT_WITHDRAWAL_ROUTER = 0xf8b2c637A68cF6A17b1DF9F8992EeBeFf63d2dFf;

    /// @dev Native USDC on Arbitrum
    address public constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    /// @dev WETH on Arbitrum
    address public constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    /// @dev Chainlink ETH/USD price feed on Arbitrum
    address public constant CHAINLINK_ETH_USD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;

    /// @dev Chainlink USDC/USD price feed on Arbitrum
    address public constant CHAINLINK_USDC_USD = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;

    /// @dev PriceOracleMiddleware base currency source (Arbitrum specific)
    address public constant BASE_CURRENCY_PRICE_SOURCE = 0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf;

    // ============ Market ID for tests ============
    uint256 public constant DOLOMITE_MARKET_ID = 50;

    // ============ Contract Instances ============
    address public plasmaVault;
    address public priceOracle;
    address public accessManager;

    DolomiteSupplyFuse public supplyFuse;
    DolomiteBalanceFuse public balanceFuse;

    // ============ Test Accounts ============
    address public admin;
    address public alpha;
    address public user1;

    /// @dev Tracks currently granted substrates
    bytes32[] internal _currentSubstrates;

    function setUp() public {
        // Fork Arbitrum at recent block (must be after DepositWithdrawalRouter v2 deployment)
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 420000000);

        // Setup test accounts
        admin = vm.addr(1001);
        alpha = vm.addr(1002);
        user1 = vm.addr(1003);

        // Deploy fuses
        _deployFuses();

        // Setup price oracle
        _setupPriceOracle();

        // Setup access manager
        _setupAccessManager();

        // Deploy PlasmaVault
        _deployPlasmaVault();
    }

    // ============ Supply Tests ============

    function test_DolomiteSupply() public {
        uint256 supplyAmount = 1000e6; // 1000 USDC (6 decimals)

        // Deal USDC to PlasmaVault
        deal(USDC, plasmaVault, supplyAmount);

        uint256 balanceBefore = ERC20(USDC).balanceOf(plasmaVault);

        // Get Dolomite market ID for USDC
        uint256 dolomiteMarketId = IDolomiteMargin(DOLOMITE_MARGIN).getMarketIdByTokenAddress(USDC);

        // Execute supply via PlasmaVault.execute()
        _supplyToDolomite(USDC, supplyAmount, 0);

        uint256 balanceAfter = ERC20(USDC).balanceOf(plasmaVault);

        assertEq(balanceBefore - balanceAfter, supplyAmount, "Should have supplied full amount");

        // Verify balance in Dolomite
        IDolomiteMargin.Wei memory dolomiteBalance = _getDolomiteBalance(USDC, 0);

        assertTrue(dolomiteBalance.sign, "Balance should be positive (supply)");
        // Allow for small rounding errors (1 wei per 1e9)
        assertGe(
            dolomiteBalance.value + 10,
            supplyAmount,
            "Dolomite balance should be ~= supply amount (allowing rounding)"
        );
    }

    function test_DolomiteWithdraw() public {
        // First supply some tokens
        uint256 supplyAmount = 2000e6; // 2000 USDC
        deal(USDC, plasmaVault, supplyAmount);

        // Supply via PlasmaVault.execute()
        _supplyToDolomite(USDC, supplyAmount, 0);

        // Now withdraw half using exit()
        uint256 withdrawAmount = 1000e6;

        uint256 balanceBeforeWithdraw = ERC20(USDC).balanceOf(plasmaVault);

        _withdrawFromDolomite(USDC, withdrawAmount, 0);

        uint256 balanceAfterWithdraw = ERC20(USDC).balanceOf(plasmaVault);

        assertEq(balanceAfterWithdraw - balanceBeforeWithdraw, withdrawAmount, "Should have received withdrawn amount");
    }

    function test_DolomiteBalance() public {
        // Supply some tokens first
        uint256 supplyAmount = 5000e6; // 5000 USDC
        deal(USDC, plasmaVault, supplyAmount);

        _supplyToDolomite(USDC, supplyAmount, 0);

        // Query balance via BalanceFuse (through PlasmaVault's totalAssets)
        uint256 totalAssets = PlasmaVault(plasmaVault).totalAssets();

        // Total assets should reflect the supplied amount (in USD value)
        // Since USDC is 1:1 with USD and we supplied 5000 USDC
        assertGt(totalAssets, 0, "Total assets should be positive after supply");

        // Check Dolomite balance directly
        IDolomiteMargin.Wei memory dolomiteBalance = _getDolomiteBalance(USDC, 0);
        assertTrue(dolomiteBalance.sign, "Should have positive balance");
        assertApproxEqAbs(dolomiteBalance.value, supplyAmount, 100, "Dolomite balance should match supply");
    }

    function test_VaultBalanceUpdate() public {
        uint256 initialSupply = 10_000e6; // 10,000 USDC
        deal(USDC, plasmaVault, initialSupply);

        // Get total assets before any Dolomite operations
        uint256 totalAssetsBefore = PlasmaVault(plasmaVault).totalAssets();

        // Supply to Dolomite
        _supplyToDolomite(USDC, 5000e6, 0);

        // Total assets should remain approximately the same (assets moved from vault to Dolomite)
        uint256 totalAssetsAfterSupply = PlasmaVault(plasmaVault).totalAssets();

        // The difference should be minimal (just gas/rounding)
        assertApproxEqRel(
            totalAssetsAfterSupply,
            totalAssetsBefore,
            0.01e18,
            "Total assets should be approximately same after supply"
        );

        // Withdraw half
        _withdrawFromDolomite(USDC, 2500e6, 0);

        uint256 totalAssetsAfterWithdraw = PlasmaVault(plasmaVault).totalAssets();

        // Should still be approximately the same total
        assertApproxEqRel(
            totalAssetsAfterWithdraw,
            totalAssetsBefore,
            0.01e18,
            "Total assets should be approximately same after withdraw"
        );
    }

    function test_SupplyZeroAmount() public {
        // Zero amount supply should be a no-op
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(supplyFuse),
            data: abi.encodeCall(
                supplyFuse.enter,
                (
                    DolomiteSupplyFuseEnterData({
                        asset: USDC,
                        amount: 0,
                        minBalanceIncrease: 0,
                        subAccountId: 0,
                        isolationModeMarketId: 0
                    })
                )
            )
        });

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(actions);
    }

    function test_WithdrawMoreThanBalance() public {
        // Supply 100 USDC
        uint256 supplyAmount = 100e6;
        deal(USDC, plasmaVault, supplyAmount);

        _supplyToDolomite(USDC, supplyAmount, 0);

        // Try to withdraw 1000 USDC (more than deposited)
        uint256 withdrawAmount = 1000e6;

        uint256 balanceBefore = ERC20(USDC).balanceOf(plasmaVault);

        _withdrawFromDolomite(USDC, withdrawAmount, 0);

        uint256 balanceAfter = ERC20(USDC).balanceOf(plasmaVault);
        uint256 actualWithdrawn = balanceAfter - balanceBefore;

        // Should withdraw only the available balance (approximately supplyAmount)
        assertLe(actualWithdrawn, supplyAmount + 1e6, "Should not withdraw more than supplied + interest");
    }

    // ============ Deployment Helpers ============

    function _deployFuses() internal {
        supplyFuse = new DolomiteSupplyFuse(DOLOMITE_MARKET_ID, DOLOMITE_MARGIN, DEPOSIT_WITHDRAWAL_ROUTER);

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
                assetName: "Dolomite Integration Test Vault",
                assetSymbol: "DITVault",
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

        // Add fuses
        address[] memory fusesToAdd = new address[](1);
        fusesToAdd[0] = address(supplyFuse);
        PlasmaVaultGovernance(plasmaVault).addFuses(fusesToAdd);

        // Add balance fuse
        PlasmaVaultGovernance(plasmaVault).addBalanceFuse(DOLOMITE_MARKET_ID, address(balanceFuse));

        // Grant substrates: USDC (canBorrow=false for supply-only tests)
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = DolomiteFuseLib.substrateToBytes32(
            DolomiteSubstrate({asset: USDC, subAccountId: 0, canBorrow: false})
        );
        PlasmaVaultGovernance(plasmaVault).grantMarketSubstrates(DOLOMITE_MARKET_ID, substrates);

        _currentSubstrates = substrates;

        vm.stopPrank();
    }

    // ============ Dolomite Action Helpers ============

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

    function _withdrawFromDolomite(address asset_, uint256 amount_, uint8 subAccountId_) internal {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(supplyFuse),
            data: abi.encodeCall(
                supplyFuse.exit,
                (
                    DolomiteSupplyFuseExitData({
                        asset: asset_,
                        amount: amount_,
                        minAmountOut: 0,
                        subAccountId: subAccountId_,
                        isolationModeMarketId: 0
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

    // ============ Receive ETH ============
    receive() external payable {}
}
