// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {ERC4626Permit} from "../tokens/ERC4626/ERC4626Permit.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

contract Vault is ERC4626Permit {
    using Address for address;

    address public constant WST_ETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    struct ConnectorAction {
        address connector;
        bytes data;
    }

    struct BalanceConnector {
        uint256 marketId;
        address connector;
    }

    /// TODO: move to storage library
    mapping(address => uint256) public supportedConnectors;

    /// @dev key = concatenate(marketId, asset), value = specific balanceConnector
    /// TODO: move to storage library
    mapping(bytes32 => address) public balanceConnectors;

    constructor(
        string memory assetName,
        string memory assetSymbol,
        address underlyingToken,
        address[] memory keepers,
        uint256[] memory connectors,
        uint256[] memory balanceConnectors
    ) ERC4626Permit(IERC20(underlyingToken)) ERC20Permit(assetName) ERC20(assetName, assetSymbol) {
        ///TODO: balance connectors are per market (not per market and asset)
        ///TODO: balacne connectors are determined by marketId from above constructor - taken from configuration in external contract
        ///TODO: when adding new connector - then validate if connector support assets defined for a given vault.
        ///TODO:


    }

    function execute(ConnectorAction[] calldata calls) external returns (bytes[] memory returnData) {
        uint256 callsCount = calls.length;

        returnData = new bytes[](callsCount);

        for (uint256 i = 0; i < callsCount; ++i) {
            require(supportedConnectors[calls[i].connector] == 1, "Vault: unsupported connector");

            returnData[i] = calls[i].connector.functionDelegateCall(calls[i].data);
        }

        return returnData;
    }

    /// TODO: use in connector when connector configurator contract is ready
    //solhint-disable-next-line
    function onMorphoFlashLoan(uint256 flashLoanAmount, bytes calldata data) external payable {
        //        uint256 assetBalanceBeforeCalls = IERC20(WST_ETH).balanceOf(payable(this));

        ConnectorAction[] memory calls = abi.decode(data, (ConnectorAction[]));

        if (calls.length == 0) {
            return;
        }

        Vault(payable(this)).execute(calls);

        //        uint256 assetBalanceAfterCalls = IERC20(WST_ETH).balanceOf(payable(this));
    }

    receive() external payable {}

    fallback() external {
        ///TODO: read msg.sender (if Morpho) and read method signature to determine connector address to execute
        /// delegate call on method onMorphoFlashLoan
        /// separate contract with configuration which connector use which flashloan method and protocol
    }

    function addConnectors(address[] calldata connectors) external {
        for (uint256 i = 0; i < connectors.length; ++i) {
            supportedConnectors[connectors[i]] = 1;
        }
    }

    function removeConnectors(address[] calldata connectors) external {
        for (uint256 i = 0; i < connectors.length; ++i) {
            supportedConnectors[connectors[i]] = 0;
        }
    }
}
