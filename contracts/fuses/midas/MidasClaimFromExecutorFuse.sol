// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFuseCommon} from "../IFuseCommon.sol";
import {MidasExecutorStorageLib} from "./lib/MidasExecutorStorageLib.sol";
import {MidasExecutor} from "./MidasExecutor.sol";
import {MidasSubstrateLib, MidasSubstrate, MidasSubstrateType} from "./lib/MidasSubstrateLib.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {Errors} from "../../libraries/errors/Errors.sol";

/// @notice Data structure for entering MidasClaimFromExecutorFuse
struct MidasClaimFromExecutorFuseEnterData {
    /// @dev token to claim from executor (mToken after deposit approval, or USDC after redemption approval)
    address token;
}

/// @title MidasClaimFromExecutorFuse
/// @notice Fuse for claiming settled assets from MidasExecutor back to PlasmaVault
/// @dev Executes in PlasmaVault storage context via delegatecall. MUST NOT contain storage variables.
///      The keeper calls this fuse to pull tokens from the executor after Midas admin approves
///      a deposit (mTokens) or redemption (underlying tokens).
contract MidasClaimFromExecutorFuse is IFuseCommon {
    event MidasClaimFromExecutorFuseClaimed(address version, address token, uint256 amount);
    event MidasClaimFromExecutorFuseExecutorCreated(address version, address executor);

    error MidasClaimFromExecutorFuseExecutorNotDeployed();
    error MidasClaimFromExecutorFuseTokenNotGranted(address token);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        if (marketId_ == 0) revert Errors.WrongValue();
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Claim all tokens of a given type from MidasExecutor to PlasmaVault
    /// @dev Token must be a granted mToken or asset in market substrates
    /// @param data_ The enter data containing the token address to claim
    function enter(MidasClaimFromExecutorFuseEnterData memory data_) external {
        bool isGranted = PlasmaVaultConfigLib.isMarketSubstrateGranted(
            MARKET_ID,
            MidasSubstrateLib.substrateToBytes32(
                MidasSubstrate({substrateType: MidasSubstrateType.M_TOKEN, substrateAddress: data_.token})
            )
        ) || PlasmaVaultConfigLib.isMarketSubstrateGranted(
            MARKET_ID,
            MidasSubstrateLib.substrateToBytes32(
                MidasSubstrate({substrateType: MidasSubstrateType.ASSET, substrateAddress: data_.token})
            )
        );

        if (!isGranted) {
            revert MidasClaimFromExecutorFuseTokenNotGranted(data_.token);
        }

        address executor = MidasExecutorStorageLib.getExecutor();

        if (executor == address(0)) {
            revert MidasClaimFromExecutorFuseExecutorNotDeployed();
        }

        uint256 amount = MidasExecutor(executor).claimAssets(data_.token);

        emit MidasClaimFromExecutorFuseClaimed(VERSION, data_.token, amount);
    }

    /// @notice Deploy the MidasExecutor if it doesn't exist yet
    /// @dev Can be called by alpha to pre-deploy the executor before any deposit/redemption requests.
    ///      If executor already exists, emits event with existing address (no-op deployment).
    function deployExecutor() external {
        address executor = MidasExecutorStorageLib.getOrCreateExecutor(address(this));

        emit MidasClaimFromExecutorFuseExecutorCreated(VERSION, executor);
    }
}
