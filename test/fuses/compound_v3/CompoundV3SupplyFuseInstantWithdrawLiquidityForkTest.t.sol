// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {
    CompoundV3SupplyFuse,
    CompoundV3SupplyFuseEnterData
} from "../../../contracts/fuses/compound_v3/CompoundV3SupplyFuse.sol";
import {CompoundV3BalanceFuse} from "../../../contracts/fuses/compound_v3/CompoundV3BalanceFuse.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";
import {Erc4626SupplyFuse, Erc4626SupplyFuseEnterData} from "../../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {Erc4626BalanceFuse} from "../../../contracts/fuses/erc4626/Erc4626BalanceFuse.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
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

/// @title CompoundV3SupplyFuseInstantWithdrawLiquidityForkTest
/// @notice IL-9562: the instant withdraw path of CompoundV3SupplyFuse caps a BASE token request at the base tokens
///         the Comet holds (free liquidity), so a partly liquid Comet pays what it can and the next instant withdraw
///         fuse takes the rest. Collateral is not lent out and stays uncapped; so does the ALPHA exit. Real cUSDCv3
///         on Ethereum, a real PlasmaVault and the real withdrawFromMarkets loop. The Comet base liquidity is lowered
///         with `deal` on the Comet's USDC balance (a real borrow needs collateral that the fork cannot supply).
contract CompoundV3SupplyFuseInstantWithdrawLiquidityForkTest is Test {
    address private constant _COMET = 0xc3d688B66703497DAA19211EEdff47f25384cdc3;
    address private constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant _W_ETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    /// @dev Real liquid ERC4626 USDC venue used as the next instant withdraw entry (Steakhouse USDC MetaMorpho vault)
    address private constant _ERC4626_USDC_VAULT = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;

    address private constant _CHAINLINK_REGISTRY = 0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf;
    address private constant _USDC_USD_CHAINLINK = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;

    address private constant _ATOMIST = address(0x111111);
    address private constant _USER = address(0x222222);

    uint256 private constant _COMPOUND_V3_MARKET_ID = 1;

    /// @dev Own fork block (recent): shared blocks share one backend
    uint256 public constant FORK_BLOCK = 26390000;

    address private _plasmaVault;
    address private _accessManager;
    address private _withdrawManager;
    address private _compoundSupplyFuse;
    address private _erc4626SupplyFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), FORK_BLOCK);

        address priceOracle = _createPriceOracle();
        _accessManager = address(new IporFusionAccessManager(_ATOMIST, 0));
        _withdrawManager = address(new WithdrawManager(_accessManager));

        vm.startPrank(_ATOMIST);
        _plasmaVault = address(PlasmaVaultCloneLib.newPlasmaVault());
        PlasmaVault(_plasmaVault).proxyInitialize(
            PlasmaVaultInitData({
                assetName: "Compound V3 IW liquidity",
                assetSymbol: "c3IWl",
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

    /// @notice Comet (liquidity 3,000, position 6,000) is the first entry, the ERC4626 venue (position 4,000) the
    ///         second: the withdrawal draws the Comet liquidity and the rest from the second entry instead of
    ///         reverting (on the base the Comet entry pays 0 and the second entry cannot cover 5,000 alone)
    function test_withdrawTakesPartialLiquidityFromCometAndRestFromNextEntry() public {
        _allocate(6_000e6, 4_000e6);
        _setCometLiquidity(3_000e6);
        assertEq(_liquidity(), 3_000e6, "Comet USDC liquidity");
        assertGt(_cometBalanceOf(_plasmaVault), 3_000e6, "the position exceeds the liquidity");

        vm.recordLogs();
        vm.prank(_USER);
        PlasmaVault(_plasmaVault).withdraw(5_000e6, _USER, _USER);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(ERC20(_USDC).balanceOf(_USER), 5_000e6, "user received the payout");
        assertEq(_exitAmount(logs), 3_000e6, "Comet pays its whole liquidity");
        assertEq(_failedCount(logs), 0, "no ExitFailed event");
        assertEq(_liquidity(), 0, "Comet liquidity fully used");
    }

    /// @notice A Comet with no base liquidity is skipped: the fuse does not call it and emits no event, the next
    ///         entry pays the whole withdrawal (on the base the Comet call reverts and the fuse emits ExitFailed)
    function test_zeroLiquidityDoesNotCallCometAndNextEntryPays() public {
        _allocate(6_000e6, 4_000e6);
        _setCometLiquidity(0);

        vm.expectCall(_COMET, abi.encodeWithSignature("withdraw(address,uint256)"), 0);
        vm.recordLogs();
        vm.prank(_USER);
        PlasmaVault(_plasmaVault).withdraw(3_000e6, _USER, _USER);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(ERC20(_USDC).balanceOf(_USER), 3_000e6, "user received the payout from the next entry");
        assertEq(_exitAmount(logs), 0, "no Comet exit event");
        assertEq(_failedCount(logs), 0, "no ExitFailed event");
    }

    /// @notice Pins D-010: the ALPHA exit is not capped at the liquidity, a request above it reverts
    function test_alphaExitAboveLiquidityStillReverts() public {
        _allocate(6_000e6, 4_000e6);
        _setCometLiquidity(3_000e6);

        FuseAction[] memory exits = new FuseAction[](1);
        exits[0] = FuseAction({
            fuse: _compoundSupplyFuse,
            data: abi.encodeWithSignature("exit((address,uint256))", _USDC, uint256(5_000e6))
        });
        // the full ALPHA amount reaches Comet (it is not shrunk to the liquidity); Comet rejects it because the USDC
        // transfer exceeds its balance, observed as Error("ERC20: transfer amount exceeds balance") in a -vvvv run
        vm.expectCall(_COMET, abi.encodeWithSignature("withdraw(address,uint256)", _USDC, uint256(5_000e6)), 1);
        vm.prank(_ATOMIST);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "ERC20: transfer amount exceeds balance"));
        PlasmaVault(_plasmaVault).execute(exits);
    }

    /// @notice A COLLATERAL asset is not lent out, so its instant withdraw is not capped by the Comet base
    ///         liquidity: with the Comet base balance at 0 the WETH is still withdrawn in full
    function test_collateralInstantWithdrawIsNotCapped() public {
        CompoundV3SupplyFuse fuse = new CompoundV3SupplyFuse(_COMPOUND_V3_MARKET_ID, _COMET);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(0x0));
        address[] memory assets = new address[](2);
        assets[0] = _USDC;
        assets[1] = _W_ETH;
        vaultMock.grantAssetsToMarket(_COMPOUND_V3_MARKET_ID, assets);

        uint256 wEthAmount = 10e18;
        deal(_W_ETH, address(vaultMock), wEthAmount);
        vaultMock.enterCompoundV3Supply(CompoundV3SupplyFuseEnterData({asset: _W_ETH, amount: wEthAmount}));
        assertEq(ERC20(_W_ETH).balanceOf(address(vaultMock)), 0, "WETH supplied as collateral");

        _setCometLiquidity(0);

        bytes32[] memory params = new bytes32[](2);
        params[0] = bytes32(wEthAmount);
        params[1] = PlasmaVaultConfigLib.addressToBytes32(_W_ETH);

        vm.expectCall(_COMET, abi.encodeWithSignature("withdraw(address,uint256)", _W_ETH, wEthAmount), 1);
        vm.recordLogs();
        vaultMock.instantWithdraw(params);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(ERC20(_W_ETH).balanceOf(address(vaultMock)), wEthAmount, "full collateral withdrawn");
        assertEq(_failedCount(logs), 0, "no ExitFailed event");
    }

    // ============ helpers ============

    function _cometBalanceOf(address account_) private view returns (uint256) {
        (bool ok, bytes memory data) = _COMET.staticcall(abi.encodeWithSignature("balanceOf(address)", account_));
        require(ok, "comet balanceOf failed");
        return abi.decode(data, (uint256));
    }

    /// @dev Comet free base liquidity: the base token held by the Comet
    function _liquidity() private view returns (uint256) {
        return ERC20(_USDC).balanceOf(_COMET);
    }

    function _setCometLiquidity(uint256 liquidity_) private {
        deal(_USDC, _COMET, liquidity_);
    }

    function _exitAmount(Vm.Log[] memory logs_) private view returns (uint256 total) {
        bytes32 topic = keccak256("CompoundV3SupplyFuseExit(address,address,address,uint256)");
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == _plasmaVault && logs_[i].topics[0] == topic) {
                (, , , uint256 amount) = abi.decode(logs_[i].data, (address, address, address, uint256));
                total += amount;
            }
        }
    }

    function _failedCount(Vm.Log[] memory logs_) private view returns (uint256 count) {
        bytes32 topic = keccak256("CompoundV3SupplyFuseExitFailed(address,address,address,uint256)");
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].topics.length > 0 && logs_[i].topics[0] == topic) ++count;
        }
    }

    /// @dev Allocates idle USDC to Compound V3 (first instant withdraw entry) and the ERC4626 venue (second)
    function _allocate(uint256 compoundAmount_, uint256 erc4626Amount_) private {
        FuseAction[] memory enter = new FuseAction[](2);
        enter[0] = FuseAction({
            fuse: _compoundSupplyFuse,
            data: abi.encodeWithSignature(
                "enter((address,uint256))",
                CompoundV3SupplyFuseEnterData({asset: _USDC, amount: compoundAmount_})
            )
        });
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
        vm.prank(_ATOMIST);
        PlasmaVault(_plasmaVault).execute(enter);
        assertEq(ERC20(_USDC).balanceOf(_plasmaVault), 10_000e6 - compoundAmount_ - erc4626Amount_, "idle USDC");

        InstantWithdrawalFusesParamsStruct[] memory iw = new InstantWithdrawalFusesParamsStruct[](2);
        iw[0] = InstantWithdrawalFusesParamsStruct({fuse: _compoundSupplyFuse, params: _iwParams(_USDC)});
        iw[1] = InstantWithdrawalFusesParamsStruct({fuse: _erc4626SupplyFuse, params: _iwParams(_ERC4626_USDC_VAULT)});
        vm.prank(_ATOMIST);
        PlasmaVaultGovernance(_plasmaVault).configureInstantWithdrawalFuses(iw);
    }

    function _iwParams(address asset_) private pure returns (bytes32[] memory params) {
        params = new bytes32[](2);
        params[0] = bytes32(0);
        params[1] = PlasmaVaultConfigLib.addressToBytes32(asset_);
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
        _compoundSupplyFuse = address(new CompoundV3SupplyFuse(_COMPOUND_V3_MARKET_ID, _COMET));
        _erc4626SupplyFuse = address(new Erc4626SupplyFuse(IporFusionMarkets.ERC4626_0001));
        fuses = new address[](2);
        fuses[0] = _compoundSupplyFuse;
        fuses[1] = _erc4626SupplyFuse;
    }

    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses) {
        balanceFuses = new MarketBalanceFuseConfig[](3);
        balanceFuses[0] = MarketBalanceFuseConfig(
            _COMPOUND_V3_MARKET_ID,
            address(new CompoundV3BalanceFuse(_COMPOUND_V3_MARKET_ID, _COMET))
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
        marketConfigs[0] = MarketSubstratesConfig(_COMPOUND_V3_MARKET_ID, usdc);
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
