// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {
    PlasmaVault,
    MarketBalanceFuseConfig,
    MarketSubstratesConfig,
    PlasmaVaultInitData,
    FuseAction
} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultCloneLib} from "../test_helpers/PlasmaVaultCloneLib.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {InstantWithdrawalFusesParamsStruct} from "../../contracts/libraries/PlasmaVaultLib.sol";
import {PlasmaVaultConfigLib} from "../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {MarketLimit} from "../../contracts/libraries/AssetDistributionProtectionLib.sol";
import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {FixedValuePriceFeed} from "../../contracts/price_oracle/price_feed/FixedValuePriceFeed.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {FeeManagerFactory, FeeConfig} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {FeeManager} from "../../contracts/managers/fee/FeeManager.sol";
import {FeeAccount} from "../../contracts/managers/fee/FeeAccount.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {Erc4626SupplyFuse, Erc4626SupplyFuseEnterData} from "../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {Erc4626BalanceFuse} from "../../contracts/fuses/erc4626/Erc4626BalanceFuse.sol";
import {UpdateBalancesPreHook} from "../../contracts/handlers/pre_hooks/pre_hooks/UpdateBalancesPreHook.sol";
import {PlasmaVaultConfigurator} from "../utils/PlasmaVaultConfigurator.sol";
import {RoleLib, UsersToRoles} from "../RoleLib.sol";
import {MockERC20Decimals} from "../unitTest/fuses/term_finance/mocks/MockERC20Decimals.sol";
import {MockERC4626} from "../test_helpers/MockErc4626.sol";
import {MockERC4626WithFee} from "../test_helpers/MockERC4626WithFee.sol";

