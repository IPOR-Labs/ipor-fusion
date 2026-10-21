// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

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
import {ExternalStateExecutor} from "../../../../contracts/fuses/external_state/ExternalStateExecutor.sol";
import {
    IExternalStateExecutor,
    ExternalStateExecutorAction
} from "../../../../contracts/fuses/external_state/IExternalStateExecutor.sol";
import {ExternalStateErrors} from "../../../../contracts/fuses/external_state/errors/ExternalStateErrors.sol";
import {ExternalStateSubstrateLib} from "../../../../contracts/fuses/external_state/lib/ExternalStateSubstrateLib.sol";

import {FeeConfigHelper} from "../../../test_helpers/FeeConfigHelper.sol";
import {RoleLib, UsersToRoles} from "../../../RoleLib.sol";
import {MutableValuePriceFeed} from "../../../managers/MutableValuePriceFeed.sol";
import {MockERC20ForExternalState} from "./mocks/MockERC20ForExternalState.sol";
import {ExternalStateTestConstants} from "./ExternalStateTestHelpers.sol";

/// @dev Custody counterparty: pulls approved tokens off the executor and pays them back on request.
contract StaleProposalMockCustody {
    function deposit(address asset_, uint256 amount_) external {
        IERC20(asset_).transferFrom(msg.sender, address(this), amount_);
    }

    function withdraw(address asset_, uint256 amount_) external {
        IERC20(asset_).transfer(msg.sender, amount_);
    }
}

