// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {CompoundV2SupplyFuse} from "../../../contracts/fuses/compound_v2/CompoundV2SupplyFuse.sol";
import {CompoundV2BalanceFuse} from "../../../contracts/fuses/compound_v2/CompoundV2BalanceFuse.sol";
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

/// @title CompoundV2SupplyFuseInstantWithdrawCashForkTest
/// @notice IL-9561: the instant withdraw path of CompoundV2SupplyFuse caps each request at the cToken cash
///         (getCash), so a partly liquid market pays what it can and the next instant withdraw fuse takes the rest.
///         Real cUSDC on an Ethereum fork, a real PlasmaVault and the real withdrawFromMarkets loop. Borrowing and
///         minting are paused on cUSDC at this block, so the cash is lowered with `deal` of the underlying held by
///         the cToken (a real borrow is impossible) and the vault position is created by `deal` of cUSDC after the
///         cash change, sized with the post-change exchange rate.
contract CompoundV2SupplyFuseInstantWithdrawCashForkTest is Test {
    address private constant _CUSDC = 0x39AA39c021dfbaE8faC545936693aC917d5E7563;
    address private constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    /// @dev Real liquid ERC4626 USDC venue used as the next instant withdraw entry (Steakhouse USDC MetaMorpho vault)
    address private constant _ERC4626_USDC_VAULT = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;

    address private constant _CHAINLINK_REGISTRY = 0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf;
    address private constant _USDC_USD_CHAINLINK = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;

    address private constant _ATOMIST = address(0x111111);
    address private constant _USER = address(0x222222);

    uint256 private constant _COMPOUND_V2_MARKET_ID = 1;

    /// @dev Own fork block (recent): shared blocks share one backend
    uint256 public constant FORK_BLOCK = 26389106;

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
                assetName: "Compound V2 IW cash",
                assetSymbol: "c2IWc",
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

    /// @notice cUSDC (cash 3,000, position 6,000) is the first entry, the ERC4626 venue (position 4,000) the
    ///         second: the withdrawal draws the cash and the rest from the second entry instead of reverting (on the
    ///         base the cUSDC redeem fails with an error code, pays 0, and the second entry cannot cover 5,000)
    function test_withdrawTakesPartialCashFromCompoundAndRestFromNextEntry() public {
        _allocate(6_000e6, 4_000e6, 3_000e6);
        assertEq(_cash(), 3_000e6, "cUSDC cash");
        assertGt(_position(), _cash(), "the position exceeds the cash");

        vm.recordLogs();
        vm.prank(_USER);
        PlasmaVault(_plasmaVault).withdraw(5_000e6, _USER, _USER);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(ERC20(_USDC).balanceOf(_USER), 5_000e6, "user received the payout");
        assertEq(_compoundExitAmount(logs), 3_000e6, "cUSDC pays its whole cash");
        assertEq(_compoundFailedCount(logs), 0, "no ExitFailed event");
        assertEq(_cash(), 0, "cash fully used");
    }

    /// @notice A market with no cash is skipped: the fuse does not call redeemUnderlying and emits no event, the next
    ///         entry pays the whole withdrawal (on the base the redeem call is made and fails with ExitFailed)
    function test_zeroCashDoesNotCallCTokenAndNextEntryPays() public {
        _allocate(6_000e6, 4_000e6, 0);
        assertEq(_cash(), 0, "cUSDC cash");

        // Selector-level: the vault requests amount + WITHDRAW_FROM_MARKETS_OFFSET, so exact calldata could never match.
        vm.expectCall(_CUSDC, abi.encodeWithSelector(bytes4(keccak256("redeemUnderlying(uint256)"))), 0);
        vm.recordLogs();
        vm.prank(_USER);
        PlasmaVault(_plasmaVault).withdraw(3_000e6, _USER, _USER);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(ERC20(_USDC).balanceOf(_USER), 3_000e6, "user received the payout from the next entry");
        assertEq(_compoundExitAmount(logs), 0, "no cUSDC exit event");
        assertEq(_compoundFailedCount(logs), 0, "no ExitFailed event");
    }

    /// @notice Pins D-010 (Compound V2 is exempt from "reverts above liquidity"): the ALPHA exit is not capped at the
    ///         cash, redeemUnderlying is called with the full amount, the cToken answers with an error code, the fuse
    ///         emits ExitFailed and does not revert, nothing is withdrawn (behaviour unchanged, out of scope)
    function test_alphaExitAboveCashIsUncappedAndEmitsExitFailed() public {
        _allocate(6_000e6, 4_000e6, 3_000e6);
        uint256 idleBefore = ERC20(_USDC).balanceOf(_plasmaVault);

        FuseAction[] memory exits = new FuseAction[](1);
        exits[0] = FuseAction({
            fuse: _compoundSupplyFuse,
            data: abi.encodeWithSignature("exit((address,uint256))", _USDC, uint256(5_000e6))
        });
        vm.expectCall(_CUSDC, abi.encodeWithSignature("redeemUnderlying(uint256)", uint256(5_000e6)));
        vm.recordLogs();
        vm.prank(_ATOMIST);
        PlasmaVault(_plasmaVault).execute(exits);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_compoundFailedCount(logs), 1, "ExitFailed emitted");
        assertEq(_compoundExitAmount(logs), 0, "no successful exit");
        assertEq(ERC20(_USDC).balanceOf(_plasmaVault), idleBefore, "nothing withdrawn");
        assertEq(_cash(), 3_000e6, "cash untouched");
    }

    // ============ helpers ============

    function _cash() private view returns (uint256) {
        return ERC20(_USDC).balanceOf(_CUSDC);
    }

    /// @dev Vault position in underlying, from the stored exchange rate (accrual happens in the same block)
    function _position() private returns (uint256) {
        (bool ok, bytes memory data) = _CUSDC.call(
            abi.encodeWithSignature("balanceOfUnderlying(address)", _plasmaVault)
        );
        require(ok, "balanceOfUnderlying failed");
        return abi.decode(data, (uint256));
    }

    function _compoundExitAmount(Vm.Log[] memory logs_) private view returns (uint256 total) {
        bytes32 topic = keccak256("CompoundV2SupplyExitFuse(address,address,address,uint256)");
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == _plasmaVault && logs_[i].topics[0] == topic) {
                (, , , uint256 amount) = abi.decode(logs_[i].data, (address, address, address, uint256));
                total += amount;
            }
        }
    }

    function _compoundFailedCount(Vm.Log[] memory logs_) private view returns (uint256 count) {
        bytes32 topic = keccak256("CompoundV2SupplyExitFailed(address,address,address,uint256)");
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == _plasmaVault && logs_[i].topics[0] == topic) ++count;
        }
    }

    /// @dev Sets up the vault with `compoundAmount_` of cUSDC position and `erc4626Amount_` in the ERC4626 venue
    ///      (total 10,000 USDC) and lowers the cUSDC cash to `cash_`. The cash is lowered first, then the cUSDC
    ///      position is dealt at the resulting exchange rate (the cToken is paused for mint and borrow).
    function _allocate(uint256 compoundAmount_, uint256 erc4626Amount_, uint256 cash_) private {
        FuseAction[] memory enter = new FuseAction[](1);
        enter[0] = FuseAction({
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

        deal(_USDC, _CUSDC, cash_);
        (bool ok, bytes memory data) = _CUSDC.call(abi.encodeWithSignature("exchangeRateCurrent()"));
        require(ok, "exchangeRateCurrent failed");
        uint256 exchangeRate = abi.decode(data, (uint256));
        // the idle USDC left after the ERC4626 entry becomes the cUSDC position
        deal(_USDC, _plasmaVault, 0);
        deal(_CUSDC, _plasmaVault, (compoundAmount_ * 1e18) / exchangeRate + 1);

        uint256[] memory markets = new uint256[](3);
        markets[0] = _COMPOUND_V2_MARKET_ID;
        markets[1] = IporFusionMarkets.ERC4626_0001;
        markets[2] = IporFusionMarkets.ERC20_VAULT_BALANCE;
        vm.prank(_ATOMIST);
        PlasmaVault(_plasmaVault).updateMarketsBalances(markets);

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
        _compoundSupplyFuse = address(new CompoundV2SupplyFuse(_COMPOUND_V2_MARKET_ID));
        _erc4626SupplyFuse = address(new Erc4626SupplyFuse(IporFusionMarkets.ERC4626_0001));
        fuses = new address[](2);
        fuses[0] = _compoundSupplyFuse;
        fuses[1] = _erc4626SupplyFuse;
    }

    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses) {
        balanceFuses = new MarketBalanceFuseConfig[](3);
        balanceFuses[0] = MarketBalanceFuseConfig(
            _COMPOUND_V2_MARKET_ID,
            address(new CompoundV2BalanceFuse(_COMPOUND_V2_MARKET_ID))
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
        bytes32[] memory cTokens = new bytes32[](1);
        cTokens[0] = PlasmaVaultConfigLib.addressToBytes32(_CUSDC);
        marketConfigs[0] = MarketSubstratesConfig(_COMPOUND_V2_MARKET_ID, cTokens);
        bytes32[] memory vaults = new bytes32[](1);
        vaults[0] = PlasmaVaultConfigLib.addressToBytes32(_ERC4626_USDC_VAULT);
        marketConfigs[1] = MarketSubstratesConfig(IporFusionMarkets.ERC4626_0001, vaults);
        bytes32[] memory usdc = new bytes32[](1);
        usdc[0] = PlasmaVaultConfigLib.addressToBytes32(_USDC);
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
