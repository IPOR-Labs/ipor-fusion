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

    /// @notice List of alphas allowed to execute actions on the vault
    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.alphas")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant CFG_PLAZMA_VAULT_ALPHAS =
        0x6e63fd334756476008e18320c17a15b90685bef378a9769b941259f22b716400;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.cfgPlazmaVaultMarketSubstrates")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant CFG_PLAZMA_VAULT_MARKET_SUBSTRATES =
        0xd5bdc7559e360e9c73313f6862fc65997a8cda8dafe6ecfa240156ec11864100;

    /// @notice List of fuses ass
    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fuses")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant CFG_PLAZMA_VAULT_FUSES =
        0x8aea6b6f6aa5634a831e026b11b303364a06768c46e3d2947b4fd826fe672900;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fusesArray")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant CFG_PLAZMA_VAULT_FUSES_ARRAY =
        0xba14be3a97cf2f8b4d597466152c4a1f5bd0a3391c168df3545415b0818dc800;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.cfgPlazmaVaultBalanceFuses")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant CFG_PLAZMA_VAULT_BALANCE_FUSES =
        0x79c8c92d14d4269e7b571a09af2cbe14b4b7cb5d7081dd3cc58334735482cf00;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.cfgPlazmaVaultBalanceFusesArray")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant CFG_PLAZMA_VAULT_BALANCE_FUSES_ARRAY =
        0xc8e943b00e69c68afc4d0f8d07f8c1977c720a201f28d8f41b019a8cdd242900;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.cfgPlazmaVaultInstantWithdrawalFusesArray")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant CFG_PLAZMA_VAULT_INSTANT_WITHDRAWAL_FUSES_ARRAY =
        0x1a6ddb1ce5f4f320920a4c0f528489c050b900038d1d9389d5273ce4a6988900;

    /// @notice Every fuse has a list of parameters used for instant withdrawal
    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.cfgPlazmaVaultInstantWithdrawalFusesParams")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant CFG_PLAZMA_VAULT_INSTANT_WITHDRAWAL_FUSES_PARAMS =
        0x397ee58b336520b7a796c422a0927e1600c688e25e66430186a8ab1f395b6500;

    struct TotalAssets {
        /// @dev total assets in the vault
        uint256 value;
    }

    struct MarketTotalAssets {
        /// @dev marketId => total assets in the vault in the market
        mapping(uint256 => uint256) value;
    }

    /// @custom:storage-location erc7201:io.ipor.alphas
    struct Alphas {
        /// @dev alpha address => 1 - is granted, otherwise - not granted
        mapping(address => uint256) value;
    }

    /// @notice Market Substrates configuration
    /// @dev Substrate - abstract item in the market, could be asset or sub market in the external protocol, it could be any item required to calculate balance in the market
    struct MarketSubstratesStruct {
        /// @notice Define which substrates are allowed and supported in the market
        /// @dev key can be specific asset or sub market in a specific external protocol (market), value - 1 - granted, otherwise - not granted
        mapping(bytes32 => uint256) substrateAllowances;
        /// @dev it could be list of assets or sub markets in a specific protocol or any other ids required to calculate balance in the market (external protocol)
        bytes32[] substrates;
    }

    struct MarketSubstrates {
        /// @dev marketId => MarketSubstratesStruct
        mapping(uint256 => MarketSubstratesStruct) value;
    }

    struct Fuses {
        /// @dev =fuse address => 1 - is granted, otherwise - not granted
        mapping(address => uint256) value;
    }

    struct FusesArray {
        /// @dev value is a fuse address
        address[] value;
    }

    struct BalanceFuses {
        /// @dev marketId => balance fuse address
        mapping(uint256 => address) value;
    }

    struct BalanceFusesArray {
        /// @dev value is a marketId and fuse address: keccak256(abi.encode(marketId, fuse))
        bytes32[] value;
    }

    struct InstantWithdrawalFuses {
        /// @dev value is a fuse address used for instant withdrawal
        address[] value;
    }

    struct InstantWithdrawalFusesParams {
        /// @dev key: fuse address and index in InstantWithdrawalFuses array, value: list of parameters used for instant withdrawal
        /// @dev first param always amount in underlying asset of PlazmaVault, second and next params are specific for the fuse and market
        mapping(bytes32 => bytes32[]) value;
    }

    function getTotalAssets() internal pure returns (TotalAssets storage totalAssets) {
        assembly {
            totalAssets.slot := PLAZMA_VAULT_TOTAL_ASSETS_IN_ALL_MARKETS
        }
    }

    function getMarketTotalAssets() internal pure returns (MarketTotalAssets storage marketTotalAssets) {
        assembly {
            marketTotalAssets.slot := PLAZMA_VAULT_TOTAL_ASSETS_IN_MARKET
        }
    }

    function getAlphas() internal pure returns (Alphas storage alphas) {
        assembly {
            alphas.slot := CFG_PLAZMA_VAULT_ALPHAS
        }
    }

    /// @notice Space in storage to store the market configuration for a given PlazmaVault
    function getMarketSubstrates() internal pure returns (MarketSubstrates storage marketSubstrates) {
        assembly {
            marketSubstrates.slot := CFG_PLAZMA_VAULT_MARKET_SUBSTRATES
        }
    }

    function getFuses() internal pure returns (Fuses storage fuses) {
        assembly {
            fuses.slot := CFG_PLAZMA_VAULT_FUSES
        }
    }

    function getFusesArray() internal pure returns (FusesArray storage fusesArray) {
        assembly {
            fusesArray.slot := CFG_PLAZMA_VAULT_FUSES_ARRAY
        }
    }

    function getBalanceFuses() internal pure returns (BalanceFuses storage balanceFuses) {
        assembly {
            balanceFuses.slot := CFG_PLAZMA_VAULT_BALANCE_FUSES
        }
    }

    function getBalanceFusesArray() internal pure returns (BalanceFusesArray storage balanceFusesArray) {
        assembly {
            balanceFusesArray.slot := CFG_PLAZMA_VAULT_BALANCE_FUSES_ARRAY
        }
    }

    function getInstantWithdrawalFusesArray()
        internal
        pure
        returns (InstantWithdrawalFuses storage instantWithdrawalFuses)
    {
        assembly {
            instantWithdrawalFuses.slot := CFG_PLAZMA_VAULT_INSTANT_WITHDRAWAL_FUSES_ARRAY
        }
    }

    function getInstantWithdrawalFusesParams()
        internal
        pure
        returns (InstantWithdrawalFusesParams storage instantWithdrawalFusesParams)
    {
        assembly {
            instantWithdrawalFusesParams.slot := CFG_PLAZMA_VAULT_INSTANT_WITHDRAWAL_FUSES_PARAMS
        }
    }
}
