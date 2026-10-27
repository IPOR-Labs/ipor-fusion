// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;
import {PlasmaVaultCloneLib} from "../../../test_helpers/PlasmaVaultCloneLib.sol";

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PlasmaVault, PlasmaVaultInitData, FuseAction} from "../../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../../../contracts/managers/withdraw/WithdrawManager.sol";
import {PriceOracleMiddleware} from "../../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {Roles} from "../../../../contracts/libraries/Roles.sol";
import {IporFusionMarkets} from "../../../../contracts/libraries/IporFusionMarkets.sol";

import {
    ExternalStateOperationFuse,
    ExternalStateOperationFuseEnterData,
    ExternalStateOperationFuseExitData
} from "../../../../contracts/fuses/external_state/ExternalStateOperationFuse.sol";
import {ExternalStateBalanceFuse} from "../../../../contracts/fuses/external_state/ExternalStateBalanceFuse.sol";
import {ExternalStatePausePreHook} from "../../../../contracts/handlers/pre_hooks/pre_hooks/ExternalStatePausePreHook.sol";
import {ExternalStateExecutor} from "../../../../contracts/fuses/external_state/ExternalStateExecutor.sol";
import {
    IExternalStateExecutor,
    ExternalStateExecutorAction
} from "../../../../contracts/fuses/external_state/IExternalStateExecutor.sol";
import {ExternalStateErrors} from "../../../../contracts/fuses/external_state/errors/ExternalStateErrors.sol";
import {
    ExternalStateSubstrateLib,
    ExternalStateSubstrateType
} from "../../../../contracts/fuses/external_state/lib/ExternalStateSubstrateLib.sol";

import {FeeConfigHelper} from "../../../test_helpers/FeeConfigHelper.sol";
import {RoleLib, UsersToRoles} from "../../../RoleLib.sol";
import {MutableValuePriceFeed} from "../../../managers/MutableValuePriceFeed.sol";
import {MockERC20ForExternalState} from "./mocks/MockERC20ForExternalState.sol";
import {ExternalStateTestConstants, ExternalStateSlotHelpers} from "./ExternalStateTestHelpers.sol";

/// @notice Custody counterparty that pulls approved tokens off the executor (README pattern:
///         TARGET (asset, approve) + TARGET (custody, deposit)). After an enter the executor is empty,
///         which is what a `dustThreshold == 0` deployment requires.
contract MockPullCustody {
    function deposit(address asset_, uint256 amount_) external {
        IERC20(asset_).transferFrom(msg.sender, address(this), amount_);
    }

    /// @dev Pays `amount_` back to the caller, like a protocol returning funds (possibly more than requested).
    function withdraw(address asset_, uint256 amount_) external {
        IERC20(asset_).transfer(msg.sender, amount_);
    }
}