/// @title PlasmaVaultMockMarketsTestBase
/// @notice Shared fixture for unit tests of PlasmaVault accounting on mocks: a locally built PlasmaVault (never a
///         FusionFactory clone, so the tests run the code of this tree) with a 6-decimals asset at a fixed price,
///         two ERC-4626 markets (A can charge an exit fee, B is a plain vault), supply and balance fuses, both markets
///         on the instant-withdraw list, a WithdrawManager and a FeeManager with a configurable fee setup.
/// @dev Subclasses override the fee knobs and call the helpers; this contract has no tests of its own.
abstract contract PlasmaVaultMockMarketsTestBase is Test {
    address public atomist = address(this);
    address public alpha = address(0x1);
    address public updater = address(0x2);
    address public user = address(0xA11CE);
    address public other = address(0xB0B);

    uint256 public constant MARKET_A = IporFusionMarkets.ERC4626_0001;
    uint256 public constant MARKET_B = IporFusionMarkets.ERC4626_0002;

    MockERC20Decimals public asset;
    MockERC4626WithFee public marketA;
    MockERC4626 public marketB;
    Erc4626SupplyFuse public supplyFuseA;
    Erc4626SupplyFuse public supplyFuseB;
    UsersToRoles public usersToRoles;
    IporFusionAccessManager public accessManager;
    WithdrawManager public withdrawManager;
    PlasmaVault public plasmaVault;

    /// @dev Exit fee of market A in basis points, charged on every withdraw and redeem from it (0 = no cost)
    function _exitFeeBpsMarketA() internal view virtual returns (uint256) {
        return 0;
    }

    /// @dev Performance fee of the IPOR DAO recipient (FeeManager percentages use 2 decimals, 10000 = 100%)
    function _performanceFee() internal view virtual returns (uint256) {
        return 1000;
    }

    /// @dev Management fee of the IPOR DAO recipient (same scale)
    function _managementFee() internal view virtual returns (uint256) {
        return 0;
    }

    function setUp() public virtual {
        asset = new MockERC20Decimals("Mock USDC", "mUSDC", 6);
        marketA = new MockERC4626WithFee(asset, "Market A", "mA", _exitFeeBpsMarketA());
        marketB = new MockERC4626(asset, "Market B", "mB");

        PriceOracleMiddleware oracle = _createOracle();
        accessManager = _createAccessManager();
        withdrawManager = new WithdrawManager(address(accessManager));

        plasmaVault = PlasmaVaultCloneLib.newPlasmaVault();
        plasmaVault.proxyInitialize(
            PlasmaVaultInitData(
                "IPOR Fusion mUSDC",
                "ipfmUSDC",
                address(asset),
                address(oracle),
                FeeConfig({
                    iporDaoManagementFee: _managementFee(),
                    iporDaoPerformanceFee: _performanceFee(),
                    feeFactory: address(new FeeManagerFactory()),
                    iporDaoFeeRecipientAddress: address(98989898)
                }),
                address(accessManager),
                address(new PlasmaVaultBase()),
                address(withdrawManager),
                address(0)
            )
        );

        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(plasmaVault), accessManager, address(withdrawManager));
        _setupExtraRoles();

        /// @dev IL-9531: requestShares checks the balance on the vault the WithdrawManager is wired to
        vm.prank(atomist);
        withdrawManager.updatePlasmaVaultAddress(address(plasmaVault));

        supplyFuseA = new Erc4626SupplyFuse(MARKET_A);
        supplyFuseB = new Erc4626SupplyFuse(MARKET_B);

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuseA);
        fuses[1] = address(supplyFuseB);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](2);
        balanceFuses[0] = MarketBalanceFuseConfig(MARKET_A, address(new Erc4626BalanceFuse(MARKET_A)));
        balanceFuses[1] = MarketBalanceFuseConfig(MARKET_B, address(new Erc4626BalanceFuse(MARKET_B)));

        MarketSubstratesConfig[] memory substrates = new MarketSubstratesConfig[](2);
        substrates[0] = MarketSubstratesConfig(
            MARKET_A,
            _single(PlasmaVaultConfigLib.addressToBytes32(address(marketA)))
        );
        substrates[1] = MarketSubstratesConfig(
            MARKET_B,
            _single(PlasmaVaultConfigLib.addressToBytes32(address(marketB)))
        );

        PlasmaVaultConfigurator.setupPlasmaVault(vm, atomist, address(plasmaVault), fuses, balanceFuses, substrates);

        _configureInstantWithdraw();

        _fund(user, 10_000_000e6);
        _fund(other, 10_000_000e6);
    }

    // ------------------------------------------------------------------ actions

    function _deposit(address user_, uint256 amount_) internal {
        vm.prank(user_);
        plasmaVault.deposit(amount_, user_);
    }

    /// @dev Moves `amount_` of idle assets into the given market through the supply fuse (alpha, execute)
    function _allocate(address market_, uint256 amount_) internal {
        Erc4626SupplyFuse fuse = market_ == address(marketA) ? supplyFuseA : supplyFuseB;
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(fuse),
            abi.encodeCall(Erc4626SupplyFuse.enter, (Erc4626SupplyFuseEnterData(market_, amount_, 0)))
        );
        vm.prank(alpha);
        plasmaVault.execute(calls);
    }

    /// @dev Unbooked gain of a market: its assets grow by `bps_` of its balance, the vault's cached balance does not
    function _accrue(address market_, uint256 bps_) internal {
        asset.mint(market_, (asset.balanceOf(market_) * bps_) / 10_000);
    }

    /// @dev Unbooked loss of a market: its assets shrink by `bps_` of its balance, the vault's cached balance does not
    function _loss(address market_, uint256 bps_) internal {
        uint256 amount = (asset.balanceOf(market_) * bps_) / 10_000;
        vm.prank(market_);
        asset.transfer(address(0xdead), amount);
    }

    /// @dev Donation straight to the vault (idle assets): lifts the share rate without touching any market
    function _donate(uint256 amount_) internal {
        asset.mint(address(plasmaVault), amount_);
    }

    /// @dev Sets and activates the share-of-NAV limits of both markets (1e18 = 100%)
    function _setLimits(uint256 limitA_, uint256 limitB_) internal {
        MarketLimit[] memory limits = new MarketLimit[](2);
        limits[0] = MarketLimit(MARKET_A, limitA_);
        limits[1] = MarketLimit(MARKET_B, limitB_);
        PlasmaVaultGovernance(address(plasmaVault)).setupMarketsLimits(limits);
        PlasmaVaultGovernance(address(plasmaVault)).activateMarketsLimits();
    }

    /// @dev The user requests `shares_` and alpha releases them, so `sharesToRelease` of the vault is `shares_`
    function _requestAndRelease(address user_, uint256 shares_) internal {
        vm.prank(user_);
        withdrawManager.requestShares(shares_);
        vm.warp(block.timestamp + 1);
        vm.prank(alpha);
        withdrawManager.releaseFunds(block.timestamp - 1, shares_);
    }

    /// @dev Runs the UpdateBalancesPreHook before the given vault function (refreshes all active markets)
    function _wireUpdateBalancesPreHook(bytes4 selector_) internal {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector_;
        address[] memory hooks = new address[](1);
        hooks[0] = address(new UpdateBalancesPreHook());
        bytes32[][] memory substrates = new bytes32[][](1);
        substrates[0] = new bytes32[](0);
        PlasmaVaultGovernance(address(plasmaVault)).setPreHookImplementations(selectors, hooks, substrates);
    }

    function _setHwmUpdateInterval(uint32 interval_) internal {
        _feeManager().updateIntervalHighWaterMarkPerformanceFee(interval_);
    }

    // ------------------------------------------------------------------ views

    function _rate() internal view returns (uint256) {
        return plasmaVault.convertToAssets(10 ** uint256(plasmaVault.decimals()));
    }

    function _hwm() internal view returns (uint256) {
        return _feeManager().getPlasmaVaultHighWaterMarkPerformanceFee().highWaterMark;
    }

    function _feeAccount() internal view returns (address) {
        return PlasmaVaultGovernance(address(plasmaVault)).getPerformanceFeeData().feeAccount;
    }

    function _feeManager() internal view returns (FeeManager) {
        return FeeManager(FeeAccount(_feeAccount()).FEE_MANAGER());
    }

    // ------------------------------------------------------------------ setup helpers

    function _single(bytes32 value_) private pure returns (bytes32[] memory result) {
        result = new bytes32[](1);
        result[0] = value_;
    }

    function _createOracle() private returns (PriceOracleMiddleware oracle) {
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(address(0));
        oracle = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );
        address[] memory assets = new address[](1);
        assets[0] = address(asset);
        address[] memory sources = new address[](1);
        sources[0] = address(new FixedValuePriceFeed(1e8));
        oracle.setAssetsPricesSources(assets, sources);
    }

    function _createAccessManager() private returns (IporFusionAccessManager) {
        usersToRoles.superAdmin = atomist;
        usersToRoles.atomist = atomist;
        address[] memory alphas = new address[](1);
        alphas[0] = alpha;
        usersToRoles.alphas = alphas;
        return RoleLib.createAccessManager(usersToRoles, 0, vm);
    }

    /// @dev Roles that RoleLib does not wire: market refresh (updater and the vault itself for the pre-hook),
    ///      instant-withdraw configuration, pre-hooks and the HWM interval
    function _setupExtraRoles() private {
        bytes4[] memory updateSig = new bytes4[](1);
        updateSig[0] = PlasmaVault.updateMarketsBalances.selector;
        accessManager.setTargetFunctionRole(address(plasmaVault), updateSig, Roles.UPDATE_MARKETS_BALANCES_ROLE);
        accessManager.grantRole(Roles.UPDATE_MARKETS_BALANCES_ROLE, updater, 0);
        accessManager.grantRole(Roles.UPDATE_MARKETS_BALANCES_ROLE, address(plasmaVault), 0);

        bytes4[] memory instantSig = new bytes4[](1);
        instantSig[0] = PlasmaVaultGovernance.configureInstantWithdrawalFuses.selector;
        accessManager.setTargetFunctionRole(
            address(plasmaVault),
            instantSig,
            Roles.CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE
        );
        accessManager.grantRole(Roles.CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE, atomist, 0);

        bytes4[] memory atomistSig = new bytes4[](1);
        atomistSig[0] = PlasmaVaultGovernance.setPreHookImplementations.selector;
        accessManager.setTargetFunctionRole(address(plasmaVault), atomistSig, Roles.ATOMIST_ROLE);

        bytes4[] memory intervalSig = new bytes4[](1);
        intervalSig[0] = FeeManager.updateIntervalHighWaterMarkPerformanceFee.selector;
        accessManager.setTargetFunctionRole(
            address(
                FeeAccount(PlasmaVaultGovernance(address(plasmaVault)).getPerformanceFeeData().feeAccount).FEE_MANAGER()
            ),
            intervalSig,
            Roles.ATOMIST_ROLE
        );
    }

    function _configureInstantWithdraw() private {
        InstantWithdrawalFusesParamsStruct[] memory instantFuses = new InstantWithdrawalFusesParamsStruct[](2);
        bytes32[] memory paramsA = new bytes32[](2);
        paramsA[1] = PlasmaVaultConfigLib.addressToBytes32(address(marketA));
        bytes32[] memory paramsB = new bytes32[](2);
        paramsB[1] = PlasmaVaultConfigLib.addressToBytes32(address(marketB));
        instantFuses[0] = InstantWithdrawalFusesParamsStruct({fuse: address(supplyFuseA), params: paramsA});
        instantFuses[1] = InstantWithdrawalFusesParamsStruct({fuse: address(supplyFuseB), params: paramsB});
        PlasmaVaultGovernance(address(plasmaVault)).configureInstantWithdrawalFuses(instantFuses);
    }

    function _fund(address user_, uint256 amount_) private {
        asset.mint(user_, amount_);
        vm.prank(user_);
        asset.approve(address(plasmaVault), type(uint256).max);
    }
}
