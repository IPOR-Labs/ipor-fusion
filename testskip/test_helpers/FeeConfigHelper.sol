// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {FeeManagerFactory, FeeConfig, RecipientFee} from "../../contracts/managers/fee/FeeManagerFactory.sol";

/// @title FeeConfigHelper
/// @notice Helper library for creating fee configurations in tests
library FeeConfigHelper {
    /// @notice Creates a basic fee configuration with zero fees
    /// @return FeeConfig with zero fees and empty recipients
    function createZeroFeeConfig() internal returns (FeeConfig memory) {
        RecipientFee[] memory recipientFees = new RecipientFee[](1);
        recipientFees[0] = RecipientFee({recipient: address(56756756), feeValue: 0});

        return
            FeeConfig({
                iporDaoManagementFee: 0,
                iporDaoPerformanceFee: 0,
                feeFactory: address(new FeeManagerFactory()),
                iporDaoFeeRecipientAddress: address(98989898),
                recipientManagementFees: recipientFees,
                recipientPerformanceFees: recipientFees
            });
    }
}
