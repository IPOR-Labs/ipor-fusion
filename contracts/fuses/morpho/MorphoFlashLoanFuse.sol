// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IMorpho} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";

struct MorphoFlashLoanFuseEnterData {
    address token;
    uint256 amount;
    // @dev Callback data to be passed to the flash loan callback. This data should encoded  FuseAction[] array.
    bytes callbackData;
}

/// @title Morpho Flash Loan Fuse
contract MorphoFlashLoanFuse is IFuseCommon {
    using SafeERC20 for ERC20;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    IMorpho public immutable MORPHO;

    error MorphoFlashLoanFuseUnsupportedToken(address token);

    event MorphoFlashLoanFuseEvent(address version, address asset, uint256 amount);

    constructor(uint256 marketId_, address morpho_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        MORPHO = IMorpho(morpho_);
    }

    function enter(MorphoFlashLoanFuseEnterData calldata data_) external {
        if (data_.amount == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.token)) {
            revert MorphoFlashLoanFuseUnsupportedToken(data_.token);
        }

        ERC20(data_.token).forceApprove(address(MORPHO), data_.amount);

        MORPHO.flashLoan(data_.token, data_.amount, data_.callbackData);

        ERC20(data_.token).forceApprove(address(MORPHO), 0);

        emit MorphoFlashLoanFuseEvent(VERSION, data_.token, data_.amount);
    }
}
