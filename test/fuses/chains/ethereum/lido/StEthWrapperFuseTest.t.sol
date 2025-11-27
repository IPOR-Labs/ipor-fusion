// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {StEthWrapperFuse} from "../../../../../contracts/fuses/chains/ethereum/lido/StEthWrapperFuse.sol";
import {ERC20BalanceFuse} from "../../../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {TransientStorageSetInputsFuse, TransientStorageSetInputsFuseEnterData} from "../../../../../contracts/fuses/transient_storage/TransientStorageSetInputsFuse.sol";
import {IporFusionMarkets} from "../../../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultConfigLib} from "../../../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {TypeConversionLib} from "../../../../../contracts/libraries/TypeConversionLib.sol";
import {Errors} from "../../../../../contracts/libraries/errors/Errors.sol";
import {IporFusionAccessManager} from "../../../../../contracts/managers/access/IporFusionAccessManager.sol";
import {FeeAccount} from "../../../../../contracts/managers/fee/FeeAccount.sol";
import {WithdrawManager} from "../../../../../contracts/managers/withdraw/WithdrawManager.sol";
import {PriceOracleMiddleware} from "../../../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {WstETHPriceFeedEthereum} from "../../../../../contracts/price_oracle/price_feed/chains/ethereum/WstETHPriceFeedEthereum.sol";
import {PlasmaVault, PlasmaVaultInitData, FuseAction, FeeConfig, MarketSubstratesConfig, MarketBalanceFuseConfig} from "../../../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../../../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManagerInitializerLibV1, InitializationData, DataForInitialization, PlasmaVaultAddress} from "../../../../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {FeeConfigHelper} from "../../../../test_helpers/FeeConfigHelper.sol";
import {PlasmaVaultConfigurator} from "../../../../utils/PlasmaVaultConfigurator.sol";
import {IWstETH} from "./IWstETH.sol";

