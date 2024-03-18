// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {IConnector} from "./IConnector.sol";
import {IMorpho} from "./interfaces/IMorpho.sol";
import {Vault} from "./Vault.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev FlashLoan Connector type does not required information about supported assets
contract FlashLoanMorphoConnector is IConnector {
    address public constant WST_ETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    struct FlashLoanData {
        address token;
        uint256 amount;
        bytes data;
    }

    address public constant MORPHO_ADDRESS = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    IMorpho public constant MORPHO_BLUE = IMorpho(MORPHO_ADDRESS);

    function enter(bytes calldata data) external returns (uint256 executionStatus) {
        FlashLoanData memory flashLoanData = abi.decode(data, (FlashLoanData));
        IERC20(flashLoanData.token).approve(MORPHO_ADDRESS, flashLoanData.amount);
        MORPHO_BLUE.flashLoan(flashLoanData.token, flashLoanData.amount, flashLoanData.data);
        return 0;
    }

    // todo remove solhint disable
    //solhint-disable-next-line
    function exit(bytes calldata data) external returns (uint256 executionStatus) {
        // todo remove solhint disable
        //solhint-disable-next-line
        revert("FlashLoanMorphoConnector: exit not supported");
    }

    // todo remove solhint disable
    //solhint-disable-next-line
    function onMorphoFlashLoan(uint256 flashLoanAmount, bytes calldata data) external payable {
        //        uint256 assetBalanceBeforeCalls = IERC20(WST_ETH).balanceOf(address(this));

        Vault.ConnectorAction[] memory calls = abi.decode(data, (Vault.ConnectorAction[]));

        if (calls.length == 0) {
            return;
        }

        Vault(payable(this)).execute(calls);

        //        uint256 assetBalanceAfterCalls = IERC20(WST_ETH).balanceOf(address(this));
    }

    receive() external payable {
        // todo remove solhint disable
        //solhint-disable-next-line
        revert("FlashLoanMorphoConnector: receive not supported");
    }

    function getSupportedAssets() external view returns (address[] memory assets) {
        return new address[](0);
    }

    // todo remove solhint disable
    //solhint-disable-next-line
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
