// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IMorpho, MarketParams, Market, Id} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morpho-org/morpho-blue/src/libraries/MarketParamsLib.sol";

import {MorphoSupplyFuse, MorphoSupplyFuseEnterData} from "../../../contracts/fuses/morpho/MorphoSupplyFuse.sol";
import {
    MorphoSupplyWithCallBackDataFuse,
    MorphoSupplyFuseEnterData as CallbackEnterData
} from "../../../contracts/fuses/morpho/MorphoSupplyWithCallBackDataFuse.sol";
import {MorphoBalanceFuse} from "../../../contracts/fuses/morpho/MorphoBalanceFuse.sol";
import {CallbackHandlerMorpho} from "../../../contracts/handlers/callbacks/CallbackHandlerMorpho.sol";
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

/// @dev Morpho oracle with a fixed price (collateral priced in loan token, scaled by 1e36)
contract MorphoSupplyInstantLiquidityMockOracle {
    uint256 public immutable price;

    constructor(uint256 price_) {
        price = price_;
    }
}

/// @title MorphoSupplyFuseInstantWithdrawLiquidityBase
/// @notice IL-9560: the instant withdraw path of the Morpho supply fuses caps each request at the free liquidity of the
///         Morpho Blue market (totalSupplyAssets - totalBorrowAssets), so a partly borrowed market pays what it has and
///         the next fuse in the list takes the rest. Real Morpho Blue on an Ethereum fork, two fresh USDC markets
///         (WETH collateral, mock oracle, no IRM so no interest), a real PlasmaVault and the real withdrawFromMarkets
///         loop. The same scenarios run for both fuses (see the two concrete suites below).
abstract contract MorphoSupplyFuseInstantWithdrawLiquidityBase is Test {
    address internal constant _MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address internal constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant _W_ETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant _CHAINLINK_REGISTRY = 0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf;
    address private constant _USDC_USD_CHAINLINK = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address private constant _ETH_USD_CHAINLINK = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    address private constant _ATOMIST = address(0x111111);
    address private constant _USER = address(0x222222);

    /// @dev LLTV enabled on Morpho Blue mainnet; the IRM is address(0) (no interest, exact accounting)
    uint256 private constant _LLTV = 0.86e18;
    /// @dev 1 WETH = 3000 USDC in the Morpho oracle (price scaled by 1e36 and by the decimals difference 6 - 18)
    uint256 private constant _ORACLE_PRICE = 3_000e24;

    address internal _plasmaVault;
    address internal _accessManager;
    address internal _withdrawManager;
    address internal _supplyFuse;

    MarketParams internal _marketA;
    MarketParams internal _marketB;
    bytes32 internal _idA;
    bytes32 internal _idB;

    /// @dev Own fork block per suite (shared blocks share one backend and leak vm.warp between suites)
    function _forkBlock() internal pure virtual returns (uint256);

    function _deploySupplyFuse() internal virtual returns (address);

    /// @dev Calldata of the fuse's enter(...) for the given market and amount
    function _enterCall(bytes32 morphoMarketId_, uint256 amount_) internal pure virtual returns (bytes memory);

    function _exitSelectorSignature() internal pure returns (string memory) {
        return "exit((bytes32,uint256))";
    }

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), _forkBlock());

        _createMarkets();
        address priceOracle = _createPriceOracle();
        _accessManager = address(new IporFusionAccessManager(_ATOMIST, 0));
        _withdrawManager = address(new WithdrawManager(_accessManager));

        vm.startPrank(_ATOMIST);
        _plasmaVault = address(PlasmaVaultCloneLib.newPlasmaVault());
        PlasmaVault(_plasmaVault).proxyInitialize(
            PlasmaVaultInitData({
                assetName: "Morpho IW liquidity",
                assetSymbol: "mIWl",
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

        _supplyFuse = _deploySupplyFuse();
        address[] memory fuses = new address[](1);
        fuses[0] = _supplyFuse;

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](2);
        balanceFuses[0] = MarketBalanceFuseConfig(
            IporFusionMarkets.MORPHO,
            address(new MorphoBalanceFuse(IporFusionMarkets.MORPHO, _MORPHO))
        );
        balanceFuses[1] = MarketBalanceFuseConfig(
            IporFusionMarkets.ERC20_VAULT_BALANCE,
            address(new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE))
        );

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](1);
        bytes32[] memory tokens = new bytes32[](1);
        tokens[0] = PlasmaVaultConfigLib.addressToBytes32(_USDC);
        marketConfigs[0] = MarketSubstratesConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, tokens);

        PlasmaVaultConfigurator.setupPlasmaVault(vm, _ATOMIST, _plasmaVault, fuses, balanceFuses, marketConfigs);

        _initAccessManager();

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = _idA;
        substrates[1] = _idB;
        vm.startPrank(_ATOMIST);
        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(IporFusionMarkets.MORPHO, substrates);
        // needed by MorphoSupplyWithCallBackDataFuse.enter (Morpho calls back the vault); harmless for the other fuse
        PlasmaVaultGovernance(_plasmaVault).updateCallbackHandler(
            address(new CallbackHandlerMorpho()),
            _MORPHO,
            CallbackHandlerMorpho.onMorphoSupply.selector
        );
        vm.stopPrank();

        deal(_USDC, _USER, 20_000e6);
        vm.startPrank(_USER);
        ERC20(_USDC).approve(_plasmaVault, 20_000e6);
        PlasmaVault(_plasmaVault).deposit(20_000e6, _USER);
        vm.stopPrank();
    }

    // -------------------------------
    // Tests
    // -------------------------------

    /// @notice Market A (8,000 supplied, 5,000 borrowed: 3,000 free) is first in the list, market B is liquid. A
    ///         withdrawal of 14,000 asks A for more than its whole position: A pays its 3,000 of liquidity and B the
    ///         rest. On 69766843 the all-shares withdrawal of A failed (0) and B (12,000) could not cover the payout.
    function testShouldPayLiquidPartFromFirstMarketAndRestFromNextWhenRequestCoversPosition() external {
        _allocate(8_000e6, 12_000e6);
        _borrowFromMarketA(5_000e6);
        assertEq(_freeLiquidity(_marketA), 3_000e6, "free liquidity of market A");

        vm.recordLogs();
        vm.prank(_USER);
        PlasmaVault(_plasmaVault).withdraw(14_000e6, _USER, _USER);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(ERC20(_USDC).balanceOf(_USER), 14_000e6, "user received the payout");
        assertEq(_exitAmount(logs, _idA), 3_000e6, "market A pays its whole free liquidity");
        assertGe(_exitAmount(logs, _idB), 11_000e6, "market B pays the rest");
        assertEq(_failedCount(logs), 0, "no ExitFailed event");
        assertEq(_freeLiquidity(_marketA), 0, "market A liquidity fully used");
    }

    /// @notice Same market state, a request below the position (5,000 of 8,000): the exact assets withdrawal of A
    ///         exceeds the 3,000 of liquidity, so it is capped and B pays the remaining 2,000. On 69766843 A failed
    ///         (0) and B (12,000) paid the whole 5,000, hence this variant only proves the cap by A's exit amount.
    function testShouldCapRequestBelowPositionAtLiquidity() external {
        _allocate(8_000e6, 12_000e6);
        _borrowFromMarketA(5_000e6);

        vm.recordLogs();
        vm.prank(_USER);
        PlasmaVault(_plasmaVault).withdraw(5_000e6, _USER, _USER);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(ERC20(_USDC).balanceOf(_USER), 5_000e6, "user received the payout");
        assertEq(_exitAmount(logs, _idA), 3_000e6, "market A pays its whole free liquidity");
        assertGe(_exitAmount(logs, _idB), 2_000e6, "market B pays the rest");
        assertEq(_failedCount(logs), 0, "no ExitFailed event");
    }

    /// @notice Market A is fully borrowed (no liquidity): the fuse returns without calling Morpho, so there is neither
    ///         an Exit nor an ExitFailed event for A, and B pays the whole payout
    function testShouldSkipMarketWithoutLiquidityWithoutCallingMorpho() external {
        _allocate(8_000e6, 12_000e6);
        _borrowFromMarketA(8_000e6);
        assertEq(_freeLiquidity(_marketA), 0, "market A has no free liquidity");

        // Prefix match (selector + market A params): the vault requests amount + WITHDRAW_FROM_MARKETS_OFFSET, so exact
        // calldata could never match, and market B legitimately calls withdraw
        vm.expectCall(
            _MORPHO,
            abi.encodePacked(
                bytes4(
                    keccak256("withdraw((address,address,address,address,uint256),uint256,uint256,address,address)")
                ),
                abi.encode(_marketA)
            ),
            0
        );
        vm.recordLogs();
        vm.prank(_USER);
        PlasmaVault(_plasmaVault).withdraw(5_000e6, _USER, _USER);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(ERC20(_USDC).balanceOf(_USER), 5_000e6, "user received the payout");
        assertEq(_exitAmount(logs, _idA), 0, "no Exit event for market A");
        assertEq(_failedCount(logs), 0, "no ExitFailed event: Morpho was not called for market A");
        assertGe(_exitAmount(logs, _idB), 5_000e6, "market B pays the whole payout");
    }

    /// @notice Pins D-010: the ALPHA exit is not capped at liquidity, a request above it reverts in Morpho Blue
    function testShouldKeepAlphaExitAboveLiquidityReverting() external {
        _allocate(8_000e6, 12_000e6);
        _borrowFromMarketA(5_000e6);

        FuseAction[] memory exits = new FuseAction[](1);
        exits[0] = FuseAction({
            fuse: _supplyFuse,
            data: abi.encodeWithSignature(_exitSelectorSignature(), _idA, uint256(5_000e6))
        });
        vm.prank(_ATOMIST);
        vm.expectRevert(bytes("insufficient liquidity"));
        PlasmaVault(_plasmaVault).execute(exits);
    }

    // -------------------------------
    // Helpers
    // -------------------------------

    /// @dev Moves all idle USDC into the two markets and configures the instant withdraw list [A, B]
    function _allocate(uint256 amountA_, uint256 amountB_) private {
        FuseAction[] memory enter = new FuseAction[](2);
        enter[0] = FuseAction({fuse: _supplyFuse, data: _enterCall(_idA, amountA_)});
        enter[1] = FuseAction({fuse: _supplyFuse, data: _enterCall(_idB, amountB_)});
        vm.prank(_ATOMIST);
        PlasmaVault(_plasmaVault).execute(enter);
        assertEq(ERC20(_USDC).balanceOf(_plasmaVault), 0, "no idle USDC");

        InstantWithdrawalFusesParamsStruct[] memory iw = new InstantWithdrawalFusesParamsStruct[](2);
        iw[0] = InstantWithdrawalFusesParamsStruct({fuse: _supplyFuse, params: _iwParams(_idA)});
        iw[1] = InstantWithdrawalFusesParamsStruct({fuse: _supplyFuse, params: _iwParams(_idB)});
        vm.prank(_ATOMIST);
        PlasmaVaultGovernance(_plasmaVault).configureInstantWithdrawalFuses(iw);
    }

    function _iwParams(bytes32 morphoMarketId_) private pure returns (bytes32[] memory params) {
        params = new bytes32[](2);
        params[0] = bytes32(0);
        params[1] = morphoMarketId_;
    }

    /// @dev A real borrower posts WETH collateral and borrows USDC from market A (the vault's position is untouched)
    function _borrowFromMarketA(uint256 amount_) private {
        address borrower = makeAddr("borrower");
        deal(_W_ETH, borrower, 100e18);
        vm.startPrank(borrower);
        ERC20(_W_ETH).approve(_MORPHO, type(uint256).max);
        IMorpho(_MORPHO).supplyCollateral(_marketA, 100e18, borrower, "");
        IMorpho(_MORPHO).borrow(_marketA, amount_, 0, borrower, borrower);
        vm.stopPrank();
    }

    function _freeLiquidity(MarketParams memory market_) private view returns (uint256) {
        Market memory market = IMorpho(_MORPHO).market(MarketParamsLib.id(market_));
        return market.totalSupplyAssets - market.totalBorrowAssets;
    }

    /// @dev Sum of MorphoSupplyFuseExit amounts emitted by the vault for the given Morpho market
    function _exitAmount(Vm.Log[] memory logs_, bytes32 morphoMarketId_) private view returns (uint256 total) {
        bytes32 topic = keccak256("MorphoSupplyFuseExit(address,address,bytes32,uint256)");
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == _plasmaVault && logs_[i].topics[0] == topic) {
                (, , bytes32 market, uint256 amount) = abi.decode(logs_[i].data, (address, address, bytes32, uint256));
                if (market == morphoMarketId_) total += amount;
            }
        }
    }

    function _failedCount(Vm.Log[] memory logs_) private view returns (uint256 count) {
        bytes32 topic = keccak256("MorphoSupplyFuseExitFailed(address,address,bytes32)");
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == _plasmaVault && logs_[i].topics[0] == topic) ++count;
        }
    }

    function _createMarkets() private {
        address oracleA = address(new MorphoSupplyInstantLiquidityMockOracle(_ORACLE_PRICE));
        address oracleB = address(new MorphoSupplyInstantLiquidityMockOracle(_ORACLE_PRICE + 1));
        _marketA = MarketParams(_USDC, _W_ETH, oracleA, address(0), _LLTV);
        _marketB = MarketParams(_USDC, _W_ETH, oracleB, address(0), _LLTV);
        IMorpho(_MORPHO).createMarket(_marketA);
        IMorpho(_MORPHO).createMarket(_marketB);
        _idA = Id.unwrap(MarketParamsLib.id(_marketA));
        _idB = Id.unwrap(MarketParamsLib.id(_marketB));
    }

    function _createPriceOracle() private returns (address) {
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(_CHAINLINK_REGISTRY);
        PriceOracleMiddleware priceOracle = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );
        address[] memory assets = new address[](2);
        address[] memory sources = new address[](2);
        assets[0] = _USDC;
        sources[0] = _USDC_USD_CHAINLINK;
        assets[1] = _W_ETH;
        sources[1] = _ETH_USD_CHAINLINK;
        priceOracle.setAssetsPricesSources(assets, sources);
        return address(priceOracle);
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

