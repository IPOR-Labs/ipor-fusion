// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {PlasmaVault, PlasmaVaultInitData, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {FixedValuePriceFeed} from "../../../contracts/price_oracle/price_feed/FixedValuePriceFeed.sol";
import {ERC4626PriceFeed} from "../../../contracts/price_oracle/price_feed/ERC4626PriceFeed.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {EulerV2BalanceFuse} from "../../../contracts/fuses/euler/EulerV2BalanceFuse.sol";
import {EulerV2SupplyFuse, EulerV2SupplyFuseEnterData} from "../../../contracts/fuses/euler/EulerV2SupplyFuse.sol";
import {EulerFuseLib, EulerSubstrate} from "../../../contracts/fuses/euler/EulerFuseLib.sol";
import {PlasmaVaultCloneLib} from "../../test_helpers/PlasmaVaultCloneLib.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {RoleLib, UsersToRoles} from "../../RoleLib.sol";

/// @title EulerV2BalanceFuseUnderlyingSkipForkTest
/// @notice IL-9707 (3sigma audit v3 #21) against the real Euler stack on an Ethereum mainnet fork: a Plasma Vault whose
///         underlying is the real Euler Prime USDC eVault share (eUSDC-2), priced by ERC4626PriceFeed, with the market
///         11 row (eUSDC-2, sub-account 0x00). EVC sub-account 0x00 is the vault address, so the eUSDC-2 shares the
///         vault wraps there are its idle underlying, already counted by `totalAssets`; EulerV2BalanceFuse must not
///         count them a second time. The control row (eUSDC-2, sub-account 0x01) is a real position and counts.
contract EulerV2BalanceFuseUnderlyingSkipForkTest is Test {
    /// @dev Own fork block of this suite (forks are not shared with other suites)
    uint256 private constant _FORK_BLOCK = 21_130_007;

    uint256 private constant _MARKET_ID = IporFusionMarkets.EULER_V2;

    address private constant _EVC = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;
    /// @dev eUSDC-2: Euler Prime USDC, the underlying of the Plasma Vault in this test
    address private constant _EULER_VAULT_PRIME_USDC = 0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9;
    address private constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    bytes1 private constant _SUB_ACCOUNT_ZERO = 0x00;
    bytes1 private constant _SUB_ACCOUNT_ONE = 0x01;

    /// @dev eUSDC-2 shares the user deposits into the Plasma Vault (its idle underlying)
    uint256 private constant _IDLE_USDC = 100_000e6;
    /// @dev USDC the vault wraps into eUSDC-2 through EulerV2SupplyFuse
    uint256 private constant _WRAPPED_USDC = 10_000e6;

    /// @dev Relative tolerance (1e-5) of the value of shares in underlying units: ERC4626PriceFeed reads the share
    ///      price with the 6 decimals of the asset
    uint256 private constant _PRICE_TOLERANCE = 1e13;

    address private constant _ALPHA = address(0x1);
    address private constant _UPDATER = address(0x2);
    address private constant _USER = address(0xA11CE);

    EulerV2SupplyFuse private _supplyFuse;
    EulerV2BalanceFuse private _balanceFuse;
    PriceOracleMiddleware private _oracle;
    PlasmaVault private _plasmaVault;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), _FORK_BLOCK);

        _oracle = _createOracle();
        _supplyFuse = new EulerV2SupplyFuse(_MARKET_ID, _EVC);
        _balanceFuse = new EulerV2BalanceFuse(_MARKET_ID, _EVC);
        _plasmaVault = _createPlasmaVault();

        // a user deposits eUSDC-2 shares: the vault's idle underlying, held on the vault address = sub-account 0x00
        deal(_USDC, _USER, _IDLE_USDC);
        vm.startPrank(_USER);
        IERC20(_USDC).approve(_EULER_VAULT_PRIME_USDC, _IDLE_USDC);
        uint256 shares = IERC4626(_EULER_VAULT_PRIME_USDC).deposit(_IDLE_USDC, _USER);
        IERC20(_EULER_VAULT_PRIME_USDC).approve(address(_plasmaVault), shares);
        _plasmaVault.deposit(shares, _USER);
        vm.stopPrank();
    }

    /// @notice The vault wraps USDC into eUSDC-2 on sub-account 0x00: the new shares land on the vault address, so
    ///         `totalAssets` grows by exactly the wrapped shares and market 11 holds nothing. Before IL-9707 the fuse
    ///         counted the whole eUSDC-2 balance of sub-account 0x00 again and `totalAssets` about doubled.
    function testShouldGrowTotalAssetsByWrappedAmountWhenUnderlyingEulerVaultIsOnSubAccountZero() external {
        // given
        _grant(_SUB_ACCOUNT_ZERO);
        uint256 totalAssetsBefore = _plasmaVault.totalAssets();
        assertEq(totalAssetsBefore, IERC20(_EULER_VAULT_PRIME_USDC).balanceOf(address(_plasmaVault)), "idle only");
        assertGt(totalAssetsBefore, 0, "vault holds idle underlying");
        uint256 expectedShares = IERC4626(_EULER_VAULT_PRIME_USDC).previewDeposit(_WRAPPED_USDC);

        // when
        uint256 wrappedShares = _wrap(_SUB_ACCOUNT_ZERO);

        // then
        assertEq(wrappedShares, expectedShares, "shares minted for the wrapped USDC");
        assertGt(wrappedShares, 0, "something was wrapped");
        assertEq(
            IERC20(_EULER_VAULT_PRIME_USDC).balanceOf(address(_plasmaVault)),
            totalAssetsBefore + wrappedShares,
            "wrapped shares are on the vault address (sub-account 0x00)"
        );
        assertEq(_plasmaVault.totalAssetsInMarket(_MARKET_ID), 0, "idle underlying not counted again in market 11");
        assertEq(
            _plasmaVault.totalAssets() - totalAssetsBefore,
            wrappedShares,
            "totalAssets grows by the wrapped value only (not doubled)"
        );
    }

    /// @notice Control: the same wrap on sub-account 0x01 is a real position. The shares are not the vault's idle
    ///         underlying, so market 11 counts them in full (value of the shares in underlying units, within the
    ///         rounding of the price feed, which truncates the share price to 6 decimals) and `totalAssets` grows by that value.
    function testShouldCountUnderlyingEulerVaultOnSubAccountOne() external {
        // given
        _grant(_SUB_ACCOUNT_ONE);
        uint256 totalAssetsBefore = _plasmaVault.totalAssets();

        // when
        uint256 wrappedShares = _wrap(_SUB_ACCOUNT_ONE);

        // then
        address subAccountOne = EulerFuseLib.generateSubAccountAddress(address(_plasmaVault), _SUB_ACCOUNT_ONE);
        assertEq(IERC20(_EULER_VAULT_PRIME_USDC).balanceOf(subAccountOne), wrappedShares, "shares on sub-account 0x01");
        assertGt(wrappedShares, 0, "something was wrapped");
        assertApproxEqRel(
            _plasmaVault.totalAssetsInMarket(_MARKET_ID),
            wrappedShares,
            _PRICE_TOLERANCE,
            "shares on 0x01 counted in full"
        );
        assertApproxEqRel(
            _plasmaVault.totalAssets() - totalAssetsBefore,
            wrappedShares,
            _PRICE_TOLERANCE,
            "totalAssets grows by the wrapped value"
        );
    }

    //******************************************************************************************************************
    //********************                              HELPERS                                     ********************
    //******************************************************************************************************************

    /// @dev The vault receives USDC (not its underlying, so not counted) and wraps it into eUSDC-2 on `subAccount_`
    ///      through EulerV2SupplyFuse; `execute` refreshes market 11. Returns the shares minted.
    function _wrap(bytes1 subAccount_) private returns (uint256) {
        deal(_USDC, address(_plasmaVault), _WRAPPED_USDC);
        address holder = EulerFuseLib.generateSubAccountAddress(address(_plasmaVault), subAccount_);
        uint256 sharesBefore = IERC20(_EULER_VAULT_PRIME_USDC).balanceOf(holder);

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_supplyFuse),
            abi.encodeCall(
                EulerV2SupplyFuse.enter,
                (
                    EulerV2SupplyFuseEnterData({
                        eulerVault: _EULER_VAULT_PRIME_USDC,
                        maxAmount: _WRAPPED_USDC,
                        subAccount: subAccount_
                    })
                )
            )
        );
        vm.prank(_ALPHA);
        _plasmaVault.execute(actions);

        return IERC20(_EULER_VAULT_PRIME_USDC).balanceOf(holder) - sharesBefore;
    }

    function _grant(bytes1 subAccount_) private {
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({
                eulerVault: _EULER_VAULT_PRIME_USDC,
                isCollateral: false,
                canBorrow: false,
                subAccounts: subAccount_
            })
        );
        PlasmaVaultGovernance(address(_plasmaVault)).grantMarketSubstrates(_MARKET_ID, substrates);
    }

    /// @dev USDC at 1 USD; eUSDC-2 priced by ERC4626PriceFeed from its share price and the USDC price
    function _createOracle() private returns (PriceOracleMiddleware oracle) {
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(address(0));
        oracle = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );
        address[] memory assets = new address[](2);
        assets[0] = _USDC;
        assets[1] = _EULER_VAULT_PRIME_USDC;
        address[] memory sources = new address[](2);
        sources[0] = address(new FixedValuePriceFeed(1e8));
        sources[1] = address(new ERC4626PriceFeed(_EULER_VAULT_PRIME_USDC));
        oracle.setAssetsPricesSources(assets, sources);
    }

    /// @dev A locally built PlasmaVault (never a factory clone, so the test runs the code of this tree) with
    ///      EulerV2SupplyFuse and EulerV2BalanceFuse on market 11; the test contract is atomist and fuse manager
    function _createPlasmaVault() private returns (PlasmaVault plasmaVault) {
        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = address(this);
        usersToRoles.atomist = address(this);
        address[] memory alphas = new address[](1);
        alphas[0] = _ALPHA;
        usersToRoles.alphas = alphas;
        IporFusionAccessManager accessManager = RoleLib.createAccessManager(usersToRoles, 0, vm);
        WithdrawManager withdrawManager = new WithdrawManager(address(accessManager));

        plasmaVault = PlasmaVaultCloneLib.newPlasmaVault();
        plasmaVault.proxyInitialize(
            PlasmaVaultInitData(
                "IPOR Fusion eUSDC",
                "ipfeUSDC",
                _EULER_VAULT_PRIME_USDC,
                address(_oracle),
                FeeConfigHelper.createZeroFeeConfig(),
                address(accessManager),
                address(new PlasmaVaultBase()),
                address(withdrawManager),
                address(0)
            )
        );
        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(plasmaVault), accessManager, address(withdrawManager));

        bytes4[] memory updateSig = new bytes4[](1);
        updateSig[0] = PlasmaVault.updateMarketsBalances.selector;
        accessManager.setTargetFunctionRole(address(plasmaVault), updateSig, Roles.UPDATE_MARKETS_BALANCES_ROLE);
        accessManager.grantRole(Roles.UPDATE_MARKETS_BALANCES_ROLE, _UPDATER, 0);

        address[] memory fuses = new address[](1);
        fuses[0] = address(_supplyFuse);
        PlasmaVaultGovernance(address(plasmaVault)).addFuses(fuses);
        PlasmaVaultGovernance(address(plasmaVault)).addBalanceFuse(_MARKET_ID, address(_balanceFuse));
    }
}
