// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ILeverageZapper} from "./ext/ILeverageZapper.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

/// @notice Minimal adapter to bridge between Vault-held WETH and zappers requiring native ETH.
/// Only the PlasmaVault may call this (enforced by onlyVault).
contract WethEthAdapter {
    using SafeERC20 for ERC20;
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

    /// @notice Unwrap `wethAmount` from the VAULT to ETH and call `zapper` with that ETH.
    /// Any ETH left after call is wrapped back to WETH and returned to the VAULT.
    function callZapperWithEth(
        address zapper,
        bytes calldata callData,
        uint256 collAmount,
        uint256 wethAmount,
        uint256 minEthToSpend
    ) external onlyVault {
        // Unwrap to ETH
        IWETH(WETH).withdraw(wethAmount);
        uint256 beforeBalance = address(this).balance;

        ERC20 collToken = ERC20(ILeverageZapper(zapper).collToken());

        collToken.forceApprove(zapper, collAmount);

        (bool ok, ) = zapper.call{value: wethAmount}(callData);
        if(!ok) revert ZapperCallFailed();
        
        collToken.forceApprove(zapper, 0);

        // Wrap any ETH that returned here (refunds / proceeds)
        uint256 afterBalance = address(this).balance;
        uint256 ethLeft = afterBalance;

        // Safety: ensure at least minEthToSpend was actually consumed
        uint256 spent = beforeBalance + wethAmount > afterBalance ? (beforeBalance + wethAmount - afterBalance) : 0;
        if(spent < minEthToSpend) revert InsufficientEthSpent();

        if (ethLeft > 0) {
            IWETH(WETH).deposit{value: ethLeft}();
            IERC20(WETH).transfer(VAULT, ethLeft);
        }
    }

    /// @notice Call zapper expecting it to return ETH here; wrap all and send WETH and collaterals to VAULT.
    /// This happens when the debt is repaid, therefore ebusd is transferred to zapper rather than collateral.
    /// Collateral will also be sent here when debt is repaid, thus we need to transfer it to the VAULT.
    function callZapperExpectEthBack(
        address zapper,
        bytes calldata callData
    ) external onlyVault {
        ERC20 ebusdToken = ERC20(ILeverageZapper(zapper).boldToken());
        ERC20 collToken = ERC20(ILeverageZapper(zapper).collToken());

        ebusdToken.forceApprove(zapper, type(uint256).max);

        (bool ok, ) = zapper.call(callData);
        if(!ok) revert ZapperCallFailed();

        ebusdToken.forceApprove(zapper, 0);

        uint256 remainsEbusd = ebusdToken.balanceOf(address(this));
        uint256 remainsColl = collToken.balanceOf(address(this));
        uint256 bal = address(this).balance;
        if (bal > 0) {
            IWETH(WETH).deposit{value: bal}();
            IERC20(WETH).transfer(VAULT, bal);
        }
        if (remainsEbusd > 0) {
            ebusdToken.transfer(VAULT, remainsEbusd);
        }
        if (remainsColl > 0) {
            collToken.transfer(VAULT, remainsColl);
        }
    }

    receive() external payable {}
}
