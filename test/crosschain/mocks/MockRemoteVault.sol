// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {UniversalReader} from "../../../contracts/universal_reader/UniversalReader.sol";
import {PlasmaVaultStorageLib} from "../../../contracts/libraries/PlasmaVaultStorageLib.sol";

/// @title MockRemoteVault
/// @notice ERC4626 stand-in for a remote PlasmaVault the dispatcher deposits into / redeems from. Adds
///         `redeemFromRequest` (mirrors `IPlasmaVault.redeemFromRequest`) so the async flow is exercisable
///         end-to-end against measured asset deltas.
/// @dev 1:1 asset:share by default (no offset). Behaves like a normal ERC4626 for DEPOSIT/REDEEM.
contract MockRemoteVault is ERC4626 {
    constructor(IERC20 asset_, string memory name_, string memory symbol_) ERC4626(asset_) ERC20(name_, symbol_) {}

    function _decimalsOffset() internal pure override returns (uint8) {
        return 0;
    }

    /// @notice Async redemption entry point: burns `shares_` from `owner_`, pays assets to `receiver_`.
    /// @dev The dispatcher calls this with `owner_ == receiver_ == address(dispatcher)`, so no allowance is
    ///      needed. Returns the assets paid out (the dispatcher measures the delta independently).
    function redeemFromRequest(uint256 shares_, address receiver_, address owner_) external virtual returns (uint256) {
        return redeem(shares_, receiver_, owner_);
    }
}

/// @title MockPermissiveAuthority
/// @notice `IAuthority`-shaped stand-in that allows every `(caller, target, selector)` immediately, so the
///         real `WithdrawManager` (`AccessManagedUpgradeable`) can be exercised in tests without deploying
///         `IporFusionAccessManager` (IL-8118 fixture, plan §3.1 item 1).
contract MockPermissiveAuthority {
    function canCall(address, address, bytes4) external pure returns (bool immediate, uint32 delay) {
        return (true, 0);
    }
}

/// @title MockRemotePlasmaVault
/// @notice `MockRemoteVault` wired to a real `WithdrawManager`: implements `transferRequestSharesFee`
///         (mirrors `PlasmaVaultBase.transferRequestSharesFee`) and overrides `redeemFromRequest` to consult
///         `canWithdrawFromRequest` first (mirrors `PlasmaVault.redeemFromRequest`), so the manager's stored
///         request is decremented the same way the real vault does it (IL-8118 fixture, plan §3.1 item 4).
///         The only change to `MockRemoteVault` itself is that `redeemFromRequest` became `virtual` so this
///         subclass can override it; its behaviour is unchanged, so every existing test using it is unaffected.
/// @dev Also a `UniversalReader`, so `read(dispatcher, plasmaVaultWithdrawManager())` executes in THIS
///      contract's storage context exactly like a real `PlasmaVault` (IL-8117). `withdrawManager()` and
///      `setWithdrawManager` read/write the real ERC-7201 slot (`PlasmaVaultStorageLib.getWithdrawManager()`,
///      mirroring `PlasmaVaultLib.updateWithdrawManager`, `contracts/libraries/PlasmaVaultLib.sol:1004-1006`,
///      minus the event) instead of a plain state variable, so the dispatcher's `UniversalReader.read`
///      cross-check reads the same slot a real vault would answer with — this mocks the STORAGE, never the
///      check itself.
contract MockRemotePlasmaVault is MockRemoteVault, UniversalReader {
    constructor(IERC20 asset_, string memory name_, string memory symbol_) MockRemoteVault(asset_, name_, symbol_) {}

    function withdrawManager() public view returns (address) {
        return PlasmaVaultStorageLib.getWithdrawManager().manager;
    }

    function setWithdrawManager(address withdrawManager_) external {
        PlasmaVaultStorageLib.getWithdrawManager().manager = withdrawManager_;
    }

    function transferRequestSharesFee(address from_, address to_, uint256 amount_) external {
        require(msg.sender == withdrawManager(), "not withdraw manager");
        _transfer(from_, to_, amount_);
    }

    function redeemFromRequest(uint256 shares_, address receiver_, address owner_)
        external
        override
        returns (uint256)
    {
        bool canWithdraw = WithdrawManager(withdrawManager()).canWithdrawFromRequest(owner_, shares_);
        require(canWithdraw, "cannot withdraw from request");
        return redeem(shares_, receiver_, owner_);
    }
}

