// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

struct FeeManagerStorage {
    address feeRecipientAddress;
    address iporDaoFeeRecipientAddress;
    uint256 plasmaVaultPerformanceFee;
    uint256 plasmaVaultManagementFee;
}

library FeeManagerStorageLib {
    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.fee.manager.storage")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant STORAGE_SLOT = 0x5a7c8692a29c4479a56e6edcb3f8c3f9e9e6e4e3d2c1b0a9f8e7d6c5b4a39300;

    function _storage() private pure returns (FeeManagerStorage storage $) {
        assembly {
            $.slot := STORAGE_SLOT
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

    function getFeeConfig() internal view returns (FeeManagerStorage memory) {
        return _storage();
    }
}
