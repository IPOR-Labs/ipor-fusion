// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {UpdateMarketsBalancesFuse} from "../../../contracts/fuses/update_balances/UpdateMarketsBalancesFuse.sol";
import {IUpdateMarketsBalancesFuse, UpdateMarketsBalancesEnterData} from "../../../contracts/fuses/update_balances/IUpdateMarketsBalancesFuse.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {ZeroBalanceFuse} from "../../../contracts/fuses/ZeroBalanceFuse.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";

import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVault, PlasmaVaultInitData, FeeConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {FeeAccount} from "../../../contracts/managers/fee/FeeAccount.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {PlasmaVaultConfigurator} from "../../utils/PlasmaVaultConfigurator.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {IporFusionAccessManagerInitializerLibV1, InitializationData, DataForInitialization, PlasmaVaultAddress} from "../../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";

/// @title UpdateMarketsBalancesFuseIntegrationTest
/// @notice Fork integration tests for UpdateMarketsBalancesFuse on Ethereum mainnet
contract UpdateMarketsBalancesFuseIntegrationTest is Test {
    // ============ Mainnet Addresses ============

    address private constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant _CHAINLINK_REGISTRY = 0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf;
    address private constant _USDC_USD_CHAINLINK = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;

    // Test accounts
    address private constant _ATOMIST = address(0x111111);
    address private constant _ALPHA = address(0x222222);
    address private constant _USER = address(0x333333);

    // ============ Fork Configuration ============

    uint256 public constant FORK_BLOCK = 20990348;

    // ============ State Variables ============

    address private _plasmaVault;
    address private _priceOracle;
    address private _accessManager;
    address private _updateMarketsBalancesFuse;
    address private _erc20BalanceFuse;
    address private _zeroBalanceFuse100;
    address private _zeroBalanceFuse200;
    address private _zeroBalanceFuseForUpdateFuse;

    // Market IDs for testing
    uint256 private constant MARKET_ID_ERC20 = IporFusionMarkets.ERC20_VAULT_BALANCE;
    uint256 private constant MARKET_ID_100 = 100;
    uint256 private constant MARKET_ID_200 = 200;

    // ============ Events ============

    event UpdateMarketsBalancesEnter(address indexed version, uint256[] marketIds);
    event MarketBalancesUpdated(uint256[] marketIds, int256 deltaInUnderlying);

    // ============ Setup ============

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), FORK_BLOCK);

        _priceOracle = _createPriceOracle();
        _accessManager = _createAccessManager();
        address withdrawManager = address(new WithdrawManager(_accessManager));

        // Deploy fuses
        _updateMarketsBalancesFuse = address(new UpdateMarketsBalancesFuse());
        _erc20BalanceFuse = address(new ERC20BalanceFuse(MARKET_ID_ERC20));
        _zeroBalanceFuse100 = address(new ZeroBalanceFuse(MARKET_ID_100));
        _zeroBalanceFuse200 = address(new ZeroBalanceFuse(MARKET_ID_200));
        // Balance fuse for UpdateMarketsBalancesFuse's MARKET_ID (ZERO_BALANCE_MARKET)
        _zeroBalanceFuseForUpdateFuse = address(new ZeroBalanceFuse(IporFusionMarkets.ZERO_BALANCE_MARKET));

        // Deploy PlasmaVault
        vm.startPrank(_ATOMIST);
        _plasmaVault = address(new PlasmaVault());
        PlasmaVault(_plasmaVault).proxyInitialize(
            PlasmaVaultInitData({
                assetName: "TEST PLASMA VAULT",
                assetSymbol: "USDC",
                underlyingToken: _USDC,
                priceOracleMiddleware: _priceOracle,
                feeConfig: _setupFeeConfig(),
                accessManager: _accessManager,
                plasmaVaultBase: address(new PlasmaVaultBase()),
                plasmaVaultERC4626: address(0),
                withdrawManager: withdrawManager,
                plasmaVaultVotesPlugin: address(0)
            })
        );
        vm.stopPrank();

        // Configure PlasmaVault
        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            _ATOMIST,
            _plasmaVault,
            _setupFuses(),
            _setupBalanceFuses(),
            _setupMarketConfigs()
        );

        _initAccessManager();
        _initialDepositIntoPlasmaVault();

        // Label addresses
        vm.label(_plasmaVault, "PlasmaVault");
        vm.label(_updateMarketsBalancesFuse, "UpdateMarketsBalancesFuse");
        vm.label(_erc20BalanceFuse, "ERC20BalanceFuse");
    }

    // ============ Test Cases ============

    function testShouldReturnCorrectMarketId() public view {
        // then - MARKET_ID is ZERO_BALANCE_MARKET which is type(uint256).max
        assertEq(
            UpdateMarketsBalancesFuse(_updateMarketsBalancesFuse).MARKET_ID(),
            IporFusionMarkets.ZERO_BALANCE_MARKET,
            "MARKET_ID should be ZERO_BALANCE_MARKET"
        );
    }

    function testShouldReturnCorrectVersion() public view {
        // then
        assertEq(
            UpdateMarketsBalancesFuse(_updateMarketsBalancesFuse).VERSION(),
            _updateMarketsBalancesFuse,
            "VERSION should be fuse address"
        );
    }

    function testShouldExecuteFuseThroughPlasmaVault() public {
        // given
        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = MARKET_ID_ERC20;

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: _updateMarketsBalancesFuse,
            data: abi.encodeWithSignature("enter((uint256[]))", UpdateMarketsBalancesEnterData({marketIds: marketIds}))
        });

        // when/then - should not revert
        vm.prank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    function testShouldUpdateBalancesForMultipleMarkets() public {
        // given
        uint256[] memory marketIds = new uint256[](3);
        marketIds[0] = MARKET_ID_ERC20;
        marketIds[1] = MARKET_ID_100;
        marketIds[2] = MARKET_ID_200;

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: _updateMarketsBalancesFuse,
            data: abi.encodeWithSignature("enter((uint256[]))", UpdateMarketsBalancesEnterData({marketIds: marketIds}))
        });

        // Record logs to verify event emission
        vm.recordLogs();

        // when
        vm.prank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);

        // then - verify event was emitted
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundEvent = false;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == keccak256("UpdateMarketsBalancesEnter(address,uint256[])")) {
                foundEvent = true;
                break;
            }
        }
        assertTrue(foundEvent, "UpdateMarketsBalancesEnter event should be emitted");
    }

    function testShouldIgnoreZeroValuesInInput() public {
        // given - array with zeros
        uint256[] memory marketIds = new uint256[](5);
        marketIds[0] = MARKET_ID_ERC20;
        marketIds[1] = 0; // Zero - should be filtered
        marketIds[2] = MARKET_ID_100;
        marketIds[3] = 0; // Zero - should be filtered
        marketIds[4] = MARKET_ID_200;

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: _updateMarketsBalancesFuse,
            data: abi.encodeWithSignature("enter((uint256[]))", UpdateMarketsBalancesEnterData({marketIds: marketIds}))
        });

        // when/then - should execute without issues (zeros filtered in library)
        vm.prank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    function testShouldEmitEventsCorrectly() public {
        // given
        uint256[] memory marketIds = new uint256[](2);
        marketIds[0] = MARKET_ID_100;
        marketIds[1] = MARKET_ID_200;

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: _updateMarketsBalancesFuse,
            data: abi.encodeWithSignature("enter((uint256[]))", UpdateMarketsBalancesEnterData({marketIds: marketIds}))
        });

        // when/then - expect event emission
        vm.expectEmit(true, false, false, true);
        emit UpdateMarketsBalancesEnter(_updateMarketsBalancesFuse, marketIds);

        vm.prank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    function testShouldRevertWhenFuseNotAdded() public {
        // given - deploy new fuse that is NOT added to vault
        address newFuse = address(new UpdateMarketsBalancesFuse());

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = MARKET_ID_ERC20;

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: newFuse,
            data: abi.encodeWithSignature("enter((uint256[]))", UpdateMarketsBalancesEnterData({marketIds: marketIds}))
        });

        // when/then - should revert with UnsupportedFuse
        vm.prank(_ALPHA);
        vm.expectRevert(); // UnsupportedFuse error
        PlasmaVault(_plasmaVault).execute(actions);
    }

    function testShouldRevertWhenExitCalled() public {
        // given
        bytes memory emptyData = "";

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: _updateMarketsBalancesFuse,
            data: abi.encodeWithSignature("exit(bytes)", emptyData)
        });

        // when/then - should revert with UpdateMarketsBalancesFuseExitNotSupported
        vm.prank(_ALPHA);
        vm.expectRevert(IUpdateMarketsBalancesFuse.UpdateMarketsBalancesFuseExitNotSupported.selector);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    function testShouldRevertWhenEmptyMarketIdsProvided() public {
        // given - empty market IDs array
        uint256[] memory marketIds = new uint256[](0);

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: _updateMarketsBalancesFuse,
            data: abi.encodeWithSignature("enter((uint256[]))", UpdateMarketsBalancesEnterData({marketIds: marketIds}))
        });

        // when/then - should revert with UpdateMarketsBalancesFuseEmptyMarkets
        vm.prank(_ALPHA);
        vm.expectRevert(IUpdateMarketsBalancesFuse.UpdateMarketsBalancesFuseEmptyMarkets.selector);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    // ============ Helper Functions ============

    function _createPriceOracle() private returns (address) {
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(_CHAINLINK_REGISTRY);
        PriceOracleMiddleware priceOracle = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );

        address[] memory assets = new address[](1);
        assets[0] = _USDC;
        address[] memory sources = new address[](1);
        sources[0] = _USDC_USD_CHAINLINK;

        priceOracle.setAssetsPricesSources(assets, sources);

        return address(priceOracle);
    }

    function _createAccessManager() private returns (address) {
        return address(new IporFusionAccessManager(_ATOMIST, 0));
    }

    function _setupFeeConfig() private returns (FeeConfig memory) {
        return FeeConfigHelper.createZeroFeeConfig();
    }

    function _setupFuses() private view returns (address[] memory) {
        address[] memory fuses = new address[](1);
        fuses[0] = _updateMarketsBalancesFuse;
        return fuses;
    }

    function _setupBalanceFuses() private view returns (MarketBalanceFuseConfig[] memory) {
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](4);

        balanceFuses[0] = MarketBalanceFuseConfig({marketId: MARKET_ID_ERC20, fuse: _erc20BalanceFuse});
        balanceFuses[1] = MarketBalanceFuseConfig({marketId: MARKET_ID_100, fuse: _zeroBalanceFuse100});
        balanceFuses[2] = MarketBalanceFuseConfig({marketId: MARKET_ID_200, fuse: _zeroBalanceFuse200});
        // Balance fuse for UpdateMarketsBalancesFuse's MARKET_ID (ZERO_BALANCE_MARKET)
        balanceFuses[3] = MarketBalanceFuseConfig({
            marketId: IporFusionMarkets.ZERO_BALANCE_MARKET,
            fuse: _zeroBalanceFuseForUpdateFuse
        });

        return balanceFuses;
    }

    function _setupMarketConfigs() private view returns (MarketSubstratesConfig[] memory) {
        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](1);

        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(_USDC);

        marketConfigs[0] = MarketSubstratesConfig({marketId: MARKET_ID_ERC20, substrates: substrates});

        return marketConfigs;
    }

    function _initAccessManager() private {
        address[] memory initAddress = new address[](2);
        initAddress[0] = address(this);
        initAddress[1] = _ATOMIST;

        address[] memory alphas = new address[](2);
        alphas[0] = _ATOMIST;
        alphas[1] = _ALPHA;

        address[] memory whitelist = new address[](1);
        whitelist[0] = _USER;

        DataForInitialization memory data = DataForInitialization({
            isPublic: true,
            iporDaos: initAddress,
            admins: initAddress,
            owners: initAddress,
            atomists: initAddress,
            alphas: alphas,
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
                withdrawManager: address(0x123),
                feeManager: FeeAccount(PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeAccount)
                    .FEE_MANAGER(),
                contextManager: address(0x123),
                priceOracleMiddlewareManager: address(0x123)
            })
        });

        InitializationData memory initData = IporFusionAccessManagerInitializerLibV1.generateInitializeIporPlasmaVault(
            data
        );

        vm.startPrank(_ATOMIST);
        IporFusionAccessManager(_accessManager).initialize(initData);
        vm.stopPrank();
    }

    function _initialDepositIntoPlasmaVault() private {
        // Give USDC to user from whale
        vm.prank(0x4B16c5dE96EB2117bBE5fd171E4d203624B014aa); // USDC whale
        ERC20(_USDC).transfer(_USER, 10_000e6);

        // User deposits into PlasmaVault
        vm.startPrank(_USER);
        ERC20(_USDC).approve(_plasmaVault, 10_000e6);
        PlasmaVault(_plasmaVault).deposit(10_000e6, _USER);
        vm.stopPrank();

        // Update balances
        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = MARKET_ID_ERC20;

        PlasmaVault(_plasmaVault).updateMarketsBalances(marketIds);
    }
}