/// @title ExternalStateDustDonationTest
/// @notice IL-8739 regression suite on a real PlasmaVault. `_checkDust` must count only tokens credited through
///         the vault path (`unforwardedCredit`), never the raw executor balance, so a third-party donation
///         cannot block custodians (and, after `stalenessMax`, freeze the vault via the pause pre-hook), while
///         enter-without-forward and exit residue still block as before. `sweepSurplus` returns donations to the vault.
contract ExternalStateDustDonationTest is Test {
    uint256 internal constant MARKET_ID = IporFusionMarkets.EXTERNAL_STATE;
    uint256 internal constant STALENESS_MAX_S = 1 days;
    uint256 internal constant BIG_CHANGE_BPS = 1000; // 10%
    uint256 internal constant MIN_UPDATE_INTERVAL_S = 5 minutes;

    PlasmaVault internal vault;
    IporFusionAccessManager internal accessManager;
    PriceOracleMiddleware internal priceOracle;
    MockERC20ForExternalState internal usdc; // 6-decimals stand-in for USDC (tracked ASSET + vault underlying)
    MutableValuePriceFeed internal priceFeed;
    MockPullCustody internal custody;

    ExternalStateOperationFuse internal opFuse;
    ExternalStateBalanceFuse internal balanceFuse;
    ExternalStatePausePreHook internal preHook;

    address internal atomist;
    address internal alpha;
    address internal custodianA;
    address internal custodianB;
    address internal balanceAccount;
    address internal user;
    address internal attacker;

    UsersToRoles internal usersToRoles;

    function setUp() public {
        atomist = makeAddr("atomist");
        alpha = makeAddr("alpha");
        custodianA = makeAddr("custodianA");
        custodianB = makeAddr("custodianB");
        balanceAccount = makeAddr("balanceAccount");
        user = makeAddr("user");
        attacker = makeAddr("attacker");

        usdc = new MockERC20ForExternalState("USD Coin", "USDC", 6);
        custody = new MockPullCustody();

        priceOracle = new PriceOracleMiddleware(address(0));
        priceOracle.initialize(atomist);
        priceFeed = new MutableValuePriceFeed(1e18);
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        address[] memory sources = new address[](1);
        sources[0] = address(priceFeed);
        vm.prank(atomist);
        priceOracle.setAssetsPricesSources(assets, sources);

        usersToRoles.superAdmin = atomist;
        usersToRoles.atomist = atomist;
        usersToRoles.alphas = new address[](1);
        usersToRoles.alphas[0] = alpha;
        usersToRoles.performanceFeeManagers = new address[](0);
        usersToRoles.managementFeeManagers = new address[](0);
        usersToRoles.feeTimelock = 0;

        accessManager = RoleLib.createAccessManager(usersToRoles, 0, vm);
        address withdrawManager = address(new WithdrawManager(address(accessManager)));

        vm.startPrank(atomist);
        vault = PlasmaVaultCloneLib.newPlasmaVault();
        vault.proxyInitialize(
            PlasmaVaultInitData({
                assetName: "ExternalState Plasma Vault",
                assetSymbol: "externalStatePV",
                underlyingToken: address(usdc),
                priceOracleMiddleware: address(priceOracle),
                feeConfig: FeeConfigHelper.createZeroFeeConfig(),
                accessManager: address(accessManager),
                plasmaVaultBase: address(new PlasmaVaultBase()),
                withdrawManager: withdrawManager,
                plasmaVaultVotesPlugin: address(0)
            })
        );
        vm.stopPrank();

        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(vault), accessManager, withdrawManager);

        bytes4[] memory extraSig = new bytes4[](3);
        extraSig[0] = PlasmaVaultGovernance.grantMarketSubstrates.selector;
        extraSig[1] = PlasmaVaultGovernance.setPreHookImplementations.selector;
        extraSig[2] = PlasmaVault.updateMarketsBalances.selector;
        vm.prank(atomist);
        accessManager.setTargetFunctionRole(address(vault), extraSig, Roles.ATOMIST_ROLE);

        opFuse = new ExternalStateOperationFuse(MARKET_ID);
        balanceFuse = new ExternalStateBalanceFuse(MARKET_ID);
        preHook = new ExternalStatePausePreHook(MARKET_ID);

        address[] memory fuses = new address[](1);
        fuses[0] = address(opFuse);

        // Production-like substrate set. DUST_THRESHOLD intentionally omitted -> README default 0
        // ("zero tolerance; any non-zero executor asset balance blocks propose/confirm").
        bytes32[] memory subs = new bytes32[](10);
        subs[0] = ExternalStateSubstrateLib.encodeAssetSubstrate(address(usdc));
        subs[1] = ExternalStateSubstrateLib.encodeBalanceAccountSubstrate(balanceAccount);
        subs[2] = ExternalStateSubstrateLib.encodeCustodianSubstrate(custodianA);
        subs[3] = ExternalStateSubstrateLib.encodeCustodianSubstrate(custodianB);
        subs[4] = ExternalStateSubstrateLib.encodeTargetSubstrate(address(usdc), IERC20.approve.selector);
        subs[5] = ExternalStateSubstrateLib.encodeTargetSubstrate(address(custody), MockPullCustody.deposit.selector);
        subs[6] = ExternalStateSubstrateLib.encodeStalenessMaxSubstrate(STALENESS_MAX_S);
        subs[7] = ExternalStateSubstrateLib.encodeBigChangeBpsSubstrate(BIG_CHANGE_BPS);
        subs[8] = ExternalStateSubstrateLib.encodeMinUpdateIntervalSubstrate(MIN_UPDATE_INTERVAL_S);
        subs[9] = ExternalStateSubstrateLib.encodeTargetSubstrate(address(custody), MockPullCustody.withdraw.selector);

        vm.startPrank(atomist);
        PlasmaVaultGovernance(address(vault)).addFuses(fuses);
        PlasmaVaultGovernance(address(vault)).addBalanceFuse(MARKET_ID, address(balanceFuse));
        PlasmaVaultGovernance(address(vault)).grantMarketSubstrates(MARKET_ID, subs);
        vm.stopPrank();

        // Deploy the executor (ALPHA createExecutor) and register the pause pre-hook on the user selectors.
        _executeFuse(address(opFuse), abi.encodeCall(opFuse.createExecutor, ()));
        // The executor settles `unforwardedCredit` only for cached assets: sync before the first enter (README 13.3).
        IExternalStateExecutor(_readExecutor()).syncSubstrates();
        _registerPausePreHook();
    }

    // ============================================================
    // 1. donation after a forwarded enter does not block custodians
    // ============================================================

    function test_donationAfterForward_doesNotBlockCustodians() public {
        address executor = _readExecutor();
        assertEq(ExternalStateExecutor(executor).dustThreshold(), 0, "README default dust threshold");

        _userDeposit(1_000e6);
        _enter(500e6, _forwardActions(500e6));
        assertEq(usdc.balanceOf(executor), 0, "executor empty after forwarding");
        assertEq(ExternalStateExecutor(executor).unforwardedCredit(address(usdc)), 0, "forwarded credit settled");

        _custodianConfirm(executor, 500e6);
        _updateMarketBalance();
        uint256 lastConfirmTs = block.timestamp;

        // Attack: 1 wei donation of the tracked asset, then past MIN_UPDATE_INTERVAL.
        usdc.mint(attacker, 10);
        vm.prank(attacker);
        usdc.transfer(executor, 1);
        assertEq(ExternalStateExecutor(executor).unforwardedCredit(address(usdc)), 0, "donation is not credit");
        vm.warp(lastConfirmTs + 1 hours);

        // propose passes, a second donation lands between propose and confirm, confirm still passes.
        vm.prank(custodianA);
        IExternalStateExecutor(executor).proposeBalance(balanceAccount, 500e6);
        (, , uint64 proposedAt, uint256 n) = ExternalStateExecutor(executor).pendingProposals(balanceAccount);
        bytes32 h = _proposalHash(executor, balanceAccount, 500e6, custodianA, proposedAt, n);
        vm.prank(attacker);
        usdc.transfer(executor, 1);
        vm.prank(custodianB);
        IExternalStateExecutor(executor).confirmBalance(balanceAccount, h);
        uint256 secondConfirmTs = block.timestamp;
        assertEq(IExternalStateExecutor(executor).getOldestUpdateTimestamp(), secondConfirmTs, "confirm landed");
        assertEq(usdc.balanceOf(executor), 2, "donations stay on the executor");

        // Past the first confirm's staleness window the vault still serves users (no PreHookStale).
        _updateMarketBalance();
        vm.warp(lastConfirmTs + STALENESS_MAX_S + 1);
        vm.prank(user);
        vault.withdraw(100e6, user, user);
        usdc.mint(user, 100e6);
        vm.startPrank(user);
        usdc.approve(address(vault), 100e6);
        vault.deposit(100e6, user);
        vm.stopPrank();
    }

    // ============================================================
    // 2. donation before an enter is not absorbed into the credit
    // ============================================================

    function test_donationBeforeEnter_isNotAbsorbed() public {
        address executor = _readExecutor();
        _userDeposit(1_000e6);

        usdc.mint(attacker, 5);
        vm.prank(attacker);
        usdc.transfer(executor, 5); // donated BEFORE the enter

        _enter(500e6, _forwardActions(500e6));

        assertEq(usdc.balanceOf(executor), 5, "only the donation is left");
        assertEq(ExternalStateExecutor(executor).unforwardedCredit(address(usdc)), 0, "credit fully settled");
        vm.prank(custodianA);
        IExternalStateExecutor(executor).proposeBalance(balanceAccount, 500e6);
    }

    // ============================================================
    // 3. enter without forwarding still blocks
    // ============================================================

    function test_unforwardedEnter_stillBlocks() public {
        address executor = _readExecutor();
        _userDeposit(1_000e6);

        _enter(500e6, new ExternalStateExecutorAction[](0));
        assertEq(ExternalStateExecutor(executor).unforwardedCredit(address(usdc)), 500e6, "credited");

        vm.prank(custodianA);
        vm.expectRevert(
            abi.encodeWithSelector(
                ExternalStateErrors.ExternalStateExecutorDustCheckFailed.selector,
                address(usdc),
                500e6,
                uint256(0)
            )
        );
        IExternalStateExecutor(executor).proposeBalance(balanceAccount, 500e6);

        // Forward the tokens with an actions-only enter: credit is settled and the check passes.
        _enterActionsOnly(_forwardActions(500e6));
        assertEq(ExternalStateExecutor(executor).unforwardedCredit(address(usdc)), 0, "settled after forward");
        vm.prank(custodianA);
        IExternalStateExecutor(executor).proposeBalance(balanceAccount, 500e6);
    }

    // ============================================================
    // 4. exit residue still blocks
    // ============================================================

    function test_exitResidual_stillBlocks() public {
        address executor = _readExecutor();
        _userDeposit(1_000e6);
        _enter(500e6, _forwardActions(500e6));

        // Exit 100 but the protocol returns 300 to the executor: 200 stays credited-but-unforwarded.
        ExternalStateExecutorAction[] memory actions = new ExternalStateExecutorAction[](1);
        actions[0] = ExternalStateExecutorAction({
            target: address(custody),
            data: abi.encodeCall(MockPullCustody.withdraw, (address(usdc), 300e6))
        });
        _exit(100e6, actions);
        assertEq(usdc.balanceOf(executor), 200e6, "residue on the executor");
        assertEq(ExternalStateExecutor(executor).unforwardedCredit(address(usdc)), 200e6, "residue credited");

        vm.prank(custodianA);
        vm.expectRevert(
            abi.encodeWithSelector(
                ExternalStateErrors.ExternalStateExecutorDustCheckFailed.selector,
                address(usdc),
                200e6,
                uint256(0)
            )
        );
        IExternalStateExecutor(executor).proposeBalance(balanceAccount, 200e6);

        // Exiting the residue clears the block.
        _exit(200e6, new ExternalStateExecutorAction[](0));
        assertEq(ExternalStateExecutor(executor).unforwardedCredit(address(usdc)), 0, "credit cleared");
        vm.prank(custodianA);
        IExternalStateExecutor(executor).proposeBalance(balanceAccount, 200e6);
    }

    // ============================================================
    // 5. sweepSurplus
    // ============================================================

    function test_sweepSurplus_movesOnlyDonation_keepsCreditAndBalances() public {
        address executor = _readExecutor();
        _userDeposit(1_000e6);
        _enter(500e6, new ExternalStateExecutorAction[](0)); // 500 credited and still on the executor

        usdc.mint(attacker, 7);
        vm.prank(attacker);
        usdc.transfer(executor, 7); // donation D = 7

        uint256 baBefore = ExternalStateExecutor(executor).balances(balanceAccount);
        uint256 creditBefore = ExternalStateExecutor(executor).unforwardedCredit(address(usdc));
        uint256 vaultIdleBefore = usdc.balanceOf(address(vault));
        uint256 navBefore = vault.totalAssets();
        assertEq(creditBefore, 500e6);

        vm.expectEmit(false, false, false, true, executor);
        emit ExternalStateExecutor.SurplusSwept(address(usdc), 7);
        _sweep(address(usdc));

        assertEq(usdc.balanceOf(executor), 500e6, "credited tokens untouched");
        assertEq(usdc.balanceOf(address(vault)) - vaultIdleBefore, 7, "exactly the donation moved to the vault");
        assertEq(ExternalStateExecutor(executor).balances(balanceAccount), baBefore, "balances unchanged");
        assertEq(ExternalStateExecutor(executor).unforwardedCredit(address(usdc)), creditBefore, "credit unchanged");
        assertEq(vault.totalAssets() - navBefore, 7, "NAV +D immediately");

        // Forward the credited tokens: propose and confirm pass afterwards.
        _enterActionsOnly(_forwardActions(500e6));
        _custodianConfirm(executor, 500e6);
    }

    function test_sweepSurplus_withoutDonation_movesNothing() public {
        address executor = _readExecutor();
        _userDeposit(1_000e6);
        _enter(500e6, new ExternalStateExecutorAction[](0));
        uint256 vaultIdleBefore = usdc.balanceOf(address(vault));

        vm.expectEmit(false, false, false, true, executor);
        emit ExternalStateExecutor.SurplusSwept(address(usdc), 0);
        _sweep(address(usdc));

        assertEq(usdc.balanceOf(address(vault)), vaultIdleBefore, "nothing moved");
        assertEq(usdc.balanceOf(executor), 500e6, "credited tokens untouched");
        assertEq(ExternalStateExecutor(executor).unforwardedCredit(address(usdc)), 500e6, "credit unchanged");
    }

    function test_sweepSurplus_onlyVaultPath() public {
        address executor = _readExecutor();
        usdc.mint(executor, 3);

        // Direct calls to the executor are rejected for everyone but the vault.
        vm.prank(alpha);
        vm.expectRevert(abi.encodeWithSelector(ExternalStateErrors.ExternalStateExecutorUnauthorizedVault.selector));
        IExternalStateExecutor(executor).sweepSurplus(address(usdc));
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ExternalStateErrors.ExternalStateExecutorUnauthorizedVault.selector));
        IExternalStateExecutor(executor).sweepSurplus(address(usdc));

        // The fuse only accepts a granted ASSET substrate.
        MockERC20ForExternalState other = new MockERC20ForExternalState("Other", "OTH", 6);
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction({fuse: address(opFuse), data: abi.encodeCall(opFuse.sweepSurplus, (address(other)))});
        vm.prank(alpha);
        vm.expectRevert(
            abi.encodeWithSelector(
                ExternalStateErrors.ExternalStateUnsupportedSubstrate.selector,
                uint8(ExternalStateSubstrateType.ASSET),
                ExternalStateSubstrateLib.encodeAssetSubstrate(address(other))
            )
        );
        vault.execute(calls);

        // A non-ALPHA caller cannot drive the fuse through the vault.
        calls[0] = FuseAction({fuse: address(opFuse), data: abi.encodeCall(opFuse.sweepSurplus, (address(usdc)))});
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("AccessManagedUnauthorized(address)", attacker));
        vault.execute(calls);
        assertEq(usdc.balanceOf(executor), 3, "donation still on the executor");
    }

    function test_duplicatedAssetGrant_isCachedOnce_outflowDebitsExactlyOnce() public {
        address executor = _readExecutor();

        // The vault accepts a duplicated ASSET grant; the executor cache must still hold the asset once.
        // `grantMarketSubstrates` replaces the whole set, so append the duplicate to the current one.
        bytes32[] memory current = PlasmaVaultGovernance(address(vault)).getMarketSubstrates(MARKET_ID);
        bytes32[] memory dup = new bytes32[](current.length + 1);
        for (uint256 i; i < current.length; ++i) {
            dup[i] = current[i];
        }
        dup[current.length] = ExternalStateSubstrateLib.encodeAssetSubstrate(address(usdc));
        vm.prank(atomist);
        PlasmaVaultGovernance(address(vault)).grantMarketSubstrates(MARKET_ID, dup);
        IExternalStateExecutor(executor).syncSubstrates();
        assertEq(IExternalStateExecutor(executor).assetsLength(), 1, "asset cached once");

        _userDeposit(1_000e6);
        _enter(500e6, new ExternalStateExecutorAction[](0)); // 500 credited, still on the executor
        _enterActionsOnly(_forwardActions(200e6)); // outflow of 200

        assertEq(usdc.balanceOf(executor), 300e6, "300 left on the executor");
        assertEq(ExternalStateExecutor(executor).unforwardedCredit(address(usdc)), 300e6, "outflow X debits exactly X");

        // The dust check still sees the remaining credit and the credited tokens cannot be swept.
        vm.prank(custodianA);
        vm.expectRevert(
            abi.encodeWithSelector(
                ExternalStateErrors.ExternalStateExecutorDustCheckFailed.selector,
                address(usdc),
                300e6,
                uint256(0)
            )
        );
        IExternalStateExecutor(executor).proposeBalance(balanceAccount, 500e6);
        _sweep(address(usdc));
        assertEq(usdc.balanceOf(executor), 300e6, "credited tokens not swept");
    }

    function test_dustCheckFailed_reportsCreditNotCreditPlusDonation() public {
        address executor = _readExecutor();
        _userDeposit(1_000e6);
        _enter(500e6, new ExternalStateExecutorAction[](0));
        usdc.mint(attacker, 7);
        vm.prank(attacker);
        usdc.transfer(executor, 7);

        vm.prank(custodianA);
        vm.expectRevert(
            abi.encodeWithSelector(
                ExternalStateErrors.ExternalStateExecutorDustCheckFailed.selector,
                address(usdc),
                500e6,
                uint256(0)
            )
        );
        IExternalStateExecutor(executor).proposeBalance(balanceAccount, 500e6);
    }

    // ============================================================
    // 9. custody returns sent straight to the executor outside a vault call (IL-8841)
    // ============================================================

    /// @dev Baseline: deposit 1000, 500 forwarded to custody and confirmed, market balance refreshed.
    function _custodyBaseline() internal returns (address executor, uint256 nav0) {
        executor = _readExecutor();
        _userDeposit(1_000e6);
        _enter(500e6, _forwardActions(500e6));
        _custodianConfirm(executor, 500e6);
        _updateMarketBalance();
        nav0 = vault.totalAssets();
    }

    /// @dev The custody pays 30 straight to the executor, outside any vault call (not credit, not a vault flow).
    function _custodyReturn(address executor_) internal {
        vm.prank(address(custody));
        usdc.transfer(executor_, 30e6);
    }

    function test_outOfBandCustodyReturn_doesNotBlockReportThatExcludesIt() public {
        (address executor, uint256 nav0) = _custodyBaseline();
        _custodyReturn(executor);
        assertEq(ExternalStateExecutor(executor).unforwardedCredit(address(usdc)), 0, "return is not credit");

        // Custodians already see 470 (custody no longer holds the 30): the dust check must not block them.
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL_S);
        _custodianConfirm(executor, 470e6);
        _updateMarketBalance();
        assertEq(vault.totalAssets(), nav0 - 30e6, "NAV drops by the excluded return");
        assertFalse(ExternalStateSlotHelpers.readPaused(address(vault)), "6% change does not pause");

        // The report excludes the tokens: sweep is the right action.
        vm.expectEmit(false, false, false, true, executor);
        emit ExternalStateExecutor.SurplusSwept(address(usdc), 30e6);
        _sweep(address(usdc));
        _updateMarketBalance();
        assertEq(vault.totalAssets(), nav0, "sweep restores NAV exactly");
        assertEq(ExternalStateExecutor(executor).balances(balanceAccount), 470e6, "balances unchanged by sweep");
        assertEq(ExternalStateExecutor(executor).unforwardedCredit(address(usdc)), 0, "credit stays 0");
        assertEq(usdc.balanceOf(executor), 0, "executor empty");
    }

    function test_outOfBandCustodyReturn_exitBeforeReport_noDoubleCount() public {
        (address executor, uint256 nav0) = _custodyBaseline();
        _custodyReturn(executor);
        uint256 idleBefore = usdc.balanceOf(address(vault));

        _exit(30e6, new ExternalStateExecutorAction[](0));
        _updateMarketBalance();
        assertEq(ExternalStateExecutor(executor).balances(balanceAccount), 470e6, "exit removes the value");
        assertEq(usdc.balanceOf(address(vault)) - idleBefore, 30e6, "vault received the tokens");
        assertEq(vault.totalAssets(), nav0, "NAV unchanged");

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL_S);
        _custodianConfirm(executor, 470e6);
        _updateMarketBalance();
        assertEq(vault.totalAssets(), nav0, "NAV unchanged after the report");
        assertFalse(ExternalStateSlotHelpers.readPaused(address(vault)), "no pause");
    }

    function test_outOfBandCustodyReturn_exitAfterExcludingReport_removesTwice() public {
        (address executor, uint256 nav0) = _custodyBaseline();
        _custodyReturn(executor);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL_S);
        _custodianConfirm(executor, 470e6);

        // Wrong action in this state: the confirmed report already excludes the 30.
        _exit(30e6, new ExternalStateExecutorAction[](0));
        _updateMarketBalance();
        assertEq(ExternalStateExecutor(executor).balances(balanceAccount), 440e6, "value removed a second time");
        assertEq(vault.totalAssets(), nav0 - 30e6, "NAV stays 30 low: sweep, not exit, in this state");
    }

    function test_outOfBandCustodyReturn_sweepBeforeReport_countsTwice() public {
        (address executor, uint256 nav0) = _custodyBaseline();
        _custodyReturn(executor);

        // Wrong action in this state: the balance still counts the 30 (balances 500) and the vault now holds them.
        _sweep(address(usdc));
        _updateMarketBalance();
        assertEq(ExternalStateExecutor(executor).balances(balanceAccount), 500e6, "balances still count the return");
        assertEq(vault.totalAssets(), nav0 + 30e6, "NAV +30 phantom until the next report");
    }

    function test_outOfBandCustodyReturn_exitConsumesPendingCredit() public {
        (address executor, ) = _custodyBaseline();
        _enter(100e6, new ExternalStateExecutorAction[](0)); // credit 100, tokens stay on the executor
        assertEq(ExternalStateExecutor(executor).unforwardedCredit(address(usdc)), 100e6, "credit 100");
        _custodyReturn(executor);

        // Exit of the return eats the credit although the tokens were not credited.
        _exit(30e6, new ExternalStateExecutorAction[](0));
        assertEq(ExternalStateExecutor(executor).unforwardedCredit(address(usdc)), 70e6, "credit debited by 30");
        assertEq(usdc.balanceOf(executor), 100e6, "100 credited tokens still on the executor");

        // The sweep now treats 30 of the credited tokens as surplus.
        _updateMarketBalance();
        uint256 navBefore = vault.totalAssets();
        vm.expectEmit(false, false, false, true, executor);
        emit ExternalStateExecutor.SurplusSwept(address(usdc), 30e6);
        _sweep(address(usdc));
        _updateMarketBalance();
        assertEq(vault.totalAssets() - navBefore, 30e6, "credited tokens swept as phantom NAV");
    }

    // ============================================================
    // Stale credit (credit above the token balance)
    // ============================================================

    /// @dev A counterparty pulls the approved tokens outside `execute`, so the credit (500) outlives the balance (0).
    ///      Donations are then covered by the credit: they block custodians, `sweepSurplus` moves nothing, and each
    ///      `exit` consumes only its own amount, so the block returns with the next donation.
    function test_staleCredit_eachExitConsumesOnlyItsAmount() public {
        address executor = _readExecutor();
        _userDeposit(1_000e6);

        ExternalStateExecutorAction[] memory approveOnly = new ExternalStateExecutorAction[](1);
        approveOnly[0] = ExternalStateExecutorAction({
            target: address(usdc),
            data: abi.encodeCall(IERC20.approve, (address(custody), 500e6))
        });
        _enter(500e6, approveOnly);
        vm.prank(address(custody));
        usdc.transferFrom(executor, address(custody), 500e6);
        assertEq(usdc.balanceOf(executor), 0, "pulled outside execute");
        assertEq(ExternalStateExecutor(executor).unforwardedCredit(address(usdc)), 500e6, "credit is stale");

        _custodianConfirm(executor, 500e6);
        _updateMarketBalance();
        uint256 navBefore = vault.totalAssets();

        // First donation is covered by the stale credit: custodians are blocked, sweep moves nothing.
        vm.warp(block.timestamp + 1 hours);
        usdc.mint(attacker, 60e6);
        vm.prank(attacker);
        usdc.transfer(executor, 30e6);
        vm.prank(custodianA);
        vm.expectRevert(
            abi.encodeWithSelector(
                ExternalStateErrors.ExternalStateExecutorDustCheckFailed.selector,
                address(usdc),
                30e6,
                uint256(0)
            )
        );
        IExternalStateExecutor(executor).proposeBalance(balanceAccount, 500e6);

        vm.expectEmit(false, false, false, true, executor);
        emit ExternalStateExecutor.SurplusSwept(address(usdc), 0);
        _sweep(address(usdc));
        assertEq(usdc.balanceOf(executor), 30e6, "sweep did not move the covered donation");

        // Exit consumes only its own amount of the credit; the account reads low by the donated tokens.
        _exit(30e6, new ExternalStateExecutorAction[](0));
        assertEq(ExternalStateExecutor(executor).unforwardedCredit(address(usdc)), 470e6, "credit consumed by 30 only");
        assertEq(ExternalStateExecutor(executor).balances(balanceAccount), 470e6, "account lowered by the exit");
        _updateMarketBalance();
        assertEq(vault.totalAssets(), navBefore, "NAV unchanged for the vault underlying");

        _custodianConfirm(executor, 500e6);

        // Credit is still 470, so the next donation blocks custodians again.
        vm.warp(block.timestamp + 1 hours);
        vm.prank(attacker);
        usdc.transfer(executor, 30e6);
        vm.prank(custodianA);
        vm.expectRevert(
            abi.encodeWithSelector(
                ExternalStateErrors.ExternalStateExecutorDustCheckFailed.selector,
                address(usdc),
                30e6,
                uint256(0)
            )
        );
        IExternalStateExecutor(executor).proposeBalance(balanceAccount, 500e6);
    }

    // ============================================================
    // Helpers
    // ============================================================

    function _forwardActions(uint256 amount_) internal view returns (ExternalStateExecutorAction[] memory actions) {
        actions = new ExternalStateExecutorAction[](2);
        actions[0] = ExternalStateExecutorAction({
            target: address(usdc),
            data: abi.encodeCall(IERC20.approve, (address(custody), amount_))
        });
        actions[1] = ExternalStateExecutorAction({
            target: address(custody),
            data: abi.encodeCall(MockPullCustody.deposit, (address(usdc), amount_))
        });
    }

    function _enterActionsOnly(ExternalStateExecutorAction[] memory actions_) internal {
        ExternalStateOperationFuseEnterData memory d = ExternalStateOperationFuseEnterData({
            asset: address(0),
            amount: 0,
            balanceAccount: address(0),
            actions: actions_
        });
        _executeFuse(address(opFuse), abi.encodeCall(opFuse.enter, (d)));
    }

    function _sweep(address asset_) internal {
        _executeFuse(address(opFuse), abi.encodeCall(opFuse.sweepSurplus, (asset_)));
    }

    function _executeFuse(address fuse_, bytes memory data_) internal {
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction({fuse: fuse_, data: data_});
        vm.prank(alpha);
        vault.execute(calls);
    }

    function _enter(uint256 amount_, ExternalStateExecutorAction[] memory actions_) internal {
        ExternalStateOperationFuseEnterData memory d = ExternalStateOperationFuseEnterData({
            asset: address(usdc),
            amount: amount_,
            balanceAccount: balanceAccount,
            actions: actions_
        });
        _executeFuse(address(opFuse), abi.encodeCall(opFuse.enter, (d)));
    }

    function _exit(uint256 amount_, ExternalStateExecutorAction[] memory actions_) internal {
        ExternalStateOperationFuseExitData memory d = ExternalStateOperationFuseExitData({
            asset: address(usdc),
            amount: amount_,
            balanceAccount: balanceAccount,
            actions: actions_
        });
        _executeFuse(address(opFuse), abi.encodeCall(opFuse.exit, (d)));
    }

    function _custodianConfirm(address executor_, uint256 value_) internal {
        vm.prank(custodianA);
        IExternalStateExecutor(executor_).proposeBalance(balanceAccount, value_);
        (, , uint64 proposedAt, uint256 n) = ExternalStateExecutor(executor_).pendingProposals(balanceAccount);
        bytes32 h = _proposalHash(executor_, balanceAccount, value_, custodianA, proposedAt, n);
        vm.prank(custodianB);
        IExternalStateExecutor(executor_).confirmBalance(balanceAccount, h);
    }

    function _proposalHash(
        address executor_,
        address ba_,
        uint256 val_,
        address proposer_,
        uint64 at_,
        uint256 n_
    ) internal view returns (bytes32) {
        return keccak256(abi.encode(executor_, block.chainid, ba_, val_, proposer_, at_, n_));
    }

    function _updateMarketBalance() internal {
        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = MARKET_ID;
        vm.prank(atomist);
        vault.updateMarketsBalances(marketIds);
    }

    function _registerPausePreHook() internal {
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = PlasmaVault.deposit.selector;
        selectors[1] = PlasmaVault.mint.selector;
        selectors[2] = PlasmaVault.withdraw.selector;
        selectors[3] = PlasmaVault.redeem.selector;
        address[] memory implementations = new address[](4);
        bytes32[][] memory substrates = new bytes32[][](4);
        for (uint256 i; i < 4; ++i) {
            implementations[i] = address(preHook);
            substrates[i] = new bytes32[](0);
        }
        vm.prank(atomist);
        PlasmaVaultGovernance(address(vault)).setPreHookImplementations(selectors, implementations, substrates);
    }

    function _userDeposit(uint256 amount_) internal {
        usdc.mint(user, amount_);
        vm.startPrank(user);
        usdc.approve(address(vault), amount_);
        vault.deposit(amount_, user);
        vm.stopPrank();
    }

    function _readExecutor() internal view returns (address) {
        bytes32 slot = bytes32(
            uint256(ExternalStateTestConstants.EXTERNAL_STATE_SLOT) + ExternalStateTestConstants.EXECUTOR_SLOT_OFFSET
        );
        return address(uint160(uint256(vm.load(address(vault), slot))));
    }
}
