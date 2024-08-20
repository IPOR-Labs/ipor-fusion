// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

/// @notice FuseAction is a struct that represents a single action that can be executed by a Alpha
struct FuseAction {
    /// @notice fuse is a address of the Fuse contract
    address fuse;
    /// @notice data is a bytes data that is passed to the Fuse contract
    bytes data;
}

/// @title Plasma Vault interface with business methods
interface IPlasmaVault {
    function totalAssetsInMarket(uint256 marketId_) external view returns (uint256);
    function getUnrealizedManagementFee() external view returns (uint256);

    function execute(FuseAction[] calldata calls_) external;
    function claimRewards(FuseAction[] calldata calls_) external;

    function depositWithPermit(
        uint256 assets_,
        address owner_,
        address receiver_,
        uint256 deadline_,
        uint8 v_,
        bytes32 r_,
        bytes32 s_
    ) external returns (uint256);
}
