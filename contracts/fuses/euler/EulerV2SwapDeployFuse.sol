// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IEVC} from "ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {EulerFuseLib} from "./EulerFuseLib.sol";
import {IEulerV2Swap} from "./ext/IEulerV2Swap.sol";
import {IEulerV2SwapFactory} from "./ext/IEulerV2SwapFactory.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";

/// @notice Data structure for deploying an EulerSwap pool
/// @param staticParams Immutable pool configuration (vaults, eulerAccount, feeRecipient)
/// @param dynamicParams Curve / fee configuration applied on activation
/// @param initialState Initial virtual reserves
/// @param salt CREATE2 salt used by the factory (mined off-chain)
/// @param predictedPool Pool address the alpha expects (anti-substitution guard)
/// @param subAccount Sub-account identifier; eulerAccount = vault XOR subAccount
struct EulerV2SwapDeployFuseEnterData {
    IEulerV2Swap.StaticParams staticParams;
    IEulerV2Swap.DynamicParams dynamicParams;
    IEulerV2Swap.InitialState initialState;
    bytes32 salt;
    address predictedPool;
    bytes1 subAccount;
}

/// @notice Data structure for decommissioning an EulerSwap pool
/// @param pool The pool whose operator authorization is removed
/// @param subAccount Sub-account identifier owning the pool
struct EulerV2SwapDeployFuseExitData {
    address pool;
    bytes1 subAccount;
}

