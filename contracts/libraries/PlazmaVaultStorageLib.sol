// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

/// @title Storage
library PlazmaVaultStorageLib {
    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.plazmaVaultTotalAssetsInAllMarkets")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant PLAZMA_VAULT_TOTAL_ASSETS_IN_ALL_MARKETS =
        0x5a03fb3ee5c2b8e397013e1f4a344208b3193b25fa29ae6c2cda3db858454700;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.plazmaVaultTotalAssetsInMarket")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant PLAZMA_VAULT_TOTAL_ASSETS_IN_MARKET =
        0xe242383a5553e6ba2476f2482afc0944276473bfda72ea3703579c6a32bd3500;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.plazmaVaultMarketConfiguration")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant MARKET_CONFIGURATION = 0xd5bdc7559e360e9c73313f6862fc65997a8cda8dafe6ecfa240156ec11864100;

    /// --------------

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.globalCfgMarkets")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant GLOBAL_CFG_MARKETS = 0x357d32c408459d6b4515886adc12a53a5cea792ef64d96e1a6de5be310df6800;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.globalCfgMarketsArray")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant GLOBAL_CFG_MARKETS_ARRAY =
        0xa9ab0f59d22adb63c5e64506bd16f6182bc321006c1f7ff0dcb1b445a2fd5400;

    /// @notice List of alphas allowed to execute actions on the vault
    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.alphas")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant ALPHAS = 0x6e63fd334756476008e18320c17a15b90685bef378a9769b941259f22b716400;

    /// @notice List of fuses ass
    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fuses")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant FUSES = 0x8aea6b6f6aa5634a831e026b11b303364a06768c46e3d2947b4fd826fe672900;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fusesArray")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant FUSES_ARRAY = 0xba14be3a97cf2f8b4d597466152c4a1f5bd0a3391c168df3545415b0818dc800;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.balanceFuses")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant BALANCE_FUSES = 0x79c8c92d14d4269e7b571a09af2cbe14b4b7cb5d7081dd3cc58334735482cf00;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.marketBalanceFuses")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant MARKET_BALANCE_FUSES = 0x3ddfefcd740eb895c0ab40938b57a412bbd0e50288e41524dda256641368a700;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.balanceFusesArray")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant BALANCE_FUSES_ARRAY = 0xc8e943b00e69c68afc4d0f8d07f8c1977c720a201f28d8f41b019a8cdd242900;

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

    /// @notice Space in storage to store the market configuration for a given PlazmaVault
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

    /// @custom:storage-location erc7201:io.ipor.alphas
    struct Alphas {
        /// @dev alpha address => 1 - is granted, otherwise - not granted
        mapping(address => uint256) value;
    }

    struct Fuses {
        /// @dev =fuse address => 1 - is granted, otherwise - not granted
        mapping(address => uint256) value;
    }

    struct MarketBalanceFuses {
        /// @dev marketId => balance fuse address
        mapping(uint256 => address) value;
    }

    struct FusesArray {
        /// @dev value is a fuse address
        address[] value;
    }

    struct BalanceFusesArray {
        /// @dev value is a marketId and fuse address: keccak256(abi.encode(marketId, fuse))
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

    function getAlphas() internal pure returns (Alphas storage alphas) {
        assembly {
            alphas.slot := ALPHAS
        }
    }

    function getFuses() internal pure returns (Fuses storage fuses) {
        assembly {
            fuses.slot := FUSES
        }
    }

    function getMarketBalanceFuses() internal pure returns (MarketBalanceFuses storage marketBalanceFuses) {
        assembly {
            marketBalanceFuses.slot := MARKET_BALANCE_FUSES
        }
    }

    ///TODO: confirm if needed
    function getFusesArray() internal pure returns (FusesArray storage fusesArray) {
        assembly {
            fusesArray.slot := FUSES_ARRAY
        }
    }

    //TODO: confirm if needed
    function getBalanceFusesArray() internal pure returns (BalanceFusesArray storage balanceFusesArray) {
        assembly {
            balanceFusesArray.slot := BALANCE_FUSES_ARRAY
        }
    }

    function getVaultTotalAssets() internal pure returns (VaultTotalAssets storage vaultTotalAssets) {
        assembly {
            vaultTotalAssets.slot := PLAZMA_VAULT_TOTAL_ASSETS_IN_ALL_MARKETS
        }
    }

    function getVaultMarketTotalAssets() internal pure returns (VaultMarketTotalAssets storage vaultMarketTotalAssets) {
        assembly {
            vaultMarketTotalAssets.slot := PLAZMA_VAULT_TOTAL_ASSETS_IN_MARKET
        }
    }
}
