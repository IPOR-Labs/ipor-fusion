// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

// At the top of the file, add file-level documentation
/// @title Fee Manager Storage Library
/// @notice Library for managing fee-related storage in the IPOR Protocol's plasma vault system
/// @dev Implements diamond storage pattern for fee management including performance, management, and DAO fees

// Add custom error at the top level, before the structs
error FeeManagerStorageLibZeroAddress();

/// @notice Storage structure for DAO fee recipient data
/// @dev Stores the address that receives IPOR DAO fees
struct DaoFeeRecipientDataStorage {
    address iporDaoFeeRecipientAddress;
}

// Add new event with just the new recipient
event IporDaoFeeRecipientAddressChanged(address indexed newRecipient);

/// @notice Storage structure for total performance fee in plasma vault
/// @dev Value stored with 2 decimal precision (10000 = 100%)
struct PlasmaVaultTotalPerformanceFeeStorage {
    uint256 value;
}

/// @notice Storage structure for total management fee in plasma vault
/// @dev Value stored with 2 decimal precision (10000 = 100%)
struct PlasmaVaultTotalManagementFeeStorage {
    uint256 value;
}

/// @notice Storage structure for fee recipient data
/// @dev Maps recipient addresses to their fee allocations and maintains list of recipients
struct FeeRecipientDataStorage {
    mapping(address recipient => uint256 feeValue) recipientFees;
    address[] recipientAddresses;
}

library FeeManagerStorageLib {
    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fee.manager.dao.fee.recipient.data.storage")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant DAO_FEE_RECIPIENT_DATA_SLOT =
        0xaf522f71ce1f2b5702c38f667fa2366c184e3c6dd86ab049ad3b02fec741fd00;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fee.manager.total.performance.fee.storage")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant TOTAL_PERFORMANCE_FEE_SLOT =
        0x91a7fd667a02d876183d5e3c0caf915fa5c0b6847afae1b6a2261f7bce984500;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fee.manager.total.management.fee.storage")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant TOTAL_MANAGEMENT_FEE_SLOT =
        0xcf56f35f42e69dcdff0b7b1f2e356cc5f92476bed919f8df0cdbf41f78aa1f00;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fee.manager.management.fee.recipient.data.storage")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant MANAGEMENT_FEE_RECIPIENT_DATA_SLOT =
        0xf1a2374333eb639fe6654c1bd32856f942f1f785e32d72be0c2e035f2e0f8000;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fee.manager.performance.fee.recipient.data.storage")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant PERFORMANCE_FEE_RECIPIENT_DATA_SLOT =
        0xc456e86573d79f7b5b60c9eb824345c471d5390facece9407699845c141b2d00;

    /// @notice Retrieves management fee recipient data storage
    /// @dev Uses assembly to access diamond storage pattern slot
    /// @return Storage pointer to FeeRecipientDataStorage
    function _managementFeeRecipientDataStorage() internal pure returns (FeeRecipientDataStorage storage $) {
        assembly {
            $.slot := MANAGEMENT_FEE_RECIPIENT_DATA_SLOT
        }
    }

    /// @notice Retrieves performance fee recipient data storage
    /// @dev Uses assembly to access diamond storage pattern slot
    /// @return Storage pointer to FeeRecipientDataStorage
    function _performanceFeeRecipientDataStorage() internal pure returns (FeeRecipientDataStorage storage $) {
        assembly {
            $.slot := PERFORMANCE_FEE_RECIPIENT_DATA_SLOT
        }
    }

    /// @notice Gets the total performance fee percentage for the plasma vault
    /// @return Total performance fee percentage with 2 decimals (10000 = 100%, 100 = 1%)
    function getPlasmaVaultTotalPerformanceFee() internal view returns (uint256) {
        return _totalPerformanceFeeStorage().value;
    }

    /// @notice Sets the total performance fee percentage for the plasma vault
    /// @dev Updates the total performance fee that will be distributed among recipients
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
    /// @dev Updates individual recipient's share of the total management fee
    /// @param recipient The address of the recipient
    /// @param feeValue The fee value to set, representing recipient's share of total fee
    function setManagementFeeRecipientFee(address recipient, uint256 feeValue) internal {
        _managementFeeRecipientDataStorage().recipientFees[recipient] = feeValue;
    }

    /// @notice Gets all management fee recipient addresses
    /// @return Array of recipient addresses
    function getManagementFeeRecipientAddresses() internal view returns (address[] memory) {
        return _managementFeeRecipientDataStorage().recipientAddresses;
    }

    /// @notice Sets all management fee recipient addresses
    /// @dev Overwrites the entire array of management fee recipients
    /// @param addresses Array of recipient addresses to set
    /// @dev Important: This replaces all existing recipients
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

    /// @notice Gets the IPOR DAO fee recipient address
    /// @return The address of the IPOR DAO fee recipient
    function getIporDaoFeeRecipientAddress() internal view returns (address) {
        return _daoFeeRecipientDataStorage().iporDaoFeeRecipientAddress;
    }

    /// @notice Sets the IPOR DAO fee recipient address
    /// @dev Updates the address that receives DAO fees and emits an event
    /// @param recipientAddress The address to set as the IPOR DAO fee recipient
    /// @dev Emits IporDaoFeeRecipientAddressChanged event
    function setIporDaoFeeRecipientAddress(address recipientAddress) internal {
        if (recipientAddress == address(0)) revert FeeManagerStorageLibZeroAddress();
        _daoFeeRecipientDataStorage().iporDaoFeeRecipientAddress = recipientAddress;
        emit IporDaoFeeRecipientAddressChanged(recipientAddress);
    }

    function _daoFeeRecipientDataStorage() private pure returns (DaoFeeRecipientDataStorage storage $) {
        assembly {
            $.slot := DAO_FEE_RECIPIENT_DATA_SLOT
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
}
