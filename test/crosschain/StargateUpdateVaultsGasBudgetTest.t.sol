// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;


import {StargateTwoSidedBase} from "./StargateTwoSidedBase.sol";
import {CrosschainConstants} from "../../contracts/crosschain/lib/CrosschainConstants.sol";

import {MockRemoteVault} from "./mocks/MockRemoteVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title StargateUpdateVaultsGasBudgetTest
/// @notice IL-8617 (TP-M-39): measures the destination gas of a Stargate `UPDATE_VAULTS` `lzReceive` (decode, persist
///         the command bytes, install the allowlist, validate each vault, quote + send the ACK) for the allowed
///         maximum of vaults, and pins the result under the recommended command-lane receive option.
/// @dev Gas is read with `gasleft()` around the real endpoint delivery into `lzReceive`, with the dispatcher and every
///      vault cooled first (`vm.cool`) so each access pays the EIP-2929 cold price a real inbound call pays. The mock
///      endpoint adds a small constant (< 10k) on top of what the production endpoint spends before `lzReceive`.
///      `UPDATE_VAULTS` never prices vaults (no `TrackedVaultPricingLib` read), so the IL-8602 per-vault 200k read cap
///      does not apply to it; the ACK carries no valuation either (a `CommandAck` of fixed size).
contract StargateUpdateVaultsGasBudgetTest is StargateTwoSidedBase {
    /// @dev The reference command-lane receive option the deployment guidance recommends (IL-8617).
    uint256 internal constant RECOMMENDED_OPTION_GAS = 4_000_000;
    /// @dev The previous reference option; the max-size update does not fit it.
    uint256 internal constant LEGACY_OPTION_GAS = 2_000_000;

    MockRemoteVault[] internal pool_;

    function setUp() public {
        _twoSidedSetUp();
        _bringUpBothSides();
    }

    function testShouldMeasureUpdateVaultsGasForGrowingVaultCounts() public {
        uint256[6] memory counts = [uint256(0), 1, 8, 16, 24, 32];
        emit log_string("UPDATE_VAULTS dispatcher lzReceive gas (fresh install over an empty allowlist)");
        uint256 maxGas;
        for (uint256 i; i < counts.length; ++i) {
            // Reset to an empty allowlist first so every row is a fresh install.
            _clearAllowlist();
            address[] memory vaults = _vaults(counts[i], 0);
            (uint256 gasUsed,) = _measureUpdate(vaults);
            emit log_named_uint("  N", counts[i]);
            emit log_named_uint("    gas", gasUsed);
            assertEq(dispatcher.getAllowedVaults().length, counts[i], "installed");
            if (counts[i] == CrosschainConstants.MAX_ALLOWED_VAULTS) maxGas = gasUsed;
        }
        _assertBudget(maxGas, "fresh N=32");
    }

    function testShouldMeasureReplaceAndRemovalAtTheCap() public {
        _clearAllowlist();
        (uint256 freshGas,) = _measureUpdate(_vaults(32, 0));

        // Replace 32 -> 32 different vaults: clears 32 flags, deletes the array, installs 32 new ones.
        (uint256 replaceGas,) = _measureUpdate(_vaults(32, 32));
        assertEq(dispatcher.getAllowedVaults().length, 32, "replaced");

        // Removal 32 -> 0.
        (uint256 removeGas,) = _measureUpdate(new address[](0));
        assertEq(dispatcher.getAllowedVaults().length, 0, "removed");

        emit log_named_uint("fresh 0 -> 32", freshGas);
        emit log_named_uint("replace 32 -> 32", replaceGas);
        emit log_named_uint("remove 32 -> 0", removeGas);

        _assertBudget(freshGas, "fresh");
        _assertBudget(replaceGas, "replace");
        _assertBudget(removeGas, "remove");
    }

    /// @notice The ACK is the executor-side receipt of the same command; its cost is reported for completeness.
    function testShouldMeasureExecutorAckGas() public {
        _clearAllowlist();
        address[] memory vaults = _vaults(32, 0);
        (, uint256 ackIndexGas) = _measureUpdate(vaults);
        emit log_named_uint("executor ACK lzReceive gas", ackIndexGas);
        assertLt(ackIndexGas, 1_000_000, "ACK handling is small and independent of the vault count");
    }

    /// @dev The legacy 2M option is below the measured maximum: documents why the reference option moved.
    function testShouldExceedLegacyTwoMillionOptionAtTheCap() public {
        _clearAllowlist();
        (uint256 gasUsed,) = _measureUpdate(_vaults(32, 0));
        assertGt(gasUsed, LEGACY_OPTION_GAS, "32 vaults no longer fit the legacy 2M receive option");
    }

    // ------------------------------------------------------------------

    /// @dev Recommended option must leave >= 25% headroom over the measurement (gas * 1.25 <= option).
    function _assertBudget(uint256 gasUsed_, string memory what_) private pure {
        assertLe((gasUsed_ * 125) / 100, RECOMMENDED_OPTION_GAS, what_);
    }

    function _clearAllowlist() private {
        if (dispatcher.getAllowedVaults().length == 0) return;
        _measureUpdate(new address[](0));
    }

    /// @dev Send one UPDATE_VAULTS from the executor and deliver it (cold) into the dispatcher; then deliver the ACK.
    function _measureUpdate(address[] memory vaults_) private returns (uint256 dispatcherGas, uint256 ackGas) {
        vm.prank(manager);
        executor.updatePlasmaVaults(REMOTE_CHAIN, vaults_);
        uint256 idx = _lastSentIndex();
        relayCursor = idx;

        vm.cool(address(dispatcher));
        for (uint256 i; i < vaults_.length; ++i) {
            vm.cool(vaults_[i]);
        }
        uint256 before_ = gasleft();
        _relayAt(idx);
        dispatcherGas = before_ - gasleft();
        relayCursor = idx + 1;

        uint256 ackIdx = _lastSentIndex();
        vm.cool(address(executor));
        before_ = gasleft();
        _relayAt(ackIdx);
        ackGas = before_ - gasleft();
        relayCursor = ackIdx + 1;
        assertFalse(_commandSlotActive(), "slot freed by the ACK");
    }

    /// @dev `count_` vaults taken from the lazily grown pool starting at `offset_`.
    function _vaults(uint256 count_, uint256 offset_) private returns (address[] memory out) {
        while (pool_.length < offset_ + count_) {
            pool_.push(new MockRemoteVault(IERC20(address(usdc)), "Remote Vault", "RVLT"));
        }
        out = new address[](count_);
        for (uint256 i; i < count_; ++i) {
            out[i] = address(pool_[offset_ + i]);
        }
    }
}
