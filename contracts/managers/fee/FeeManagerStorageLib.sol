// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

error FeeManagerStorageLibZeroAddress();

/// @notice Enum representing the type of fee
enum FeeType {
    MANAGEMENT,
    PERFORMANCE
}

/// @notice Storage structure for DAO fee recipient data
/// @dev Stores the address that receives IPOR DAO fees
struct DaoFeeRecipientDataStorage {
    address iporDaoFeeRecipientAddress;
}

// Add new event with just the new recipient
event IporDaoFeeRecipientAddressChanged(address indexed newRecipient);

event HighWaterMarkPerformanceFeeUpdated(uint128 highWaterMark);
event HighWaterMarkPerformanceFeeUpdateIntervalUpdated(uint32 updateInterval);

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

/// @notice Storage structure for high water mark performance fee logic in plasma vaults
/// @dev Used to track the high water mark (HWM) for performance fee calculation,
///      ensuring fees are only charged on new profits above the previous HWM.
///      - `highWaterMark`: The highest value (e.g., share price or NAV) reached by the vault,
///         used as a reference for performance fee accrual. Expressed in the same units as the tracked metric.
///      - `lastUpdate`: The timestamp (in seconds) of the last HWM update. Used to enforce update intervals and prevent fee gaming.
///      - `updateInterval`: The minimum interval (in seconds) required between HWM updates.
///         Prevents frequent updates that could allow manipulation of performance fee calculations.
/// @custom:security Implements a classic "plasma-style" HWM pattern to mitigate fee abuse and ensure fair fee accrual.
/// @custom:see EIP-4626 for vault fee patterns and best practices.
struct HighWaterMarkPerformanceFeeStorage {
    uint128 highWaterMark;
    uint32 lastUpdate;
    uint32 updateInterval;
}

struct TotalFeeStorage {
    mapping(FeeType feeType => uint256 value) totalFees;
}

