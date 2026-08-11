// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {PlasmaVaultConfigLib} from "../../../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {ExternalStateExecutorStorageLib} from "../../../../../contracts/fuses/external_state/lib/ExternalStateExecutorStorageLib.sol";
import {ExternalStateSubstrateLib} from "../../../../../contracts/fuses/external_state/lib/ExternalStateSubstrateLib.sol";
import {IExternalStateExecutor} from "../../../../../contracts/fuses/external_state/IExternalStateExecutor.sol";
import {ExternalStateExecutor} from "../../../../../contracts/fuses/external_state/ExternalStateExecutor.sol";
import {ExternalStateErrors} from "../../../../../contracts/fuses/external_state/errors/ExternalStateErrors.sol";
import {IporFusionMarkets} from "../../../../../contracts/libraries/IporFusionMarkets.sol";

/// @title ExternalStateExecutorStorageLibHarness
/// @notice Harness that lets tests call the internal library methods. The harness itself serves
///         as the "vault" because the lib uses `address(this)` as the vault reference for
///         `getOrCreateExecutor`.
contract ExternalStateExecutorStorageLibHarness {
    function getExecutor() external view returns (address) {
        return ExternalStateExecutorStorageLib.getExecutor();
    }

    function setExecutor(address e_) external {
        ExternalStateExecutorStorageLib.setExecutor(e_);
    }

    function getOrCreateExecutor(uint256 m_) external returns (address) {
        return ExternalStateExecutorStorageLib.getOrCreateExecutor(m_);
    }

    function getLastTotalBalance() external view returns (uint256) {
        return ExternalStateExecutorStorageLib.getLastTotalBalance();
    }

    function setLastTotalBalance(uint256 v_) external {
        ExternalStateExecutorStorageLib.setLastTotalBalance(v_);
    }

    function getLastCheckedCustodianTimestamp() external view returns (uint256) {
        return ExternalStateExecutorStorageLib.getLastCheckedCustodianTimestamp();
    }

    function setLastCheckedCustodianTimestamp(uint256 v_) external {
        ExternalStateExecutorStorageLib.setLastCheckedCustodianTimestamp(v_);
    }

    function getPaused() external view returns (bool) {
        return ExternalStateExecutorStorageLib.getPaused();
    }

    function setPaused(bool v_) external {
        ExternalStateExecutorStorageLib.setPaused(v_);
    }

    function isUnpauseNonceUsed(uint256 n_) external view returns (bool) {
        return ExternalStateExecutorStorageLib.isUnpauseNonceUsed(n_);
    }

    function markUnpauseNonceUsed(uint256 n_) external {
        ExternalStateExecutorStorageLib.markUnpauseNonceUsed(n_);
    }

    /// @notice Returns the raw ERC-7201 slot contents at the known offset for `executor`.
    function readExecutorSlot() external view returns (bytes32 raw) {
        // ERC-7201 slot: getExternalStateStorage().executor at offset 0
        bytes32 slot = 0x1781023874512ec457c16827ad102f41a5c5ce1cd7ba8aa8fcd2da52541d8a00;
        assembly {
            raw := sload(slot)
        }
    }

    /// @notice Grant substrates for the harness's market id (only needed by createExecutor tests).
    function grantMarketSubstrates(uint256 m_, bytes32[] memory subs_) external {
        PlasmaVaultConfigLib.grantMarketSubstrates(m_, subs_);
    }

    function getMarketSubstrates(uint256 m_) external view returns (bytes32[] memory) {
        return PlasmaVaultConfigLib.getMarketSubstrates(m_);
    }
}

