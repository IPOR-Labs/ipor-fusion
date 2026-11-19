// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Vm} from "forge-std/Test.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVaultVotesPlugin} from "../../../contracts/vaults/plugins/PlasmaVaultVotesPlugin.sol";
import {IPlasmaVaultVotesPlugin} from "../../../contracts/interfaces/IPlasmaVaultVotesPlugin.sol";
import {FuseAction} from "../../../contracts/interfaces/IPlasmaVault.sol";
import {IFuseCommon} from "../../../contracts/fuses/IFuseCommon.sol";
import {CallbackHandlerLib} from "../../../contracts/libraries/CallbackHandlerLib.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {Errors} from "../../../contracts/libraries/errors/Errors.sol";
import {TransientStorageLib} from "../../../contracts/transient_storage/TransientStorageLib.sol";
import {RealizeManagementFeeFuse} from "../../../contracts/fuses/management_fee/RealizeManagementFeeFuse.sol";
import {IRealizeManagementFeeInternal} from "../../../contracts/interfaces/IRealizeManagementFeeInternal.sol";
import {RealizeManagementFeeTestBase} from "../../vaults/PlasmaVaultRealizeManagementFeeTest.t.sol";

/// @notice Test fuse that publishes the transient outputs of the fuse under test (it runs in the vault context)
contract RealizeManagementFeeOutputsReaderFuse is IFuseCommon {
    event OutputsRead(uint256 length, bytes32 first);

    uint256 public constant MARKET_ID = IporFusionMarkets.ZERO_BALANCE_MARKET;

    address public immutable FUSE_UNDER_TEST;

    constructor(address fuseUnderTest_) {
        FUSE_UNDER_TEST = fuseUnderTest_;
    }

    function enter() external {
        bytes32[] memory outputs = TransientStorageLib.getOutputs(FUSE_UNDER_TEST);
        emit OutputsRead(outputs.length, outputs.length > 0 ? outputs[0] : bytes32(0));
    }
}

