// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ILeverageZapper} from "./ILeverageZapper.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

/// @notice Minimal adapter to bridge between Vault-held WETH and zappers requiring native ETH.
/// Only the PlasmaVault may call this (enforced by onlyVault).
contract WethEthAdapter {
    using SafeERC20 for IERC20;
    using Address for address payable;

    address public immutable VAULT;
    address public immutable WETH;

    error InsufficientEthSpent();
    error NotVault();
    error ZapperCallFailed();

    modifier onlyVault() {
        if (msg.sender != VAULT) revert NotVault();
        _;
    }

    constructor(address vault, address weth) {
        VAULT = vault;
        WETH = weth;
    }

    /// @notice Unwrap `wethAmount_` from the VAULT to ETH and call `zapper` with that ETH.
    /// @param params_ the open trove params to call the zapper with
    /// @param zapper_ the address of the zapper to call
    /// @param wethAmount_ the WETH to deposit to Zapper as compensation
    function callZapperWithEth(
        ILeverageZapper.OpenLeveragedTroveParams calldata params_,
        address zapper_,
        uint256 wethAmount_
    ) external onlyVault {
        IWETH(WETH).withdraw(wethAmount_);

        IERC20 collToken = IERC20(ILeverageZapper(zapper_).collToken());

        collToken.forceApprove(zapper_, params_.collAmount);

        ILeverageZapper(zapper_).openLeveragedTroveWithRawETH{value: wethAmount_}(params_);

        collToken.forceApprove(zapper_, 0);
        // transfer everything left to vault
        uint256 remainsColl = collToken.balanceOf(address(this));
        if (remainsColl > 0) {
            collToken.safeTransfer(VAULT, remainsColl);
        }
    }

    /// @notice Call zapper expecting it to return ETH here; wrap all and send WETH and collaterals to VAULT.
    /// This happens when the debt is repaid, therefore ebusd is transferred to zapper rather than collateral.
    /// Collateral will also be sent here when debt is repaid, thus we need to transfer it to the VAULT.
    function callZapperExpectEthBack(
        address zapper_,
        bool exitFromCollateral_,
        uint256 troveId_,
        uint256 flashLoanAmount_,
        uint256 minExpectedCollateral_
    ) external onlyVault {
        IERC20 ebusdToken = IERC20(ILeverageZapper(zapper_).boldToken());
        IERC20 collToken = IERC20(ILeverageZapper(zapper_).collToken());

        ebusdToken.forceApprove(zapper_, type(uint256).max);

        exitFromCollateral_ ? 
            ILeverageZapper(zapper_).closeTroveFromCollateral(troveId_, flashLoanAmount_, minExpectedCollateral_) :
            ILeverageZapper(zapper_).closeTroveToRawETH(troveId_);

        ebusdToken.forceApprove(zapper_, 0);

        uint256 remainsEbusd = ebusdToken.balanceOf(address(this));
        uint256 remainsColl = collToken.balanceOf(address(this));
        uint256 bal = address(this).balance;
        if (bal > 0) {
            IWETH(WETH).deposit{value: bal}();
            IERC20(WETH).safeTransfer(VAULT, bal);
        }
        if (remainsEbusd > 0) {
            ebusdToken.safeTransfer(VAULT, remainsEbusd);
        }
        if (remainsColl > 0) {
            collToken.safeTransfer(VAULT, remainsColl);
        }
    }

    receive() external payable {}
}
