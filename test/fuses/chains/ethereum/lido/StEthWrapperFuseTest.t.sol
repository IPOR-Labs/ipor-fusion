// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {PlasmaVault, PlasmaVaultInitData, MarketBalanceFuseConfig, FuseAction, FeeConfig} from "../../../../../contracts/vaults/PlasmaVault.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig} from "../../../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../../../../contracts/vaults/PlasmaVaultBase.sol";
import {PriceOracleMiddleware} from "../../../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {WstETHPriceFeedEthereum} from "../../../../../contracts/price_oracle/price_feed/chains/ethereum/WstETHPriceFeedEthereum.sol";
import {StEthWrapperFuse} from "../../../../../contracts/fuses/chains/ethereum/lido/StEthWrapperFuse.sol";
import {WithdrawManager} from "../../../../../contracts/managers/withdraw/WithdrawManager.sol";
import {PlasmaVaultConfigurator} from "../../../../utils/PlasmaVaultConfigurator.sol";
import {IporFusionAccessManager} from "../../../../../contracts/managers/access/IporFusionAccessManager.sol";
import {IporFusionMarkets} from "../../../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultConfigLib} from "../../../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {ERC20BalanceFuse} from "../../../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {FeeConfigHelper} from "../../../../test_helpers/FeeConfigHelper.sol";
import {IporFusionAccessManagerInitializerLibV1, InitializationData, DataForInitialization, PlasmaVaultAddress} from "../../../../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {FeeAccount} from "../../../../../contracts/managers/fee/FeeAccount.sol";
import {PlasmaVaultGovernance} from "../../../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IWstETH} from "./IWstETH.sol";

