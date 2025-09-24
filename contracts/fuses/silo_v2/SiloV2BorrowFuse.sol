// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";

import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SiloIndex} from "./SiloIndex.sol";
import {ISilo} from "./ext/ISilo.sol";
import {ISiloConfig} from "./ext/ISiloConfig.sol";
struct SiloV2BorrowFuseEnterData {
    /// @dev Silo Config address - contract that manages the Silo
    address siloConfig;
    /// @dev Specify which silo to supply Silo0 or Silo1
    SiloIndex siloIndex;
    /// @dev amount of Silo underlying asset to supply
    uint256 siloAssetAmount;
}

struct SiloV2BorrowFuseExitData {
    /// @dev Silo Config address - contract that manages the Silo
    address siloConfig;
    /// @dev Specify which silo to supply Silo0 or Silo1
    SiloIndex siloIndex;
    /// @dev amount of Silo underlying asset to supply
    uint256 siloAssetAmount;
}

contract SiloV2BorrowFuse is IFuseCommon {
    using SafeERC20 for ERC20;

    /// @dev The version of the contract.
    address public immutable VERSION;
    /// @dev The unique identifier for IporFusionMarkets.
    uint256 public immutable MARKET_ID;

    error SiloV2BorrowFuseUnsupportedSiloConfig(string action, address siloConfig);

    event SiloV2BorrowFuseEvent(
        address version,
        uint256 marketId,
        address siloConfig,
        address silo,
        uint256 siloAssetAmountBorrowed,
        uint256 siloSharesBorrowed
    );

    event SiloV2BorrowFuseRepay(
        address version,
        uint256 marketId,
        address siloConfig,
        address silo,
        uint256 siloAssetAmountRepaid,
        uint256 siloSharesRepaid
    );

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    function enter(SiloV2BorrowFuseEnterData calldata data_) public {
        if (data_.siloAssetAmount == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.siloConfig)) {
            revert SiloV2BorrowFuseUnsupportedSiloConfig("enter", data_.siloConfig);
        }

        (address silo0, address silo1) = ISiloConfig(data_.siloConfig).getSilos();

        address silo = data_.siloIndex == SiloIndex.SILO0 ? silo0 : silo1;

        uint256 sharesBorrowed = ISilo(silo).borrow(data_.siloAssetAmount, address(this), address(this));

        emit SiloV2BorrowFuseEvent(VERSION, MARKET_ID, data_.siloConfig, silo, data_.siloAssetAmount, sharesBorrowed);
    }

    function exit(SiloV2BorrowFuseExitData calldata data_) public {
        if (data_.siloAssetAmount == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.siloConfig)) {
            revert SiloV2BorrowFuseUnsupportedSiloConfig("exit", data_.siloConfig);
        }

        (address silo0, address silo1) = ISiloConfig(data_.siloConfig).getSilos();

        address silo = data_.siloIndex == SiloIndex.SILO0 ? silo0 : silo1;

        address siloAssetAddress = ISilo(silo).asset();

        ERC20(siloAssetAddress).forceApprove(silo, data_.siloAssetAmount);

        uint256 sharesRepaid = ISilo(silo).repay(data_.siloAssetAmount, address(this));

        ERC20(siloAssetAddress).forceApprove(silo, 0);

        emit SiloV2BorrowFuseRepay(VERSION, MARKET_ID, data_.siloConfig, silo, data_.siloAssetAmount, sharesRepaid);
    }
}