/// @notice Field-for-field mirror of `WithdrawManager.WithdrawRequestInfo` so the ABI decode is compatible.
struct WithdrawRequestInfoView {
    uint256 shares;
    uint256 endWithdrawWindowTimestamp;
    bool canWithdraw;
    uint256 withdrawWindowInSeconds;
}

/// @title MockWithdrawManager
/// @notice Serves two roles in the crosschain suite (IL-8117): (1) the GENUINE manager in the positive
///         `_mockWm()` fixture, wired to a `MockRemotePlasmaVault` via `setWithdrawManager` so the vault's
///         own storage names it; and (2) the FOREIGN/attacker manager in the negative tests, where it is
///         simply a manager no vault is configured with — since IL-8117 the dispatcher asks the VAULT, so
///         this mock's `PLASMA_VAULT` self-attestation is no longer consulted by production code and only
///         documents the constructor argument. `requestShares` OVERWRITES the stored request (matching the
///         real `WithdrawManager`, IL-8118) after applying a settable fee, so the recorded post-fee amount
///         differs from the input; the fee is in bps for test convenience, unlike the real manager's WAD
///         scale. `requestInfo` is a view. `canWithdrawFromRequest` is ABI-compatible with the real
///         manager so `MockRemotePlasmaVault.redeemFromRequest` can call it, and DECREMENTS the stored
///         request rather than overwriting it.
contract MockWithdrawManager {
    address public immutable PLASMA_VAULT;
    uint256 private constant BPS = 10_000;

    /// @notice Fee applied to each `requestShares` call in bps (recorded amount = shares * (BPS - feeBps) / BPS).
    uint256 public feeBps;

    mapping(address account => uint256 shares) public requestedShares;

    constructor(address plasmaVault_) {
        PLASMA_VAULT = plasmaVault_;
    }

    function getPlasmaVaultAddress() external view returns (address) {
        return PLASMA_VAULT;
    }

    function setFeeBps(uint256 feeBps_) external {
        feeBps = feeBps_;
    }

    /// @notice Absolute fee (share units) actually moved out of the caller's balance on each `requestShares`,
    ///         through the vault's `transferRequestSharesFee` like the real manager (IL-8603 tests).
    uint256 public feeShares;

    function setFeeShares(uint256 feeShares_) external {
        feeShares = feeShares_;
    }

    function requestShares(uint256 shares_) external {
        // Overwrite, not accumulate (IL-8118) — see the contract NatSpec above.
        uint256 net = (shares_ * (BPS - feeBps)) / BPS;
        requestedShares[msg.sender] = net;
        if (feeShares > 0) {
            MockRemotePlasmaVault(PLASMA_VAULT).transferRequestSharesFee(msg.sender, address(this), feeShares);
        }
    }

    function requestInfo(address account_) external view returns (WithdrawRequestInfoView memory) {
        return WithdrawRequestInfoView({
            shares: requestedShares[account_],
            endWithdrawWindowTimestamp: 0,
            canWithdraw: true,
            withdrawWindowInSeconds: 0
        });
    }

    /// @notice ABI-compatible with `WithdrawManager.canWithdrawFromRequest`: `false` (no state change) if
    ///         the account has not requested at least `shares_`, else decrements the recorded request and
    ///         returns `true`. Lets a `MockRemotePlasmaVault` wired to this contract exercise the same
    ///         `redeemFromRequest` path a real vault does.
    function canWithdrawFromRequest(address account_, uint256 shares_) external returns (bool) {
        if (requestedShares[account_] < shares_) return false;
        requestedShares[account_] -= shares_;
        return true;
    }
}
