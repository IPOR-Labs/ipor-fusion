// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BorrowTest} from "../supplyFuseTemplate/BorrowTests.sol";
import {IAavePriceOracle} from "../../../contracts/fuses/aave_v3/ext/IAavePriceOracle.sol";
import {AaveV3SupplyFuse, AaveV3SupplyFuseEnterData, AaveV3SupplyFuseExitData} from "../../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {AaveV3BorrowFuse, AaveV3BorrowFuseEnterData, AaveV3BorrowFuseExitData} from "../../../contracts/fuses/aave_v3/AaveV3BorrowFuse.sol";
import {PlasmaVault, FuseAction, MarketSubstratesConfig, MarketBalanceFuseConfig, FeeConfig, PlasmaVaultInitData} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {AaveV3BalanceFuse} from "../../../contracts/fuses/aave_v3/AaveV3BalanceFuse.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {IPriceOracleMiddleware} from "../../../contracts/price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {WstETHPriceFeedEthereum} from "../../../contracts/price_oracle/price_feed/chains/ethereum/WstETHPriceFeedEthereum.sol";
import {FeeManagerFactory} from "../../../contracts/managers/fee/FeeManagerFactory.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {IporFusionAccessManagerInitializerLibV1, DataForInitialization, PlasmaVaultAddress, InitializationData} from "../../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {FeeAccount} from "../../../contracts/managers/fee/FeeAccount.sol";

