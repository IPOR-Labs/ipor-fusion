// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import "forge-std/console2.sol";
import "./IConnector.sol";
import "./interfaces/IMorpho.sol";
import "./Vault.sol";

/// @dev FlashLoan Connector type does not required information about supported assets
contract FlashLoanMorphoConnector is IConnector {
    address public constant wstEth = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    struct FlashLoanData {
        address token;
        uint256 amount;
        bytes data;
    }

    address public constant morphoAddress = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    IMorpho public constant morphoBlue = IMorpho(morphoAddress);

    function enter(bytes calldata data) external returns (uint256 executionStatus) {
        console2.log("FlashLoanMorphoConnector: ENTER...");
        FlashLoanData memory flashLoanData = abi.decode(data, (FlashLoanData));
        IERC20(flashLoanData.token).approve(morphoAddress, flashLoanData.amount);
        morphoBlue.flashLoan(flashLoanData.token, flashLoanData.amount, flashLoanData.data);
        console2.log("FlashLoanMorphoConnector: END.");
        return 0;
    }

    function exit(bytes calldata data) external returns (uint256 executionStatus) {
        revert("FlashLoanMorphoConnector: exit not supported");
    }

    function onMorphoFlashLoan(uint256 flashLoanAmount, bytes calldata data) external payable {
        console2.log("FlashLoanMorphoConnector: onMorphoFlashLoan");
        uint256 assetBalanceBeforeCalls = IERC20(wstEth).balanceOf(address(this));

        console2.log("assetBalanceBeforeCalls", assetBalanceBeforeCalls);

        Vault.ConnectorAction[] memory calls = abi.decode(data, (Vault.ConnectorAction[]));

        if (calls.length == 0) {
            console2.log("FlashLoanMorphoConnector: no calls to execute");
            return;
        }

        bytes[] memory returnData = Vault(payable(this)).execute(calls);

        uint256 assetBalanceAfterCalls = IERC20(wstEth).balanceOf(address(this));
        console2.log("assetBalanceAfterCalls", assetBalanceAfterCalls);
    }

    receive() external payable {
        revert("FlashLoanMorphoConnector: receive not supported");
    }

    function getSupportedAssets() external view returns (address[] memory assets) {
        return new address[](0);
    }

    function isSupportedAsset(address asset) external view returns (bool) {
        return true;
    }

    function marketId() external view returns (uint256) {
        return 0;
    }
    function marketName() external view returns (string memory) {
        return "";
    }
}
