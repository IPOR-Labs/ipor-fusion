// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ERC4626Permit} from "../tokens/ERC4626/ERC4626Permit.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {KeepersLib} from "../libraries/KeepersLib.sol";
import {ConnectorsLib} from "../libraries/ConnectorsLib.sol";
import {AssetsToMarketLib} from "../libraries/AssetsToMarketLib.sol";
import {IConnectorCommon} from "./IConnectorCommon.sol";

contract Vault is ERC4626Permit, Ownable2Step {
    using Address for address;

    error InvalidKeeper();
    error UnsupportedConnector();

    //TODO: setup Vault type - required for fee

    struct ConnectorAction {
        address connector;
        bytes data;
    }

    struct ConnectorStruct {
        /// @dev When marketId is 0, then connector is supported for all markets - example flashloan connector
        uint256 marketId;
        address connector;
    }

    struct AssetsMarketStruct {
        uint256 marketId;
        address[] assets;
    }

    /// @param assetName Name of the asset
    /// @param assetSymbol Symbol of the asset
    /// @param underlyingToken Address of the underlying token
    /// @param keepers Array of keepers initially granted to execute actions on the vault
    /// @param connectors Array of connectors initially granted to be supported by the vault in general
    /// @param balanceConnectors Array of balance connectors initially granted to be supported by the vault for a specific markets, balanceConnectors have to also a part of connectors array
    constructor(
        address initialOwner,
        string memory assetName,
        string memory assetSymbol,
        address underlyingToken,
        address[] memory keepers,
        AssetsMarketStruct[] memory supportedAssetsInMarkets,
        ConnectorStruct[] memory connectors,
        ConnectorStruct[] memory balanceConnectors
    )
        ERC4626Permit(IERC20(underlyingToken))
        ERC20Permit(assetName)
        ERC20(assetName, assetSymbol)
        Ownable(initialOwner)
    {
        for (uint256 i; i < keepers.length; ++i) {
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
            AssetsToMarketLib.grantAssetsToMarket(
                supportedAssetsInMarkets[i].marketId,
                supportedAssetsInMarkets[i].assets
            );
        }

        ///TODO: when adding new connector - then validate if connector support assets defined for a given vault.
    }

    function _addConnector(ConnectorStruct memory connectorInput) internal {
        ConnectorsLib.addConnector(connectorInput.connector);
    }

    function _addBalanceConnector(ConnectorStruct memory connectorInput) internal {
        ConnectorsLib.addBalanceConnector(connectorInput.marketId, connectorInput.connector);
    }

    function _grantKeeper(address keeper) internal {
        if (keeper == address(0)) {
            revert InvalidKeeper();
        }

        KeepersLib.grantKeeper(keeper);
    }

    function execute(ConnectorAction[] calldata calls) external returns (bytes[] memory returnData) {
        uint256 callsCount = calls.length;

        returnData = new bytes[](callsCount);

        uint256[] memory markets = new uint256[](callsCount);
        uint256 marketIndex = 0;

        for (uint256 i = 0; i < callsCount; ++i) {
            if (ConnectorsLib.isConnectorSupported(calls[i].connector)) {
                revert UnsupportedConnector();
            }

            uint256 connectorMarketId = IConnectorCommon(calls[i].connector).MARKET_ID();

            if (_checkIfExistsMarket(markets, connectorMarketId) == false) {
                markets[marketIndex] = connectorMarketId;
                marketIndex++;
            }

            returnData[i] = calls[i].connector.functionDelegateCall(calls[i].data);
        }

        _updateBalances(markets);

        return returnData;
    }

    /// marketId and connetcore
    function _checkIfExistsMarket(uint256[] memory markets, uint256 marketId) internal view returns (bool exists) {
        for (uint256 i = 0; i < markets.length; ++i) {
            if (markets[i] == 0) {
                break;
            }
            if (markets[i] == marketId) {
                exists = true;
            }
        }
    }

    function _updateBalances(uint256[] memory markets) internal {
//        mapping(uint256 => address) storage marketBalances;

        for (uint256 i = 0; i < markets.length; ++i) {
            if (markets[i] == 0) {
                break;
            }
            //            marketBalances[markets[i]] = IConnectorBalanceOf(ConnectorsLib.getMarketBalanceConnectors().value[markets[i]]).balanceOfMarket(
            //                address(this),
            //
            //            );
            ConnectorsLib.updateBalance(markets[i]);
        }
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

    function addConnectors(ConnectorStruct[] calldata connectors) external onlyOwner {
        for (uint256 i = 0; i < connectors.length; ++i) {
            ConnectorsLib.addConnector(connectors[i].connector);
        }
    }

    function removeConnectors(ConnectorStruct[] calldata connectors) external onlyOwner {
        for (uint256 i = 0; i < connectors.length; ++i) {
            ConnectorsLib.removeConnector(connectors[i].connector);
        }
    }
}
