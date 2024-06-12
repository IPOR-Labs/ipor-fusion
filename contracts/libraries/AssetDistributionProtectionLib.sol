// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {PlasmaVaultStorageLib} from "./PlasmaVaultStorageLib.sol";

struct MarketToCheck {
    uint256 marketId;
    uint256 balanceInMarket;
}

struct DataToCheck {
    uint256 totalBalanceInVault;
    MarketToCheck[] marketsToCheck;
}

library AssetDistributionProtectionLib {


    function
}
