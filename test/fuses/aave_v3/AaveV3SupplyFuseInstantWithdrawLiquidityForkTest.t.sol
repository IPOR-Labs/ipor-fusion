// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {AaveV3SupplyFuse, AaveV3SupplyFuseEnterData} from "../../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {AaveV3BalanceFuse} from "../../../contracts/fuses/aave_v3/AaveV3BalanceFuse.sol";
import {Erc4626SupplyFuse, Erc4626SupplyFuseEnterData} from "../../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {Erc4626BalanceFuse} from "../../../contracts/fuses/erc4626/Erc4626BalanceFuse.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {IPool} from "../../../contracts/fuses/aave_v3/ext/IPool.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {InstantWithdrawalFusesParamsStruct} from "../../../contracts/libraries/PlasmaVaultLib.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVault, PlasmaVaultInitData} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {FeeAccount} from "../../../contracts/managers/fee/FeeAccount.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {PlasmaVaultCloneLib} from "../../test_helpers/PlasmaVaultCloneLib.sol";
import {PlasmaVaultConfigurator} from "../../utils/PlasmaVaultConfigurator.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {
    IporFusionAccessManagerInitializerLibV1,
    InitializationData,
    DataForInitialization,
    PlasmaVaultAddress
} from "../../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";

/// @title AaveV3SupplyFuseInstantWithdrawLiquidityForkTest
/// @notice IL-9558: the instant withdraw path of AaveV3SupplyFuse caps each request at the reserve liquidity, so a
///         partly liquid reserve pays what it can and the next instant withdraw fuse takes the rest. Real Aave V3
///         Ethereum Core (virtual accounting active, bit 252), a real PlasmaVault and the real withdrawFromMarkets
///         loop. The reserve liquidity is lowered with a real borrow, which also lowers the virtual balance.
contract AaveV3SupplyFuseInstantWithdrawLiquidityForkTest is Test {
    address private constant _AAVE_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    IPool private constant _POOL = IPool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    address private constant _AAVE_ORACLE = 0x54586bE62E3c3580375aE3723C145253060Ca0C2;

    address private constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant _W_ETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    /// @dev Real liquid ERC4626 USDC venue used as the next instant withdraw entry (Steakhouse USDC MetaMorpho vault)
    address private constant _ERC4626_USDC_VAULT = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;

    address private constant _CHAINLINK_REGISTRY = 0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf;
    address private constant _USDC_USD_CHAINLINK = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;

    address private constant _ATOMIST = address(0x111111);
    address private constant _USER = address(0x222222);

    /// @dev Own fork block (recent, Aave V3.x with virtual accounting): shared blocks share one backend
    uint256 public constant FORK_BLOCK = 26389106;

    address private _plasmaVault;
    address private _accessManager;
    address private _withdrawManager;
    address private _aaveSupplyFuse;
    address private _erc4626SupplyFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), FORK_BLOCK);

        // the reserve must have virtual accounting active, otherwise the test would not cover bit 252
        assertEq((_configuration() >> 252) & 1, 1, "virtual accounting active for USDC");

        address priceOracle = _createPriceOracle();
        _accessManager = address(new IporFusionAccessManager(_ATOMIST, 0));
        _withdrawManager = address(new WithdrawManager(_accessManager));

        vm.startPrank(_ATOMIST);
        _plasmaVault = address(PlasmaVaultCloneLib.newPlasmaVault());
        PlasmaVault(_plasmaVault).proxyInitialize(
            PlasmaVaultInitData({
                assetName: "Aave IW liquidity",
                assetSymbol: "aIWl",
                underlyingToken: _USDC,
                priceOracleMiddleware: priceOracle,
                feeConfig: FeeConfigHelper.createZeroFeeConfig(),
                accessManager: _accessManager,
                plasmaVaultBase: address(new PlasmaVaultBase()),
                withdrawManager: _withdrawManager,
                plasmaVaultVotesPlugin: address(0)
            })
        );
        vm.stopPrank();

        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            _ATOMIST,
            _plasmaVault,
            _setupFuses(),
            _setupBalanceFuses(),
            _setupMarketConfigs()
        );

        _initAccessManager();

        deal(_USDC, _USER, 10_000e6);
        vm.startPrank(_USER);
        ERC20(_USDC).approve(_plasmaVault, 10_000e6);
        PlasmaVault(_plasmaVault).deposit(10_000e6, _USER);
        vm.stopPrank();
    }

    /// @notice Aave (liquidity 3,000, position 6,000) is the first entry, the ERC4626 venue (position 4,000) the
    ///         second: the withdrawal draws the Aave liquidity and the rest from the second entry instead of
    ///         reverting (on the base the Aave entry pays 0 and the second entry cannot cover 5,000 alone)
    function test_withdrawTakesPartialLiquidityFromAaveAndRestFromNextEntry() public {
        _allocate(6_000e6, 4_000e6);
        _lowerAaveLiquidity(3_000e6);
        uint256 liquidity = _virtualBalance();
        assertEq(liquidity, 3_000e6, "Aave USDC virtual balance");
        assertGe(ERC20(_USDC).balanceOf(_aToken()), liquidity, "virtual balance is not above the aToken balance");
        assertGt(ERC20(_aToken()).balanceOf(_plasmaVault), liquidity, "the position exceeds the liquidity");

        vm.recordLogs();
        vm.prank(_USER);
        PlasmaVault(_plasmaVault).withdraw(5_000e6, _USER, _USER);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(ERC20(_USDC).balanceOf(_USER), 5_000e6, "user received the payout");
        assertEq(_aaveExitAmount(logs), liquidity, "Aave pays its whole liquidity");
        assertEq(_aaveFailedCount(logs), 0, "no ExitFailed event");
        assertEq(_virtualBalance(), 0, "Aave liquidity fully used");
    }

    /// @notice Half of the shares are redeemed and Aave is the only entry. Its liquidity covers the redeem payout
    ///         (+1%) but sits below the vault's 2% slippage-buffered request, while the position exceeds that
    ///         request, so the liquidity cap is the binding one: the entry pays the whole liquidity and the redeem
    ///         succeeds (on the base the entry pays 0 and the redeem reverts)
    function test_redeemSucceedsWhenLiquidityIsBelowSlippageBuffer() public {
        _allocate(10_000e6, 0);

        uint256 shares = ERC20(_plasmaVault).balanceOf(_USER);
        uint256 sharesToRedeem = shares / 2;
        uint256 payout = PlasmaVault(_plasmaVault).convertToAssets(sharesToRedeem);
        uint256 liquidityLeft = (payout * 101) / 100;
        assertLt(liquidityLeft, (payout * 102) / 100, "liquidity is below the buffered request");
        assertGt(
            ERC20(_aToken()).balanceOf(_plasmaVault),
            (payout * 103) / 100,
            "position exceeds the buffered request"
        );

        _lowerAaveLiquidity(liquidityLeft);
        assertEq(_virtualBalance(), liquidityLeft, "Aave USDC virtual balance");

        vm.recordLogs();
        vm.prank(_USER);
        uint256 assets = PlasmaVault(_plasmaVault).redeem(sharesToRedeem, _USER, _USER);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_aaveExitAmount(logs), liquidityLeft, "request capped at the liquidity");
        assertEq(_virtualBalance(), 0, "Aave liquidity fully used");
        assertEq(_aaveFailedCount(logs), 0, "no ExitFailed event");
        assertEq(ERC20(_USDC).balanceOf(_USER), assets, "user received the redeem payout");
        // the borrow in the fork moves the Aave position value by a few millionths before the redeem
        assertApproxEqRel(assets, payout, 1e14, "redeem paid the converted payout");
        assertEq(ERC20(_plasmaVault).balanceOf(_USER), shares - sharesToRedeem, "half of the shares redeemed");
    }

    /// @notice Pins D-010: the ALPHA exit is not capped at the liquidity, a request above it reverts
    function test_alphaExitAboveLiquidityStillReverts() public {
        _allocate(6_000e6, 4_000e6);
        _lowerAaveLiquidity(3_000e6);

        FuseAction[] memory exits = new FuseAction[](1);
        exits[0] = FuseAction({
            fuse: _aaveSupplyFuse,
            data: abi.encodeWithSignature("exit((address,uint256))", _USDC, uint256(5_000e6))
        });
        // the full ALPHA amount reaches the pool (it is not shrunk to the liquidity); the pool rejects it because the
        // virtual underlying balance (bit 252) underflows, observed as Panic(0x11) in a -vvvv run
        vm.expectCall(
            address(_POOL),
            abi.encodeWithSignature("withdraw(address,uint256,address)", _USDC, uint256(5_000e6), _plasmaVault),
            1
        );
        vm.prank(_ATOMIST);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", uint256(0x11)));
        PlasmaVault(_plasmaVault).execute(exits);
    }

    /// @notice The reserve liquidity is borrowed down to 0 (bit 252): the instant entry is skipped without a pool
    ///         withdraw call and without an exit or failure event, and the next entry pays the user
    function test_withdrawSkipsAaveAtZeroLiquidityAndPaysFromNextEntry() public {
        _allocate(6_000e6, 4_000e6);
        _lowerAaveLiquidity(0);
        assertEq(_virtualBalance(), 0, "Aave USDC virtual balance is zero");
        assertGt(ERC20(_aToken()).balanceOf(_plasmaVault), 0, "the position is still there");

        // selector-level match: any pool withdraw call, whatever the amount, would fail this expectation
        vm.expectCall(address(_POOL), abi.encodeWithSignature("withdraw(address,uint256,address)"), 0);
        vm.recordLogs();
        vm.prank(_USER);
        PlasmaVault(_plasmaVault).withdraw(1_000e6, _USER, _USER);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(ERC20(_USDC).balanceOf(_USER), 1_000e6, "user paid by the next entry");
        assertEq(_aaveExitAmount(logs), 0, "no Aave exit event");
        assertEq(_aaveFailedCount(logs), 0, "no ExitFailed event");
    }

    // ============ helpers ============

    function _aToken() private view returns (address aToken) {
        (bool ok, bytes memory data) = _dataProvider().staticcall(
            abi.encodeWithSignature("getReserveTokensAddresses(address)", _USDC)
        );
        require(ok, "getReserveTokensAddresses failed");
        (aToken, , ) = abi.decode(data, (address, address, address));
    }

    function _dataProvider() private pure returns (address) {
        return 0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3;
    }

    function _virtualBalance() private view returns (uint256) {
        /* solhint-disable avoid-low-level-calls */
        (bool ok, bytes memory data) = address(_POOL).staticcall(
            abi.encodeWithSignature("getVirtualUnderlyingBalance(address)", _USDC)
        );
        /* solhint-enable avoid-low-level-calls */
        require(ok, "getVirtualUnderlyingBalance failed");
        return abi.decode(data, (uint128));
    }

    /// @dev Reserve configuration bitmap of USDC (read by signature: the test does not depend on a local interface)
    function _configuration() private view returns (uint256) {
        /* solhint-disable avoid-low-level-calls */
        (bool ok, bytes memory data) = address(_POOL).staticcall(
            abi.encodeWithSignature("getConfiguration(address)", _USDC)
        );
        /* solhint-enable avoid-low-level-calls */
        require(ok, "getConfiguration failed");
        return abi.decode(data, (uint256));
    }

    function _aaveExitAmount(Vm.Log[] memory logs_) private view returns (uint256 total) {
        bytes32 topic = keccak256("AaveV3SupplyFuseExit(address,address,uint256)");
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == _plasmaVault && logs_[i].topics[0] == topic) {
                (, , uint256 amount) = abi.decode(logs_[i].data, (address, address, uint256));
                total += amount;
            }
        }
    }

    function _aaveFailedCount(Vm.Log[] memory logs_) private view returns (uint256 count) {
        bytes32 topic = keccak256("AaveV3SupplyFuseExitFailed(address,address,uint256)");
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == _plasmaVault && logs_[i].topics[0] == topic) ++count;
        }
    }

    /// @dev Allocates idle USDC to Aave (first instant withdraw entry) and optionally to the ERC4626 venue (second)
    function _allocate(uint256 aaveAmount_, uint256 erc4626Amount_) private {
        uint256 count = erc4626Amount_ > 0 ? 2 : 1;
        FuseAction[] memory enter = new FuseAction[](count);
        enter[0] = FuseAction({
            fuse: _aaveSupplyFuse,
            data: abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                AaveV3SupplyFuseEnterData({asset: _USDC, amount: aaveAmount_, userEModeCategoryId: 1000})
            )
        });
        if (erc4626Amount_ > 0) {
            enter[1] = FuseAction({
                fuse: _erc4626SupplyFuse,
                data: abi.encodeWithSignature(
                    "enter((address,uint256,uint256))",
                    Erc4626SupplyFuseEnterData({
                        vault: _ERC4626_USDC_VAULT,
                        vaultAssetAmount: erc4626Amount_,
                        minSharesOut: 0
                    })
                )
            });
        }
        vm.prank(_ATOMIST);
        PlasmaVault(_plasmaVault).execute(enter);
        assertEq(ERC20(_USDC).balanceOf(_plasmaVault), 10_000e6 - aaveAmount_ - erc4626Amount_, "idle USDC");

        InstantWithdrawalFusesParamsStruct[] memory iw = new InstantWithdrawalFusesParamsStruct[](count);
        iw[0] = InstantWithdrawalFusesParamsStruct({fuse: _aaveSupplyFuse, params: _iwParams(_USDC)});
        if (erc4626Amount_ > 0) {
            iw[1] = InstantWithdrawalFusesParamsStruct({
                fuse: _erc4626SupplyFuse,
                params: _iwParams(_ERC4626_USDC_VAULT)
            });
        }
        vm.prank(_ATOMIST);
        PlasmaVaultGovernance(_plasmaVault).configureInstantWithdrawalFuses(iw);
    }

    function _iwParams(address asset_) private pure returns (bytes32[] memory params) {
        params = new bytes32[](2);
        params[0] = bytes32(0);
        params[1] = PlasmaVaultConfigLib.addressToBytes32(asset_);
    }

    /// @dev An unrelated borrower posts WETH collateral (a dealt token, not an aToken, so the pool books it as a real
    ///      supply) and borrows USDC until `liquidityLeft_` remains. Aave lowers the virtual balance on every borrow,
    ///      so this is the real way to reduce the reserve liquidity. The USDC borrow cap and the WETH supply cap are
    ///      removed through the real pool configurator (the pool admin is pranked on the fork).
    function _lowerAaveLiquidity(uint256 liquidityLeft_) private {
        _removeCaps();

        address borrower = makeAddr("aaveBorrower");
        uint256 wEth = 150_000e18;
        deal(_W_ETH, borrower, wEth);

        uint256 borrowAmount = _virtualBalance() - liquidityLeft_;

        vm.startPrank(borrower);
        ERC20(_W_ETH).approve(address(_POOL), wEth);
        _POOL.supply(_W_ETH, wEth, borrower, 0);
        _POOL.borrow(_USDC, borrowAmount, 2, 0, borrower);
        vm.stopPrank();
    }

    /// @dev Pranks the ACL admin to make this contract a pool admin, then lifts the caps via the pool configurator
    function _removeCaps() private {
        /* solhint-disable avoid-low-level-calls */
        (bool okAdmin, bytes memory adminData) = _AAVE_PROVIDER.staticcall(abi.encodeWithSignature("getACLAdmin()"));
        (bool okAcl, bytes memory aclData) = _AAVE_PROVIDER.staticcall(abi.encodeWithSignature("getACLManager()"));
        (bool okCfg, bytes memory cfgData) = _AAVE_PROVIDER.staticcall(
            abi.encodeWithSignature("getPoolConfigurator()")
        );
        require(okAdmin && okAcl && okCfg, "provider reads failed");
        address aclAdmin = abi.decode(adminData, (address));
        address aclManager = abi.decode(aclData, (address));
        address configurator = abi.decode(cfgData, (address));

        vm.prank(aclAdmin);
        (bool okRole, ) = aclManager.call(abi.encodeWithSignature("addPoolAdmin(address)", address(this)));
        require(okRole, "addPoolAdmin failed");

        (bool okBorrow, ) = configurator.call(abi.encodeWithSignature("setBorrowCap(address,uint256)", _USDC, 0));
        (bool okSupply, ) = configurator.call(abi.encodeWithSignature("setSupplyCap(address,uint256)", _W_ETH, 0));
        require(okBorrow && okSupply, "setCap failed");
        /* solhint-enable avoid-low-level-calls */
    }

    function _createPriceOracle() private returns (address) {
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(_CHAINLINK_REGISTRY);
        PriceOracleMiddleware priceOracle = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );
        address[] memory assets = new address[](1);
        address[] memory sources = new address[](1);
        assets[0] = _USDC;
        sources[0] = _USDC_USD_CHAINLINK;
        priceOracle.setAssetsPricesSources(assets, sources);
        return address(priceOracle);
    }

    function _setupFuses() private returns (address[] memory fuses) {
        _aaveSupplyFuse = address(new AaveV3SupplyFuse(IporFusionMarkets.AAVE_V3, _AAVE_PROVIDER));
        _erc4626SupplyFuse = address(new Erc4626SupplyFuse(IporFusionMarkets.ERC4626_0001));
        fuses = new address[](2);
        fuses[0] = _aaveSupplyFuse;
        fuses[1] = _erc4626SupplyFuse;
    }

    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses) {
        balanceFuses = new MarketBalanceFuseConfig[](3);
        balanceFuses[0] = MarketBalanceFuseConfig(
            IporFusionMarkets.AAVE_V3,
            address(new AaveV3BalanceFuse(IporFusionMarkets.AAVE_V3, _AAVE_PROVIDER))
        );
        balanceFuses[1] = MarketBalanceFuseConfig(
            IporFusionMarkets.ERC4626_0001,
            address(new Erc4626BalanceFuse(IporFusionMarkets.ERC4626_0001))
        );
        balanceFuses[2] = MarketBalanceFuseConfig(
            IporFusionMarkets.ERC20_VAULT_BALANCE,
            address(new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE))
        );
    }

    function _setupMarketConfigs() private pure returns (MarketSubstratesConfig[] memory marketConfigs) {
        marketConfigs = new MarketSubstratesConfig[](3);
        bytes32[] memory usdc = new bytes32[](1);
        usdc[0] = PlasmaVaultConfigLib.addressToBytes32(_USDC);
        marketConfigs[0] = MarketSubstratesConfig(IporFusionMarkets.AAVE_V3, usdc);
        bytes32[] memory vaults = new bytes32[](1);
        vaults[0] = PlasmaVaultConfigLib.addressToBytes32(_ERC4626_USDC_VAULT);
        marketConfigs[1] = MarketSubstratesConfig(IporFusionMarkets.ERC4626_0001, vaults);
        marketConfigs[2] = MarketSubstratesConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, usdc);
    }

    function _initAccessManager() private {
        address[] memory initAddress = new address[](2);
        initAddress[0] = address(this);
        initAddress[1] = _ATOMIST;

        address[] memory whitelist = new address[](1);
        whitelist[0] = _USER;

        DataForInitialization memory data = DataForInitialization({
            isPublic: false,
            iporDaos: initAddress,
            admins: initAddress,
            owners: initAddress,
            atomists: initAddress,
            alphas: initAddress,
            whitelist: whitelist,
            guardians: initAddress,
            fuseManagers: initAddress,
            claimRewards: initAddress,
            transferRewardsManagers: initAddress,
            configInstantWithdrawalFusesManagers: initAddress,
            updateMarketsBalancesAccounts: initAddress,
            updateRewardsBalanceAccounts: initAddress,
            withdrawManagerRequestFeeManagers: initAddress,
            withdrawManagerWithdrawFeeManagers: initAddress,
            priceOracleMiddlewareManagers: initAddress,
            preHooksManagers: initAddress,
            plasmaVaultAddress: PlasmaVaultAddress({
                plasmaVault: _plasmaVault,
                accessManager: _accessManager,
                rewardsClaimManager: address(0x123),
                withdrawManager: _withdrawManager,
                feeManager: FeeAccount(PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeAccount)
                    .FEE_MANAGER(),
                contextManager: address(0x123),
                priceOracleMiddlewareManager: address(0x123)
            })
        });

        InitializationData memory initializationData = IporFusionAccessManagerInitializerLibV1
            .generateInitializeIporPlasmaVault(data);
        vm.startPrank(_ATOMIST);
        IporFusionAccessManager(_accessManager).initialize(initializationData);
        vm.stopPrank();
    }
}
