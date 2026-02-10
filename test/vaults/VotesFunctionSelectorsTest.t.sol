// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IERC6372} from "@openzeppelin/contracts/interfaces/IERC6372.sol";
import {IPlasmaVaultVotesPlugin} from "../../contracts/interfaces/IPlasmaVaultVotesPlugin.sol";

/// @title VotesFunctionSelectorsTest
/// @notice Verifies that function selectors for IVotes, IERC6372, and IPlasmaVaultVotesPlugin match expected values
/// @dev These tests ensure that the selectors used in PlasmaVault._isVotesFunction are correct
contract VotesFunctionSelectorsTest is Test {
    // ============================================
    // IVotes selectors
    // ============================================

    function testIVotes_getVotes_selector() public pure {
        assertEq(IVotes.getVotes.selector, bytes4(0x9ab24eb0), "getVotes selector mismatch");
    }

    function testIVotes_getPastVotes_selector() public pure {
        assertEq(IVotes.getPastVotes.selector, bytes4(0x3a46b1a8), "getPastVotes selector mismatch");
    }

    function testIVotes_getPastTotalSupply_selector() public pure {
        assertEq(IVotes.getPastTotalSupply.selector, bytes4(0x8e539e8c), "getPastTotalSupply selector mismatch");
    }

    function testIVotes_delegates_selector() public pure {
        assertEq(IVotes.delegates.selector, bytes4(0x587cde1e), "delegates selector mismatch");
    }

    function testIVotes_delegate_selector() public pure {
        assertEq(IVotes.delegate.selector, bytes4(0x5c19a95c), "delegate selector mismatch");
    }

    function testIVotes_delegateBySig_selector() public pure {
        assertEq(IVotes.delegateBySig.selector, bytes4(0xc3cda520), "delegateBySig selector mismatch");
    }

    // ============================================
    // IERC6372 selectors
    // ============================================

    function testIERC6372_clock_selector() public pure {
        assertEq(IERC6372.clock.selector, bytes4(0x91ddadf4), "clock selector mismatch");
    }

    function testIERC6372_CLOCK_MODE_selector() public pure {
        assertEq(IERC6372.CLOCK_MODE.selector, bytes4(0x4bf5d7e9), "CLOCK_MODE selector mismatch");
    }

    // ============================================
    // IPlasmaVaultVotesPlugin selectors
    // ============================================

    function testIPlasmaVaultVotesPlugin_numCheckpoints_selector() public pure {
        assertEq(IPlasmaVaultVotesPlugin.numCheckpoints.selector, bytes4(0x6fcfff45), "numCheckpoints selector mismatch");
    }

    function testIPlasmaVaultVotesPlugin_checkpoints_selector() public pure {
        assertEq(IPlasmaVaultVotesPlugin.checkpoints.selector, bytes4(0xf1127ed8), "checkpoints selector mismatch");
    }

    function testIPlasmaVaultVotesPlugin_transferVotingUnits_selector() public pure {
        assertEq(IPlasmaVaultVotesPlugin.transferVotingUnits.selector, bytes4(0x0d207a0f), "transferVotingUnits selector mismatch");
    }

    // Note: _transferVotingUnits is internal in OpenZeppelin ERC20VotesUpgradeable,
    // so it's not callable externally and should not be checked in _isVotesFunction

    // ============================================
    // Verify keccak256 computation matches interface selectors
    // ============================================

    function testSelector_getVotes_keccak() public pure {
        bytes4 computed = bytes4(keccak256("getVotes(address)"));
        assertEq(IVotes.getVotes.selector, computed, "getVotes keccak mismatch");
    }

    function testSelector_getPastVotes_keccak() public pure {
        bytes4 computed = bytes4(keccak256("getPastVotes(address,uint256)"));
        assertEq(IVotes.getPastVotes.selector, computed, "getPastVotes keccak mismatch");
    }

    function testSelector_getPastTotalSupply_keccak() public pure {
        bytes4 computed = bytes4(keccak256("getPastTotalSupply(uint256)"));
        assertEq(IVotes.getPastTotalSupply.selector, computed, "getPastTotalSupply keccak mismatch");
    }

    function testSelector_delegates_keccak() public pure {
        bytes4 computed = bytes4(keccak256("delegates(address)"));
        assertEq(IVotes.delegates.selector, computed, "delegates keccak mismatch");
    }

    function testSelector_delegate_keccak() public pure {
        bytes4 computed = bytes4(keccak256("delegate(address)"));
        assertEq(IVotes.delegate.selector, computed, "delegate keccak mismatch");
    }

    function testSelector_delegateBySig_keccak() public pure {
        bytes4 computed = bytes4(keccak256("delegateBySig(address,uint256,uint256,uint8,bytes32,bytes32)"));
        assertEq(IVotes.delegateBySig.selector, computed, "delegateBySig keccak mismatch");
    }

    function testSelector_clock_keccak() public pure {
        bytes4 computed = bytes4(keccak256("clock()"));
        assertEq(IERC6372.clock.selector, computed, "clock keccak mismatch");
    }

    function testSelector_CLOCK_MODE_keccak() public pure {
        bytes4 computed = bytes4(keccak256("CLOCK_MODE()"));
        assertEq(IERC6372.CLOCK_MODE.selector, computed, "CLOCK_MODE keccak mismatch");
    }

    function testSelector_numCheckpoints_keccak() public pure {
        bytes4 computed = bytes4(keccak256("numCheckpoints(address)"));
        assertEq(IPlasmaVaultVotesPlugin.numCheckpoints.selector, computed, "numCheckpoints keccak mismatch");
    }

    function testSelector_checkpoints_keccak() public pure {
        bytes4 computed = bytes4(keccak256("checkpoints(address,uint32)"));
        assertEq(IPlasmaVaultVotesPlugin.checkpoints.selector, computed, "checkpoints keccak mismatch");
    }

    function testSelector_transferVotingUnits_keccak() public pure {
        bytes4 computed = bytes4(keccak256("transferVotingUnits(address,address,uint256)"));
        assertEq(IPlasmaVaultVotesPlugin.transferVotingUnits.selector, computed, "transferVotingUnits keccak mismatch");
    }
}
