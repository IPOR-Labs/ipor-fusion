// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFuseCommon} from "../../IFuseCommon.sol";
import {IporMath} from "../../../libraries/math/IporMath.sol";
import {ICrosschainExecutor} from "../../../crosschain/interfaces/ICrosschainExecutor.sol";
import {ICcipCrosschainExecutor} from "../../../crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {ICrosschainExecutorMetadata} from "../../../crosschain/common/ICrosschainExecutorMetadata.sol";
import {CrosschainTransportKind} from "../../../crosschain/common/CrosschainTransportTypes.sol";
import {CrosschainSubstrateLib} from "../lib/CrosschainSubstrateLib.sol";
import {CrosschainRecoveryLib} from "../lib/CrosschainRecoveryLib.sol";

struct CcipSupplyFuseEnterData {
    address executor;
    address asset;
    uint256 dstChainId;
    uint256 amount;
    uint256 maxFee;
    address feeToken;
    /// @dev 0 = route policy; above policy is clamped; below policy reverts (`CcipGasLimitBelowRoutePolicy`).
    uint256 gasLimit;
    /// @dev Floor on the tokens the destination must receive, in local asset decimals; 0 = no floor, and it must
    ///      not exceed the amount actually sent (`amount` after the vault-balance clamp and dust floor; the executor
    ///      reverts `InvalidMinDelivered`). A CCIP token pool may charge a fee or apply a haircut, so the
    ///      destination can receive less than was sent. The floor is NOT a revert guard:
    ///      the tokens have already left when the pool delivers, so a miss only surfaces at settlement as
    ///      `SettledBelowMinDelivered` (and the shortfall as `SettledCreditShortfall`); the value that arrived is
    ///      booked and the chain is not blocked. Trust assumption: the pool owner is a trusted external party who
    ///      can change the pool fee; this field lets the atomist detect that, it does not constrain it.
    uint256 minDelivered;
}

struct CcipSupplyFuseExitData {
    address executor;
    uint256 dstChainId;
    uint256 amount;
    /// @dev Checked by the dispatcher against the GROSS amount it sends, before any CCIP token-pool fee on the
    ///      return leg; the net tokens received can be lower (`ReturnFinalized.sentSD - received` is the fee).
    uint256 minReturn;
    uint256 maxFee;
    address feeToken;
    /// @dev 0 = route policy; above policy is clamped; below policy reverts (`CcipGasLimitBelowRoutePolicy`).
    uint256 gasLimit;
}

/// @notice Local-to-shared decimals ratio of the executor (`10 ** (localDecimals - sharedDecimals)`).
interface ICcipConversionRate {
    function DECIMAL_CONVERSION_RATE() external view returns (uint256);
}

contract CcipCrosschainSupplyFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    error CcipSupplyFuseExecutorManagerMismatch(address executor, address manager);
    error CcipSupplyFuseWrongTransport(address executor);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    /// @param version The address of this fuse contract version.
    /// @param minDelivered The delivered-amount floor the keeper set for this send, in local `asset` decimals
    ///        (`0` = no floor), emitted so monitoring can check the floor before it is missed (IL-8581).
    event CcipSupplyFuseEnter(
        address version, address executor, uint256 chainId, uint256 amount, uint256 minDelivered
    );
    /// @param version The address of this fuse contract version.
    event CcipSupplyFuseExit(address version, address executor, uint256 chainId, uint256 amount);

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    function enter(CcipSupplyFuseEnterData calldata data_) external {
        if (data_.amount == 0) return;
        _validate(data_.executor);
        CrosschainRecoveryLib.markNewExposure();
        ICrosschainExecutor(data_.executor).getBalance();
        CrosschainSubstrateLib.validateExecutorHandlesAsset(data_.executor, data_.asset);
        uint256 amount = IporMath.min(data_.amount, IERC20(data_.asset).balanceOf(address(this)));
        // The executor rejects a send that is not an exact multiple of the shared-decimals unit (`AmountHasDust`).
        // The clamp above makes that reachable by anyone who donates 1 wei to the vault, so floor the amount here;
        // the sub-unit remainder stays in the vault.
        amount -= amount % ICcipConversionRate(data_.executor).DECIMAL_CONVERSION_RATE();
        if (amount == 0) return;
        IERC20(data_.asset).safeTransfer(data_.executor, amount);
        ICcipCrosschainExecutor(data_.executor)
            .sendAssetToDispatcher(
                data_.dstChainId, amount, data_.maxFee, data_.feeToken, data_.gasLimit, data_.minDelivered
            );
        emit CcipSupplyFuseEnter(VERSION, data_.executor, data_.dstChainId, amount, data_.minDelivered);
    }

    function exit(CcipSupplyFuseExitData calldata data_) external {
        if (data_.amount == 0) return;
        _validate(data_.executor);
        CrosschainRecoveryLib.markRecovery(MARKET_ID, data_.executor);
        ICcipCrosschainExecutor(data_.executor)
            .requestAssetsFromDispatcher(
                data_.dstChainId, data_.amount, data_.minReturn, data_.maxFee, data_.feeToken, data_.gasLimit
            );
        emit CcipSupplyFuseExit(VERSION, data_.executor, data_.dstChainId, data_.amount);
    }

    function _validate(address executor_) private view {
        CrosschainSubstrateLib.validateExecutorGranted(MARKET_ID, executor_);
        address manager = ICrosschainExecutor(executor_).MANAGER();
        if (manager != address(this)) revert CcipSupplyFuseExecutorManagerMismatch(executor_, manager);
        if (ICrosschainExecutorMetadata(executor_).transportKind() != CrosschainTransportKind.CHAINLINK_CCIP) {
            revert CcipSupplyFuseWrongTransport(executor_);
        }
    }
}