/// @title ExternalStateStaleProposalTest
/// @notice IL-8748 regression suite on a real PlasmaVault. A custodian proposal is an absolute snapshot of a balance
///         account, so `confirmBalance` must revert when an ALPHA `enter` / `exit` changed the account after the
///         proposal was stored (otherwise the flow is erased or double counted in NAV). Net-zero flows, re-proposals
///         and flows on other accounts must keep working.
contract ExternalStateStaleProposalTest is Test {
    uint256 internal constant MARKET_ID = IporFusionMarkets.EXTERNAL_STATE;
    uint256 internal constant STALENESS_MAX_S = 1 days;
    uint256 internal constant BIG_CHANGE_BPS = 1000; // 10%
    uint256 internal constant MIN_UPDATE_INTERVAL_S = 5 minutes;

    PlasmaVault internal vault;
    IporFusionAccessManager internal accessManager;
    PriceOracleMiddleware internal priceOracle;
    MockERC20ForExternalState internal usdc;
    MutableValuePriceFeed internal priceFeed;
    StaleProposalMockCustody internal custody;

    ExternalStateOperationFuse internal opFuse;
    ExternalStateBalanceFuse internal balanceFuse;

    address internal atomist;
    address internal alpha;
    address internal custodianA;
    address internal custodianB;
    address internal baA;
    address internal baB;
    address internal user;

    address internal executor;

    UsersToRoles internal usersToRoles;

    function setUp() public {
        atomist = makeAddr("atomist");
        alpha = makeAddr("alpha");
        custodianA = makeAddr("custodianA");
        custodianB = makeAddr("custodianB");
        baA = makeAddr("baA");
        baB = makeAddr("baB");
        user = makeAddr("user");

        usdc = new MockERC20ForExternalState("USD Coin", "USDC", 6);
        custody = new StaleProposalMockCustody();

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
        vault = new PlasmaVault();
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

        bytes4[] memory extraSig = new bytes4[](2);
        extraSig[0] = PlasmaVaultGovernance.grantMarketSubstrates.selector;
        extraSig[1] = PlasmaVault.updateMarketsBalances.selector;
        vm.prank(atomist);
        accessManager.setTargetFunctionRole(address(vault), extraSig, Roles.ATOMIST_ROLE);

        opFuse = new ExternalStateOperationFuse(MARKET_ID);
        balanceFuse = new ExternalStateBalanceFuse(MARKET_ID);

        address[] memory fuses = new address[](1);
        fuses[0] = address(opFuse);

        bytes32[] memory subs = new bytes32[](11);
        subs[0] = ExternalStateSubstrateLib.encodeAssetSubstrate(address(usdc));
        subs[1] = ExternalStateSubstrateLib.encodeBalanceAccountSubstrate(baA);
        subs[2] = ExternalStateSubstrateLib.encodeBalanceAccountSubstrate(baB);
        subs[3] = ExternalStateSubstrateLib.encodeCustodianSubstrate(custodianA);
        subs[4] = ExternalStateSubstrateLib.encodeCustodianSubstrate(custodianB);
        subs[5] = ExternalStateSubstrateLib.encodeTargetSubstrate(address(usdc), IERC20.approve.selector);
        subs[6] = ExternalStateSubstrateLib.encodeTargetSubstrate(
            address(custody),
            StaleProposalMockCustody.deposit.selector
        );
        subs[7] = ExternalStateSubstrateLib.encodeTargetSubstrate(
            address(custody),
            StaleProposalMockCustody.withdraw.selector
        );
        subs[8] = ExternalStateSubstrateLib.encodeStalenessMaxSubstrate(STALENESS_MAX_S);
        subs[9] = ExternalStateSubstrateLib.encodeBigChangeBpsSubstrate(BIG_CHANGE_BPS);
        subs[10] = ExternalStateSubstrateLib.encodeMinUpdateIntervalSubstrate(MIN_UPDATE_INTERVAL_S);

        vm.startPrank(atomist);
        PlasmaVaultGovernance(address(vault)).addFuses(fuses);
        PlasmaVaultGovernance(address(vault)).addBalanceFuse(MARKET_ID, address(balanceFuse));
        PlasmaVaultGovernance(address(vault)).grantMarketSubstrates(MARKET_ID, subs);
        vm.stopPrank();

        _executeFuse(abi.encodeCall(opFuse.createExecutor, ()));
        executor = _readExecutor();
        IExternalStateExecutor(executor).syncSubstrates();

        // Starting point: depositor holds 2000 USDC worth of shares, 1000 of it is allocated to baA and attested.
        _userDeposit(2_000e6);
        _enter(baA, 1_000e6);
        _confirmFresh(baA, 1_000e6);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL_S + 1);
    }

    // ============================================================
    // 1. exit between propose and confirm
    // ============================================================

    function test_confirmAfterInterveningExit_reverts() public {
        uint256 navBefore = vault.totalAssets();
        uint256 priceBefore = vault.convertToAssets(1e6);
        assertEq(navBefore, 2_000e6, "nav before");

        // Custodian A observes 1000 on baA.
        bytes32 h = _propose(custodianA, baA, 1_000e6);
        assertEq(ExternalStateExecutor(executor).proposalBaseBalance(baA), 1_000e6, "base stored at propose");

        // ALPHA exits 50 afterwards: 50 USDC come back to the vault, baA tracks 950.
        _exit(baA, 50e6);
        assertEq(ExternalStateExecutor(executor).balances(baA), 950e6, "balance after exit");

        // Confirm with the stale hash would put the exited 50 back into the market (NAV 2050).
        vm.prank(custodianB);
        vm.expectRevert(
            abi.encodeWithSelector(
                ExternalStateErrors.ExternalStateExecutorBalanceChangedSinceProposal.selector,
                baA,
                1_000e6,
                950e6
            )
        );
        IExternalStateExecutor(executor).confirmBalance(baA, h);
        assertEq(ExternalStateExecutor(executor).balances(baA), 950e6, "balance untouched by the failed confirm");
        (, address proposer, , ) = ExternalStateExecutor(executor).pendingProposals(baA);
        assertEq(proposer, custodianA, "proposal stays pending");

        // Custodians report again after the flow: NAV equals real coverage, share price unchanged.
        _proposeAndConfirm(baA, 950e6);
        _updateMarketBalance();
        assertEq(vault.totalAssetsInMarket(MARKET_ID), 950e6, "market balance = real coverage");
        assertEq(vault.totalAssets(), navBefore, "nav equals real coverage");
        assertEq(vault.convertToAssets(1e6), priceBefore, "share price unchanged");
    }

    // ============================================================
    // 2. enter between propose and confirm
    // ============================================================

    function test_confirmAfterInterveningEnter_reverts() public {
        bytes32 h = _propose(custodianA, baA, 1_000e6);

        _enter(baA, 50e6);
        assertEq(ExternalStateExecutor(executor).balances(baA), 1_050e6, "balance after enter");

        vm.prank(custodianB);
        vm.expectRevert(
            abi.encodeWithSelector(
                ExternalStateErrors.ExternalStateExecutorBalanceChangedSinceProposal.selector,
                baA,
                1_000e6,
                1_050e6
            )
        );
        IExternalStateExecutor(executor).confirmBalance(baA, h);

        // The re-report after the flow is accepted and NAV stays at real coverage.
        _proposeAndConfirm(baA, 1_050e6);
        _updateMarketBalance();
        assertEq(vault.totalAssets(), 2_000e6, "nav equals real coverage");
    }

    // ============================================================
    // 3. net-zero flow
    // ============================================================

    function test_netZeroFlow_confirmPasses() public {
        bytes32 h = _propose(custodianA, baA, 1_000e6);

        _enter(baA, 50e6);
        _exit(baA, 50e6);
        assertEq(ExternalStateExecutor(executor).balances(baA), 1_000e6, "back to the proposal base");

        vm.prank(custodianB);
        IExternalStateExecutor(executor).confirmBalance(baA, h);
        assertEq(ExternalStateExecutor(executor).balances(baA), 1_000e6, "confirmed");
        _updateMarketBalance();
        assertEq(vault.totalAssets(), 2_000e6, "nav equals real coverage");
    }

    // ============================================================
    // 4. re-proposal re-bases the snapshot
    // ============================================================

    function test_reProposalRebasesSnapshot() public {
        _propose(custodianA, baA, 1_000e6);
        (, , , uint256 firstNonce) = ExternalStateExecutor(executor).pendingProposals(baA);
        assertEq(ExternalStateExecutor(executor).proposalBaseBalance(baA), 1_000e6, "first base");

        _exit(baA, 50e6);

        vm.expectEmit(address(executor));
        emit ExternalStateExecutor.ProposalOverwritten(baA, custodianA, custodianB, firstNonce, firstNonce + 1);
        bytes32 h = _propose(custodianB, baA, 950e6);
        assertEq(ExternalStateExecutor(executor).proposalBaseBalance(baA), 950e6, "base re-based on overwrite");

        vm.prank(custodianA);
        IExternalStateExecutor(executor).confirmBalance(baA, h);
        assertEq(ExternalStateExecutor(executor).balances(baA), 950e6, "confirmed after re-proposal");
        _updateMarketBalance();
        assertEq(vault.totalAssets(), 2_000e6, "nav equals real coverage");
    }

    // ============================================================
    // 5. flow on another account
    // ============================================================

    function test_flowOnOtherAccount_doesNotBlock() public {
        bytes32 h = _propose(custodianA, baA, 1_000e6);

        _enter(baB, 100e6);
        _exit(baB, 30e6);
        assertEq(ExternalStateExecutor(executor).balances(baB), 70e6, "baB changed");

        vm.prank(custodianB);
        IExternalStateExecutor(executor).confirmBalance(baA, h);
        assertEq(ExternalStateExecutor(executor).balances(baA), 1_000e6, "baA confirmed");
        assertEq(ExternalStateExecutor(executor).balances(baB), 70e6, "baB untouched by the confirm");
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
            data: abi.encodeCall(StaleProposalMockCustody.deposit, (address(usdc), amount_))
        });
    }

    /// @dev Enter `amount_` into `ba_` and forward it to the custody counterparty (executor stays empty).
    function _enter(address ba_, uint256 amount_) internal {
        ExternalStateOperationFuseEnterData memory d = ExternalStateOperationFuseEnterData({
            asset: address(usdc),
            amount: amount_,
            balanceAccount: ba_,
            actions: _forwardActions(amount_)
        });
        _executeFuse(abi.encodeCall(opFuse.enter, (d)));
    }

    /// @dev Exit `amount_` from `ba_`: the custody counterparty pays it back, the fuse forwards it to the vault.
    function _exit(address ba_, uint256 amount_) internal {
        ExternalStateExecutorAction[] memory actions = new ExternalStateExecutorAction[](1);
        actions[0] = ExternalStateExecutorAction({
            target: address(custody),
            data: abi.encodeCall(StaleProposalMockCustody.withdraw, (address(usdc), amount_))
        });
        ExternalStateOperationFuseExitData memory d = ExternalStateOperationFuseExitData({
            asset: address(usdc),
            amount: amount_,
            balanceAccount: ba_,
            actions: actions
        });
        _executeFuse(abi.encodeCall(opFuse.exit, (d)));
    }

    function _propose(address proposer_, address ba_, uint256 value_) internal returns (bytes32 h) {
        vm.prank(proposer_);
        IExternalStateExecutor(executor).proposeBalance(ba_, value_);
        (, , uint64 proposedAt, uint256 n) = ExternalStateExecutor(executor).pendingProposals(ba_);
        h = keccak256(abi.encode(executor, block.chainid, ba_, value_, proposer_, proposedAt, n));
    }

    function _proposeAndConfirm(address ba_, uint256 value_) internal {
        bytes32 h = _propose(custodianA, ba_, value_);
        vm.prank(custodianB);
        IExternalStateExecutor(executor).confirmBalance(ba_, h);
    }

    /// @dev First report of an account (exempt from MIN_UPDATE_INTERVAL), followed by a market refresh.
    function _confirmFresh(address ba_, uint256 value_) internal {
        _proposeAndConfirm(ba_, value_);
        _updateMarketBalance();
    }

    function _updateMarketBalance() internal {
        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = MARKET_ID;
        vm.prank(atomist);
        vault.updateMarketsBalances(marketIds);
    }

    function _executeFuse(bytes memory data_) internal {
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction({fuse: address(opFuse), data: data_});
        vm.prank(alpha);
        vault.execute(calls);
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
