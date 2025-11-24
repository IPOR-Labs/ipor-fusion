// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

interface ISiloConfig {
    /// @notice Retrieves the silo ID
    /// @dev Each silo is assigned a unique ID. ERC-721 token is minted with identical ID to deployer.
    /// An owner of that token receives the deployer fees.
    /// @return siloId The ID of the silo
    function SILO_ID() external view returns (uint256 siloId); // solhint-disable-line func-name-mixedcase

    /// @notice Retrieves the addresses of the two silos
    /// @return silo0 The address of the first silo
    /// @return silo1 The address of the second silo
    function getSilos() external view returns (address silo0, address silo1);

    /// @notice Retrieves share tokens associated with a specific silo
    /// @dev This function reverts for incorrect silo address input
    /// @param _silo The address of the silo for which share tokens are being retrieved
    /// @return protectedShareToken The address of the protected (non-borrowable) share token
    /// @return collateralShareToken The address of the collateral share token
    /// @return debtShareToken The address of the debt share token
    function getShareTokens(
        address _silo
    ) external view returns (address protectedShareToken, address collateralShareToken, address debtShareToken);
}
