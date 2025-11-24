// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFuseCommon} from "../IFuseCommon.sol";
import {EnsoExecutor} from "./EnsoExecutor.sol";
import {EnsoStorageLib} from "./lib/EnsoStorageLib.sol";

/// @title EnsoInitExecutorFuse
/// @notice This contract is designed to initialize and store the EnsoExecutor instance
/// @dev Provides a dedicated fuse for one-time executor creation and storage
contract EnsoInitExecutorFuse is IFuseCommon {
    event EnsoExecutorCreated(address executor, address plasmaVault, address delegateEnsoShortcuts, address weth);

    error EnsoInitExecutorInvalidWethAddress();
    error EnsoInitExecutorInvalidAddress();

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address public immutable WETH;
    address public immutable DELEGATE_ENSO_SHORTCUTS;

    constructor(uint256 marketId_, address weth_, address delegateEnsoShortcuts_) {
        if (weth_ == address(0)) {
            revert EnsoInitExecutorInvalidWethAddress();
        }

        if (delegateEnsoShortcuts_ == address(0)) {
            revert EnsoInitExecutorInvalidAddress();
        }

        VERSION = address(this);
        MARKET_ID = marketId_;
        WETH = weth_;
        DELEGATE_ENSO_SHORTCUTS = delegateEnsoShortcuts_;
    }

    /// @notice Creates a new EnsoExecutor and stores its address in storage if it doesn't exist
    /// @dev This function is parameterless and can be called to initialize the executor
    function enter() external {
        address executorAddress = EnsoStorageLib.getEnsoExecutor();

        if (executorAddress == address(0)) {
            executorAddress = address(new EnsoExecutor(DELEGATE_ENSO_SHORTCUTS, WETH, address(this)));
            EnsoStorageLib.setEnsoExecutor(executorAddress);
            emit EnsoExecutorCreated(executorAddress, address(this), DELEGATE_ENSO_SHORTCUTS, WETH);
        }
    }
}
