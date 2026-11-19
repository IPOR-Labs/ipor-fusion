// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.24;

/// @dev EVault config flag: when set, the vault does not socialize the debt left after a liquidation that seized all
///      collateral (euler-vault-kit `src/EVault/shared/Constants.sol`)
uint32 constant CFG_DONT_SOCIALIZE_DEBT = 1 << 0;

/// @title IEulerV2VaultGovernance
/// @notice Subset of the EVault Governance module read by EulerV2BalanceFuse
interface IEulerV2VaultGovernance {
    /// @notice Bitmask of the vault's configuration flags
    function configFlags() external view returns (uint32);

    /// @notice LTV configuration of a collateral in this (controller) vault
    /// @dev EVK `LTVConfig.isRecognizedCollateral`: a collateral is recognized, so seizable in a liquidation, when its
    ///      `targetTimestamp` is not zero; an EVault never recognizes its own shares (`setLTV` reverts `E_InvalidLTVAsset`)
    function LTVFull(
        address collateral
    )
        external
        view
        returns (
            uint16 borrowLTV,
            uint16 liquidationLTV,
            uint16 initialLiquidationLTV,
            uint48 targetTimestamp,
            uint32 rampDuration
        );
}
