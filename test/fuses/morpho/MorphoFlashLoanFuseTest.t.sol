// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PlasmaVault, PlasmaVaultInitData, MarketBalanceFuseConfig, MarketSubstratesConfig, FuseAction, FeeConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {IporFusionAccessManagerInitializerLibV1, DataForInitialization, PlasmaVaultAddress, InitializationData} from "../../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {MorphoFlashLoanFuse, MorphoFlashLoanFuseEnterData} from "../../../contracts/fuses/morpho/MorphoFlashLoanFuse.sol";
import {MockInnerBalance} from "./MockInnerBalance.sol";
import {ZeroBalanceFuse} from "../../../contracts/fuses/ZeroBalanceFuse.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {CallbackHandlerMorpho} from "../../../contracts/handlers/callbacks/CallbackHandlerMorpho.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {FeeAccount} from "../../../contracts/managers/fee/FeeAccount.sol";

import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {PlasmaVaultConfigurator} from "../../utils/PlasmaVaultConfigurator.sol";

contract MorphoFlashLoanFuseTest is Test {
    address private constant _MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address private constant _ATOMIST = address(1111111);
    address private constant _ALPHA = address(2222222);
    address private constant _USER = address(12121212);
    address private constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant _USDC_HOLDER = 0x77EC2176824Df1145425EB51b3C88B9551847667;
    address private constant _DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address private constant _USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    address private _plasmaVault;
    address private _priceOracle = 0x9838c0d15b439816D25d5fD1AEbd259EeddB66B4;
    address private _accessManager;
    address private _flashLoanFuse;
    address private _mockInnerBalance;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 20818075);
        vm.prank(_USDC_HOLDER);
        ERC20(_USDC).transfer(_USER, 10_000e6);
        _createAccessManager();
        _createPriceOracle();
        _createPlasmaVault();
        _initAccessManager();

        vm.startPrank(_USER);
        ERC20(_USDC).approve(_plasmaVault, 10_000e6);
        PlasmaVault(_plasmaVault).deposit(10_000e6, _USER);
        vm.stopPrank();
    }

    function _createPlasmaVault() private {
        address withdrawManager = address(new WithdrawManager(_accessManager));

        vm.startPrank(_ATOMIST);
        _plasmaVault = address(
            new PlasmaVault(
                PlasmaVaultInitData({
                    assetName: "PLASMA VAULT",
                    assetSymbol: "PLASMA",
                    underlyingToken: _USDC,
                    priceOracleMiddleware: _priceOracle,
                    feeConfig: _setupFeeConfig(),
                    accessManager: _accessManager,
                    plasmaVaultBase: address(new PlasmaVaultBase()),
                    withdrawManager: withdrawManager
                })
            )
        );
        vm.stopPrank();

        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            _ATOMIST,
            address(_plasmaVault),
            _createFuse(),
            _setupBalanceFuses(),
            _setupMarketConfigs()
        );
    }

    function _setupMarketConfigs() private returns (MarketSubstratesConfig[] memory marketConfigs) {
        marketConfigs = new MarketSubstratesConfig[](1);
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(_DAI);

        marketConfigs[0] = MarketSubstratesConfig({
            marketId: IporFusionMarkets.MORPHO_FLASH_LOAN,
            substrates: substrates
        });
    }

    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses) {
        balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig({
            marketId: IporFusionMarkets.MORPHO_FLASH_LOAN,
            fuse: address(new ZeroBalanceFuse(IporFusionMarkets.MORPHO_FLASH_LOAN))
        });
    }

    function _setupFeeConfig() private returns (FeeConfig memory feeConfig) {
        feeConfig = FeeConfigHelper.createZeroFeeConfig();
    }

    function _createFuse() private returns (address[] memory) {
        address[] memory fuses = new address[](2);
        fuses[0] = address(new MorphoFlashLoanFuse(IporFusionMarkets.MORPHO_FLASH_LOAN, _MORPHO));
        fuses[1] = address(new MockInnerBalance(IporFusionMarkets.MORPHO_FLASH_LOAN, _DAI));
        _flashLoanFuse = fuses[0];
        _mockInnerBalance = fuses[1];
        return fuses;
    }

    function _createAccessManager() private {
        _accessManager = address(new IporFusionAccessManager(_ATOMIST, 0));
    }

    function _createPriceOracle() private {
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf);

        _priceOracle = address(
            new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
        );
    }

    function _initAccessManager() private {
        address[] memory initAddress = new address[](3);
        initAddress[0] = address(this);
        initAddress[1] = _ATOMIST;
        initAddress[2] = _ALPHA;

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

    function testShouldNotPassWhenCallBackHandlerNotAdded() external {
        // given
        FuseAction[] memory callbackCalls = new FuseAction[](1);
        callbackCalls[0] = FuseAction(_mockInnerBalance, abi.encodeWithSignature("enter()"));

        MorphoFlashLoanFuseEnterData memory dataFlashLoan = MorphoFlashLoanFuseEnterData({
            token: _DAI,
            tokenAmount: 100e18,
            callbackFuseActionsData: abi.encode(callbackCalls)
        });

        FuseAction[] memory morphoFlashCalls = new FuseAction[](1);
        morphoFlashCalls[0] = FuseAction(
            address(_flashLoanFuse),
            abi.encodeWithSignature("enter((address,uint256,bytes))", dataFlashLoan)
        );

        bytes memory error = abi.encodeWithSignature("HandlerNotFound()");

        // when
        vm.expectRevert(error);
        PlasmaVault(_plasmaVault).execute(morphoFlashCalls);
    }

    function testShouldGetAndRepayFlashLoan() external {
        // given
        FuseAction[] memory callbackCalls = new FuseAction[](1);
        callbackCalls[0] = FuseAction(_mockInnerBalance, abi.encodeWithSignature("enter()"));

        MorphoFlashLoanFuseEnterData memory dataFlashLoan = MorphoFlashLoanFuseEnterData({
            token: _DAI,
            tokenAmount: 100e18,
            callbackFuseActionsData: abi.encode(callbackCalls)
        });

        FuseAction[] memory morphoFlashCalls = new FuseAction[](1);
        morphoFlashCalls[0] = FuseAction(
            address(_flashLoanFuse),
            abi.encodeWithSignature("enter((address,uint256,bytes))", dataFlashLoan)
        );

        CallbackHandlerMorpho callbackHandler = new CallbackHandlerMorpho();

        vm.startPrank(_ATOMIST);
        PlasmaVaultGovernance(_plasmaVault).updateCallbackHandler(
            address(callbackHandler),
            _MORPHO,
            CallbackHandlerMorpho.onMorphoFlashLoan.selector
        );

        // when
        vm.recordLogs();
        PlasmaVault(_plasmaVault).execute(morphoFlashCalls);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // then
        (address token, uint256 amount) = _extractMockInnerBalanceEvent(entries);

        assertEq(token, _DAI, "Token should be DAI");
        assertEq(amount, 100e18, "Amount should be 100e6");
    }

    function testShouldNotBeAbleUseNotApprovedToken() external {
        // given
        FuseAction[] memory callbackCalls = new FuseAction[](1);
        callbackCalls[0] = FuseAction(_mockInnerBalance, abi.encodeWithSignature("enter()"));

        MorphoFlashLoanFuseEnterData memory dataFlashLoan = MorphoFlashLoanFuseEnterData({
            token: _USDT,
            tokenAmount: 100e6,
            callbackFuseActionsData: abi.encode(callbackCalls)
        });

        FuseAction[] memory morphoFlashCalls = new FuseAction[](1);
        morphoFlashCalls[0] = FuseAction(
            address(_flashLoanFuse),
            abi.encodeWithSignature("enter((address,uint256,bytes))", dataFlashLoan)
        );

        CallbackHandlerMorpho callbackHandler = new CallbackHandlerMorpho();

        bytes memory error = abi.encodeWithSignature("MorphoFlashLoanFuseUnsupportedToken(address)", _USDT);

        vm.startPrank(_ATOMIST);
        PlasmaVaultGovernance(_plasmaVault).updateCallbackHandler(
            address(callbackHandler),
            _MORPHO,
            CallbackHandlerMorpho.onMorphoFlashLoan.selector
        );

        // when
        vm.expectRevert(error);
        PlasmaVault(_plasmaVault).execute(morphoFlashCalls);
    }

    function _extractMockInnerBalanceEvent(
        Vm.Log[] memory entries
    ) private view returns (address token, uint256 amount) {
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == keccak256("MockInnerBalance(address,uint256)")) {
                (token, amount) = abi.decode(entries[i].data, (address, uint256));
                break;
            }
        }
    }
}
