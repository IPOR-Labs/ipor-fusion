// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Errors} from "../../libraries/errors/Errors.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "../../libraries/PlasmaVaultStorageLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IExtTermController} from "./ext/IExtTermController.sol";
import {IExtTermRepoServicer} from "./ext/IExtTermRepoServicer.sol";

/// @notice Data for post-maturity redemption of TermRepoToken into purchase token.
/// @param servicer Substrate key — TermRepoServicer proxy
/// @param amountToRedeem TermRepoToken raw units to burn (decimals match purchase token by Term design)
struct TermFinanceRedeemFuseEnterData {
    address servicer;
    uint256 amountToRedeem;
}

/// @title TermFinanceRedeemFuse
/// @author IPOR Labs
/// @notice Post-maturity exit: burn TermRepoToken and receive purchase token from TermRepoLocker
///         (minus any realised default haircut applied by the servicer).
/// @dev Servicer.redeemTermRepoTokens(redeemer, amount) burns the TermRepoToken (servicer holds
///      BURNER_ROLE) and transfers the proceeds via TermRepoLocker. The fuse measures the
///      actual purchase-token delta on the vault so the emitted event reflects what was
///      received (which may differ from `amountToRedeem * redemptionValue` if a haircut applies).
contract TermFinanceRedeemFuse is IFuseCommon {
    /// @notice Emitted on successful redemption with the measured purchase-token delta.
    event TermFinanceRedeemed(
        address version,
        address servicer,
        uint256 amountToRedeem,
        uint256 purchaseTokenReceived
    );

    /// @notice Reverts when the PlasmaVault has no WithdrawManager configured.
    /// @dev Codifies the non-functional requirement: a vault without a WithdrawManager
    ///      could allow LP withdrawals at any time, bypassing the Term Finance maturity timeline.
    ///      Mirror of `TermFinanceBidFuse.TermFinanceBidFuseWithdrawManagerRequired`.
    error TermFinanceRedeemFuseWithdrawManagerRequired();

    /// @notice Reverts when `servicer` is not in the vault substrate allowlist.
    error TermFinanceRedeemFuseUnsupportedMarket(address servicer);
    /// @notice Reverts when `controller.isTermDeployed(servicer)` returns false.
    error TermFinanceRedeemFuseTermNotDeployed(address servicer);
    /// @notice Reverts when `amountToRedeem == 0`.
    error TermFinanceRedeemFuseZeroAmount();
    /// @notice Reverts when `block.timestamp < redemptionTimestamp` on the servicer.
    error TermFinanceRedeemFuseTooEarly(address servicer, uint256 redemptionTimestamp);

    /// @notice Address of this contract instance, used as the version identifier in event logs.
    address public immutable VERSION;
    /// @notice PlasmaVault market id assigned to Term Finance.
    uint256 public immutable MARKET_ID;
    /// @notice Live Term Finance `TermController` proxy.
    address public immutable TERM_CONTROLLER;

    /// @notice Initialise immutables.
    /// @param marketId_ PlasmaVault market id
    /// @param termController_ Term Finance evergreen controller proxy
    constructor(uint256 marketId_, address termController_) {
        if (marketId_ == 0) revert Errors.WrongValue();
        if (termController_ == address(0)) revert Errors.WrongAddress();

        VERSION = address(this);
        MARKET_ID = marketId_;
        TERM_CONTROLLER = termController_;
    }

    function enter(TermFinanceRedeemFuseEnterData calldata data_) external {
        _assertWithdrawManagerSet();
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.servicer)) {
            revert TermFinanceRedeemFuseUnsupportedMarket(data_.servicer);
        }
        if (!IExtTermController(TERM_CONTROLLER).isTermDeployed(data_.servicer)) {
            revert TermFinanceRedeemFuseTermNotDeployed(data_.servicer);
        }
        if (data_.amountToRedeem == 0) revert TermFinanceRedeemFuseZeroAmount();

        uint256 tred = IExtTermRepoServicer(data_.servicer).redemptionTimestamp();
        if (block.timestamp < tred) {
            revert TermFinanceRedeemFuseTooEarly(data_.servicer, tred);
        }

        address purchaseToken = IExtTermRepoServicer(data_.servicer).purchaseToken();
        uint256 balanceBefore = IERC20(purchaseToken).balanceOf(address(this));

        IExtTermRepoServicer(data_.servicer).redeemTermRepoTokens(address(this), data_.amountToRedeem);

        uint256 received = IERC20(purchaseToken).balanceOf(address(this)) - balanceBefore;

        emit TermFinanceRedeemed(VERSION, data_.servicer, data_.amountToRedeem, received);
    }

    /// @notice Reverts unless the vault has a WithdrawManager configured.
    /// @dev Mirror of `TermFinanceBidFuse._assertWithdrawManagerSet`. Reads directly from the
    ///      canonical storage slot via `PlasmaVaultStorageLib.getWithdrawManager()` — during
    ///      fuse delegatecall the slot is read from PlasmaVault storage (the intended context).
    function _assertWithdrawManagerSet() private view {
        if (PlasmaVaultStorageLib.getWithdrawManager().manager == address(0)) {
            revert TermFinanceRedeemFuseWithdrawManagerRequired();
        }
    }
}
