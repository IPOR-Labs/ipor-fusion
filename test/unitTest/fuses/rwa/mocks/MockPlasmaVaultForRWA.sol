// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {PlasmaVaultConfigLib} from "../../../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../../../../../contracts/libraries/PlasmaVaultLib.sol";

/// @title MockPlasmaVaultForRWA
/// @notice Minimal Plasma-Vault-like harness used by RWA unit tests.
/// @dev Holds substrates, price-oracle-middleware pointer and access manager address in the
///      canonical storage slots (via `PlasmaVaultConfigLib` / `PlasmaVaultLib`). Also implements
///      the `IPlasmaVaultGovernance` methods actually consumed by the RWA fuses and the
///      `IERC4626.asset()` method required by the operation and balance fuses.
contract MockPlasmaVaultForRWA {
    /// @notice Underlying asset returned by `asset()` (satisfies IERC4626.asset()).
    address public underlying;

    /// @notice Access manager address returned by `getAccessManagerAddress()`.
    address public accessManager;

    /// @notice Set the underlying asset.
    function setUnderlying(address underlying_) external {
        underlying = underlying_;
    }

    /// @notice Set the access manager returned by `getAccessManagerAddress()`.
    function setAccessManager(address accessManager_) external {
        accessManager = accessManager_;
    }

    /// @notice Set the price-oracle-middleware used by `PlasmaVaultLib.getPriceOracleMiddleware()`.
    function setPriceOracleMiddleware(address middleware_) external {
        PlasmaVaultLib.setPriceOracleMiddleware(middleware_);
    }

    /// @notice Grant substrates to a market (overwriting any previous grants).
    function grantMarketSubstrates(uint256 marketId_, bytes32[] memory substrates_) external {
        PlasmaVaultConfigLib.grantMarketSubstrates(marketId_, substrates_);
    }

    // -------------------------------------------------
    // IERC4626 (only the pieces RWA fuses call)
    // -------------------------------------------------

    function asset() external view returns (address) {
        return underlying;
    }

    // -------------------------------------------------
    // IPlasmaVaultGovernance (only the pieces RWA fuses call)
    // -------------------------------------------------

    function getMarketSubstrates(uint256 marketId_) external view returns (bytes32[] memory) {
        return PlasmaVaultConfigLib.getMarketSubstrates(marketId_);
    }

    function isMarketSubstrateGranted(uint256 marketId_, bytes32 substrate_) external view returns (bool) {
        return PlasmaVaultConfigLib.isMarketSubstrateGranted(marketId_, substrate_);
    }

    function getAccessManagerAddress() external view returns (address) {
        return accessManager;
    }

    // -------------------------------------------------
    // Delegatecall harness
    // -------------------------------------------------

    /// @notice Forward `data_` to `target_` via delegatecall, bubbling reverts.
    function delegateExecute(address target_, bytes calldata data_) external returns (bytes memory) {
        (bool ok, bytes memory ret) = target_.delegatecall(data_);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        return ret;
    }
}
