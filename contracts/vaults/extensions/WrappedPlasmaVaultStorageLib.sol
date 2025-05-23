// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Errors} from "../../libraries/errors/Errors.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

struct PerformanceFeeData {
    address feeAccount;
    uint16 feeInPercentage;
}

library WrappedPlasmaVaultStorageLib {
    using SafeCast for uint256;

    event PerformanceFeeDataConfigured(address feeAccount, uint256 feeInPercentage);

    error InvalidPerformanceFee(uint256 feeInPercentage);
    error InvalidManagementFee(uint256 feeInPercentage);

    bytes32 private constant PLASMA_VAULT_PERFORMANCE_FEE_DATA =
        0x9399757a27831a6cfb6cf4cd5c97a908a2f8f41e95a5952fbf83a04e05288400;

    uint256 public constant PERFORMANCE_MAX_FEE_IN_PERCENTAGE = 5000;

    function configurePerformanceFee(address feeAccount_, uint256 feeInPercentage_) internal {
        if (feeAccount_ == address(0)) {
            revert Errors.WrongAddress();
        }
        if (feeInPercentage_ > PERFORMANCE_MAX_FEE_IN_PERCENTAGE) {
            revert InvalidPerformanceFee(feeInPercentage_);
        }

        PerformanceFeeData storage performanceFeeData = _getPerformanceFeeData();

        performanceFeeData.feeAccount = feeAccount_;
        performanceFeeData.feeInPercentage = feeInPercentage_.toUint16();

        emit PerformanceFeeDataConfigured(feeAccount_, feeInPercentage_);
    }

    function getPerformanceFeeData() internal view returns (PerformanceFeeData memory feeData) {
        feeData = _getPerformanceFeeData();
    }

    function _getPerformanceFeeData() private pure returns (PerformanceFeeData storage performanceFeeData) {
        assembly {
            performanceFeeData.slot := PLASMA_VAULT_PERFORMANCE_FEE_DATA
        }
    }
}
