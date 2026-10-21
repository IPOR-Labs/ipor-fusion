// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockRemoteVault} from "./MockRemoteVault.sol";

/// @title MockPausableRemoteVault
/// @notice Remote ERC-4626 whose deposits can be switched off (`maxDeposit` = 0), the shape of a paused or capped
///         vault. OZ `deposit` then reverts `ERC4626ExceededMaxDeposit` (non-empty data), so the dispatcher NACKs the
///         DEPOSIT as a business failure and the command stays FAILED on the executor.
contract MockPausableRemoteVault is MockRemoteVault {
    bool public paused;

    constructor(IERC20 asset_) MockRemoteVault(asset_, "Pausable Remote Vault", "PRV") {}

    function setPaused(bool paused_) external {
        paused = paused_;
    }

    function maxDeposit(address receiver_) public view override returns (uint256) {
        return paused ? 0 : super.maxDeposit(receiver_);
    }
}

/// @title MockAssetSwitchRemoteVault
/// @notice Remote ERC-4626 whose reported `asset()` can be switched. While it reports a foreign asset the dispatcher
///         refuses to allowlist it (`InvalidVault`), so an allowlist-adding update is NACKed and stays FAILED.
contract MockAssetSwitchRemoteVault is MockRemoteVault {
    address public reportedAsset;

    constructor(IERC20 asset_) MockRemoteVault(asset_, "Asset Switch Remote Vault", "ASV") {}

    function setReportedAsset(address asset_) external {
        reportedAsset = asset_;
    }

    function asset() public view override returns (address) {
        return reportedAsset == address(0) ? super.asset() : reportedAsset;
    }
}
