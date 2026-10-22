// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AuthorityUtils} from "@openzeppelin/contracts/access/manager/AuthorityUtils.sol";
import {MockRemoteVault} from "./MockRemoteVault.sol";

/// @dev Minimal ERC-20 balance book shared by the shaped tokens below.
abstract contract ShapedTokenBase {
    mapping(address account => uint256 amount) public balanceOf;

    function mint(address to_, uint256 amount_) external {
        balanceOf[to_] += amount_;
    }
}

/// @title Weth9ShapedToken
/// @notice WETH9-shaped token (IL-8625 R1): `transfer` returns a bool but REVERTS WITH EMPTY DATA when the balance is
///         short (`require(balanceOf[msg.sender] >= wad)` with no reason in WETH9).
contract Weth9ShapedToken is ShapedTokenBase {
    function transfer(address to_, uint256 amount_) external returns (bool) {
        if (balanceOf[msg.sender] < amount_) revert();
        balanceOf[msg.sender] -= amount_;
        balanceOf[to_] += amount_;
        return true;
    }
}

/// @title UsdtShapedToken
/// @notice USDT-shaped token (IL-8625 R1): `transfer` returns NO value and reverts with empty data when the balance is
///         short.
contract UsdtShapedToken is ShapedTokenBase {
    function transfer(address to_, uint256 amount_) external {
        if (balanceOf[msg.sender] < amount_) revert();
        balanceOf[msg.sender] -= amount_;
        balanceOf[to_] += amount_;
    }
}

/// @title MockShapedLiquidityVault
/// @notice `MockRemoteVault` whose `redeem` settles an "instant liquidity" leg through a WETH9- or USDT-shaped token with
///         OpenZeppelin `SafeERC20`, exactly the call a real PlasmaVault makes when it pays a withdrawal. A REDEEM above
///         the vault's instant liquidity therefore reverts with empty data inside the token, which `SafeERC20` turns into
///         `FailedInnerCall()` (OZ 5.0.x) or `FailedCall()` (OZ >= 5.1): the R1 shape that used to be bubbled.
/// @dev The shaped token only models the liquidity leg; the dispatcher's own asset still moves through the normal
///      ERC-4626 path afterwards, so a redeem within the instant liquidity completes and credits real assets.
contract MockShapedLiquidityVault is MockRemoteVault {
    using SafeERC20 for IERC20;

    IERC20 public immutable LIQUIDITY_TOKEN;

    constructor(IERC20 asset_, IERC20 liquidityToken_) MockRemoteVault(asset_, "Shaped Liquidity Vault", "SLV") {
        LIQUIDITY_TOKEN = liquidityToken_;
    }

    function redeem(uint256 shares_, address receiver_, address owner_) public override returns (uint256) {
        // The shaped token reverts with empty data when the vault's instant liquidity is short.
        LIQUIDITY_TOKEN.safeTransfer(address(0xdead), shares_);
        return super.redeem(shares_, receiver_, owner_);
    }
}

/// @title MockGasHungryAuthority
/// @notice `IAuthority`-shaped authority whose `canCall` needs `gasNeeded` gas (a cold access-manager check): it
///         answers `(true, 0)` when it gets that much, and runs out of gas inside the caller's `staticcall` otherwise.
contract MockGasHungryAuthority {
    uint256 public gasNeeded;

    function setGasNeeded(uint256 gasNeeded_) external {
        gasNeeded = gasNeeded_;
    }

    function canCall(address, address, bytes4) external view returns (bool, uint32) {
        uint256 start = gasleft();
        uint256 needed = gasNeeded;
        while (start - gasleft() < needed) {}
        return (true, 0);
    }
}

/// @title MockAuthorityGatedVault
/// @notice `MockRemoteVault` whose `redeem` first runs OpenZeppelin `AuthorityUtils.canCallWithDelay` against a
///         `MockGasHungryAuthority`, like the real `PlasmaVault.redeem` reaching the AccessManager through
///         `WithdrawManager.canWithdrawFromUnallocated` (IL-8625 R5). An out-of-gas inside the authority's `staticcall`
///         is swallowed by `AuthorityUtils` as `(false, 0)` and surfaces as the DECODABLE `AccessManagedUnauthorized`.
contract MockAuthorityGatedVault is MockRemoteVault {
    /// @dev Same selector as OpenZeppelin `IAccessManaged.AccessManagedUnauthorized(address)`.
    error AccessManagedUnauthorized(address caller);

    MockGasHungryAuthority public immutable AUTHORITY;

    constructor(IERC20 asset_) MockRemoteVault(asset_, "Authority Gated Vault", "AGV") {
        AUTHORITY = new MockGasHungryAuthority();
    }

    function redeem(uint256 shares_, address receiver_, address owner_) public override returns (uint256) {
        (bool immediate,) =
            AuthorityUtils.canCallWithDelay(address(AUTHORITY), msg.sender, address(this), this.redeem.selector);
        if (!immediate) revert AccessManagedUnauthorized(msg.sender);
        return super.redeem(shares_, receiver_, owner_);
    }
}
