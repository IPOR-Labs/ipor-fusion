// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Extended interface for Term Finance TermRepoToken
/// @notice TermRepoToken is ERC20 with extra Term-specific fields. decimals() is inherited
///         on the concrete impl via IERC20MetadataUpgradeable but is NOT declared on the
///         upstream ITermRepoToken interface — same for termRepoId() which is a public
///         state variable auto-getter.
interface IExtTermRepoToken is IERC20 {
    function decimals() external view returns (uint8);

    function redemptionValue() external view returns (uint256);

    function termRepoId() external view returns (bytes32);
}
