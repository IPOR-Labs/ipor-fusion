// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import {Roles} from "../../libraries/Roles.sol";

import {IFuseCommon} from "../IFuseCommon.sol";
import {IExternalStateExecutor} from "./IExternalStateExecutor.sol";
import {ExternalStateErrors} from "./errors/ExternalStateErrors.sol";
import {ExternalStateExecutorStorageLib} from "./lib/ExternalStateExecutorStorageLib.sol";

/// @notice Data carried inside an atomist-signed unpause request.
/// @param confirmedTotalBalance Total balance (underlying units) the atomist signed off on.
/// @param nonce Unique, strictly-increasing nonce chosen off-chain.
/// @param expirationTime Unix timestamp after which the signature is rejected.
/// @param signature Concatenated (r, s, v) ECDSA signature over the canonical digest.
struct ExternalStateUnpauseData {
    uint256 confirmedTotalBalance;
    uint256 nonce;
    uint256 expirationTime;
    bytes signature;
}

/// @title ExternalStateUnpauseFuse
/// @notice Clears the ExternalState pause flag after verifying an atomist ECDSA signature that endorses the
///         current balance snapshot. Does not move funds.
/// @dev Runs via delegatecall from PlasmaVault. Uses a plain `keccak256(abi.encodePacked(...))` digest
///      (no EIP-712) to match `ContextManager._verifySignature` and keep the signing surface simple.
///      Replay protection is provided by binding `(address(this), MARKET_ID, chainId, nonce)` and by
///      consuming the nonce from `ExternalStateExecutorStorageLib`.
/// @author IPOR Labs
contract ExternalStateUnpauseFuse is IFuseCommon {
    /// @notice Deployment address captured at construction.
    address public immutable VERSION;

    /// @notice Market identifier bound to this fuse instance.
    uint256 public immutable override MARKET_ID;

    /// @notice Emitted when an atomist successfully clears the pause flag.
    event ExternalStateUnpaused(address signer, uint256 confirmedTotalBalance, uint256 nonce);

    /// @param marketId_ Market identifier this fuse serves (must be non-zero).
    constructor(uint256 marketId_) {
        if (marketId_ == 0) revert ExternalStateErrors.ExternalStateZeroMarketId();
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Verify the atomist signature, match the confirmed balance against the executor's live
    ///         balance, and clear the ExternalState pause flag.
    /// @param data_ Signed unpause payload.
    function unpause(ExternalStateUnpauseData calldata data_) external {
        address executor = ExternalStateExecutorStorageLib.getExecutor();
        if (executor == address(0)) revert ExternalStateErrors.ExternalStateUnpauseNotPaused();
        if (!ExternalStateExecutorStorageLib.getPaused()) revert ExternalStateErrors.ExternalStateUnpauseNotPaused();
        if (block.timestamp > data_.expirationTime) revert ExternalStateErrors.ExternalStateUnpauseSignatureExpired();
        if (ExternalStateExecutorStorageLib.isUnpauseNonceUsed(data_.nonce)) {
            revert ExternalStateErrors.ExternalStateUnpauseSignatureReplay(data_.nonce);
        }

        bytes32 digest = keccak256(
            abi.encodePacked(
                address(this), MARKET_ID, data_.confirmedTotalBalance, data_.nonce, data_.expirationTime, block.chainid
            )
        );
        // ECDSA.recover rejects high-s signatures (EIP-2) and malformed inputs by reverting.
        address signer = ECDSA.recover(digest, data_.signature);

        // authority() is on PlasmaVault's own ABI (AccessManagedUpgradeable), so this self-call
        // resolves without touching the fallback — getAccessManagerAddress() lives only on
        // PlasmaVaultGovernance behind the fallback, which rejects callbacks during execute().
        address accessManager = IAccessManaged(address(this)).authority();
        (bool isMember,) = IAccessManager(accessManager).hasRole(Roles.ATOMIST_ROLE, signer);
        if (!isMember) revert ExternalStateErrors.ExternalStateUnpauseSignerNotAtomist(signer);

        (uint256 currentTotal,,) = IExternalStateExecutor(executor).getBalanceFuseSnapshot();
        if (currentTotal != data_.confirmedTotalBalance) {
            revert ExternalStateErrors.ExternalStateUnpauseBalanceMismatch(data_.confirmedTotalBalance, currentTotal);
        }

        ExternalStateExecutorStorageLib.markUnpauseNonceUsed(data_.nonce);
        ExternalStateExecutorStorageLib.setPaused(false);

        emit ExternalStateUnpaused(signer, data_.confirmedTotalBalance, data_.nonce);
    }
}
