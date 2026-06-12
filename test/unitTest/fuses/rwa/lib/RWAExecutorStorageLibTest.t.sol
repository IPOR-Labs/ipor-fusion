// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {PlasmaVaultConfigLib} from "../../../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {RWAExecutorStorageLib} from "../../../../../contracts/fuses/rwa/lib/RWAExecutorStorageLib.sol";
import {RWASubstrateLib} from "../../../../../contracts/fuses/rwa/lib/RWASubstrateLib.sol";
import {IRWAExecutor} from "../../../../../contracts/fuses/rwa/IRWAExecutor.sol";
import {RWAExecutor} from "../../../../../contracts/fuses/rwa/RWAExecutor.sol";
import {RWAErrors} from "../../../../../contracts/fuses/rwa/errors/RWAErrors.sol";
import {IporFusionMarkets} from "../../../../../contracts/libraries/IporFusionMarkets.sol";

/// @title RWAExecutorStorageLibHarness
/// @notice Harness that lets tests call the internal library methods. The harness itself serves
///         as the "vault" because the lib uses `address(this)` as the vault reference for
///         `getOrCreateExecutor`.
contract RWAExecutorStorageLibHarness {
    function getExecutor() external view returns (address) {
        return RWAExecutorStorageLib.getExecutor();
    }

    function setExecutor(address e_) external {
        RWAExecutorStorageLib.setExecutor(e_);
    }

    function getOrCreateExecutor(uint256 m_) external returns (address) {
        return RWAExecutorStorageLib.getOrCreateExecutor(m_);
    }

    function getLastTotalBalance() external view returns (uint256) {
        return RWAExecutorStorageLib.getLastTotalBalance();
    }

    function setLastTotalBalance(uint256 v_) external {
        RWAExecutorStorageLib.setLastTotalBalance(v_);
    }

    function getLastCheckedCustodianTimestamp() external view returns (uint256) {
        return RWAExecutorStorageLib.getLastCheckedCustodianTimestamp();
    }

    function setLastCheckedCustodianTimestamp(uint256 v_) external {
        RWAExecutorStorageLib.setLastCheckedCustodianTimestamp(v_);
    }

    function getPaused() external view returns (bool) {
        return RWAExecutorStorageLib.getPaused();
    }

    function setPaused(bool v_) external {
        RWAExecutorStorageLib.setPaused(v_);
    }

    function isUnpauseNonceUsed(uint256 n_) external view returns (bool) {
        return RWAExecutorStorageLib.isUnpauseNonceUsed(n_);
    }

    function markUnpauseNonceUsed(uint256 n_) external {
        RWAExecutorStorageLib.markUnpauseNonceUsed(n_);
    }

    /// @notice Returns the raw ERC-7201 slot contents at the known offset for `executor`.
    function readExecutorSlot() external view returns (bytes32 raw) {
        // ERC-7201 slot: getRwaStorage().executor at offset 0
        bytes32 slot = 0x2c33642f9f95a2ae96c65138627f6a55480cec20290d678b3efcc2db4caa9400;
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

/// @title RWAExecutorStorageLibTest
/// @notice 12 tests covering storage lib getters, setters, factory, and ERC-7201 slot derivation.
contract RWAExecutorStorageLibTest is Test {
    RWAExecutorStorageLibHarness internal h;
    uint256 internal constant MARKET_ID = IporFusionMarkets.RWA;

    function setUp() public {
        h = new RWAExecutorStorageLibHarness();
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
        assertEq(IRWAExecutor(e).VAULT(), address(h));
        assertEq(IRWAExecutor(e).MARKET_ID(), MARKET_ID);
    }

    // ---------- 2.4 ----------
    function test_getOrCreateExecutor_returnsExistingWhenSet() public {
        _seedMandatorySubstrates();
        address e1 = h.getOrCreateExecutor(MARKET_ID);
        address e2 = h.getOrCreateExecutor(MARKET_ID);
        assertEq(e1, e2);
    }

    // ---------- 2.5 ----------
    function test_getOrCreateExecutor_callsSyncSubstratesOnNewDeploy() public {
        // Seed STALENESS_MAX + BIG_CHANGE_BPS singletons and assert the deployed executor cached them.
        uint256 stalenessValue = 12345;
        bytes32[] memory subs = new bytes32[](2);
        subs[0] = RWASubstrateLib.encodeStalenessMaxSubstrate(stalenessValue);
        subs[1] = RWASubstrateLib.encodeBigChangeBpsSubstrate(500);
        h.grantMarketSubstrates(MARKET_ID, subs);
        address e = h.getOrCreateExecutor(MARKET_ID);
        assertEq(IRWAExecutor(e).stalenessMax(), stalenessValue);
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
        // Slot derivation: keccak256(abi.encode(uint256(keccak256("io.ipor.rwa.Executor")) - 1)) & ~0xff
        bytes32 step1 = keccak256("io.ipor.rwa.Executor");
        bytes32 step2 = keccak256(abi.encode(uint256(step1) - 1));
        bytes32 expected = step2 & bytes32(type(uint256).max ^ uint256(0xff));

        // Write a sentinel into the executor slot and read the ERC-7201 slot via assembly
        address sentinel = address(0xA11CE);
        h.setExecutor(sentinel);
        bytes32 raw = h.readExecutorSlot();
        assertEq(uint160(uint256(raw)), uint160(sentinel));

        // Additionally verify the hardcoded slot matches the derivation.
        bytes32 hardcoded = 0x2c33642f9f95a2ae96c65138627f6a55480cec20290d678b3efcc2db4caa9400;
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
            abi.encodeWithSelector(RWAErrors.RWAMultipleMarketsNotSupported.selector, MARKET_ID, MARKET_ID + 1)
        );
        h.getOrCreateExecutor(MARKET_ID + 1);
    }

    // ---------- helpers ----------
    function _seedMandatorySubstrates() internal {
        bytes32[] memory subs = new bytes32[](2);
        subs[0] = RWASubstrateLib.encodeStalenessMaxSubstrate(3600);
        subs[1] = RWASubstrateLib.encodeBigChangeBpsSubstrate(500);
        h.grantMarketSubstrates(MARKET_ID, subs);
    }
}
