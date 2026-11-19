// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IEVC} from "ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";

import {
    EulerV2SupplyFuse,
    EulerV2SupplyFuseEnterData,
    EulerV2SupplyFuseExitData
} from "../../../contracts/fuses/euler/EulerV2SupplyFuse.sol";
import {
    EulerV2CollateralFuse,
    EulerV2CollateralFuseEnterData
} from "../../../contracts/fuses/euler/EulerV2CollateralFuse.sol";
import {EulerV2BalanceFuse} from "../../../contracts/fuses/euler/EulerV2BalanceFuse.sol";
import {EulerFuseLib, EulerSubstrate} from "../../../contracts/fuses/euler/EulerFuseLib.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {InstantWithdrawalFusesParamsStruct} from "../../../contracts/libraries/PlasmaVaultLib.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVault, PlasmaVaultInitData, FeeConfig} from "../../../contracts/vaults/PlasmaVault.sol";
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

/// @title EulerV2SupplyFuseInstantWithdrawCollateralForkTest
/// @notice IL-9644 (L13): a position whose Euler vault is enabled as collateral of the sub-account in the EVC is
///         skipped by the instant withdraw path of EulerV2SupplyFuse, even when the substrate was later re-granted
///         without flags. The skip is not a revert: the user withdrawal is served by the next fuse in the list.
///         Real EVC and Euler V2 EVaults on a mainnet fork, a real PlasmaVault and the real withdrawFromMarkets loop.
contract EulerV2SupplyFuseInstantWithdrawCollateralForkTest is Test {
    address private constant _EVC = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;
    address private constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant _W_ETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @dev Venue A (drained to low cash) and venue B (liquid), both real Euler V2 USDC EVaults
    address private constant EULER_VAULT_PRIME_USDC = 0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9;
    address private constant EULER_VAULT_USDC = 0xB93d4928f39fBcd6C89a7DFbF0A867E6344561bE;
    /// @dev WETH EVault, accepted as collateral by Prime USDC (see EulerV2CreditMarket.t.sol)
    address private constant EULER_VAULT_WETH = 0xb3b36220fA7d12f7055dab5c9FD18E860e9a6bF8;

    address private constant _CHAINLINK_REGISTRY = 0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf;
    address private constant _USDC_USD_CHAINLINK = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address private constant _USDC_WHALE = 0x4B16c5dE96EB2117bBE5fd171E4d203624B014aa;

    address private constant _ATOMIST = address(0x111111);
    address private constant _USER = address(0x222222);

    bytes1 private constant _SUB_A = 0x01;
    bytes1 private constant _SUB_B = 0x02;

    /// @dev Own fork block: shared blocks share one backend and leak vm.warp between suites
    uint256 public constant FORK_BLOCK = 20990353;

    address private _plasmaVault;
    address private _accessManager;
    address private _withdrawManager;
    address private _eulerSupplyFuse;
    address private _eulerCollateralFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), FORK_BLOCK);

        address priceOracle = _createPriceOracle();
        _accessManager = address(new IporFusionAccessManager(_ATOMIST, 0));
        _withdrawManager = address(new WithdrawManager(_accessManager));

        vm.startPrank(_ATOMIST);
        _plasmaVault = address(PlasmaVaultCloneLib.newPlasmaVault());
        PlasmaVault(_plasmaVault).proxyInitialize(
            PlasmaVaultInitData({
                assetName: "Euler IW cash",
                assetSymbol: "eIWc",
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
            _setupMarketConfigsErc20()
        );

        _initAccessManager();
        _grantEulerSubstrates(true);

        vm.prank(_USDC_WHALE);
        ERC20(_USDC).transfer(_USER, 10_000e6);
        vm.startPrank(_USER);
        ERC20(_USDC).approve(_plasmaVault, 10_000e6);
        PlasmaVault(_plasmaVault).deposit(10_000e6, _USER);
        vm.stopPrank();
    }

    /// @notice Venue A was granted with isCollateral and its collateral was enabled in the EVC; the substrate was then
    ///         re-granted without flags. The instant withdraw skips venue A (position untouched) and venue B pays the
    ///         whole withdrawal: the user withdrawal does not revert
    function test_instantWithdrawSkipsVenueWithCollateralEnabledAfterUnflaggedRegrant() public {
        // given - collateral enabled through the flagged entry, then the list is re-granted without flags
        _allocate(4_000e6, 6_000e6);
        _enableCollateralOnVenueA();
        _grantEulerSubstrates(false);
        assertTrue(IEVC(_EVC).isCollateralEnabled(_subA(), EULER_VAULT_PRIME_USDC), "collateral enabled in the EVC");
        bytes32[] memory granted = PlasmaVaultGovernance(_plasmaVault).getMarketSubstrates(IporFusionMarkets.EULER_V2);
        assertEq(
            EulerFuseLib.bytes32ToSubstrate(granted[0]).isCollateral,
            false,
            "substrate list alone would allow the instant withdraw"
        );
        uint256 sharesA = IERC20(EULER_VAULT_PRIME_USDC).balanceOf(_subA());
        assertGt(sharesA, 0, "venue A holds a position");

        // when
        vm.recordLogs();
        vm.prank(_USER);
        PlasmaVault(_plasmaVault).withdraw(5_000e6, _USER, _USER);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // then
        assertEq(ERC20(_USDC).balanceOf(_USER), 5_000e6, "user received the payout");
        assertEq(_exitAmount(logs, EULER_VAULT_PRIME_USDC), 0, "venue A skipped");
        assertEq(IERC20(EULER_VAULT_PRIME_USDC).balanceOf(_subA()), sharesA, "venue A position untouched");
        assertEq(_exitAmount(logs, EULER_VAULT_USDC), 5_000e6 + 10, "venue B pays the whole withdrawal incl. offset");
        assertEq(_failedCount(logs), 0, "no ExitFailed event");
    }

    /// @notice IL-9644 / D-044: venue A is still granted with isCollateral (flagged entry): the instant path skips
    ///         it instead of reverting, so the user PlasmaVault.withdraw succeeds and venue B pays it
    function test_instantWithdrawSkipsFlaggedVenueWithoutRevert() public {
        // given - the setUp grant keeps venue A flagged (isCollateral = true)
        _allocate(4_000e6, 6_000e6);
        bytes32[] memory granted = PlasmaVaultGovernance(_plasmaVault).getMarketSubstrates(IporFusionMarkets.EULER_V2);
        assertTrue(EulerFuseLib.bytes32ToSubstrate(granted[0]).isCollateral, "venue A entry is flagged");
        uint256 sharesA = IERC20(EULER_VAULT_PRIME_USDC).balanceOf(_subA());
        assertGt(sharesA, 0, "venue A holds a position");

        // when
        vm.recordLogs();
        vm.prank(_USER);
        PlasmaVault(_plasmaVault).withdraw(5_000e6, _USER, _USER);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // then
        assertEq(ERC20(_USDC).balanceOf(_USER), 5_000e6, "user received the payout");
        assertEq(_exitAmount(logs, EULER_VAULT_PRIME_USDC), 0, "flagged venue A skipped");
        assertEq(IERC20(EULER_VAULT_PRIME_USDC).balanceOf(_subA()), sharesA, "venue A position untouched");
        assertEq(_exitAmount(logs, EULER_VAULT_USDC), 5_000e6 + 10, "venue B pays the whole withdrawal incl. offset");
        assertEq(_failedCount(logs), 0, "no ExitFailed event");
    }

    /// @notice Control: the same setup without enabling collateral in the EVC draws from venue A first
    function test_instantWithdrawDrawsFromVenueWithoutCollateralEnabled() public {
        // given
        _grantEulerSubstrates(false);
        _allocate(4_000e6, 6_000e6);
        assertFalse(IEVC(_EVC).isCollateralEnabled(_subA(), EULER_VAULT_PRIME_USDC), "collateral not enabled");

        // when
        vm.recordLogs();
        vm.prank(_USER);
        PlasmaVault(_plasmaVault).withdraw(3_000e6, _USER, _USER);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // then
        assertEq(ERC20(_USDC).balanceOf(_USER), 3_000e6, "user received the payout");
        assertEq(_exitAmount(logs, EULER_VAULT_PRIME_USDC), 3_000e6 + 10, "venue A pays incl. offset");
        assertEq(_exitAmount(logs, EULER_VAULT_USDC), 0, "venue B not used");
        assertEq(_failedCount(logs), 0, "no ExitFailed event");
    }

    /// @notice The normal ALPHA exit of the same position still works with collateral enabled
    function test_alphaExitStillWorksWithCollateralEnabled() public {
        // given
        _allocate(4_000e6, 6_000e6);
        _enableCollateralOnVenueA();
        uint256 idleBefore = ERC20(_USDC).balanceOf(_plasmaVault);

        FuseAction[] memory exits = new FuseAction[](1);
        exits[0] = FuseAction({
            fuse: _eulerSupplyFuse,
            data: abi.encodeWithSignature(
                "exit((address,uint256,bytes1))",
                EulerV2SupplyFuseExitData({eulerVault: EULER_VAULT_PRIME_USDC, maxAmount: 1_000e6, subAccount: _SUB_A})
            )
        });

        // when
        vm.prank(_ATOMIST);
        PlasmaVault(_plasmaVault).execute(exits);

        // then
        assertEq(ERC20(_USDC).balanceOf(_plasmaVault) - idleBefore, 1_000e6, "ALPHA exit withdrew");
    }

    // ============ helpers ============

    function _enableCollateralOnVenueA() private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: _eulerCollateralFuse,
            data: abi.encodeWithSignature(
                "enter((address,bytes1))",
                EulerV2CollateralFuseEnterData({eulerVault: EULER_VAULT_PRIME_USDC, subAccount: _SUB_A})
            )
        });
        vm.prank(_ATOMIST);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    /// @dev Allocates idle USDC to venue A (sub-account 0x01) and optionally B (0x02), sets the instant withdraw list
    function _allocate(uint256 amountA_, uint256 amountB_) private {
        FuseAction[] memory enter = new FuseAction[](2);
        enter[0] = FuseAction({
            fuse: _eulerSupplyFuse,
            data: abi.encodeWithSignature(
                "enter((address,uint256,bytes1))",
                EulerV2SupplyFuseEnterData({
                    eulerVault: EULER_VAULT_PRIME_USDC,
                    maxAmount: amountA_,
                    subAccount: _SUB_A
                })
            )
        });
        {
            enter[1] = FuseAction({
                fuse: _eulerSupplyFuse,
                data: abi.encodeWithSignature(
                    "enter((address,uint256,bytes1))",
                    EulerV2SupplyFuseEnterData({eulerVault: EULER_VAULT_USDC, maxAmount: amountB_, subAccount: _SUB_B})
                )
            });
        }
        vm.prank(_ATOMIST);
        PlasmaVault(_plasmaVault).execute(enter);
        assertEq(ERC20(_USDC).balanceOf(_plasmaVault), 0, "no idle USDC");

        InstantWithdrawalFusesParamsStruct[] memory iw = new InstantWithdrawalFusesParamsStruct[](2);
        iw[0] = InstantWithdrawalFusesParamsStruct({
            fuse: _eulerSupplyFuse,
            params: _iwParams(EULER_VAULT_PRIME_USDC, _SUB_A)
        });
        {
            iw[1] = InstantWithdrawalFusesParamsStruct({
                fuse: _eulerSupplyFuse,
                params: _iwParams(EULER_VAULT_USDC, _SUB_B)
            });
        }
        vm.prank(_ATOMIST);
        PlasmaVaultGovernance(_plasmaVault).configureInstantWithdrawalFuses(iw);
    }

    function _subA() private view returns (address) {
        return EulerFuseLib.generateSubAccountAddress(_plasmaVault, _SUB_A);
    }

    function _subB() private view returns (address) {
        return EulerFuseLib.generateSubAccountAddress(_plasmaVault, _SUB_B);
    }

    /// @dev Sum of EulerV2SupplyExitFuse amounts emitted by the vault for the given EVault
    function _exitAmount(Vm.Log[] memory logs_, address eulerVault_) private view returns (uint256 total) {
        bytes32 topic = keccak256("EulerV2SupplyExitFuse(address,address,uint256,address)");
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == _plasmaVault && logs_[i].topics[0] == topic) {
                (, address eulerVault, uint256 amount, ) = abi.decode(
                    logs_[i].data,
                    (address, address, uint256, address)
                );
                if (eulerVault == eulerVault_) total += amount;
            }
        }
    }

    function _failedCount(Vm.Log[] memory logs_) private view returns (uint256 count) {
        bytes32 topic = keccak256("EulerV2SupplyFuseExitFailed(address,address,uint256,address)");
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == _plasmaVault && logs_[i].topics[0] == topic) ++count;
        }
    }

    function _iwParams(address eulerVault_, bytes1 subAccount_) private pure returns (bytes32[] memory params) {
        params = new bytes32[](3);
        params[0] = bytes32(0);
        params[1] = PlasmaVaultConfigLib.addressToBytes32(eulerVault_);
        params[2] = bytes32(subAccount_);
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
        _eulerSupplyFuse = address(new EulerV2SupplyFuse(IporFusionMarkets.EULER_V2, _EVC));
        _eulerCollateralFuse = address(new EulerV2CollateralFuse(IporFusionMarkets.EULER_V2, _EVC));
        fuses = new address[](2);
        fuses[0] = _eulerSupplyFuse;
        fuses[1] = _eulerCollateralFuse;
    }

    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses) {
        balanceFuses = new MarketBalanceFuseConfig[](2);
        balanceFuses[0] = MarketBalanceFuseConfig(
            IporFusionMarkets.EULER_V2,
            address(new EulerV2BalanceFuse(IporFusionMarkets.EULER_V2, _EVC))
        );
        balanceFuses[1] = MarketBalanceFuseConfig(
            IporFusionMarkets.ERC20_VAULT_BALANCE,
            address(new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE))
        );
    }

    function _setupMarketConfigsErc20() private pure returns (MarketSubstratesConfig[] memory marketConfigs) {
        marketConfigs = new MarketSubstratesConfig[](1);
        bytes32[] memory tokens = new bytes32[](1);
        tokens[0] = PlasmaVaultConfigLib.addressToBytes32(_USDC);
        marketConfigs[0] = MarketSubstratesConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, tokens);
    }

    function _grantEulerSubstrates(bool flaggedA_) private {
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({
                eulerVault: EULER_VAULT_PRIME_USDC,
                isCollateral: flaggedA_,
                canBorrow: false,
                subAccounts: _SUB_A
            })
        );
        substrates[1] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: EULER_VAULT_USDC, isCollateral: false, canBorrow: false, subAccounts: _SUB_B})
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