/// @title EulerV2SwapDeployFuse
/// @notice Deploys (and decommissions) an EulerSwap v2 LP pool owned by a PlasmaVault sub-account.
/// @dev Operates under the EULER_V2 market: the pool's supply/borrow vaults are validated against the
///      same substrates used by EulerV2SupplyFuse / EulerV2BalanceFuse, which guarantees every pool
///      position is accounted for in NAV. The fuse installs the pool as the EVC account operator and
///      asks the factory to deploy it. Registration in the EulerSwap registry is intentionally left to
///      the dedicated EulerV2SwapRegistryFuse. No storage variables (runs via delegatecall from PlasmaVault).
contract EulerV2SwapDeployFuse is IFuseCommon {
    /// @notice Upper bound (exclusive) for a per-side fee, scaled to 1e18 == 100%
    uint256 private constant MAX_FEE = 1e18;

    /// @notice Emitted when a pool is deployed and its operator authorization installed
    event EulerV2SwapDeployFuseEnter(
        address version,
        address pool,
        address eulerAccount,
        bytes1 subAccount,
        address asset0,
        address asset1
    );

    /// @notice Emitted when a pool's operator authorization is removed
    event EulerV2SwapDeployFuseExit(address version, address pool, address eulerAccount, bytes1 subAccount);

    /// @notice Thrown when staticParams.eulerAccount does not match the vault's derived sub-account
    error EulerV2SwapDeployFuseInvalidEulerAccount(address expected, address provided);
    /// @notice Thrown when a supply/borrow vault is not granted on the EULER_V2 market for the sub-account
    error EulerV2SwapDeployFuseUnsupportedVault(address vault, bytes1 subAccount);
    /// @notice Thrown when the predicted pool address does not match the factory computation / deployment
    error EulerV2SwapDeployFusePoolAddressMismatch(address predicted, address computed);
    /// @notice Thrown when feeRecipient is not address(0) (fees must compound into the supply vault)
    error EulerV2SwapDeployFuseInvalidFeeRecipient(address feeRecipient);
    /// @notice Thrown when dynamic parameters fail sanity bounds (fee, expiration) or request a swap hook
    error EulerV2SwapDeployFuseInvalidParams();

    /// @notice Address of this fuse contract version
    address public immutable VERSION;
    /// @notice Market ID this fuse operates on (EULER_V2)
    uint256 public immutable MARKET_ID;
    /// @notice Ethereum Vault Connector used to install the pool as account operator
    IEVC public immutable EVC;
    /// @notice EulerSwap factory used to deploy pools
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

    /// @notice Installs the pool as the EVC account operator and deploys it via the factory
    /// @dev Atomic within a single PlasmaVault.execute. Reentrancy protection inherited from PlasmaVault.
    /// @param data_ Deployment parameters
    /// @return pool The deployed pool address (equals data_.predictedPool)
    function enter(EulerV2SwapDeployFuseEnterData memory data_) public returns (address pool) {
        address eulerAccount = EulerFuseLib.generateSubAccountAddress(address(this), data_.subAccount);

        if (data_.staticParams.eulerAccount != eulerAccount) {
            revert EulerV2SwapDeployFuseInvalidEulerAccount(eulerAccount, data_.staticParams.eulerAccount);
        }

        if (data_.staticParams.feeRecipient != address(0)) {
            revert EulerV2SwapDeployFuseInvalidFeeRecipient(data_.staticParams.feeRecipient);
        }

        // Dynamic parameter sanity bounds, mirrored in EulerV2SwapReconfigureFuse. A swap hook is rejected
        // outright: it would let an external contract execute arbitrary state-changing code in the swap
        // context of vault-owned funds, ceding control of the position (see feeRecipient == 0 rationale).
        if (
            data_.dynamicParams.fee0 >= MAX_FEE ||
            data_.dynamicParams.fee1 >= MAX_FEE ||
            (data_.dynamicParams.expiration != 0 && data_.dynamicParams.expiration <= block.timestamp) ||
            data_.dynamicParams.swapHook != address(0) ||
            data_.dynamicParams.swapHookedOperations != 0
        ) {
            revert EulerV2SwapDeployFuseInvalidParams();
        }

        // Permissioning against EULER_V2 substrates. This simultaneously guarantees that every position
        // the pool can open is counted by EulerV2BalanceFuse (NAV), so a pool whose positions are
        // invisible to NAV cannot be deployed.
        _requireSupply(data_.staticParams.supplyVault0, data_.subAccount);
        _requireSupply(data_.staticParams.supplyVault1, data_.subAccount);
        // EulerSwap allows borrowVault0/1 == address(0) (supply-only / non-JIT pools). A non-zero borrow
        // vault, however, can open debt that must be netted in NAV, so it must be a granted borrow substrate.
        if (data_.staticParams.borrowVault0 != address(0)) {
            _requireBorrow(data_.staticParams.borrowVault0, data_.subAccount);
        }
        if (data_.staticParams.borrowVault1 != address(0)) {
            _requireBorrow(data_.staticParams.borrowVault1, data_.subAccount);
        }

        // Anti-substitution: the address authorized as operator must be exactly the address the
        // factory will CREATE2-deploy for these static params + salt.
        address computed = FACTORY.computePoolAddress(data_.staticParams, data_.salt);
        if (data_.predictedPool != computed) {
            revert EulerV2SwapDeployFusePoolAddressMismatch(data_.predictedPool, computed);
        }

        // setAccountOperator is a direct call: under delegatecall address(this) == PlasmaVault, which is the
        // EVC owner of eulerAccount (shared 19-byte owner prefix via XOR), so the EVC authorizes the operator.
        EVC.setAccountOperator(eulerAccount, data_.predictedPool, true);

        // deployPool MUST be routed through the EVC on behalf of eulerAccount: the factory is an EVCUtil
        // contract that enforces `_msgSender() == staticParams.eulerAccount`. A direct call would resolve
        // `_msgSender()` to PlasmaVault (!= eulerAccount for any non-zero sub-account) and revert Unauthorized.
        pool = abi.decode(
            EVC.call(
                address(FACTORY),
                eulerAccount,
                0,
                abi.encodeCall(
                    IEulerV2SwapFactory.deployPool,
                    (data_.staticParams, data_.dynamicParams, data_.initialState, data_.salt)
                )
            ),
            (address)
        );

        if (pool != data_.predictedPool) {
            revert EulerV2SwapDeployFusePoolAddressMismatch(data_.predictedPool, pool);
        }

        (address asset0, address asset1) = IEulerV2Swap(pool).getAssets();

        emit EulerV2SwapDeployFuseEnter(VERSION, pool, eulerAccount, data_.subAccount, asset0, asset1);
    }

    /// @notice Removes the pool's operator authorization, disabling further pool operation
    /// @dev Withdrawal of the underlying positions is handled by EulerV2SupplyFuse / EulerV2BorrowFuse.
    /// @param data_ Decommission parameters
    function exit(EulerV2SwapDeployFuseExitData memory data_) public {
        address eulerAccount = EulerFuseLib.generateSubAccountAddress(address(this), data_.subAccount);

        EVC.setAccountOperator(eulerAccount, data_.pool, false);

        emit EulerV2SwapDeployFuseExit(VERSION, data_.pool, eulerAccount, data_.subAccount);
    }

    /// @notice Enters using parameters read from transient storage (concatenated bytes32 chunks)
    /// @dev Inputs are the ABI-encoded EulerV2SwapDeployFuseEnterData split into bytes32 chunks; the
    ///      deployed pool address is written to outputs[0].
    function enterTransient() external {
        EulerV2SwapDeployFuseEnterData memory data = abi.decode(
            _readEncodedInputs(),
            (EulerV2SwapDeployFuseEnterData)
        );
        address pool = enter(data);
        bytes32[] memory outputs = new bytes32[](1);
        outputs[0] = TypeConversionLib.toBytes32(pool);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Exits using parameters read from transient storage (concatenated bytes32 chunks)
    function exitTransient() external {
        EulerV2SwapDeployFuseExitData memory data = abi.decode(_readEncodedInputs(), (EulerV2SwapDeployFuseExitData));
        exit(data);
    }

    /// @notice Reverts unless `vault`/`subAccount` is a supply substrate on the EULER_V2 market
    function _requireSupply(address vault, bytes1 subAccount) private view {
        if (!EulerFuseLib.canSupply(MARKET_ID, vault, subAccount)) {
            revert EulerV2SwapDeployFuseUnsupportedVault(vault, subAccount);
        }
    }

    /// @notice Reverts unless `vault`/`subAccount` is a borrow substrate on the EULER_V2 market
    function _requireBorrow(address vault, bytes1 subAccount) private view {
        if (!EulerFuseLib.canBorrow(MARKET_ID, vault, subAccount)) {
            revert EulerV2SwapDeployFuseUnsupportedVault(vault, subAccount);
        }
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