/// @title StEthWrapperFuseTest
/// @notice Tests for StEthWrapperFuse
/// @author IPOR Labs
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
    address private _transientStorageSetInputsFuse;

    /// @notice Setup the test environment
    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 23041700);

        _priceOracle = _createPriceOracle();

        address accessManager = _createAccessManager();
        address withdrawManager = address(new WithdrawManager(accessManager));

        // plasma vault
        vm.startPrank(_ATOMIST);
        _plasmaVault = address(new PlasmaVault());
        PlasmaVault(_plasmaVault).proxyInitialize(
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

    /// @notice Create price oracle
    /// @return Address of the price oracle
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

    /// @notice Setup market configs
    /// @return marketConfigs_ Array of market configs
    function _setupMarketConfigsErc20() private returns (MarketSubstratesConfig[] memory marketConfigs_) {
        marketConfigs_ = new MarketSubstratesConfig[](1);

        bytes32[] memory tokens = new bytes32[](3);
        tokens[0] = PlasmaVaultConfigLib.addressToBytes32(_WETH_ADDRESS);
        tokens[1] = PlasmaVaultConfigLib.addressToBytes32(_stETH_ADDRESS);
        tokens[2] = PlasmaVaultConfigLib.addressToBytes32(_wstETH_ADDRESS);

        marketConfigs_[0] = MarketSubstratesConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, tokens);
    }

    /// @notice Setup fuses
    /// @return fuses Array of fuses
    function _setupFuses() private returns (address[] memory fuses) {
        _stEthWrapperFuse = address(new StEthWrapperFuse(IporFusionMarkets.ERC20_VAULT_BALANCE));
        _transientStorageSetInputsFuse = address(new TransientStorageSetInputsFuse());

        fuses = new address[](2);
        fuses[0] = address(_stEthWrapperFuse);
        fuses[1] = address(_transientStorageSetInputsFuse);
    }

    /// @notice Setup balance fuses
    /// @return balanceFuses_ Array of balance fuses
    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses_) {
        ERC20BalanceFuse erc20Balance = new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE);

        balanceFuses_ = new MarketBalanceFuseConfig[](1);
        balanceFuses_[0] = MarketBalanceFuseConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, address(erc20Balance));
    }

    /// @notice Setup fee config
    /// @return feeConfig Fee configuration
    function _setupFeeConfig() private returns (FeeConfig memory feeConfig) {
        feeConfig = FeeConfigHelper.createZeroFeeConfig();
    }

    /// @notice Create access manager
    /// @return accessManager_ Address of the access manager
    function _createAccessManager() private returns (address accessManager_) {
        accessManager_ = address(new IporFusionAccessManager(_ATOMIST, 0));
        _accessManager = accessManager_;
    }

    /// @notice Initialize access manager
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

    /// @notice Initial deposit into plasma vault
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

    /// @notice Tests wrapping stETH to wstETH
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

    /// @notice Tests wrapping stETH to wstETH with smaller amount than requested
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

    /// @notice Tests unwrapping wstETH to stETH
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

    /// @notice Tests unwrapping wstETH to stETH with smaller amount than requested
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

    /// @notice Tests entering the wrapper via transient storage inputs
    function testShouldEnterTransient() external {
        // given
        uint256 stEthToWrap = 50e18;
        address fuseAddress = _stEthWrapperFuse;

        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = TypeConversionLib.toBytes32(stEthToWrap);

        address[] memory fuses = new address[](1);
        fuses[0] = fuseAddress;
        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = inputs;

        TransientStorageSetInputsFuseEnterData memory inputData = TransientStorageSetInputsFuseEnterData({
            fuse: fuses,
            inputsByFuse: inputsByFuse
        });

        FuseAction[] memory enterCalls = new FuseAction[](2);

        enterCalls[0] = FuseAction({
            fuse: _transientStorageSetInputsFuse,
            data: abi.encodeWithSelector(TransientStorageSetInputsFuse.enter.selector, inputData)
        });
        enterCalls[1] = FuseAction({fuse: _stEthWrapperFuse, data: abi.encodeWithSignature("enterTransient()")});

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

    /// @notice Tests exiting the wrapper via transient storage inputs
    function testShouldExitTransient() external {
        // given
        uint256 stEthToWrap = 50e18;

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction({
            fuse: _stEthWrapperFuse,
            data: abi.encodeWithSignature("enter(uint256)", stEthToWrap)
        });
        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(enterCalls);
        vm.stopPrank();

        uint256 wstEthBalanceAfterWrap = ERC20(_wstETH_ADDRESS).balanceOf(_plasmaVault);

        address fuseAddress = _stEthWrapperFuse;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = TypeConversionLib.toBytes32(wstEthBalanceAfterWrap);

        address[] memory fuses = new address[](1);
        fuses[0] = fuseAddress;
        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = inputs;

        TransientStorageSetInputsFuseEnterData memory inputData = TransientStorageSetInputsFuseEnterData({
            fuse: fuses,
            inputsByFuse: inputsByFuse
        });

        FuseAction[] memory exitCalls = new FuseAction[](2);
        exitCalls[0] = FuseAction({
            fuse: _transientStorageSetInputsFuse,
            data: abi.encodeWithSelector(TransientStorageSetInputsFuse.enter.selector, inputData)
        });
        exitCalls[1] = FuseAction({fuse: _stEthWrapperFuse, data: abi.encodeWithSignature("exitTransient()")});

        //when
        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(exitCalls);
        vm.stopPrank();

        //then
        uint256 wstEthBalanceAfter = ERC20(_wstETH_ADDRESS).balanceOf(_plasmaVault);
        uint256 plasmaVaultBalanceAfter = ERC20(_stETH_ADDRESS).balanceOf(_plasmaVault);

        assertApproxEqAbs(wstEthBalanceAfter, 0, _errorDelta, "invalid wstETH balance");
        assertApproxEqAbs(plasmaVaultBalanceAfter, 100e18, _errorDelta, "stETH balance after should be 100");
    }

    /// @notice Tests entering with zero amount
    function testShouldReturnWhenEnteringWithZeroAmount() external {
        // given
        uint256 stEthToWrap = 0;

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction({
            fuse: _stEthWrapperFuse,
            data: abi.encodeWithSignature("enter(uint256)", stEthToWrap)
        });

        uint256 wstEthBalanceBefore = ERC20(_wstETH_ADDRESS).balanceOf(_plasmaVault);
        uint256 plasmaVaultBalanceBefore = ERC20(_stETH_ADDRESS).balanceOf(_plasmaVault);

        //when
        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(enterCalls);
        vm.stopPrank();

        //then
        uint256 wstEthBalanceAfter = ERC20(_wstETH_ADDRESS).balanceOf(_plasmaVault);
        uint256 plasmaVaultBalanceAfter = ERC20(_stETH_ADDRESS).balanceOf(_plasmaVault);

        assertEq(wstEthBalanceAfter, wstEthBalanceBefore, "wstETH balance should not change");
        assertEq(plasmaVaultBalanceAfter, plasmaVaultBalanceBefore, "stETH balance should not change");
    }

    /// @notice Tests exiting with zero amount
    function testShouldReturnWhenExitingWithZeroAmount() external {
        // given
        uint256 wstEthToUnwrap = 0;

        FuseAction[] memory exitCalls = new FuseAction[](1);
        exitCalls[0] = FuseAction({
            fuse: _stEthWrapperFuse,
            data: abi.encodeWithSignature("exit(uint256)", wstEthToUnwrap)
        });

        uint256 wstEthBalanceBefore = ERC20(_wstETH_ADDRESS).balanceOf(_plasmaVault);
        uint256 plasmaVaultBalanceBefore = ERC20(_stETH_ADDRESS).balanceOf(_plasmaVault);

        //when
        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(exitCalls);
        vm.stopPrank();

        //then
        uint256 wstEthBalanceAfter = ERC20(_wstETH_ADDRESS).balanceOf(_plasmaVault);
        uint256 plasmaVaultBalanceAfter = ERC20(_stETH_ADDRESS).balanceOf(_plasmaVault);

        assertEq(wstEthBalanceAfter, wstEthBalanceBefore, "wstETH balance should not change");
        assertEq(plasmaVaultBalanceAfter, plasmaVaultBalanceBefore, "stETH balance should not change");
    }

    /// @notice Tests entering transient with zero amount
    function testShouldReturnWhenEnteringTransientWithZeroAmount() external {
        // given
        address fuseAddress = _stEthWrapperFuse;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = TypeConversionLib.toBytes32(uint256(0));

        address[] memory fuses = new address[](1);
        fuses[0] = fuseAddress;
        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = inputs;

        TransientStorageSetInputsFuseEnterData memory inputData = TransientStorageSetInputsFuseEnterData({
            fuse: fuses,
            inputsByFuse: inputsByFuse
        });

        FuseAction[] memory enterCalls = new FuseAction[](2);
        enterCalls[0] = FuseAction({
            fuse: _transientStorageSetInputsFuse,
            data: abi.encodeWithSelector(TransientStorageSetInputsFuse.enter.selector, inputData)
        });
        enterCalls[1] = FuseAction({fuse: _stEthWrapperFuse, data: abi.encodeWithSignature("enterTransient()")});

        uint256 wstEthBalanceBefore = ERC20(_wstETH_ADDRESS).balanceOf(_plasmaVault);
        uint256 plasmaVaultBalanceBefore = ERC20(_stETH_ADDRESS).balanceOf(_plasmaVault);

        //when
        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(enterCalls);
        vm.stopPrank();

        //then
        uint256 wstEthBalanceAfter = ERC20(_wstETH_ADDRESS).balanceOf(_plasmaVault);
        uint256 plasmaVaultBalanceAfter = ERC20(_stETH_ADDRESS).balanceOf(_plasmaVault);

        assertEq(wstEthBalanceAfter, wstEthBalanceBefore, "wstETH balance should not change");
        assertEq(plasmaVaultBalanceAfter, plasmaVaultBalanceBefore, "stETH balance should not change");
    }

    /// @notice Tests exiting transient with zero amount
    function testShouldReturnWhenExitingTransientWithZeroAmount() external {
        // given
        address fuseAddress = _stEthWrapperFuse;
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = TypeConversionLib.toBytes32(uint256(0));

        address[] memory fuses = new address[](1);
        fuses[0] = fuseAddress;
        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = inputs;

        TransientStorageSetInputsFuseEnterData memory inputData = TransientStorageSetInputsFuseEnterData({
            fuse: fuses,
            inputsByFuse: inputsByFuse
        });

        FuseAction[] memory exitCalls = new FuseAction[](2);
        exitCalls[0] = FuseAction({
            fuse: _transientStorageSetInputsFuse,
            data: abi.encodeWithSelector(TransientStorageSetInputsFuse.enter.selector, inputData)
        });
        exitCalls[1] = FuseAction({fuse: _stEthWrapperFuse, data: abi.encodeWithSignature("exitTransient()")});

        uint256 wstEthBalanceBefore = ERC20(_wstETH_ADDRESS).balanceOf(_plasmaVault);
        uint256 plasmaVaultBalanceBefore = ERC20(_stETH_ADDRESS).balanceOf(_plasmaVault);

        //when
        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(exitCalls);
        vm.stopPrank();

        //then
        uint256 wstEthBalanceAfter = ERC20(_wstETH_ADDRESS).balanceOf(_plasmaVault);
        uint256 plasmaVaultBalanceAfter = ERC20(_stETH_ADDRESS).balanceOf(_plasmaVault);

        assertEq(wstEthBalanceAfter, wstEthBalanceBefore, "wstETH balance should not change");
        assertEq(plasmaVaultBalanceAfter, plasmaVaultBalanceBefore, "stETH balance should not change");
    }

    /// @notice Tests constructor reverts with zero market id
    function testShouldRevertWhenMarketIdIsZero() external {
        vm.expectRevert(Errors.WrongValue.selector);
        new StEthWrapperFuse(0);
    }

    /// @notice Tests validation fails when asset is not supported
    function testShouldRevertWhenAssetIsNotSupported() external {
        // Deploy a fuse with a random market ID that doesn't have configured assets
        address badFuse = address(new StEthWrapperFuse(99999));

        address[] memory fuses = new address[](1);
        fuses[0] = badFuse;
        vm.startPrank(_ATOMIST);
        PlasmaVaultGovernance(_plasmaVault).addFuses(fuses);
        vm.stopPrank();

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction({fuse: badFuse, data: abi.encodeWithSignature("enter(uint256)", 10e18)});

        vm.startPrank(_ALPHA);
        // The revert happens inside the fuse via delegatecall.
        // The fuse checks underlyingAsset (stETH) vs ST_ETH (match)
        // So _validateSubstrates passes the first check.
        // But it fails the second check: underlyingAsset (stETH) != WST_ETH (True)
        // AND isSubstrateAsAssetGranted(99999, WST_ETH) -> False
        // So it should revert StEthWrapperFuseUnsupportedAsset("enter", WST_ETH)
        vm.expectRevert(
            abi.encodeWithSelector(StEthWrapperFuse.StEthWrapperFuseUnsupportedAsset.selector, "enter", _wstETH_ADDRESS)
        );
        PlasmaVault(_plasmaVault).execute(enterCalls);
        vm.stopPrank();
    }
}
