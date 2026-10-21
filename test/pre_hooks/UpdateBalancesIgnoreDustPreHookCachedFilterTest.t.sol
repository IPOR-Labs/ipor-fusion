// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {FuseAction} from "../../contracts/interfaces/IPlasmaVault.sol";
import {PlasmaVaultHelper, DeployMinimalPlasmaVaultParams} from "../test_helpers/PlasmaVaultHelper.sol";
import {TestAddresses} from "../test_helpers/TestAddresses.sol";
import {PriceOracleMiddlewareHelper} from "../test_helpers/PriceOracleMiddlewareHelper.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {ERC20BalanceFuse} from "../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {IporFusionAccessManagerHelper} from "../test_helpers/IporFusionAccessManagerHelper.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {UpdateBalancesIgnoreDustPreHook} from "../../contracts/handlers/pre_hooks/pre_hooks/UpdateBalancesIgnoreDustPreHook.sol";
import {UpdateBalancesPreHook} from "../../contracts/handlers/pre_hooks/pre_hooks/UpdateBalancesPreHook.sol";
import {Erc4626BalanceFuse} from "../../contracts/fuses/erc4626/Erc4626BalanceFuse.sol";
import {Erc4626SupplyFuse, Erc4626SupplyFuseEnterData} from "../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {UpdateMarketsBalancesFuse} from "../../contracts/fuses/update_balances/UpdateMarketsBalancesFuse.sol";
import {UpdateMarketsBalancesEnterData} from "../../contracts/fuses/update_balances/IUpdateMarketsBalancesFuse.sol";
import {ZeroBalanceFuse} from "../../contracts/fuses/ZeroBalanceFuse.sol";
import {MockERC4626} from "../test_helpers/MockErc4626.sol";
import {RewardsClaimManager} from "../../contracts/managers/rewards/RewardsClaimManager.sol";
import {InstantWithdrawalFusesParamsStruct} from "../../contracts/libraries/PlasmaVaultLib.sol";
import {PlasmaVaultConfigLib} from "../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";

/// @dev ERC4626 whose convertToAssets can be forced to 0, modelling a balance fuse that reports 0 for one
///      refresh (paused venue, oracle failure, a try/catch-to-zero branch) while the position is intact
contract BreakableERC4626 is MockERC4626 {
    bool public broken;

    constructor(IERC20 asset_) MockERC4626(asset_, "BRK", "BRK") {}

    function setBroken(bool broken_) external {
        broken = broken_;
    }

    function convertToAssets(uint256 shares_) public view override returns (uint256) {
        return broken ? 0 : super.convertToAssets(shares_);
    }
}

