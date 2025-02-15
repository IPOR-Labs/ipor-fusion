// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IFuseCommon} from "../IFuse.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {PlasmaVaultStorageLib} from "../../libraries/PlasmaVaultStorageLib.sol";

struct BurnRequestFeeDataEnter {
    uint256 amount;
}

contract BurnRequestFeeFuse is IFuseCommon, ERC20Upgradeable {
    error BurnRequestFeeWithdrawManagerNotSet();
    error BurnRequestFeeExitNotImplemented();
    event BurnRequestFeeEnter(address version, uint256 amount);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) initializer {
        VERSION = address(this);
        MARKET_ID = marketId_;
        __ERC20_init("Burn Request Fee - Fuse", "BRF");
    }

    function enter(BurnRequestFeeDataEnter memory data_) external {
        address withdrawManager = PlasmaVaultStorageLib.getWithdrawManager().manager;

        if (withdrawManager == address(0)) {
            revert BurnRequestFeeWithdrawManagerNotSet();
        }

        if (data_.amount == 0) {
            return;
        }

        _burn(withdrawManager, data_.amount);

        emit BurnRequestFeeEnter(VERSION, data_.amount);
    }

    function exit() external pure {
        revert BurnRequestFeeExitNotImplemented();
    }
}