/// @title RealizeManagementFeeFuseTest
/// @notice IL-8870 unit tests of RealizeManagementFeeFuse through a real PlasmaVault: the new version (self-call of
///         `realizeManagementFeeInternal()`) and the legacy branch, forced with `vm.mockCallRevert` of the exact
///         `HandlerNotFound()` data that vaults without the entry answer with during `execute`
contract RealizeManagementFeeFuseTest is RealizeManagementFeeTestBase {
    event OutputsRead(uint256 length, bytes32 first);

    bytes32 private constant FUSE_ENTER_TOPIC = keccak256("RealizeManagementFeeFuseEnter(address,uint256)");
    bytes32 private constant FEE_REALIZED_TOPIC = keccak256("ManagementFeeRealized(uint256,uint256)");
    bytes32 private constant OUTPUTS_READ_TOPIC = keccak256("OutputsRead(uint256,bytes32)");

    // ---------------------------------------------------------------------------------------------
    // 1. New version
    // ---------------------------------------------------------------------------------------------

    function testShouldCollectThroughInternalEntryOnNewVersion() public {
        _deployVault(MANAGEMENT_FEE, address(0));
        _deposit(user, DEPOSIT);
        vm.warp(block.timestamp + 365 days);

        uint256 fee = plasmaVault.getUnrealizedManagementFee();
        uint256 expectedShares = _expectedShares(fee, plasmaVault.totalSupply(), plasmaVault.totalAssets());
        uint256 rateBefore = plasmaVault.convertToAssets(RATE_PROBE);
        uint256 snapshot = vm.snapshotState();

        vm.expectCall(
            address(plasmaVault),
            abi.encodeWithSelector(IRealizeManagementFeeInternal.realizeManagementFeeInternal.selector)
        );
        vm.recordLogs();
        _executeRealizeFuse();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(plasmaVault.balanceOf(feeAccount), expectedShares, "fee shares of the vault formula");
        assertEq(plasmaVault.convertToAssets(RATE_PROBE), rateBefore, "share price unchanged");
        assertEq(_lastUpdate(), block.timestamp, "clock moved to now");
        assertEq(_pending(), 0, "pending cleared");

        uint256 realizedIndex = _logIndex(logs, FEE_REALIZED_TOPIC);
        uint256 enterIndex = _logIndex(logs, FUSE_ENTER_TOPIC);
        assertLt(realizedIndex, enterIndex, "ManagementFeeRealized comes before RealizeManagementFeeFuseEnter");
        (uint256 eventFee, uint256 eventShares) = abi.decode(logs[realizedIndex].data, (uint256, uint256));
        assertEq(eventFee, fee, "vault event fee");
        assertEq(eventShares, expectedShares, "vault event shares");
        (address version, uint256 enterShares) = abi.decode(logs[enterIndex].data, (address, uint256));
        assertEq(version, address(realizeFuse), "fuse event version");
        assertEq(enterShares, expectedShares, "fuse event shares");

        vm.revertToState(snapshot);
        _deposit(depositor, ONE_UNIT);
        assertEq(plasmaVault.balanceOf(feeAccount), expectedShares, "same fee shares as the deposit collection");
    }

    function testShouldKeepStateOfDepositCollectionWhenVaultHasNoFee() public {
        _deployVault(0, address(0));
        _deposit(user, DEPOSIT);
        uint256 clockBefore = _lastUpdate();
        vm.warp(block.timestamp + 30 days);
        uint256 snapshot = vm.snapshotState();

        vm.recordLogs();
        _executeRealizeFuse();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        State memory viaFuse = _state();
        vm.revertToState(snapshot);
        _deposit(depositor, ONE_UNIT);
        State memory viaDeposit = _state();

        assertLt(clockBefore, block.timestamp, "precondition: time passed");
        assertEq(_countVaultLogs(logs, FEE_REALIZED_TOPIC), 0, "no ManagementFeeRealized");
        assertEq(_countVaultLogs(logs, FUSE_ENTER_TOPIC), 0, "no RealizeManagementFeeFuseEnter on zero shares");
        assertEq(viaFuse.feeShares, 0, "nothing minted");
        assertEq(viaFuse.feeShares, viaDeposit.feeShares, "fee shares as for a deposit");
        assertEq(viaFuse.clock, block.timestamp, "clock moved to now");
        assertEq(viaFuse.clock, viaDeposit.clock, "clock as for a deposit");
        assertEq(viaFuse.pending, viaDeposit.pending, "pending as for a deposit");
    }

    function testShouldKeepStateOfDepositCollectionWhenSupplyIsZero() public {
        _deployVault(MANAGEMENT_FEE, address(0));
        vm.warp(block.timestamp + 100 days);
        uint256 snapshot = vm.snapshotState();

        vm.recordLogs();
        _executeRealizeFuse();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        State memory viaFuse = _state();
        vm.revertToState(snapshot);
        _deposit(depositor, ONE_UNIT);
        State memory viaDeposit = _state();

        assertEq(_countVaultLogs(logs, FEE_REALIZED_TOPIC), 0, "no ManagementFeeRealized");
        assertEq(_countVaultLogs(logs, FUSE_ENTER_TOPIC), 0, "no RealizeManagementFeeFuseEnter");
        assertEq(viaFuse.totalSupply, 0, "still no supply");
        assertEq(viaFuse.feeShares, viaDeposit.feeShares, "fee shares as for a deposit");
        assertEq(viaFuse.clock, block.timestamp, "clock moved to now");
        assertEq(viaFuse.clock, viaDeposit.clock, "clock as for a deposit");
        assertEq(viaFuse.pending, viaDeposit.pending, "pending as for a deposit");
    }

    function testShouldKeepStateOfDepositCollectionWhenFeeRoundsToZeroShares() public {
        _deployDustVault();
        vm.warp(block.timestamp + 90 days);
        uint256 fee = plasmaVault.getUnrealizedManagementFee();
        assertGt(fee, 0, "precondition: positive accrual");
        assertEq(_expectedShares(fee, plasmaVault.totalSupply(), plasmaVault.totalAssets()), 0, "rounds to 0 shares");
        uint256 snapshot = vm.snapshotState();

        vm.recordLogs();
        _executeRealizeFuse();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        State memory viaFuse = _state();
        vm.revertToState(snapshot);
        _deposit(depositor, 1_000e6);
        State memory viaDeposit = _state();

        assertEq(_countVaultLogs(logs, FUSE_ENTER_TOPIC), 0, "no RealizeManagementFeeFuseEnter on zero shares");
        assertEq(viaFuse.feeShares, 0, "nothing minted");
        assertEq(viaFuse.pending, fee, "the accrual stays in pending");
        assertEq(viaFuse.pending, viaDeposit.pending, "pending as for a deposit");
        assertEq(viaFuse.clock, block.timestamp, "clock moved to now");
        assertEq(viaFuse.clock, viaDeposit.clock, "clock as for a deposit");
        assertEq(viaFuse.feeShares, viaDeposit.feeShares, "fee shares as for a deposit");
    }

    // ---------------------------------------------------------------------------------------------
    // 2. Supply cap, performance fee, high water mark
    // ---------------------------------------------------------------------------------------------

    function testShouldMintAboveSupplyCapAndResetCapFlagOnNewVersion() public {
        _assertCapBypassAndPerformanceFeeUntouched(false);
    }

    function testShouldMintAboveSupplyCapAndResetCapFlagOnLegacyBranch() public {
        _assertCapBypassAndPerformanceFeeUntouched(true);
    }

    // ---------------------------------------------------------------------------------------------
    // 3. exit, exitTransient, enterTransient, constants
    // ---------------------------------------------------------------------------------------------

    function testShouldRevertExitAndExitTransient() public {
        RealizeManagementFeeFuse fuse = new RealizeManagementFeeFuse();

        vm.expectRevert(RealizeManagementFeeFuse.RealizeManagementFeeFuseExitNotSupported.selector);
        fuse.exit();

        vm.expectRevert(RealizeManagementFeeFuse.RealizeManagementFeeFuseExitNotSupported.selector);
        fuse.exitTransient();
    }

    /// @dev Outside a vault the self-call hits the fuse itself, which has no such function and no fallback, so the
    ///      empty revert data is re-thrown unchanged
    function testShouldRevertWhenFuseCalledDirectly() public {
        RealizeManagementFeeFuse fuse = new RealizeManagementFeeFuse();

        vm.expectRevert(bytes(""));
        fuse.enter();
    }

    function testShouldExposeMarketIdAndVersion() public {
        RealizeManagementFeeFuse fuse = new RealizeManagementFeeFuse();

        assertEq(fuse.MARKET_ID(), IporFusionMarkets.ZERO_BALANCE_MARKET, "MARKET_ID");
        assertEq(fuse.VERSION(), address(fuse), "VERSION");
    }

    function testShouldWriteFeeSharesToTransientOutputsOnEnterTransient() public {
        _deployVault(MANAGEMENT_FEE, address(0));
        _deposit(user, DEPOSIT);
        vm.warp(block.timestamp + 365 days);
        uint256 expectedShares = _expectedShares(
            plasmaVault.getUnrealizedManagementFee(),
            plasmaVault.totalSupply(),
            plasmaVault.totalAssets()
        );
        RealizeManagementFeeOutputsReaderFuse reader = new RealizeManagementFeeOutputsReaderFuse(address(realizeFuse));
        _addFuse(address(reader));

        FuseAction[] memory actions = new FuseAction[](2);
        actions[0] = FuseAction({
            fuse: address(realizeFuse),
            data: abi.encodeWithSelector(RealizeManagementFeeFuse.enterTransient.selector)
        });
        actions[1] = FuseAction({
            fuse: address(reader),
            data: abi.encodeWithSelector(RealizeManagementFeeOutputsReaderFuse.enter.selector)
        });
        vm.recordLogs();
        vm.prank(alpha);
        plasmaVault.execute(actions);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertGt(expectedShares, 0, "precondition: fee shares expected");
        assertEq(plasmaVault.balanceOf(feeAccount), expectedShares, "minted");
        uint256 index = _logIndex(logs, OUTPUTS_READ_TOPIC);
        (uint256 length, bytes32 first) = abi.decode(logs[index].data, (uint256, bytes32));
        assertEq(length, 1, "one output");
        assertEq(first, bytes32(expectedShares), "outputs[0] is the fee shares");
    }

    // ---------------------------------------------------------------------------------------------
    // 4. Legacy branch (exact HandlerNotFound() from the self-call)
    // ---------------------------------------------------------------------------------------------

    function testShouldMintOnLegacyPathAndMoveClock() public {
        _deployVault(MANAGEMENT_FEE, address(0));
        _deposit(user, DEPOSIT);
        vm.warp(block.timestamp + 365 days);

        uint256 fee = plasmaVault.getUnrealizedManagementFee();
        uint256 supply = plasmaVault.totalSupply();
        uint256 gross = plasmaVault.totalAssets();
        uint256 expectedShares = _legacyExpectedShares(fee, 0, supply, gross);
        assertGt(expectedShares, 0, "precondition: legacy mints");
        assertTrue(expectedShares != _expectedShares(fee, supply, gross), "legacy and new formulas differ here");

        _mockHandlerNotFound();
        vm.expectEmit(false, false, false, true, address(plasmaVault));
        emit ManagementFeeRealized(fee, expectedShares);
        vm.expectEmit(false, false, false, true, address(plasmaVault));
        emit RealizeManagementFeeFuseEnter(address(realizeFuse), expectedShares);
        _executeRealizeFuse();

        assertEq(plasmaVault.balanceOf(feeAccount), expectedShares, "legacy fee shares");
        assertEq(_lastUpdate(), block.timestamp, "clock moved to now");
        assertEq(_pending(), 0, "pending cleared");
        assertEq(plasmaVault.totalSupply(), supply + expectedShares, "supply grew by the minted shares");
    }

    function testShouldClearPendingOnLegacyPath() public {
        _deployDustVault();
        vm.warp(block.timestamp + 90 days);
        vm.prank(alpha);
        plasmaVault.realizeManagementFee();
        uint256 pendingBefore = _pending();
        assertGt(pendingBefore, 0, "precondition: pending fee");
        vm.warp(block.timestamp + 90 days);

        uint256 fee = plasmaVault.getUnrealizedManagementFee();
        uint256 expectedShares = _legacyExpectedShares(
            fee,
            pendingBefore,
            plasmaVault.totalSupply(),
            plasmaVault.totalAssets()
        );
        assertGt(expectedShares, 0, "precondition: legacy mints");

        _mockHandlerNotFound();
        vm.expectEmit(false, false, false, true, address(plasmaVault));
        emit ManagementFeeRealized(fee, expectedShares);
        _executeRealizeFuse();

        assertEq(plasmaVault.balanceOf(feeAccount), expectedShares, "legacy fee shares");
        assertEq(_pending(), 0, "pending slot cleared");
        assertEq(_lastUpdate(), block.timestamp, "clock moved to now");
    }

    function testShouldRestoreClockOnLegacyPathWhenZeroShares() public {
        _deployDustVault();
        vm.warp(block.timestamp + 90 days);
        uint256 clockBefore = _lastUpdate();
        uint256 fee = plasmaVault.getUnrealizedManagementFee();
        assertGt(fee, 0, "precondition: positive accrual");
        assertEq(
            _legacyExpectedShares(fee, 0, plasmaVault.totalSupply(), plasmaVault.totalAssets()),
            0,
            "precondition: legacy conversion rounds to 0 shares"
        );
        assertLt(clockBefore, block.timestamp, "precondition: time passed");

        _mockHandlerNotFound();
        vm.recordLogs();
        _executeRealizeFuse();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(plasmaVault.balanceOf(feeAccount), 0, "nothing minted");
        assertEq(_lastUpdate(), clockBefore, "clock restored to the old value");
        assertEq(_pending(), 0, "pending untouched");
        assertEq(plasmaVault.getUnrealizedManagementFee(), fee, "the fee stays accrued");
        assertEq(_countVaultLogs(logs, FEE_REALIZED_TOPIC), 0, "no ManagementFeeRealized");
        assertEq(_countVaultLogs(logs, FUSE_ENTER_TOPIC), 0, "no RealizeManagementFeeFuseEnter");
    }

    // ---------------------------------------------------------------------------------------------
    // 5. The mint goes through PlasmaVaultBase._update (votes checkpoints, supply cap check)
    // ---------------------------------------------------------------------------------------------

    function testShouldUpdateVotesAndCheckpointsOnNewVersion() public {
        _assertVotesFollowFeeMint(false);
    }

    function testShouldUpdateVotesAndCheckpointsOnLegacyBranch() public {
        _assertVotesFollowFeeMint(true);
    }

    // ---------------------------------------------------------------------------------------------
    // 6. Anything but the exact HandlerNotFound() is re-thrown, a malformed success fails closed
    // ---------------------------------------------------------------------------------------------

    function testShouldRethrowWrongCallerFromInternalEntry() public {
        _deployVault(MANAGEMENT_FEE, address(0));
        _deposit(user, DEPOSIT);
        vm.warp(block.timestamp + 365 days);
        bytes memory revertData = abi.encodeWithSelector(Errors.WrongCaller.selector, makeAddr("someone"));
        vm.mockCallRevert(address(plasmaVault), _entryCall(), revertData);

        vm.expectRevert(revertData);
        _executeRealizeFuse();

        assertEq(plasmaVault.balanceOf(feeAccount), 0, "no legacy mint");
    }

    function testShouldRethrowEmptyRevertDataFromInternalEntry() public {
        _deployVault(MANAGEMENT_FEE, address(0));
        _deposit(user, DEPOSIT);
        vm.warp(block.timestamp + 365 days);
        vm.mockCallRevert(address(plasmaVault), _entryCall(), bytes(""));

        /// @dev `execute` delegatecalls the fuse with Address.functionDelegateCall, which maps empty revert data to
        ///      FailedInnerCall(): the fuse itself reverted with empty data (it did not switch to the legacy path)
        vm.expectRevert(Address.FailedInnerCall.selector);
        _executeRealizeFuse();

        assertEq(plasmaVault.balanceOf(feeAccount), 0, "no legacy mint");
    }

    function testShouldRethrowHandlerNotFoundWithTrailingBytes() public {
        _deployVault(MANAGEMENT_FEE, address(0));
        _deposit(user, DEPOSIT);
        vm.warp(block.timestamp + 365 days);
        bytes memory revertData = abi.encodePacked(CallbackHandlerLib.HandlerNotFound.selector, uint8(1));
        vm.mockCallRevert(address(plasmaVault), _entryCall(), revertData);

        vm.expectRevert(revertData);
        _executeRealizeFuse();

        assertEq(plasmaVault.balanceOf(feeAccount), 0, "no legacy mint");
    }

    function testShouldFailClosedWhenInternalEntryReturnsNoData() public {
        _deployVault(MANAGEMENT_FEE, address(0));
        _deposit(user, DEPOSIT);
        vm.warp(block.timestamp + 365 days);
        vm.mockCall(address(plasmaVault), _entryCall(), bytes(""));

        /// @dev `execute` delegatecalls the fuse with Address.functionDelegateCall, which maps empty revert data to
        ///      FailedInnerCall(): the fuse itself reverted with empty data (it did not switch to the legacy path)
        vm.expectRevert(Address.FailedInnerCall.selector);
        _executeRealizeFuse();

        assertEq(plasmaVault.balanceOf(feeAccount), 0, "nothing minted");
    }

    function testShouldFailClosedWhenInternalEntryReturnsLessThan32Bytes() public {
        _deployVault(MANAGEMENT_FEE, address(0));
        _deposit(user, DEPOSIT);
        vm.warp(block.timestamp + 365 days);
        vm.mockCall(address(plasmaVault), _entryCall(), new bytes(31));

        /// @dev `execute` delegatecalls the fuse with Address.functionDelegateCall, which maps empty revert data to
        ///      FailedInnerCall(): the fuse itself reverted with empty data (it did not switch to the legacy path)
        vm.expectRevert(Address.FailedInnerCall.selector);
        _executeRealizeFuse();

        assertEq(plasmaVault.balanceOf(feeAccount), 0, "nothing minted");
    }

    // ---------------------------------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------------------------------

    function _entryCall() private pure returns (bytes memory) {
        return abi.encodeWithSelector(IRealizeManagementFeeInternal.realizeManagementFeeInternal.selector);
    }

    /// @dev Makes the self-call of the fuse answer like a vault without the entry during `execute`
    function _mockHandlerNotFound() private {
        vm.mockCallRevert(
            address(plasmaVault),
            _entryCall(),
            abi.encodeWithSelector(CallbackHandlerLib.HandlerNotFound.selector)
        );
    }

    /// @dev What the legacy path mints on this (option A) vault when the pending fee is `pending_` and the accrual is
    ///      time only: the fuse moves the clock first, so `convertToShares(fee_)` prices the pending fee as virtual
    ///      shares V_p = floor(P * (S + scale) / (G - P + 1)) and the fee as floor(F * (S + V_p + scale) / (G + 1))
    function _legacyExpectedShares(
        uint256 fee_,
        uint256 pending_,
        uint256 supply_,
        uint256 gross_
    ) private view returns (uint256) {
        uint256 virtualShares = pending_ == 0 ? 0 : Math.mulDiv(pending_, supply_ + shareScale, gross_ - pending_ + 1);
        return Math.mulDiv(fee_, supply_ + virtualShares + shareScale, gross_ + 1);
    }

    function _logIndex(Vm.Log[] memory logs_, bytes32 topic0_) private view returns (uint256) {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == address(plasmaVault) && logs_[i].topics[0] == topic0_) {
                return i;
            }
        }
        revert("log not found");
    }

    function _setSupplyCapToCurrentSupply() private {
        uint256 cap = plasmaVault.totalSupply();
        vm.prank(atomist);
        PlasmaVaultGovernance(address(plasmaVault)).setTotalSupplyCap(cap);
    }

    function _assertCapBypassAndPerformanceFeeUntouched(bool legacy_) private {
        _deployVault(MANAGEMENT_FEE, address(0));
        _deposit(user, DEPOSIT);
        vm.warp(block.timestamp + 365 days);
        _setSupplyCapToCurrentSupply();

        uint256 cap = plasmaVault.totalSupply();
        uint256 fee = plasmaVault.getUnrealizedManagementFee();
        uint256 supply = plasmaVault.totalSupply();
        uint256 gross = plasmaVault.totalAssets();
        uint256 expectedShares = legacy_
            ? _legacyExpectedShares(fee, 0, supply, gross)
            : _expectedShares(fee, supply, gross);
        uint256 hwmBefore = _hwm();
        assertEq(uint256(vm.load(address(plasmaVault), CAP_VALIDATION_FLAG_SLOT)), 0, "cap checked before");
        assertGt(expectedShares, 0, "precondition: shares to mint");

        if (legacy_) {
            _mockHandlerNotFound();
        }
        _executeRealizeFuse();

        assertEq(plasmaVault.balanceOf(feeAccount), expectedShares, "fee shares minted");
        assertEq(plasmaVault.totalSupply(), cap + expectedShares, "supply above the cap");
        assertGt(
            plasmaVault.totalSupply(),
            PlasmaVaultGovernance(address(plasmaVault)).getTotalSupplyCap(),
            "the cap was bypassed for the mint"
        );
        assertEq(uint256(vm.load(address(plasmaVault), CAP_VALIDATION_FLAG_SLOT)), 0, "cap flag back to 0");
        assertEq(plasmaVault.balanceOf(performanceFeeAccount), 0, "no performance fee shares");
        assertEq(_hwm(), hwmBefore, "high water mark unchanged");
    }

    function _assertVotesFollowFeeMint(bool legacy_) private {
        _deployVault(MANAGEMENT_FEE, address(new PlasmaVaultVotesPlugin()));
        _deposit(user, DEPOSIT);
        IPlasmaVaultVotesPlugin votes = IPlasmaVaultVotesPlugin(address(plasmaVault));
        vm.prank(feeAccount);
        votes.delegate(feeAccount);
        vm.warp(block.timestamp + 365 days);
        _setSupplyCapToCurrentSupply();

        uint256 fee = plasmaVault.getUnrealizedManagementFee();
        uint256 supply = plasmaVault.totalSupply();
        uint256 gross = plasmaVault.totalAssets();
        uint256 expectedShares = legacy_
            ? _legacyExpectedShares(fee, 0, supply, gross)
            : _expectedShares(fee, supply, gross);
        uint256 votesBefore = votes.getVotes(feeAccount);
        assertGt(expectedShares, 0, "precondition: shares to mint");

        if (legacy_) {
            _mockHandlerNotFound();
        }
        _executeRealizeFuse();
        uint48 collectionPoint = votes.clock();

        assertEq(plasmaVault.balanceOf(feeAccount), expectedShares, "fee shares minted");
        assertEq(votes.getVotes(feeAccount), votesBefore + expectedShares, "votes of the fee account grew by the mint");

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
        assertEq(
            votes.getPastTotalSupply(collectionPoint),
            plasmaVault.totalSupply(),
            "total supply checkpoint includes the mint"
        );
        assertEq(votes.getPastVotes(feeAccount, collectionPoint), expectedShares, "vote checkpoint of the fee account");
        assertGt(plasmaVault.totalSupply(), supply, "supply grew above the cap");
        assertEq(uint256(vm.load(address(plasmaVault), CAP_VALIDATION_FLAG_SLOT)), 0, "cap flag back to 0");
    }
}