/// @notice The scenarios above against MorphoSupplyFuse
contract MorphoSupplyFuseInstantWithdrawLiquidityForkTest is MorphoSupplyFuseInstantWithdrawLiquidityBase {
    function _forkBlock() internal pure override returns (uint256) {
        return 21_100_010;
    }

    function _deploySupplyFuse() internal override returns (address) {
        return address(new MorphoSupplyFuse(IporFusionMarkets.MORPHO, _MORPHO));
    }

    function _enterCall(bytes32 morphoMarketId_, uint256 amount_) internal pure override returns (bytes memory) {
        return
            abi.encodeWithSignature(
                "enter((bytes32,uint256))",
                MorphoSupplyFuseEnterData({morphoMarketId: morphoMarketId_, amount: amount_})
            );
    }
}

/// @notice The scenarios above against MorphoSupplyWithCallBackDataFuse
contract MorphoSupplyWithCallBackDataFuseInstantWithdrawLiquidityForkTest is
    MorphoSupplyFuseInstantWithdrawLiquidityBase
{
    function _forkBlock() internal pure override returns (uint256) {
        return 21_100_020;
    }

    function _deploySupplyFuse() internal override returns (address) {
        return address(new MorphoSupplyWithCallBackDataFuse(IporFusionMarkets.MORPHO, _MORPHO));
    }

    function _enterCall(bytes32 morphoMarketId_, uint256 amount_) internal pure override returns (bytes memory) {
        return
            abi.encodeWithSignature(
                "enter((bytes32,uint256,bytes))",
                CallbackEnterData({
                    morphoMarketId: morphoMarketId_,
                    maxTokenAmount: amount_,
                    callbackFuseActionsData: abi.encode(new FuseAction[](0))
                })
            );
    }
}
