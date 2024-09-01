// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title Library responsible for managing access to the storage of the PlasmaVault contract using the ERC-7201 standard
library PlasmaVaultStorageLib {
    /// @dev value taken from ERC20CappedUpgradeable contract, don't change it
    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ERC20Capped")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ERC20_CAPPED_STORAGE_LOCATION =
        0x0f070392f17d5f958cc1ac31867dabecfc5c9758b4a419a200803226d7155d00;

    /// @dev storage pointer location for a flag which indicates if the Total Supply Cap validation is enabled
    // keccak256(abi.encode(uint256(keccak256("io.ipor.Erc20CappedValidationFlag")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ERC20_CAPPED_VALIDATION_FLAG =
        0xaef487a7a52e82ae7bbc470b42be72a1d3c066fb83773bf99cce7e6a7df2f900;

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

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.PriceOracleMiddleware")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant PRICE_ORACLE_MIDDLEWARE =
        0x0d761ae54d86fc3be4f1f2b44ade677efb1c84a85fc6bb1d087dc42f1e319a00;

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

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.executeRunning")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant EXECUTE_RUNNING = 0x054644eb87255c1c6a2d10801735f52fa3b9d6e4477dbed74914d03844ab6600;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.callbackHandler")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant CALLBACK_HANDLER = 0xb37e8684757599da669b8aea811ee2b3693b2582d2c730fab3f4965fa2ec3e00;

    /// @custom:storage-location erc7201:openzeppelin.storage.ERC20Capped
    struct ERC20CappedStorage {
        uint256 cap;
    }

    /// @notice ERC20CappedValidationFlag is used to enable or disable the total supply cap validation during execution
    /// Required for situation when performance fee or management fee is minted for fee managers
    /// @custom:storage-location erc7201:io.ipor.Erc20CappedValidationFlag
    struct ERC20CappedValidationFlag {
        uint256 value;
    }

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

    /// @custom:storage-location erc7201:io.ipor.callbackHandler
    struct CallbackHandler {
        /// @dev key: keccak256(abi.encodePacked(sender, sig)), value: handler address
        mapping(bytes32 key => address handler) callbackHandler;
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

    /// @custom:storage-location erc7201:io.ipor.PriceOracleMiddleware
    struct PriceOracleMiddleware {
        address value;
    }

    /// @custom:storage-location erc7201:io.ipor.executeRunning
    struct ExecuteState {
        uint256 value;
    }

    /// @dev limit is percentage of total assets in the market in 18 decimals, 1e18 is 100%
    /// @deb if limit for zero marketId is greater than 0, then limits are activated
    /// @custom:storage-location erc7201:io.ipor.MarketLimits
    struct MarketLimits {
        mapping(uint256 marketId => uint256 limit) limitInPercentage;
    }

    function getERC20CappedStorage() internal pure returns (ERC20CappedStorage storage $) {
        assembly {
            $.slot := ERC20_CAPPED_STORAGE_LOCATION
        }
    }

    function getERC20CappedValidationFlag() internal pure returns (ERC20CappedValidationFlag storage $) {
        assembly {
            $.slot := ERC20_CAPPED_VALIDATION_FLAG
        }
    }

    /// @notice Gets the total assets storage pointer
    /// @return totalAssets storage pointer
    function getTotalAssets() internal pure returns (TotalAssets storage totalAssets) {
        assembly {
            totalAssets.slot := PLASMA_VAULT_TOTAL_ASSETS_IN_ALL_MARKETS
        }
    }

    /// @notice Gets execution state storage pointer
    /// @return executeRunning storage pointer
    function getExecutionState() internal pure returns (ExecuteState storage executeRunning) {
        assembly {
            executeRunning.slot := EXECUTE_RUNNING
        }
    }

    /// @notice Gets the callback handler storage pointer
    /// @return handler storage pointer
    function getCallbackHandler() internal pure returns (CallbackHandler storage handler) {
        assembly {
            handler.slot := CALLBACK_HANDLER
        }
    }

    /// @notice Gets the dependency balance graph storage pointer
    /// @return dependencyBalanceGraph storage pointer
    function getDependencyBalanceGraph() internal pure returns (DependencyBalanceGraph storage dependencyBalanceGraph) {
        assembly {
            dependencyBalanceGraph.slot := DEPENDENCY_BALANCE_GRAPH
        }
    }

    /// @notice Gets the market total assets storage pointer
    /// @return marketTotalAssets storage pointer
    function getMarketTotalAssets() internal pure returns (MarketTotalAssets storage marketTotalAssets) {
        assembly {
            marketTotalAssets.slot := PLASMA_VAULT_TOTAL_ASSETS_IN_MARKET
        }
    }

    /// @notice Gets the market substrates storage pointer
    /// @return marketSubstrates storage pointer
    function getMarketSubstrates() internal pure returns (MarketSubstrates storage marketSubstrates) {
        assembly {
            marketSubstrates.slot := CFG_PLASMA_VAULT_MARKET_SUBSTRATES
        }
    }

    /// @notice Gets the balance fuses storage pointer
    /// @return balanceFuses storage pointer
    function getBalanceFuses() internal pure returns (BalanceFuses storage balanceFuses) {
        assembly {
            balanceFuses.slot := CFG_PLASMA_VAULT_BALANCE_FUSES
        }
    }

    /// @notice Gets the instant withdrawal fuses storage pointer
    /// @return instantWithdrawalFuses storage pointer
    function getInstantWithdrawalFusesArray()
        internal
        pure
        returns (InstantWithdrawalFuses storage instantWithdrawalFuses)
    {
        assembly {
            instantWithdrawalFuses.slot := CFG_PLASMA_VAULT_INSTANT_WITHDRAWAL_FUSES_ARRAY
        }
    }

    /// @notice Gets the instant withdrawal fuses params storage pointer
    /// @return instantWithdrawalFusesParams storage pointer
    function getInstantWithdrawalFusesParams()
        internal
        pure
        returns (InstantWithdrawalFusesParams storage instantWithdrawalFusesParams)
    {
        assembly {
            instantWithdrawalFusesParams.slot := CFG_PLASMA_VAULT_INSTANT_WITHDRAWAL_FUSES_PARAMS
        }
    }

    /// @notice Gets the PriceOracleMiddleware storage pointer
    /// @return oracle storage pointer
    function getPriceOracleMiddleware() internal pure returns (PriceOracleMiddleware storage oracle) {
        assembly {
            oracle.slot := PRICE_ORACLE_MIDDLEWARE
        }
    }

    /// @notice Gets performance fee config storage pointer
    /// @return performanceFeeData storage pointer
    function getPerformanceFeeData() internal pure returns (PerformanceFeeData storage performanceFeeData) {
        assembly {
            performanceFeeData.slot := PLASMA_VAULT_PERFORMANCE_FEE_DATA
        }
    }

    /// @notice Gets management fee config storage pointer
    /// @return managementFeeData storage pointer
    function getManagementFeeData() internal pure returns (ManagementFeeData storage managementFeeData) {
        assembly {
            managementFeeData.slot := PLASMA_VAULT_MANAGEMENT_FEE_DATA
        }
    }

    /// @notice Gets the Rewards Claim Manager address storage pointer
    /// @return rewardsClaimManagerAddress storage pointer
    function getRewardsClaimManagerAddress()
        internal
        pure
        returns (RewardsClaimManagerAddress storage rewardsClaimManagerAddress)
    {
        assembly {
            rewardsClaimManagerAddress.slot := REWARDS_CLAIM_MANAGER_ADDRESS
        }
    }

    /// @notice Gets the MarketLimits storage pointer
    /// @return marketLimits storage pointer
    function getMarketsLimits() internal pure returns (MarketLimits storage marketLimits) {
        assembly {
            marketLimits.slot := MARKET_LIMITS
        }
    }
}
