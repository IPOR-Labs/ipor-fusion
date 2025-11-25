// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title PrincipalToken External Interface
interface IPrincipalToken is IERC20Metadata {
    struct TokenReward {
        address token;
        uint256 amount;
    }
    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    function i_factory() external view returns (address);

    function i_yt() external view returns (address);

    function i_resolver() external view returns (address);

    function i_asset() external view returns (address);

    /*//////////////////////////////////////////////////////////////
                               LIFECYCLE
    //////////////////////////////////////////////////////////////*/

    function supply(uint256 shares, address receiver) external returns (uint256);

    function issue(uint256 principal, address receiver) external returns (uint256);

    function unite(uint256 shares, address receiver) external returns (uint256);

    function combine(uint256 principal, address receiver) external returns (uint256);

    function collect(address receiver, address owner) external returns (uint256 shares, TokenReward[] memory rewards);

    function withdraw(uint256 shares, address receiver, address owner) external returns (uint256);

    function redeem(uint256 principal, address receiver, address owner) external returns (uint256);

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    function previewSupply(uint256 shares) external view returns (uint256 principal);

    function previewIssue(uint256 principal) external view returns (uint256 shares);

    function previewUnite(uint256 shares) external view returns (uint256 principal);

    function previewCombine(uint256 principal) external view returns (uint256 shares);

    function previewCollect(address owner) external view returns (uint256 shares);

    function previewWithdraw(uint256 shares) external view returns (uint256 principal);

    function previewRedeem(uint256 principal) external view returns (uint256 shares);

    function convertToUnderlying(uint256 principal) external view returns (uint256);

    function convertToPrincipal(uint256 shares) external view returns (uint256);

    function underlying() external view returns (address);

    function maturity() external view returns (uint256);
}
