// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/**
 * @title Fusion Factory Storage Library
 * @notice Library managing storage layout and access for the FusionFactory system using ERC-7201 namespaced storage pattern
 * @dev This library is a core component of the FusionFactory system that:
 * 1. Defines and manages all storage structures using ERC-7201 namespaced storage pattern
 * 2. Provides storage access functions for FusionFactory.sol
 * 3. Ensures storage safety for the upgradeable factory system
 *
 * Storage Components:
 * - Factory addresses (rewards, fee, withdraw, context, price, plasma vault, access)
 * - Price oracle middleware
 * - Fee configuration (IPOR DAO management and performance fees)
 * - Redemption and withdrawal timing parameters
 * - Burn request fee configuration
 *
 * Security Considerations:
 * - Uses ERC-7201 namespaced storage pattern to prevent storage collisions
 * - Each storage struct has a unique namespace derived from its purpose
 * - Critical for maintaining storage integrity in upgradeable contracts
 * - Storage slots are carefully chosen and must not be modified
 *
 * @custom:security-contact security@ipor.io
 */
library FusionFactoryStorageLib {

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fusion.factory.PlasmaVaultFactoryAddress")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PLASMA_VAULT_FACTORY_ADDRESS =
        0xe03d6bb506e833b55bb7e35e66d871fd1486b3efc6bb02b49fae15b9d0247c00;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fusion.factory.AccessManagerFactoryAddress")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ACCESS_MANAGER_FACTORY_ADDRESS =
        0xc4010ca65378f19e44b7504e0cbdfa0cf4c6c98dc078f9636d3e6f447548f800;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fusion.factory.FeeManagerFactoryAddress")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant FEE_MANAGER_FACTORY_ADDRESS =
        0x721d35383ddb7c0788c39a71ec2b671094a2dff039cf875075cb2cc19150ee00;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fusion.factory.RewardsManagerFactoryAddress")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant REWARDS_MANAGER_FACTORY_ADDRESS =
        0x876e1f4e6bf0084ef05fd36552de50d6a3381705e29281ddedec7e73a391a100;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fusion.factory.WithdrawManagerFactoryAddress")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant WITHDRAW_MANAGER_FACTORY_ADDRESS =
        0xedd99766ca1e8c3d62993721acdaaf42a25e38027fea50866095b850992fdc00;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fusion.factory.ContextManagerFactoryAddress")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CONTEXT_MANAGER_FACTORY_ADDRESS =
        0x33ff6c98f150f6340aa139cf0a40783e1ff0404e5958622d928ebe5534456a00;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fusion.factory.PriceManagerFactoryAddress")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PRICE_MANAGER_FACTORY_ADDRESS =
        0xd7a02eb1d0bb68108f76123da75aaeb1a46f41df9f533c7662e3a619ec932800;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fusion.factory.PlasmaVaultBaseAddress")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PLASMA_VAULT_BASE_ADDRESS =
        0x184318af1b1e15812549d3991019d6e84064e321b012fca8ea3de5c3da16db00;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fusion.factory.PriceOracleMiddlewareAddress")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PRICE_ORACLE_MIDDLEWARE_ADDRESS =
        0x6fbe74bad032cccb3ef5e7d7be660790fda329f96cf9462b85accc6e1d7d4100;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fusion.factory.BurnRequestFeeBalanceFuseAddress")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BURNR_REQUEST_FEE_BALANCE_FUSE_ADDRESS = 0xa0dc2f24541d4bbdc49c383a8746cd6256371b67d8afc882e3ce7e04f721df00;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fusion.factory.BurnRequestFeeFuseAddress")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BURN_REQUEST_FEE_FUSE_ADDRESS = 0xf011e505a711b4f906e6e0cfcd988c477cb335d6eb81d8284628276cae32ab00;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fusion.factory.IporDaoFeeRecipientAddress")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant IPOR_DAO_FEE_RECIPIENT_ADDRESS =
        0xe26401adf3cefb9a94bf1fba47a8129fd18fd2e2e83de494ce289a832073a500;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fusion.factory.IporDaoManagementFee")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant IPOR_DAO_MANAGEMENT_FEE = 0x8fc808da4bdddf1c57ae4d57b8d77cb4183e940f6bb88a2aecb349605eb51800;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fusion.factory.IporDaoPerformanceFee")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant IPOR_DAO_PERFORMANCE_FEE = 0x3d6b96d1c7d5b94a3af077c0baedb5f7745382ef440582d67ffa3542d73b9f00;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fusion.factory.RedemptionDelayInSeconds")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant REDEMPTION_DELAY_IN_SECONDS = 0xf5f7bf2a3be534f496ee2079085992e191fe987b91953e0e010e320f6bf8e100;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fusion.factory.WithdrawWindowInSeconds")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant WITHDRAW_WINDOW_IN_SECONDS = 0x95f9ecba121b4f2a2786b729864c46a5066694903a7462f772cd92093beb0500;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fusion.factory.VestingPeriodInSeconds")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant VESTING_PERIOD_IN_SECONDS = 0xe7de166eee522f429c14923fb385ff49d6c65d576ad910fc76c16800f269be00;


    struct AddressType {
        address value;
    }

    struct Uint256Type {
        uint256 value;
    }

    function getPlasmaVaultFactoryAddressSlot() internal pure returns (AddressType storage $) {
        assembly {
            $.slot := PLASMA_VAULT_FACTORY_ADDRESS
        }
    }

    function getAccessManagerFactoryAddressSlot() internal pure returns (AddressType storage $) {
        assembly {
            $.slot := ACCESS_MANAGER_FACTORY_ADDRESS
        }
    }

    function getFeeManagerFactoryAddressSlot() internal pure returns (AddressType storage $) {
        assembly {
            $.slot := FEE_MANAGER_FACTORY_ADDRESS
        }
    }

    function getRewardsManagerFactoryAddressSlot() internal pure returns (AddressType storage $) {
        assembly {
            $.slot := REWARDS_MANAGER_FACTORY_ADDRESS
        }
    }

    function getWithdrawManagerFactoryAddressSlot() internal pure returns (AddressType storage $) {
        assembly {
            $.slot := WITHDRAW_MANAGER_FACTORY_ADDRESS
        }
    }

    function getContextManagerFactoryAddressSlot() internal pure returns (AddressType storage $) {
        assembly {
            $.slot := CONTEXT_MANAGER_FACTORY_ADDRESS
        }
    }

    function getPriceManagerFactoryAddressSlot() internal pure returns (AddressType storage $) {
        assembly {
            $.slot := PRICE_MANAGER_FACTORY_ADDRESS
        }
    }

    function getPlasmaVaultBaseAddressSlot() internal pure returns (AddressType storage $) {
        assembly {
            $.slot := PLASMA_VAULT_BASE_ADDRESS
        }
    }

    function getPriceOracleMiddlewareSlot() internal pure returns (AddressType storage $) {
        assembly {
            $.slot := PRICE_ORACLE_MIDDLEWARE_ADDRESS
        }
    }

    function getBurnRequestFeeBalanceFuseAddressSlot() internal pure returns (AddressType storage $) {
        assembly {
            $.slot := BURNR_REQUEST_FEE_BALANCE_FUSE_ADDRESS
        }
    }

    function getBurnRequestFeeFuseAddressSlot() internal pure returns (AddressType storage $) {
        assembly {
            $.slot := BURN_REQUEST_FEE_FUSE_ADDRESS
        }
    }

    function getIporDaoFeeRecipientAddressSlot() internal pure returns (AddressType storage $) {
        assembly {
            $.slot := IPOR_DAO_FEE_RECIPIENT_ADDRESS
        }
    }

    function getIporDaoManagementFeeSlot() internal pure returns (Uint256Type storage $) {
        assembly {
            $.slot := IPOR_DAO_MANAGEMENT_FEE
        }
    }

    function getIporDaoPerformanceFeeSlot() internal pure returns (Uint256Type storage $) {
        assembly {
            $.slot := IPOR_DAO_PERFORMANCE_FEE
        }
    }

    function getRedemptionDelayInSecondsSlot() internal pure returns (Uint256Type storage $) {
        assembly {
            $.slot := REDEMPTION_DELAY_IN_SECONDS
        }
    }

    function getWithdrawWindowInSecondsSlot() internal pure returns (Uint256Type storage $) {
        assembly {
            $.slot := WITHDRAW_WINDOW_IN_SECONDS
        }
    }

    function getVestingPeriodInSecondsSlot() internal pure returns (Uint256Type storage $) {
        assembly {
            $.slot := VESTING_PERIOD_IN_SECONDS
        }
    }

    
    
    
}
