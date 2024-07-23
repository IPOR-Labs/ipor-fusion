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

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.MarketLimits")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant MARKET_LIMITS = 0xc2733c187287f795e2e6e84d35552a190e774125367241c3e99e955f4babf000;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.DependencyBalanceGraph")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant DEPENDENCY_BALANCE_GRAPH =
        0x82411e549329f2815579116a6c5e60bff72686c93ab5dba4d06242cfaf968900;

    /// @custom:storage-location erc7201:io.ipor.RewardsClaimManagerAddress
    struct RewardsClaimManagerAddress {
        /// @dev total assets in the Plasma Vault
        address value;
    }

    /// @custom:storage-location erc7201:io.ipor.PlasmaVaultTotalAssetsInAllMarkets
    struct TotalAssets {
        /// @dev total assets in the Plasma Vault
        uint256 value;
    }

    /// @custom:storage-location erc7201:io.ipor.PlasmaVaultTotalAssetsInMarket
    struct MarketTotalAssets {
        /// @dev marketId => total assets in the vault in the market
        mapping(uint256 => uint256) value;
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

    /// @custom:storage-location erc7201:io.ipor.CfgPlasmaVaultMarketSubstrates
    struct MarketSubstrates {
        /// @dev marketId => MarketSubstratesStruct
        mapping(uint256 => MarketSubstratesStruct) value;
    }

    /// @custom:storage-location erc7201:io.ipor.CfgPlasmaVaultBalanceFuses
    struct BalanceFuses {
        /// @dev marketId => balance fuse address
        mapping(uint256 => address) value;
    }

    /// @custom:storage-location erc7201:io.ipor.BalanceDependenceGraph
    struct DependencyBalanceGraph {
        mapping(uint256 marketId => uint256[] marketIds) dependencyGraph;
    }

    /// @custom:storage-location erc7201:io.ipor.CfgPlasmaVaultInstantWithdrawalFusesArray
    struct InstantWithdrawalFuses {
        /// @dev value is a Fuse address used for instant withdrawal
        address[] value;
    }

    /// @custom:storage-location erc7201:io.ipor.CfgPlasmaVaultInstantWithdrawalFusesParams
    struct InstantWithdrawalFusesParams {
        /// @dev key: fuse address and index in InstantWithdrawalFuses array, value: list of parameters used for instant withdrawal
        /// @dev first param always amount in underlying asset of PlasmaVault, second and next params are specific for the fuse and market
        mapping(bytes32 => bytes32[]) value;
    }

    /// @custom:storage-location erc7201:io.ipor.PlasmaVaultPerformanceFeeData
    struct PerformanceFeeData {
        address feeManager;
        uint16 feeInPercentage;
    }

    /// @custom:storage-location erc7201:io.ipor.PlasmaVaultManagementFeeData
    struct ManagementFeeData {
        address feeManager;
        uint16 feeInPercentage;
        uint32 lastUpdateTimestamp;
    }

    /// @custom:storage-location erc7201:io.ipor.PriceOracle
    struct PriceOracle {
        address value;
    }

    /// @dev limit is percentage of total assets in the market in 18 decimals, 1e18 is 100%
    /// @deb if limit for zero marketId is greater than 0, then limits are activated
    /// @custom:storage-location erc7201:io.ipor.matrketLimits
    struct MarketLimits {
        mapping(uint256 marketId => uint256 limit) limitInPercentage;
    }

    function getTotalAssets() internal pure returns (TotalAssets storage totalAssets) {
        assembly {
            totalAssets.slot := PLASMA_VAULT_TOTAL_ASSETS_IN_ALL_MARKETS
        }
    }

    function getDependencyBalanceGraph() internal pure returns (DependencyBalanceGraph storage dependencyGraph) {
        assembly {
            dependencyGraph.slot := DEPENDENCY_BALANCE_GRAPH
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

    function getMarketsLimits() internal pure returns (MarketLimits storage marketLimits) {
        assembly {
            marketLimits.slot := MARKET_LIMITS
        }
    }
}
