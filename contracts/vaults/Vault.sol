// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626Permit} from "../tokens/ERC4626/ERC4626Permit.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {KeepersLib} from "../libraries/KeepersLib.sol";
import {ConnectorsLib} from "../libraries/ConnectorsLib.sol";
import {AssetsToMarketLib} from "../libraries/AssetsToMarketLib.sol";

contract Vault is ERC4626Permit {
    using Address for address;

    address public constant WST_ETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    struct ConnectorAction {
        address connector;
        bytes data;
    }

    struct ConnectorStruct {
        uint256 marketId;
        address connector;
    }

    struct AssetsMarketStruct {
        uint256 marketId;
        address[] assets;
    }

    /// TODO: move to storage library
//    mapping(address => uint256) public supportedConnectors;

    /// @dev key = concatenate(marketId, asset), value = specific balanceConnector
    /// TODO: move to storage library
//    mapping(bytes32 => address) public balanceConnectors;

    /// @param assetName Name of the asset
    /// @param assetSymbol Symbol of the asset
    /// @param underlyingToken Address of the underlying token
    /// @param keepers Array of keepers initially granted to execute actions on the vault
    /// @param connectors Array of connectors initially granted to be supported by the vault in general
    /// @param balanceConnectors Array of balance connectors initially granted to be supported by the vault for a specific markets, balanceConnectors have to also a part of connectors array
    constructor(
        string memory assetName,
        string memory assetSymbol,
        address underlyingToken,
        address[] memory keepers,
        AssetsMarketStruct[] memory supportedAssetsInMarkets,
        ConnectorStruct[] memory connectors,
        ConnectorStruct[] memory balanceConnectors
    ) ERC4626Permit(IERC20(underlyingToken)) ERC20Permit(assetName) ERC20(assetName, assetSymbol) {
        for (uint256 i = 0; i < keepers.length; ++i) {
            _grantKeeper(keepers[i]);
        }

        //TODO: validations supported assets are supported by connectors
        for (uint256 i = 0; i < connectors.length; ++i) {
            _addConnector(connectors[i]);
        }

        //TODO: validations supported assets are supported by connectors
        for (uint256 i = 0; i < balanceConnectors.length; ++i) {
            _addBalanceConnector(balanceConnectors[i]);
        }

        for (uint256 i = 0; i < supportedAssetsInMarkets.length; ++i) {
            AssetsToMarketLib.grantAssetsToMarket(supportedAssetsInMarkets[i].marketId, supportedAssetsInMarkets[i].assets);
        }

        ///TODO: balance connectors are per market (not per market and asset)
        ///TODO: balacne connectors are determined by marketId from above constructor - taken from configuration in external contract
        ///TODO: when adding new connector - then validate if connector support assets defined for a given vault.
        ///TODO:


    }

    function _addConnector(ConnectorStruct memory connectorInput) internal {
        //TODO: fix it
//        require((ConnectorsLib.isConnectorSupported(connectorInput.connector) == 0), "Vault: connector already supported");
        ConnectorsLib.addConnector(connectorInput.marketId, connectorInput.connector);
    }

    function _addBalanceConnector(ConnectorStruct memory connectorInput) internal {
        ConnectorsLib.addConnector(connectorInput.marketId, connectorInput.connector);
        ConnectorsLib.addBalanceConnector(connectorInput.marketId, connectorInput.connector);
    }

    function _grantKeeper(address keeper) internal {
        require(keeper != address(0), "Vault: invalid keeper");
        KeepersLib.grantKeeper(keeper);
    }

    function execute(ConnectorAction[] calldata calls) external returns (bytes[] memory returnData) {
        uint256 callsCount = calls.length;

        returnData = new bytes[](callsCount);

        for (uint256 i = 0; i < callsCount; ++i) {
            //TODO: fix it
//            require(ConnectorsLib.isConnectorSupported(calls[i].connector), "Vault: unsupported connector");

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

    function addConnectors(ConnectorStruct[] calldata connectors) external {
        for (uint256 i = 0; i < connectors.length; ++i) {
            ConnectorsLib.addConnector(connectors[i].marketId, connectors[i].connector);
        }
    }

    function removeConnectors(ConnectorStruct[] calldata connectors) external {
        for (uint256 i = 0; i < connectors.length; ++i) {
            ConnectorsLib.removeConnector(connectors[i].marketId, connectors[i].connector);
        }
    }
}