/// @title Fee Manager Storage Library
/// @notice Library for managing fee-related storage in the IPOR Protocol's plasma vault system
/// @dev Implements diamond storage pattern for fee management including performance, management, and DAO fees
library FeeManagerStorageLib {
    using SafeCast for uint256;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fee.manager.dao.fee.recipient.data.storage")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant DAO_FEE_RECIPIENT_DATA_SLOT =
        0xaf522f71ce1f2b5702c38f667fa2366c184e3c6dd86ab049ad3b02fec741fd00;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fee.manager.total.management.fee.storage")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant TOTAL_MANAGEMENT_FEE_SLOT =
        0xcf56f35f42e69dcdff0b7b1f2e356cc5f92476bed919f8df0cdbf41f78aa1f00;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fee.manager.management.fee.recipient.data.storage")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant MANAGEMENT_FEE_RECIPIENT_DATA_SLOT =
        0xf1a2374333eb639fe6654c1bd32856f942f1f785e32d72be0c2e035f2e0f8000;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fee.manager.performance.fee.recipient.data.storage")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant PERFORMANCE_FEE_RECIPIENT_DATA_SLOT =
        0xc456e86573d79f7b5b60c9eb824345c471d5390facece9407699845c141b2d00;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fee.manager.high.water.mark.performance.fee.storage")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant HIGH_WATER_MARK_PERFORMANCE_FEE_SLOT =
        0xb9423b11a8779228bace4bf919d779502e12a07e11bd2f782c23aeac55439c00;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fee.manager.total.fee.storage")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant TOTAL_FEE_SLOT = 0xc456e86573d79f7b5b60c9eb824345c471d5390facec19407699845c141b2d00; // TODO: change this to the correct slot

    /// @notice Retrieves management fee recipient data storage
    /// @dev Uses assembly to access diamond storage pattern slot
    /// @return $ Storage pointer to FeeRecipientDataStorage
    function _managementFeeRecipientDataStorage() internal pure returns (FeeRecipientDataStorage storage $) {
        assembly {
            $.slot := MANAGEMENT_FEE_RECIPIENT_DATA_SLOT
        }
    }

    /// @notice Retrieves performance fee recipient data storage
    /// @dev Uses assembly to access diamond storage pattern slot
    /// @return $ Storage pointer to FeeRecipientDataStorage
    function _performanceFeeRecipientDataStorage() internal pure returns (FeeRecipientDataStorage storage $) {
        assembly {
            $.slot := PERFORMANCE_FEE_RECIPIENT_DATA_SLOT
        }
    }

    /// @notice Gets the total performance fee percentage for the plasma vault
    /// @return Total performance fee percentage with 2 decimals (10000 = 100%, 100 = 1%)
    function getPlasmaVaultTotalPerformanceFee() internal view returns (uint256) {
        return _totalFeeStorage().totalFees[FeeType.PERFORMANCE];
    }

    /// @notice Gets the high water mark performance fee percentage for the plasma vault
    /// @return High water mark performance fee percentage with 2 decimals (10000 = 100%, 100 = 1%)
    function getPlasmaVaultHighWaterMarkPerformanceFee()
        internal
        view
        returns (HighWaterMarkPerformanceFeeStorage memory)
    {
        return _highWaterMarkPerformanceFeeStorage();
    }

    function updateHighWaterMarkPerformanceFee(uint128 highWaterMark_) internal {
        HighWaterMarkPerformanceFeeStorage storage $ = _highWaterMarkPerformanceFeeStorage();
        $.highWaterMark = highWaterMark_;
        $.lastUpdate = block.timestamp.toUint32();
        emit HighWaterMarkPerformanceFeeUpdated(highWaterMark_);
    }

    function updateIntervalHighWaterMarkPerformanceFee(uint32 updateInterval_) internal {
        HighWaterMarkPerformanceFeeStorage storage $ = _highWaterMarkPerformanceFeeStorage();
        $.updateInterval = updateInterval_;
        emit HighWaterMarkPerformanceFeeUpdateIntervalUpdated(updateInterval_);
    }

    /// @notice Gets the total management fee percentage for the plasma vault
    /// @return Total management fee percentage with 2 decimals (10000 = 100%, 100 = 1%)
    function getPlasmaVaultTotalManagementFee() internal view returns (uint256) {
        return _totalManagementFeeStorage().value;
    }

    /// @notice Sets the total management fee percentage for the plasma vault
    /// @param fee_ Total management fee percentage with 2 decimals (10000 = 100%, 100 = 1%)
    function setPlasmaVaultTotalManagementFee(uint256 fee_) internal {
        _totalManagementFeeStorage().value = fee_;
    }

    /// @notice Gets the fee value for a specific management fee recipient
    /// @param recipient_ The address of the recipient
    /// @return The fee value for the recipient
    function getManagementFeeRecipientFee(address recipient_) internal view returns (uint256) {
        return _managementFeeRecipientDataStorage().recipientFees[recipient_];
    }

    /// @notice Sets the fee value for a specific management fee recipient
    /// @dev Updates individual recipient's share of the total management fee
    /// @param recipient_ The address of the recipient
    /// @param feeValue_ The fee value to set, representing recipient's share of total fee
    function setManagementFeeRecipientFee(address recipient_, uint256 feeValue_) internal {
        _managementFeeRecipientDataStorage().recipientFees[recipient_] = feeValue_;
    }

    /// @notice Gets all management fee recipient addresses
    /// @return Array of recipient addresses
    function getManagementFeeRecipientAddresses() internal view returns (address[] memory) {
        return _managementFeeRecipientDataStorage().recipientAddresses;
    }

    /// @notice Sets all management fee recipient addresses
    /// @dev Overwrites the entire array of management fee recipients
    /// @param addresses_ Array of recipient addresses to set
    /// @dev Important: This replaces all existing recipients
    function setManagementFeeRecipientAddresses(address[] memory addresses_) internal {
        _managementFeeRecipientDataStorage().recipientAddresses = addresses_;
    }

    /// @notice Gets the fee value for a specific performance fee recipient
    /// @param recipient_ The address of the recipient
    /// @return The fee value for the recipient
    function getPerformanceFeeRecipientFee(address recipient_) internal view returns (uint256) {
        return _performanceFeeRecipientDataStorage().recipientFees[recipient_];
    }

    /// @notice Sets the fee value for a specific performance fee recipient
    /// @param recipient_ The address of the recipient
    /// @param feeValue_ The fee value to set
    function setPerformanceFeeRecipientFee(address recipient_, uint256 feeValue_) internal {
        _performanceFeeRecipientDataStorage().recipientFees[recipient_] = feeValue_;
    }

    /// @notice Gets all performance fee recipient addresses
    /// @return Array of recipient addresses
    function getPerformanceFeeRecipientAddresses() internal view returns (address[] memory) {
        return _performanceFeeRecipientDataStorage().recipientAddresses;
    }

    /// @notice Sets all performance fee recipient addresses
    /// @param addresses_ Array of recipient addresses to set
    function setPerformanceFeeRecipientAddresses(address[] memory addresses_) internal {
        _performanceFeeRecipientDataStorage().recipientAddresses = addresses_;
    }

    /// @notice Gets the IPOR DAO fee recipient address
    /// @return The address of the IPOR DAO fee recipient
    function getIporDaoFeeRecipientAddress() internal view returns (address) {
        return _daoFeeRecipientDataStorage().iporDaoFeeRecipientAddress;
    }

    /// @notice Sets the IPOR DAO fee recipient address
    /// @dev Updates the address that receives DAO fees and emits an event
    /// @param recipientAddress_ The address to set as the IPOR DAO fee recipient
    /// @dev Emits IporDaoFeeRecipientAddressChanged event
    function setIporDaoFeeRecipientAddress(address recipientAddress_) internal {
        _daoFeeRecipientDataStorage().iporDaoFeeRecipientAddress = recipientAddress_;
        emit IporDaoFeeRecipientAddressChanged(recipientAddress_);
    }

    function getTotalFee(FeeType feeType_) internal view returns (uint256) {
        return _totalFeeStorage().totalFees[feeType_];
    }

    function setTotalFee(FeeType feeType_, uint256 value_) internal {
        _totalFeeStorage().totalFees[feeType_] = value_;
    }

    function _daoFeeRecipientDataStorage() private pure returns (DaoFeeRecipientDataStorage storage $) {
        assembly {
            $.slot := DAO_FEE_RECIPIENT_DATA_SLOT
        }
    }

    function _totalManagementFeeStorage() private pure returns (PlasmaVaultTotalManagementFeeStorage storage $) {
        assembly {
            $.slot := TOTAL_MANAGEMENT_FEE_SLOT
        }
    }

    /// @notice Retrieves high water mark performance fee storage
    /// @dev Uses assembly to access diamond storage pattern slot
    /// @return $ Storage pointer to HighWaterMarkPerformanceFeeStorage
    function _highWaterMarkPerformanceFeeStorage() private pure returns (HighWaterMarkPerformanceFeeStorage storage $) {
        assembly {
            $.slot := HIGH_WATER_MARK_PERFORMANCE_FEE_SLOT
        }
    }

    function _totalFeeStorage() private pure returns (TotalFeeStorage storage $) {
        assembly {
            $.slot := TOTAL_FEE_SLOT
        }
    }
}
