// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IAguaGlobalCarryVault} from "./ext/IAguaGlobalCarryVault.sol";
import {AguaSubstrateLib} from "./lib/AguaSubstrateLib.sol";
import {Errors} from "../../libraries/errors/Errors.sol";

/// @notice Data structure for entering AguaSupplyFuse (synchronous deposit)
struct AguaSupplyFuseEnterData {
    /// @dev Agua Global Carry Vault address
    address vault;
    /// @dev amount of underlying asset (e.g. USDC) to deposit
    uint256 assetAmount;
    /// @dev minimum shares expected to receive (slippage protection)
    uint256 minSharesOut;
}

/// @title AguaSupplyFuse
/// @notice Fuse for synchronous deposits into Reservoir's Agua Global Carry Vault.
/// @dev Executes in PlasmaVault storage context via delegatecall. MUST NOT contain storage variables.
///      This fuse deliberately does NOT implement IFuseInstantWithdraw: exits are async and go
///      through the Agua redemption fuse set only. `exit` always reverts. This structural exclusion guarantees
///      a PlasmaVault redemption can never auto-trigger an Agua exit (redemption DoS impossible).
contract AguaSupplyFuse is IFuseCommon {
    using SafeERC20 for ERC20;

    /// @notice Emitted when a deposit into the Agua vault succeeds
    /// @param version The address of this fuse contract version
    /// @param vault The Agua vault that received the deposit
    /// @param assetAmount The amount of underlying asset deposited
    /// @param shares The amount of shares minted to the PlasmaVault
    event AguaSupplyFuseEnter(address version, address vault, uint256 assetAmount, uint256 shares);

    /// @notice Thrown when received shares are below the minimum required
    /// @param shares The amount of shares actually received
    /// @param minSharesOut The minimum amount of shares required
    error AguaSupplyFuseInsufficientShares(uint256 shares, uint256 minSharesOut);

    /// @notice Thrown when `exit` is called; Agua exits go through the Agua redemption fuse set
    error AguaSupplyFuseExitNotSupported();

    /// @notice Address of this fuse contract version
    address public immutable VERSION;

    /// @notice Market ID this fuse operates on
    uint256 public immutable MARKET_ID;

    /// @notice Initializes the fuse with a specific market ID
    /// @param marketId_ The market ID used to identify the Agua vault substrates
    constructor(uint256 marketId_) {
        if (marketId_ == 0) revert Errors.WrongValue();
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Synchronous deposit of underlying asset into the Agua vault, minting shares to the PlasmaVault
    /// @dev Clamps the amount to the PlasmaVault's asset balance and the vault's deposit cap so the deposit
    ///      never reverts on the cap. Cleans up the approval after depositing.
    /// @param data_ The enter data containing vault, assetAmount, and minSharesOut
    function enter(AguaSupplyFuseEnterData memory data_) external {
        if (data_.assetAmount == 0) {
            return;
        }

        AguaSubstrateLib.validateVaultGranted(MARKET_ID, data_.vault);

        address asset = IAguaGlobalCarryVault(data_.vault).asset();
        AguaSubstrateLib.validateAssetGranted(MARKET_ID, asset);

        uint256 finalAmount = IporMath.min(
            IporMath.min(data_.assetAmount, ERC20(asset).balanceOf(address(this))),
            IAguaGlobalCarryVault(data_.vault).maxDeposit(address(this))
        );

        if (finalAmount == 0) {
            return;
        }

        ERC20(asset).forceApprove(data_.vault, finalAmount);

        uint256 shares = IAguaGlobalCarryVault(data_.vault).deposit(finalAmount, address(this));

        ERC20(asset).forceApprove(data_.vault, 0);

        if (shares < data_.minSharesOut) {
            revert AguaSupplyFuseInsufficientShares(shares, data_.minSharesOut);
        }

        emit AguaSupplyFuseEnter(VERSION, data_.vault, finalAmount, shares);
    }

    /// @notice Exits are not supported on this fuse; use the Agua redemption fuse set for async redemptions
    /// @dev Always reverts. The parameter is accepted to keep an `exit(bytes)` shape but is ignored.
    function exit(bytes calldata) external pure {
        revert AguaSupplyFuseExitNotSupported();
    }
}
