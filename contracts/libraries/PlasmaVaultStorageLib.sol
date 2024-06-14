// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title Storage
library PlasmaVaultStorageLib {
    using SafeCast for uint256;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.PlasmaVaultTotalAssetsInAllMarkets")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant PLASMA_VAULT_TOTAL_ASSETS_IN_ALL_MARKETS =
    0x24e02552e88772b8e8fd15f3e6699ba530635ffc6b52322da922b0b497a77300;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.PlasmaVaultTotalAssetsInMarket")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant PLASMA_VAULT_TOTAL_ASSETS_IN_MARKET =
    0x656f5ca8c676f20b936e991a840e1130bdd664385322f33b6642ec86729ee600;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.CfgPlasmaVaultMarketSubstrates")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant CFG_PLASMA_VAULT_MARKET_SUBSTRATES =
    0x78e40624004925a4ef6749756748b1deddc674477302d5b7fe18e5335cde3900;

    /// @notice List of fuses ass
    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.CfgPlasmaVaultFuses")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant CFG_PLASMA_VAULT_FUSES =
    0xb51560274e32ee3aa5950cd99ede1261a60520ae70eca2e5b2e0df1ab5340000;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.CfgPlasmaVaultFusesArray")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant CFG_PLASMA_VAULT_FUSES_ARRAY =
    0x7e27ab4f0ce7a13bf94cb7667cbc77f39749d1cc36801f4d0f5d3bda3450e900;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.CfgPlasmaVaultBalanceFuses")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant CFG_PLASMA_VAULT_BALANCE_FUSES =
    0x150144dd6af711bac4392499881ec6649090601bd196a5ece5174c1400b1f700;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.CfgPlasmaVaultInstantWithdrawalFusesArray")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant CFG_PLASMA_VAULT_INSTANT_WITHDRAWAL_FUSES_ARRAY =
    0xd243afa3da07e6bdec20fdd573a17f99411aa8a62ae64ca2c426d3a86ae0ac00;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.PriceOracle")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant PRICE_ORACLE = 0x13673b0e97c9c64fe16a7d0ebe40964562729b0147b60cb9a5240695a3704a00;

    /// @notice Every fuse has a list of parameters used for instant withdrawal
    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.CfgPlasmaVaultInstantWithdrawalFusesParams")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant CFG_PLASMA_VAULT_INSTANT_WITHDRAWAL_FUSES_PARAMS =
    0x45a704819a9dcb1bb5b8cff129eda642cf0e926a9ef104e27aa53f1d1fa47b00;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.CfgPlasmaVaultFeeConfig")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant CFG_PLASMA_VAULT_FEE_CONFIG =
    0x78b5ce597bdb64d5aa30a201c7580beefe408ff13963b5d5f3dce2dc09e89c00;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.PlasmaVaultPerformanceFeeData")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant PLASMA_VAULT_PERFORMANCE_FEE_DATA =
    0x9399757a27831a6cfb6cf4cd5c97a908a2f8f41e95a5952fbf83a04e05288400;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.PlasmaVaultManagementFeeData")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant PLASMA_VAULT_MANAGEMENT_FEE_DATA =
    0x239dd7e43331d2af55e2a25a6908f3bcec2957025f1459db97dcdc37c0003f00;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.RewardsClaimManagerAddress")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant REWARDS_CLAIM_MANAGER_ADDRESS =
    0x08c469289c3f85d9b575f3ae9be6831541ff770a06ea135aa343a4de7c962d00;

    /// @custom:storage-location erc7201:io.ipor.PlasmaVaultRewardsClaimManagerAddress
    struct RewardsClaimManagerAddress {
        /// @dev total assets in the Plasma Vault
        address value;
    }

    /// @custom:storage-location erc7201:io.ipor.plasmaVaultTotalAssetsInAllMarkets
    struct TotalAssets {
        /// @dev total assets in the Plasma Vault
        uint256 value;
    }

    /// @custom:storage-location erc7201:io.ipor.plasmaVaultTotalAssetsInMarket
    struct MarketTotalAssets {
        /// @dev marketId => total assets in the vault in the market
        mapping(uint256 => uint256) value;
    }

    /// @custom:storage-location erc7201:io.ipor.cfgPlasmaVaultAlphas
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

    /// @custom:storage-location erc7201:io.ipor.cfgPlasmaVaultMarketSubstrates
    struct MarketSubstrates {
        /// @dev marketId => MarketSubstratesStruct
        mapping(uint256 => MarketSubstratesStruct) value;
    }

    /// @custom:storage-location erc7201:io.ipor.cfgPlasmaVaultFuses
    struct Fuses {
        /// @dev fuse address => 1 - is granted, otherwise - not granted
        mapping(address => uint256) value;
    }

    /// @custom:storage-location erc7201:io.ipor.cfgPlasmaVaultFusesArray
    struct FusesArray {
        /// @dev value is a fuse address
        address[] value;
    }

    /// @custom:storage-location erc7201:io.ipor.cfgPlasmaVaultBalanceFuses
    struct BalanceFuses {
        /// @dev marketId => balance fuse address
        mapping(uint256 => address) value;
    }

    /// @custom:storage-location erc7201:io.ipor.cfgPlasmaVaultInstantWithdrawalFusesArray
    struct InstantWithdrawalFuses {
        /// @dev value is a Fuse address used for instant withdrawal
        address[] value;
    }

    /// @custom:storage-location erc7201:io.ipor.cfgPlasmaVaultInstantWithdrawalFusesParams
    struct InstantWithdrawalFusesParams {
        /// @dev key: fuse address and index in InstantWithdrawalFuses array, value: list of parameters used for instant withdrawal
        /// @dev first param always amount in underlying asset of PlasmaVault, second and next params are specific for the fuse and market
        mapping(bytes32 => bytes32[]) value;
    }

    /// @custom:storage-location erc7201:io.ipor.cfgPlasmaVaultGrantedAddressesToInteractWithVault
    struct GrantedAddressesToInteractWithVault {
        /// @dev The zero address serves as a flag indicating whether the vault has limited access.
        /// @dev address => 1 - is granted, otherwise - not granted
        mapping(address => uint256) value;
    }

    /// @custom:storage-location erc7201:io.ipor.plasmaVaultPerformanceFeeData
    struct PerformanceFeeData {
        address feeManager;
        uint16 feeInPercentage;
    }

    /// @custom:storage-location erc7201:io.ipor.plasmaVaultManagementFeeData
    struct ManagementFeeData {
        address feeManager;
        uint16 feeInPercentage;
        uint32 lastUpdateTimestamp;
    }

    /// @custom:storage-location erc7201:io.ipor.priceOracle
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

    function getRewardsClaimManagerAddress()
        internal
        pure
        returns (RewardsClaimManagerAddress storage rewardsClaimManagerAddress_)
    {
        assembly {
            rewardsClaimManagerAddress_.slot := REWARDS_CLAIM_MANAGER_ADDRESS
        }
    }
}
