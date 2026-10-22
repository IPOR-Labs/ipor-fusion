// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {CrosschainErrors} from "../../lib/CrosschainErrors.sol";

/// @notice First probe of the fee ceiling: the `FACTORY` public immutable of the executor (and of the dispatcher,
///         whose factory does not list it in `isExecutor`). The factory itself has no such getter and takes the
///         self-cap branch of `StargateNativeFeeCapLib.enforce`.
interface IStargateFactoryHolder {
    function FACTORY() external view returns (address);
}

/// @notice The two `StargateCrosschainFactory` getters the ceiling read relies on.
interface IStargateNativeFeeCapProvider {
    function isExecutor(address app_) external view returns (bool);
    function maxNativeFee(uint256 chainId_) external view returns (uint256);
}

/// @title StargateNativeFeeCapLib
/// @notice Enforces a governance-held ceiling on the LayerZero native fee a Stargate app may pay for one
///         send, read live from the app's own factory. Runs inside the delegatecalled send libraries, so
///         `address(this)` is the sending app; the app's factory is resolved through its own `FACTORY()`
///         getter (`StargateCrosschainExecutor.FACTORY`). Apps whose factory does not list them in
///         `isExecutor` — dispatchers — are not capped; their sends carry no caller options and several run
///         inside inbound handlers that must not gain revert paths. The factory itself (no `FACTORY()` getter)
///         is capped by its own `maxNativeFee(dstChainId_)`: its CREATE_DISPATCHER, ACK and NACK sends draw on
///         the native budget all tenants share, so an unset (zero) ceiling blocks them too (IL-8565 / IL-8605).
/// @dev The two probes (`FACTORY()`, `isExecutor`) are tolerant, low-level staticcalls that fall through to
///      "uncapped" on a reverting call or a wrong-length return: the factory itself has no `FACTORY()`
///      function (it takes the self-cap branch above), and a dispatcher's factory answers
///      `isExecutor(dispatcher) == false` (only executors are ever written to `isExecutor`, in
///      `StargateCrosschainFactory.createExecutor`) — or, in the two-sided test fixture, has no code at all. A
///      well-formed but non-canonical 32-byte boolean is not tolerated the same way: `abi.decode(ret, (bool))`
///      itself reverts on a value other than 0 or 1. Once both probes confirm a real, registered executor, the
///      third call (`maxNativeFee`) is a hard call: a confirmed executor whose factory lacks the getter is a
///      deployment defect and must revert loudly, not fall through.
/// @author IPOR Labs
library StargateNativeFeeCapLib {
    /// @notice Reverts `CrosschainErrors.NativeFeeTooHigh` when `nativeFee_` exceeds the ceiling the
    ///         caller's factory holds for `dstChainId_`, for apps the factory lists in `isExecutor`. The
    ///         factory itself is capped by its own `maxNativeFee(dstChainId_)` for its ticket / ACK / NACK
    ///         sends (IL-8565). A zero ceiling blocks those sends too (fail-closed by design): the inbound
    ///         CREATE_DISPATCHER is retained by LayerZero and can be retried once the ceiling is set.
    ///         A quote equal to the ceiling is admitted (`>`, not `>=`).
    /// @param dstChainId_ The destination chain id the pending send targets.
    /// @param nativeFee_ The native fee quoted for the pending send.
    function enforce(uint256 dstChainId_, uint256 nativeFee_) internal view {
        (bool ok, bytes memory ret) = address(this).staticcall(
            abi.encodeWithSelector(IStargateFactoryHolder.FACTORY.selector)
        );
        if (!ok || ret.length != 32) {
            // No `FACTORY()` getter: the caller is the factory itself (IL-8565 / IL-8605). Its own CREATE_DISPATCHER
            // / ACK / NACK sends are paid from the budget every tenant shares, so they take the same per-chain
            // ceiling as executor sends. Tolerant probe: any other app without the getter stays uncapped.
            (ok, ret) = address(this).staticcall(
                abi.encodeWithSelector(IStargateNativeFeeCapProvider.maxNativeFee.selector, dstChainId_)
            );
            if (!ok || ret.length != 32) return;
            uint256 ownCap = abi.decode(ret, (uint256));
            if (nativeFee_ > ownCap) revert CrosschainErrors.NativeFeeTooHigh(nativeFee_, ownCap);
            return;
        }
        address provider = abi.decode(ret, (address));
        (ok, ret) = provider.staticcall(
            abi.encodeWithSelector(IStargateNativeFeeCapProvider.isExecutor.selector, address(this))
        );
        if (!ok || ret.length != 32 || !abi.decode(ret, (bool))) return;
        uint256 cap = IStargateNativeFeeCapProvider(provider).maxNativeFee(dstChainId_);
        if (nativeFee_ > cap) revert CrosschainErrors.NativeFeeTooHigh(nativeFee_, cap);
    }
}
