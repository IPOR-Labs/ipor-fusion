// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IFuseInstantWithdraw} from "../IFuseInstantWithdraw.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";

/// @notice Data structure for entering - supply - the ERC4626 vault
struct Erc4626SupplyFuseEnterData {
    /// @dev ERC4626 vault address
    address vault;
    /// @dev amount to supply, this is amount of underlying asset in the given ERC4626 vault
    uint256 vaultAssetAmount;
    /// @dev minimum amount of shares expected to receive from the deposit
    uint256 minSharesOut;
}

/// @notice Data structure for exiting - withdrawing - the ERC4626 vault
struct Erc4626SupplyFuseExitData {
    /// @dev ERC4626 vault address
    address vault;
    /// @dev amount to withdraw, this is amount of underlying asset in the given ERC4626 vault
    /// @dev an amount greater than or equal to the exit cap (see Erc4626SupplyFuse._exit) is a full exit: the fuse
    ///      redeems min(balanceOf, maxRedeem) shares instead of withdrawing assets (IL-8489)
    uint256 vaultAssetAmount;
    /// @dev maximum number of vault shares that can be burned during the withdraw, 0 means no limit
    uint256 maxSharesBurned;
}

/// @title Generic fuse for ERC4626 vaults responsible for supplying and withdrawing assets from the ERC4626 vaults based on preconfigured market substrates
/// @dev Substrates in this fuse are the assets that are used in the ERC4626 vaults for a given MARKET_ID
contract Erc4626SupplyFuse is IFuseCommon, IFuseInstantWithdraw {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;

    /// @notice Emitted when assets are successfully deposited into an ERC4626 vault
    /// @param version The address of this fuse contract version
    /// @param asset The address of the underlying asset being deposited
    /// @param vault The address of the ERC4626 vault receiving the deposit
    /// @param vaultAssetAmount The amount of underlying assets deposited into the vault
    event Erc4626SupplyFuseEnter(address version, address asset, address vault, uint256 vaultAssetAmount);

    /// @notice Emitted when assets are successfully withdrawn from an ERC4626 vault
    /// @param version The address of this fuse contract version
    /// @param asset The address of the underlying asset being withdrawn
    /// @param vault The address of the ERC4626 vault from which assets are withdrawn
    /// @param vaultAssetAmount The amount of underlying assets withdrawn from the vault
    /// @param shares The amount of vault shares redeemed for the withdrawal
    event Erc4626SupplyFuseExit(
        address version,
        address asset,
        address vault,
        uint256 vaultAssetAmount,
        uint256 shares
    );

    /// @notice Emitted when withdrawal from an ERC4626 vault fails (used in instant withdraw scenarios)
    /// @param version The address of this fuse contract version
    /// @param asset The address of the underlying asset that failed to withdraw
    /// @param vault The address of the ERC4626 vault from which withdrawal was attempted
    /// @param vaultAssetAmount The amount of underlying assets that failed to withdraw
    event Erc4626SupplyFuseExitFailed(address version, address asset, address vault, uint256 vaultAssetAmount);

    error Erc4626SupplyFuseUnsupportedVault(string action, address asset);

    /// @notice Thrown when received shares are below the minimum required
    /// @param receivedShares The amount of shares actually received
    /// @param minSharesOut The minimum amount of shares required
    error Erc4626SupplyFuseInsufficientShares(uint256 receivedShares, uint256 minSharesOut);

    /// @notice Thrown when shares burned during withdraw exceed the maximum allowed
    /// @param sharesBurned The amount of shares actually burned
    /// @param maxSharesBurned The maximum amount of shares allowed to be burned
    error Erc4626SupplyFuseExcessiveSharesBurned(uint256 sharesBurned, uint256 maxSharesBurned);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    function enter(Erc4626SupplyFuseEnterData memory data_) public returns (uint256 finalVaultAssetAmount) {
        if (data_.vaultAssetAmount == 0) {
            return 0;
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.vault)) {
            revert Erc4626SupplyFuseUnsupportedVault("enter", data_.vault);
        }

        address underlyingAsset = IERC4626(data_.vault).asset();

        finalVaultAssetAmount = IporMath.min(data_.vaultAssetAmount, ERC20(underlyingAsset).balanceOf(address(this)));

        if (finalVaultAssetAmount == 0) {
            return 0;
        }

        ERC20(underlyingAsset).forceApprove(data_.vault, finalVaultAssetAmount);

        uint256 shares = IERC4626(data_.vault).deposit(finalVaultAssetAmount, address(this));

        if (shares < data_.minSharesOut) {
            revert Erc4626SupplyFuseInsufficientShares(shares, data_.minSharesOut);
        }

        emit Erc4626SupplyFuseEnter(VERSION, underlyingAsset, data_.vault, finalVaultAssetAmount);
    }

    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        address vault = TypeConversionLib.toAddress(inputs[0]);
        uint256 amount = TypeConversionLib.toUint256(inputs[1]);
        uint256 minSharesOut = TypeConversionLib.toUint256(inputs[2]);

        uint256 suppliedAmount = enter(
            Erc4626SupplyFuseEnterData({vault: vault, vaultAssetAmount: amount, minSharesOut: minSharesOut})
        );

        bytes32[] memory outputs = new bytes32[](1);
        outputs[0] = TypeConversionLib.toBytes32(suppliedAmount);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    function exit(Erc4626SupplyFuseExitData memory data_) public returns (uint256 shares) {
        return _exit({data_: data_, catchExceptions_: false});
    }

    function exitTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        address vault = TypeConversionLib.toAddress(inputs[0]);
        uint256 amount = TypeConversionLib.toUint256(inputs[1]);
        uint256 maxSharesBurned = TypeConversionLib.toUint256(inputs[2]);

        uint256 shares = exit(
            Erc4626SupplyFuseExitData({vault: vault, vaultAssetAmount: amount, maxSharesBurned: maxSharesBurned})
        );

        bytes32[] memory outputs = new bytes32[](1);
        outputs[0] = TypeConversionLib.toBytes32(shares);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @dev params[0] - amount in underlying asset, params[1] - vault address
    function instantWithdraw(bytes32[] calldata params_) external override {
        uint256 amount = uint256(params_[0]);

        address vault = PlasmaVaultConfigLib.bytes32ToAddress(params_[1]);

        _exit(Erc4626SupplyFuseExitData(vault, amount, 0), true);
    }

    /// @dev Shared exit path of `exit()` (reverts on failure) and `instantWithdraw()` (catches a failing vault `withdraw()`).
    ///      The assets to withdraw are `min(data_.vaultAssetAmount, cap)` where the cap is:
    ///      - `maxWithdraw(this)` when it is greater than 0 (the standard EIP-4626 cap),
    ///      - `previewRedeem(balanceOf(this))` (fallback `convertToAssets`) when `maxWithdraw(this)` is 0 and shares
    ///        are held. EIP-4626 allows `maxWithdraw` to under-report, and Morpho Vaults V2 returns a constant 0
    ///        from `maxDeposit/maxMint/maxWithdraw/maxRedeem` while `withdraw()/redeem()` work (GitHub #554, IL-8505).
    ///      0 is returned (no-op) only when there is nothing to withdraw: the requested amount is 0, no shares are
    ///      held, or the held shares preview to 0 assets (dust). When the vault itself cannot pay out (paused,
    ///      illiquid), its `withdraw()` reverts: `exit()` reverts, `instantWithdraw()` catches it and emits
    ///      `Erc4626SupplyFuseExitFailed` instead of a silent no-op (the substrate check and the view reads before
    ///      `withdraw()` are not caught). A partial exit (requested amount below the
    ///      cap) is performed with `withdraw(assets)`; a full exit (requested amount >= the cap) redeems shares with
    ///      `redeem(min(balanceOf, maxRedeem))`, falling back to `balanceOf` when `maxRedeem` is 0 (IL-8489), because
    ///      `withdraw(maxWithdraw)` can revert when the vault crystallizes a pending performance fee inside `withdraw`.
    ///      When the whole position is withdrawn this way via `previewRedeem(shares)`, share dust worth at most 1 wei
    ///      of the underlying asset may remain (about 1e12 share-wei for 18-decimal shares over a 6-decimal asset);
    ///      a later exit of that dust is a no-op.
    function _exit(Erc4626SupplyFuseExitData memory data_, bool catchExceptions_) internal returns (uint256 shares) {
        if (data_.vaultAssetAmount == 0) {
            return 0;
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.vault)) {
            revert Erc4626SupplyFuseUnsupportedVault("exit", data_.vault);
        }

        uint256 maxWithdrawAmount = _maxWithdrawableAssets(data_.vault);

        if (maxWithdrawAmount == 0) {
            return 0;
        }

        /// @dev A full exit redeems shares instead of withdrawing the cap in assets. The cap is a view and can
        ///      overestimate what withdraw accepts in the same call: a PlasmaVault crystallizes a pending
        ///      performance fee inside withdraw before it checks the limit, so withdraw(maxWithdraw) reverts with
        ///      ERC4626ExceededMaxWithdraw (IL-8489). redeem burns exactly the given shares, so it cannot overshoot.
        if (data_.vaultAssetAmount >= maxWithdrawAmount) {
            return _performRedeem(data_.vault, maxWithdrawAmount, data_.maxSharesBurned, catchExceptions_);
        }

        return _performWithdraw(data_.vault, data_.vaultAssetAmount, data_.maxSharesBurned, catchExceptions_);
    }

    /// @dev Cap for an exit. maxWithdraw() is the standard cap, but EIP-4626 lets it under-report and
    ///      Morpho Vaults V2 returns a constant 0 while withdraw() works (GitHub #554). When it is 0 and
    ///      shares are held, size the exit from the shares and let the vault's withdraw() decide:
    ///      a paused or illiquid vault reverts (the ALPHA batch reverts, instantWithdraw catches it and
    ///      emits Erc4626SupplyFuseExitFailed) instead of a silent no-op.
    function _maxWithdrawableAssets(address vault_) private view returns (uint256) {
        uint256 vaultMaxWithdraw = IERC4626(vault_).maxWithdraw(address(this));
        if (vaultMaxWithdraw > 0) {
            return vaultMaxWithdraw;
        }
        uint256 shares = IERC4626(vault_).balanceOf(address(this));
        if (shares == 0) {
            return 0;
        }
        try IERC4626(vault_).previewRedeem(shares) returns (uint256 assets) {
            return assets;
        } catch {
            return IERC4626(vault_).convertToAssets(shares);
        }
    }

    function _performRedeem(
        address vault_,
        uint256 maxWithdrawAmount_,
        uint256 maxSharesBurned_,
        bool catchExceptions_
    ) private returns (uint256 shares) {
        uint256 ownedShares = IERC4626(vault_).balanceOf(address(this));
        uint256 vaultMaxRedeem = IERC4626(vault_).maxRedeem(address(this));
        /// @dev Morpho Vaults V2 returns 0 from maxRedeem while redeem works (GitHub #554, IL-8505): size from balanceOf
        uint256 sharesToRedeem = vaultMaxRedeem == 0 ? ownedShares : IporMath.min(ownedShares, vaultMaxRedeem);

        if (sharesToRedeem == 0) {
            return 0;
        }

        if (maxSharesBurned_ > 0 && sharesToRedeem > maxSharesBurned_) {
            revert Erc4626SupplyFuseExcessiveSharesBurned(sharesToRedeem, maxSharesBurned_);
        }

        if (catchExceptions_) {
            try IERC4626(vault_).redeem(sharesToRedeem, address(this), address(this)) returns (uint256 assets_) {
                shares = sharesToRedeem;
                emit Erc4626SupplyFuseExit(VERSION, IERC4626(vault_).asset(), vault_, assets_, shares);
            } catch {
                /// @dev if redeem failed, continue with the next step
                emit Erc4626SupplyFuseExitFailed(VERSION, IERC4626(vault_).asset(), vault_, maxWithdrawAmount_);
            }
        } else {
            uint256 assets = IERC4626(vault_).redeem(sharesToRedeem, address(this), address(this));
            shares = sharesToRedeem;
            emit Erc4626SupplyFuseExit(VERSION, IERC4626(vault_).asset(), vault_, assets, shares);
        }
    }

    function _performWithdraw(
        address vault_,
        uint256 finalVaultAssetAmount_,
        uint256 maxSharesBurned_,
        bool catchExceptions_
    ) private returns (uint256 shares) {
        if (catchExceptions_) {
            try IERC4626(vault_).withdraw(finalVaultAssetAmount_, address(this), address(this)) returns (
                uint256 shares_
            ) {
                if (maxSharesBurned_ > 0 && shares_ > maxSharesBurned_) {
                    revert Erc4626SupplyFuseExcessiveSharesBurned(shares_, maxSharesBurned_);
                }
                shares = shares_;
                emit Erc4626SupplyFuseExit(VERSION, IERC4626(vault_).asset(), vault_, finalVaultAssetAmount_, shares);
            } catch {
                /// @dev if withdraw failed, continue with the next step
                emit Erc4626SupplyFuseExitFailed(VERSION, IERC4626(vault_).asset(), vault_, finalVaultAssetAmount_);
            }
        } else {
            shares = IERC4626(vault_).withdraw(finalVaultAssetAmount_, address(this), address(this));
            if (maxSharesBurned_ > 0 && shares > maxSharesBurned_) {
                revert Erc4626SupplyFuseExcessiveSharesBurned(shares, maxSharesBurned_);
            }
            emit Erc4626SupplyFuseExit(VERSION, IERC4626(vault_).asset(), vault_, finalVaultAssetAmount_, shares);
        }
    }
}
