// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PlasmaVault, PlasmaVaultInitData, FeeConfig} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {FeeAccount} from "../../contracts/managers/fee/FeeAccount.sol";
import {PriceOracleMiddlewareManager} from "../../contracts/managers/price/PriceOracleMiddlewareManager.sol";
import {PriceOracleMiddlewareManagerLib} from "../../contracts/managers/price/PriceOracleMiddlewareManagerLib.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {ERC4626PriceFeed} from "../../contracts/price_oracle/price_feed/ERC4626PriceFeed.sol";
import {ValidateAllAssetsPricesPreHook} from "../../contracts/handlers/pre_hooks/pre_hooks/ValidateAllAssetsPricesPreHook.sol";
import {
    IporFusionAccessManagerInitializerLibV1,
    InitializationData,
    DataForInitialization,
    PlasmaVaultAddress
} from "../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {ContextManager} from "../../contracts/managers/context/ContextManager.sol";
import {FeeConfigHelper} from "../test_helpers/FeeConfigHelper.sol";
import {MockERC4626} from "../test_helpers/MockErc4626.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";

/// @dev Fixed $1 Chainlink-style feed (8 decimals) for the underlying USDC mock.
contract FixedUsdFeed {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound)
    {
        return (1, 1e8, block.timestamp, block.timestamp, 1);
    }
}

/// @dev Unprivileged attacker contract. Everything below runs inside ONE external call (one transaction):
///      nudge the donation-movable ERC4626 feed by < maxPriceDelta, then make a 1-wei deposit into the
///      PlasmaVault so that ValidateAllAssetsPricesPreHook -> validateAllAssetsPrices() accepts the move and
///      re-anchors lastValidatedPrices. Repeat.
contract RatchetAttacker {
    IERC20 public immutable usdc;
    IERC4626 public immutable thinVault;
    IERC4626 public immutable plasmaVault;

    constructor(IERC20 usdc_, IERC4626 thinVault_, IERC4626 plasmaVault_) {
        usdc = usdc_;
        thinVault = thinVault_;
        plasmaVault = plasmaVault_;
    }

    function attack(uint256 steps_, uint256 stepBps_) external {
        usdc.approve(address(plasmaVault), type(uint256).max);
        for (uint256 i; i < steps_; ++i) {
            // 1. move the registered feed by just under maxPriceDelta (donation raises convertToAssets)
            uint256 donation = (thinVault.totalAssets() * stepBps_) / 10_000;
            usdc.transfer(address(thinVault), donation);
            // 2. dust deposit -> pre-hook validates and re-anchors the baseline
            plasmaVault.deposit(1, address(this));
        }
    }
}

