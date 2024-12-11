// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessManagedUpgradeable} from "../access/AccessManagedUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {AuthorityUtils} from "@openzeppelin/contracts/access/manager/AuthorityUtils.sol";
import {FusesLib} from "../../libraries/FusesLib.sol";
import {FuseAction} from "../../vaults/PlasmaVault.sol";
import {RewardsClaimManagersStorageLib, VestingData} from "./RewardsClaimManagersStorageLib.sol";
import {PlasmaVault} from "../../vaults/PlasmaVault.sol";
import {IRewardsClaimManager} from "../../interfaces/IRewardsClaimManager.sol";
import {ContextClient} from "../context/ContextClient.sol";

/// @title RewardsClaimManager contract responsible for managing rewards claiming from the Plasma Vault
contract RewardsClaimManager is AccessManagedUpgradeable, ContextClient, IRewardsClaimManager {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    address public immutable UNDERLYING_TOKEN;
    address public immutable PLASMA_VAULT;

    error UnableToTransferUnderlyingToken();

    event AmountWithdrawn(uint256 amount);

    constructor(address initialAuthority_, address plasmaVault_) initializer {
        super.__AccessManaged_init_unchained(initialAuthority_);

        UNDERLYING_TOKEN = PlasmaVault(plasmaVault_).asset();
        PLASMA_VAULT = plasmaVault_;

        RewardsClaimManagersStorageLib.setupVestingTime(1);
    }

    function balanceOf() public view returns (uint256) {
        VestingData memory data = RewardsClaimManagersStorageLib.getVestingData();

        if (data.vestingTime == 0) {
            return IERC20(UNDERLYING_TOKEN).balanceOf(address(this));
        }

        if (data.updateBalanceTimestamp == 0) {
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

    function _msgSender() internal view override returns (address) {
        return getSenderFromContext();
    }

    /**
     * @dev Reverts if the caller is not allowed to call the function identified by a selector. Panics if the calldata
     * is less than 4 bytes long.
     */
    function _checkCanCall(address caller_, bytes calldata data_) internal override {
        bytes4 sig = bytes4(data_[0:4]);
        // @dev for context manager 87ef0b87 - setupContext, db99bddd - clearContext
        if (sig == bytes4(0x87ef0b87) || sig == bytes4(0xdb99bddd)) {
            caller_ = msg.sender;
        }

        AccessManagedStorage storage $ = _getAccessManagedStorage();
        (bool immediate, uint32 delay) = AuthorityUtils.canCallWithDelay(
            authority(),
            caller_,
            address(this),
            bytes4(data_[0:4])
        );
        if (!immediate) {
            if (delay > 0) {
                $._consumingSchedule = true;
                IAccessManager(authority()).consumeScheduledOp(caller_, data_);
                $._consumingSchedule = false;
            } else {
                revert AccessManagedUnauthorized(caller_);
            }
        }
    }
}
