// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";

import {HyperCoreEffectSettlementBase} from "./HyperCoreEffectSettlementBase.sol";
import {ExecuteData} from "../../../contracts/managers/context/ContextManager.sol";
import {PlasmaVaultMarketsLib} from "../../../contracts/vaults/lib/PlasmaVaultMarketsLib.sol";

/// @title HyperCoreContextManagerFlowTest
/// @notice IL-8948 (C-027): a deposit and a withdraw relayed through `ContextManager.runWithContext` on a
///         factory-created HyperCore vault with the capital-flow hook wired must behave exactly like direct calls
///         (IL-8310: the hook's nested `updateMarketsBalances` self-call is authorized against the vault, the outer
///         call against the context sender). Each relayed flow runs on a snapshot twin of the direct flow.
contract HyperCoreContextManagerFlowTest is HyperCoreEffectSettlementBase {
    uint256 private constant DEPOSIT_ASSETS = 100_000e6;
    uint256 private constant WITHDRAW_ASSETS = 40_000e6;

    struct FlowResult {
        uint256 shares;
        uint256 assets;
        uint256 userShares;
        uint256 userAssets;
        uint256 totalAssets;
        uint256 totalSupply;
        uint256 refreshEvents;
    }

    function setUp() public override {
        super.setUp();
        vm.startPrank(_user);
        _usdc.mint(_user, DEPOSIT_ASSETS);
        _usdc.approve(address(_vault), type(uint256).max);
        vm.stopPrank();
        // Clear any same-timestamp redemption guard left by the fixture's initial deposit.
        vm.warp(block.timestamp + 1 days);
    }

    function test_depositRelayedThroughContextManagerMatchesDirectDeposit() external {
        uint256 snapshot = vm.snapshotState();
        FlowResult memory direct = _deposit(false);
        vm.revertToState(snapshot);
        FlowResult memory relayed = _deposit(true);

        assertGt(direct.shares, 0, "direct deposit minted no shares");
        assertEq(relayed.shares, direct.shares, "shares");
        assertEq(relayed.userShares, direct.userShares, "user shares");
        assertEq(relayed.userAssets, direct.userAssets, "user assets");
        assertEq(relayed.totalAssets, direct.totalAssets, "totalAssets");
        assertEq(relayed.totalSupply, direct.totalSupply, "totalSupply");
        assertEq(direct.refreshEvents, 1, "direct: hook refreshed market 55 once");
        assertEq(relayed.refreshEvents, 1, "relayed: hook refreshed market 55 once");
    }

    function test_withdrawRelayedThroughContextManagerMatchesDirectWithdraw() external {
        uint256 snapshot = vm.snapshotState();
        FlowResult memory direct = _withdraw(false);
        vm.revertToState(snapshot);
        FlowResult memory relayed = _withdraw(true);

        assertGt(direct.shares, 0, "direct withdraw burned no shares");
        assertEq(relayed.shares, direct.shares, "shares burned");
        assertEq(relayed.userShares, direct.userShares, "user shares");
        assertEq(relayed.userAssets, direct.userAssets, "user assets");
        assertEq(relayed.totalAssets, direct.totalAssets, "totalAssets");
        assertEq(relayed.totalSupply, direct.totalSupply, "totalSupply");
        assertEq(direct.refreshEvents, 1, "direct: hook refreshed market 55 once");
        assertEq(relayed.refreshEvents, 1, "relayed: hook refreshed market 55 once");
    }

    function _deposit(bool relayed_) private returns (FlowResult memory r) {
        uint256 sharesBefore = _vault.balanceOf(_user);
        bytes memory data = abi.encodeCall(_vault.deposit, (DEPOSIT_ASSETS, _user));
        vm.recordLogs();
        if (relayed_) {
            _relay(data);
        } else {
            vm.prank(_user);
            _vault.deposit(DEPOSIT_ASSETS, _user);
        }
        r = _collect(vm.getRecordedLogs());
        r.shares = r.userShares - sharesBefore;
    }

    function _withdraw(bool relayed_) private returns (FlowResult memory r) {
        uint256 sharesBefore = _vault.balanceOf(_user);
        bytes memory data = abi.encodeCall(_vault.withdraw, (WITHDRAW_ASSETS, _user, _user));
        vm.recordLogs();
        if (relayed_) {
            _relay(data);
        } else {
            vm.prank(_user);
            _vault.withdraw(WITHDRAW_ASSETS, _user, _user);
        }
        r = _collect(vm.getRecordedLogs());
        r.shares = sharesBefore - r.userShares;
    }

    function _relay(bytes memory data_) private {
        address[] memory targets = new address[](1);
        targets[0] = address(_vault);
        bytes[] memory datas = new bytes[](1);
        datas[0] = data_;
        vm.prank(_user);
        _contextManager.runWithContext(ExecuteData({targets: targets, datas: datas}));
    }

    /// @dev Counts `MarketBalancesUpdated([MARKET_ID], _)` emitted by the vault (only the capital-flow hook's nested
    ///      refresh emits it in these flows) and snapshots the post-flow state.
    function _collect(Vm.Log[] memory logs_) private view returns (FlowResult memory r) {
        bytes32 topic = PlasmaVaultMarketsLib.MarketBalancesUpdated.selector;
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter != address(_vault) || logs_[i].topics[0] != topic) continue;
            (uint256[] memory marketIds, ) = abi.decode(logs_[i].data, (uint256[], int256));
            if (marketIds.length == 1 && marketIds[0] == MARKET_ID) ++r.refreshEvents;
        }
        r.userShares = _vault.balanceOf(_user);
        r.userAssets = _usdc.balanceOf(_user);
        r.totalAssets = _vault.totalAssets();
        r.totalSupply = _vault.totalSupply();
    }
}
