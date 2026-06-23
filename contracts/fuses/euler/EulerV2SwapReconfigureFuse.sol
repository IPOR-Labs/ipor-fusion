// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IEVC} from "ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {EulerFuseLib} from "./EulerFuseLib.sol";
import {IEulerV2Swap} from "./ext/IEulerV2Swap.sol";
import {IEulerV2SwapFactory} from "./ext/IEulerV2SwapFactory.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";

/// @notice Data structure for reconfiguring an EulerSwap pool
/// @param pool The pool to reconfigure
/// @param subAccount Sub-account identifier owning the pool
/// @param dynamicParams New curve / fee configuration
/// @param initialState New virtual reserves
struct EulerV2SwapReconfigureFuseEnterData {
    address pool;
    bytes1 subAccount;
    IEulerV2Swap.DynamicParams dynamicParams;
    IEulerV2Swap.InitialState initialState;
}

/// @title EulerV2SwapReconfigureFuse
/// @notice Updates the mutable curve / fee parameters of an EulerSwap v2 pool owned by a vault sub-account.
/// @dev Validates that the pool is owned by the vault's sub-account and that its supply/borrow vaults are
///      still granted on the EULER_V2 market before reconfiguring. No storage variables (delegatecall).
contract EulerV2SwapReconfigureFuse is IFuseCommon {
    /// @notice Upper bound (exclusive) for a per-side fee, scaled to 1e18 == 100%
    uint256 private constant MAX_FEE = 1e18;

    /// @notice Emitted when a pool is reconfigured
    event EulerV2SwapReconfigureFuseEnter(address version, address pool, address eulerAccount);

    /// @notice Thrown when the pool was not deployed by the trusted EulerSwap factory
    error EulerV2SwapReconfigureFuseUnknownPool(address pool);
    /// @notice Thrown when the pool is not owned by the vault's derived sub-account
    error EulerV2SwapReconfigureFuseInvalidOwner(address pool, address expectedEulerAccount);
    /// @notice Thrown when a pool supply/borrow vault is not granted on the EULER_V2 market
    error EulerV2SwapReconfigureFuseUnsupportedVault(address vault, bytes1 subAccount);
    /// @notice Thrown when dynamic parameters fail sanity bounds (fee, expiration) or request a swap hook
    error EulerV2SwapReconfigureFuseInvalidParams();
    /// @notice Thrown when calling exit (reconfiguration is one-directional; decommission via DeployFuse)
    error UnsupportedOperation();

    /// @notice Address of this fuse contract version
    address public immutable VERSION;
    /// @notice Market ID this fuse operates on (EULER_V2)
    uint256 public immutable MARKET_ID;
    /// @notice Ethereum Vault Connector used to call the pool on behalf of the eulerAccount
    IEVC public immutable EVC;
    /// @notice EulerSwap factory used to verify the pool is a genuine factory deployment
    IEulerV2SwapFactory public immutable FACTORY;

    /// @param marketId_ The EULER_V2 market ID
    /// @param eulerV2EVC_ The Ethereum Vault Connector address (must not be address(0))
    /// @param eulerV2SwapFactory_ The EulerSwap factory address (must not be address(0))
    constructor(uint256 marketId_, address eulerV2EVC_, address eulerV2SwapFactory_) {
        if (eulerV2EVC_ == address(0) || eulerV2SwapFactory_ == address(0)) {
            revert Errors.WrongAddress();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
        EVC = IEVC(eulerV2EVC_);
        FACTORY = IEulerV2SwapFactory(eulerV2SwapFactory_);
    }

    /// @notice Reconfigures the pool's dynamic parameters and virtual reserves
    /// @param data_ Reconfiguration parameters
    function enter(EulerV2SwapReconfigureFuseEnterData memory data_) public {
        address eulerAccount = EulerFuseLib.generateSubAccountAddress(address(this), data_.subAccount);

        // Anti-substitution: only reconfigure a pool the trusted factory actually deployed, so getStaticParams
        // (used for ownership / vault validation below) is read from a genuine EulerSwap pool, not a spoof.
        if (!FACTORY.deployedPools(data_.pool)) {
            revert EulerV2SwapReconfigureFuseUnknownPool(data_.pool);
        }

        IEulerV2Swap.StaticParams memory sp = IEulerV2Swap(data_.pool).getStaticParams();

        if (sp.eulerAccount != eulerAccount) {
            revert EulerV2SwapReconfigureFuseInvalidOwner(data_.pool, eulerAccount);
        }

        _requireSupply(sp.supplyVault0, data_.subAccount);
        _requireSupply(sp.supplyVault1, data_.subAccount);
        // borrowVault0/1 may be address(0) for supply-only pools; only a non-zero borrow vault must be a
        // granted borrow substrate so any debt it opens is netted in NAV.
        if (sp.borrowVault0 != address(0)) {
            _requireBorrow(sp.borrowVault0, data_.subAccount);
        }
        if (sp.borrowVault1 != address(0)) {
            _requireBorrow(sp.borrowVault1, data_.subAccount);
        }

        // A swap hook is rejected outright: it would let an external contract execute arbitrary
        // state-changing code in the swap context of vault-owned funds, ceding control of the position.
        if (
            data_.dynamicParams.fee0 >= MAX_FEE ||
            data_.dynamicParams.fee1 >= MAX_FEE ||
            (data_.dynamicParams.expiration != 0 && data_.dynamicParams.expiration <= block.timestamp) ||
            data_.dynamicParams.swapHook != address(0) ||
            data_.dynamicParams.swapHookedOperations != 0
        ) {
            revert EulerV2SwapReconfigureFuseInvalidParams();
        }

        // Routed through the EVC on behalf of eulerAccount: the pool is an EVCUtil contract enforcing
        // `_msgSender() == eulerAccount` (or an installed manager). A direct call would revert Unauthorized.
        EVC.call(
            data_.pool,
            eulerAccount,
            0,
            abi.encodeCall(IEulerV2Swap.reconfigure, (data_.dynamicParams, data_.initialState))
        );

        emit EulerV2SwapReconfigureFuseEnter(VERSION, data_.pool, eulerAccount);
    }

    /// @notice Not supported; decommissioning is handled by EulerV2SwapDeployFuse.exit
    function exit() external pure {
        revert UnsupportedOperation();
    }

    /// @notice Enters using parameters read from transient storage (concatenated bytes32 chunks)
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        uint256 inputsLen = inputs.length;
        bytes memory encodedData = new bytes(inputsLen * 32);
        for (uint256 i; i < inputsLen; ++i) {
            bytes32 chunk = inputs[i];
            assembly {
                mstore(add(encodedData, add(32, mul(i, 32))), chunk)
            }
        }
        enter(abi.decode(encodedData, (EulerV2SwapReconfigureFuseEnterData)));
    }

    /// @notice Reverts unless `vault`/`subAccount` is a supply substrate on the EULER_V2 market
    function _requireSupply(address vault, bytes1 subAccount) private view {
        if (!EulerFuseLib.canSupply(MARKET_ID, vault, subAccount)) {
            revert EulerV2SwapReconfigureFuseUnsupportedVault(vault, subAccount);
        }
    }

    /// @notice Reverts unless `vault`/`subAccount` is a borrow substrate on the EULER_V2 market
    function _requireBorrow(address vault, bytes1 subAccount) private view {
        if (!EulerFuseLib.canBorrow(MARKET_ID, vault, subAccount)) {
            revert EulerV2SwapReconfigureFuseUnsupportedVault(vault, subAccount);
        }
    }
}
