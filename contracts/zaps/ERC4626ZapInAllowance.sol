// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IERC4626ZapiIn {
    /// @notice Returns the address of the current user performing a zap-in operation
    function currentZapSender() external view returns (address);
}

/// @title ERC4626ZapInAllowance
/// @notice Helper contract for handling token allowances in ERC4626 zap-in operations
/// @dev This contract acts as an intermediary for token transfers in the zap-in process
contract ERC4626ZapInAllowance {
    using SafeERC20 for IERC20;

    /// @notice Address of the ERC4626ZapIn contract
    address public immutable ERC4626_ZAP_IN;

    error NotERC4626ZapIn();
    error AmountIsZero();
    error AssetIsZero();
    error CurrentZapSenderIsZero();
    error EthTransfersNotAccepted();

    /// @notice Emitted when assets are fetched from a user
    /// @param from Address from which the assets are fetched
    /// @param asset Address of the token being fetched
    /// @param amount Amount of tokens being fetched
    event AssetsTransferred(address indexed from, address indexed asset, uint256 amount);

    /// @notice Constructs the ERC4626ZapInAllowance contract
    /// @param erc4626ZapIn_ Address of the ERC4626ZapIn contract
    constructor(address erc4626ZapIn_) {
        ERC4626_ZAP_IN = erc4626ZapIn_;
    }

    /// @notice Fetches approved tokens from a user to the ERC4626ZapIn contract
    /// @param asset_ Address of the token to fetch
    /// @param amount_ Amount of tokens to fetch
    /// @return success True if the transfer was successful
    function transferApprovedAssets(address asset_, uint256 amount_) external OnlyERC4626ZapIn returns (bool success) {
        if (amount_ == 0) {
            revert AmountIsZero();
        }

        if (asset_ == address(0)) {
            revert AssetIsZero();
        }

        address currentZapSender = IERC4626ZapiIn(ERC4626_ZAP_IN).currentZapSender();

        if (currentZapSender == address(0)) {
            revert CurrentZapSenderIsZero();
        }

        IERC20(asset_).safeTransferFrom(currentZapSender, ERC4626_ZAP_IN, amount_);

        emit AssetsTransferred(currentZapSender, asset_, amount_);
        return true;
    }

    receive() external payable {
        revert EthTransfersNotAccepted();
    }

    fallback() external payable {
        revert EthTransfersNotAccepted();
    }

    modifier OnlyERC4626ZapIn() {
        if (msg.sender != ERC4626_ZAP_IN) {
            revert NotERC4626ZapIn();
        }
        _;
    }
}
