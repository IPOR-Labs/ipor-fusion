// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

import {IPlasmaVaultGovernance} from "../../interfaces/IPlasmaVaultGovernance.sol";
import {Roles} from "../../libraries/Roles.sol";

import {IFuseCommon} from "../IFuseCommon.sol";
import {IRWAExecutor} from "./IRWAExecutor.sol";
import {RWAErrors} from "./errors/RWAErrors.sol";
import {RWAExecutorStorageLib} from "./lib/RWAExecutorStorageLib.sol";

/// @notice Data carried inside an atomist-signed unpause request.
/// @param confirmedTotalBalance Total balance (underlying units) the atomist signed off on.
/// @param nonce Unique, strictly-increasing nonce chosen off-chain.
/// @param expirationTime Unix timestamp after which the signature is rejected.
/// @param signature Concatenated (r, s, v) ECDSA signature over the canonical digest.
struct RWAUnpauseData {
    uint256 confirmedTotalBalance;
    uint256 nonce;
    uint256 expirationTime;
    bytes signature;
}

/// @title RWAUnpauseFuse
/// @notice Clears the RWA pause flag after verifying an atomist ECDSA signature that endorses the
///         current balance snapshot. Does not move funds.
/// @dev Runs via delegatecall from PlasmaVault. Uses a plain `keccak256(abi.encodePacked(...))` digest
///      (no EIP-712) to match `ContextManager._verifySignature` and keep the signing surface simple.
///      Replay protection is provided by binding `(address(this), MARKET_ID, chainId, nonce)` and by
///      consuming the nonce from `RWAExecutorStorageLib`.
/// @author IPOR Labs
contract RWAUnpauseFuse is IFuseCommon {
    /// @notice Deployment address captured at construction.
    address public immutable VERSION;

    /// @notice Market identifier bound to this fuse instance.
    uint256 public immutable override MARKET_ID;

    /// @notice Emitted when an atomist successfully clears the pause flag.
    event RWAUnpaused(address signer, uint256 confirmedTotalBalance, uint256 nonce);

    /// @param marketId_ Market identifier this fuse serves (must be non-zero).
    constructor(uint256 marketId_) {
        if (marketId_ == 0) revert RWAErrors.RWAZeroMarketId();
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Verify the atomist signature, match the confirmed balance against the executor's live
    ///         balance, and clear the RWA pause flag.
    /// @param data_ Signed unpause payload.
    function unpause(RWAUnpauseData calldata data_) external {
        address executor = RWAExecutorStorageLib.getExecutor();
        if (executor == address(0)) revert RWAErrors.RWAUnpauseNotPaused();
        if (!RWAExecutorStorageLib.getPaused()) revert RWAErrors.RWAUnpauseNotPaused();
        if (block.timestamp > data_.expirationTime) revert RWAErrors.RWAUnpauseSignatureExpired();
        if (RWAExecutorStorageLib.isUnpauseNonceUsed(data_.nonce)) {
            revert RWAErrors.RWAUnpauseSignatureReplay(data_.nonce);
        }

        bytes32 digest = keccak256(
            abi.encodePacked(
                address(this), MARKET_ID, data_.confirmedTotalBalance, data_.nonce, data_.expirationTime, block.chainid
            )
        );
        // ECDSA.recover rejects high-s signatures (EIP-2) and malformed inputs by reverting.
        address signer = ECDSA.recover(digest, data_.signature);

        address accessManager = IPlasmaVaultGovernance(address(this)).getAccessManagerAddress();
        (bool isMember,) = IAccessManager(accessManager).hasRole(Roles.ATOMIST_ROLE, signer);
        if (!isMember) revert RWAErrors.RWAUnpauseSignerNotAtomist(signer);

        (uint256 currentTotal,,) = IRWAExecutor(executor).getBalanceFuseSnapshot();
        if (currentTotal != data_.confirmedTotalBalance) {
            revert RWAErrors.RWAUnpauseBalanceMismatch(data_.confirmedTotalBalance, currentTotal);
        }

        RWAExecutorStorageLib.markUnpauseNonceUsed(data_.nonce);
        RWAExecutorStorageLib.setPaused(false);

        emit RWAUnpaused(signer, data_.confirmedTotalBalance, data_.nonce);
    }
}
