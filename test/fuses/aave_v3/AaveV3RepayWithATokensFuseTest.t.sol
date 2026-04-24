// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TestAddresses} from "../../test_helpers/TestAddresses.sol";
import {FusionFactoryDaoFeePackagesHelper} from "../../test_helpers/FusionFactoryDaoFeePackagesHelper.sol";
import {FusionFactoryLogicLib} from "../../../contracts/factory/lib/FusionFactoryLogicLib.sol";
import {FusionFactory} from "../../../contracts/factory/FusionFactory.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVault, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";

import {IPool} from "../../../contracts/fuses/aave_v3/ext/IPool.sol";
import {IPoolAddressesProvider} from "../../../contracts/fuses/aave_v3/ext/IPoolAddressesProvider.sol";
import {IAavePoolDataProvider} from "../../../contracts/fuses/aave_v3/ext/IAavePoolDataProvider.sol";
import {AaveV3BalanceFuse} from "../../../contracts/fuses/aave_v3/AaveV3BalanceFuse.sol";
import {AaveV3SupplyFuse, AaveV3SupplyFuseEnterData} from "../../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {AaveV3BorrowFuse, AaveV3BorrowFuseEnterData} from "../../../contracts/fuses/aave_v3/AaveV3BorrowFuse.sol";
import {AaveV3RepayWithATokensFuse, AaveV3RepayWithATokensFuseEnterData} from "../../../contracts/fuses/aave_v3/AaveV3RepayWithATokensFuse.sol";

