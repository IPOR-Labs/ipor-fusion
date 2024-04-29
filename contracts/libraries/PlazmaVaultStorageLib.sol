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
    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.cfgPlazmaVaultAlphas")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant CFG_PLAZMA_VAULT_ALPHAS =
        0xbbd7bc5cd719a97025518945196354def0448dfbb28026fa8e24bdb46e847d00;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.cfgPlazmaVaultMarketSubstrates")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant CFG_PLAZMA_VAULT_MARKET_SUBSTRATES =
        0x687e7b34daf9b2313d902de6df703f968b9401655e0597c93605beb6dcd2a200;

    /// @notice List of fuses ass
    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.cfgPlazmaVaultFuses")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant CFG_PLAZMA_VAULT_FUSES =
        0x000870d0ab0f5888c0443d38da0ef74462768b61a0736020c116cc1261f85100;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.cfgPlazmaVaultFusesArray")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant CFG_PLAZMA_VAULT_FUSES_ARRAY =
        0xe1087412b7cc398415230a6f08f19ca4eb4b4903631014f99bd0383ea79b5600;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.cfgPlazmaVaultBalanceFuses")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant CFG_PLAZMA_VAULT_BALANCE_FUSES =
        0xecfbe2133c36991f817b6176be193a570614fe65c12380c8155f71c8db8ffa00;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.cfgPlazmaVaultBalanceFusesArray")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant CFG_PLAZMA_VAULT_BALANCE_FUSES_ARRAY =
        0xc6ea71123e83eb9e295d0fbbb08460fe8b3972391fb51a770212c1740a87e600;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.cfgPlazmaVaultInstantWithdrawalFusesArray")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant CFG_PLAZMA_VAULT_INSTANT_WITHDRAWAL_FUSES_ARRAY =
        0xc650b77456730746bf5cfc334017a83f195e5f3c1517bf4b6f17a14213596e00;

    /// @notice Every fuse has a list of parameters used for instant withdrawal
    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.cfgPlazmaVaultInstantWithdrawalFusesParams")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant CFG_PLAZMA_VAULT_INSTANT_WITHDRAWAL_FUSES_PARAMS =
        0xdc3a1c6868589d5b4c729d47a3a17bacae0afe31d7c568e7b5699f211a9ef000;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.cfgPlazmaVaultGrantedAddressesToInteractWithVault")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant CFG_PLAZMA_VAULT_GRANTED_ADDRESSES_TO_INTERACT_WITH_VAULT =
        0x46ec56ade62cfd6abda269a58cda0f97b3c6351a2256484532e7afc30b7ba600;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.cfgPlazmaVaultFees")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant CFG_PLAZMA_VAULT_FEES = 0x61ae617869d57de2346d52225ecd25878c9518b527e367e03eeeee76158e8900;

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
        /// @dev first param always amount in underlying asset of PlazmaVault, second and next params are specific for the fuse and market
        mapping(bytes32 => bytes32[]) value;
    }

    struct GrantedAddressesToInteractWithVault {
        /// @dev The zero address serves as a flag indicating whether the vault has limited access.
        /// @dev address => 1 - is granted, otherwise - not granted
        mapping(address => uint256) value;
    }

    /// @notice Fee configuration and balance
    struct Fees {
        /// @notice Fee Manager address, all fees are sent to this address and then distributed based on logic implemented in the Fee Manager contract
        address manager;
        /// @notice Configuration of performance fee in percentage, represented in 2 decimals, 100% = 10000, 1% = 100, 0.01% = 1
        uint16 cfgPerformanceFeeInPercentage;
        /// @notice Configuration of management fee in percentage, represented in 2 decimals, 100% = 10000, 1% = 100, 0.01% = 1
        uint16 cfgManagementFeeInPercentage;
        /// @notice Performance fee balance, accounting for the performance fee
        uint32 performanceFeeBalance;
        /// @notice Management fee balance, accounting for the management fee
        uint32 managementFeeBalance;
    }

    struct FeeStorage {
        Fees value;
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

    function getGrantedAddressesToInteractWithVault()
        internal
        pure
        returns (GrantedAddressesToInteractWithVault storage grantedAddressesToInteractWithVault)
    {
        assembly {
            grantedAddressesToInteractWithVault.slot := CFG_PLAZMA_VAULT_GRANTED_ADDRESSES_TO_INTERACT_WITH_VAULT
        }
    }

    function getFees() internal pure returns (FeeStorage storage fees) {
        assembly {
            fees.slot := CFG_PLAZMA_VAULT_FEES
        }
    }
}
