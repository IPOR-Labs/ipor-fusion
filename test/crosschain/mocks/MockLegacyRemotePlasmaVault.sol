// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UniversalReader} from "../../../contracts/universal_reader/UniversalReader.sol";
import {MockRemoteVault, MockWithdrawManager} from "./MockRemoteVault.sol";

/// @title MockLegacyRemotePlasmaVault
/// @notice Remote PlasmaVault stand-in deployed from a pre-IL-6952 base (IL-8608): the withdraw manager lives in
///         `WITHDRAW_MANAGER_LEGACY_SLOT` and the corrected ERC-7201 slot is never written. Like a real vault it
///         is a `UniversalReader`, so the dispatcher's `read(dispatcher, plasmaVaultWithdrawManager())` executes
///         in this contract's storage. Its own `redeemFromRequest` consults the legacy-slot manager.
contract MockLegacyRemotePlasmaVault is MockRemoteVault, UniversalReader {
    /// @dev Same constant as `PlasmaVaultStorageLib.WITHDRAW_MANAGER_LEGACY_SLOT` (private there).
    bytes32 internal constant LEGACY_SLOT = 0xb37e8684757599da669b8aea811ee2b3693b2582d2c730fab3f4965fa2ec3e11;

    constructor(IERC20 asset_, string memory name_, string memory symbol_) MockRemoteVault(asset_, name_, symbol_) {}

    function setLegacyWithdrawManager(address withdrawManager_) external {
        bytes32 slot = LEGACY_SLOT;
        assembly {
            sstore(slot, withdrawManager_)
        }
    }

    function legacyWithdrawManager() public view returns (address manager) {
        bytes32 slot = LEGACY_SLOT;
        assembly {
            manager := sload(slot)
        }
    }

    function transferRequestSharesFee(address from_, address to_, uint256 amount_) external {
        require(msg.sender == legacyWithdrawManager(), "not withdraw manager");
        _transfer(from_, to_, amount_);
    }

    function redeemFromRequest(uint256 shares_, address receiver_, address owner_)
        external
        override
        returns (uint256)
    {
        require(
            MockWithdrawManager(legacyWithdrawManager()).canWithdrawFromRequest(owner_, shares_),
            "cannot withdraw from request"
        );
        return redeem(shares_, receiver_, owner_);
    }
}
