// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockRemoteVault} from "./MockRemoteVault.sol";

/// @title MockOverReportingVault
/// @notice Non-conforming ERC-4626 (IL-8601): pulls the full asset amount, mints only `mintedPercent` of the
///         conforming share amount (0 = nothing) and RETURNS `reportedMultiplier` times the conforming amount.
contract MockOverReportingVault is MockRemoteVault {
    uint256 public mintedPercent;
    uint256 public reportedMultiplier;

    constructor(IERC20 asset_, uint256 mintedPercent_, uint256 reportedMultiplier_)
        MockRemoteVault(asset_, "OverReport", "OVR")
    {
        mintedPercent = mintedPercent_;
        reportedMultiplier = reportedMultiplier_;
    }

    function deposit(uint256 assets_, address receiver_) public override returns (uint256) {
        uint256 honest = previewDeposit(assets_);
        uint256 minted = (honest * mintedPercent) / 100;
        _deposit(_msgSender(), receiver_, assets_, minted);
        return honest * reportedMultiplier;
    }
}
