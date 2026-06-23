// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IEVC} from "ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {EulerFuseLib} from "./EulerFuseLib.sol";
import {IEulerV2Swap} from "./ext/IEulerV2Swap.sol";
import {IEulerV2SwapRegistry} from "./ext/IEulerV2SwapRegistry.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";

/// @notice Data structure for registering an EulerSwap pool
/// @param pool The pool to register
/// @param subAccount Sub-account identifier owning the pool
struct EulerV2SwapRegistryFuseEnterData {
    address pool;
    bytes1 subAccount;
}

/// @notice Data structure for unregistering an EulerSwap pool
/// @param pool The pool to unregister (used for ownership validation and the event)
/// @param subAccount Sub-account identifier owning the pool
struct EulerV2SwapRegistryFuseExitData {
    address pool;
    bytes1 subAccount;
}

/// @title EulerV2SwapRegistryFuse
/// @notice Registers / unregisters an EulerSwap v2 pool in the public registry, decoupled from deployment.
/// @dev In v2 the registry (separate from the factory) holds registration, the validity bond, and pool
///      enumeration. The PlasmaVault cannot source or receive native ETH, so this fuse always registers
///      with a zero validity bond (msg.value == 0); registration is rejected by the registry if a non-zero
///      `minimumValidityBond` is ever configured. Ownership is validated against the vault's EULER_V2
///      sub-account via the pool's static params. No storage variables (delegatecall).
contract EulerV2SwapRegistryFuse is IFuseCommon {
    /// @notice Emitted when a pool is registered
    event EulerV2SwapRegistryFuseEnter(address version, address pool, address eulerAccount);
    /// @notice Emitted when a pool is unregistered
    event EulerV2SwapRegistryFuseExit(address version, address pool, address eulerAccount);

    /// @notice Thrown when the pool is not owned by the vault's derived sub-account
    error EulerV2SwapRegistryFuseInvalidOwner(address pool, address expectedEulerAccount);
    /// @notice Thrown when there is no registered pool for the sub-account on exit
    error EulerV2SwapRegistryFuseNotRegistered(address eulerAccount);

    /// @notice Address of this fuse contract version
    address public immutable VERSION;
    /// @notice Market ID this fuse operates on (EULER_V2)
    uint256 public immutable MARKET_ID;
    /// @notice Ethereum Vault Connector used to call the registry on behalf of the eulerAccount
    IEVC public immutable EVC;
    /// @notice EulerSwap registry used to register / unregister pools
    IEulerV2SwapRegistry public immutable REGISTRY;

    /// @param marketId_ The EULER_V2 market ID
    /// @param eulerV2EVC_ The Ethereum Vault Connector address (must not be address(0))
    /// @param eulerV2SwapRegistry_ The EulerSwap registry address (must not be address(0))
    constructor(uint256 marketId_, address eulerV2EVC_, address eulerV2SwapRegistry_) {
        if (eulerV2EVC_ == address(0) || eulerV2SwapRegistry_ == address(0)) {
            revert Errors.WrongAddress();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
        EVC = IEVC(eulerV2EVC_);
        REGISTRY = IEulerV2SwapRegistry(eulerV2SwapRegistry_);
    }

    /// @notice Registers the pool in the registry with a zero validity bond (no native ETH transferred)
    /// @param data_ Registration parameters
    function enter(EulerV2SwapRegistryFuseEnterData memory data_) public {
        address eulerAccount = EulerFuseLib.generateSubAccountAddress(address(this), data_.subAccount);

        IEulerV2Swap.StaticParams memory sp = IEulerV2Swap(data_.pool).getStaticParams();
        if (sp.eulerAccount != eulerAccount) {
            revert EulerV2SwapRegistryFuseInvalidOwner(data_.pool, eulerAccount);
        }

        // Routed through the EVC on behalf of eulerAccount: the registry is an EVCUtil contract enforcing
        // the caller authority over the pool's eulerAccount. No value is forwarded — the PlasmaVault cannot
        // source native ETH for a bond, nor receive a refund, so registration is always zero-bond.
        EVC.call(
            address(REGISTRY),
            eulerAccount,
            0,
            abi.encodeCall(IEulerV2SwapRegistry.registerPool, (data_.pool))
        );

        emit EulerV2SwapRegistryFuseEnter(VERSION, data_.pool, eulerAccount);
    }

    /// @notice Unregisters the pool, refunding its validity bond to the vault
    /// @param data_ Unregistration parameters
    function exit(EulerV2SwapRegistryFuseExitData memory data_) public {
        address eulerAccount = EulerFuseLib.generateSubAccountAddress(address(this), data_.subAccount);

        if (REGISTRY.poolByEulerAccount(eulerAccount) == address(0)) {
            revert EulerV2SwapRegistryFuseNotRegistered(eulerAccount);
        }

        EVC.call(address(REGISTRY), eulerAccount, 0, abi.encodeCall(IEulerV2SwapRegistry.unregisterPool, ()));

        emit EulerV2SwapRegistryFuseExit(VERSION, data_.pool, eulerAccount);
    }

    /// @notice Enters using parameters read from transient storage (concatenated bytes32 chunks)
    function enterTransient() external {
        enter(abi.decode(_readEncodedInputs(), (EulerV2SwapRegistryFuseEnterData)));
    }

    /// @notice Exits using parameters read from transient storage (concatenated bytes32 chunks)
    function exitTransient() external {
        exit(abi.decode(_readEncodedInputs(), (EulerV2SwapRegistryFuseExitData)));
    }

    /// @notice Reconstructs the ABI-encoded calldata from transient-storage bytes32 chunks
    function _readEncodedInputs() private view returns (bytes memory encodedData) {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        uint256 inputsLen = inputs.length;
        encodedData = new bytes(inputsLen * 32);
        for (uint256 i; i < inputsLen; ++i) {
            bytes32 chunk = inputs[i];
            assembly {
                mstore(add(encodedData, add(32, mul(i, 32))), chunk)
            }
        }
    }
}
