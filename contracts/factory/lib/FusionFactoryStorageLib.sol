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
 * - Fee configuration (DAO management and performance fees)
 * - Burn request fee configuration
 *
 * Security Considerations:
 * - Uses ERC-7201 namespaced storage pattern to prevent storage collisions
 * - Each storage struct has a unique namespace derived from its purpose
 * - Critical for maintaining storage integrity in upgradeable contracts
 * - Storage slots are carefully chosen and must not be modified
 */
library FusionFactoryStorageLib {
    struct FactoryAddresses {
        address accessManagerFactory;
        address plasmaVaultFactory;
        address feeManagerFactory;
        address withdrawManagerFactory;
        address rewardsManagerFactory;
        address contextManagerFactory;
        address priceManagerFactory;
    }

    struct AddressType {
        address value;
    }

    struct Uint256Type {
        uint256 value;
    }

    struct AddressArrayType {
        address[] value;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fusion.factory.FusionFactoryVersion")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant FUSION_FACTORY_VERSION =
        0x12d32eeb1bff59ce950917bf8e830c4c4200d70d78bc80ef73671dd3e0c72000;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fusion.factory.FusionFactoryIndex")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant FUSION_FACTORY_INDEX = 0x7c54bb33443ce94044aec2970018125c202903e78abecda9a8871f0a2e085400;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fusion.factory.PlasmaVaultAdminArray")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PLASMA_VAULT_ADMIN_ARRAY =
        0x09e657bd0ea9e1ace5b99e5e8bb556174727dbd9076ea35b667e7736f1584000;

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
    bytes32 private constant BURNR_REQUEST_FEE_BALANCE_FUSE_ADDRESS =
        0xa0dc2f24541d4bbdc49c383a8746cd6256371b67d8afc882e3ce7e04f721df00;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fusion.factory.BurnRequestFeeFuseAddress")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BURN_REQUEST_FEE_FUSE_ADDRESS =
        0xf011e505a711b4f906e6e0cfcd988c477cb335d6eb81d8284628276cae32ab00;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fusion.factory.IporDaoFeeRecipientAddress")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant DAO_FEE_RECIPIENT_ADDRESS =
        0xe26401adf3cefb9a94bf1fba47a8129fd18fd2e2e83de494ce289a832073a500;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fusion.factory.IporDaoManagementFee")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant DAO_MANAGEMENT_FEE = 0x8fc808da4bdddf1c57ae4d57b8d77cb4183e940f6bb88a2aecb349605eb51800;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fusion.factory.IporDaoPerformanceFee")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant DAO_PERFORMANCE_FEE = 0x3d6b96d1c7d5b94a3af077c0baedb5f7745382ef440582d67ffa3542d73b9f00;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fusion.factory.WithdrawWindowInSeconds")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant WITHDRAW_WINDOW_IN_SECONDS =
        0x95f9ecba121b4f2a2786b729864c46a5066694903a7462f772cd92093beb0500;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fusion.factory.VestingPeriodInSeconds")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant VESTING_PERIOD_IN_SECONDS =
        0xe7de166eee522f429c14923fb385ff49d6c65d576ad910fc76c16800f269be00;

    function getFactoryAddresses() internal view returns (FactoryAddresses memory) {
        return
            FactoryAddresses({
                accessManagerFactory: _getAccessManagerFactoryAddressSlot().value,
                plasmaVaultFactory: _getPlasmaVaultFactoryAddressSlot().value,
                feeManagerFactory: _getFeeManagerFactoryAddressSlot().value,
                withdrawManagerFactory: _getWithdrawManagerFactoryAddressSlot().value,
                rewardsManagerFactory: _getRewardsManagerFactoryAddressSlot().value,
                contextManagerFactory: _getContextManagerFactoryAddressSlot().value,
                priceManagerFactory: _getPriceManagerFactoryAddressSlot().value
            });
    }

    function getFusionFactoryVersion() internal view returns (uint256) {
        return _getFusionFactoryVersionSlot().value;
    }

    function getFusionFactoryIndex() internal view returns (uint256) {
        return _getFusionFactoryIndexSlot().value;
    }

    function getPlasmaVaultAdminArray() internal view returns (address[] memory) {
        return _getPlasmaVaultAdminArraySlot().value;
    }

    function getPlasmaVaultBaseAddress() internal view returns (address) {
        return _getPlasmaVaultBaseAddressSlot().value;
    }

    function getPriceOracleMiddleware() internal view returns (address) {
        return _getPriceOracleMiddlewareSlot().value;
    }

    function getBurnRequestFeeBalanceFuseAddress() internal view returns (address) {
        return _getBurnRequestFeeBalanceFuseAddressSlot().value;
    }

    function getBurnRequestFeeFuseAddress() internal view returns (address) {
        return _getBurnRequestFeeFuseAddressSlot().value;
    }

    function getDaoFeeRecipientAddress() internal view returns (address) {
        return _getDaoFeeRecipientAddressSlot().value;
    }

    function getDaoManagementFee() internal view returns (uint256) {
        return _getDaoManagementFeeSlot().value;
    }

    function getDaoPerformanceFee() internal view returns (uint256) {
        return _getDaoPerformanceFeeSlot().value;
    }

    function getWithdrawWindowInSeconds() internal view returns (uint256) {
        return _getWithdrawWindowInSecondsSlot().value;
    }

    function getVestingPeriodInSeconds() internal view returns (uint256) {
        return _getVestingPeriodInSecondsSlot().value;
    }

    function setFusionFactoryVersion(uint256 value) internal {
        _getFusionFactoryVersionSlot().value = value;
    }

    function setFusionFactoryIndex(uint256 value) internal {
        _getFusionFactoryIndexSlot().value = value;
    }

    function setPlasmaVaultAdminArray(address[] memory value) internal {
        delete _getPlasmaVaultAdminArraySlot().value;
        _getPlasmaVaultAdminArraySlot().value = value;
    }

    function setPlasmaVaultFactoryAddress(address value) internal {
        _getPlasmaVaultFactoryAddressSlot().value = value;
    }

    function setAccessManagerFactoryAddress(address value) internal {
        _getAccessManagerFactoryAddressSlot().value = value;
    }

    function setFeeManagerFactoryAddress(address value) internal {
        _getFeeManagerFactoryAddressSlot().value = value;
    }

    function setWithdrawManagerFactoryAddress(address value) internal {
        _getWithdrawManagerFactoryAddressSlot().value = value;
    }

    function setRewardsManagerFactoryAddress(address value) internal {
        _getRewardsManagerFactoryAddressSlot().value = value;
    }

    function setContextManagerFactoryAddress(address value) internal {
        _getContextManagerFactoryAddressSlot().value = value;
    }

    function setPriceManagerFactoryAddress(address value) internal {
        _getPriceManagerFactoryAddressSlot().value = value;
    }

    function setPlasmaVaultBaseAddress(address value) internal {
        _getPlasmaVaultBaseAddressSlot().value = value;
    }

    function setPriceOracleMiddlewareAddress(address value) internal {
        _getPriceOracleMiddlewareSlot().value = value;
    }

    function setBurnRequestFeeBalanceFuseAddress(address value) internal {
        _getBurnRequestFeeBalanceFuseAddressSlot().value = value;
    }

    function setBurnRequestFeeFuseAddress(address value) internal {
        _getBurnRequestFeeFuseAddressSlot().value = value;
    }

    function setDaoFeeRecipientAddress(address value) internal {
        _getDaoFeeRecipientAddressSlot().value = value;
    }

    function setDaoManagementFee(uint256 value) internal {
        _getDaoManagementFeeSlot().value = value;
    }

    function setDaoPerformanceFee(uint256 value) internal {
        _getDaoPerformanceFeeSlot().value = value;
    }

    function setWithdrawWindowInSeconds(uint256 value) internal {
        _getWithdrawWindowInSecondsSlot().value = value;
    }

    function setVestingPeriodInSeconds(uint256 value) internal {
        _getVestingPeriodInSecondsSlot().value = value;
    }

    function _getFusionFactoryVersionSlot() private pure returns (Uint256Type storage $) {
        assembly {
            $.slot := FUSION_FACTORY_VERSION
        }
    }

    function _getFusionFactoryIndexSlot() private pure returns (Uint256Type storage $) {
        assembly {
            $.slot := FUSION_FACTORY_INDEX
        }
    }

    function _getPlasmaVaultAdminArraySlot() private pure returns (AddressArrayType storage $) {
        assembly {
            $.slot := PLASMA_VAULT_ADMIN_ARRAY
        }
    }

    function _getPlasmaVaultFactoryAddressSlot() private pure returns (AddressType storage $) {
        assembly {
            $.slot := PLASMA_VAULT_FACTORY_ADDRESS
        }
    }

    function _getAccessManagerFactoryAddressSlot() private pure returns (AddressType storage $) {
        assembly {
            $.slot := ACCESS_MANAGER_FACTORY_ADDRESS
        }
    }

    function _getFeeManagerFactoryAddressSlot() private pure returns (AddressType storage $) {
        assembly {
            $.slot := FEE_MANAGER_FACTORY_ADDRESS
        }
    }

    function _getRewardsManagerFactoryAddressSlot() private pure returns (AddressType storage $) {
        assembly {
            $.slot := REWARDS_MANAGER_FACTORY_ADDRESS
        }
    }

    function _getWithdrawManagerFactoryAddressSlot() private pure returns (AddressType storage $) {
        assembly {
            $.slot := WITHDRAW_MANAGER_FACTORY_ADDRESS
        }
    }

    function _getContextManagerFactoryAddressSlot() private pure returns (AddressType storage $) {
        assembly {
            $.slot := CONTEXT_MANAGER_FACTORY_ADDRESS
        }
    }

    function _getPriceManagerFactoryAddressSlot() private pure returns (AddressType storage $) {
        assembly {
            $.slot := PRICE_MANAGER_FACTORY_ADDRESS
        }
    }

    function _getPlasmaVaultBaseAddressSlot() private pure returns (AddressType storage $) {
        assembly {
            $.slot := PLASMA_VAULT_BASE_ADDRESS
        }
    }

    function _getPriceOracleMiddlewareSlot() private pure returns (AddressType storage $) {
        assembly {
            $.slot := PRICE_ORACLE_MIDDLEWARE_ADDRESS
        }
    }

    function _getBurnRequestFeeBalanceFuseAddressSlot() private pure returns (AddressType storage $) {
        assembly {
            $.slot := BURNR_REQUEST_FEE_BALANCE_FUSE_ADDRESS
        }
    }

    function _getBurnRequestFeeFuseAddressSlot() private pure returns (AddressType storage $) {
        assembly {
            $.slot := BURN_REQUEST_FEE_FUSE_ADDRESS
        }
    }

    function _getDaoFeeRecipientAddressSlot() private pure returns (AddressType storage $) {
        assembly {
            $.slot := DAO_FEE_RECIPIENT_ADDRESS
        }
    }

    function _getDaoManagementFeeSlot() private pure returns (Uint256Type storage $) {
        assembly {
            $.slot := DAO_MANAGEMENT_FEE
        }
    }

    function _getDaoPerformanceFeeSlot() private pure returns (Uint256Type storage $) {
        assembly {
            $.slot := DAO_PERFORMANCE_FEE
        }
    }

    function _getWithdrawWindowInSecondsSlot() private pure returns (Uint256Type storage $) {
        assembly {
            $.slot := WITHDRAW_WINDOW_IN_SECONDS
        }
    }

    function _getVestingPeriodInSecondsSlot() private pure returns (Uint256Type storage $) {
        assembly {
            $.slot := VESTING_PERIOD_IN_SECONDS
        }
    }
}