contract StEthWrapperFuseTest is Test {
    ///  assets
    address private constant _WETH_ADDRESS = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant _stETH_ADDRESS = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address private constant _wstETH_ADDRESS = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    ///  Oracle
    address private constant _ETH_USD_CHAINLINK = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address private constant _CHAINLINK_REGISTRY = 0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf;

    ///  Plasma Vault tests config
    address private constant _ATOMIST = address(1111111);
    address private constant _ALPHA = address(2222222);
    address private constant _stETH_HOLDER = 0x176F3DAb24a159341c0509bB36B833E7fdd0a132;

    uint256 private _errorDelta = 1e3;

    address private _plasmaVault;
    address private _priceOracle;
    address private _accessManager;

    address private _stEthWrapperFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 23041700);

        _priceOracle = _createPriceOracle();

        address accessManager = _createAccessManager();
        address withdrawManager = address(new WithdrawManager(accessManager));

        // plasma vault
        vm.startPrank(_ATOMIST);
        _plasmaVault = address(
            new PlasmaVault(
                PlasmaVaultInitData(
                    "TEST PLASMA VAULT",
                    "stETH",
                    _stETH_ADDRESS,
                    _priceOracle,
                    _setupFeeConfig(),
                    accessManager,
                    address(new PlasmaVaultBase()),
                    withdrawManager
                )
            )
        );
        vm.stopPrank();

        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            _ATOMIST,
            address(_plasmaVault),
            _setupFuses(),
            _setupBalanceFuses(),
            _setupMarketConfigsErc20()
        );

        _initAccessManager();
        _initialDepositIntoPlasmaVault();
    }

    function _createPriceOracle() private returns (address) {
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(_CHAINLINK_REGISTRY);
        PriceOracleMiddleware priceOracle = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );

        WstETHPriceFeedEthereum wstETHPriceFeed = new WstETHPriceFeedEthereum();

        address[] memory assets = new address[](3);
        address[] memory sources = new address[](3);

        assets[0] = _wstETH_ADDRESS;
        sources[0] = address(wstETHPriceFeed);

        assets[1] = _WETH_ADDRESS;
        sources[1] = _ETH_USD_CHAINLINK;

        assets[2] = _stETH_ADDRESS;
        sources[2] = _ETH_USD_CHAINLINK;

        priceOracle.setAssetsPricesSources(assets, sources);

        return address(priceOracle);
    }

    function _setupMarketConfigsErc20() private returns (MarketSubstratesConfig[] memory marketConfigs_) {
        marketConfigs_ = new MarketSubstratesConfig[](1);

        bytes32[] memory tokens = new bytes32[](3);
        tokens[0] = PlasmaVaultConfigLib.addressToBytes32(_WETH_ADDRESS);
        tokens[1] = PlasmaVaultConfigLib.addressToBytes32(_stETH_ADDRESS);
        tokens[2] = PlasmaVaultConfigLib.addressToBytes32(_wstETH_ADDRESS);

        marketConfigs_[0] = MarketSubstratesConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, tokens);
    }

    function _setupFuses() private returns (address[] memory fuses) {
        _stEthWrapperFuse = address(new StEthWrapperFuse(IporFusionMarkets.ERC20_VAULT_BALANCE));

        fuses = new address[](1);
        fuses[0] = address(_stEthWrapperFuse);
    }

    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses_) {
        ERC20BalanceFuse erc20Balance = new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE);

        balanceFuses_ = new MarketBalanceFuseConfig[](1);
        balanceFuses_[0] = MarketBalanceFuseConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, address(erc20Balance));
    }

    function _setupFeeConfig() private returns (FeeConfig memory feeConfig) {
        feeConfig = FeeConfigHelper.createZeroFeeConfig();
    }

    function _createAccessManager() private returns (address accessManager_) {
        accessManager_ = address(new IporFusionAccessManager(_ATOMIST, 0));
        _accessManager = accessManager_;
    }

    function _initAccessManager() private {
        address[] memory initAddress = new address[](3);
        initAddress[0] = address(this);
        initAddress[1] = _ATOMIST;
        initAddress[2] = _ALPHA;

        address[] memory whitelist = new address[](1);
        whitelist[0] = _stETH_HOLDER;

        address[] memory dao = new address[](1);
        dao[0] = address(this);

        DataForInitialization memory data = DataForInitialization({
            isPublic: false,
            iporDaos: dao,
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
                withdrawManager: address(0x123),
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

    function _initialDepositIntoPlasmaVault() private {
        /// this transfer is only for testing purposes, in production one have to swap underlying assets to this assets
        vm.startPrank(_stETH_HOLDER);
        ERC20(_stETH_ADDRESS).transfer(_plasmaVault, 100e18);
        vm.stopPrank();

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.ERC20_VAULT_BALANCE;

        PlasmaVault(_plasmaVault).updateMarketsBalances(marketIds);
    }

    //******************************************************************************************************************
    //********************                              TESTS                                       ********************
    //******************************************************************************************************************

    function testShouldBeAbleWrap() external {
        // given
        uint256 stEthToWrap = 50e18;

        FuseAction[] memory enterCalls = new FuseAction[](1);

        enterCalls[0] = FuseAction({
            fuse: _stEthWrapperFuse,
            data: abi.encodeWithSignature("enter(uint256)", stEthToWrap)
        });

        uint256 wstEthBalanceBefore = ERC20(_wstETH_ADDRESS).balanceOf(_plasmaVault);
        uint256 plasmaVaultBalanceBefore = ERC20(_stETH_ADDRESS).balanceOf(_plasmaVault);
        uint256 expectedWstEthAmount = IWstETH(_wstETH_ADDRESS).getWstETHByStETH(stEthToWrap);

        //when
        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(enterCalls);
        vm.stopPrank();

        //then

        uint256 wstEthBalanceAfter = ERC20(_wstETH_ADDRESS).balanceOf(_plasmaVault);
        uint256 plasmaVaultBalanceAfter = ERC20(_stETH_ADDRESS).balanceOf(_plasmaVault);

        assertEq(wstEthBalanceBefore, 0, "wstETH balance before should be 0");
        assertApproxEqAbs(plasmaVaultBalanceBefore, 100e18, _errorDelta, "stETH balance before should be 100");
        assertApproxEqAbs(wstEthBalanceAfter, expectedWstEthAmount, _errorDelta, "invalid wstETH balance");
        assertApproxEqAbs(plasmaVaultBalanceAfter, 50e18, _errorDelta, "stETH balance before should be 50");
    }

    function testShouldBeAbleWrapSmallerAmountThanRequested() external {
        // given
        uint256 stEthToWrap = 101e18;

        FuseAction[] memory enterCalls = new FuseAction[](1);

        enterCalls[0] = FuseAction({
            fuse: _stEthWrapperFuse,
            data: abi.encodeWithSignature("enter(uint256)", stEthToWrap)
        });

        uint256 wstEthBalanceBefore = ERC20(_wstETH_ADDRESS).balanceOf(_plasmaVault);
        uint256 plasmaVaultBalanceBefore = ERC20(_stETH_ADDRESS).balanceOf(_plasmaVault);
        uint256 expectedWstEthAmount = IWstETH(_wstETH_ADDRESS).getWstETHByStETH(100e18);

        //when
        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(enterCalls);
        vm.stopPrank();

        //then

        uint256 wstEthBalanceAfter = ERC20(_wstETH_ADDRESS).balanceOf(_plasmaVault);
        uint256 plasmaVaultBalanceAfter = ERC20(_stETH_ADDRESS).balanceOf(_plasmaVault);

        assertEq(wstEthBalanceBefore, 0, "wstETH balance before should be 0");
        assertApproxEqAbs(plasmaVaultBalanceBefore, 100e18, _errorDelta, "stETH balance before should be 100");
        assertApproxEqAbs(wstEthBalanceAfter, expectedWstEthAmount, _errorDelta, "invalid wstETH balance");
        assertApproxEqAbs(plasmaVaultBalanceAfter, 0, _errorDelta, "stETH balance before should be 50");
    }

    function testShouldBeAbleUnwrap() external {
        // given
        uint256 stEthToWrap = 50e18;

        FuseAction[] memory enterCalls = new FuseAction[](1);

        enterCalls[0] = FuseAction({
            fuse: _stEthWrapperFuse,
            data: abi.encodeWithSignature("enter(uint256)", stEthToWrap)
        });

        uint256 wstEthBalanceBefore = ERC20(_wstETH_ADDRESS).balanceOf(_plasmaVault);
        uint256 plasmaVaultBalanceBefore = ERC20(_stETH_ADDRESS).balanceOf(_plasmaVault);
        uint256 expectedWstEthAmount = IWstETH(_wstETH_ADDRESS).getWstETHByStETH(stEthToWrap);

        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(enterCalls);
        vm.stopPrank();

        uint256 wstEthBalanceAfter = ERC20(_wstETH_ADDRESS).balanceOf(_plasmaVault);
        uint256 plasmaVaultBalanceAfter = ERC20(_stETH_ADDRESS).balanceOf(_plasmaVault);

        assertEq(wstEthBalanceBefore, 0, "wstETH balance before should be 0");
        assertApproxEqAbs(plasmaVaultBalanceBefore, 100e18, _errorDelta, "stETH balance before should be 100");
        assertApproxEqAbs(wstEthBalanceAfter, expectedWstEthAmount, _errorDelta, "invalid wstETH balance");
        assertApproxEqAbs(plasmaVaultBalanceAfter, 50e18, _errorDelta, "stETH balance before should be 50");

        FuseAction[] memory exitCalls = new FuseAction[](1);

        exitCalls[0] = FuseAction({
            fuse: _stEthWrapperFuse,
            data: abi.encodeWithSignature("exit(uint256)", wstEthBalanceAfter)
        });

        //when
        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(exitCalls);
        vm.stopPrank();

        //then
        wstEthBalanceAfter = ERC20(_wstETH_ADDRESS).balanceOf(_plasmaVault);
        plasmaVaultBalanceAfter = ERC20(_stETH_ADDRESS).balanceOf(_plasmaVault);

        assertApproxEqAbs(wstEthBalanceAfter, 0, _errorDelta, "invalid wstETH balance");
        assertApproxEqAbs(plasmaVaultBalanceAfter, 100e18, _errorDelta, "stETH balance before should be 50");
    }

    function testShouldBeAbleUnwrapSmallerAmountThanRequested() external {
        // given
        uint256 stEthToWrap = 50e18;

        FuseAction[] memory enterCalls = new FuseAction[](1);

        enterCalls[0] = FuseAction({
            fuse: _stEthWrapperFuse,
            data: abi.encodeWithSignature("enter(uint256)", stEthToWrap)
        });

        uint256 wstEthBalanceBefore = ERC20(_wstETH_ADDRESS).balanceOf(_plasmaVault);
        uint256 plasmaVaultBalanceBefore = ERC20(_stETH_ADDRESS).balanceOf(_plasmaVault);
        uint256 expectedWstEthAmount = IWstETH(_wstETH_ADDRESS).getWstETHByStETH(stEthToWrap);

        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(enterCalls);
        vm.stopPrank();

        uint256 wstEthBalanceAfter = ERC20(_wstETH_ADDRESS).balanceOf(_plasmaVault);
        uint256 plasmaVaultBalanceAfter = ERC20(_stETH_ADDRESS).balanceOf(_plasmaVault);

        assertEq(wstEthBalanceBefore, 0, "wstETH balance before should be 0");
        assertApproxEqAbs(plasmaVaultBalanceBefore, 100e18, _errorDelta, "stETH balance before should be 100");
        assertApproxEqAbs(wstEthBalanceAfter, expectedWstEthAmount, _errorDelta, "invalid wstETH balance");
        assertApproxEqAbs(plasmaVaultBalanceAfter, 50e18, _errorDelta, "stETH balance before should be 50");

        FuseAction[] memory exitCalls = new FuseAction[](1);

        exitCalls[0] = FuseAction({
            fuse: _stEthWrapperFuse,
            data: abi.encodeWithSignature("exit(uint256)", wstEthBalanceAfter + 10e18)
        });

        //when
        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(exitCalls);
        vm.stopPrank();

        //then
        wstEthBalanceAfter = ERC20(_wstETH_ADDRESS).balanceOf(_plasmaVault);
        plasmaVaultBalanceAfter = ERC20(_stETH_ADDRESS).balanceOf(_plasmaVault);

        assertApproxEqAbs(wstEthBalanceAfter, 0, _errorDelta, "invalid wstETH balance");
        assertApproxEqAbs(plasmaVaultBalanceAfter, 100e18, _errorDelta, "stETH balance before should be 50");
    }
}
