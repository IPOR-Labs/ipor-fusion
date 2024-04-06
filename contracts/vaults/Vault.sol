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
import {IConnectorCommon} from "./IConnectorCommon.sol";
import {MarketConfigurationLib} from "../libraries/MarketConfigurationLib.sol";
import {VaultLib} from "../libraries/VaultLib.sol";

contract Vault is ERC4626Permit, Ownable2Step {
    using Address for address;

    error InvalidKeeper();
    error UnsupportedConnector();

    //TODO: setup Vault type - required for fee

    struct ConnectorAction {
        address connector;
        bytes data;
    }

    struct FuseStruct {
        /// @dev When marketId is 0, then connector is independent to a market - example flashloan connector
        uint256 marketId;
        address fuse;
    }

    struct MarketConfig {
        uint256 marketId;
        /// @dev it could be list of assets or sub markets in a specific protocol or any other ids required to calculate balance in the market (external protocol)
        bytes32[] substrates;
    }

    /// @param assetName Name of the asset
    /// @param assetSymbol Symbol of the asset
    /// @param underlyingToken Address of the underlying token
    /// @param keepers Array of keepers initially granted to execute actions on the vault
    /// @param marketConfigs Array of market configurations
    /// @param fuses Array of connectors
    /// @param balanceFuses Array of balance connectors
    constructor(
        address initialOwner,
        string memory assetName,
        string memory assetSymbol,
        address underlyingToken,
        address[] memory keepers,
        MarketConfig[] memory marketConfigs,
        address[] memory fuses,
        FuseStruct[] memory balanceFuses
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
        for (uint256 i = 0; i < fuses.length; ++i) {
            _addFuse(fuses[i]);
        }

        //TODO: validations supported assets are supported by connectors
        for (uint256 i = 0; i < balanceFuses.length; ++i) {
            _addBalanceFuse(balanceFuses[i]);
        }

        for (uint256 i = 0; i < marketConfigs.length; ++i) {
            MarketConfigurationLib.grandSubstratesToMarket(marketConfigs[i].marketId, marketConfigs[i].substrates);
        }

        ///TODO: when adding new connector - then validate if connector support assets defined for a given vault.
    }

    function totalAssets() public view virtual override returns (uint256) {
        return VaultLib.getTotalAssets();
    }

    function totalAssetsInMarket(uint256 marketId) public view virtual returns (uint256) {
        return VaultLib.getTotalAssetsInMarket(marketId);
    }

    function execute(ConnectorAction[] calldata calls) external returns (bytes[] memory returnData) {
        uint256 callsCount = calls.length;

        returnData = new bytes[](callsCount);

        //TODO: move to transient storage
        uint256[] memory markets = new uint256[](callsCount);
        uint256 marketIndex = 0;

        uint256 connectorMarketId;

        for (uint256 i = 0; i < callsCount; ++i) {
            if (!ConnectorsLib.isConnectorSupported(calls[i].connector)) {
                revert UnsupportedConnector();
            }

            connectorMarketId = IConnectorCommon(calls[i].connector).MARKET_ID();

            if (_checkIfExistsMarket(markets, connectorMarketId) == false) {
                markets[marketIndex] = connectorMarketId;
                marketIndex++;
            }

            returnData[i] = calls[i].connector.functionDelegateCall(calls[i].data);
        }

        _updateBalances(markets);

        return returnData;
    }

    function grantKeeper(address keeper) external onlyOwner {
        _grantKeeper(keeper);
    }

    function revokeKeeper(address keeper) external onlyOwner {
        KeepersLib.revokeKeeper(keeper);
    }

    function isKeeperGranted(address keeper) external view returns (bool) {
        return KeepersLib.isKeeperGranted(keeper);
    }

    function addConnector(address fuse) external onlyOwner {
        _addFuse(fuse);
    }

    function removeConnector(address connector) external onlyOwner {
        ConnectorsLib.removeConnector(connector);
    }

    function isConnectorSupported(address connector) external view returns (bool) {
        return ConnectorsLib.isConnectorSupported(connector);
    }

    function isBalanceConnectorSupported(uint256 marketId, address connector) external view returns (bool) {
        return ConnectorsLib.isBalanceConnectorSupported(marketId, connector);
    }

    function addBalanceFuse(FuseStruct memory fuse) external onlyOwner {
        _addBalanceFuse(fuse);
    }

    function removeBalanceFuse(FuseStruct memory fuseInput) external onlyOwner {
        ConnectorsLib.removeBalanceConnector(fuseInput.marketId, fuseInput.fuse);
    }

    function _addFuse(address fuseInput) internal {
        ConnectorsLib.addConnector(fuseInput);
    }

    function _addBalanceFuse(FuseStruct memory fuseInput) internal {
        ConnectorsLib.setBalanceFuse(fuseInput.marketId, fuseInput.fuse);
    }

    function _grantKeeper(address keeper) internal {
        if (keeper == address(0)) {
            revert InvalidKeeper();
        }

        KeepersLib.grantKeeper(keeper);
    }

    /// marketId and connetcore
    function _checkIfExistsMarket(uint256[] memory markets, uint256 marketId) internal view returns (bool exists) {
        for (uint256 i = 0; i < markets.length; ++i) {
            if (markets[i] == 0) {
                break;
            }
            if (markets[i] == marketId) {
                exists = true;
                break;
            }
        }
    }

    function _updateBalances(uint256[] memory markets) internal {
        uint256 deltas = 0;
        uint256 balanceAmount;
        address balanceAsset;

        for (uint256 i = 0; i < markets.length; ++i) {
            if (markets[i] == 0) {
                break;
            }

            address balanceFuse = ConnectorsLib.getMarketBalanceConnector(markets[i]);

            bytes memory returnedData = balanceFuse.functionDelegateCall(
                abi.encodeWithSignature("balanceOfMarket(address)", address(this))
            );

            (balanceAmount, balanceAsset) = abi.decode(returnedData, (uint256, address));
            deltas = deltas + VaultLib.updateTotalAssetsInMarket(markets[i], balanceAmount);

            //TODO: here use price oracle to convert balanceAmount to underlying token
            ///TODO:.....
        }

        if (deltas != 0) {
            VaultLib.addToTotalAssets(deltas);
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

    function addConnectors(FuseStruct[] calldata fuses) external onlyOwner {
        for (uint256 i = 0; i < fuses.length; ++i) {
            ConnectorsLib.addConnector(fuses[i].fuse);
        }
    }

    function removeConnectors(FuseStruct[] calldata fuses) external onlyOwner {
        for (uint256 i = 0; i < fuses.length; ++i) {
            ConnectorsLib.removeConnector(fuses[i].fuse);
        }
    }
}
