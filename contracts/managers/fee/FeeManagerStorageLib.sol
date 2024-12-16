// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

struct FeeManagerStorage {
    address feeRecipientAddress;
    address iporDaoFeeRecipientAddress;
    uint256 plasmaVaultPerformanceFee;
    uint256 plasmaVaultManagementFee;
}

struct PlasmaVaultTotalPerformanceFeeStorage {
    uint256 value;
}

struct PlasmaVaultTotalManagementFeeStorage {
    uint256 value;
}

struct FeeRecipientDataStorage {
    mapping(address recipient => uint256 feeValue) recipientFees;
    address[] recipientAddresses;
}

library FeeManagerStorageLib {
    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fee.manager.storage")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant STORAGE_SLOT = 0x6b6e11a2184881fb60b9dd5717029d54bff22805620d5aac5728fb19c945a900;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fee.manager.total.performance.fee.storage")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant TOTAL_PERFORMANCE_FEE_SLOT =
        0x8b6e11a2184881fb60b9dd5717029d54bff22805620d5aac5728fb19c945a901;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fee.manager.total.management.fee.storage")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant TOTAL_MANAGEMENT_FEE_SLOT =
        0x9b6e11a2184881fb60b9dd5717029d54bff22805620d5aac5728fb19c945a902;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fee.manager.management.fee.recipient.data.storage")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant MANAGEMENT_FEE_RECIPIENT_DATA_SLOT =
        0xab6e11a2184881fb60b9dd5717029d54bff22805620d5aac5728fb19c945a903;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fee.manager.performance.fee.recipient.data.storage")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant PERFORMANCE_FEE_RECIPIENT_DATA_SLOT =
        0xbb6e11a2184881fb60b9dd5717029d54bff22805620d5aac5728fb19c945a904;

    function _storage() private pure returns (FeeManagerStorage storage $) {
        assembly {
            $.slot := STORAGE_SLOT
        }
    }

    function _totalPerformanceFeeStorage() private pure returns (PlasmaVaultTotalPerformanceFeeStorage storage $) {
        assembly {
            $.slot := TOTAL_PERFORMANCE_FEE_SLOT
        }
    }

    function _totalManagementFeeStorage() private pure returns (PlasmaVaultTotalManagementFeeStorage storage $) {
        assembly {
            $.slot := TOTAL_MANAGEMENT_FEE_SLOT
        }
    }

    function _managementFeeRecipientDataStorage() internal pure returns (FeeRecipientDataStorage storage $) {
        assembly {
            $.slot := MANAGEMENT_FEE_RECIPIENT_DATA_SLOT
        }
    }

    function _performanceFeeRecipientDataStorage() internal pure returns (FeeRecipientDataStorage storage $) {
        assembly {
            $.slot := PERFORMANCE_FEE_RECIPIENT_DATA_SLOT
        }
    }

    function getFeeRecipientAddress() internal view returns (address) {
        return _storage().feeRecipientAddress;
    }

    function setFeeRecipientAddress(address addr) internal {
        _storage().feeRecipientAddress = addr;
    }

    function getIporDaoFeeRecipientAddress() internal view returns (address) {
        return _storage().iporDaoFeeRecipientAddress;
    }

    function setIporDaoFeeRecipientAddress(address addr) internal {
        _storage().iporDaoFeeRecipientAddress = addr;
    }

    function getPlasmaVaultPerformanceFee() internal view returns (uint256) {
        return _storage().plasmaVaultPerformanceFee;
    }

    function setPlasmaVaultPerformanceFee(uint256 fee) internal {
        _storage().plasmaVaultPerformanceFee = fee;
    }

    function getPlasmaVaultManagementFee() internal view returns (uint256) {
        return _storage().plasmaVaultManagementFee;
    }

    function setPlasmaVaultManagementFee(uint256 fee) internal {
        _storage().plasmaVaultManagementFee = fee;
    }

    /// @notice Gets the total performance fee percentage for the plasma vault
    /// @return Total performance fee percentage with 2 decimals (10000 = 100%, 100 = 1%)
    function getPlasmaVaultTotalPerformanceFee() internal view returns (uint256) {
        return _totalPerformanceFeeStorage().value;
    }

    /// @notice Sets the total performance fee percentage for the plasma vault
    /// @param fee Total performance fee percentage with 2 decimals (10000 = 100%, 100 = 1%)
    function setPlasmaVaultTotalPerformanceFee(uint256 fee) internal {
        _totalPerformanceFeeStorage().value = fee;
    }

    /// @notice Gets the total management fee percentage for the plasma vault
    /// @return Total management fee percentage with 2 decimals (10000 = 100%, 100 = 1%)
    function getPlasmaVaultTotalManagementFee() internal view returns (uint256) {
        return _totalManagementFeeStorage().value;
    }

    /// @notice Sets the total management fee percentage for the plasma vault
    /// @param fee Total management fee percentage with 2 decimals (10000 = 100%, 100 = 1%)
    function setPlasmaVaultTotalManagementFee(uint256 fee) internal {
        _totalManagementFeeStorage().value = fee;
    }

    /// @notice Gets the fee value for a specific management fee recipient
    /// @param recipient The address of the recipient
    /// @return The fee value for the recipient
    function getManagementFeeRecipientFee(address recipient) internal view returns (uint256) {
        return _managementFeeRecipientDataStorage().recipientFees[recipient];
    }

    /// @notice Sets the fee value for a specific management fee recipient
    /// @param recipient The address of the recipient
    /// @param feeValue The fee value to set
    function setManagementFeeRecipientFee(address recipient, uint256 feeValue) internal {
        _managementFeeRecipientDataStorage().recipientFees[recipient] = feeValue;
    }

    /// @notice Gets all management fee recipient addresses
    /// @return Array of recipient addresses
    function getManagementFeeRecipientAddresses() internal view returns (address[] memory) {
        return _managementFeeRecipientDataStorage().recipientAddresses;
    }

    /// @notice Sets all management fee recipient addresses
    /// @param addresses Array of recipient addresses to set
    function setManagementFeeRecipientAddresses(address[] memory addresses) internal {
        _managementFeeRecipientDataStorage().recipientAddresses = addresses;
    }

    /// @notice Gets the fee value for a specific performance fee recipient
    /// @param recipient The address of the recipient
    /// @return The fee value for the recipient
    function getPerformanceFeeRecipientFee(address recipient) internal view returns (uint256) {
        return _performanceFeeRecipientDataStorage().recipientFees[recipient];
    }

    /// @notice Sets the fee value for a specific performance fee recipient
    /// @param recipient The address of the recipient
    /// @param feeValue The fee value to set
    function setPerformanceFeeRecipientFee(address recipient, uint256 feeValue) internal {
        _performanceFeeRecipientDataStorage().recipientFees[recipient] = feeValue;
    }

    /// @notice Gets all performance fee recipient addresses
    /// @return Array of recipient addresses
    function getPerformanceFeeRecipientAddresses() internal view returns (address[] memory) {
        return _performanceFeeRecipientDataStorage().recipientAddresses;
    }

    /// @notice Sets all performance fee recipient addresses
    /// @param addresses Array of recipient addresses to set
    function setPerformanceFeeRecipientAddresses(address[] memory addresses) internal {
        _performanceFeeRecipientDataStorage().recipientAddresses = addresses;
    }

    function getFeeConfig() internal view returns (FeeManagerStorage memory) {
        return _storage();
    }
}
