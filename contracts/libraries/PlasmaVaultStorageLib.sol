// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title Storage
library PlasmaVaultStorageLib {
    using SafeCast for uint256;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.plasmaVaultTotalAssetsInAllMarkets")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant PLASMA_VAULT_TOTAL_ASSETS_IN_ALL_MARKETS =
        0xf660efede6b8071aab61a75191de57a4a8a416b088f961d8c2a18168aa7c7700;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.plasmaVaultTotalAssetsInMarket")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant PLASMA_VAULT_TOTAL_ASSETS_IN_MARKET =
        0x4b7e21bd695ff47386ac5a9c91bc5af89ae8f70db8784eaaf7e339cf59a90400;

    /// @notice List of alphas allowed to execute actions on the vault
    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.cfgPlasmaVaultAlphas")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant CFG_PLASMA_VAULT_ALPHAS =
        0xb4a789f3429f4117549bcd6c9310113f9405d6b1c930f53ac188a1907a86c400;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.cfgPlasmaVaultMarketSubstrates")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant CFG_PLASMA_VAULT_MARKET_SUBSTRATES =
        0xfe9ad807db753417e8720b1fc03cc0413cb78b2a910b408a05319e9fda3ed100;

    /// @notice List of fuses ass
    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.cfgPlasmaVaultFuses")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant CFG_PLASMA_VAULT_FUSES =
        0xa96ee4949aa7df44b46d24f50f8a0d5df8f141f78617dead947063334c48e700;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.cfgPlasmaVaultFusesArray")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant CFG_PLASMA_VAULT_FUSES_ARRAY =
        0x25ef92c2997157a4d79515d18f6eba738994580f5e258ef357c1ee175bcbbc00;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.cfgPlasmaVaultBalanceFuses")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant CFG_PLASMA_VAULT_BALANCE_FUSES =
        0xa5d630b12943d05aa5b6826803880948eb9a1ad1cf4a04bb7a5d69aae8b60600;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.cfgPlasmaVaultInstantWithdrawalFusesArray")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant CFG_PLASMA_VAULT_INSTANT_WITHDRAWAL_FUSES_ARRAY =
        0x4320b221b0115d4c27700eb9530f9b97354a11fc1d15a3bfa71b7d6e46733f00;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.priceOracle")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant PRICE_ORACLE = 0x58241ab58cc0d3d7994d58fd91816a26df3bcc7565a2c401cab5971211036a00;

    /// @notice Every fuse has a list of parameters used for instant withdrawal
    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.cfgPlasmaVaultInstantWithdrawalFusesParams")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant CFG_PLASMA_VAULT_INSTANT_WITHDRAWAL_FUSES_PARAMS =
        0x471d4152a74f0c2d2daea41c6f0f65733a7bcc61fedc32bc0084a98c5f96ff00;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.cfgPlasmaVaultGrantedAddressesToInteractWithVault")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant CFG_PLASMA_VAULT_GRANTED_ADDRESSES_TO_INTERACT_WITH_VAULT =
        0xfa87daeda1dbf9ff4e1e074074afad700558780bbfeeb3fc95c580b632362700;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.cfgPlasmaVaultFeeConfig")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant CFG_PLASMA_VAULT_FEE_CONFIG =
        0xc54b723690b3d8f5a3756b82753e38bca87e5d79881cee3d06a3f9eb950f0f00;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.plasmaVaultPerformanceFeeData")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant PLASMA_VAULT_PERFORMANCE_FEE_DATA =
        0xa8ad752bed828f0b4a1b7e81147393b0a5446d2e62297cffa22cb84bfb19f100;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.plasmaVaultManagementFeeData")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant PLASMA_VAULT_MANAGEMENT_FEE_DATA =
        0x09d6601575ea05ac39a145900e734264a5a09fe803eeb2ccc2884e0dc893b100;

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
        /// @dev fuse address => 1 - is granted, otherwise - not granted
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
        /// @dev first param always amount in underlying asset of PlasmaVault, second and next params are specific for the fuse and market
        mapping(bytes32 => bytes32[]) value;
    }

    struct GrantedAddressesToInteractWithVault {
        /// @dev The zero address serves as a flag indicating whether the vault has limited access.
        /// @dev address => 1 - is granted, otherwise - not granted
        mapping(address => uint256) value;
    }

    struct PerformanceFeeData {
        address feeManager;
        uint16 feeInPercentage;
    }

    struct ManagementFeeData {
        address feeManager;
        uint16 feeInPercentage;
        uint32 lastUpdateTimestamp;
    }

    struct PriceOracle {
        address value;
    }

    function getTotalAssets() internal pure returns (TotalAssets storage totalAssets) {
        assembly {
            totalAssets.slot := PLASMA_VAULT_TOTAL_ASSETS_IN_ALL_MARKETS
        }
    }

    function getMarketTotalAssets() internal pure returns (MarketTotalAssets storage marketTotalAssets) {
        assembly {
            marketTotalAssets.slot := PLASMA_VAULT_TOTAL_ASSETS_IN_MARKET
        }
    }

    function getAlphas() internal pure returns (Alphas storage alphas) {
        assembly {
            alphas.slot := CFG_PLASMA_VAULT_ALPHAS
        }
    }

    /// @notice Space in storage to store the market configuration for a given PlasmaVault
    function getMarketSubstrates() internal pure returns (MarketSubstrates storage marketSubstrates) {
        assembly {
            marketSubstrates.slot := CFG_PLASMA_VAULT_MARKET_SUBSTRATES
        }
    }

    function getFuses() internal pure returns (Fuses storage fuses) {
        assembly {
            fuses.slot := CFG_PLASMA_VAULT_FUSES
        }
    }

    function getFusesArray() internal pure returns (FusesArray storage fusesArray) {
        assembly {
            fusesArray.slot := CFG_PLASMA_VAULT_FUSES_ARRAY
        }
    }

    function getBalanceFuses() internal pure returns (BalanceFuses storage balanceFuses) {
        assembly {
            balanceFuses.slot := CFG_PLASMA_VAULT_BALANCE_FUSES
        }
    }

    function getInstantWithdrawalFusesArray()
        internal
        pure
        returns (InstantWithdrawalFuses storage instantWithdrawalFuses)
    {
        assembly {
            instantWithdrawalFuses.slot := CFG_PLASMA_VAULT_INSTANT_WITHDRAWAL_FUSES_ARRAY
        }
    }

    function getInstantWithdrawalFusesParams()
        internal
        pure
        returns (InstantWithdrawalFusesParams storage instantWithdrawalFusesParams)
    {
        assembly {
            instantWithdrawalFusesParams.slot := CFG_PLASMA_VAULT_INSTANT_WITHDRAWAL_FUSES_PARAMS
        }
    }

    function getGrantedAddressesToInteractWithVault()
        internal
        pure
        returns (GrantedAddressesToInteractWithVault storage grantedAddressesToInteractWithVault)
    {
        assembly {
            grantedAddressesToInteractWithVault.slot := CFG_PLASMA_VAULT_GRANTED_ADDRESSES_TO_INTERACT_WITH_VAULT
        }
    }

    function getPriceOracle() internal pure returns (PriceOracle storage oracle) {
        assembly {
            oracle.slot := PRICE_ORACLE
        }
    }

    function getPerformanceFeeData() internal pure returns (PerformanceFeeData storage performanceFeeData) {
        assembly {
            performanceFeeData.slot := PLASMA_VAULT_PERFORMANCE_FEE_DATA
        }
    }

    function getManagementFeeData() internal pure returns (ManagementFeeData storage managementFeeData) {
        assembly {
            managementFeeData.slot := PLASMA_VAULT_MANAGEMENT_FEE_DATA
        }
    }
}