/// @title AaveV3RepayWithATokensFuseTest
/// @notice Fork integration tests for AaveV3RepayWithATokensFuse running against a real PlasmaVault
///         cloned from the Ethereum mainnet FusionFactory and wired with the production
///         AAVE_V3 market id.
/// @dev The fork points at an Ethereum mainnet block where the FusionFactory proxy exists.
///      The FusionFactoryDaoFeePackagesHelper upgrades the proxy to the latest logic so that
///      `clone(...)` is callable. The resulting PlasmaVault is then configured with the supply,
///      borrow, balance and repay-with-aTokens fuses and with DAI/WETH as substrates for the
///      Aave V3 market. Tests exercise the repay fuse through PlasmaVault.execute, i.e. the
///      same path a real strategy would take in production.
contract AaveV3RepayWithATokensFuseTest is Test {
    // --- Ethereum mainnet addresses ---
    address private constant ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    IAavePoolDataProvider private constant AAVE_POOL_DATA_PROVIDER =
        IAavePoolDataProvider(0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3);

    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    // Mainnet FusionFactory proxy — same address used by FusionFactoryDaoFeePackagesForkTest
    // for fork tests against Ethereum state.
    address private constant ETHEREUM_FUSION_FACTORY = 0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852;

    uint256 private constant FORK_BLOCK = 23831825;

    // --- Roles ---
    address private constant USER = TestAddresses.USER;
    address private constant ATOMIST = TestAddresses.ATOMIST;
    address private constant FUSE_MANAGER = TestAddresses.FUSE_MANAGER;
    address private constant ALPHA = TestAddresses.ALPHA;

    // --- Fusion instance under test ---
    FusionFactoryLogicLib.FusionInstance private _fusionInstance;

    AaveV3SupplyFuse private _supplyFuse;
    AaveV3BorrowFuse private _borrowFuse;
    AaveV3RepayWithATokensFuse private _repayFuse;
    AaveV3BalanceFuse private _balanceFuse;

    address private _aDaiToken;
    address private _variableDebtDaiToken;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), FORK_BLOCK);

        FusionFactory fusionFactory = FusionFactory(ETHEREUM_FUSION_FACTORY);

        // Upgrade factory + configure zero-fee DAO package so clone() is callable.
        FusionFactoryDaoFeePackagesHelper.setupDefaultDaoFeePackages(vm, fusionFactory);

        // Clone a fresh PlasmaVault with DAI as the underlying.
        _fusionInstance = fusionFactory.clone(
            "AaveV3RepayWithATokensFuseTest",
            "RWAT",
            DAI,
            0,
            ATOMIST,
            0
        );

        // Assign roles through the access manager.
        vm.startPrank(ATOMIST);
        IporFusionAccessManager(_fusionInstance.accessManager).grantRole(Roles.ATOMIST_ROLE, ATOMIST, 0);
        IporFusionAccessManager(_fusionInstance.accessManager).grantRole(Roles.FUSE_MANAGER_ROLE, FUSE_MANAGER, 0);
        IporFusionAccessManager(_fusionInstance.accessManager).grantRole(Roles.ALPHA_ROLE, ALPHA, 0);
        IporFusionAccessManager(_fusionInstance.accessManager).grantRole(Roles.CLAIM_REWARDS_ROLE, ALPHA, 0);
        IporFusionAccessManager(_fusionInstance.accessManager).grantRole(
            Roles.PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE,
            ATOMIST,
            0
        );
        PlasmaVaultGovernance(_fusionInstance.plasmaVault).convertToPublicVault();
        PlasmaVaultGovernance(_fusionInstance.plasmaVault).enableTransferShares();
        vm.stopPrank();

        // Deploy fuses for this test — all bound to IporFusionMarkets.AAVE_V3.
        _supplyFuse = new AaveV3SupplyFuse(IporFusionMarkets.AAVE_V3, ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER);
        _borrowFuse = new AaveV3BorrowFuse(IporFusionMarkets.AAVE_V3, ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER);
        _repayFuse = new AaveV3RepayWithATokensFuse(
            IporFusionMarkets.AAVE_V3,
            ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER
        );
        _balanceFuse = new AaveV3BalanceFuse(IporFusionMarkets.AAVE_V3, ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER);

        address[] memory fuses = new address[](3);
        fuses[0] = address(_supplyFuse);
        fuses[1] = address(_borrowFuse);
        fuses[2] = address(_repayFuse);

        vm.startPrank(FUSE_MANAGER);
        PlasmaVaultGovernance(_fusionInstance.plasmaVault).addFuses(fuses);
        PlasmaVaultGovernance(_fusionInstance.plasmaVault).addBalanceFuse(
            IporFusionMarkets.AAVE_V3,
            address(_balanceFuse)
        );
        PlasmaVaultGovernance(_fusionInstance.plasmaVault).addBalanceFuse(
            IporFusionMarkets.ERC20_VAULT_BALANCE,
            address(new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE))
        );

        // Grant DAI + WETH as substrates for AAVE_V3 and for ERC20_VAULT_BALANCE.
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(DAI);
        substrates[1] = PlasmaVaultConfigLib.addressToBytes32(WETH);

        PlasmaVaultGovernance(_fusionInstance.plasmaVault).grantMarketSubstrates(
            IporFusionMarkets.AAVE_V3,
            substrates
        );
        PlasmaVaultGovernance(_fusionInstance.plasmaVault).grantMarketSubstrates(
            IporFusionMarkets.ERC20_VAULT_BALANCE,
            substrates
        );

        // Make AAVE_V3 dependent on ERC20_VAULT_BALANCE so totalAssetsInMarket includes raw token balances.
        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.AAVE_V3;
        uint256[][] memory deps = new uint256[][](1);
        deps[0] = new uint256[](1);
        deps[0][0] = IporFusionMarkets.ERC20_VAULT_BALANCE;
        PlasmaVaultGovernance(_fusionInstance.plasmaVault).updateDependencyBalanceGraphs(marketIds, deps);
        vm.stopPrank();

        (address aDai, , address vDebtDai) = AAVE_POOL_DATA_PROVIDER.getReserveTokensAddresses(DAI);
        _aDaiToken = aDai;
        _variableDebtDaiToken = vDebtDai;
    }

    // ============ Constructor tests ============

    function testShouldRevertWhenConstructorMarketIdIsZero() external {
        vm.expectRevert(AaveV3RepayWithATokensFuse.AaveV3RepayWithATokensFuseInvalidMarketId.selector);
        new AaveV3RepayWithATokensFuse(0, ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER);
    }

    function testShouldRevertWhenConstructorAddressesProviderIsZero() external {
        vm.expectRevert(AaveV3RepayWithATokensFuse.AaveV3RepayWithATokensFuseInvalidAddressesProvider.selector);
        new AaveV3RepayWithATokensFuse(IporFusionMarkets.AAVE_V3, address(0));
    }

    function testShouldSetImmutablesAndVersionInConstructor() external {
        AaveV3RepayWithATokensFuse fuse = new AaveV3RepayWithATokensFuse(
            42,
            ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER
        );
        assertEq(fuse.VERSION(), address(fuse), "VERSION should equal deployment address");
        assertEq(fuse.MARKET_ID(), 42, "MARKET_ID should equal constructor arg");
        assertEq(
            fuse.AAVE_V3_POOL_ADDRESSES_PROVIDER(),
            ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER,
            "addresses provider should equal constructor arg"
        );
        assertEq(fuse.INTEREST_RATE_MODE(), 2, "INTEREST_RATE_MODE should be 2 (variable)");
    }

    // ============ enter() tests against the real PlasmaVault ============

    function testShouldBeNoOpWhenAmountIsZero() external {
        _seedCollateralAndDebt();

        uint256 aDaiBefore = ERC20(_aDaiToken).balanceOf(_fusionInstance.plasmaVault);
        uint256 vDebtBefore = ERC20(_variableDebtDaiToken).balanceOf(_fusionInstance.plasmaVault);

        vm.recordLogs();
        _callRepay(DAI, 0, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertFalse(_hasRepayEvent(logs), "no repay event should be emitted for zero amount");
        assertEq(
            ERC20(_aDaiToken).balanceOf(_fusionInstance.plasmaVault),
            aDaiBefore,
            "aToken balance must not change"
        );
        assertEq(
            ERC20(_variableDebtDaiToken).balanceOf(_fusionInstance.plasmaVault),
            vDebtBefore,
            "variable debt balance must not change"
        );
    }

    function testShouldRevertWhenAssetNotGranted() external {
        // Revoke DAI as substrate for the market so the fuse must reject it.
        bytes32[] memory onlyWeth = new bytes32[](1);
        onlyWeth[0] = PlasmaVaultConfigLib.addressToBytes32(WETH);
        vm.startPrank(FUSE_MANAGER);
        PlasmaVaultGovernance(_fusionInstance.plasmaVault).grantMarketSubstrates(
            IporFusionMarkets.AAVE_V3,
            onlyWeth
        );
        vm.stopPrank();

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(_repayFuse),
            abi.encodeCall(
                AaveV3RepayWithATokensFuse.enter,
                AaveV3RepayWithATokensFuseEnterData({asset: DAI, amount: 1e18, minAmount: 0})
            )
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV3RepayWithATokensFuse.AaveV3RepayWithATokensFuseUnsupportedAsset.selector,
                "enter",
                DAI
            )
        );
        vm.startPrank(ALPHA);
        PlasmaVault(_fusionInstance.plasmaVault).execute(calls);
        vm.stopPrank();
    }

    function testShouldRepayHalfDebtAndEmitEvent() external {
        _seedCollateralAndDebt();

        uint256 debtBefore = ERC20(_variableDebtDaiToken).balanceOf(_fusionInstance.plasmaVault);
        uint256 aDaiBefore = ERC20(_aDaiToken).balanceOf(_fusionInstance.plasmaVault);
        uint256 repayAmount = debtBefore / 2;

        vm.recordLogs();
        _callRepay(DAI, repayAmount, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 debtAfter = ERC20(_variableDebtDaiToken).balanceOf(_fusionInstance.plasmaVault);
        uint256 aDaiAfter = ERC20(_aDaiToken).balanceOf(_fusionInstance.plasmaVault);

        assertApproxEqAbs(debtBefore - debtAfter, repayAmount, 1, "variable debt reduced by repaidAmount");
        assertApproxEqAbs(aDaiBefore - aDaiAfter, repayAmount, 1, "aToken burned 1:1 against debt");

        (bool found, address eventAsset, uint256 amountRequested, uint256 amountRepaid) = _findRepayEvent(logs);
        assertTrue(found, "fuse Enter event should be emitted");
        assertEq(eventAsset, DAI, "event asset must be DAI");
        assertEq(amountRequested, repayAmount, "event requested amount must equal input");
        assertApproxEqAbs(amountRepaid, repayAmount, 1, "event repaid amount must be close to input");
    }

    function testShouldRepayFullDebtWithUintMax() external {
        _seedCollateralAndDebt();

        uint256 aDaiBefore = ERC20(_aDaiToken).balanceOf(_fusionInstance.plasmaVault);
        uint256 debtBefore = ERC20(_variableDebtDaiToken).balanceOf(_fusionInstance.plasmaVault);

        vm.recordLogs();
        _callRepay(DAI, type(uint256).max, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 debtAfter = ERC20(_variableDebtDaiToken).balanceOf(_fusionInstance.plasmaVault);
        assertEq(debtAfter, 0, "variable debt must be zero after max repay");

        uint256 aDaiAfter = ERC20(_aDaiToken).balanceOf(_fusionInstance.plasmaVault);
        assertLt(aDaiAfter, aDaiBefore, "aToken balance must decrease");
        assertApproxEqAbs(aDaiBefore - aDaiAfter, debtBefore, 1, "aToken burned ~= debt outstanding");
        /// @dev Seed: aDAI (20_000) > debt (10_000), so after a full-debt repay the vault MUST
        /// retain the excess aDAI. Guards against a regression that would burn the entire balance.
        assertGt(aDaiAfter, 0, "vault should retain aDAI beyond outstanding debt");

        (bool found, address eventAsset, uint256 amountRequested, uint256 amountRepaid) = _findRepayEvent(logs);
        assertTrue(found, "fuse Enter event should be emitted");
        assertEq(eventAsset, DAI, "event asset must be DAI");
        assertEq(amountRequested, type(uint256).max, "event requested amount must equal uint256.max");
        assertGt(amountRepaid, 0, "event repaid amount must be > 0");
        assertApproxEqAbs(amountRepaid, debtBefore, 1, "event repaid amount ~ prior debt");
    }

    function testShouldRepayPartialWhenATokenBalanceBelowDebtWithUintMax() external {
        _seedCollateralAndUndercollateralisedATokens();

        uint256 aDaiMid = ERC20(_aDaiToken).balanceOf(_fusionInstance.plasmaVault);
        uint256 debtMid = ERC20(_variableDebtDaiToken).balanceOf(_fusionInstance.plasmaVault);
        assertLt(aDaiMid, debtMid, "test precondition: aDAI < debt");

        vm.recordLogs();
        _callRepay(DAI, type(uint256).max, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 debtAfter = ERC20(_variableDebtDaiToken).balanceOf(_fusionInstance.plasmaVault);
        uint256 aDaiAfter = ERC20(_aDaiToken).balanceOf(_fusionInstance.plasmaVault);
        assertGt(debtAfter, 0, "partial repay should leave some debt");
        assertLt(debtAfter, debtMid, "debt must have decreased");
        assertLt(aDaiAfter, aDaiMid, "aToken balance must have decreased");
        /// @dev Guards against a regression where debt delta diverges from aToken delta by more
        /// than index-drift tolerance — catches e.g. double-count bugs on Aave's internal math.
        assertApproxEqAbs(debtMid - debtAfter, aDaiMid, 1, "debt delta must equal aToken delta (1:1 burn)");

        (bool found, , uint256 amountRequested, uint256 amountRepaid) = _findRepayEvent(logs);
        assertTrue(found, "fuse Enter event should be emitted");
        assertEq(amountRequested, type(uint256).max, "event requested = uint256.max");
        assertLt(amountRepaid, debtMid, "event repaid < debt when aToken balance is the cap");
        assertApproxEqAbs(amountRepaid, aDaiMid, 1, "event repaid amount ~ available aTokens");
    }

    function testShouldRevertWhenCalledDirectlyByEoa() external {
        // Stateless fuse: calling directly from the test contract (no delegatecall through a vault)
        // reads the test contract's empty substrate storage and reverts with UnsupportedAsset.
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV3RepayWithATokensFuse.AaveV3RepayWithATokensFuseUnsupportedAsset.selector,
                "enter",
                DAI
            )
        );
        _repayFuse.enter(AaveV3RepayWithATokensFuseEnterData({asset: DAI, amount: 1e18, minAmount: 0}));
    }

    function testShouldEmitEventWithCorrectVersion() external {
        _seedCollateralAndDebt();

        uint256 debtBefore = ERC20(_variableDebtDaiToken).balanceOf(_fusionInstance.plasmaVault);

        vm.recordLogs();
        _callRepay(DAI, debtBefore / 4, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 expectedTopic = keccak256(
            "AaveV3RepayWithATokensFuseEnter(address,address,uint256,uint256,uint256)"
        );
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == expectedTopic) {
                (address version, , , , ) = abi.decode(
                    logs[i].data,
                    (address, address, uint256, uint256, uint256)
                );
                assertEq(version, _repayFuse.VERSION(), "event version == fuse.VERSION()");
                assertEq(version, address(_repayFuse), "VERSION is the fuse deployment address");
                /// @dev Under delegatecall the vault is the emitter, not the fuse. Guards against
                /// a regression in which the fuse somehow emits from its own storage context.
                assertEq(
                    logs[i].emitter,
                    _fusionInstance.plasmaVault,
                    "event emitter must be the PlasmaVault (delegatecall context)"
                );
                return;
            }
        }
        revert("event not found");
    }

    // ============ minAmount / aToken-cap tests ============

    function testShouldRevertWhenRepaidAmountBelowMinAmount() external {
        _seedCollateralAndDebt();

        uint256 debtBefore = ERC20(_variableDebtDaiToken).balanceOf(_fusionInstance.plasmaVault);
        uint256 amount = debtBefore / 2;
        uint256 minAmount = amount + 10;

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(_repayFuse),
            abi.encodeCall(
                AaveV3RepayWithATokensFuse.enter,
                AaveV3RepayWithATokensFuseEnterData({asset: DAI, amount: amount, minAmount: minAmount})
            )
        );

        /// @dev Post-call branch (F1). All actions (seed + repay) execute within the same block
        /// on the pinned fork, so Aave's index accrual is zero — `repaidAmount` equals `amount`
        /// exactly and the full error payload is deterministic.
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV3RepayWithATokensFuse.AaveV3RepayWithATokensFuseRepaidAmountBelowMinimum.selector,
                DAI,
                minAmount,
                amount
            )
        );
        vm.startPrank(ALPHA);
        PlasmaVault(_fusionInstance.plasmaVault).execute(calls);
        vm.stopPrank();
    }

    function testShouldRevertWhenATokenBalanceZeroAndMinAmountPositive() external {
        // Grant substrate DAI (already set in setUp) — vault has zero aDAI, zero debt.
        uint256 minAmount = 1;
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(_repayFuse),
            abi.encodeCall(
                AaveV3RepayWithATokensFuse.enter,
                AaveV3RepayWithATokensFuseEnterData({asset: DAI, amount: 1e18, minAmount: minAmount})
            )
        );

        /// @dev Pre-call branch (D1): `finalAmount == 0` so Aave is never called and `repaidAmount`
        /// is hard-coded to 0 in the error — deterministic, so match the full payload.
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV3RepayWithATokensFuse.AaveV3RepayWithATokensFuseRepaidAmountBelowMinimum.selector,
                DAI,
                minAmount,
                uint256(0)
            )
        );
        vm.startPrank(ALPHA);
        PlasmaVault(_fusionInstance.plasmaVault).execute(calls);
        vm.stopPrank();
    }

    function testShouldBeNoOpWhenATokenBalanceZeroAndMinAmountZero() external {
        // No seed — vault has zero aDAI.
        vm.recordLogs();
        _callRepay(DAI, 1e18, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertFalse(_hasRepayEvent(logs), "no event when aToken balance is zero and minAmount == 0");
    }

    /// @dev Edge case for the `type(uint256).max` branch (C1): when the caller requests max on an
    /// empty position, `finalAmount` stays at `type(uint256).max` (the cap short-circuits) and the
    /// call is forwarded to Aave. The Aave Pool must reject it because the caller holds no
    /// variable debt, which revertWith bubbles up through the fuse unchanged — documenting that the
    /// fuse does NOT silently no-op this branch.
    function testShouldRevertWhenMaxRequestedOnEmptyPosition() external {
        // No seed — vault has zero aDAI, zero variable debt, zero collateral.
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(_repayFuse),
            abi.encodeCall(
                AaveV3RepayWithATokensFuse.enter,
                AaveV3RepayWithATokensFuseEnterData({
                    asset: DAI,
                    amount: type(uint256).max,
                    minAmount: 0
                })
            )
        );

        /// @dev Aave surfaces its own error selector (e.g. "39" / NO_DEBT_OF_SELECTED_TYPE), which
        /// the repo does not import, so match only that the call reverts (not a specific selector).
        vm.expectRevert();
        vm.startPrank(ALPHA);
        PlasmaVault(_fusionInstance.plasmaVault).execute(calls);
        vm.stopPrank();
    }

    function testShouldCapAmountToATokenBalanceWhenAmountExceedsBalance() external {
        _seedCollateralAndUndercollateralisedATokens();

        uint256 aDaiMid = ERC20(_aDaiToken).balanceOf(_fusionInstance.plasmaVault);
        uint256 debtMid = ERC20(_variableDebtDaiToken).balanceOf(_fusionInstance.plasmaVault);
        assertLt(aDaiMid, debtMid, "precondition: aDAI < debt");

        uint256 requested = aDaiMid * 2;

        vm.recordLogs();
        _callRepay(DAI, requested, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 debtAfter = ERC20(_variableDebtDaiToken).balanceOf(_fusionInstance.plasmaVault);
        uint256 aDaiAfter = ERC20(_aDaiToken).balanceOf(_fusionInstance.plasmaVault);

        assertGt(debtAfter, 0, "some debt should remain after cap");
        assertLt(debtAfter, debtMid, "debt must have decreased");
        assertLt(aDaiAfter, aDaiMid, "aToken balance must have decreased");

        (bool found, , uint256 amountRequested, uint256 amountRepaid) = _findRepayEvent(logs);
        assertTrue(found, "fuse Enter event should be emitted");
        assertEq(amountRequested, requested, "event requested = raw input, not the cap");
        assertLt(amountRepaid, requested, "event repaid < requested because of the cap");
        assertApproxEqAbs(amountRepaid, aDaiMid, 1, "event repaid ~ aToken balance pre-call");
    }

    function testShouldAcceptWhenRepaidAmountEqualsMinAmount() external {
        _seedCollateralAndDebt();

        uint256 debtBefore = ERC20(_variableDebtDaiToken).balanceOf(_fusionInstance.plasmaVault);
        uint256 amount = debtBefore / 4;
        uint256 minAmount = amount > 1 ? amount - 1 : 0;

        vm.recordLogs();
        _callRepay(DAI, amount, minAmount);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (bool found, , , uint256 amountRepaid) = _findRepayEvent(logs);
        assertTrue(found, "fuse Enter event should be emitted");
        assertGe(amountRepaid, minAmount, "repaid must satisfy the minimum");
    }

    /// @dev Repaying variable debt with aTokens burns aToken supply and shrinks the debt by the
    /// same USD amount, so the market's net value (supply USD - debt USD) is invariant. Verify
    /// that `PlasmaVault.totalAssets()` is preserved within a small tolerance dominated by Aave's
    /// intra-block index accrual.
    function testShouldPreserveTotalAssetsInvariantAfterRepay() external {
        _seedCollateralAndDebt();

        uint256 totalAssetsBefore = PlasmaVault(_fusionInstance.plasmaVault).totalAssets();
        uint256 debtBefore = ERC20(_variableDebtDaiToken).balanceOf(_fusionInstance.plasmaVault);
        assertGt(totalAssetsBefore, 0, "precondition: vault has non-zero totalAssets");

        _callRepay(DAI, debtBefore / 2, 0);

        uint256 totalAssetsAfter = PlasmaVault(_fusionInstance.plasmaVault).totalAssets();

        /// @dev Tolerance absorbs one-block index drift on both the aToken supply side and the
        /// variable-debt side. DAI has 18 decimals — a few-wei tolerance is well under any
        /// economically meaningful threshold. Tighten if the block is re-pinned.
        assertApproxEqAbs(
            totalAssetsAfter,
            totalAssetsBefore,
            1e12,
            "repay-with-aTokens must preserve totalAssets (net-zero on market value)"
        );
    }

    // ============ Helpers ============

    /// @dev Seeds the PlasmaVault with WETH collateral + a DAI variable-debt position and
    ///      simultaneously supplies a larger DAI amount so the vault holds aDAI strictly greater
    ///      than the debt (happy-path repay scenarios).
    function _seedCollateralAndDebt() internal {
        // 1. Fund the vault directly with WETH and DAI. PlasmaVault accepts raw token balances
        //    because ERC20_VAULT_BALANCE is wired and DAI/WETH are granted substrates there.
        deal(WETH, _fusionInstance.plasmaVault, 100e18);
        deal(DAI, _fusionInstance.plasmaVault, 20_000e18);

        // 2. Supply 100 WETH as collateral (userEModeCategoryId > uint8.max skips setUserEMode).
        FuseAction[] memory supplyWeth = new FuseAction[](1);
        supplyWeth[0] = FuseAction(
            address(_supplyFuse),
            abi.encodeCall(
                AaveV3SupplyFuse.enter,
                AaveV3SupplyFuseEnterData({asset: WETH, amount: 100e18, userEModeCategoryId: uint256(300)})
            )
        );
        vm.startPrank(ALPHA);
        PlasmaVault(_fusionInstance.plasmaVault).execute(supplyWeth);
        vm.stopPrank();

        // 3. Borrow 10_000 DAI.
        FuseAction[] memory borrowDai = new FuseAction[](1);
        borrowDai[0] = FuseAction(
            address(_borrowFuse),
            abi.encodeCall(
                AaveV3BorrowFuse.enter,
                AaveV3BorrowFuseEnterData({asset: DAI, amount: 10_000e18})
            )
        );
        vm.startPrank(ALPHA);
        PlasmaVault(_fusionInstance.plasmaVault).execute(borrowDai);
        vm.stopPrank();

        // 4. Supply 20_000 DAI so the vault owns aDAI > debt — ready for repay-with-aTokens.
        FuseAction[] memory supplyDai = new FuseAction[](1);
        supplyDai[0] = FuseAction(
            address(_supplyFuse),
            abi.encodeCall(
                AaveV3SupplyFuse.enter,
                AaveV3SupplyFuseEnterData({asset: DAI, amount: 20_000e18, userEModeCategoryId: uint256(300)})
            )
        );
        vm.startPrank(ALPHA);
        PlasmaVault(_fusionInstance.plasmaVault).execute(supplyDai);
        vm.stopPrank();

        assertGt(ERC20(_aDaiToken).balanceOf(_fusionInstance.plasmaVault), 0, "vault should hold aDAI");
        assertGt(
            ERC20(_variableDebtDaiToken).balanceOf(_fusionInstance.plasmaVault),
            0,
            "vault should hold DAI variable debt"
        );
    }

    /// @dev Seeds a position where the vault's aDAI balance is strictly below its DAI debt.
    ///      Used to exercise the cap-to-aToken-balance branch of the fuse.
    function _seedCollateralAndUndercollateralisedATokens() internal {
        deal(WETH, _fusionInstance.plasmaVault, 100e18);
        deal(DAI, _fusionInstance.plasmaVault, 100e18);

        FuseAction[] memory supplyWeth = new FuseAction[](1);
        supplyWeth[0] = FuseAction(
            address(_supplyFuse),
            abi.encodeCall(
                AaveV3SupplyFuse.enter,
                AaveV3SupplyFuseEnterData({asset: WETH, amount: 100e18, userEModeCategoryId: uint256(300)})
            )
        );
        vm.startPrank(ALPHA);
        PlasmaVault(_fusionInstance.plasmaVault).execute(supplyWeth);
        vm.stopPrank();

        FuseAction[] memory borrowDai = new FuseAction[](1);
        borrowDai[0] = FuseAction(
            address(_borrowFuse),
            abi.encodeCall(
                AaveV3BorrowFuse.enter,
                AaveV3BorrowFuseEnterData({asset: DAI, amount: 10_000e18})
            )
        );
        vm.startPrank(ALPHA);
        PlasmaVault(_fusionInstance.plasmaVault).execute(borrowDai);
        vm.stopPrank();

        FuseAction[] memory supplyDai = new FuseAction[](1);
        supplyDai[0] = FuseAction(
            address(_supplyFuse),
            abi.encodeCall(
                AaveV3SupplyFuse.enter,
                AaveV3SupplyFuseEnterData({asset: DAI, amount: 100e18, userEModeCategoryId: uint256(300)})
            )
        );
        vm.startPrank(ALPHA);
        PlasmaVault(_fusionInstance.plasmaVault).execute(supplyDai);
        vm.stopPrank();

        assertGt(ERC20(_aDaiToken).balanceOf(_fusionInstance.plasmaVault), 0, "vault should hold some aDAI");
        assertGt(
            ERC20(_variableDebtDaiToken).balanceOf(_fusionInstance.plasmaVault),
            ERC20(_aDaiToken).balanceOf(_fusionInstance.plasmaVault),
            "debt must exceed aDAI in the undercollateralised seed"
        );
    }

    /// @dev Executes the repay fuse through the real PlasmaVault so that msg.sender at the
    ///      Aave Pool is the vault (production path).
    function _callRepay(address asset_, uint256 amount_, uint256 minAmount_) internal {
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(_repayFuse),
            abi.encodeCall(
                AaveV3RepayWithATokensFuse.enter,
                AaveV3RepayWithATokensFuseEnterData({asset: asset_, amount: amount_, minAmount: minAmount_})
            )
        );
        vm.startPrank(ALPHA);
        PlasmaVault(_fusionInstance.plasmaVault).execute(calls);
        vm.stopPrank();
    }

    /// @dev Scans recorded logs for the fuse's Enter event topic and returns whether it appeared.
    function _hasRepayEvent(Vm.Log[] memory logs_) internal pure returns (bool) {
        bytes32 expectedTopic = keccak256(
            "AaveV3RepayWithATokensFuseEnter(address,address,uint256,uint256,uint256)"
        );
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].topics.length > 0 && logs_[i].topics[0] == expectedTopic) {
                return true;
            }
        }
        return false;
    }

    /// @dev Scans recorded logs for the fuse's Enter event and decodes its payload.
    function _findRepayEvent(
        Vm.Log[] memory logs_
    ) internal pure returns (bool found, address asset, uint256 amountRequested, uint256 amountRepaid) {
        bytes32 expectedTopic = keccak256(
            "AaveV3RepayWithATokensFuseEnter(address,address,uint256,uint256,uint256)"
        );
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].topics.length > 0 && logs_[i].topics[0] == expectedTopic) {
                (, address asset_, uint256 requested_, , uint256 repaid_) = abi.decode(
                    logs_[i].data,
                    (address, address, uint256, uint256, uint256)
                );
                return (true, asset_, requested_, repaid_);
            }
        }
        return (false, address(0), 0, 0);
    }
}
