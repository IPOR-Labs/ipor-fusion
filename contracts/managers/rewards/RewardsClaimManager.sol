// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {FusesLib} from "../../libraries/FusesLib.sol";
import {FuseAction} from "../../vaults/PlasmaVault.sol";
import {RewardsClaimManagersStorageLib, VestingData} from "./RewardsClaimManagersStorageLib.sol";
import {PlasmaVault} from "../../vaults/PlasmaVault.sol";
import {IRewardsClaimManager} from "../../interfaces/IRewardsClaimManager.sol";

/// @title RewardsClaimManager contract responsible for managing rewards claiming from the Plasma Vault
contract RewardsClaimManager is AccessManaged, IRewardsClaimManager {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    address public immutable UNDERLYING_TOKEN;
    address public immutable PLASMA_VAULT;

    error UnableToTransferUnderlyingToken();

    event AmountWithdrawn(uint256 amount);

    constructor(address initialAuthority_, address plasmaVault_) AccessManaged(initialAuthority_) {
        UNDERLYING_TOKEN = PlasmaVault(plasmaVault_).asset();
        PLASMA_VAULT = plasmaVault_;
    }

    function balanceOf() public view returns (uint256) {
        VestingData memory data = RewardsClaimManagersStorageLib.getVestingData();

        if (data.updateBalanceTimestamp == 0 || data.vestingTime == 0) {
            return 0;
        }

        uint256 ratio = 1e18;
        if (block.timestamp >= data.updateBalanceTimestamp) {
            ratio = ((block.timestamp - data.updateBalanceTimestamp) * 1e18) / data.vestingTime;
        }

        if (ratio == 0) {
            return 0;
        }

        if (ratio >= 1e18) {
            return data.lastUpdateBalance - data.transferredTokens;
        } else {
            return Math.mulDiv(data.lastUpdateBalance, ratio, 1e18) - data.transferredTokens;
        }
    }

    function isRewardFuseSupported(address fuse_) external view returns (bool) {
        return FusesLib.isFuseSupported(fuse_);
    }

    function getVestingData() external view returns (VestingData memory) {
        return RewardsClaimManagersStorageLib.getVestingData();
    }

    function getRewardsFuses() external view returns (address[] memory) {
        return FusesLib.getFusesArray();
    }

    function transfer(address asset_, address to_, uint256 amount_) external restricted {
        if (asset_ == UNDERLYING_TOKEN) {
            revert UnableToTransferUnderlyingToken();
        }
        IERC20(asset_).safeTransfer(to_, amount_);
    }

    function claimRewards(FuseAction[] calldata calls_) external restricted {
        uint256 len = calls_.length;
        for (uint256 i; i < len; ++i) {
            if (!FusesLib.isFuseSupported(calls_[i].fuse)) {
                revert FusesLib.FuseUnsupported(calls_[i].fuse);
            }
        }

        PlasmaVault(PLASMA_VAULT).claimRewards(calls_);
    }

    function updateBalance() external restricted {
        uint256 balance = balanceOf();
        if (balance > 0) {
            IERC20(UNDERLYING_TOKEN).safeTransfer(PLASMA_VAULT, balance);
        }
        VestingData memory data = RewardsClaimManagersStorageLib.getVestingData();
        data.updateBalanceTimestamp = block.timestamp.toUint32();
        data.lastUpdateBalance = IERC20(UNDERLYING_TOKEN).balanceOf(address(this)).toUint128();
        data.transferredTokens = 0;

        RewardsClaimManagersStorageLib.setVestingData(data);
    }

    function transferVestedTokensToVault() external restricted {
        uint256 balance = balanceOf();
        if (balance == 0) {
            return;
        }
        IERC20(UNDERLYING_TOKEN).safeTransfer(PLASMA_VAULT, balance);
        RewardsClaimManagersStorageLib.updateTransferredTokens(balance);
        emit AmountWithdrawn(balance);
    }

    function addRewardFuses(address[] calldata fuses_) external restricted {
        uint256 len = fuses_.length;
        for (uint256 i; i < len; ++i) {
            FusesLib.addFuse(fuses_[i]);
        }
    }

    function removeRewardFuses(address[] calldata fuses_) external restricted {
        uint256 len = fuses_.length;
        for (uint256 i; i < len; ++i) {
            FusesLib.removeFuse(fuses_[i]);
        }
    }

    function setupVestingTime(uint256 vestingTime_) external restricted {
        RewardsClaimManagersStorageLib.setupVestingTime(vestingTime_);
    }
}
