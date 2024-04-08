// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

/// @title Storage
library VaultStorageLib {
    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.vaultTotalAssets")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant VAULT_TOTAL_ASSETS = 0x357d32c408459d6b4515886adc12a53a5cea792ef64d96e1a6de5be310df6800;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.vaultMarketTotalAssets")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant VAULT_MARKET_TOTAL_ASSETS =
        0xc6a86114ffcf09bc9efb3cc43636220a50177b2dd24c2e11f6f3c549ab662600;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.vaultMarketConfiguration")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant MARKET_CONFIGURATION = 0xde0ed8ff1d9b0e8c557d6f5222521c90408a837fe441ce1ebbb1b1425d9b0f00;

    /// --------------

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.globalCfgMarkets")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant GLOBAL_CFG_MARKETS = 0x357d32c408459d6b4515886adc12a53a5cea792ef64d96e1a6de5be310df6800;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.globalCfgMarketsArray")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant GLOBAL_CFG_MARKETS_ARRAY =
        0xa9ab0f59d22adb63c5e64506bd16f6182bc321006c1f7ff0dcb1b445a2fd5400;

    /// @notice List of keepers allowed to execute actions on the vault
    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.keepers")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant KEEPERS = 0x7dd7151eda9a8aa729c84433daab8cd1eaf1f4ce42af566ab5ad0e56a8023100;

    /// @notice List of connectors ass
    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.commandConnectors")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant CONNECTORS = 0x8df706fc41a6e9ea82576edcbe6c0508c833d6c213c8726956c1b91cfc40df00;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.connectorsArray")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant CONNECTORS_ARRAY = 0xfc45338140a0465eb8fe9e6810faefca6449a87e343df9e2e6431bb075b65500;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.balanceConnectors")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant BALANCE_CONNECTORS = 0x5a5829737eca653c0b5b4a20468c03c7bec2bc961055a682ab2b91dff4463a00;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.marketBalanceConnectors")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant MARKET_BALANCE_CONNECTORS =
        0xeba9231169beda60a3a6e498152686285436fed40abcb5feb85c88b510ca8b00;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.balanceConnectorsArray")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant BALANCE_CONNECTORS_ARRAY =
        0x1fc2ff582e84eb55aac3390e0ea40e2b04f7ca631b7916a8c1670711fd11f600;

    /// @notice Global configuration of markets
    struct GlobalCfgMarkets {
        /// @dev marketId => name
        mapping(uint256 => string) value;
    }

    /// @dev Iterable array of marketIds, associated with the structure GlobalCfgMarkets
    struct GlobalCfgMarketsArray {
        /// @dev array of marketIds
        //TODO: change to bytes32
        uint256[] value;
    }

    /// @notice Market configuration
    /// @dev Substrate - abstract item in the market, could be asset or sub market in the external protocol, it could be any item required to calculate balance in the market
    struct MarketStruct {
        /// @notice Define which substrates are allowed and supported in the market
        /// @dev key can be specific asset or sub market in a specific external protocol (market), value - 1 - granted, otherwise - not granted
        mapping(bytes32 => uint256) substrateAllowances;
        /// @dev it could be list of assets or sub markets in a specific protocol or any other ids required to calculate balance in the market (external protocol)
        bytes32[] substrates;
    }

    struct MarketConfiguration {
        /// @dev marketId => MarketStruct
        mapping(uint256 => MarketStruct) value;
    }

    function getMarketConfiguration() internal pure returns (MarketConfiguration storage marketConfiguration) {
        assembly {
            marketConfiguration.slot := MARKET_CONFIGURATION
        }
    }

    struct VaultTotalAssets {
        /// @dev total assets in the vault
        uint256 value;
    }

    struct VaultMarketTotalAssets {
        /// @dev marketId => total assets in the vault in the market
        mapping(uint256 => uint256) value;
    }

    /// @custom:storage-location erc7201:io.ipor.keepers
    struct Keepers {
        /// @dev keeper address => 1 - is granted, otherwise - not granted
        mapping(address => uint256) value;
    }

    struct Connectors {
        /// @dev =connector address => 1 - is granted, otherwise - not granted
        mapping(address => uint256) value;
    }

    struct MarketBalanceConnectors {
        /// @dev marketId => balance connector address
        mapping(uint256 => address) value;
    }

    struct ConnectorsArray {
        /// @dev value is a connector address
        address[] value;
    }

    struct BalanceConnectorsArray {
        /// @dev value is a marketId and connector address: keccak256(abi.encode(marketId, connector))
        bytes32[] value;
    }

    function getGlobalCfgMarkets() internal pure returns (GlobalCfgMarkets storage globalCfgMarkets) {
        assembly {
            globalCfgMarkets.slot := GLOBAL_CFG_MARKETS
        }
    }

    function getGlobalCfgMarketsArray() internal pure returns (GlobalCfgMarketsArray storage globalCfgMarketsArray) {
        assembly {
            globalCfgMarketsArray.slot := GLOBAL_CFG_MARKETS_ARRAY
        }
    }

    function getKeepers() internal pure returns (Keepers storage keepers) {
        assembly {
            keepers.slot := KEEPERS
        }
    }

    function getConnectors() internal pure returns (Connectors storage connectors) {
        assembly {
            connectors.slot := CONNECTORS
        }
    }

    function getMarketBalanceConnectors()
        internal
        pure
        returns (MarketBalanceConnectors storage marketBalanceConnectors)
    {
        assembly {
            marketBalanceConnectors.slot := MARKET_BALANCE_CONNECTORS
        }
    }

    ///TODO: confirm if needed
    function getConnectorsArray() internal pure returns (ConnectorsArray storage connectorsArray) {
        assembly {
            connectorsArray.slot := CONNECTORS_ARRAY
        }
    }

    //TODO: confirm if needed
    function getBalanceConnectorsArray() internal pure returns (BalanceConnectorsArray storage balanceConnectorsArray) {
        assembly {
            balanceConnectorsArray.slot := BALANCE_CONNECTORS_ARRAY
        }
    }

    function getVaultTotalAssets() internal pure returns (VaultTotalAssets storage vaultTotalAssets) {
        assembly {
            vaultTotalAssets.slot := VAULT_TOTAL_ASSETS
        }
    }

    function getVaultMarketTotalAssets() internal pure returns (VaultMarketTotalAssets storage vaultMarketTotalAssets) {
        assembly {
            vaultMarketTotalAssets.slot := VAULT_MARKET_TOTAL_ASSETS
        }
    }
}