/// @title ValidateAllAssetsPricesRatchetTest
/// @notice Regression for the price circuit breaker ratchet: the baseline re-anchors at most once per block,
///         so repeated hooked dust deposits in one transaction cannot walk the accepted price past the bound.
contract ValidateAllAssetsPricesRatchetTest is Test {
    address private constant _DAO = address(1111111);
    address private constant _OWNER = address(2222222);
    address private constant _ADMIN = address(3333333);
    address private constant _ATOMIST = address(4444444);
    address private constant _ALPHA = address(5555555);
    address private constant _GUARDIAN = address(7777777);
    address private constant _FUSE_MANAGER = address(8888888);
    address private constant _CLAIM_REWARDS = address(9999991);
    address private constant _TRANSFER_REWARDS_MANAGER = address(9999992);
    address private constant _CONFIG_INSTANT_WITHDRAWAL_FUSES_MANAGER = address(9999993);
    address private constant _PRICE_SOURCE_MANAGER = address(10101010);
    address private constant _PRE_HOOKS_MANAGER = address(10101011);
    address private constant _MIDDLEWARE_OWNER = address(10101012);

    address private constant _VICTIM = address(0xBEEF);
    address private constant _THIN_VAULT_LP = address(0xA11CE);
    address private constant _CONTROL_ACTOR = address(0xC0C0);

    /// @dev 1% max allowed price change per validation
    uint256 private constant MAX_PRICE_DELTA = 1e16;
    /// @dev 0.9% per step: above maxPriceDelta/2 (re-anchors), below maxPriceDelta (never trips)
    uint256 private constant STEP_BPS = 90;
    uint256 private constant STEPS = 25;

    MockERC20 private _usdc;
    MockERC4626 private _thinVault;
    PriceOracleMiddleware private _middleware;
    IporFusionAccessManager private _accessManager;
    address private _withdrawManager;
    address private _plasmaVault;
    PriceOracleMiddlewareManager private _priceManager;
    ContextManager private _contextManager;
    ValidateAllAssetsPricesPreHook private _hook;
    RatchetAttacker private _attacker;

    function setUp() public {
        _usdc = new MockERC20("Mock USDC", "mUSDC", 6);
        // External, donation-movable ERC4626 whose share price is a registered, validated asset
        _thinVault = new MockERC4626(IERC20(address(_usdc)), "Thin Yield Vault", "tYV");

        // Shared middleware with a $1 USDC feed
        PriceOracleMiddleware impl = new PriceOracleMiddleware(address(0));
        _middleware = PriceOracleMiddleware(
            address(new ERC1967Proxy(address(impl), abi.encodeWithSignature("initialize(address)", _MIDDLEWARE_OWNER)))
        );
        {
            address[] memory a = new address[](1);
            a[0] = address(_usdc);
            address[] memory s = new address[](1);
            s[0] = address(new FixedUsdFeed());
            vm.prank(_MIDDLEWARE_OWNER);
            _middleware.setAssetsPricesSources(a, s);
        }

        FeeConfig memory feeConfig = FeeConfigHelper.createZeroFeeConfig();
        _accessManager = new IporFusionAccessManager(_ATOMIST, 0);
        _withdrawManager = address(new WithdrawManager(address(_accessManager)));
        _priceManager = new PriceOracleMiddlewareManager(address(_accessManager), address(_middleware));

        PlasmaVaultInitData memory initData = PlasmaVaultInitData({
            assetName: "USDC Plasma Vault",
            assetSymbol: "USDC-PV",
            underlyingToken: address(_usdc),
            priceOracleMiddleware: address(_priceManager),
            feeConfig: feeConfig,
            accessManager: address(_accessManager),
            plasmaVaultBase: address(new PlasmaVaultBase()),
            withdrawManager: _withdrawManager,
            plasmaVaultVotesPlugin: address(0)
        });

        vm.startPrank(_ATOMIST);
        _plasmaVault = address(new PlasmaVault());
        PlasmaVault(_plasmaVault).proxyInitialize(initData);
        vm.stopPrank();

        _setupInitialRoles();

        // ---- curator configuration (as designed): register the ERC4626 feed, set 1% breaker, install pre-hook
        {
            address[] memory assets = new address[](1);
            assets[0] = address(_thinVault);
            address[] memory sources = new address[](1);
            sources[0] = address(new ERC4626PriceFeed(address(_thinVault)));
            vm.prank(_PRICE_SOURCE_MANAGER);
            _priceManager.setAssetsPriceSources(assets, sources);

            uint256[] memory deltas = new uint256[](1);
            deltas[0] = MAX_PRICE_DELTA;
            vm.prank(_ATOMIST);
            _priceManager.updatePriceValidation(assets, deltas);
        }
        {
            _hook = new ValidateAllAssetsPricesPreHook();
            bytes4[] memory selectors = new bytes4[](1);
            selectors[0] = IERC4626.deposit.selector;
            address[] memory impls = new address[](1);
            impls[0] = address(_hook);
            bytes32[][] memory substrates = new bytes32[][](1);
            substrates[0] = new bytes32[](1);
            substrates[0][0] = bytes32(0);
            vm.prank(_PRE_HOOKS_MANAGER);
            PlasmaVaultGovernance(_plasmaVault).setPreHookImplementations(selectors, impls, substrates);
        }

        // ---- seed the external ERC4626 (price 1.0)
        _usdc.mint(_THIN_VAULT_LP, 100_000e6);
        vm.startPrank(_THIN_VAULT_LP);
        _usdc.approve(address(_thinVault), type(uint256).max);
        _thinVault.deposit(100_000e6, _THIN_VAULT_LP);
        vm.stopPrank();

        // ---- honest depositor: first deposit anchors the breaker baseline at 1e18
        _usdc.mint(_VICTIM, 20_000e6);
        vm.startPrank(_VICTIM);
        _usdc.approve(_plasmaVault, type(uint256).max);
        PlasmaVault(_plasmaVault).deposit(10_000e6, _VICTIM);
        vm.stopPrank();

        // ---- unprivileged attacker contract (no role, vault is public)
        _attacker = new RatchetAttacker(IERC20(address(_usdc)), IERC4626(address(_thinVault)), IERC4626(_plasmaVault));
        _usdc.mint(address(_attacker), 100_000e6);

        _usdc.mint(_CONTROL_ACTOR, 100_000e6);
    }

    function test_ratchetInOneTx_revertsByThirdStep_sameBlockAsBaseline() public {
        (, uint256 baseline0, uint256 ts0) = _priceManager.getPriceValidationInfo(address(_thinVault));
        assertEq(baseline0, 1e18, "baseline anchored at 1.0 by the honest first deposit");
        assertEq(ts0, block.timestamp, "baseline timestamp recorded");

        // Control: a one-shot +25% move is rejected.
        uint256 snap = vm.snapshotState();
        vm.startPrank(_CONTROL_ACTOR);
        _usdc.transfer(address(_thinVault), 25_100e6);
        _usdc.approve(_plasmaVault, 1);
        (bool okOneShot, bytes memory ret) = _plasmaVault.call(
            abi.encodeCall(IERC4626.deposit, (uint256(1), _CONTROL_ACTOR))
        );
        vm.stopPrank();
        assertFalse(okOneShot, "one-shot +25% move must be rejected");
        assertEq(bytes4(ret), PriceOracleMiddlewareManagerLib.PriceChangeExceeded.selector, "PriceChangeExceeded");
        vm.revertToState(snap);

        // Attack: 25 steps of 0.9% in one transaction. Baseline was written in this very block, so it cannot
        // re-anchor: the second step (+1.8% cumulative) already exceeds maxPriceDelta.
        vm.prank(address(0xBAD));
        vm.expectPartialRevert(PriceOracleMiddlewareManagerLib.PriceChangeExceeded.selector);
        _attacker.attack(STEPS, STEP_BPS);
    }

    function test_ratchetInOneTx_revertsByThirdStep_afterNewBlock() public {
        vm.warp(block.timestamp + 1);

        // Step 1 and 2 are accepted (the first re-anchors once, the second stays within the delta of that
        // baseline), step 3 exceeds maxPriceDelta of the single re-anchored baseline.
        vm.prank(address(0xBAD));
        _attacker.attack(2, STEP_BPS);
        (, uint256 baseline, uint256 ts) = _priceManager.getPriceValidationInfo(address(_thinVault));
        assertEq(ts, block.timestamp, "re-anchored once in this block");
        assertGt(baseline, 1.0085e18, "baseline moved by step 1");
        assertLt(baseline, 1.0095e18, "baseline was not walked by step 2");

        vm.prank(address(0xBAD));
        vm.expectPartialRevert(PriceOracleMiddlewareManagerLib.PriceChangeExceeded.selector);
        _attacker.attack(1, STEP_BPS);

        vm.warp(block.timestamp + 1);
        vm.prank(address(0xBAD));
        vm.expectPartialRevert(PriceOracleMiddlewareManagerLib.PriceChangeExceeded.selector);
        _attacker.attack(STEPS, STEP_BPS);
    }

    function test_acceptedPriceStaysWithinSquaredMaxDeltaOfInitialBaseline() public {
        (, uint256 baseline0, ) = _priceManager.getPriceValidationInfo(address(_thinVault));
        vm.warp(block.timestamp + 1);

        // Largest ACCEPTED price: two steps pass (one re-anchor, one within the delta of the new baseline).
        vm.prank(address(0xBAD));
        _attacker.attack(2, STEP_BPS);

        (uint256 acceptedPrice, ) = _priceManager.getAssetPrice(address(_thinVault));
        uint256 bound = (baseline0 * (1e18 + MAX_PRICE_DELTA) * (1e18 + MAX_PRICE_DELTA)) / 1e36;
        assertGt(acceptedPrice, baseline0, "price actually moved");
        assertLe(acceptedPrice, bound, "accepted price stays within (1 + maxPriceDelta)^2 of initial baseline");

        // Any further steps in the same timestamp revert, so the accepted maximum cannot grow.
        vm.prank(address(0xBAD));
        vm.expectPartialRevert(PriceOracleMiddlewareManagerLib.PriceChangeExceeded.selector);
        _attacker.attack(STEPS, STEP_BPS);

        (uint256 priceAfter, ) = _priceManager.getAssetPrice(address(_thinVault));
        assertLe(priceAfter, bound, "feed price still within the bound");

        // Honest hooked deposits keep working at the original price.
        vm.prank(_VICTIM);
        PlasmaVault(_plasmaVault).deposit(1_000e6, _VICTIM);
    }

    function _setupInitialRoles() private {
        address[] memory approvedAddresses = new address[](2);
        approvedAddresses[0] = _plasmaVault;
        approvedAddresses[1] = address(_priceManager);
        _contextManager = new ContextManager(address(_accessManager), approvedAddresses);

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
        address[] memory priceManagers = new address[](1);
        priceManagers[0] = _PRICE_SOURCE_MANAGER;
        address[] memory preHooksManagers = new address[](1);
        preHooksManagers[0] = _PRE_HOOKS_MANAGER;

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
            updateMarketsBalancesAccounts: new address[](0),
            updateRewardsBalanceAccounts: new address[](0),
            withdrawManagerRequestFeeManagers: new address[](0),
            withdrawManagerWithdrawFeeManagers: new address[](0),
            priceOracleMiddlewareManagers: priceManagers,
            preHooksManagers: preHooksManagers,
            plasmaVaultAddress: PlasmaVaultAddress({
                plasmaVault: _plasmaVault,
                accessManager: address(_accessManager),
                rewardsClaimManager: address(0x123),
                withdrawManager: _withdrawManager,
                feeManager: FeeAccount(PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeAccount)
                    .FEE_MANAGER(),
                contextManager: address(_contextManager),
                priceOracleMiddlewareManager: address(_priceManager)
            })
        });

        InitializationData memory initializationData = IporFusionAccessManagerInitializerLibV1
            .generateInitializeIporPlasmaVault(data);

        vm.startPrank(_ATOMIST);
        _accessManager.initialize(initializationData);
        vm.stopPrank();
    }
}
