// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "forge-std/console2.sol";

contract Vault is ERC4626 {
    using Address for address;

    address public constant wstEth = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    struct ConnectorAction {
        address connector;
        bytes data;
    }

    mapping(address => uint256) public supportedConnectors;

    constructor(
        string memory assetName,
        string memory assetSymbol,
        address underlyingToken
    ) ERC4626(IERC20Metadata(underlyingToken)) ERC20(assetName, assetSymbol) {}

    function execute(
        ConnectorAction[] calldata calls
    ) external returns (bytes[] memory returnData) {
        console2.log("Vault: EXECUTE START...");
        uint256 callsCount = calls.length;

        returnData = new bytes[](callsCount);

        for (uint256 i = 0; i < callsCount; ++i) {
            require(
                supportedConnectors[calls[i].connector] == 1,
                "Vault: unsupported connector"
            );
            console2.log("Vault: calls[i].connector", calls[i].connector);

            returnData[i] = calls[i].connector.functionDelegateCall(
                calls[i].data
            );
        }

        console2.log("Vault: EXECUTE END.");

        return returnData;
    }

    /// TODO: use in connector when connector configurator contract is ready
    function onMorphoFlashLoan(
        uint256 flashLoanAmount,
        bytes calldata data
    ) external payable {
        console2.log("VAULT FlashLoanMorphoConnector: onMorphoFlashLoan");
        uint256 assetBalanceBeforeCalls = IERC20(wstEth).balanceOf(
            payable(this)
        );

        console2.log(
            "VAULT FlashLoanMorphoConnector: assetBalanceBeforeCalls",
            assetBalanceBeforeCalls
        );

        ConnectorAction[] memory calls = abi.decode(data, (ConnectorAction[]));

        if (calls.length == 0) {
            console2.log("FlashLoanMorphoConnector: no calls to execute");
            return;
        }

        bytes[] memory returnData = Vault(payable(this)).execute(calls);

        uint256 assetBalanceAfterCalls = IERC20(wstEth).balanceOf(
            payable(this)
        );
        console2.log(
            "VAULT FlashLoanMorphoConnector: assetBalanceAfterCalls",
            assetBalanceAfterCalls
        );
    }

    receive() external payable {}

    fallback() external {
        ///TODO: read msg.sender (if Morpho) and read method signature to determine connector address to execute delegate call on method onMorphoFlashLoan
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