/// @notice IL-8326: UpdateBalancesIgnoreDustPreHook filters markets on their cached balance, not the live one.
///         Pins the documented refresh paths and residual limitations, with UpdateBalancesPreHook as the control.
contract UpdateBalancesIgnoreDustPreHookCachedFilterTest is Test {
    using PlasmaVaultHelper for PlasmaVault;
    using PriceOracleMiddlewareHelper for PriceOracleMiddleware;
    using IporFusionAccessManagerHelper for IporFusionAccessManager;

    address private constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant _USER = TestAddresses.USER;
    address private constant _DONOR = address(0xD0D0);
    address private constant _KEEPER = address(0x777);

    /// @dev 1 USDC in underlying decimals
    uint256 private constant _DUST = 1e6;

    uint256 private constant _M1 = IporFusionMarkets.ERC4626_0001;
    uint256 private constant _M2 = IporFusionMarkets.ERC4626_0002;
    uint256 private constant _M3 = IporFusionMarkets.ERC4626_0003;

    PlasmaVault private _plasmaVault;
    IporFusionAccessManager private _accessManager;
    address private _withdrawManager;

    UpdateBalancesIgnoreDustPreHook private _dustHook;
    UpdateBalancesPreHook private _fullHook;

    MockERC4626 private _vault1;
    MockERC4626 private _vault2;
    BreakableERC4626 private _vault3;

    Erc4626SupplyFuse private _supplyFuse1;
    Erc4626SupplyFuse private _supplyFuse2;
    UpdateMarketsBalancesFuse private _updateMarketsBalancesFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 21596204);

        PriceOracleMiddleware priceOracleMiddleware = PriceOracleMiddlewareHelper.getEthereumPriceOracleMiddleware();

        vm.startPrank(TestAddresses.ATOMIST);
        (_plasmaVault, _withdrawManager) = PlasmaVaultHelper.deployMinimalPlasmaVault(
            DeployMinimalPlasmaVaultParams({
                underlyingToken: _USDC,
                underlyingTokenName: "USDC",
                priceOracleMiddleware: priceOracleMiddleware.addressOf(),
                atomist: TestAddresses.ATOMIST
            })
        );
        _accessManager = _plasmaVault.accessManagerOf();
        _accessManager.setupInitRoles(
            _plasmaVault,
            _withdrawManager,
            address(new RewardsClaimManager(address(_accessManager), address(_plasmaVault)))
        );
        _accessManager.grantRole(Roles.UPDATE_MARKETS_BALANCES_ROLE, _KEEPER, 0);
        vm.stopPrank();

        _dustHook = new UpdateBalancesIgnoreDustPreHook();
        _fullHook = new UpdateBalancesPreHook();

        _vault1 = new MockERC4626(IERC20(_USDC), "V1", "V1");
        _vault2 = new MockERC4626(IERC20(_USDC), "V2", "V2");
        _vault3 = new BreakableERC4626(IERC20(_USDC));

        _supplyFuse1 = new Erc4626SupplyFuse(_M1);
        _supplyFuse2 = new Erc4626SupplyFuse(_M2);
        _updateMarketsBalancesFuse = new UpdateMarketsBalancesFuse();

        vm.startPrank(TestAddresses.FUSE_MANAGER);
        _plasmaVault.addBalanceFusesToVault(
            IporFusionMarkets.ERC20_VAULT_BALANCE,
            address(new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE))
        );
        _plasmaVault.addBalanceFusesToVault(_M1, address(new Erc4626BalanceFuse(_M1)));
        _plasmaVault.addBalanceFusesToVault(_M2, address(new Erc4626BalanceFuse(_M2)));
        _plasmaVault.addBalanceFusesToVault(_M3, address(new Erc4626BalanceFuse(_M3)));
        _plasmaVault.addBalanceFusesToVault(
            IporFusionMarkets.ZERO_BALANCE_MARKET,
            address(new ZeroBalanceFuse(IporFusionMarkets.ZERO_BALANCE_MARKET))
        );

        address[] memory fuses = new address[](3);
        fuses[0] = address(_supplyFuse1);
        fuses[1] = address(_supplyFuse2);
        fuses[2] = address(_updateMarketsBalancesFuse);
        _plasmaVault.addFusesToVault(fuses);

        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(_USDC);
        _plasmaVault.addSubstratesToMarket(IporFusionMarkets.ERC20_VAULT_BALANCE, substrates);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(address(_vault1));
        _plasmaVault.addSubstratesToMarket(_M1, substrates);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(address(_vault2));
        _plasmaVault.addSubstratesToMarket(_M2, substrates);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(address(_vault3));
        _plasmaVault.addSubstratesToMarket(_M3, substrates);
        vm.stopPrank();

        deal(_USDC, _USER, 10_000_000e6);
        deal(_USDC, _DONOR, 10_000_000e6);

        vm.prank(_USER);
        IERC20(_USDC).approve(address(_plasmaVault), type(uint256).max);
        vm.startPrank(_DONOR);
        IERC20(_USDC).approve(address(_vault1), type(uint256).max);
        IERC20(_USDC).approve(address(_vault2), type(uint256).max);
        IERC20(_USDC).approve(address(_vault3), type(uint256).max);
        vm.stopPrank();

        vm.prank(_USER);
        _plasmaVault.deposit(1_000e6, _USER);
    }

    function testShouldSkipMarketWhoseCachedBalanceIsDustEvenIfLiveBalanceGrew() public {
        // given
        _wireHook(address(_dustHook), _DUST);
        _seedCachedBalance(_vault1, _M1, 5e5);
        _donate(_vault1, 50_000e6);

        // when
        _userDeposit(1e6);

        // then
        assertEq(_plasmaVault.totalAssetsInMarket(_M1), 5e5, "cached 0.5 USDC is kept, live 50,000.5 USDC ignored");

        _keeperRefresh(_M1);
        assertApproxEqAbs(_plasmaVault.totalAssetsInMarket(_M1), 50_000_500_000, 2, "keeper refresh reads live");
    }

    function testShouldRefreshMarketWithGrownLiveBalanceWhenFullHookIsUsed() public {
        // given
        _wireHook(address(_fullHook), _DUST);
        _seedCachedBalance(_vault1, _M1, 5e5);
        _donate(_vault1, 50_000e6);

        // when
        _userDeposit(1e6);

        // then
        assertApproxEqAbs(_plasmaVault.totalAssetsInMarket(_M1), 50_000_500_000, 2, "full hook reads live");
    }

    function testShouldRefreshMarketWhoseCachedBalanceEqualsThreshold() public {
        // given
        _wireHook(address(_dustHook), _DUST);
        _donate(_vault1, _DUST);
        _donate(_vault2, _DUST - 1);
        _keeperRefresh2(_M1, _M2);
        _donate(_vault1, 1_000e6);
        _donate(_vault2, 1_000e6);

        // when
        _userDeposit(1e6);

        // then
        assertApproxEqAbs(_plasmaVault.totalAssetsInMarket(_M1), _DUST + 1_000e6, 1, "cache == threshold: refreshed");
        assertEq(_plasmaVault.totalAssetsInMarket(_M2), _DUST - 1, "cache == threshold - 1: skipped");
    }

    function testShouldRefreshDustMarketThroughDependencyGraphOfNonDustMarket() public {
        // given
        _wireHook(address(_dustHook), _DUST);
        _donate(_vault1, 10_000e6);
        _donate(_vault2, 5e5);
        _keeperRefresh2(_M1, _M2);

        uint256[] memory dependencies = new uint256[](1);
        dependencies[0] = _M2;
        vm.prank(TestAddresses.FUSE_MANAGER);
        _plasmaVault.addDependencyBalanceGraphs(_M1, dependencies);

        _donate(_vault2, 20_000e6);

        // when
        _userDeposit(1e6);

        // then
        assertApproxEqAbs(
            _plasmaVault.totalAssetsInMarket(_M2),
            20_000_500_000,
            2,
            "dust market refreshed through the dependency graph of a non-dust market"
        );
    }

    function testShouldRefreshDustMarketOnExecuteOnThatMarket() public {
        // given
        _wireHook(address(_dustHook), _DUST);
        _seedCachedBalance(_vault1, _M1, 5e5);
        _donate(_vault1, 50_000e6);

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(_supplyFuse1),
            abi.encodeWithSelector(
                Erc4626SupplyFuse.enter.selector,
                Erc4626SupplyFuseEnterData({vault: address(_vault1), vaultAssetAmount: 1e6, minSharesOut: 0})
            )
        );

        // when
        vm.prank(TestAddresses.ALPHA);
        _plasmaVault.execute(calls);

        // then
        assertApproxEqAbs(
            _plasmaVault.totalAssetsInMarket(_M1),
            50_001_500_000,
            2,
            "execute on the market refreshes it"
        );
    }

    function testShouldRefreshDustMarketOnUpdateMarketsBalancesFuse() public {
        // given
        _wireHook(address(_dustHook), _DUST);
        _seedCachedBalance(_vault1, _M1, 5e5);
        _donate(_vault1, 50_000e6);

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = _M1;
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(_updateMarketsBalancesFuse),
            abi.encodeWithSelector(UpdateMarketsBalancesFuse.enter.selector, UpdateMarketsBalancesEnterData(marketIds))
        );

        // when
        vm.prank(TestAddresses.ALPHA);
        _plasmaVault.execute(calls);

        // then
        assertApproxEqAbs(
            _plasmaVault.totalAssetsInMarket(_M1),
            50_000_500_000,
            2,
            "UpdateMarketsBalancesFuse refreshes it"
        );
    }

    function testShouldRefreshDustMarketOnInstantWithdrawalFromThatMarket() public {
        // given
        _wireHook(address(_dustHook), _DUST);
        _configureInstantWithdrawalFromM1();

        // park the idle USDC in M2 so that the withdrawal has to pull liquidity from M1
        uint256 idle = IERC20(_USDC).balanceOf(address(_plasmaVault));
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(_supplyFuse2),
            abi.encodeWithSelector(
                Erc4626SupplyFuse.enter.selector,
                Erc4626SupplyFuseEnterData({vault: address(_vault2), vaultAssetAmount: idle, minSharesOut: 0})
            )
        );
        vm.prank(TestAddresses.ALPHA);
        _plasmaVault.execute(calls);
        assertEq(IERC20(_USDC).balanceOf(address(_plasmaVault)), 0, "no idle USDC left");

        _seedCachedBalance(_vault1, _M1, 5e5);
        _donate(_vault1, 50_000e6);

        // when
        vm.prank(_USER);
        _plasmaVault.withdraw(100e6, _USER, _USER);

        // then
        assertApproxEqAbs(
            _plasmaVault.totalAssetsInMarket(_M1),
            49_900_500_000,
            1_000, // withdrawal rounding pulls a few wei more than 100 USDC
            "instant withdrawal refreshes the market it pulls from"
        );
    }

    function testShouldKeepTransientZeroCachedWhenDustHookIsUsed() public {
        // given
        _wireHook(address(_dustHook), _DUST);

        // when
        uint256 cachedAfterRecovery = _transientZeroScenario();

        // then
        assertEq(cachedAfterRecovery, 0, "a one-off 0 read turns the market into dust and it is not re-read");
    }

    function testShouldRecoverFromTransientZeroWhenFullHookIsUsed() public {
        // given
        _wireHook(address(_fullHook), _DUST);

        // when
        uint256 cachedAfterRecovery = _transientZeroScenario();

        // then
        assertApproxEqAbs(cachedAfterRecovery, 20_000e6, 1, "full hook re-reads the market on the next deposit");
    }

    function testShouldRefreshNothingWhenThresholdIsInWrongDecimals() public {
        // given
        _wireHook(address(_dustHook), 1e18); // 18 decimals on USDC = 1e12 USDC
        _donate(_vault1, 1_000_000e6);
        _keeperRefresh(_M1);
        _donate(_vault1, 25_000e6);

        // when
        _userDeposit(1e6);

        // then
        assertEq(_plasmaVault.totalAssetsInMarket(_M1), 1_000_000e6, "1M USDC market is treated as dust");
    }

    function _transientZeroScenario() private returns (uint256) {
        _donate(_vault3, 20_000e6);
        _keeperRefresh(_M3);
        assertApproxEqAbs(_plasmaVault.totalAssetsInMarket(_M3), 20_000e6, 1, "market cached at 20,000 USDC");

        _vault3.setBroken(true);
        _userDeposit(1e6);
        assertEq(_plasmaVault.totalAssetsInMarket(_M3), 0, "hook cached the transient 0");

        _vault3.setBroken(false);
        _userDeposit(1e6);
        _userDeposit(1e6);
        return _plasmaVault.totalAssetsInMarket(_M3);
    }

    function _configureInstantWithdrawalFromM1() private {
        InstantWithdrawalFusesParamsStruct[] memory config = new InstantWithdrawalFusesParamsStruct[](1);
        bytes32[] memory params = new bytes32[](2);
        params[0] = bytes32(0);
        params[1] = PlasmaVaultConfigLib.addressToBytes32(address(_vault1));
        config[0] = InstantWithdrawalFusesParamsStruct({fuse: address(_supplyFuse1), params: params});
        vm.prank(TestAddresses.CONFIG_INSTANT_WITHDRAWAL_FUSES_MANAGER);
        PlasmaVaultGovernance(address(_plasmaVault)).configureInstantWithdrawalFuses(config);
    }

    function _wireHook(address hook_, uint256 threshold_) private {
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = PlasmaVault.deposit.selector;
        selectors[1] = PlasmaVault.withdraw.selector;
        selectors[2] = PlasmaVault.redeem.selector;
        address[] memory hooks = new address[](3);
        bytes32[][] memory substrates = new bytes32[][](3);
        for (uint256 i; i < 3; ++i) {
            hooks[i] = hook_;
            substrates[i] = new bytes32[](1);
            substrates[i][0] = bytes32(threshold_);
        }
        vm.prank(TestAddresses.ATOMIST);
        PlasmaVaultGovernance(address(_plasmaVault)).setPreHookImplementations(selectors, hooks, substrates);
    }

    function _seedCachedBalance(MockERC4626 vault_, uint256 marketId_, uint256 amount_) private {
        _donate(vault_, amount_);
        _keeperRefresh(marketId_);
        assertEq(_plasmaVault.totalAssetsInMarket(marketId_), amount_, "seeded cache");
    }

    function _donate(MockERC4626 vault_, uint256 amount_) private {
        vm.prank(_DONOR);
        vault_.deposit(amount_, address(_plasmaVault));
    }

    function _keeperRefresh(uint256 marketId_) private {
        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = marketId_;
        vm.prank(_KEEPER);
        _plasmaVault.updateMarketsBalances(marketIds);
    }

    function _keeperRefresh2(uint256 marketIdA_, uint256 marketIdB_) private {
        uint256[] memory marketIds = new uint256[](2);
        marketIds[0] = marketIdA_;
        marketIds[1] = marketIdB_;
        vm.prank(_KEEPER);
        _plasmaVault.updateMarketsBalances(marketIds);
    }

    function _userDeposit(uint256 amount_) private {
        vm.prank(_USER);
        _plasmaVault.deposit(amount_, _USER);
    }
}
