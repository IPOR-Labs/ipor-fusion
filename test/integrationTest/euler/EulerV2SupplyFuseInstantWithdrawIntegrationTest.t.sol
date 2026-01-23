// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IEVC} from "ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";

import {EulerV2SupplyFuse, EulerV2SupplyFuseEnterData, EulerV2SupplyFuseExitData} from "../../../contracts/fuses/euler/EulerV2SupplyFuse.sol";
import {EulerV2BalanceFuse} from "../../../contracts/fuses/euler/EulerV2BalanceFuse.sol";
import {EulerFuseLib, EulerSubstrate} from "../../../contracts/fuses/euler/EulerFuseLib.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
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

/// @title EulerV2SupplyFuseInstantWithdrawIntegrationTest
/// @notice Fork integration tests for instant withdraw on Ethereum mainnet
contract EulerV2SupplyFuseInstantWithdrawIntegrationTest is Test {
    // ============ Mainnet Addresses ============

    address private constant _EVC = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;
    address private constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // Euler V2 USDC Vault (eUSDC-1) - used for instant withdraw
    address private constant EULER_VAULT_USDC = 0xB93d4928f39fBcd6C89a7DFbF0A867E6344561bE;

    // Chainlink Oracle
    address private constant _CHAINLINK_REGISTRY = 0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf;
    address private constant _USDC_USD_CHAINLINK = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;

    // Test accounts
    address private constant _ATOMIST = address(0x111111);
    address private constant _USER = address(0x222222);

    // Sub-accounts
    bytes1 private constant _SUB_ACCOUNT_INSTANT = 0x01; // For instant withdraw
    bytes1 private constant _SUB_ACCOUNT_COLLATERAL = 0x02; // For collateral (comparison)

    // ============ Fork Configuration ============

    uint256 public constant FORK_BLOCK = 20990348; // Same as EulerV2CreditMarket

    // ============ State Variables ============

    address private _plasmaVault;
    address private _priceOracle;
    address private _accessManager;
    address private _eulerSupplyFuse;

    address private _subAccountInstantAddress;
    address private _subAccountCollateralAddress;

    // ============ Events ============

    event EulerV2SupplyEnterFuse(address version, address eulerVault, uint256 supplyAmount, address subAccount);
    event EulerV2SupplyExitFuse(address version, address eulerVault, uint256 withdrawnAmount, address subAccount);

    // ============ Setup ============

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), FORK_BLOCK);

        _priceOracle = _createPriceOracle();
        _accessManager = _createAccessManager();
        address withdrawManager = address(new WithdrawManager(_accessManager));

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
                withdrawManager: withdrawManager
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
            _setupMarketConfigsErc20()
        );

        _initAccessManager();
        _grantMarketSubstratesForEuler();
        _initialDepositIntoPlasmaVault();

        _subAccountInstantAddress = EulerFuseLib.generateSubAccountAddress(_plasmaVault, _SUB_ACCOUNT_INSTANT);
        _subAccountCollateralAddress = EulerFuseLib.generateSubAccountAddress(_plasmaVault, _SUB_ACCOUNT_COLLATERAL);

        // Label addresses
        vm.label(_plasmaVault, "PlasmaVault");
        vm.label(_eulerSupplyFuse, "EulerV2SupplyFuse");
        vm.label(EULER_VAULT_USDC, "EulerVaultUSDC");
        vm.label(_subAccountInstantAddress, "SubAccountInstant");
        vm.label(_subAccountCollateralAddress, "SubAccountCollateral");
    }

    // ============ Test 1: Full Instant Withdraw Flow ============

    function testShouldInstantWithdrawFromEulerV2OnMainnetFork() public {
        // given - Enter with some USDC
        uint256 supplyAmount = 1000e6; // 1000 USDC

        FuseAction[] memory enterActions = new FuseAction[](1);
        enterActions[0] = FuseAction({
            fuse: _eulerSupplyFuse,
            data: abi.encodeWithSignature(
                "enter((address,uint256,bytes1))",
                EulerV2SupplyFuseEnterData({
                    eulerVault: EULER_VAULT_USDC,
                    maxAmount: supplyAmount,
                    subAccount: _SUB_ACCOUNT_INSTANT
                })
            )
        });

        vm.prank(_ATOMIST);
        PlasmaVault(_plasmaVault).execute(enterActions);

        // Check balance after enter
        uint256 balanceAfterEnter = ERC20(EULER_VAULT_USDC).balanceOf(_subAccountInstantAddress);
        assertGt(balanceAfterEnter, 0, "Should have shares after enter");

        // when - Instant withdraw
        bytes32[] memory params = new bytes32[](3);
        params[0] = bytes32(supplyAmount);
        params[1] = PlasmaVaultConfigLib.addressToBytes32(EULER_VAULT_USDC);
        params[2] = bytes32(_SUB_ACCOUNT_INSTANT);

        uint256 usdcBefore = ERC20(_USDC).balanceOf(_plasmaVault);

        FuseAction[] memory instantWithdrawActions = new FuseAction[](1);
        instantWithdrawActions[0] = FuseAction({
            fuse: _eulerSupplyFuse,
            data: abi.encodeWithSignature("instantWithdraw(bytes32[])", params)
        });

        vm.prank(_ATOMIST);
        PlasmaVault(_plasmaVault).execute(instantWithdrawActions);

        // then - Verify USDC increased
        uint256 usdcAfter = ERC20(_USDC).balanceOf(_plasmaVault);
        assertGt(usdcAfter, usdcBefore, "USDC balance should increase after instant withdraw");
    }

    // ============ Test 2: Enter and Instant Withdraw ============

    function testShouldEnterAndInstantWithdrawOnMainnetFork() public {
        // given
        uint256 supplyAmount = 500e6; // 500 USDC
        uint256 usdcInitial = ERC20(_USDC).balanceOf(_plasmaVault);

        // when - Enter
        FuseAction[] memory enterActions = new FuseAction[](1);
        enterActions[0] = FuseAction({
            fuse: _eulerSupplyFuse,
            data: abi.encodeWithSignature(
                "enter((address,uint256,bytes1))",
                EulerV2SupplyFuseEnterData({
                    eulerVault: EULER_VAULT_USDC,
                    maxAmount: supplyAmount,
                    subAccount: _SUB_ACCOUNT_INSTANT
                })
            )
        });

        vm.prank(_ATOMIST);
        PlasmaVault(_plasmaVault).execute(enterActions);

        // then - Instant withdraw all
        bytes32[] memory params = new bytes32[](3);
        params[0] = bytes32(type(uint256).max); // Withdraw max
        params[1] = PlasmaVaultConfigLib.addressToBytes32(EULER_VAULT_USDC);
        params[2] = bytes32(_SUB_ACCOUNT_INSTANT);

        FuseAction[] memory withdrawActions = new FuseAction[](1);
        withdrawActions[0] = FuseAction({
            fuse: _eulerSupplyFuse,
            data: abi.encodeWithSignature("instantWithdraw(bytes32[])", params)
        });

        vm.prank(_ATOMIST);
        PlasmaVault(_plasmaVault).execute(withdrawActions);

        // Verify we got back most of our USDC (allowing for rounding)
        uint256 usdcFinal = ERC20(_USDC).balanceOf(_plasmaVault);
        assertApproxEqAbs(usdcFinal, usdcInitial, 10, "Should recover most USDC");
    }

    // ============ Test 3: Real Protocol State ============

    function testShouldHandleRealEulerProtocolState() public {
        // given - Query real protocol state
        uint256 totalAssets = ERC20(EULER_VAULT_USDC).totalSupply();
        assertGt(totalAssets, 0, "Euler vault should have total assets");

        // when/then - Should be able to interact with real state
        uint256 supplyAmount = 100e6; // Small amount

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: _eulerSupplyFuse,
            data: abi.encodeWithSignature(
                "enter((address,uint256,bytes1))",
                EulerV2SupplyFuseEnterData({
                    eulerVault: EULER_VAULT_USDC,
                    maxAmount: supplyAmount,
                    subAccount: _SUB_ACCOUNT_INSTANT
                })
            )
        });

        vm.prank(_ATOMIST);
        PlasmaVault(_plasmaVault).execute(actions);

        // Verify shares received
        uint256 shares = ERC20(EULER_VAULT_USDC).balanceOf(_subAccountInstantAddress);
        assertGt(shares, 0, "Should receive shares from real Euler protocol");
    }

    // ============ Test 4: Max Amount Withdraw ============

    function testShouldInstantWithdrawMaxAmount() public {
        // given - Supply some USDC
        uint256 supplyAmount = 2000e6;

        FuseAction[] memory enterActions = new FuseAction[](1);
        enterActions[0] = FuseAction({
            fuse: _eulerSupplyFuse,
            data: abi.encodeWithSignature(
                "enter((address,uint256,bytes1))",
                EulerV2SupplyFuseEnterData({
                    eulerVault: EULER_VAULT_USDC,
                    maxAmount: supplyAmount,
                    subAccount: _SUB_ACCOUNT_INSTANT
                })
            )
        });

        vm.prank(_ATOMIST);
        PlasmaVault(_plasmaVault).execute(enterActions);

        uint256 sharesBefore = ERC20(EULER_VAULT_USDC).balanceOf(_subAccountInstantAddress);

        // when - Withdraw with max amount (type(uint256).max)
        bytes32[] memory params = new bytes32[](3);
        params[0] = bytes32(type(uint256).max);
        params[1] = PlasmaVaultConfigLib.addressToBytes32(EULER_VAULT_USDC);
        params[2] = bytes32(_SUB_ACCOUNT_INSTANT);

        FuseAction[] memory withdrawActions = new FuseAction[](1);
        withdrawActions[0] = FuseAction({
            fuse: _eulerSupplyFuse,
            data: abi.encodeWithSignature("instantWithdraw(bytes32[])", params)
        });

        vm.prank(_ATOMIST);
        PlasmaVault(_plasmaVault).execute(withdrawActions);

        // then - All shares should be withdrawn
        uint256 sharesAfter = ERC20(EULER_VAULT_USDC).balanceOf(_subAccountInstantAddress);
        assertEq(sharesAfter, 0, "All shares should be withdrawn");
        assertGt(sharesBefore, 0, "Should have had shares before");
    }

    // ============ Test 5: Multiple Sub-Accounts ============

    function testShouldHandleMultipleSubAccounts() public {
        // given - Supply to two different sub-accounts
        uint256 amount1 = 300e6;
        uint256 amount2 = 700e6;

        // Supply to instant withdraw sub-account
        FuseAction[] memory enter1 = new FuseAction[](1);
        enter1[0] = FuseAction({
            fuse: _eulerSupplyFuse,
            data: abi.encodeWithSignature(
                "enter((address,uint256,bytes1))",
                EulerV2SupplyFuseEnterData({
                    eulerVault: EULER_VAULT_USDC,
                    maxAmount: amount1,
                    subAccount: _SUB_ACCOUNT_INSTANT
                })
            )
        });

        vm.prank(_ATOMIST);
        PlasmaVault(_plasmaVault).execute(enter1);

        // Supply to collateral sub-account
        FuseAction[] memory enter2 = new FuseAction[](1);
        enter2[0] = FuseAction({
            fuse: _eulerSupplyFuse,
            data: abi.encodeWithSignature(
                "enter((address,uint256,bytes1))",
                EulerV2SupplyFuseEnterData({
                    eulerVault: EULER_VAULT_USDC,
                    maxAmount: amount2,
                    subAccount: _SUB_ACCOUNT_COLLATERAL
                })
            )
        });

        vm.prank(_ATOMIST);
        PlasmaVault(_plasmaVault).execute(enter2);

        // when - Instant withdraw from first sub-account only
        bytes32[] memory params = new bytes32[](3);
        params[0] = bytes32(type(uint256).max);
        params[1] = PlasmaVaultConfigLib.addressToBytes32(EULER_VAULT_USDC);
        params[2] = bytes32(_SUB_ACCOUNT_INSTANT);

        FuseAction[] memory withdrawActions = new FuseAction[](1);
        withdrawActions[0] = FuseAction({
            fuse: _eulerSupplyFuse,
            data: abi.encodeWithSignature("instantWithdraw(bytes32[])", params)
        });

        vm.prank(_ATOMIST);
        PlasmaVault(_plasmaVault).execute(withdrawActions);

        // then - Only instant sub-account should be empty
        uint256 sharesInstant = ERC20(EULER_VAULT_USDC).balanceOf(_subAccountInstantAddress);
        uint256 sharesCollateral = ERC20(EULER_VAULT_USDC).balanceOf(_subAccountCollateralAddress);

        assertEq(sharesInstant, 0, "Instant sub-account should be empty");
        assertGt(sharesCollateral, 0, "Collateral sub-account should still have shares");
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
        address[] memory sources = new address[](1);

        assets[0] = _USDC;
        sources[0] = _USDC_USD_CHAINLINK;

        priceOracle.setAssetsPricesSources(assets, sources);

        return address(priceOracle);
    }

    function _createAccessManager() private returns (address) {
        return address(new IporFusionAccessManager(_ATOMIST, 0));
    }

    function _setupFuses() private returns (address[] memory fuses) {
        _eulerSupplyFuse = address(new EulerV2SupplyFuse(IporFusionMarkets.EULER_V2, _EVC));

        fuses = new address[](1);
        fuses[0] = _eulerSupplyFuse;
    }

    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses) {
        EulerV2BalanceFuse eulerBalance = new EulerV2BalanceFuse(IporFusionMarkets.EULER_V2, _EVC);
        ERC20BalanceFuse erc20Balance = new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE);

        balanceFuses = new MarketBalanceFuseConfig[](2);
        balanceFuses[0] = MarketBalanceFuseConfig(IporFusionMarkets.EULER_V2, address(eulerBalance));
        balanceFuses[1] = MarketBalanceFuseConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, address(erc20Balance));
    }

    function _setupMarketConfigsErc20() private returns (MarketSubstratesConfig[] memory marketConfigs) {
        marketConfigs = new MarketSubstratesConfig[](1);

        bytes32[] memory tokens = new bytes32[](1);
        tokens[0] = PlasmaVaultConfigLib.addressToBytes32(_USDC);

        marketConfigs[0] = MarketSubstratesConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, tokens);
    }

    function _setupFeeConfig() private returns (FeeConfig memory) {
        return FeeConfigHelper.createZeroFeeConfig();
    }

    function _grantMarketSubstratesForEuler() private {
        bytes32[] memory substrates = new bytes32[](2);

        // Substrate for instant withdraw (isCollateral=false, canBorrow=false)
        substrates[0] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({
                eulerVault: EULER_VAULT_USDC,
                isCollateral: false,
                canBorrow: false,
                subAccounts: _SUB_ACCOUNT_INSTANT
            })
        );

        // Substrate with isCollateral=true (for comparison tests)
        substrates[1] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({
                eulerVault: EULER_VAULT_USDC,
                isCollateral: true,
                canBorrow: false,
                subAccounts: _SUB_ACCOUNT_COLLATERAL
            })
        );

        vm.prank(_ATOMIST);
        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(IporFusionMarkets.EULER_V2, substrates);
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
        // Give USDC to user
        vm.prank(0x4B16c5dE96EB2117bBE5fd171E4d203624B014aa); // USDC whale
        ERC20(_USDC).transfer(_USER, 10_000e6);

        // User deposits into PlasmaVault
        vm.startPrank(_USER);
        ERC20(_USDC).approve(_plasmaVault, 10_000e6);
        PlasmaVault(_plasmaVault).deposit(10_000e6, _USER);
        vm.stopPrank();

        // Update balances
        uint256[] memory marketIds = new uint256[](2);
        marketIds[0] = IporFusionMarkets.EULER_V2;
        marketIds[1] = IporFusionMarkets.ERC20_VAULT_BALANCE;

        PlasmaVault(_plasmaVault).updateMarketsBalances(marketIds);
    }
}