contract AaveV32WstETHBorrowEtheriumTest is Test {
    address private constant W_ETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant WST_ETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address private constant CHAINLINK_ETH = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address public constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address public constant AAVE_POOL_DATA_PROVIDER = 0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3;
    address public constant AAVE_PRICE_ORACLE = 0x54586bE62E3c3580375aE3723C145253060Ca0C2;

    address private constant SUPPLY_FUSE_AAVE_V3 = 0x465D639EB964158beE11f35E8fc23f704EC936a2;
    address private constant BALANCE_FUSE_AAVE_V3 = 0x05bCb16a50DaFE0526FB7b3941B81B1B74a7877e;

    address private constant _UNDERLYING = W_ETH;
    address private constant _PRICE_ORACLE_MIDDLEWARE = 0xB7018C15279E0f5990613cc00A91b6032066f2f7;
    address private constant _PRICE_ORACLE_MIDDLEWARE_OWNER = 0xF6a9bd8F6DC537675D499Ac1CA14f2c55d8b5569;
    address private constant _DAO = address(1111111);
    address private constant _OWNER = address(2222222);
    address private constant _ADMIN = address(3333333);
    address private constant _ATOMIST = address(4444444);
    address private constant _ALPHA = address(5555555);
    address private constant _USER = address(6666666);
    address private constant _GUARDIAN = address(7777777);
    address private constant _FUSE_MANAGER = address(8888888);
    address private constant _CLAIM_REWARDS = address(7777777);
    address private constant _TRANSFER_REWARDS_MANAGER = address(8888888);
    address private constant _CONFIG_INSTANT_WITHDRAWAL_FUSES_MANAGER = address(9999999);

    address private _plasmaVault;
    address private _accessManager;
    address private _aaveV3BorrowFuse;

    function setUp() public {
        // Fork mainnet
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 21033361);
        addAssetsToPriceOracleMiddleware();
        _plasmaVault = deployMinimalPlasmaVault();
        setupInitialRoles(_plasmaVault);
        addAaveFusesToPlasmaVault(_plasmaVault);
        provideWstEthAndWEthToUser(1000e18, 1000e18);
        depositToPlasmaVault(_USER, _plasmaVault, W_ETH, 100e18);
        addErc20BalanceFuseAndSubstrate();
        vm.startPrank(_USER);
        ERC20(WST_ETH).transfer(_plasmaVault, 100e18);
        vm.stopPrank();

        uint256[] memory marketIds = new uint256[](2);
        marketIds[0] = IporFusionMarkets.ERC20_VAULT_BALANCE;
        marketIds[1] = IporFusionMarkets.AAVE_V3;
        PlasmaVault(_plasmaVault).updateMarketsBalances(marketIds);
    }

    function deployMinimalPlasmaVault() private returns (address) {
        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](1);
        marketConfigs[0] = MarketSubstratesConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, new bytes32[](0));

        address[] memory fuses = new address[](0);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(
            IporFusionMarkets.ERC20_VAULT_BALANCE,
            address(new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE))
        );

        FeeConfig memory feeConfig = FeeConfig({
            iporDaoManagementFee: 0,
            iporDaoPerformanceFee: 0,
            atomistManagementFee: 0,
            atomistPerformanceFee: 0,
            feeFactory: address(new FeeManagerFactory()),
            feeRecipientAddress: address(0),
            iporDaoFeeRecipientAddress: address(0)
        });

        _accessManager = address(new IporFusionAccessManager(_ATOMIST, 0));

        PlasmaVaultInitData memory initData = PlasmaVaultInitData({
            assetName: "Minimal Plasma Vault",
            assetSymbol: "MPV",
            underlyingToken: _UNDERLYING,
            priceOracleMiddleware: _PRICE_ORACLE_MIDDLEWARE,
            marketSubstratesConfigs: new MarketSubstratesConfig[](0),
            fuses: new address[](0),
            balanceFuses: new MarketBalanceFuseConfig[](0),
            feeConfig: feeConfig,
            accessManager: _accessManager,
            plasmaVaultBase: address(new PlasmaVaultBase()),
            totalSupplyCap: type(uint256).max,
            withdrawManager: address(0)
        });

        vm.startPrank(_ATOMIST);
        _plasmaVault = address(new PlasmaVault(initData));
        vm.stopPrank();

        return _plasmaVault;
    }

    function setupInitialRoles(address plasmaVault) public {
        address[] memory daos = new address[](1);
        daos[0] = _DAO;

        address[] memory admins = new address[](1);
        admins[0] = _ADMIN;

        address[] memory owners = new address[](1);
        owners[0] = _OWNER;

        address[] memory atomists = new address[](1);
        atomists[0] = _ATOMIST;

        address[] memory alphas = new address[](1);
        alphas[0] = _ALPHA;

        address[] memory guardians = new address[](1);
        guardians[0] = _GUARDIAN;

        address[] memory fuseManagers = new address[](1);
        fuseManagers[0] = _FUSE_MANAGER;

        address[] memory claimRewards = new address[](1);
        claimRewards[0] = _CLAIM_REWARDS;

        address[] memory transferRewardsManagers = new address[](1);
        transferRewardsManagers[0] = _TRANSFER_REWARDS_MANAGER;

        address[] memory configInstantWithdrawalFusesManagers = new address[](1);
        configInstantWithdrawalFusesManagers[0] = _CONFIG_INSTANT_WITHDRAWAL_FUSES_MANAGER;

        DataForInitialization memory data = DataForInitialization({
            isPublic: true,
            iporDaos: daos,
            admins: admins,
            owners: owners,
            atomists: atomists,
            alphas: alphas,
            whitelist: new address[](0),
            guardians: guardians,
            fuseManagers: fuseManagers,
            claimRewards: claimRewards,
            transferRewardsManagers: transferRewardsManagers,
            configInstantWithdrawalFusesManagers: configInstantWithdrawalFusesManagers,
            plasmaVaultAddress: PlasmaVaultAddress({
                plasmaVault: _plasmaVault,
                accessManager: _accessManager,
                rewardsClaimManager: address(0),
                withdrawManager: address(0),
                feeManager: FeeAccount(PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeAccount)
                    .FEE_MANAGER()
            })
        });

        InitializationData memory initializationData = IporFusionAccessManagerInitializerLibV1
            .generateInitializeIporPlasmaVault(data);

        vm.startPrank(_ATOMIST);
        IporFusionAccessManager(_accessManager).initialize(initializationData);
        vm.stopPrank();
    }

    function deployAaveV3BorrowFuse() public returns (address) {
        vm.startPrank(_ATOMIST);

        address aaveV3BorrowFuse = address(new AaveV3BorrowFuse(IporFusionMarkets.AAVE_V3, AAVE_POOL));

        vm.stopPrank();
        _aaveV3BorrowFuse = aaveV3BorrowFuse;

        return aaveV3BorrowFuse;
    }

    function addAaveFusesToPlasmaVault(address plasmaVault_) public {
        uint256 marketId = IporFusionMarkets.AAVE_V3;

        // Deploy AaveV3SupplyFuse and AaveV3BorrowFuse
        address aaveSupplyFuse = SUPPLY_FUSE_AAVE_V3;
        address aaveBorrowFuse = deployAaveV3BorrowFuse();

        // Add supply and borrow fuses to PlasmaVault
        address[] memory fusesToAdd = new address[](2);
        fusesToAdd[0] = aaveSupplyFuse;
        fusesToAdd[1] = aaveBorrowFuse;

        vm.startPrank(_FUSE_MANAGER);
        PlasmaVaultGovernance(plasmaVault_).addFuses(fusesToAdd);

        // Add balance fuse to PlasmaVault for the specific market
        address aaveBalanceFuse = BALANCE_FUSE_AAVE_V3;
        PlasmaVaultGovernance(plasmaVault_).addBalanceFuse(marketId, aaveBalanceFuse);

        vm.stopPrank();

        // Grant market substrates for the AAVE_V3 market
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(W_ETH);
        substrates[1] = PlasmaVaultConfigLib.addressToBytes32(WST_ETH);

        vm.prank(_ATOMIST);
        PlasmaVaultGovernance(plasmaVault_).grantMarketSubstrates(marketId, substrates);
    }

    function addErc20BalanceFuseAndSubstrate() public {
        // Deploy ERC20BalanceFuse
        vm.startPrank(_ATOMIST);
        address erc20BalanceFuse = address(new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE));
        vm.stopPrank();

        // Add ERC20BalanceFuse to PlasmaVault
        vm.startPrank(_FUSE_MANAGER);
        PlasmaVaultGovernance(_plasmaVault).addBalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE, erc20BalanceFuse);
        vm.stopPrank();

        // Add WST_ETH as substrate for ERC20_VAULT_BALANCE market
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = bytes32(uint256(uint160(WST_ETH)));

        vm.startPrank(_ATOMIST);
        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(IporFusionMarkets.ERC20_VAULT_BALANCE, substrates);
        vm.stopPrank();

        // Update dependency balance graph
        uint256[][] memory dependencies = new uint256[][](1);
        uint256[] memory aaveDependencies = new uint256[](1);
        aaveDependencies[0] = IporFusionMarkets.ERC20_VAULT_BALANCE;
        dependencies[0] = aaveDependencies;

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.AAVE_V3;

        vm.startPrank(_ATOMIST);
        PlasmaVaultGovernance(_plasmaVault).updateDependencyBalanceGraphs(marketIds, dependencies);
        vm.stopPrank();
    }

    function provideWstEthAndWEthToUser(uint256 wstEthAmount, uint256 wEthAmount) public {
        // Provide wstETH to _USER
        deal(WST_ETH, _USER, wstEthAmount);

        // Provide WETH to _USER
        deal(W_ETH, _USER, wEthAmount);

        // Verify balances
        assertEq(ERC20(WST_ETH).balanceOf(_USER), wstEthAmount, "Incorrect wstETH balance");
        assertEq(ERC20(W_ETH).balanceOf(_USER), wEthAmount, "Incorrect WETH balance");
    }

    function depositToPlasmaVault(address user_, address plasmaVault_, address token_, uint256 amount_) public {
        // Approve PlasmaVault to spend user's tokens
        vm.startPrank(user_);
        ERC20(token_).approve(plasmaVault_, amount_);

        // Deposit tokens to PlasmaVault
        PlasmaVault(plasmaVault_).deposit(amount_, user_);
        vm.stopPrank();

        // Verify deposit
        uint256 shares = PlasmaVault(plasmaVault_).balanceOf(user_);
        assertGt(shares, 0, "User should have received shares");

        uint256 assets = PlasmaVault(plasmaVault_).convertToAssets(shares);
        assertEq(assets, amount_, "Deposited assets should match the amount");
    }

    function addAssetsToPriceOracleMiddleware() public {
        address[] memory assets = new address[](2);
        address[] memory sources = new address[](2);

        assets[0] = W_ETH;
        sources[0] = CHAINLINK_ETH;

        assets[1] = WST_ETH;
        sources[1] = address(new WstETHPriceFeedEthereum());

        vm.startPrank(_PRICE_ORACLE_MIDDLEWARE_OWNER);
        IPriceOracleMiddleware(_PRICE_ORACLE_MIDDLEWARE).setAssetsPricesSources(assets, sources);
        vm.stopPrank();
    }

    function testDeployAaveV3BorrowFuse() public {
        // given
        setUp();

        // Prepare enter data for supply
        AaveV3SupplyFuseEnterData memory enterSupplyData = AaveV3SupplyFuseEnterData({
            asset: W_ETH,
            amount: 10e18, // 10 W_ETH
            userEModeCategoryId: 300 // Use default mode
        });

        // Encode the enter call
        bytes memory encodedEnterCall = abi.encodeWithSignature("enter((address,uint256,uint256))", enterSupplyData);

        // Prepare FuseAction
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(SUPPLY_FUSE_AAVE_V3, encodedEnterCall);

        // Execute the supply action
        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(calls);
        vm.stopPrank();

        uint256 plasmaVaultBalanceBefore = PlasmaVault(_plasmaVault).totalAssets();
        uint256 plasmaVaultAaveBalanceBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.AAVE_V3);
        // when
        // Prepare enter data for borrow
        AaveV3BorrowFuseEnterData memory enterBorrowData = AaveV3BorrowFuseEnterData({
            asset: WST_ETH,
            amount: 1e18 // 1 WST_ETH
        });

        // Encode the borrow enter call
        bytes memory encodedBorrowEnterCall = abi.encodeWithSignature("enter((address,uint256))", enterBorrowData);

        // Prepare FuseAction for borrow
        FuseAction[] memory borrowCalls = new FuseAction[](1);
        borrowCalls[0] = FuseAction(_aaveV3BorrowFuse, encodedBorrowEnterCall);

        // Execute the borrow action
        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(borrowCalls);
        vm.stopPrank();

        uint256 plasmaVaultBalanceAfter = PlasmaVault(_plasmaVault).totalAssets();
        uint256 plasmaVaultAaveBalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.AAVE_V3);

        console2.log("PlasmaVault balance after  : ", plasmaVaultBalanceAfter);
        assertEq(
            plasmaVaultBalanceAfter,
            218210107370894981284,
            "PlasmaVault balance after should be 218210107370894981284"
        );
        console2.log("PlasmaVault balance before : ", plasmaVaultBalanceBefore);
        assertEq(
            plasmaVaultBalanceBefore,
            218210682032569715259,
            "PlasmaVault balance before should be 218210107370894981284"
        );

        console2.log("PlasmaVault Aave balance before", plasmaVaultAaveBalanceBefore);
        console2.log("PlasmaVault Aave balance after", plasmaVaultAaveBalanceAfter);
        assertEq(
            plasmaVaultAaveBalanceAfter,
            8817318517999568872,
            "PlasmaVault Aave balance after should be 8817318517999568872"
        );
        assertEq(
            plasmaVaultAaveBalanceBefore,
            10000000000000000000,
            "PlasmaVault Aave balance before should be 10000000000000000000"
        );
    }
}
//  w_eth - w_eth(wst_eth)
// 10000000000000000000 - 1179260000000000000 = 8,82074e18