/// @title ExternalStateExecutorStorageLibTest
/// @notice 12 tests covering storage lib getters, setters, factory, and ERC-7201 slot derivation.
contract ExternalStateExecutorStorageLibTest is Test {
    ExternalStateExecutorStorageLibHarness internal h;
    uint256 internal constant MARKET_ID = IporFusionMarkets.EXTERNAL_STATE;

    function setUp() public {
        h = new ExternalStateExecutorStorageLibHarness();
    }

    // ---------- 2.1 ----------
    function test_getExecutor_returnsZeroInitially() public view {
        assertEq(h.getExecutor(), address(0));
    }

    // ---------- 2.2 ----------
    function test_setExecutor_updatesStorage() public {
        address manual = address(0xBEEF);
        h.setExecutor(manual);
        assertEq(h.getExecutor(), manual);
    }

    // ---------- 2.3 ----------
    function test_getOrCreateExecutor_deploysWhenZero() public {
        _seedMandatorySubstrates();
        address e = h.getOrCreateExecutor(MARKET_ID);
        assertTrue(e != address(0));
        assertEq(h.getExecutor(), e);
        assertEq(IExternalStateExecutor(e).VAULT(), address(h));
        assertEq(IExternalStateExecutor(e).MARKET_ID(), MARKET_ID);
    }

    // ---------- 2.4 ----------
    function test_getOrCreateExecutor_returnsExistingWhenSet() public {
        _seedMandatorySubstrates();
        address e1 = h.getOrCreateExecutor(MARKET_ID);
        address e2 = h.getOrCreateExecutor(MARKET_ID);
        assertEq(e1, e2);
    }

    // ---------- 2.5 ----------
    function test_getOrCreateExecutor_appliesSubstratesOnNewDeploy() public {
        // Seed STALENESS_MAX + BIG_CHANGE_BPS singletons and assert the deployed executor cached them.
        uint256 stalenessValue = 12345;
        bytes32[] memory subs = new bytes32[](2);
        subs[0] = ExternalStateSubstrateLib.encodeStalenessMaxSubstrate(stalenessValue);
        subs[1] = ExternalStateSubstrateLib.encodeBigChangeBpsSubstrate(500);
        h.grantMarketSubstrates(MARKET_ID, subs);
        address e = h.getOrCreateExecutor(MARKET_ID);
        assertEq(IExternalStateExecutor(e).stalenessMax(), stalenessValue);
    }

    // ---------- 2.6 ----------
    function test_getLastTotalBalance_setterRoundtrip() public {
        h.setLastTotalBalance(987654321);
        assertEq(h.getLastTotalBalance(), 987654321);
    }

    // ---------- 2.7 ----------
    function test_getLastCheckedCustodianTimestamp_setterRoundtrip() public {
        h.setLastCheckedCustodianTimestamp(1_700_000_000);
        assertEq(h.getLastCheckedCustodianTimestamp(), 1_700_000_000);
    }

    // ---------- 2.8 ----------
    function test_getPaused_setterRoundtrip() public {
        assertFalse(h.getPaused());
        h.setPaused(true);
        assertTrue(h.getPaused());
        h.setPaused(false);
        assertFalse(h.getPaused());
    }

    // ---------- 2.9 ----------
    function test_isUnpauseNonceUsed_falseInitially() public view {
        assertFalse(h.isUnpauseNonceUsed(0));
        assertFalse(h.isUnpauseNonceUsed(type(uint256).max));
    }

    // ---------- 2.10 ----------
    function test_markUnpauseNonceUsed_flipsToTrue() public {
        h.markUnpauseNonceUsed(42);
        assertTrue(h.isUnpauseNonceUsed(42));
        // Other nonces remain false
        assertFalse(h.isUnpauseNonceUsed(43));
    }

    // ---------- 2.11 ----------
    function test_storageSlot_matchesExpectedErc7201Formula() public {
        // Slot derivation: keccak256(abi.encode(uint256(keccak256("io.ipor.externalState.Executor")) - 1)) & ~0xff
        bytes32 step1 = keccak256("io.ipor.externalState.Executor");
        bytes32 step2 = keccak256(abi.encode(uint256(step1) - 1));
        bytes32 expected = step2 & bytes32(type(uint256).max ^ uint256(0xff));

        // Write a sentinel into the executor slot and read the ERC-7201 slot via assembly
        address sentinel = address(0xA11CE);
        h.setExecutor(sentinel);
        bytes32 raw = h.readExecutorSlot();
        assertEq(uint160(uint256(raw)), uint160(sentinel));

        // Additionally verify the hardcoded slot matches the derivation.
        bytes32 hardcoded = 0x1781023874512ec457c16827ad102f41a5c5ce1cd7ba8aa8fcd2da52541d8a00;
        assertEq(expected, hardcoded);
    }

    // ---------- 2.12 ----------
    function test_distinctFieldsDoNotAlias() public {
        // Writing different fields must not cross-contaminate storage.
        h.setExecutor(address(0x1));
        h.setLastTotalBalance(100);
        h.setLastCheckedCustodianTimestamp(200);
        h.setPaused(true);
        h.markUnpauseNonceUsed(300);

        assertEq(h.getExecutor(), address(0x1));
        assertEq(h.getLastTotalBalance(), 100);
        assertEq(h.getLastCheckedCustodianTimestamp(), 200);
        assertTrue(h.getPaused());
        assertTrue(h.isUnpauseNonceUsed(300));
    }

    // ---------- multi-market guard ----------
    function test_getOrCreateExecutor_revertsOnMarketIdMismatch() public {
        _seedMandatorySubstrates();
        h.getOrCreateExecutor(MARKET_ID);
        vm.expectRevert(
            abi.encodeWithSelector(ExternalStateErrors.ExternalStateMultipleMarketsNotSupported.selector, MARKET_ID, MARKET_ID + 1)
        );
        h.getOrCreateExecutor(MARKET_ID + 1);
    }

    // ---------- helpers ----------
    function _seedMandatorySubstrates() internal {
        bytes32[] memory subs = new bytes32[](2);
        subs[0] = ExternalStateSubstrateLib.encodeStalenessMaxSubstrate(3600);
        subs[1] = ExternalStateSubstrateLib.encodeBigChangeBpsSubstrate(500);
        h.grantMarketSubstrates(MARKET_ID, subs);
    }
}
