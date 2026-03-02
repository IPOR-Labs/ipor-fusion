// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

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
/// @notice Component identifiers for lazy deployment
enum Component {
    RewardsManager,
    ContextManager
}

/// @notice Stores all addresses for a vault instance (deployed + pending)
struct VaultInstanceAddresses {
    bytes32 masterSalt;
    // Phase 1 — deployed atomically
    address plasmaVault;
    address accessManager;
    address priceManager;
    address withdrawManager;
    address feeManager; // created inside PlasmaVault.init, NOT deterministic
    // Phase 2 — pre-computed, deployed later via deployComponent()
    address rewardsManager; // deterministic, lazy-deployed
    address contextManager; // deterministic, lazy-deployed
    // Deployment status flags
    bool rewardsManagerDeployed;
    bool contextManagerDeployed;
    // Stored for AccessManager re-initialization when Phase 2 components are deployed
    address owner;
    bool withAdmin;
    address daoFeeRecipientAddress;
}

library FusionFactoryStorageLib {
    struct BaseAddresses {
        address plasmaVaultCoreBase;
        address accessManagerBase;
        address priceManagerBase;
        address withdrawManagerBase;
        address rewardsManagerBase;
        address contextManagerBase;
    }
    struct FactoryAddresses {
        address accessManagerFactory;
        address plasmaVaultFactory;
        address feeManagerFactory;
        address withdrawManagerFactory;
        address rewardsManagerFactory;
        address contextManagerFactory;
        address priceManagerFactory;
    }

    /// @notice Fee package structure for vault creation
    /// @param managementFee Management fee with 2 decimals (10000 = 100%)
    /// @param performanceFee Performance fee with 2 decimals (10000 = 100%)
    /// @param feeRecipient Address that receives the fees
    struct FeePackage {
        uint256 managementFee;
        uint256 performanceFee;
        address feeRecipient;
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

    /// @dev ERC-7201 namespaced storage struct for DAO fee packages
    struct DaoFeePackagesStorage {
        FeePackage[] packages;
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
        0xe03d6bb506e833b55bb7e35e66d871fd1486b3efc6bb02b49fae15b9d0247c01;

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

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fusion.factory.FeePackages")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant DAO_FEE_PACKAGES_STORAGE_SLOT =
        0x59feb9265c4719d36ddde95dfd6b130deb8154e067cc891498b39e0bd8956900;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fusion.factory.WithdrawWindowInSeconds")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant WITHDRAW_WINDOW_IN_SECONDS =
        0x95f9ecba121b4f2a2786b729864c46a5066694903a7462f772cd92093beb0500;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fusion.factory.VestingPeriodInSeconds")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant VESTING_PERIOD_IN_SECONDS =
        0xe7de166eee522f429c14923fb385ff49d6c65d576ad910fc76c16800f269be00;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fusion.factory.AccessManagerBaseAddress")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ACCESS_MANAGER_BASE_ADDRESS =
        0xdee5af15cbb5c7d3f575c81c43b164c912e2cacae09ac95ab04460973550ec00;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fusion.factory.WithdrawManagerBaseAddress")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant WITHDRAW_MANAGER_BASE_ADDRESS =
        0x71c920154481896f4e6224fa3f403d92b902534a39efd0adf8948440a29f6900;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fusion.factory.RewardsManagerBaseAddress")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant REWARDS_MANAGER_BASE_ADDRESS =
        0x7947c1b14a70a26b8ee1c91656f600b5c452629fc225e1bd435f2d73da810600;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fusion.factory.ContextManagerBaseAddress")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CONTEXT_MANAGER_BASE_ADDRESS =
        0x327c4805778da4e3703f4a6907d698c910c93cbbedf6f536be61f90d407ed600;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fusion.factory.PriceManagerBaseAddress")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PRICE_MANAGER_BASE_ADDRESS =
        0x5e1e7003d30cfb3abdb5e35688c765a955b6455e91670898a8e5c73d9c677000;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fusion.factory.PlasmaVaultCoreBaseAddress")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PLASMA_VAULT_CORE_BASE_ADDRESS =
        0x64580ae806e62df65aec7b569ca88d764fcb6a37f8b0f20662030e6001952700;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fusion.factory.VaultInstances")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant VAULT_INSTANCES =
        0x03ff616484bc7e9a9055e1b4c004c1779c28b6de187fb358bb61255f168bf800;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fusion.factory.VaultByIndex")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant VAULT_BY_INDEX =
        0x1dc87522d04ceda83867368990d1c95f7259de0f353ad136d9f7a4cca7b1c200;

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

    function getBaseAddresses() internal view returns (BaseAddresses memory) {
        return
            BaseAddresses({
                plasmaVaultCoreBase: _getPlasmaVaultCoreBaseAddressSlot().value,
                accessManagerBase: _getAccessManagerBaseAddressSlot().value,
                priceManagerBase: _getPriceManagerBaseAddressSlot().value,
                withdrawManagerBase: _getWithdrawManagerBaseAddressSlot().value,
                rewardsManagerBase: _getRewardsManagerBaseAddressSlot().value,
                contextManagerBase: _getContextManagerBaseAddressSlot().value
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

    function getWithdrawWindowInSeconds() internal view returns (uint256) {
        return _getWithdrawWindowInSecondsSlot().value;
    }

    function getVestingPeriodInSeconds() internal view returns (uint256) {
        return _getVestingPeriodInSecondsSlot().value;
    }

    function getAccessManagerBaseAddress() internal view returns (address) {
        return _getAccessManagerBaseAddressSlot().value;
    }

    function getWithdrawManagerBaseAddress() internal view returns (address) {
        return _getWithdrawManagerBaseAddressSlot().value;
    }

    function getRewardsManagerBaseAddress() internal view returns (address) {
        return _getRewardsManagerBaseAddressSlot().value;
    }

    function getContextManagerBaseAddress() internal view returns (address) {
        return _getContextManagerBaseAddressSlot().value;
    }

    function getPriceManagerBaseAddress() internal view returns (address) {
        return _getPriceManagerBaseAddressSlot().value;
    }

    function getPlasmaVaultCoreBaseAddress() internal view returns (address) {
        return _getPlasmaVaultCoreBaseAddressSlot().value;
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

    function setWithdrawWindowInSeconds(uint256 value) internal {
        _getWithdrawWindowInSecondsSlot().value = value;
    }

    function setVestingPeriodInSeconds(uint256 value) internal {
        _getVestingPeriodInSecondsSlot().value = value;
    }

    function setAccessManagerBaseAddress(address value) internal {
        _getAccessManagerBaseAddressSlot().value = value;
    }

    function setWithdrawManagerBaseAddress(address value) internal {
        _getWithdrawManagerBaseAddressSlot().value = value;
    }

    function setRewardsManagerBaseAddress(address value) internal {
        _getRewardsManagerBaseAddressSlot().value = value;
    }

    function setContextManagerBaseAddress(address value) internal {
        _getContextManagerBaseAddressSlot().value = value;
    }

    function setPriceManagerBaseAddress(address value) internal {
        _getPriceManagerBaseAddressSlot().value = value;
    }

    function setPlasmaVaultCoreBaseAddress(address value) internal {
        _getPlasmaVaultCoreBaseAddressSlot().value = value;
    }

    function _getAccessManagerBaseAddressSlot() private pure returns (AddressType storage $) {
        assembly {
            $.slot := ACCESS_MANAGER_BASE_ADDRESS
        }
    }

    function _getWithdrawManagerBaseAddressSlot() private pure returns (AddressType storage $) {
        assembly {
            $.slot := WITHDRAW_MANAGER_BASE_ADDRESS
        }
    }

    function _getRewardsManagerBaseAddressSlot() private pure returns (AddressType storage $) {
        assembly {
            $.slot := REWARDS_MANAGER_BASE_ADDRESS
        }
    }

    function _getContextManagerBaseAddressSlot() private pure returns (AddressType storage $) {
        assembly {
            $.slot := CONTEXT_MANAGER_BASE_ADDRESS
        }
    }

    function _getPriceManagerBaseAddressSlot() private pure returns (AddressType storage $) {
        assembly {
            $.slot := PRICE_MANAGER_BASE_ADDRESS
        }
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

    function _getPlasmaVaultCoreBaseAddressSlot() private pure returns (AddressType storage $) {
        assembly {
            $.slot := PLASMA_VAULT_CORE_BASE_ADDRESS
        }
    }

    // ============ DAO Fee Packages Storage Functions ============

    function _getDaoFeePackagesStorageSlot() private pure returns (DaoFeePackagesStorage storage $) {
        assembly {
            $.slot := DAO_FEE_PACKAGES_STORAGE_SLOT
        }
    }

    /// @notice Returns all DAO fee packages
    /// @return Array of DAO fee packages
    function getDaoFeePackages() internal view returns (FeePackage[] memory) {
        return _getDaoFeePackagesStorageSlot().packages;
    }

    /// @notice Returns a specific DAO fee package by index
    /// @param index_ Index of the DAO fee package
    /// @return DAO fee package at the specified index
    function getDaoFeePackage(uint256 index_) internal view returns (FeePackage memory) {
        return _getDaoFeePackagesStorageSlot().packages[index_];
    }

    /// @notice Returns the number of DAO fee packages
    /// @return Number of DAO fee packages
    function getDaoFeePackagesLength() internal view returns (uint256) {
        return _getDaoFeePackagesStorageSlot().packages.length;
    }

    /// @notice Sets DAO fee packages (replaces entire array)
    /// @param packages_ Array of DAO fee packages to set
    function setDaoFeePackages(FeePackage[] memory packages_) internal {
        delete _getDaoFeePackagesStorageSlot().packages;
        FeePackage[] storage storagePackages = _getDaoFeePackagesStorageSlot().packages;
        uint256 length = packages_.length;
        for (uint256 i; i < length; ++i) {
            storagePackages.push(packages_[i]);
        }
    }

    // ============ Vault Instance Addresses Storage Functions ============

    /// @notice Returns the vault instance addresses for a given plasma vault
    /// @param plasmaVault_ Address of the plasma vault
    /// @return Vault instance addresses struct
    function getVaultInstanceAddresses(address plasmaVault_) internal view returns (VaultInstanceAddresses memory) {
        bytes32 slot = _getVaultInstanceSlot(plasmaVault_);
        VaultInstanceAddresses memory result;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            // Load all struct fields from consecutive storage slots starting at `slot`
            mstore(result, sload(slot)) // masterSalt
            mstore(add(result, 0x20), sload(add(slot, 1))) // plasmaVault
            mstore(add(result, 0x40), sload(add(slot, 2))) // accessManager
            mstore(add(result, 0x60), sload(add(slot, 3))) // priceManager
            mstore(add(result, 0x80), sload(add(slot, 4))) // withdrawManager
            mstore(add(result, 0xa0), sload(add(slot, 5))) // feeManager
            mstore(add(result, 0xc0), sload(add(slot, 6))) // rewardsManager
            mstore(add(result, 0xe0), sload(add(slot, 7))) // contextManager
            mstore(add(result, 0x100), sload(add(slot, 8))) // rewardsManagerDeployed
            mstore(add(result, 0x120), sload(add(slot, 9))) // contextManagerDeployed
            mstore(add(result, 0x140), sload(add(slot, 10))) // owner
            mstore(add(result, 0x160), sload(add(slot, 11))) // withAdmin
            mstore(add(result, 0x180), sload(add(slot, 12))) // daoFeeRecipientAddress
        }
        return result;
    }

    /// @notice Sets the vault instance addresses for a given plasma vault
    /// @param plasmaVault_ Address of the plasma vault
    /// @param addresses_ Vault instance addresses to store
    function setVaultInstanceAddresses(address plasmaVault_, VaultInstanceAddresses memory addresses_) internal {
        bytes32 slot = _getVaultInstanceSlot(plasmaVault_);
        // solhint-disable-next-line no-inline-assembly
        assembly {
            sstore(slot, mload(addresses_)) // masterSalt
            sstore(add(slot, 1), mload(add(addresses_, 0x20))) // plasmaVault
            sstore(add(slot, 2), mload(add(addresses_, 0x40))) // accessManager
            sstore(add(slot, 3), mload(add(addresses_, 0x60))) // priceManager
            sstore(add(slot, 4), mload(add(addresses_, 0x80))) // withdrawManager
            sstore(add(slot, 5), mload(add(addresses_, 0xa0))) // feeManager
            sstore(add(slot, 6), mload(add(addresses_, 0xc0))) // rewardsManager
            sstore(add(slot, 7), mload(add(addresses_, 0xe0))) // contextManager
            sstore(add(slot, 8), mload(add(addresses_, 0x100))) // rewardsManagerDeployed
            sstore(add(slot, 9), mload(add(addresses_, 0x120))) // contextManagerDeployed
            sstore(add(slot, 10), mload(add(addresses_, 0x140))) // owner
            sstore(add(slot, 11), mload(add(addresses_, 0x160))) // withAdmin
            sstore(add(slot, 12), mload(add(addresses_, 0x180))) // daoFeeRecipientAddress
        }
    }

    /// @notice Marks a component as deployed for a given plasma vault
    /// @param plasmaVault_ Address of the plasma vault
    /// @param component_ Component to mark as deployed
    function markComponentDeployed(address plasmaVault_, Component component_) internal {
        bytes32 slot = _getVaultInstanceSlot(plasmaVault_);
        // solhint-disable-next-line no-inline-assembly
        assembly {
            // rewardsManagerDeployed is at offset 8, contextManagerDeployed at offset 9
            let flagSlot := add(slot, add(8, component_))
            sstore(flagSlot, 1)
        }
    }

    // ============ Vault By Index Storage Functions ============

    /// @notice Returns the plasma vault address for a given index
    /// @param index_ Index of the vault
    /// @return Plasma vault address
    function getVaultByIndex(uint256 index_) internal view returns (address) {
        bytes32 slot = _getVaultByIndexSlot(index_);
        address result;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            result := sload(slot)
        }
        return result;
    }

    /// @notice Sets the plasma vault address for a given index
    /// @param index_ Index of the vault
    /// @param plasmaVault_ Address of the plasma vault
    function setVaultByIndex(uint256 index_, address plasmaVault_) internal {
        bytes32 slot = _getVaultByIndexSlot(index_);
        // solhint-disable-next-line no-inline-assembly
        assembly {
            sstore(slot, plasmaVault_)
        }
    }

    /// @dev Computes the storage slot for a vault instance mapping entry
    /// @param plasmaVault_ The key (plasma vault address)
    /// @return The storage slot
    function _getVaultInstanceSlot(address plasmaVault_) private pure returns (bytes32) {
        return keccak256(abi.encode(plasmaVault_, VAULT_INSTANCES));
    }

    /// @dev Computes the storage slot for a vault-by-index mapping entry
    /// @param index_ The key (vault index)
    /// @return The storage slot
    function _getVaultByIndexSlot(uint256 index_) private pure returns (bytes32) {
        return keccak256(abi.encode(index_, VAULT_BY_INDEX));
    }
}
