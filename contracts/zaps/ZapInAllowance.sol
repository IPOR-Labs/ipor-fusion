// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IporFusionZapIn {
    /// @notice Returns the address of the current user performing a zap-in operation
    function currentZapSender() external view returns (address);
}

/// @title ZapInAllowance
/// @notice Helper contract for handling token allowances in IporFusionZapIn
/// @dev This contract acts as an intermediary for token transfers in the zap-in process
contract ZapInAllowance {
    using SafeERC20 for IERC20;

    /// @notice Address of the IporFusionZapIn contract
    address public immutable IPOR_FUSION_ZAP_IN;

    error OnlyIPORFusionZapIn();
    error AmountIsZero();
    error AssetIsZero();
    error CurrentZapSenderIsZero();
    error EthTransfersNotAccepted();

    /// @notice Emitted when assets are fetched from a user
    /// @param from Address from which the assets are fetched
    /// @param asset Address of the token being fetched
    /// @param amount Amount of tokens being fetched
    event FetchAssets(address indexed from, address indexed asset, uint256 amount);

    /// @notice Constructs the ZapInAllowance contract
    /// @param iporFusionZapIn_ Address of the IporFusionZapIn contract
    constructor(address iporFusionZapIn_) {
        IPOR_FUSION_ZAP_IN = iporFusionZapIn_;
    }

    /// @notice Fetches approved tokens from a user to the IporFusionZapIn contract
    /// @param asset_ Address of the token to fetch
    /// @param amount_ Amount of tokens to fetch
    /// @return success True if the transfer was successful
    function fetchAssets(address asset_, uint256 amount_) external onlyIPORFusionZapIn returns (bool success) {
        if (amount_ == 0) {
            revert AmountIsZero();
        }

        if (asset_ == address(0)) {
            revert AssetIsZero();
        }

        address currentZapSender = IporFusionZapIn(IPOR_FUSION_ZAP_IN).currentZapSender();

        if (currentZapSender == address(0)) {
            revert CurrentZapSenderIsZero();
        }

        IERC20(asset_).safeTransferFrom(currentZapSender, IPOR_FUSION_ZAP_IN, amount_);

        emit FetchAssets(currentZapSender, asset_, amount_);
        return true;
    }

    receive() external payable {
        revert EthTransfersNotAccepted();
    }

    fallback() external payable {
        revert EthTransfersNotAccepted();
    }

    modifier onlyIPORFusionZapIn() {
        if (msg.sender != IPOR_FUSION_ZAP_IN) {
            revert OnlyIPORFusionZapIn();
        }
        _;
    }
}
